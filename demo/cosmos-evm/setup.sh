#!/usr/bin/env bash
# setup.sh — boot a Cosmos (wfchain) + Besu+Teku (Ethereum) devnet and wire up
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
#   SOLIDITY_IBC_DIR       — local checkout; otherwise auto-downloaded (SOLIDITY_IBC_TAG)
#   ETHEREUM_LC_WASM_PATH  — path to ethereum-lc.wasm; otherwise extracted from tarball
#   ICS26_ROUTER_ADDR / ICS20_TRANSFER_ADDR / SP1_ICS07_ADDR — skip forge deploy
#   WASM_CHECKSUM          — skip wasm fetch
#
# Requirements: docker (compose plugin), jq, curl, openssl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
LIB_DIR="$SCRIPT_DIR/lib"
# Static configs + templates, grouped by which service reads them.
COSMOS_CFG_DIR="$SCRIPT_DIR/cosmos"   # app.toml, config.toml, genesis jq filters
EVM_DIR="$SCRIPT_DIR/evm"              # besu.toml, teku.yaml, el-genesis, mnemonics tmpl
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
export COSMOS_IMAGE="${COSMOS_IMAGE:-ghcr.io/cosmos/wfchain:latest}"
export BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:26.2.0}"
export TEKU_IMAGE="${TEKU_IMAGE:-consensys/teku:26.4}"
export ETH2_VAL_TOOLS_IMAGE="${ETH2_VAL_TOOLS_IMAGE:-protolambda/eth2-val-tools}"
# ethpandaops publishes separate arch-specific tags for this image (no
# multi-arch manifest), so pick based on host. Apple-silicon dev hosts get
# arm64; everything else (x86 Linux, CI runners) gets amd64.
case "$(uname -m)" in
  arm64|aarch64) _eth2_genesis_arch="arm64" ;;
  *)             _eth2_genesis_arch="amd64" ;;
esac
export ETH2_TESTNET_GENESIS_IMAGE="${ETH2_TESTNET_GENESIS_IMAGE:-ethpandaops/ethereum-genesis-generator:master-linux-${_eth2_genesis_arch}}"
unset _eth2_genesis_arch
export FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:latest}"
export BUN_IMAGE="${BUN_IMAGE:-oven/bun:1}"
export OPERATOR_IMAGE="${OPERATOR_IMAGE:-ghcr.io/cosmos/ibc-relayer:v0.0.2}"
export ATTESTOR_IMAGE="${ATTESTOR_IMAGE:-ghcr.io/cosmos/ibc-attestor:latest}"
export PROOF_API_IMAGE="${PROOF_API_IMAGE:-ghcr.io/cosmos/proof-api:latest}"

# Cosmos (wfchain)
COSMOS_CHAIN_ID="cosmos-1"
COSMOS_BINARY="wfchaind"
COSMOS_HOME="/data"
COSMOS_BECH32_PREFIX="wf"
COSMOS_DENOM="uatom"
COSMOS_VALIDATOR_STAKE="1000000000uatom"      # 1 000 ATOM
COSMOS_VALIDATOR_BALANCE="10000000000uatom"   # 10 000 ATOM (validator + fees)
COSMOS_RELAYER_BALANCE="10000000uatom"        #     10 ATOM (relayer gas)

# Ethereum
ETH_CHAIN_ID=32382
ETH_VALIDATOR_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ETH_VALIDATOR_PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# DEVNET mnemonic — insecure, for local devnet only, never use on mainnet.
DEVNET_MNEMONIC="${DEVNET_MNEMONIC:-plastic ozone child tennis endless permit sort glory evolve text because disease acoustic perfect master want artefact comic escape machine exclude bread melt play}"

# IBC (Phase 4)
SOLIDITY_IBC_DIR="${SOLIDITY_IBC_DIR:-}"
# Default to main: the latest tagged release (solidity-v2.0.1) predates
# ICS27GMP.sol, which is required for IFT end-to-end (IFT routes packets
# through GMP on port "gmpport"; v2.0.1 only wires ICS20 on port "transfer").
# Pin to a specific tag once main stabilises an ICS27-aware release.
SOLIDITY_IBC_TAG="${SOLIDITY_IBC_TAG:-main}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-scripts/E2ETestDeploy.s.sol}"
SP1_PROVER="${SP1_PROVER:-mock}"
ICS26_ROUTER_ADDR="${ICS26_ROUTER_ADDR:-}"
ICS20_TRANSFER_ADDR="${ICS20_TRANSFER_ADDR:-}"
SP1_ICS07_ADDR="${SP1_ICS07_ADDR:-}"
ETHEREUM_LC_WASM_PATH="${ETHEREUM_LC_WASM_PATH:-}"
WASM_CHECKSUM="${WASM_CHECKSUM:-}"

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
EVM_COSMOS_CLIENT_ID="${EVM_COSMOS_CLIENT_ID:-}"
COSMOS_WASM_CLIENT_ID="${COSMOS_WASM_CLIENT_ID:-}"

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
  log "║  IBC Demo: Cosmos ↔ Besu+Teku (Ethereum)          ║"
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
  if [[ -z "${COSMOS_WASM_CLIENT_ID:-}" ]]; then
    COSMOS_WASM_CLIENT_ID=$(docker compose run --rm --no-deps --entrypoint="" cosmos \
      wfchaind query ibc client states --home /data --node tcp://cosmos:26657 \
      --output json 2>/dev/null | jq -r '.client_states[].client_id' 2>/dev/null \
      | grep "^attestations-" | tail -1 || true)
    [[ -n "$COSMOS_WASM_CLIENT_ID" ]] || die "COSMOS_WASM_CLIENT_ID unknown — run './setup.sh ibc' first"
    echo "COSMOS_WASM_CLIENT_ID=$COSMOS_WASM_CLIENT_ID" >> "$IBC_STATE_FILE"
  fi
  if [[ -z "${EVM_COSMOS_CLIENT_ID:-}" ]]; then
    local next_seq
    next_seq=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getNextClientSeq()(uint256)" \
      --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || next_seq=0
    if [[ "$next_seq" =~ ^[0-9]+$ ]] && (( next_seq > 0 )); then
      EVM_COSMOS_CLIENT_ID="client-$((next_seq - 1))"
      echo "EVM_COSMOS_CLIENT_ID=$EVM_COSMOS_CLIENT_ID" >> "$IBC_STATE_FILE"
    fi
  fi
  log "Cosmos client: ${COSMOS_WASM_CLIENT_ID}, EVM client: ${EVM_COSMOS_CLIENT_ID:-<unknown>}"

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