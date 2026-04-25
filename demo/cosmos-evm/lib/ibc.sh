#!/usr/bin/env bash
# Phase 4: IBC setup (source fetch, forge deploy, client create, relayer wiring).

fetch_solidity_ibc() {
  if [[ -n "$ICS26_ROUTER_ADDR" && -n "$ICS20_TRANSFER_ADDR" && -n "$EVM_ATTESTATION_LC_ADDR" ]]; then
    log "IBC contracts already provided — skipping source fetch"
    return 0
  fi
  if [[ -n "$SOLIDITY_IBC_DIR" ]]; then
    [[ -d "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR='$SOLIDITY_IBC_DIR' not found"
    log "Using existing SOLIDITY_IBC_DIR: $SOLIDITY_IBC_DIR"
    return 0
  fi

  local dest_dir="$IBC_DIR/solidity-ibc-eureka-${SOLIDITY_IBC_TAG}"
  if [[ -d "$dest_dir" ]]; then
    log "solidity-ibc-eureka ${SOLIDITY_IBC_TAG} already fetched — reusing"
    SOLIDITY_IBC_DIR="$dest_dir"
    return 0
  fi

  # Short-form archive URL accepts tag, branch, or commit SHA — so SOLIDITY_IBC_TAG
  # can be "main", "solidity-v2.0.1", or a full 40-char SHA. Extracted dir name
  # is always <repo>-<ref> (e.g. "solidity-ibc-eureka-main").
  local url="https://github.com/cosmos/solidity-ibc-eureka/archive/${SOLIDITY_IBC_TAG}.tar.gz"
  local tarball="$IBC_DIR/${SOLIDITY_IBC_TAG}.tar.gz"
  log "Fetching $url..."
  mkdir -p "$IBC_DIR"
  curl -fsSL "$url" -o "$tarball" || die "Failed to download $url"
  tar -xzf "$tarball" -C "$IBC_DIR"
  rm -f "$tarball"
  [[ -d "$dest_dir" ]] || die "Extraction failed: $dest_dir not found"
  SOLIDITY_IBC_DIR="$dest_dir"
  log "solidity-ibc-eureka source ready at $SOLIDITY_IBC_DIR"
}

fetch_ethereum_lc_wasm() {
  if [[ -n "$WASM_CHECKSUM" ]]; then
    log "WASM_CHECKSUM already provided — skipping wasm fetch"
    return 0
  fi
  if [[ -n "$ETHEREUM_LC_WASM_PATH" ]]; then
    [[ -f "$ETHEREUM_LC_WASM_PATH" ]] || die "ETHEREUM_LC_WASM_PATH='$ETHEREUM_LC_WASM_PATH' not found"
    log "Using existing ETHEREUM_LC_WASM_PATH: $ETHEREUM_LC_WASM_PATH"
    return 0
  fi

  local dest="$IBC_DIR/cw_ics08_wasm_eth.wasm"
  if [[ -f "$dest" ]]; then
    log "cw_ics08_wasm_eth.wasm already extracted — reusing"
    ETHEREUM_LC_WASM_PATH="$dest"
    return 0
  fi

  [[ -n "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR not set — run fetch_solidity_ibc first"
  local gz="$SOLIDITY_IBC_DIR/e2e/interchaintestv8/wasm/cw_ics08_wasm_eth.wasm.gz"
  [[ -f "$gz" ]] || die "Wasm not found: $gz"
  log "Extracting cw_ics08_wasm_eth.wasm from source tarball..."
  gunzip -c "$gz" > "$dest"
  ETHEREUM_LC_WASM_PATH="$dest"
  log "cw_ics08_wasm_eth.wasm ready at $ETHEREUM_LC_WASM_PATH"
}

# Extract a contract address from the forge broadcast artefact.
_forge_broadcast_addr() {
  local script_name="$1" query="$2"
  local run_json="$SOLIDITY_IBC_DIR/broadcast/${script_name}/$ETH_CHAIN_ID/run-latest.json"
  [[ -f "$run_json" ]] || die "Forge broadcast not found: $run_json"
  jq -r "$query" "$run_json" 2>/dev/null
}

# Preferred: look up a contract address by label in E2ETestDeploy's returned
# JSON (`.returns."0".value` is a JSON-encoded string mapping labels like
# "ics26Router", "ics20Transfer", "ics27Gmp", "ift", "erc20" to addresses).
# Robust against reordering or new proxies being added.
#
# Forge double-escapes the returned string: after jq reads the outer file it
# still contains literal `\"` sequences inside. We strip backslashes with
# gsub before fromjson; addresses are all-hex, so no legitimate backslash
# data is lost. Verified empirically against a main-branch deploy where
# `.value | fromjson` alone returns "Invalid numeric literal at column 3".
_forge_return_addr() {
  local script_name="$1" label="$2"
  local run_json="$SOLIDITY_IBC_DIR/broadcast/${script_name}/$ETH_CHAIN_ID/run-latest.json"
  [[ -f "$run_json" ]] || die "Forge broadcast not found: $run_json"
  jq -r ".returns.\"0\".value | gsub(\"\\\\\\\\\"; \"\") | fromjson | .${label} // empty" \
    "$run_json" 2>/dev/null
}

deploy_ibc_contracts() {
  # Skip the ~60s forge deploy if ICS26Router + ICS20Transfer addresses are
  # already known AND the router actually has bytecode at that address on the
  # live chain. The bytecode check catches the case where state.env survived
  # but Besu's volume was wiped (addresses point to empty accounts).
  # AttestationLightClient is NOT gated on here: E2ETestDeploy doesn't produce
  # it (it's deployed later in create_evm_ibc_client via cast --create).
  if [[ -n "$ICS26_ROUTER_ADDR" && -n "$ICS20_TRANSFER_ADDR" ]]; then
    local router_code
    router_code=$(cast_in_net code "$ICS26_ROUTER_ADDR" \
      --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || router_code=""
    if [[ "$router_code" != "" && "$router_code" != "0x" ]]; then
      log "IBC contracts already deployed — skipping forge script"
      log "  ICS26Router        : $ICS26_ROUTER_ADDR"
      log "  ICS20Transfer      : $ICS20_TRANSFER_ADDR"
      log "  ICS27GMP           : ${ICS27_GMP_ADDR:-<not set>}"
      return 0
    fi
    log "Recorded ICS26Router at $ICS26_ROUTER_ADDR has no bytecode on-chain — redeploying"
  fi

  [[ -n "$SOLIDITY_IBC_DIR" ]] || die "Set SOLIDITY_IBC_DIR or pre-set contract addresses"
  [[ -d "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR='$SOLIDITY_IBC_DIR' not found"

  log "Deploying solidity-ibc-eureka contracts on Besu (chain-id $ETH_CHAIN_ID)..."

  # Linux bind-mount permission fix (no-op on macOS Docker Desktop):
  # foundry + bun images run as UID 1000 by default; a GitHub runner's
  # checkout is owned by a different UID (1001), so the non-root container
  # user can't MKDIR `out/` / `cache/` / `broadcast/` / `node_modules/` at
  # the root of the bind mount and forge aborts with
  # `"/contracts/out": Permission denied (os error 13)`.
  #
  # Pre-create those subdirs on the host with world-write (0777) so forge /
  # bun write INTO them instead of trying to create them — narrower than a
  # recursive chmod on the whole source tree.
  mkdir -p "$SOLIDITY_IBC_DIR"/{out,cache,broadcast,node_modules}
  chmod 0777 "$SOLIDITY_IBC_DIR"/{out,cache,broadcast,node_modules} 2>/dev/null || true

  if [[ ! -d "$SOLIDITY_IBC_DIR/node_modules" ]] || [[ -z "$(ls -A "$SOLIDITY_IBC_DIR/node_modules" 2>/dev/null)" ]]; then
    log "Installing contract dependencies (bun install)..."
    docker run --rm \
      -v "$SOLIDITY_IBC_DIR":/contracts -w /contracts \
      "$BUN_IMAGE" bun install --frozen-lockfile
  fi

  docker run --rm --entrypoint "" \
    --network "${COMPOSE_PROJECT}_ibc-net" \
    -v "$SOLIDITY_IBC_DIR":/contracts -w /contracts \
    -e E2E_FAUCET_ADDRESS="$ETH_VALIDATOR_ADDR" \
    -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    "$FOUNDRY_IMAGE" \
    forge script "$DEPLOY_SCRIPT" \
      --rpc-url "http://besu:8545" \
      --private-key "$ETH_VALIDATOR_PRIVKEY" \
      --broadcast --chain-id "$ETH_CHAIN_ID" 2>&1 | grep -v "^$"

  local s; s=$(basename "$DEPLOY_SCRIPT")
  ICS26_ROUTER_ADDR=$(_forge_return_addr "$s" ics26Router)
  ICS20_TRANSFER_ADDR=$(_forge_return_addr "$s" ics20Transfer)
  ICS27_GMP_ADDR=$(_forge_return_addr "$s" ics27Gmp)

  [[ -n "$ICS26_ROUTER_ADDR"  ]] || die "ics26Router not in E2ETestDeploy returns — check forge broadcast"
  [[ -n "$ICS20_TRANSFER_ADDR" ]] || die "ics20Transfer not in E2ETestDeploy returns"

  log "Contracts deployed:"
  log "  ICS26Router (proxy)   : $ICS26_ROUTER_ADDR"
  log "  ICS20Transfer (proxy) : $ICS20_TRANSFER_ADDR"
  log "  ICS27GMP (proxy)      : ${ICS27_GMP_ADDR:-<not present — using old tag without ICS27?>}"

  # Persist for `./setup.sh demo …` re-runs (they source state.env and need
  # these to talk to the EVM router). Each phase appends its own values so
  # state.env is a pure runtime accumulator — no template render races.
  mkdir -p "$IBC_DIR"
  {
    echo "ICS26_ROUTER_ADDR=$ICS26_ROUTER_ADDR"
    echo "ICS20_TRANSFER_ADDR=$ICS20_TRANSFER_ADDR"
    [[ -n "${ICS27_GMP_ADDR:-}" ]] && echo "ICS27_GMP_ADDR=$ICS27_GMP_ADDR"
  } >> "$IBC_STATE_FILE"
}

deploy_ift_contracts() {
  if [[ -n "$IFT_CONTRACT_ADDR" ]]; then
    log "IFT contract already provided: $IFT_CONTRACT_ADDR"
    return 0
  fi
  [[ -n "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR not set"
  # Prefer the dedicated TestIFT proxy (key "ift") — that's the token
  # ICS27GMP mints into on IFT packet delivery. Fall back to the plain
  # TestERC20 ("erc20") for compatibility with older tags that don't ship
  # a TestIFT contract.
  IFT_CONTRACT_ADDR=$(_forge_return_addr "$(basename "$DEPLOY_SCRIPT")" ift)
  if [[ -z "$IFT_CONTRACT_ADDR" ]]; then
    IFT_CONTRACT_ADDR=$(_forge_return_addr "$(basename "$DEPLOY_SCRIPT")" erc20)
    [[ -n "$IFT_CONTRACT_ADDR" ]] \
      && log "  (using legacy 'erc20' label — this tag lacks TestIFT)"
  fi
  [[ -n "$IFT_CONTRACT_ADDR" ]] || \
    die "Neither 'ift' nor 'erc20' label in E2ETestDeploy returns"
  log "IFT token resolved: $IFT_CONTRACT_ADDR"
  echo "IFT_CONTRACT_ADDR=$IFT_CONTRACT_ADDR" >> "$IBC_STATE_FILE"
}

store_ethereum_lc() {
  if [[ -n "$WASM_CHECKSUM" ]]; then
    log "Ethereum LC wasm checksum: $WASM_CHECKSUM"
    return 0
  fi
  [[ -n "$ETHEREUM_LC_WASM_PATH" && -f "$ETHEREUM_LC_WASM_PATH" ]] || \
    die "ETHEREUM_LC_WASM_PATH must point to an existing file"
  WASM_CHECKSUM=$(openssl dgst -sha256 "$ETHEREUM_LC_WASM_PATH" | awk '{print $NF}')
  log "Ethereum LC wasm checksum: $WASM_CHECKSUM"
  echo "WASM_CHECKSUM=$WASM_CHECKSUM" >> "$IBC_STATE_FILE"
}

# Generate the attestor's Web3 v3 JSON keystore (idempotent).
_ensure_attestor_keystore() {
  local keystore_dir="$IBC_DIR/local/.ibc-attestor"
  [[ -f "$keystore_dir/ibc-attestor-keystore" ]] && return 0
  log "Generating attestor keystore..."
  mkdir -p "$keystore_dir"
  docker run --rm --user root \
    -v "$IBC_DIR/local:/home/nonroot" \
    -e HOME=/home/nonroot "$ATTESTOR_IMAGE" key generate
  log "Attestor keystore generated"
}

create_ibc_clients() {
  if [[ -n "${COSMOS_WASM_CLIENT_ID:-}" ]]; then
    log "IBC attestation client already known: $COSMOS_WASM_CLIENT_ID"
    return 0
  fi

  log "Creating IBC attestation light client on Cosmos..."
  mkdir -p "$IBC_DIR/local"
  generate_attestor_config
  _ensure_attestor_keystore

  # Attestor Ethereum address — `key show` prints lowercase hex with no 0x / newline.
  local attestor_eth_addr
  attestor_eth_addr="0x$(docker run --rm --user root \
    -v "$IBC_DIR/local:/home/nonroot" \
    -e HOME=/home/nonroot "$ATTESTOR_IMAGE" \
    key show 2>/dev/null | tr -d '[:space:]')"
  [[ "$attestor_eth_addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || \
    die "Failed to get valid attestor address (got: $attestor_eth_addr)"
  log "  Attestor address: $attestor_eth_addr"

  # Beacon slot: finalized first, head fallback, floor of 1 (latest_height > 0).
  local beacon_slot
  beacon_slot=$(curl -sf "http://localhost:5051/eth/v1/beacon/headers/finalized" 2>/dev/null \
    | jq -r '.data.header.message.slot // "0"' 2>/dev/null || echo "0")
  [[ "$beacon_slot" =~ ^[0-9]+$ ]] || beacon_slot=0
  if [[ "$beacon_slot" -eq 0 ]]; then
    beacon_slot=$(curl -sf "http://localhost:5051/eth/v1/beacon/headers/head" 2>/dev/null \
      | jq -r '.data.header.message.slot // "0"' 2>/dev/null || echo "0")
    [[ "$beacon_slot" =~ ^[0-9]+$ ]] || beacon_slot=0
  fi
  [[ "$beacon_slot" -gt 0 ]] || beacon_slot=1

  local genesis_time
  genesis_time=$(curl -sf "http://localhost:5051/eth/v1/beacon/genesis" 2>/dev/null \
    | jq -r '.data.genesis_time // "0"' 2>/dev/null || echo "0")
  [[ "$genesis_time" =~ ^[0-9]+$ && "$genesis_time" -gt 0 ]] || genesis_time=$(date +%s)

  local seconds_per_slot
  seconds_per_slot=$(curl -sf "http://localhost:5051/eth/v1/config/spec" 2>/dev/null \
    | jq -r '.data.SECONDS_PER_SLOT // "12"' 2>/dev/null || echo "12")
  [[ "$seconds_per_slot" =~ ^[0-9]+$ && "$seconds_per_slot" -gt 0 ]] || seconds_per_slot=12

  local beacon_ts=$(( genesis_time + beacon_slot * seconds_per_slot ))
  local beacon_ts_ns=$(( beacon_ts * 1000000000 ))
  log "  Beacon slot=$beacon_slot genesis_time=$genesis_time seconds_per_slot=$seconds_per_slot ts=$beacon_ts"

  # Render ClientState and ConsensusState into cosmos-data volume.
  local tmp_dir; tmp_dir=$(mktemp -d)
  ATTESTOR_ETH_ADDR="$attestor_eth_addr" BEACON_SLOT="$beacon_slot" \
    render_template "$IBC_DIR/client-state.json.tmpl" \
                    "$tmp_dir/ibc_client_state.json"
  BEACON_TS_NS="$beacon_ts_ns" \
    render_template "$IBC_DIR/consensus-state.json.tmpl" \
                    "$tmp_dir/ibc_consensus_state.json"
  log "  ClientState: $(cat "$tmp_dir/ibc_client_state.json")"
  log "  ConsensusState: $(cat "$tmp_dir/ibc_consensus_state.json")"
  vol_cp_to "$tmp_dir/ibc_client_state.json"    "$COSMOS_HOME/ibc_client_state.json"
  vol_cp_to "$tmp_dir/ibc_consensus_state.json" "$COSMOS_HOME/ibc_consensus_state.json"
  rm -rf "$tmp_dir"

  # Submit MsgCreateClient.
  local tx_output
  tx_output=$(run_in cosmos "$COSMOS_BINARY" tx ibc client create \
    "$COSMOS_HOME/ibc_client_state.json" \
    "$COSMOS_HOME/ibc_consensus_state.json" \
    --from relayer --keyring-backend test --home "$COSMOS_HOME" \
    --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
    --gas auto --gas-adjustment 1.4 --gas-prices "0.025uatom" \
    --yes --output json 2>&1) || tx_output=""

  # docker compose run prepends "Container … Creating/Created" lines. Pull
  # out the single JSON line before handing to jq so the parse is reliable.
  local tx_hash tx_json_line
  tx_json_line=$(echo "$tx_output" | grep -E '^\{' | tail -1 || echo "")
  tx_hash=$(echo "$tx_json_line" | jq -r '.txhash // empty' 2>/dev/null || echo "")
  if [[ -n "$tx_hash" ]]; then
    log "  MsgCreateClient submitted — txhash: $tx_hash"
  else
    warn "MsgCreateClient may have failed — output: $(echo "$tx_output" | head -3)"
  fi

  # Poll for the client ID — on a cold chain, tx commit + REST indexing can
  # take 10-20s (block time is 5s). Retry both the tx query and the client-list
  # fallback; exit early only if the tx committed with a non-zero code.
  local max=90 step=3 elapsed=0
  log "  Waiting for tx commit + client ID (up to ${max}s)..."
  while (( elapsed < max )); do
    if [[ -n "$tx_hash" ]]; then
      local tx_result
      tx_result=$(curl -sf "http://localhost:1317/cosmos/tx/v1beta1/txs/${tx_hash}" 2>/dev/null) || tx_result=""
      if [[ -n "$tx_result" ]]; then
        local tx_code
        tx_code=$(echo "$tx_result" | jq -r '.tx_response.code // 0' 2>/dev/null || echo "0")
        if [[ "$tx_code" != "0" ]]; then
          local raw_log
          raw_log=$(echo "$tx_result" | jq -r '.tx_response.raw_log // "?"' 2>/dev/null || echo "(parse error)")
          die "MsgCreateClient committed with non-zero code=$tx_code: $raw_log"
        fi
        COSMOS_WASM_CLIENT_ID=$(echo "$tx_result" | jq -r '
          (
            (.tx_response.logs[0].events[]? | select(.type=="create_client") | .attributes[]? | select(.key=="client_id") | .value),
            (.tx_response.events[]? | select(.type=="create_client") | .attributes[]? | select(.key=="client_id") | .value)
          ) | first' 2>/dev/null | head -1 || echo "")
        [[ -n "$COSMOS_WASM_CLIENT_ID" ]] && break
      fi
    fi

    COSMOS_WASM_CLIENT_ID=$(curl -sf "http://localhost:1317/ibc/core/client/v1/client_states" 2>/dev/null \
      | jq -r '.client_states[].client_id' 2>/dev/null \
      | grep "^attestations-" | tail -1 || echo "")
    [[ -n "$COSMOS_WASM_CLIENT_ID" ]] && break

    sleep "$step"; (( elapsed += step ))
    echo -n "."
  done

  [[ -n "${COSMOS_WASM_CLIENT_ID:-}" ]] || \
    die "Failed to create attestation IBC client after ${max}s — check: docker compose logs cosmos"

  log "Attestation IBC client created: $COSMOS_WASM_CLIENT_ID"
  echo "COSMOS_WASM_CLIENT_ID=$COSMOS_WASM_CLIENT_ID" >> "$IBC_STATE_FILE"
}

setup_relayer_key() {
  log "Resolving relayer wallet on Cosmos..."
  RELAYER_ADDR=$(docker compose run --rm --no-deps --entrypoint="" cosmos \
    "$COSMOS_BINARY" keys show relayer -a --keyring-backend test --home "$COSMOS_HOME")
  log "Relayer wallet: $RELAYER_ADDR"
  echo "RELAYER_ADDR=$RELAYER_ADDR" >> "$IBC_STATE_FILE"

  # Relayer signs Cosmos txs from /relayer/cosmos-keys; copy the keyring across.
  log "Populating relayer cosmos keyring (relayer-data volume)..."
  docker run --rm \
    -v "${COMPOSE_PROJECT}_cosmos-data:/cosmos-data:ro" \
    -v "${COMPOSE_PROJECT}_relayer-data:/relayer" \
    busybox \
    sh -c "mkdir -p /relayer/cosmos-keys && cp -r /cosmos-data/keyring-test /relayer/cosmos-keys/"
  log "Relayer cosmos keyring ready"
}

# counterparty_chains fragment for relayer-config.yml.tmpl — mapping or empty dict.
_cp_block() {
  local client_id="$1" chain_id="$2"
  if [[ -n "$client_id" ]]; then
    printf 'counterparty_chains:\n        %s: "%s"' "$client_id" "$chain_id"
  else
    printf 'counterparty_chains: {}'
  fi
}

generate_relayer_config() {
  log "Generating relayer config → ibc/local/config.yml"
  mkdir -p "$IBC_DIR/local"

  # signing.keys_path JSON: {chain_id: {private_key: hex}}
  local cosmos_privkey
  cosmos_privkey=$(run_in cosmos "$COSMOS_BINARY" keys export relayer \
    --keyring-backend test --home "$COSMOS_HOME" \
    --unarmored-hex --unsafe 2>/dev/null) || cosmos_privkey=""

  ETH_PRIVKEY_BARE="${ETH_VALIDATOR_PRIVKEY#0x}" COSMOS_PRIVKEY="$cosmos_privkey" \
    render_template "$IBC_DIR/relayer-keys.json.tmpl" "$IBC_DIR/local/keys.json"
  log "Signing keys file written → $IBC_DIR/local/keys.json"

  COSMOS_CP_BLOCK=$(_cp_block "${COSMOS_WASM_CLIENT_ID:-}" "$ETH_CHAIN_ID")
  BESU_CP_BLOCK=$(_cp_block "${EVM_COSMOS_CLIENT_ID:-}" "$COSMOS_CHAIN_ID")
  export COSMOS_CP_BLOCK BESU_CP_BLOCK
  render_template "$IBC_DIR/relayer-config.yml.tmpl" "$IBC_DIR/local/config.yml"

  log "Relayer config written"
}

generate_attestor_config() {
  log "Generating attestor config → ibc/local/attestor-config.toml"
  mkdir -p "$IBC_DIR/local"
  render_template "$IBC_DIR/attestor-config.toml.tmpl" \
                  "$IBC_DIR/local/attestor-config.toml"
}

generate_attestor_cosmos_config() {
  log "Generating cosmos-attestor config → ibc/local/attestor-cosmos-config.toml"
  mkdir -p "$IBC_DIR/local"
  render_template "$IBC_DIR/attestor-cosmos-config.toml.tmpl" \
                  "$IBC_DIR/local/attestor-cosmos-config.toml"
}

generate_proof_api_config() {
  log "Generating proof-api config → ibc/local/relayer.json"
  mkdir -p "$IBC_DIR/local"
  render_template "$IBC_DIR/proof-api.json.tmpl" \
                  "$IBC_DIR/local/relayer.json"
  log "Proof-api config written (attestation mode, both directions)"
}

run_db_migrations() {
  local relayer_tag="${OPERATOR_IMAGE##*:}"
  local src_dir="$IBC_DIR/ibc-relayer-${relayer_tag}"
  if [[ ! -d "$src_dir" ]]; then
    local url="https://github.com/cosmos/ibc-relayer/archive/refs/tags/${relayer_tag}.tar.gz"
    local tarball="$IBC_DIR/${relayer_tag}.tar.gz"
    log "Fetching cosmos/ibc-relayer@${relayer_tag} source..."
    curl -fsSL "$url" -o "$tarball" || die "Failed to download $url"
    tar -xzf "$tarball" -C "$IBC_DIR"; rm -f "$tarball"
    local extracted
    extracted=$(find "$IBC_DIR" -maxdepth 1 -type d -name "ibc-relayer-*" | head -1)
    [[ -d "$extracted" ]] || die "Extraction failed"
    mv "$extracted" "$src_dir"
  fi
  log "Running DB migrations..."
  docker run --rm --network "${COMPOSE_PROJECT}_ibc-net" \
    -v "$src_dir/db/migrations":/migrations \
    migrate/migrate -path /migrations \
      -database "postgres://relayer:relayer@postgres:5432/relayer?sslmode=disable" up
  log "DB migrations complete"
}

start_relayer()  { log "Starting IBC relayer ($OPERATOR_IMAGE)..."; docker compose up -d relayer; }
start_attestor() {
  log "Starting IBC attestor — EVM watcher ($ATTESTOR_IMAGE)..."
  generate_attestor_config
  _ensure_attestor_keystore
  docker compose up -d attestor
}
start_attestor_cosmos() {
  log "Starting IBC attestor — Cosmos watcher ($ATTESTOR_IMAGE)..."
  generate_attestor_cosmos_config
  _ensure_attestor_keystore
  docker compose up -d attestor-cosmos
}
start_proof_api() {
  log "Starting proof API ($PROOF_API_IMAGE, attestation mode)..."
  generate_proof_api_config
  docker compose up -d proof-api
}

create_evm_ibc_client() {
  if [[ -n "${EVM_COSMOS_CLIENT_ID:-}" ]]; then
    log "EVM Cosmos client already known: $EVM_COSMOS_CLIENT_ID"
    return 0
  fi

  log "Creating EVM-side Cosmos light client (AttestationLightClient)..."

  # Attestor address: same key signs for both directions (single keystore is
  # mounted into attestor + attestor-cosmos). Registering this address with
  # the EVM AttestationLightClient is what authorises the cosmos-watching
  # attestor to advance the client; the EVM-watching attestor's signatures
  # advance the 08-wasm LC on Cosmos via a parallel registration.
  local attestor_eth_addr
  attestor_eth_addr="0x$(docker run --rm --user root \
    -v "$IBC_DIR/local:/home/nonroot" \
    -e HOME=/home/nonroot "$ATTESTOR_IMAGE" \
    key show 2>/dev/null | tr -d '[:space:]')"
  [[ "$attestor_eth_addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || \
    die "Failed to get valid attestor address (got: $attestor_eth_addr)"
  log "  Attestor address: $attestor_eth_addr"

  # Initial trusted height/timestamp = current Cosmos chain head. Future
  # cosmos states are accepted by AttestationLightClient.updateClient as
  # long as a quorum of attestors signs StateAttestation{height,timestamp}.
  local cosmos_status init_height init_time_str init_ts
  cosmos_status=$(curl -sf http://localhost:26657/status 2>/dev/null) \
    || die "Cosmos RPC not reachable on :26657"
  init_height=$(echo "$cosmos_status" | jq -r '.result.sync_info.latest_block_height // empty' 2>/dev/null || echo "")
  init_time_str=$(echo "$cosmos_status" | jq -r '.result.sync_info.latest_block_time // empty' 2>/dev/null || echo "")
  [[ "$init_height" =~ ^[0-9]+$ && "$init_height" -gt 0 ]] || die "Bad cosmos height: $init_height"
  [[ -n "$init_time_str" ]] || die "Empty cosmos block time"
  # CometBFT timestamps are RFC3339 with nanosecond precision; strip the
  # fractional + trailing 'Z' before handing to date(1). Try GNU date first,
  # fall back to BSD date (macOS).
  local clean_ts="${init_time_str%.*}"
  clean_ts="${clean_ts%Z}"
  init_ts=$(date -u -d "$init_time_str" +%s 2>/dev/null \
            || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" +%s 2>/dev/null \
            || echo "")
  [[ "$init_ts" =~ ^[0-9]+$ && "$init_ts" -gt 0 ]] || die "Failed to parse cosmos block time: $init_time_str"
  log "  Initial trusted state: height=$init_height ts=$init_ts ($init_time_str)"

  # Predict client ID from current ICS26Router seq.
  local next_seq
  next_seq=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getNextClientSeq()(uint256)" \
    --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || next_seq=0
  [[ "$next_seq" =~ ^[0-9]+$ ]] || next_seq=0
  local predicted="client-${next_seq}"
  log "  Next client seq: $next_seq → predicted: $predicted"

  # Encode constructor args:
  #   constructor(address[] attestors, uint8 quorum, uint64 initHeight,
  #               uint64 initTimestamp, address roleManager)
  # roleManager=address(0) makes the LC permissionless: the onlyProofSubmitter
  # modifier short-circuits when PROOF_SUBMITTER_ROLE is granted to address(0)
  # (see contracts/light-clients/attestation/AttestationLightClient.sol:270).
  # Fine for this devnet; production should pass an admin EOA/multisig.
  local lc_artifact="$SOLIDITY_IBC_DIR/out/AttestationLightClient.sol/AttestationLightClient.json"
  [[ -f "$lc_artifact" ]] || die "AttestationLightClient artifact missing: $lc_artifact"
  local bytecode
  bytecode=$(jq -r '.bytecode.object' "$lc_artifact")
  [[ -n "$bytecode" && "$bytecode" != "null" ]] || die "Empty bytecode in $lc_artifact"

  local ctor_args
  ctor_args=$(cast_in_net abi-encode "constructor(address[],uint8,uint64,uint64,address)" \
    "[$attestor_eth_addr]" 1 "$init_height" "$init_ts" \
    "0x0000000000000000000000000000000000000000" 2>/dev/null \
    | sed 's/^0x//') || ctor_args=""
  [[ -n "$ctor_args" ]] || die "Failed to abi-encode AttestationLightClient constructor"

  log "  Deploying AttestationLightClient..."
  local deploy_receipt lc_addr
  deploy_receipt=$(cast_in_net send \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" \
    --json --create "${bytecode}${ctor_args}" 2>/dev/null) || deploy_receipt=""
  lc_addr=$(echo "$deploy_receipt" | jq -r '.contractAddress // empty' 2>/dev/null || echo "")
  [[ -n "$lc_addr" && "$lc_addr" != "null" ]] || \
    die "AttestationLightClient deployment failed — check Besu logs"
  log "  AttestationLightClient deployed: $lc_addr"

  # Register with ICS26Router.addClient. merklePrefix MUST have exactly 1
  # element for AttestationLightClient: ICS24Host.prefixedPath() keeps
  # merklePrefix.length unchanged and concatenates the packet commitment
  # path into the last element — and the LC's verifyMembership requires
  # path.length == 1, otherwise it reverts with InvalidPathLength(1, N).
  # The old SP1ICS07Tendermint setup used `[bytes("ibc"), bytes("")]`
  # (length 2) because Tendermint chains nest under an "ibc" subtree;
  # attestation LCs verify the commitment directly so a single empty
  # prefix is correct.
  local add_receipt add_status
  add_receipt=$(cast_in_net send "$ICS26_ROUTER_ADDR" \
    "addClient((string,bytes[]),address)" \
    "($COSMOS_WASM_CLIENT_ID,[0x])" "$lc_addr" \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" --json 2>/dev/null) || add_receipt=""
  add_status=$(echo "$add_receipt" | jq -r '.status // empty' 2>/dev/null || echo "")
  [[ "$add_status" == "0x1" ]] || die "ICS26Router.addClient failed (status=$add_status)"

  local verify_addr
  verify_addr=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getClient(string)(address)" "$predicted" \
    --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || verify_addr=""
  EVM_COSMOS_CLIENT_ID="$predicted"
  EVM_ATTESTATION_LC_ADDR="$lc_addr"
  if [[ -n "$verify_addr" && "$verify_addr" != "0x0000000000000000000000000000000000000000" ]]; then
    log "EVM Cosmos client registered: $EVM_COSMOS_CLIENT_ID → $verify_addr"
  else
    warn "Could not verify $predicted — using predicted ID"
  fi

  {
    echo "EVM_COSMOS_CLIENT_ID=$EVM_COSMOS_CLIENT_ID"
    echo "EVM_ATTESTATION_LC_ADDR=$lc_addr"
  } >> "$IBC_STATE_FILE"
}

wait_for_evm_client() {
  [[ -n "${EVM_COSMOS_CLIENT_ID:-}" ]] && { log "EVM Cosmos client: $EVM_COSMOS_CLIENT_ID"; return 0; }

  local max=300 step=5 elapsed=0
  log "Waiting for Cosmos light client on EVM (ICS26Router)..."
  while true; do
    local next_seq
    next_seq=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getNextClientSeq()(uint256)" \
      --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || next_seq=0
    if [[ "$next_seq" =~ ^[0-9]+$ ]] && (( next_seq > 0 )); then
      EVM_COSMOS_CLIENT_ID="client-0"
      log "EVM Cosmos client ready: $EVM_COSMOS_CLIENT_ID"
      echo "EVM_COSMOS_CLIENT_ID=$EVM_COSMOS_CLIENT_ID" >> "$IBC_STATE_FILE"
      return 0
    fi
    (( elapsed += step ))
    if (( elapsed >= max )); then
      warn "EVM Cosmos client not found within ${max}s"
      warn "Set EVM_COSMOS_CLIENT_ID manually and re-run: ./setup.sh ibc"
      return 0
    fi
    sleep "$step"; echo -n "."
  done
}

wait_for_ibc_ready() {
  [[ -n "${COSMOS_WASM_CLIENT_ID:-}" ]] && { log "IBC attestation client: $COSMOS_WASM_CLIENT_ID"; return 0; }

  local max=300 step=5 elapsed=0
  log "Waiting for attestation IBC client on Cosmos..."
  while true; do
    local cid
    cid=$(curl -sf "http://localhost:1317/ibc/core/client/v1/client_states" 2>/dev/null \
      | jq -r '.client_states[].client_id' 2>/dev/null \
      | grep "^attestations-" | head -1 || true)
    if [[ -n "$cid" ]]; then
      COSMOS_WASM_CLIENT_ID="$cid"
      log "IBC attestation client ready: $COSMOS_WASM_CLIENT_ID"
      echo "COSMOS_WASM_CLIENT_ID=$COSMOS_WASM_CLIENT_ID" >> "$IBC_STATE_FILE"
      return 0
    fi
    (( elapsed += step ))
    (( elapsed >= max )) && die "Attestation IBC client did not appear within ${max}s — check relayer logs"
    sleep "$step"; echo -n "."
  done
}

register_counterparty() {
  log "Registering IBC counterparty on Cosmos..."
  [[ -n "$COSMOS_WASM_CLIENT_ID" ]] || die "COSMOS_WASM_CLIENT_ID not set"
  if [[ -z "$EVM_COSMOS_CLIENT_ID" ]]; then
    warn "EVM_COSMOS_CLIENT_ID unknown — skipping add-counterparty"
    return 0
  fi

  local existing
  existing=$(curl -sf "http://localhost:1317/ibc/core/client/v2/counterparty_info/${COSMOS_WASM_CLIENT_ID}" 2>/dev/null \
    | jq -r '.counterparty_info.client_id // empty' 2>/dev/null || true)
  if [[ "$existing" == "$EVM_COSMOS_CLIENT_ID" ]]; then
    log "  Counterparty already registered: $COSMOS_WASM_CLIENT_ID ↔ $EVM_COSMOS_CLIENT_ID"
    return 0
  fi

  log "  add-counterparty: $COSMOS_WASM_CLIENT_ID ↔ $EVM_COSMOS_CLIENT_ID"
  run_in cosmos "$COSMOS_BINARY" tx ibc client add-counterparty \
    "$COSMOS_WASM_CLIENT_ID" "$EVM_COSMOS_CLIENT_ID" "" \
    --from relayer --keyring-backend test --home "$COSMOS_HOME" \
    --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
    --gas auto --gas-adjustment 1.4 --gas-prices 0.025uatom \
    --yes --output json 2>/dev/null || \
    warn "add-counterparty failed — check: docker compose logs cosmos"

  log "Counterparty registration complete"
}

register_ift_bridges() {
  if [[ -z "$IFT_CONTRACT_ADDR" ]]; then
    warn "IFT_CONTRACT_ADDR not set — skipping IFT bridge registration"
    return 0
  fi

  if [[ -z "$COSMOS_IFT_DENOM" ]]; then
    # wfchain's tokenfactory + IFT modules use the bare subdenom everywhere:
    # tokenfactory stores denoms by subdenom alone, IFT register-bridge
    # expects the subdenom, mint amounts are "Nuift", and bank balances
    # show up as "uift" (not "factory/<creator>/uift" as in osmosis-style
    # tokenfactory). Verified empirically against the running chain.
    COSMOS_IFT_DENOM="uift"
  fi
  log "  Cosmos IFT denom: $COSMOS_IFT_DENOM"

  # Idempotency guard: if the bridge is already registered on-chain, skip the
  # create-denom + register-bridge txs (they would fail with "denom already
  # exists" / "bridge already registered" and die under cosmos_tx_and_wait,
  # aborting the whole setup on re-runs).
  local existing_bridge
  existing_bridge=$(docker compose exec -T cosmos wfchaind query ift bridge \
    "$COSMOS_IFT_DENOM" "$COSMOS_WASM_CLIENT_ID" \
    --node tcp://localhost:26657 -o json 2>/dev/null \
    | jq -r '.bridge.counterparty_ift_address // empty' 2>/dev/null || echo "")
  # CRITICAL: register the bridge with the EIP-55 CHECKSUMMED form of the EVM
  # IFT contract address. wfchain's x/ift MsgIFTMint handler does a plain
  # string compare:   bridge.CounterpartyIftAddress == accountID.Sender
  # and the GMP packet's sender field is recorded by ICS27GMP in checksummed
  # form (e.g. 0x9A676e78… not 0x9a676e78…). Registering with the lowercase
  # form makes that check fail at recv time and the relayer reports
  # COMPLETE_WITH_WRITE_ACK_ERROR — packet acked, but no mint.
  local ift_addr_checksum
  ift_addr_checksum=$(cast_in_net to-check-sum-address "$IFT_CONTRACT_ADDR" 2>/dev/null \
    | tr -d '[:space:]') || ift_addr_checksum=""
  [[ -n "$ift_addr_checksum" ]] || ift_addr_checksum="$IFT_CONTRACT_ADDR"

  # Self-heal: if a previous setup registered with the wrong casing (e.g. before
  # this fix landed), remove the stale bridge and re-register with the correct
  # checksum form. Avoids forcing the user into manual `tx ift remove-bridge`
  # recovery dances when re-running after upgrading the script.
  if [[ -n "$existing_bridge" && "$existing_bridge" != "$ift_addr_checksum" ]]; then
    log "Cosmos IFT bridge registered with stale address:"
    log "  on chain: $existing_bridge"
    log "  expected: $ift_addr_checksum  (EIP-55 checksum)"
    log "  → removing and re-registering with the correct casing..."
    cosmos_tx_and_wait tx ift remove-bridge \
      "$COSMOS_IFT_DENOM" "$COSMOS_WASM_CLIENT_ID" \
      --from validator >/dev/null
    existing_bridge=""  # fall through to the registration block below
  fi

  if [[ -n "$existing_bridge" ]]; then
    log "Cosmos IFT bridge already registered (→ $existing_bridge) — skipping create-denom + register-bridge"
  else
    # Idempotency on create-denom: only create if the validator hasn't already
    # registered this subdenom under tokenfactory (re-running after a partial
    # setup must not re-broadcast `create-denom` — it would die under
    # cosmos_tx_and_wait with "denom already exists").
    local subdenom="${COSMOS_IFT_DENOM##*/}"
    local validator_addr
    validator_addr=$(run_in cosmos "$COSMOS_BINARY" keys show validator -a \
      --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')
    if docker compose exec -T cosmos wfchaind query tokenfactory denoms-by-creator \
         "$validator_addr" --node tcp://localhost:26657 -o json 2>/dev/null \
         | jq -e --arg s "$subdenom" '.denoms[]? | select(. == $s)' >/dev/null 2>&1; then
      log "  Denom '$subdenom' already created by validator — skipping create-denom"
    else
      log "  Creating tokenfactory denom '$subdenom'..."
      cosmos_tx_and_wait tx tokenfactory create-denom "$subdenom" \
        --from validator >/dev/null
      log "  Denom created."
    fi

    # tx ift register-bridge [denom] [client_id] [counterparty_ift_address] [ift_send_call_constructor]
    # constructor = "evm" for an EVM counterparty (vs. "cosmostx").
    log "  Registering Cosmos IFT bridge (client=$COSMOS_WASM_CLIENT_ID → evm=$ift_addr_checksum)..."
    cosmos_tx_and_wait tx ift register-bridge \
      "$COSMOS_IFT_DENOM" "$COSMOS_WASM_CLIENT_ID" "$ift_addr_checksum" evm \
      --from validator >/dev/null
    log "Cosmos IFT bridge registered"
  fi

  # EVM-side registration is done in a separate phase (register_evm_ift_bridge)
  # because it needs the ICA address derived from ICS26Router + TestIFT proxy,
  # and then deploys the CosmosIFTSendCallConstructor parameterised with it.

  echo "COSMOS_IFT_DENOM=$COSMOS_IFT_DENOM" >> "$IBC_STATE_FILE"

  # Default the demo to transfer IFT instead of uatom. Persist so it survives
  # across invocations (`./setup.sh demo cosmos-evm` on a later run).
  local num="1000000"
  [[ "$DEMO_TRANSFER_AMOUNT" =~ ^([0-9]+) ]] && num="${BASH_REMATCH[1]}"
  DEMO_TRANSFER_AMOUNT="${num}${COSMOS_IFT_DENOM}"
  echo "DEMO_TRANSFER_AMOUNT=$DEMO_TRANSFER_AMOUNT" >> "$IBC_STATE_FILE"
  log "DEMO_TRANSFER_AMOUNT → $DEMO_TRANSFER_AMOUNT"
}

# Mint IFT tokens to the validator. Called lazily from demo_cosmos_to_evm_transfer
# when the sender's balance would be insufficient — not from setup_ibc.
mint_ift_tokens() {
  if [[ -z "${COSMOS_IFT_DENOM:-}" ]]; then
    warn "COSMOS_IFT_DENOM not set — skipping IFT mint"
    return 0
  fi

  # Mint via tokenfactory (IFT module has no mint; it wraps tokenfactory).
  # Signature: tx tokenfactory mint [address] [amount]
  local validator_addr mint_amount="${IFT_MINT_AMOUNT:-1000000000}"
  validator_addr=$(run_in cosmos "$COSMOS_BINARY" keys show validator -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')

  log "  Minting ${mint_amount}${COSMOS_IFT_DENOM} to ${validator_addr}..."
  cosmos_tx_and_wait tx tokenfactory mint \
    "$validator_addr" "${mint_amount}${COSMOS_IFT_DENOM}" \
    --from validator >/dev/null
  log "  Mint committed."
}

# Wire up the EVM side of the IFT bridge. Does three things, all shell-only:
#   1. Ask wfchaind for the ICA address the Cosmos GMP module will use to
#      sign MsgIFTMint when a packet arrives from the EVM TestIFT proxy.
#   2. Deploy CosmosIFTSendCallConstructor from compiled bytecode, wiring the
#      ICA + type URL + denom into it (E2ETestDeploy skipped this contract
#      because IFT_ICA_ADDRESS wasn't known at forge-deploy time).
#   3. Call TestIFT.registerIFTBridge(clientId, icaAddress, constructor) so
#      TestIFT.iftTransfer can wrap iftTransfer → ICS27GMP.sendCall with a
#      correctly-signed MsgIFTMint payload.
register_evm_ift_bridge() {
  [[ -n "$IFT_CONTRACT_ADDR" ]]      || { warn "IFT_CONTRACT_ADDR not set — skipping EVM IFT bridge"; return 0; }
  [[ -n "$EVM_COSMOS_CLIENT_ID" ]]   || { warn "EVM_COSMOS_CLIENT_ID not set — skipping EVM IFT bridge"; return 0; }
  [[ -n "$COSMOS_WASM_CLIENT_ID" ]]  || { warn "COSMOS_WASM_CLIENT_ID not set — skipping EVM IFT bridge"; return 0; }
  [[ -n "$COSMOS_IFT_DENOM" ]]       || { warn "COSMOS_IFT_DENOM not set — skipping EVM IFT bridge"; return 0; }

  # Compute the correct ICA up front (requires the EIP-55 checksummed EVM
  # address; see comment block below). Compare against state.env's stored
  # value to decide whether we can skip or need to redeploy.
  #
  # CRITICAL: the sender string for ICA derivation MUST be in EIP-55
  # checksummed form. ICS27GMP.sendCall records the EVM sender with mixed
  # case (e.g. 0x9A676e781A523b5d0C0e43731313A708CB607508), and Cosmos GMP
  # derives the ICA by hashing that exact string at packet-recv time.
  # Querying gmp get-address with lowercase produces a DIFFERENT ICA, the
  # signer check on MsgIFTMint fails, and the packet gets an error ack —
  # the relayer reports COMPLETE_WITH_WRITE_ACK_ERROR even though no
  # mint actually happened.
  local ift_addr_checksum
  ift_addr_checksum=$(cast_in_net to-check-sum-address "$IFT_CONTRACT_ADDR" 2>/dev/null \
    | tr -d '[:space:]') || ift_addr_checksum=""
  [[ -n "$ift_addr_checksum" ]] || ift_addr_checksum="$IFT_CONTRACT_ADDR"

  log "  Computing ICA for (client=$COSMOS_WASM_CLIENT_ID, sender=$ift_addr_checksum)..."
  local ica
  ica=$(docker compose exec -T cosmos wfchaind query gmp get-address \
    "$COSMOS_WASM_CLIENT_ID" "$ift_addr_checksum" "" -o json 2>/dev/null \
    | jq -r '.account_address // empty' 2>/dev/null) || ica=""
  [[ -n "$ica" ]] || { warn "Failed to compute ICA via 'query gmp get-address'"; return 0; }
  log "  ICA: $ica"

  # Idempotency / self-heal: skip everything below if state.env already has
  # an ICA matching what we just computed (the ICA is a deterministic
  # function of client + checksum-sender + salt, so a match means we're
  # using the correct CosmosIFTSendCallConstructor that was deployed in a
  # prior run). If state.env's ICA differs (e.g. it was written by an
  # earlier setup that queried with the wrong-cased sender), fall through
  # to redeploy the constructor with the correct ICA and re-register the
  # bridge on TestIFT — overwriting the stale registration.
  if [[ "${IFT_ICA_ADDRESS:-}" == "$ica" && -n "${IFT_CTOR_ADDR:-}" && -n "${COSMOS_IFT_MODULE_ADDR:-}" ]]; then
    log "EVM IFT bridge already registered with correct ICA — skipping"
    return 0
  fi
  if [[ -n "${IFT_ICA_ADDRESS:-}" && "$IFT_ICA_ADDRESS" != "$ica" ]]; then
    log "Stale EVM IFT bridge state detected:"
    log "  state.env: $IFT_ICA_ADDRESS"
    log "  expected:  $ica"
    log "  → redeploying CosmosIFTSendCallConstructor + re-registering bridge on TestIFT"
  fi

  # 1b. Cosmos IFT module account — the `.sender` in outgoing GMP packets
  #     FROM Cosmos (different from the ICA!). TestIFT.iftMint checks that
  #     bridge.counterpartyIFTAddress == packet.sender; failing that check
  #     is what caused the last run's silent `IFTUnauthorizedMint` revert,
  #     making the relayer report COMPLETE while EVM balance stayed 0.
  log "  Querying Cosmos IFT module account..."
  local cosmos_ift_module
  cosmos_ift_module=$(docker compose exec -T cosmos wfchaind query auth module-account ift \
    --node tcp://localhost:26657 -o json 2>/dev/null \
    | jq -r '.account.base_account.address // .account.value.address // empty' 2>/dev/null) || cosmos_ift_module=""
  [[ -n "$cosmos_ift_module" ]] || die "Failed to resolve Cosmos IFT module account via auth query"
  log "  Cosmos IFT module: $cosmos_ift_module"

  # 2. Deploy CosmosIFTSendCallConstructor(typeUrl, denom, icaAddress).
  #    Bytecode comes from the forge build output in $SOLIDITY_IBC_DIR/out/.
  local ctor_abi="$SOLIDITY_IBC_DIR/out/CosmosIFTSendCallConstructor.sol/CosmosIFTSendCallConstructor.json"
  [[ -f "$ctor_abi" ]] || die "CosmosIFTSendCallConstructor artefact missing: $ctor_abi"

  local bytecode
  bytecode=$(jq -r '.bytecode.object' "$ctor_abi")
  [[ -n "$bytecode" && "$bytecode" != "null" ]] || die "Empty bytecode in $ctor_abi"

  # MsgIFTMint type URL + tokenfactory denom match wfchain's x/ift + tokenfactory
  # wiring; keeping them together here so the constructor matches what
  # CosmosIFTSendCallConstructor expects on the other side.
  local type_url="/wfchain.ift.MsgIFTMint"

  log "  Encoding constructor args (typeUrl, denom, ica)..."
  local ctor_args
  ctor_args=$(cast_in_net abi-encode "constructor(string,string,string)" \
    "$type_url" "$COSMOS_IFT_DENOM" "$ica" 2>/dev/null \
    | sed 's/^0x//') || ctor_args=""
  [[ -n "$ctor_args" ]] || die "Failed to abi-encode CosmosIFTSendCallConstructor args"

  log "  Deploying CosmosIFTSendCallConstructor..."
  local deploy_receipt
  deploy_receipt=$(cast_in_net send \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" --json \
    --create "${bytecode}${ctor_args}" 2>/dev/null) || deploy_receipt=""
  local ctor_addr
  ctor_addr=$(echo "$deploy_receipt" | jq -r '.contractAddress // empty' 2>/dev/null || echo "")
  [[ -n "$ctor_addr" && "$ctor_addr" != "null" ]] || \
    die "CosmosIFTSendCallConstructor deployment failed — check Besu logs"
  log "  CosmosIFTSendCallConstructor: $ctor_addr"

  # 3. Register the bridge on TestIFT. counterpartyIFTAddress is the Cosmos
  #    IFT module account (the packet sender), NOT the ICA. IFTBase.iftMint
  #    enforces bridge.counterpartyIFTAddress == accountId.sender; registering
  #    the ICA here would pass the first two checks and then revert silently
  #    on the sender-match check, which manifests as "relay complete but
  #    EVM balance 0".
  log "  TestIFT.registerIFTBridge(client=$EVM_COSMOS_CLIENT_ID, module=$cosmos_ift_module, ctor=$ctor_addr)..."
  cast_in_net send "$IFT_CONTRACT_ADDR" \
    "registerIFTBridge(string,string,address)" \
    "$EVM_COSMOS_CLIENT_ID" "$cosmos_ift_module" "$ctor_addr" \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" 2>/dev/null \
    || die "TestIFT.registerIFTBridge failed — check authority / access control on TestIFT"

  IFT_ICA_ADDRESS="$ica"
  IFT_CTOR_ADDR="$ctor_addr"
  COSMOS_IFT_MODULE_ADDR="$cosmos_ift_module"
  {
    echo "IFT_ICA_ADDRESS=$ica"
    echo "IFT_CTOR_ADDR=$ctor_addr"
    echo "COSMOS_IFT_MODULE_ADDR=$cosmos_ift_module"
  } >> "$IBC_STATE_FILE"
  log "EVM IFT bridge registered"
}

finalize_relayer_config() {
  log "Finalising relayer config with counterparty client mappings..."
  generate_relayer_config
  log "Restarting relayer to pick up updated config..."
  docker compose restart relayer
  log "Relayer restarted"
}

reconcile_ibc_client_pair() {
  if [[ -z "${COSMOS_WASM_CLIENT_ID:-}" || -z "${EVM_COSMOS_CLIENT_ID:-}" ]]; then
    COSMOS_WASM_CLIENT_ID=""; EVM_COSMOS_CLIENT_ID=""
    return 0
  fi

  local cosmos_cp
  cosmos_cp=$(curl -sf "http://localhost:1317/ibc/core/client/v2/counterparty_info/${COSMOS_WASM_CLIENT_ID}" 2>/dev/null \
    | jq -r '.counterparty_info.client_id // empty' 2>/dev/null || echo "")

  # Decode ICS26Router.getCounterparty → CounterpartyInfo(string clientId, bytes[] merklePrefix).
  # `cast call` with the `(string,bytes[])` return signature gives us a parsed
  # multi-line output where the first line is the clientId string. Drop the
  # hand-rolled ABI pointer arithmetic — any layout change breaks it silently.
  local evm_cp
  evm_cp=$(cast_in_net call "$ICS26_ROUTER_ADDR" \
    "getCounterparty(string)((string,bytes[]))" "$EVM_COSMOS_CLIENT_ID" \
    --rpc-url "http://besu:8545" 2>/dev/null \
    | sed -n 's/^(//; s/,.*$//; s/"//g; 1p' \
    | tr -d '[:space:]') || evm_cp=""

  if [[ "$cosmos_cp" == "$EVM_COSMOS_CLIENT_ID" && "$evm_cp" == "$COSMOS_WASM_CLIENT_ID" ]]; then
    log "IBC client pair verified: $COSMOS_WASM_CLIENT_ID ↔ $EVM_COSMOS_CLIENT_ID"
    return 0
  fi

  warn "IBC client pair inconsistent — clearing stale IDs, will create fresh pair"
  warn "  Cosmos: $COSMOS_WASM_CLIENT_ID.counterparty = '${cosmos_cp:-<unknown>}' (want: $EVM_COSMOS_CLIENT_ID)"
  warn "  EVM:    $EVM_COSMOS_CLIENT_ID.counterparty = '${evm_cp:-<unknown>}' (want: $COSMOS_WASM_CLIENT_ID)"
  COSMOS_WASM_CLIENT_ID=""; EVM_COSMOS_CLIENT_ID=""
}

_wait_for_postgres() {
  log "Waiting for postgres to be ready..."
  local max=60 step=3 elapsed=0
  while ! docker compose exec -T postgres pg_isready -U relayer -q 2>/dev/null; do
    (( elapsed += step ))
    (( elapsed >= max )) && die "Postgres did not become ready within ${max}s"
    sleep "$step"
  done
  log "Postgres is ready"
}

setup_ibc() {
  log "╔══════════════════════════════════════════════════╗"
  log "║  IBC Setup: Cosmos ↔ Besu + Teku (Ethereum)       ║"
  log "╚══════════════════════════════════════════════════╝"

  # DO NOT wipe state.env here: each phase is idempotent (checks state or
  # the chain before re-submitting), so preserving prior addresses + client
  # IDs across `./setup.sh ibc` re-runs is what makes the flow fast. The
  # earlier blanket truncation + shell-var clear forced every phase to
  # re-do its work (re-deploying constructors, re-creating clients, etc.).
  # reconcile_ibc_client_pair clears stale client IDs on its own if the
  # on-chain counterparty pair doesn't match.

  run_phase "Phase 4A0: Fetch solidity-ibc-eureka source" fetch_solidity_ibc
  run_phase "Phase 4A:  Deploy IBC contracts on Besu"     deploy_ibc_contracts
  run_phase "Phase 4A1: Resolve IFT ERC20 address"        deploy_ift_contracts
  run_phase "Phase 4B0: Fetch ethereum-lc.wasm"           fetch_ethereum_lc_wasm
  run_phase "Phase 4B:  Resolve Ethereum LC checksum"     store_ethereum_lc
  run_phase "Phase 4C:  Resolve relayer wallet"           setup_relayer_key
  run_phase "Phase 4B5: Reconcile IBC client pair"        reconcile_ibc_client_pair
  run_phase "Phase 4B5: Create attestation IBC client"    create_ibc_clients
  run_phase "Phase 4D:  Generate relayer config"          generate_relayer_config
  # Render proof-api config BEFORE starting relayer: relayer depends_on
  # proof-api, so `docker compose up -d relayer` transitively starts proof-api
  # which bind-mounts ./ibc/local/relayer.json. If that file doesn't exist yet,
  # Docker creates a directory at the path and the later render fails.
  run_phase "Phase 4D1: Generate proof-api config"        generate_proof_api_config

  log "--- Phase 4E0: Start postgres + DB migrations ---"
  docker compose up -d postgres
  _wait_for_postgres
  run_db_migrations

  run_phase "Phase 4E:  Start relayer"                    start_relayer
  run_phase "Phase 4E1: Start attestor (EVM watcher)"     start_attestor
  run_phase "Phase 4E1a: Start attestor (Cosmos watcher)" start_attestor_cosmos
  run_phase "Phase 4E2: Start proof API"                  start_proof_api
  run_phase "Phase 4E3: Create EVM-side Cosmos client"    create_evm_ibc_client

  # Alloy HTTP provider may have cached state from before addClient — refresh.
  log "Restarting proof-api to clear stale provider state..."
  docker compose restart proof-api

  run_phase "Phase 4F:  Wait for attestation client"      wait_for_ibc_ready
  run_phase "Phase 4F1: Wait for Cosmos client on EVM"    wait_for_evm_client
  run_phase "Phase 4F2: Register counterparties"          register_counterparty
  run_phase "Phase 4F3:  Register IFT bridges (cosmos)"   register_ift_bridges
  run_phase "Phase 4F3a: Register IFT bridge (evm side)"  register_evm_ift_bridge
  # IFT tokens are minted lazily in demo_cosmos_to_evm_transfer when the sender
  # doesn't have enough — no pre-mint at setup time.
  run_phase "Phase 4F4: Finalise relayer config"          finalize_relayer_config

  run_phase "Phase 4G:  Run user-story demos"             demo_all

  echo ""
  info "════════════════════════════════════════════════════════"
  info " IBC Setup Complete"
  info "════════════════════════════════════════════════════════"
  info " ICS26Router          : $ICS26_ROUTER_ADDR"
  info " ICS20Transfer        : $ICS20_TRANSFER_ADDR"
  info " AttestationLightClient (EVM-side Cosmos LC) : ${EVM_ATTESTATION_LC_ADDR:-<not found>}"
  info " IFT ERC20            : ${IFT_CONTRACT_ADDR:-<not deployed>}"
  info " Cosmos IFT denom     : ${COSMOS_IFT_DENOM:-<not set>}"
  info " Wasm checksum        : $WASM_CHECKSUM"
  info " Cosmos wasm client   : ${COSMOS_WASM_CLIENT_ID:-<none>}"
  info " EVM Cosmos client    : ${EVM_COSMOS_CLIENT_ID:-<none>}"
  info " Relayer logs         : docker compose logs -f relayer"
  info " Attestor logs        : docker compose logs -f attestor"
  info " State file           : $IBC_STATE_FILE"
  info "════════════════════════════════════════════════════════"
  echo ""
}
