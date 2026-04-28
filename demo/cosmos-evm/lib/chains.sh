#!/usr/bin/env bash
# Phase 1-3: chain initialisation, boot, readiness.

# Reclaim host-user ownership of cosmos/local/. wfchaind runs as root inside
# the container, so files it writes through the /data/config/ bind-mount end
# up root-owned on the host. macOS Docker Desktop transparently maps UIDs so
# this is a no-op there; on Linux/CI runners the host user can't read those
# files, and the host-side jq / cp that follow fail with EACCES (
# `Permission denied` on patch-genesis.jq, in particular).
# `[[ -O … ]]` short-circuits when ownership is already correct, so the
# docker spin-up only fires on fresh Linux runs.
_ensure_host_owns_cosmos_local() {
  [[ -O "$COSMOS_CFG_DIR/local/config/genesis.json" ]] && return 0
  docker run --rm --user 0 \
    -v "$COSMOS_CFG_DIR/local:/local" \
    busybox chown -R "$(id -u):$(id -g)" /local
}

# Apply a jq program to genesis.json directly on the host. The cosmos
# /data/config/ directory is bind-mounted from ./cosmos/local/config/ (see
# docker-compose.yml), so wfchaind init / add-genesis-account /
# collect-gentxs and these jq patches all write through to the same file —
# no volume roundtrip needed.
# Usage: patch_cosmos_genesis <prog.jq> [extra jq args...]
patch_cosmos_genesis() {
  local prog="$1"; shift
  local genesis="$COSMOS_CFG_DIR/local/config/genesis.json"
  _ensure_host_owns_cosmos_local
  local patched; patched=$(mktemp)
  jq "$@" -f "$prog" "$genesis" > "$patched"
  mv "$patched" "$genesis"
}

init_cosmos() {
  log "Initialising Cosmos chain ($COSMOS_CHAIN_ID)..."

  # Pre-create the host config dir so the directory bind-mount in
  # docker-compose.yml resolves cleanly. wfchaind init writes its default
  # genesis.json / app.toml / config.toml / *_key.json files directly into
  # this directory; we then overwrite app.toml / config.toml with our
  # customized versions and apply jq patches to genesis.json.
  mkdir -p "$COSMOS_CFG_DIR/local/config"

  # Idempotency guard — re-running add-genesis-account / gentx fails.
  if run_in cosmos "$COSMOS_BINARY" keys show validator \
      --keyring-backend test --home "$COSMOS_HOME" >/dev/null 2>&1; then
    log "Cosmos already initialised — skipping (validator key present)"
    return 0
  fi

  run_in cosmos "$COSMOS_BINARY" init wfchain-node \
    --chain-id "$COSMOS_CHAIN_ID" --home "$COSMOS_HOME" --overwrite 2>/dev/null

  run_in cosmos "$COSMOS_BINARY" keys add validator \
    --keyring-backend test --home "$COSMOS_HOME" --output json --no-backup 2>/dev/null
  local validator_addr
  validator_addr=$(run_in cosmos "$COSMOS_BINARY" keys show validator -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null)
  run_in cosmos "$COSMOS_BINARY" genesis add-genesis-account \
    "$validator_addr" "$COSMOS_VALIDATOR_BALANCE" --home "$COSMOS_HOME"

  run_in cosmos "$COSMOS_BINARY" keys add relayer \
    --keyring-backend test --home "$COSMOS_HOME" --output json --no-backup 2>/dev/null
  local relayer_addr
  relayer_addr=$(run_in cosmos "$COSMOS_BINARY" keys show relayer -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null)
  run_in cosmos "$COSMOS_BINARY" genesis add-genesis-account \
    "$relayer_addr" "$COSMOS_RELAYER_BALANCE" --home "$COSMOS_HOME"

  # Patch bond_denom etc. BEFORE gentx so the stake denom validates correctly.
  # Also override IFT module authority to the validator so `tx ift register-bridge`
  # works with --from validator (default authority is the gov module account).
  log "Patching Cosmos genesis (bond_denom → uatom, ift authority → validator)..."
  patch_cosmos_genesis "$COSMOS_CFG_DIR/patch-genesis.jq" \
    --arg validator_addr "$validator_addr"

  run_in cosmos "$COSMOS_BINARY" genesis gentx validator "$COSMOS_VALIDATOR_STAKE" \
    --chain-id "$COSMOS_CHAIN_ID" --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null
  run_in cosmos "$COSMOS_BINARY" genesis collect-gentxs --home "$COSMOS_HOME" 2>/dev/null

  # Override init's default app.toml/config.toml with the customized versions
  # in ./cosmos/. Host-side cp because /data/config/ is bind-mounted from
  # ./cosmos/local/config/. Reclaim ownership first — collect-gentxs above
  # may have flipped genesis.json (and any sibling files it touches) back to
  # root via tmpfile+rename, and cp -T over a root-owned dest fails on Linux.
  _ensure_host_owns_cosmos_local
  cp "$COSMOS_CFG_DIR/app.toml"    "$COSMOS_CFG_DIR/local/config/app.toml"
  cp "$COSMOS_CFG_DIR/config.toml" "$COSMOS_CFG_DIR/local/config/config.toml"

  log "Cosmos init done"
  log "  validator: $validator_addr  ($COSMOS_VALIDATOR_BALANCE)"
  log "  relayer:   $relayer_addr    ($COSMOS_RELAYER_BALANCE)"
}

init_ethereum() {
  log "Initialising Ethereum (Besu)..."
  [[ -f "$EVM_DIR/el-genesis.json" ]] || die "evm/el-genesis.json not found"

  log "Starting Besu..."
  docker compose up -d besu
  wait_for_rpc "besu" "http://localhost:8545"

  log "Ethereum init done"
}

start_services() {
  log "Starting cosmos..."
  docker compose up -d cosmos
}

wait_for_services() {
  wait_for_cosmos "cosmos" "http://localhost:26657"
}

print_status() {
  echo ""
  info "════════════════════════════════════════════"
  info " Chain endpoints"
  info "════════════════════════════════════════════"
  info " Cosmos (wfchain)"
  info "   CometBFT RPC : http://localhost:26657"
  info "   REST API      : http://localhost:1317"
  info "   gRPC          : localhost:9090"
  info ""
  info " Besu (Ethereum EL)"
  info "   JSON-RPC HTTP : http://localhost:8545"
  info "   WebSocket     : ws://localhost:8546"
  info "   Chain ID      : $ETH_CHAIN_ID"
  info "   Funded addr   : $ETH_VALIDATOR_ADDR"
  info "   Private key   : $ETH_VALIDATOR_PRIVKEY"
  info "════════════════════════════════════════════"
  echo ""

  local cosmos_height eth_height_hex eth_height
  cosmos_height=$(curl -sf http://localhost:26657/status 2>/dev/null \
    | jq -r '.result.sync_info.latest_block_height' 2>/dev/null) || cosmos_height="?"
  eth_height_hex=$(curl -sf http://localhost:8545 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r '.result' 2>/dev/null) || eth_height_hex="?"
  [[ "$eth_height_hex" != "?" ]] && eth_height=$(( eth_height_hex )) || eth_height="?"
  info " Cosmos block height : $cosmos_height"
  info " EVM chain height  : $eth_height"
  echo ""
}

# Remove each path if it exists, logging what was actually removed. Accepts
# plain paths and unquoted globs — unmatched globs are silently skipped.
_clean_path() {
  local path removed=0
  for path in "$@"; do
    [[ -e "$path" ]] || continue
    log "  removed $path"
    rm -rf "$path"
    removed=$((removed + 1))
  done
  return 0
}

clean() {
  log "Stopping containers and removing data..."
  docker compose down -v --remove-orphans 2>/dev/null || true

  _clean_path \
    "$COSMOS_CFG_DIR/local" \
    "$IBC_DIR/local" \
    "$IBC_DIR/state.env" \
    "$IBC_DIR"/solidity-ibc-eureka-* \
    "$IBC_DIR"/ibc-relayer-*

  log "Clean done"
}
