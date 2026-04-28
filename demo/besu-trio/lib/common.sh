#!/usr/bin/env bash
# Shared helpers: logging, prerequisites, RPC waiters.

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
  command -v curl      >/dev/null || die "curl is required"
}

# Poll an EVM JSON-RPC endpoint until eth_blockNumber returns a result.
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

# Read current block number (decimal) from an EVM RPC URL.
eth_block_number() {
  local url="$1"
  curl -sf "$url" -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | sed -n 's/.*"result":"0x\([0-9a-fA-F]*\)".*/\1/p' \
    | { read -r hex; [[ -n "$hex" ]] && printf '%d\n' "0x$hex" || echo "?"; }
}

run_phase() {
  local label="$1"; shift
  log "--- $label ---"
  "$@"
}

# Render a template by substituting `${VAR}` placeholders with the values of
# matching environment variables (variables must be exported — call sites
# should `set -a` around state.env sourcing or pass them inline).
#
# Pure substitution: no `$(...)` execution, no command parsing of expanded
# content. This matters when a placeholder expands to multi-line YAML — the
# previous eval+heredoc approach treated lines of the expanded value as
# commands and emitted spurious "command not found" errors (and was a
# security foot-gun).
#
# Heals the docker-bind-mount-created-a-directory case: if the output path
# is an empty directory, remove it first.
render_template() {
  local tmpl="$1" out="$2"
  [[ -d "$out" && ! -L "$out" ]] && rmdir "$out" 2>/dev/null || true
  mkdir -p "$(dirname "$out")"
  perl -pe 's/\$\{(\w+)\}/defined $ENV{$1} ? $ENV{$1} : ""/ge' "$tmpl" > "$out"
}
