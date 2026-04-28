#!/usr/bin/env bash
# setup.sh — besu-trio demo.
#
# Boots three single-validator Besu QBFT chains (A, hub, B), deploys the
# solidity-ibc-eureka contract stack on each, brings up the relayer + 4
# attestors + proof-api, and wires both IBC pairs (A↔hub, B↔hub) by deploying
# BesuQBFTLightClient instances and calling ICS26Router.addClient on each side.
#
# Usage:
#   ./setup.sh                  — chains + contracts + services + wire (default end-to-end)
#   ./setup.sh chains           — start besu-a, besu-hub, besu-b only
#   ./setup.sh contracts        — deploy IBC contracts to all 3 chains
#                                  (chains must already be up)
#   ./setup.sh build-proof-api  — build the local proof-api image from the
#                                  fetched eureka source. Idempotent.
#                                  (contracts must already be deployed so the
#                                  source exists)
#   ./setup.sh services         — build local proof-api image (if missing),
#                                  render attestor/relayer/proof-api configs,
#                                  and start postgres + 4 attestors + proof-api
#                                  + relayer (contracts must already be deployed)
#   ./setup.sh wire           — deploy BesuQBFTLightClient on each chain,
#                                call ICS26Router.addClient (sets counterparty),
#                                re-render relayer config + restart relayer
#                                (services must already be running)
#   ./setup.sh transfer DIR [AMOUNT]
#                             — DIR ∈ {a-to-hub,hub-to-a,hub-to-b,b-to-hub,a-hub-b}
#                                Deploys EVMIFTSendCallConstructor (once per
#                                chain), registers IFT bridges (lazy), mints
#                                if needed, calls TestIFT.iftTransfer, submits
#                                tx to relayer gRPC Relay API, waits for the
#                                destination IFT balance to change.
#                                Default amount 1000.
#   ./setup.sh status         — print RPC endpoints, block heights, addresses
#   ./setup.sh clean          — stop containers, remove volumes + fetched source
#
# Environment (optional):
#   SOLIDITY_IBC_DIR  — local checkout; otherwise auto-downloaded
#   SOLIDITY_IBC_TAG  — tag/branch to fetch (default: main)
#   DEPLOY_SCRIPT     — forge script path inside the eureka tree
#                       (default: scripts/MinimalDeploy.s.sol; copied from
#                       ibc/scripts/ before each deploy)
#
# Requirements: docker (compose plugin), curl, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
LIB_DIR="$SCRIPT_DIR/lib"
IBC_DIR="$SCRIPT_DIR/ibc"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee >(perl -pe 's/\x1b\[[0-9;]*[A-Za-z]//g' >> "$LOG_FILE")) 2>&1
echo "[$(date '+%H:%M:%S')] Logging to $LOG_FILE"

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
export BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:25.4.0}"
export FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:latest}"
export BUN_IMAGE="${BUN_IMAGE:-oven/bun:1}"
export ATTESTOR_IMAGE="${ATTESTOR_IMAGE:-ghcr.io/cosmos/ibc-attestor:latest}"
# Default to a locally-built proof-api image (built from gjermund/besu-poc
# source, which includes the besu-to-besu relayer module that ghcr.io/cosmos/
# proof-api:latest lacks). build_proof_api_image creates this tag on demand.
export PROOF_API_IMAGE="${PROOF_API_IMAGE:-besu-trio/proof-api:local}"
export OPERATOR_IMAGE="${OPERATOR_IMAGE:-ghcr.io/cosmos/ibc-relayer:v0.0.2}"
COMPOSE_PROJECT="$COMPOSE_PROJECT_NAME"

# IBC source / deploy config
SOLIDITY_IBC_DIR="${SOLIDITY_IBC_DIR:-}"
SOLIDITY_IBC_TAG="${SOLIDITY_IBC_TAG:-gjermund/besu-poc}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-scripts/MinimalDeploy.s.sol}"
IBC_STATE_FILE="$IBC_DIR/state.env"

# Deployer key — Anvil dev account #0 (chain A's validator), pre-funded on
# all three chains via the genesis allocs, so the same EOA can deploy
# everywhere. Exported so render_template (perl + $ENV) can see them when
# rendering proof-api.json.tmpl.
export DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
export DEPLOYER_PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/chains.sh
source "$LIB_DIR/chains.sh"
# shellcheck source=lib/ibc.sh
source "$LIB_DIR/ibc.sh"

cmd_chains() {
  check_prerequisites
  log "╔══════════════════════════════════════════════════╗"
  log "║  besu-trio: 3 Besu QBFT chains (A, hub, B)        ║"
  log "╚══════════════════════════════════════════════════╝"
  run_phase "Phase 1A: Start chains"      start_chains
  run_phase "Phase 1B: Wait for RPC"      wait_for_chains
  print_status
  log "Chains are live and producing blocks."
}

cmd_contracts() {
  command -v jq >/dev/null || die "jq is required for contracts deploy"
  # set -a auto-exports every var sourced from state.env so render_template
  # (perl + $ENV) can see them.
  set -a
  [[ -f "$IBC_STATE_FILE" ]] && source "$IBC_STATE_FILE" 2>/dev/null || true
  set +a
  log "--- Phase 2: Deploy IBC contracts on each chain ---"
  deploy_all_chains
  print_deployed
}

cmd_services() {
  set -a
  [[ -f "$IBC_STATE_FILE" ]] && source "$IBC_STATE_FILE" 2>/dev/null \
    || die "$IBC_STATE_FILE not found — run './setup.sh contracts' first"
  set +a
  log "--- Phase 3: Render configs + start IBC services ---"
  run_phase "Phase 3A: Build local proof-api image"               build_proof_api_image
  run_phase "Phase 3B: Render attestor/relayer/proof-api configs" render_ibc_configs
  run_phase "Phase 3C: Start IBC services"                        start_ibc_services
  log "Services running. Run './setup.sh wire' to deploy LCs + register counterparties."
}

cmd_build_proof_api() {
  build_proof_api_image
}

cmd_transfer() {
  local direction="${1:-}" amount="${2:-1000}"
  command -v jq >/dev/null || die "jq is required for transfer"
  set -a
  [[ -f "$IBC_STATE_FILE" ]] && source "$IBC_STATE_FILE" 2>/dev/null \
    || die "$IBC_STATE_FILE not found — run './setup.sh' (chains+contracts+services+wire) first"
  set +a
  case "$direction" in
    a-to-hub) transfer_ift A   hub "$amount" ;;
    hub-to-a) transfer_ift hub A   "$amount" ;;
    hub-to-b) transfer_ift hub B   "$amount" ;;
    b-to-hub) transfer_ift B   hub "$amount" ;;
    a-hub-b)
      transfer_ift A   hub "$amount"
      transfer_ift hub B   "$amount"
      ;;
    "")
      echo "Usage: $0 transfer <a-to-hub|hub-to-a|hub-to-b|b-to-hub|a-hub-b> [amount]" >&2
      exit 1
      ;;
    *) die "Unknown transfer direction '$direction'. Try a-to-hub | hub-to-b | a-hub-b" ;;
  esac
}

cmd_wire() {
  command -v jq >/dev/null || die "jq is required for wire"
  set -a
  [[ -f "$IBC_STATE_FILE" ]] && source "$IBC_STATE_FILE" 2>/dev/null \
    || die "$IBC_STATE_FILE not found — run './setup.sh contracts && ./setup.sh services' first"
  set +a

  log "--- Phase 4: BesuQBFTLightClient deploy + counterparty registration ---"
  run_phase "Phase 4A: Deploy LCs + addClient on each pair" wire_all_pairs

  # Re-source state so the new *_LC_ID values are visible to the renderer.
  set -a
  source "$IBC_STATE_FILE"
  set +a

  run_phase "Phase 4B: Re-render relayer config with populated counterparty_chains" \
    generate_relayer_config

  log "Restarting relayer to pick up new counterparty_chains..."
  docker compose restart relayer
  log "Phase 4 complete. Relayer should now be driving both pairs."
}

main() {
  case "${1:-}" in
    clean)     clean;        exit 0 ;;
    status)    print_status; print_deployed; exit 0 ;;
    chains)         cmd_chains;          exit 0 ;;
    contracts)      cmd_contracts;       exit 0 ;;
    build-proof-api) cmd_build_proof_api; exit 0 ;;
    services)       cmd_services;        exit 0 ;;
    wire)           cmd_wire;            exit 0 ;;
    transfer)       shift; cmd_transfer "$@"; exit 0 ;;
    "")
      cmd_chains
      cmd_contracts
      cmd_services
      cmd_wire
      exit 0
      ;;
    *)
      echo "Usage: $0 [chains|contracts|build-proof-api|services|wire|transfer|status|clean]" >&2
      echo "       $0 transfer <a-to-hub|hub-to-a|hub-to-b|b-to-hub|a-hub-b> [amount]" >&2
      exit 1
      ;;
  esac
}

main "$@"
