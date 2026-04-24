#!/usr/bin/env bash
# Phase 1-3: chain initialisation, boot, readiness.

# Apply a jq program to cosmos-data/config/genesis.json.
# Usage: patch_cosmos_genesis <prog.jq> [extra jq args...]
patch_cosmos_genesis() {
  local prog="$1"; shift
  local tmp; tmp=$(mktemp)
  local patched="${tmp}.patched"
  vol_cp_from "$COSMOS_HOME/config/genesis.json" "$tmp"
  jq "$@" -f "$prog" "$tmp" > "$patched"
  vol_cp_to "$patched" "$COSMOS_HOME/config/genesis.json"
  rm -f "$tmp" "$patched"
}

init_cosmos() {
  log "Initialising Cosmos chain ($COSMOS_CHAIN_ID)..."

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
  log "Patching Cosmos genesis (bond_denom → uatom, 08-wasm allowed, ift authority → validator)..."
  patch_cosmos_genesis "$COSMOS_CFG_DIR/patch-genesis.jq" \
    --arg validator_addr "$validator_addr"

  # Embed Ethereum LC wasm directly in genesis — available from block 0.
  if [[ -n "$ETHEREUM_LC_WASM_PATH" ]]; then
    [[ -f "$ETHEREUM_LC_WASM_PATH" ]] || die "ETHEREUM_LC_WASM_PATH='$ETHEREUM_LC_WASM_PATH' not found"
    log "Injecting Ethereum LC wasm into genesis..."
    local wasm_abs wasm_b64 wasm_hash_b64
    wasm_abs="$(cd "$(dirname "$ETHEREUM_LC_WASM_PATH")" && pwd)/$(basename "$ETHEREUM_LC_WASM_PATH")"
    wasm_b64=$(base64 < "$wasm_abs" | tr -d '\n')
    wasm_hash_b64=$(openssl dgst -sha256 -binary "$wasm_abs" | base64 | tr -d '\n')
    WASM_CHECKSUM=$(openssl dgst -sha256 "$wasm_abs" | awk '{print $NF}')
    patch_cosmos_genesis "$COSMOS_CFG_DIR/inject-wasm-lc.jq" \
      --arg code "$wasm_b64" --arg hash "$wasm_hash_b64"
    log "Ethereum LC wasm injected — checksum: $WASM_CHECKSUM"
  fi

  run_in cosmos "$COSMOS_BINARY" genesis gentx validator "$COSMOS_VALIDATOR_STAKE" \
    --chain-id "$COSMOS_CHAIN_ID" --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null
  run_in cosmos "$COSMOS_BINARY" genesis collect-gentxs --home "$COSMOS_HOME" 2>/dev/null

  vol_cp_to "$COSMOS_CFG_DIR/app.toml"    "$COSMOS_HOME/config/app.toml"
  vol_cp_to "$COSMOS_CFG_DIR/config.toml" "$COSMOS_HOME/config/config.toml"

  log "Cosmos init done"
  log "  validator: $validator_addr  ($COSMOS_VALIDATOR_BALANCE)"
  log "  relayer:   $relayer_addr    ($COSMOS_RELAYER_BALANCE)"
}

init_ethereum() {
  log "Initialising Ethereum (Besu + Teku)..."
  [[ -f "$EVM_DIR/el-genesis.json" ]] || die "evm/el-genesis.json not found"
  [[ -f "$EVM_DIR/cl-config.yaml" ]]  || die "evm/cl-config.yaml not found"

  # JWT secret — regenerating while Besu is live would break Engine API auth.
  if docker compose ps besu 2>/dev/null | grep -q "Up"; then
    if [[ -f "$EVM_DIR/jwt.hex" ]]; then
      log "jwt.hex already present and Besu is running — reusing"
    else
      log "Besu running but jwt.hex missing — restarting Besu with new secret"
      openssl rand -hex 32 | tr -d '\n' > "$EVM_DIR/jwt.hex"
      docker compose restart besu
    fi
  else
    openssl rand -hex 32 | tr -d '\n' > "$EVM_DIR/jwt.hex"
    log "jwt.hex written"
  fi

  log "Starting Besu..."
  docker compose up -d besu
  wait_for_rpc "besu" "http://localhost:8545"

  local genesis_block el_genesis_ts_hex
  genesis_block=$(curl -sf http://localhost:8545 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}')
  EL_GENESIS_HASH=$(echo "$genesis_block" | jq -r '.result.hash')
  el_genesis_ts_hex=$(echo "$genesis_block" | jq -r '.result.timestamp')
  EL_GENESIS_TS_DEC=$(( el_genesis_ts_hex ))
  log "Besu EL genesis hash : $EL_GENESIS_HASH"
  log "Besu EL genesis time : $EL_GENESIS_TS_DEC"

  if [[ -f "$EVM_DIR/cl-genesis.ssz" ]]; then
    log "cl-genesis.ssz already present — skipping regeneration"
  else
    local cl_genesis_time; cl_genesis_time=$(date +%s)
    log "Generating CL genesis SSZ (genesis-time=$cl_genesis_time, el-hash=$EL_GENESIS_HASH)..."

    local tmp_cfg; tmp_cfg=$(mktemp)
    sed "s/^MIN_GENESIS_TIME:.*/MIN_GENESIS_TIME: $cl_genesis_time/" \
      "$EVM_DIR/cl-config.yaml" > "$tmp_cfg"
    render_template "$EVM_DIR/mnemonics.yaml.tmpl" "$EVM_DIR/mnemonics.yaml"

    docker run --rm --user root \
      --entrypoint /usr/local/bin/eth-genesis-state-generator \
      -v "$EVM_DIR":/evm \
      -v "$tmp_cfg":/cl-genesis-config.yaml:ro \
      "$ETH2_TESTNET_GENESIS_IMAGE" \
      beaconchain \
        --config /cl-genesis-config.yaml \
        --eth1-config /evm/el-genesis.json \
        --mnemonics /evm/mnemonics.yaml \
        --state-output /evm/cl-genesis.ssz \
        --json-output /evm/cl-genesis-debug.json

    local genesis_el_hash
    genesis_el_hash=$(jq -r '.latest_execution_payload_header.block_hash' \
      "$EVM_DIR/cl-genesis-debug.json" 2>/dev/null || echo "unknown")
    rm -f "$EVM_DIR/cl-genesis-debug.json" "$tmp_cfg" "$EVM_DIR/mnemonics.yaml"
    [[ "$genesis_el_hash" == "$EL_GENESIS_HASH" ]] || \
      die "EL genesis hash mismatch: expected $EL_GENESIS_HASH got $genesis_el_hash"
    log "cl-genesis.ssz written (EL genesis hash verified)"
  fi

  # BLS validator keystores → teku-data volume (idempotent).
  local teku_keys_cid has_keys=""
  teku_keys_cid=$(docker create -v "${COMPOSE_PROJECT}_teku-data":/data "$TEKU_IMAGE" 2>/dev/null)
  docker cp "${teku_keys_cid}:/data/validators/keys" - >/dev/null 2>&1 && has_keys="yes"
  docker rm "$teku_keys_cid" >/dev/null 2>&1

  if [[ -n "$has_keys" ]]; then
    log "Validator keystores already present — skipping"
  else
    log "Generating BLS validator keystores (eth2-val-tools → teku volume)..."
    docker run --rm --user root \
      -v "${COMPOSE_PROJECT}_teku-data":/data \
      "$ETH2_VAL_TOOLS_IMAGE" \
      keystores --insecure \
        --source-mnemonic "$DEVNET_MNEMONIC" \
        --source-min 0 --source-max 1 \
        --out-loc /data/validators

    # Teku wants each secret file wrapped in a directory named after its pubkey.
    docker run --rm --user root --entrypoint /bin/sh \
      -v "${COMPOSE_PROJECT}_teku-data":/data "$TEKU_IMAGE" \
      -c 'for f in /data/validators/secrets/0x*; do
            [ -f "$f" ] || continue
            tmp="${f}.tmp"
            mkdir "$tmp" && mv "$f" "$tmp/voting-keystore.txt" && mv "$tmp" "$f"
          done'
    log "BLS keystores at /data/validators/keys/"
  fi

  log "Ethereum init done"
}

start_services() {
  log "Starting cosmos + teku..."
  docker compose up -d cosmos teku
}

wait_for_services() {
  wait_for_cosmos "cosmos" "http://localhost:26657"
  local max=120 step=3 elapsed=0
  log "Waiting for teku beacon node..."
  while true; do
    local syncing
    syncing=$(curl -sf http://localhost:5051/eth/v1/node/syncing 2>/dev/null \
      | jq -r '.data.is_syncing') || syncing="err"
    if [[ "$syncing" == "false" ]]; then
      log "Teku is synced"; break
    fi
    (( elapsed += step ))
    (( elapsed >= max )) && die "Teku did not sync within ${max}s"
    sleep "$step"; echo -n "."
  done
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
  info ""
  info " Teku (Ethereum CL)"
  info "   Beacon REST   : http://localhost:5051"
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
    "$EVM_DIR/jwt.hex" \
    "$EVM_DIR/cl-genesis.ssz" \
    "$EVM_DIR/cl-genesis-debug.json" \
    "$EVM_DIR/mnemonics.yaml" \
    "$EVM_DIR/keystores" \
    "$IBC_DIR/local" \
    "$IBC_DIR/cw_ics08_wasm_eth.wasm" \
    "$IBC_DIR/state.env" \
    "$IBC_DIR"/solidity-ibc-eureka-* \
    "$IBC_DIR"/ibc-relayer-*

  log "Clean done"
}
