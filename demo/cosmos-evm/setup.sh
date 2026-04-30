#!/usr/bin/env bash
# setup.sh — boot a Cosmos (sandbox) + Besu (Ethereum) devnet and wire up
#            IBC between them using cosmos/solidity-ibc-eureka.
#
# Usage:
#   ./setup.sh              — init chains, start everything, set up IBC
#   ./setup.sh chains       — init + start chains only (skip IBC)
#   ./setup.sh ibc          — set up IBC on already-running chains
#   ./setup.sh demo [sub]   — run user-story demos
#                             (transfer | cosmos-evm | evm-cosmos | track | failure | observe | all)
#   ./setup.sh status       — print RPC endpoints and block heights
#   ./setup.sh clean        — stop containers and remove all data
#
# Implementation layout:
#   lib/common.sh   — logging, docker helpers, template rendering
#   lib/chains.sh   — cosmos + ethereum init, readiness
#   lib/ibc.sh      — contract deploy, client create, relayer wiring
#   lib/demo.sh     — user-story demonstrations
#   templates/      — config templates (rendered via render_template)
#
# Environment (optional):
#   SOLIDITY_IBC_DIR        — local checkout; otherwise auto-downloaded (SOLIDITY_IBC_TAG)
#   ICS26_ROUTER_ADDR       — skip forge deploy
#   EVM_ATTESTATION_LC_ADDR — skip AttestationLightClient deploy
#
# Requirements: docker (compose plugin), jq, curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
LIB_DIR="$SCRIPT_DIR/lib"
# Static configs + templates, grouped by which service reads them.
COSMOS_CFG_DIR="$SCRIPT_DIR/cosmos"   # app.toml, config.toml, genesis jq filters
EVM_DIR="$SCRIPT_DIR/evm"              # besu.toml, el-genesis.json, key
IBC_DIR="$SCRIPT_DIR/ibc"              # relayer + attestor + proof-api templates, runtime state

# ─── Log file ─────────────────────────────────────────────────────────────────
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee >(perl -pe 's/\x1b\[[0-9;]*[A-Za-z]//g' >> "$LOG_FILE")) 2>&1
echo "[$(date '+%H:%M:%S')] Logging to $LOG_FILE"

# ─── Configuration ────────────────────────────────────────────────────────────
# Docker Compose project name (= volume prefix: ${COMPOSE_PROJECT}_cosmos-data).
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"

# Docker images — exported so docker-compose.yml picks them up via ${VAR:-default}.
export COSMOS_IMAGE="${COSMOS_IMAGE:-ghcr.io/cosmos/sandbox-ledger:latest}"
export BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:25.4.0}"
export FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:latest}"
export BUN_IMAGE="${BUN_IMAGE:-oven/bun:1}"
export OPERATOR_IMAGE="${OPERATOR_IMAGE:-ghcr.io/cosmos/ibc-relayer:v0.0.2}"
export ATTESTOR_IMAGE="${ATTESTOR_IMAGE:-ghcr.io/cosmos/ibc-attestor:latest}"
export PROOF_API_IMAGE="${PROOF_API_IMAGE:-ghcr.io/cosmos/proof-api:latest}"

# Cosmos (sandbox)
COSMOS_CHAIN_ID="cosmos-1"
# The cosmos image's ENTRYPOINT is `["sandboxd","start"]` (the chain binary
# baked together with its default subcommand), so appending `init …` to
# `docker compose run` would still run `start` and choke on the missing
# genesis. We override the entrypoint to just the binary on every run_in
# call — keep COSMOS_BINARY in sync if the image changes.
COSMOS_BINARY="sandboxd"
export RUN_IN_ENTRYPOINT="$COSMOS_BINARY"
COSMOS_HOME="/data"
COSMOS_BECH32_PREFIX="cosmos"
COSMOS_DENOM="uatom"
COSMOS_VALIDATOR_STAKE="1000000000uatom"      # 1 000 ATOM
COSMOS_VALIDATOR_BALANCE="10000000000uatom"   # 10 000 ATOM (validator + fees)
COSMOS_RELAYER_BALANCE="10000000uatom"        #     10 ATOM (relayer gas)

# Ethereum
ETH_CHAIN_ID=32382
ETH_VALIDATOR_ADDR="0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
ETH_VALIDATOR_PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# IBC (Phase 4)
SOLIDITY_IBC_DIR="${SOLIDITY_IBC_DIR:-}"
# Default to main: the latest tagged release (solidity-v2.0.1) predates
# ICS27GMP.sol, which is required for IFT end-to-end (IFT routes packets
# through GMP on port "gmpport";
# Pin to a specific tag once main stabilises an ICS27-aware release.
SOLIDITY_IBC_TAG="${SOLIDITY_IBC_TAG:-main}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-scripts/MinimalDeploy.s.sol}"
ICS26_ROUTER_ADDR="${ICS26_ROUTER_ADDR:-}"
# AttestationLightClient on EVM — replaces SP1ICS07Tendermint. Deployed by
# create_evm_ibc_client; pre-set to skip that phase if you already have one
# wired up to ICS26Router.
EVM_ATTESTATION_LC_ADDR="${EVM_ATTESTATION_LC_ADDR:-}"

# Demo transfer
DEMO_ETH_RECIPIENT="${DEMO_ETH_RECIPIENT:-$ETH_VALIDATOR_ADDR}"
DEMO_TRANSFER_AMOUNT="${DEMO_TRANSFER_AMOUNT:-1000000uatom}"

# IFT (Interchain Fungible Token)
IFT_CONTRACT_ADDR="${IFT_CONTRACT_ADDR:-}"
COSMOS_IFT_DENOM="${COSMOS_IFT_DENOM:-}"
IFT_MINT_AMOUNT="${IFT_MINT_AMOUNT:-1000000000}"
# Populated by register_evm_ift_bridge at setup time; needed by the EVM→Cosmos
# IFT demo and persisted in state.env.
IFT_ICA_ADDRESS="${IFT_ICA_ADDRESS:-}"
IFT_CTOR_ADDR="${IFT_CTOR_ADDR:-}"

# Runtime-set client IDs (populated by setup_ibc; left as sentinels so the
# generate_relayer_config's ${VAR:-} expansion works before they're known).
EVM_CLIENT_ID="${EVM_CLIENT_ID:-}"
COSMOS_CLIENT_ID="${COSMOS_CLIENT_ID:-}"

PROOF_API_GRPC_ADDR="${PROOF_API_GRPC_ADDR:-proof-api:9090}"
# Flat fee (in COSMOS_DENOM) the relayer attaches to every IBC tx on Cosmos.
# Chain min-gas-prices is 0.025uatom × ~150k gas ≈ 3750 uatom for recv txs,
# so anything below that is rejected with "insufficient fee".
RELAYER_TX_FEE_AMOUNT="${RELAYER_TX_FEE_AMOUNT:-20000}"
IBC_STATE_FILE="$IBC_DIR/state.env"

# ─── Load libraries ────────────────────────────────────────────────────────────
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/chains.sh
source "$LIB_DIR/chains.sh"
# shellcheck source=lib/ibc.sh
source "$LIB_DIR/ibc.sh"
# shellcheck source=lib/demo.sh
source "$LIB_DIR/demo.sh"

# ─── Sub-commands ──────────────────────────────────────────────────────────────
cmd_chains() {
  check_prerequisites
  log "╔══════════════════════════════════════════════════╗"
  log "║  IBC Demo: Cosmos ↔ Besu (Ethereum, QBFT)         ║"
  log "╚══════════════════════════════════════════════════╝"
  log "--- Phase 1: Chain initialisation ---"
  init_cosmos
  init_ethereum     # leaves Besu running
  run_phase "Phase 2: Start remaining services" start_services
  run_phase "Phase 3: Wait for chains"          wait_for_services
  print_status
}

cmd_ibc() {
  [[ -f "$IBC_STATE_FILE" ]] && source "$IBC_STATE_FILE" 2>/dev/null || true
  setup_ibc
  # register_counterparty already runs inside setup_ibc (Phase 4F2); no
  # need to call it again here.
}

cmd_demo() {
  [[ -f "$IBC_STATE_FILE" ]] && source "$IBC_STATE_FILE" 2>/dev/null \
    || die "State file not found — run './setup.sh ibc' first"

  # Resolve client IDs from the running chain if missing.
  if [[ -z "${COSMOS_CLIENT_ID:-}" ]]; then
    COSMOS_CLIENT_ID=$(run_in cosmos query ibc client states --home /data \
      --node tcp://cosmos:26657 --output json 2>/dev/null \
      | jq -r '.client_states[].client_id' 2>/dev/null \
      | grep "^attestations-" | tail -1 || true)
    [[ -n "$COSMOS_CLIENT_ID" ]] || die "COSMOS_CLIENT_ID unknown — run './setup.sh ibc' first"
    echo "COSMOS_CLIENT_ID=$COSMOS_CLIENT_ID" >> "$IBC_STATE_FILE"
  fi
  if [[ -z "${EVM_CLIENT_ID:-}" ]]; then
    local next_seq
    next_seq=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getNextClientSeq()(uint256)" \
      --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || next_seq=0
    if [[ "$next_seq" =~ ^[0-9]+$ ]] && (( next_seq > 0 )); then
      EVM_CLIENT_ID="client-$((next_seq - 1))"
      echo "EVM_CLIENT_ID=$EVM_CLIENT_ID" >> "$IBC_STATE_FILE"
    fi
  fi
  log "Cosmos client: ${COSMOS_CLIENT_ID}, EVM client: ${EVM_CLIENT_ID:-<unknown>}"

  case "${1:-all}" in
    transfer)   demo_cosmos_to_evm_transfer; demo_evm_to_cosmos_transfer ;;
    cosmos-evm) demo_cosmos_to_evm_transfer ;;
    evm-cosmos) demo_evm_to_cosmos_transfer ;;
    track)      demo_track_packet_status ;;
    failure)    demo_failure_and_retry ;;
    observe)    demo_observability ;;
    all)        demo_all ;;
    *)
      echo "Usage: $0 demo [transfer|cosmos-evm|evm-cosmos|track|failure|observe|all]"
      exit 1
      ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in
    clean)  clean; exit 0 ;;
    status) print_status; exit 0 ;;
    chains)
      cmd_chains
      log "Both chains are live.  Run './setup.sh ibc' to set up IBC."
      exit 0
      ;;
    ibc)    cmd_ibc; exit 0 ;;
    demo)   shift; cmd_demo "$@"; exit 0 ;;
  esac

  # Default: end-to-end — chains then IBC.
  cmd_chains
  run_phase "Phase 4: IBC setup" setup_ibc
}

main "$@"