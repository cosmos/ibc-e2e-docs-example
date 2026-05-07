#!/usr/bin/env bash
# Phase 1-3: chain initialisation, boot, readiness.

# Reclaim host-user ownership of cosmos/local/. sandboxd runs as root inside
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
# docker-compose.yml), so sandboxd init / add-genesis-account /
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
  # docker-compose.yml resolves cleanly. sandboxd init writes its default
  # genesis.json / app.toml / config.toml / *_key.json files directly into
  # this directory; we then overwrite app.toml / config.toml with our
  # customized versions and apply jq patches to genesis.json.
  mkdir -p "$COSMOS_CFG_DIR/local/config"
  # docker-compose.yml bind-mounts ./cosmos/local/keyring-test into both
  # cosmos and relayer containers; pre-create it so docker doesn't make
  # the host dir root-owned on Linux.
  mkdir -p "$COSMOS_CFG_DIR/local/keyring-test"

  # Always sync our customized app.toml / config.toml — this happens before
  # the idempotency guard so edits to ./cosmos/{app,config}.toml apply on
  # re-runs without `./setup.sh clean`. On a *fresh* run the dest files
  # don't exist yet (init hasn't run); cp creates them, and init's
  # subsequent --overwrite call replaces them with its own defaults that
  # we'll need to re-cp at the end of this function to win.
  if [[ -f "$COSMOS_CFG_DIR/local/config/genesis.json" ]]; then
    _ensure_host_owns_cosmos_local
    cp "$COSMOS_CFG_DIR/app.toml"    "$COSMOS_CFG_DIR/local/config/app.toml"
    cp "$COSMOS_CFG_DIR/config.toml" "$COSMOS_CFG_DIR/local/config/config.toml"
  fi

  # Idempotency guard — re-running keys add / add-genesis-account fails.
  if run_in cosmos keys show validator \
      --keyring-backend test --home "$COSMOS_HOME" >/dev/null 2>&1; then
    log "Cosmos already initialised — skipping (validator key present)"
    return 0
  fi

  run_in cosmos init sandbox-node \
    --chain-id "$COSMOS_CHAIN_ID" --home "$COSMOS_HOME" \
    --default-denom "$COSMOS_DENOM" --overwrite

  # `--key-type secp256k1` overrides sandbox's default of `eth_secp256k1`.
  # The Go ibc-relayer parses its keys.json privkey via the standard
  # cosmos-sdk `secp256k1.PrivKey.UnmarshalAmino`, which derives addresses
  # as bech32(ripemd160(sha256(pubkey))). `eth_secp256k1` uses Ethereum-
  # style bech32(keccak256(pubkey)[12:]) — the SAME 32 raw privkey bytes
  # produce DIFFERENT bech32 addresses across the two algorithms, which
  # surfaces as `account cosmosX… not found` at recvPacket time even
  # though the privkey extraction is clean.
  run_in cosmos keys add validator --key-type secp256k1 \
    --keyring-backend test --home "$COSMOS_HOME" --output json --no-backup
  local validator_addr
  validator_addr=$(run_in cosmos keys show validator -a \
    --keyring-backend test --home "$COSMOS_HOME")
  run_in cosmos genesis add-genesis-account \
    "$validator_addr" "$COSMOS_VALIDATOR_BALANCE" --home "$COSMOS_HOME"

  run_in cosmos keys add relayer --key-type secp256k1 \
    --keyring-backend test --home "$COSMOS_HOME" --output json --no-backup
  local relayer_addr
  relayer_addr=$(run_in cosmos keys show relayer -a \
    --keyring-backend test --home "$COSMOS_HOME")
  run_in cosmos genesis add-genesis-account \
    "$relayer_addr" "$COSMOS_RELAYER_BALANCE" --home "$COSMOS_HOME"

  # The PoA module needs at least one validator pre-baked into genesis or
  # its `init_genesis` rejects on `total_power == 0`. We use the consensus
  # ed25519 key sandboxd just wrote to priv_validator_key.json — that key
  # is the one CometBFT signs blocks with for this node, so registering
  # a different key would deadlock the chain at height 1.
  local consensus_pubkey
  consensus_pubkey=$(jq -r '.pub_key.value' \
    "$COSMOS_CFG_DIR/local/config/priv_validator_key.json")
  [[ -n "$consensus_pubkey" && "$consensus_pubkey" != "null" ]] \
    || die "Failed to read consensus pubkey from priv_validator_key.json"

  # Patch denoms (mostly defaults on sandbox), IFT authority, and PoA
  # validator/admin. patch-genesis.jq must run BEFORE the chain starts so
  # PoA validation passes when sandboxd loads the genesis.
  log "Patching Cosmos genesis (denoms → uatom, ift authority → validator, PoA validator)..."
  patch_cosmos_genesis "$COSMOS_CFG_DIR/patch-genesis.jq" \
    --arg validator_addr   "$validator_addr" \
    --arg consensus_pubkey "$consensus_pubkey"

  # gentx + collect-gentxs intentionally omitted: sandbox is PoA-driven, so
  # a staking self-delegation tx wouldn't supply consensus power, and
  # collect-gentxs's whole-genesis validation step rejects an empty
  # poa.validators array (which is why the previous flow was failing).

  # Re-cp the customized app.toml / config.toml after init's --overwrite
  # clobbered them. _ensure_host_owns_cosmos_local first because patch
  # rewrites genesis.json via tmpfile+rename and may flip sibling
  # ownership to root on Linux.
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
  info " Cosmos (sandbox)"
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
