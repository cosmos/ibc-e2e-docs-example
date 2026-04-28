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
  command -v perl      >/dev/null || die "perl is required (used to strip ANSI codes from the log file)"
  docker compose version >/dev/null 2>&1 || die "'docker compose' plugin required"
  command -v jq        >/dev/null || die "jq is required"
  command -v curl      >/dev/null || die "curl is required"
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
  local max=60 step=3 elapsed=0 out hash res code

  out=$(run_in cosmos "$COSMOS_BINARY" "$@" \
        --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
        --keyring-backend test --home "$COSMOS_HOME" \
        --gas auto --gas-adjustment 1.4 --gas-prices 0.025uatom \
        --yes --output json 2>&1) \
    || die "cosmos tx broadcast failed. output:"$'\n'"$(head -10 <<<"$out")"

  hash=$(grep -E '^\{' <<<"$out" | tail -1 | jq -r '.txhash // empty' 2>/dev/null) || hash=""
  [[ -n "$hash" ]] || die "no txhash in tx output. raw output:"$'\n'"$(head -10 <<<"$out")"

  while (( elapsed < max )); do
    res=$(curl -sf "http://localhost:1317/cosmos/tx/v1beta1/txs/${hash}" 2>/dev/null) || res=""
    if [[ -n "$res" ]]; then
      code=$(jq -r '.tx_response.code // 0' <<<"$res" 2>/dev/null) || code=0
      [[ "$code" == "0" ]] || \
        die "tx $hash committed with code=$code: $(jq -r '.tx_response.raw_log // "(no log)"' <<<"$res" 2>/dev/null)"
      echo "$res"
      return 0
    fi
    sleep "$step"; (( elapsed += step ))
  done
  die "tx $hash did not commit within ${max}s — check: docker compose logs cosmos"
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

# HTTP curl inside the compose network. Use this for endpoints that aren't
# published on the host: relayer :3000 (gRPC API + /health), relayer :9100
# (Prometheus), attestor :9102 (HTTP health). Internal-only by docker-compose
# convention. Args are forwarded to curl as-is.
curl_in_net() {
  docker run --rm --entrypoint "" \
    --network "${COMPOSE_PROJECT}_ibc-net" \
    curlimages/curl:latest curl "$@"
}

# Persist KEY=VAL into $IBC_STATE_FILE, replacing any prior line for that
# key. Replaces the bare `echo "FOO=$FOO" >> "$IBC_STATE_FILE"` pattern that
# accumulated duplicate entries across re-runs (last value still won via
# shell sourcing semantics, but the file grew unboundedly).
state_set() {
  local key="$1" val="$2"
  if [[ -f "$IBC_STATE_FILE" ]]; then
    grep -v "^${key}=" "$IBC_STATE_FILE" > "${IBC_STATE_FILE}.tmp" 2>/dev/null || true
    mv "${IBC_STATE_FILE}.tmp" "$IBC_STATE_FILE"
  fi
  echo "${key}=${val}" >> "$IBC_STATE_FILE"
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
