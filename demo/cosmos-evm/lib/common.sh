#!/usr/bin/env bash
# Shared helpers: logging, prerequisites, docker + template rendering.

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR${NC} $*" >&2; exit 1; }

check_prerequisites() {
  log "Checking prerequisites..."
  command -v docker    >/dev/null || die "docker is required"
  docker compose version >/dev/null 2>&1 || die "'docker compose' plugin required"
  command -v jq        >/dev/null || die "jq is required"
  command -v curl      >/dev/null || die "curl is required"
  command -v openssl   >/dev/null || die "openssl is required"
}

# Render a template via bash variable expansion. Templates are trusted (in-repo);
# $(...) and backticks in templates WILL execute.
#
# Heals a common failure mode: when docker-compose bind-mounts a missing source
# file (e.g. ./ibc/local/relayer.json before it exists), Docker creates a
# directory at the mount path. Subsequent renders then fail with "Is a
# directory". If the output path is an empty directory we remove it first;
# non-empty directories surface the original error so the user can investigate.
render_template() {
  local tmpl="$1" out="$2"
  [[ -d "$out" && ! -L "$out" ]] && rmdir "$out" 2>/dev/null || true
  eval "cat <<RENDER_EOF
$(cat "$tmpl")
RENDER_EOF
" > "$out"
}

# One-off container using the compose service's image + mounts, no entrypoint.
run_in() {
  local svc="$1"; shift
  printf 'y\n' | docker compose run --rm --no-deps -T --entrypoint="" "$svc" "$@"
}

# Submit a Cosmos tx and wait for it to commit. Dies loudly on any failure.
#
# Usage:  cosmos_tx_and_wait tx <module> <subcommand> <args...> --from <key>
#
# Injects the common flags (chain-id, node, keyring, home, gas, yes, output json)
# so callers don't repeat them. Polls /cosmos/tx/v1beta1/txs/<hash> until the
# tx is indexed. Fails if:
#   - mempool/CheckTx rejects (run_in exits non-zero)
#   - no txhash in output
#   - tx commits with code != 0 (surfaces raw_log)
#   - tx doesn't commit within 60s
# On success: echoes the committed tx JSON (caller can pipe to jq for events).
cosmos_tx_and_wait() {
  local out json_line hash res code raw_log
  local max=60 step=3 elapsed=0

  out=$(run_in cosmos "$COSMOS_BINARY" "$@" \
        --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
        --keyring-backend test --home "$COSMOS_HOME" \
        --gas auto --gas-adjustment 1.4 --gas-prices 0.025uatom \
        --yes --output json 2>&1) \
    || die "cosmos tx broadcast failed. output:"$'\n'"$(echo "$out" | head -10)"

  # docker compose run mixes "Container … Creating/Created" status lines into
  # the captured output. Pick out the actual JSON line (starts with `{`) so jq
  # doesn't choke on the status noise.
  json_line=$(echo "$out" | grep -E '^\{' | tail -1 || echo "")
  hash=$(echo "$json_line" | jq -r '.txhash // empty' 2>/dev/null || echo "")
  [[ -n "$hash" ]] || die "no txhash in tx output. raw output:"$'\n'"$(echo "$out" | head -10)"

  while (( elapsed < max )); do
    res=$(curl -sf "http://localhost:1317/cosmos/tx/v1beta1/txs/${hash}" 2>/dev/null) || res=""
    if [[ -n "$res" ]]; then
      code=$(echo "$res" | jq -r '.tx_response.code // 0' 2>/dev/null || echo "0")
      if [[ "$code" != "0" ]]; then
        raw_log=$(echo "$res" | jq -r '.tx_response.raw_log // "(no log)"' 2>/dev/null || echo "(parse error)")
        die "tx $hash committed with code=$code: $raw_log"
      fi
      echo "$res"
      return 0
    fi
    sleep "$step"; (( elapsed += step ))
  done
  die "tx $hash did not commit within ${max}s — check: docker compose logs cosmos"
}

# Copy a file into/out of the cosmos-data volume via a stopped container.
# The cosmos image has no shell/cp, so `docker cp` is the only option.
vol_cp_to() {
  local src="$1" dest="$2" cid
  cid=$(docker create \
    -v "${COMPOSE_PROJECT}_cosmos-data:/data" \
    --entrypoint="" "$COSMOS_IMAGE" "$COSMOS_BINARY" version 2>/dev/null)
  docker cp "$src" "${cid}:${dest}"
  docker rm "$cid" >/dev/null 2>&1
}
vol_cp_from() {
  local src="$1" dest="$2" cid
  cid=$(docker create \
    -v "${COMPOSE_PROJECT}_cosmos-data:/data" \
    --entrypoint="" "$COSMOS_IMAGE" "$COSMOS_BINARY" version 2>/dev/null)
  docker cp "${cid}:${src}" "$dest"
  docker rm "$cid" >/dev/null 2>&1
}

# Foundry cast inside the compose network.
cast_in_net() {
  docker run --rm \
    --network "${COMPOSE_PROJECT}_ibc-net" \
    --entrypoint "" -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    "$FOUNDRY_IMAGE" cast "$@"
}

# grpcurl inside the compose network.
grpc_call() {
  docker run --rm \
    --network "${COMPOSE_PROJECT}_ibc-net" \
    fullstorydev/grpcurl:latest -plaintext "$@"
}

# Poll an EVM JSON-RPC endpoint until eth_blockNumber succeeds.
wait_for_rpc() {
  local name="$1" url="$2" max=120 step=3 elapsed=0
  log "Waiting for $name at $url..."
  while true; do
    if curl -sf "$url" -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
        | grep -q '"result"'; then
      log "$name is up"; return 0
    fi
    (( elapsed += step ))
    (( elapsed >= max )) && die "$name did not respond within ${max}s"
    sleep "$step"; echo -n "."
  done
}

# Poll a CometBFT node until caught up.
wait_for_cosmos() {
  local name="$1" url="$2" max=120 step=3 elapsed=0
  log "Waiting for $name at $url..."
  while true; do
    local v
    v=$(curl -sf "$url/status" 2>/dev/null | jq -r '.result.sync_info.catching_up') || v="err"
    if [[ "$v" == "false" ]]; then
      log "$name is live and caught up"; return 0
    fi
    (( elapsed += step ))
    (( elapsed >= max )) && die "$name did not become ready within ${max}s"
    sleep "$step"; echo -n "."
  done
}

# run_phase <label> <cmd...> — logs a banner then runs the command.
run_phase() {
  local label="$1"; shift
  log "--- $label ---"
  "$@"
}
