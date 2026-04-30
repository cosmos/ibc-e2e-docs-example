#!/usr/bin/env bash
# Phase 4: IBC setup (source fetch, forge deploy, client create, relayer wiring).

# ─── Phase 4A0 ───────────────────────────────────────────────────────────────
# Download the cosmos/solidity-ibc-eureka archive at $SOLIDITY_IBC_TAG into
# $IBC_DIR. Skips if SOLIDITY_IBC_DIR is pre-set or already extracted.
fetch_solidity_ibc() {
  if [[ -n "$ICS26_ROUTER_ADDR" && -n "$EVM_ATTESTATION_LC_ADDR" ]]; then
    log "IBC contracts already provided — skipping source fetch"
    return 0
  fi
  if [[ -n "$SOLIDITY_IBC_DIR" ]]; then
    [[ -d "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR='$SOLIDITY_IBC_DIR' not found"
    log "Using existing SOLIDITY_IBC_DIR: $SOLIDITY_IBC_DIR"
    return 0
  fi

  SOLIDITY_IBC_DIR="$IBC_DIR/solidity-ibc-eureka-${SOLIDITY_IBC_TAG}"
  if [[ -d "$SOLIDITY_IBC_DIR" ]]; then
    log "solidity-ibc-eureka ${SOLIDITY_IBC_TAG} already fetched — reusing"
    return 0
  fi

  local url="https://github.com/cosmos/solidity-ibc-eureka/archive/${SOLIDITY_IBC_TAG}.tar.gz"
  local tarball="$IBC_DIR/${SOLIDITY_IBC_TAG}.tar.gz"
  log "Fetching $url..."
  mkdir -p "$IBC_DIR"
  curl -fsSL "$url" -o "$tarball" || die "Failed to download $url"
  tar -xzf "$tarball" -C "$IBC_DIR"
  rm -f "$tarball"
  [[ -d "$SOLIDITY_IBC_DIR" ]] || die "Extraction failed: $SOLIDITY_IBC_DIR not found"
  log "solidity-ibc-eureka source ready at $SOLIDITY_IBC_DIR"
}

# Helper used by deploy_ibc_contracts + deploy_ift_contracts: look up a
# contract address by label in MinimalDeploy's returned JSON
# (`.returns."0".value` is a JSON-encoded string mapping labels like
# "ics26Router", "ics27Gmp", "ift", "erc20" to addresses).
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

# ─── Phase 4A ────────────────────────────────────────────────────────────────
# Run `forge script MinimalDeploy` on Besu to deploy ICS26Router + ICS27GMP +
# TestIFT. Idempotent: skips if router has bytecode at the recorded address.
deploy_ibc_contracts() {
  if [[ -n "$ICS26_ROUTER_ADDR" ]]; then
    local router_code
    router_code=$(cast_in_net code "$ICS26_ROUTER_ADDR" \
      --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || router_code=""
    if [[ "${router_code:-0x}" != "0x" ]]; then
      log "IBC contracts already deployed — skipping forge script"
      log "  ICS26Router        : $ICS26_ROUTER_ADDR"
      log "  ICS27GMP           : ${ICS27_GMP_ADDR:-<not set>}"
      return 0
    fi
    log "Recorded ICS26Router at $ICS26_ROUTER_ADDR has no bytecode on-chain — redeploying"
  fi

  [[ -n "$SOLIDITY_IBC_DIR" ]] || die "Set SOLIDITY_IBC_DIR or pre-set contract addresses"
  [[ -d "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR='$SOLIDITY_IBC_DIR' not found"

  log "Deploying solidity-ibc-eureka contracts on Besu (chain-id $ETH_CHAIN_ID)..."

  mkdir -p "$SOLIDITY_IBC_DIR"/{out,cache,broadcast,node_modules}
  chmod 0777 "$SOLIDITY_IBC_DIR"/{out,cache,broadcast,node_modules} 2>/dev/null || true

  # Stage any committed forge scripts from ibc/scripts/ into the fetched
  # source tree's scripts/ dir. Lets users add custom DEPLOY_SCRIPT options
  # (e.g. scripts/MinimalDeploy.s.sol) without editing the gitignored
  # solidity-ibc-eureka checkout. Idempotent — runs every deploy.
  if compgen -G "$IBC_DIR/scripts/*.s.sol" > /dev/null; then
    cp -f "$IBC_DIR/scripts"/*.s.sol "$SOLIDITY_IBC_DIR/scripts/"
  fi

  if [[ -z "$(ls -A "$SOLIDITY_IBC_DIR/node_modules" 2>/dev/null)" ]]; then
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
  ICS27_GMP_ADDR=$(_forge_return_addr "$s" ics27Gmp)

  [[ -n "$ICS26_ROUTER_ADDR" ]] || die "ics26Router not present"

  log "Contracts deployed:"
  log "  ICS26Router (proxy)   : $ICS26_ROUTER_ADDR"
  log "  ICS27GMP (proxy)      : ${ICS27_GMP_ADDR:-<not present — using old tag without ICS27?>}"

  state_set ICS26_ROUTER_ADDR "$ICS26_ROUTER_ADDR"
  [[ -n "${ICS27_GMP_ADDR:-}" ]] && state_set ICS27_GMP_ADDR "$ICS27_GMP_ADDR"
}

# ─── Phase 4A1 ───────────────────────────────────────────────────────────────
# Resolve IFT_CONTRACT_ADDR from the same forge return JSON. Falls back to
# the legacy "erc20" label for tags that predate the dedicated TestIFT proxy.
deploy_ift_contracts() {
  if [[ -n "$IFT_CONTRACT_ADDR" ]]; then
    log "IFT contract already provided: $IFT_CONTRACT_ADDR"
    return 0
  fi
  [[ -n "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR not set"

  IFT_CONTRACT_ADDR=$(_forge_return_addr "$(basename "$DEPLOY_SCRIPT")" ift)
  if [[ -z "$IFT_CONTRACT_ADDR" ]]; then
    IFT_CONTRACT_ADDR=$(_forge_return_addr "$(basename "$DEPLOY_SCRIPT")" erc20)
    [[ -n "$IFT_CONTRACT_ADDR" ]] \
      && log "  (using legacy 'erc20' label — this tag lacks TestIFT)"
  fi
  [[ -n "$IFT_CONTRACT_ADDR" ]] || \
    die "Neither 'ift' nor 'erc20' label in MinimalDeploy returns"
  log "IFT token resolved: $IFT_CONTRACT_ADDR"
  state_set IFT_CONTRACT_ADDR "$IFT_CONTRACT_ADDR"
}

# ─── Phase 4C ────────────────────────────────────────────────────────────────
# Read the relayer's bech32 address; copy the cosmos keyring-test directory
# into the relayer-data named volume so the relayer can sign Cosmos txs.
setup_relayer_key() {
  log "Resolving relayer wallet on Cosmos..."
  RELAYER_ADDR=$(run_in cosmos keys show relayer -a \
    --keyring-backend test --home "$COSMOS_HOME")
  log "Relayer wallet: $RELAYER_ADDR"
  state_set RELAYER_ADDR "$RELAYER_ADDR"

  # Relayer signs Cosmos txs from /relayer/cosmos-keys; copy the keyring across.
  log "Populating relayer cosmos keyring (relayer-data volume)..."
  docker run --rm \
    -v "${COMPOSE_PROJECT}_cosmos-data:/cosmos-data:ro" \
    -v "${COMPOSE_PROJECT}_relayer-data:/relayer" \
    busybox \
    sh -c "mkdir -p /relayer/cosmos-keys && cp -r /cosmos-data/keyring-test /relayer/cosmos-keys/"
  log "Relayer cosmos keyring ready"
}

# ─── Phase 4B5a ──────────────────────────────────────────────────────────────
# Verify persisted COSMOS_CLIENT_ID ↔ EVM_CLIENT_ID still match
# on-chain. Clears both on inconsistency so the next phase recreates them.
reconcile_ibc_client_pair() {
  if [[ -z "${COSMOS_CLIENT_ID:-}" || -z "${EVM_CLIENT_ID:-}" ]]; then
    COSMOS_CLIENT_ID=""; EVM_CLIENT_ID=""
    return 0
  fi

  local cosmos_cp
  cosmos_cp=$(curl -sf "http://localhost:1317/ibc/core/client/v2/counterparty_info/${COSMOS_CLIENT_ID}" 2>/dev/null \
    | jq -r '.counterparty_info.client_id // empty' 2>/dev/null || echo "")

  local evm_cp
  evm_cp=$(cast_in_net call "$ICS26_ROUTER_ADDR" \
    "getCounterparty(string)((string,bytes[]))" "$EVM_CLIENT_ID" \
    --rpc-url "http://besu:8545" 2>/dev/null \
    | sed -n 's/^(//; s/,.*$//; s/"//g; 1p' \
    | tr -d '[:space:]') || evm_cp=""

  if [[ "$cosmos_cp" == "$EVM_CLIENT_ID" && "$evm_cp" == "$COSMOS_CLIENT_ID" ]]; then
    log "IBC client pair verified: $COSMOS_CLIENT_ID ↔ $EVM_CLIENT_ID"
    return 0
  fi

  warn "IBC client pair inconsistent — clearing stale IDs, will create fresh pair"
  warn "  Cosmos: $COSMOS_CLIENT_ID.counterparty = '${cosmos_cp:-<unknown>}' (want: $EVM_CLIENT_ID)"
  warn "  EVM:    $EVM_CLIENT_ID.counterparty = '${evm_cp:-<unknown>}' (want: $COSMOS_CLIENT_ID)"
  COSMOS_CLIENT_ID=""; EVM_CLIENT_ID=""
}

# Helper used by create_ibc_clients (and re-run by start_attestor): render
# the EVM-watcher attestor config from its template.
generate_attestor_config() {
  log "Generating attestor config → ibc/local/attestor-config.toml"
  mkdir -p "$IBC_DIR/local"
  render_template "$IBC_DIR/attestor-config.toml.tmpl" \
                  "$IBC_DIR/local/attestor-config.toml"
}

# Helper used by create_ibc_clients + start_attestor + start_attestor_cosmos:
# generate the attestor's Web3 v3 JSON keystore (idempotent).
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

# ─── Phase 4B5b ──────────────────────────────────────────────────────────────
# Render ClientState + ConsensusState (attestor address, EVM height + ts),
# submit MsgCreateClient, poll REST until the attestations-N client appears.
create_ibc_clients() {
  if [[ -n "${COSMOS_CLIENT_ID:-}" ]]; then
    log "IBC attestation client already known: $COSMOS_CLIENT_ID"
    return 0
  fi

  log "Creating IBC attestation light client on Cosmos..."
  mkdir -p "$IBC_DIR/local"
  generate_attestor_config
  _ensure_attestor_keystore

  local attestor_eth_addr
  attestor_eth_addr="0x$(docker run --rm --user root \
    -v "$IBC_DIR/local:/home/nonroot" \
    -e HOME=/home/nonroot "$ATTESTOR_IMAGE" \
    key show 2>/dev/null | tr -d '[:space:]')"
  [[ "$attestor_eth_addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || \
    die "Failed to get valid attestor address (got: $attestor_eth_addr)"
  log "  Attestor address: $attestor_eth_addr"

  # EVM head height + its block timestamp. With Besu running internal QBFT
  # (no separate CL), the attestation LC trusts the EVM block directly. Floor
  # the height to 1 because the LC requires latest_height > 0 even if no
  # blocks have been produced yet.
  local evm_height_hex evm_height block_json block_ts_hex evm_ts evm_ts_ns
  evm_height_hex=$(curl -sf http://localhost:8545 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r '.result // "0x0"' 2>/dev/null) || evm_height_hex="0x0"
  evm_height=$(( evm_height_hex ))
  (( evm_height > 0 )) || evm_height=1

  block_json=$(curl -sf http://localhost:8545 \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"${evm_height_hex}\",false],\"id\":1}" 2>/dev/null) || block_json=""
  block_ts_hex=$(echo "$block_json" | jq -r '.result.timestamp // "0x0"' 2>/dev/null || echo "0x0")
  evm_ts=$(( block_ts_hex ))
  (( evm_ts > 0 )) || evm_ts=$(date +%s)
  evm_ts_ns=$(( evm_ts * 1000000000 ))
  log "  EVM height=$evm_height ts=$evm_ts"

  # Render ClientState and ConsensusState directly into ./cosmos/local/ on
  # the host. The cosmos service has ./cosmos bind-mounted RO at
  # /cosmos-config, so sandboxd tx ibc client create can read these files
  # there — RO is fine, the tx only reads them.
  local local_dir="$COSMOS_CFG_DIR/local"
  mkdir -p "$local_dir"
  ATTESTOR_ETH_ADDR="$attestor_eth_addr" EVM_HEIGHT="$evm_height" \
    render_template "$IBC_DIR/client-state.json.tmpl" \
                    "$local_dir/ibc_client_state.json"
  EVM_TS_NS="$evm_ts_ns" \
    render_template "$IBC_DIR/consensus-state.json.tmpl" \
                    "$local_dir/ibc_consensus_state.json"
  log "  ClientState: $(cat "$local_dir/ibc_client_state.json")"
  log "  ConsensusState: $(cat "$local_dir/ibc_consensus_state.json")"

  # Submit MsgCreateClient.
  local tx_output
  tx_output=$(run_in cosmos tx ibc client create \
    /cosmos-config/local/ibc_client_state.json \
    /cosmos-config/local/ibc_consensus_state.json \
    --from relayer --keyring-backend test --home "$COSMOS_HOME" \
    --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
    --gas auto --gas-adjustment 1.4 --gas-prices "0.025uatom" \
    --yes --output json)

  local tx_hash tx_json_line
  tx_json_line=$(echo "$tx_output" | grep -E '^\{' | tail -1 || echo "")
  tx_hash=$(echo "$tx_json_line" | jq -r '.txhash // empty' 2>/dev/null || echo "")
  if [[ -n "$tx_hash" ]]; then
    log "  MsgCreateClient submitted — txhash: $tx_hash"
  else
    warn "MsgCreateClient may have failed — output: $(echo "$tx_output" | head -3)"
  fi

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
        COSMOS_CLIENT_ID=$(echo "$tx_result" | jq -r '
          (
            (.tx_response.logs[0].events[]? | select(.type=="create_client") | .attributes[]? | select(.key=="client_id") | .value),
            (.tx_response.events[]? | select(.type=="create_client") | .attributes[]? | select(.key=="client_id") | .value)
          ) | first' 2>/dev/null | head -1 || echo "")
        [[ -n "$COSMOS_CLIENT_ID" ]] && break
      fi
    fi

    COSMOS_CLIENT_ID=$(curl -sf "http://localhost:1317/ibc/core/client/v1/client_states" 2>/dev/null \
      | jq -r '.client_states[].client_id' 2>/dev/null \
      | grep "^attestations-" | tail -1 || echo "")
    [[ -n "$COSMOS_CLIENT_ID" ]] && break

    sleep "$step"; (( elapsed += step ))
    echo -n "."
  done

  [[ -n "${COSMOS_CLIENT_ID:-}" ]] || \
    die "Failed to create attestation IBC client after ${max}s — check: docker compose logs cosmos"

  log "Attestation IBC client created: $COSMOS_CLIENT_ID"
  state_set COSMOS_CLIENT_ID "$COSMOS_CLIENT_ID"
}

# Helper used by generate_relayer_config: emits the counterparty_chains: YAML
# fragment for relayer-config.yml.tmpl — mapping or empty dict.
_cp_block() {
  local client_id="$1" chain_id="$2"
  if [[ -n "$client_id" ]]; then
    printf 'counterparty_chains:\n        %s: "%s"' "$client_id" "$chain_id"
  else
    printf 'counterparty_chains: {}'
  fi
}

# ─── Phase 4D ────────────────────────────────────────────────────────────────
# Export the cosmos relayer privkey, render keys.json + config.yml from
# templates. Run once early with empty client maps; finalized later by
# finalize_relayer_config once both client IDs are known.
generate_relayer_config() {
  log "Generating relayer config → ibc/local/config.yml"
  mkdir -p "$IBC_DIR/local"

  # signing.keys_path JSON: {chain_id: {private_key: hex}}
  #
  # `keys export --unarmored-hex --unsafe` confirms via stdin (run_in pipes
  # `printf 'y\n'`) and prints the warning to stderr, BUT older versions
  # also echoed the prompt to stdout, contaminating the captured output
  # with prefix bytes. Filter strictly to a single 64-char lowercase hex
  # line and bail loudly if extraction returns the wrong length — that's
  # the cause of "relayer signer cosmosX… not found" errors at recv time
  # (the relayer derives a different address from the contaminated key).
  local cosmos_privkey raw_export
  raw_export=$(run_in cosmos keys export relayer \
    --keyring-backend test --home "$COSMOS_HOME" \
    --unarmored-hex --unsafe 2>/dev/null)
  cosmos_privkey=$(echo "$raw_export" | grep -Eo '^[0-9a-f]{64}$' | tail -1)
  if [[ ${#cosmos_privkey} -ne 64 ]]; then
    warn "cosmos relayer privkey extraction returned ${#cosmos_privkey} chars (expected 64)"
    warn "raw 'keys export' output (first 200 chars, hex-escaped non-printables):"
    warn "$(echo "$raw_export" | head -c 200 | od -c | head -5)"
    die "Aborting — keys.json would have an invalid privkey, recvPacket would fail."
  fi
  log "  cosmos relayer privkey: ${#cosmos_privkey} chars (ok)"

  # Cross-check: derive the address from the keyring's relayer key and
  # compare to RELAYER_ADDR (set earlier by setup_relayer_key). If the
  # values diverge here the bug is upstream of this helper.
  local keyring_addr
  keyring_addr=$(run_in cosmos keys show relayer -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "${RELAYER_ADDR:-}" && -n "$keyring_addr" && "$keyring_addr" != "$RELAYER_ADDR" ]]; then
    warn "RELAYER_ADDR mismatch: state.env=$RELAYER_ADDR  keyring=$keyring_addr"
  fi
  log "  cosmos relayer address (keyring): $keyring_addr"

  ETH_PRIVKEY_BARE="${ETH_VALIDATOR_PRIVKEY#0x}" COSMOS_PRIVKEY="$cosmos_privkey" \
    render_template "$IBC_DIR/relayer-keys.json.tmpl" "$IBC_DIR/local/keys.json"
  log "Signing keys file written → $IBC_DIR/local/keys.json"

  COSMOS_CP_BLOCK=$(_cp_block "${COSMOS_CLIENT_ID:-}" "$ETH_CHAIN_ID")
  BESU_CP_BLOCK=$(_cp_block "${EVM_CLIENT_ID:-}" "$COSMOS_CHAIN_ID")
  export COSMOS_CP_BLOCK BESU_CP_BLOCK
  render_template "$IBC_DIR/relayer-config.yml.tmpl" "$IBC_DIR/local/config.yml"

  log "Relayer config written"
}

# ─── Phase 4D1 ───────────────────────────────────────────────────────────────
# Render proof-api config. Must run before start_relayer because relayer
# depends_on proof-api, which bind-mounts ./ibc/local/relayer.json — Docker
# would create a directory at the mount path if the file doesn't exist yet.
generate_proof_api_config() {
  log "Generating proof-api config → ibc/local/relayer.json"
  mkdir -p "$IBC_DIR/local"
  render_template "$IBC_DIR/proof-api.json.tmpl" \
                  "$IBC_DIR/local/relayer.json"
  log "Proof-api config written (attestation mode, both directions)"
}

# Helper used by setup_ibc (Phase 4E0): wait for postgres before migrations.
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

# ─── Phase 4E0 ───────────────────────────────────────────────────────────────
# Fetch cosmos/ibc-relayer source at the OPERATOR_IMAGE tag (cached on disk),
# run migrate/migrate up against the relayer DB.
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

# ─── Phase 4E ────────────────────────────────────────────────────────────────
# Start the IBC relayer service.
start_relayer()  { log "Starting IBC relayer ($OPERATOR_IMAGE)..."; docker compose up -d relayer; }

# ─── Phase 4E1 ───────────────────────────────────────────────────────────────
# Start the EVM-watcher attestor. Its attestations advance the
# attestations LC on Cosmos. Re-renders config (idempotent) and ensures
# the keystore exists.
start_attestor() {
  log "Starting IBC attestor — EVM watcher ($ATTESTOR_IMAGE)..."
  generate_attestor_config
  _ensure_attestor_keystore
  docker compose up -d attestor
}

# Helper used by start_attestor_cosmos: render the Cosmos-watcher attestor
# config from its template.
generate_attestor_cosmos_config() {
  log "Generating cosmos-attestor config → ibc/local/attestor-cosmos-config.toml"
  mkdir -p "$IBC_DIR/local"
  render_template "$IBC_DIR/attestor-cosmos-config.toml.tmpl" \
                  "$IBC_DIR/local/attestor-cosmos-config.toml"
}

# ─── Phase 4E1a ──────────────────────────────────────────────────────────────
# Start the Cosmos-watcher attestor. Shares the keystore with the EVM
# watcher, so a single attestor address is registered with both light clients.
# Its attestations advance the AttestationLightClient on EVM.
start_attestor_cosmos() {
  log "Starting IBC attestor — Cosmos watcher ($ATTESTOR_IMAGE)..."
  generate_attestor_cosmos_config
  _ensure_attestor_keystore
  docker compose up -d attestor-cosmos
}

# ─── Phase 4E2 ───────────────────────────────────────────────────────────────
# Start proof-api (attestation mode, both directions). Re-renders config to
# defend against a partial state where the host file went missing.
start_proof_api() {
  log "Starting proof API ($PROOF_API_IMAGE, attestation mode)..."
  generate_proof_api_config
  docker compose up -d proof-api
}

# ─── Phase 4E3 ───────────────────────────────────────────────────────────────
# Read attestor address + Cosmos head height/timestamp, deploy
# AttestationLightClient(attestors, quorum=1, initHeight, initTs,
# roleManager=0x0) via `cast --create`, then call ICS26Router.addClient to
# register it. Persists EVM_CLIENT_ID + EVM_ATTESTATION_LC_ADDR.
create_evm_ibc_client() {
  if [[ -n "${EVM_CLIENT_ID:-}" ]]; then
    log "EVM Cosmos client already known: $EVM_CLIENT_ID"
    return 0
  fi

  log "Creating EVM-side Cosmos light client (AttestationLightClient)..."
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

  local add_receipt add_status
  add_receipt=$(cast_in_net send "$ICS26_ROUTER_ADDR" \
    "addClient((string,bytes[]),address)" \
    "($COSMOS_CLIENT_ID,[0x])" "$lc_addr" \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" --json 2>/dev/null) || add_receipt=""
  add_status=$(echo "$add_receipt" | jq -r '.status // empty' 2>/dev/null || echo "")
  [[ "$add_status" == "0x1" ]] || die "ICS26Router.addClient failed (status=$add_status)"

  local verify_addr
  verify_addr=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getClient(string)(address)" "$predicted" \
    --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || verify_addr=""
  EVM_CLIENT_ID="$predicted"
  EVM_ATTESTATION_LC_ADDR="$lc_addr"
  if [[ -n "$verify_addr" && "$verify_addr" != "0x0000000000000000000000000000000000000000" ]]; then
    log "EVM Cosmos client registered: $EVM_CLIENT_ID → $verify_addr"
  else
    warn "Could not verify $predicted — using predicted ID"
  fi

  state_set EVM_CLIENT_ID "$EVM_CLIENT_ID"
  state_set EVM_ATTESTATION_LC_ADDR "$lc_addr"
}

# ─── Phase 4F ────────────────────────────────────────────────────────────────
# Poll Cosmos REST for any attestations-* client. Covers the case where the
# relayer auto-creates it instead of create_ibc_clients.
wait_for_ibc_ready() {
  [[ -n "${COSMOS_CLIENT_ID:-}" ]] && { log "IBC attestation client: $COSMOS_CLIENT_ID"; return 0; }

  local max=300 step=5 elapsed=0
  log "Waiting for attestation IBC client on Cosmos..."
  while true; do
    local cid
    cid=$(curl -sf "http://localhost:1317/ibc/core/client/v1/client_states" 2>/dev/null \
      | jq -r '.client_states[].client_id' 2>/dev/null \
      | grep "^attestations-" | head -1 || true)
    if [[ -n "$cid" ]]; then
      COSMOS_CLIENT_ID="$cid"
      log "IBC attestation client ready: $COSMOS_CLIENT_ID"
      state_set COSMOS_CLIENT_ID "$COSMOS_CLIENT_ID"
      return 0
    fi
    (( elapsed += step ))
    (( elapsed >= max )) && die "Attestation IBC client did not appear within ${max}s — check relayer logs"
    sleep "$step"; echo -n "."
  done
}

# ─── Phase 4F1 ───────────────────────────────────────────────────────────────
# Poll ICS26Router.getNextClientSeq() until > 0 — assumes client-0.
wait_for_evm_client() {
  [[ -n "${EVM_CLIENT_ID:-}" ]] && { log "EVM Cosmos client: $EVM_CLIENT_ID"; return 0; }

  local max=300 step=5 elapsed=0
  log "Waiting for Cosmos light client on EVM (ICS26Router)..."
  while true; do
    local next_seq
    next_seq=$(cast_in_net call "$ICS26_ROUTER_ADDR" "getNextClientSeq()(uint256)" \
      --rpc-url "http://besu:8545" 2>/dev/null | tr -d '[:space:]') || next_seq=0
    if [[ "$next_seq" =~ ^[0-9]+$ ]] && (( next_seq > 0 )); then
      # getNextClientSeq returns the next-id-to-assign, so the most recently
      # added client is one less. Hardcoding client-0 broke any chain where
      # addClient had been called more than once (e.g. partial-state re-runs).
      EVM_CLIENT_ID="client-$((next_seq - 1))"
      log "EVM Cosmos client ready: $EVM_CLIENT_ID"
      state_set EVM_CLIENT_ID "$EVM_CLIENT_ID"
      return 0
    fi
    (( elapsed += step ))
    if (( elapsed >= max )); then
      warn "EVM Cosmos client not found within ${max}s"
      warn "Set EVM_CLIENT_ID manually and re-run: ./setup.sh ibc"
      return 0
    fi
    sleep "$step"; echo -n "."
  done
}

# ─── Phase 4F2 ───────────────────────────────────────────────────────────────
# Submit Cosmos-side `tx ibc client add-counterparty` so the wasm client knows
# its EVM peer.
register_counterparty() {
  log "Registering IBC counterparty on Cosmos..."
  [[ -n "$COSMOS_CLIENT_ID" ]] || die "COSMOS_CLIENT_ID not set"
  if [[ -z "$EVM_CLIENT_ID" ]]; then
    warn "EVM_CLIENT_ID unknown — skipping add-counterparty"
    return 0
  fi

  local existing
  existing=$(curl -sf "http://localhost:1317/ibc/core/client/v2/counterparty_info/${COSMOS_CLIENT_ID}" 2>/dev/null \
    | jq -r '.counterparty_info.client_id // empty' 2>/dev/null || true)
  if [[ "$existing" == "$EVM_CLIENT_ID" ]]; then
    log "  Counterparty already registered: $COSMOS_CLIENT_ID ↔ $EVM_CLIENT_ID"
    return 0
  fi

  log "  add-counterparty: $COSMOS_CLIENT_ID ↔ $EVM_CLIENT_ID"
  run_in cosmos tx ibc client add-counterparty \
    "$COSMOS_CLIENT_ID" "$EVM_CLIENT_ID" "" \
    --from relayer --keyring-backend test --home "$COSMOS_HOME" \
    --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
    --gas auto --gas-adjustment 1.4 --gas-prices 0.025uatom \
    --yes --output json 2>/dev/null || \
    warn "add-counterparty failed — check: docker compose logs cosmos"

  log "Counterparty registration complete"
}

# ─── Phase 4F3 ───────────────────────────────────────────────────────────────
# Cosmos side of the IFT bridge: compute the EIP-55 checksummed EVM IFT
# address (critical — sandbox x/ift does string compare against ICS27GMP's
# checksummed sender), self-heal stale registrations, create the tokenfactory
# subdenom `uift`, then `tx ift register-bridge … evm`. Rewrites
# DEMO_TRANSFER_AMOUNT to `<N>uift`.
register_ift_bridges() {
  if [[ -z "$IFT_CONTRACT_ADDR" ]]; then
    warn "IFT_CONTRACT_ADDR not set — skipping IFT bridge registration"
    return 0
  fi

  if [[ -z "$COSMOS_IFT_DENOM" ]]; then
    COSMOS_IFT_DENOM="uift"
  fi
  log "  Cosmos IFT denom: $COSMOS_IFT_DENOM"

  local existing_bridge
  existing_bridge=$(docker compose exec -T cosmos sandboxd query ift bridge \
    "$COSMOS_IFT_DENOM" "$COSMOS_CLIENT_ID" \
    --node tcp://localhost:26657 -o json 2>/dev/null \
    | jq -r '.bridge.counterparty_ift_address // empty' 2>/dev/null || echo "")
  
  local ift_addr_checksum
  ift_addr_checksum=$(cast_in_net to-check-sum-address "$IFT_CONTRACT_ADDR" 2>/dev/null \
    | tr -d '[:space:]') || ift_addr_checksum=""
  [[ -n "$ift_addr_checksum" ]] || ift_addr_checksum="$IFT_CONTRACT_ADDR"

  if [[ -n "$existing_bridge" && "$existing_bridge" != "$ift_addr_checksum" ]]; then
    log "Cosmos IFT bridge registered with stale address:"
    log "  on chain: $existing_bridge"
    log "  expected: $ift_addr_checksum  (EIP-55 checksum)"
    log "  → removing and re-registering with the correct casing..."
    cosmos_tx_and_wait tx ift remove-bridge \
      "$COSMOS_IFT_DENOM" "$COSMOS_CLIENT_ID" \
      --from validator >/dev/null
    existing_bridge=""  # fall through to the registration block below
  fi

  if [[ -n "$existing_bridge" ]]; then
    log "Cosmos IFT bridge already registered (→ $existing_bridge) — skipping create-denom + register-bridge"
  else
    local subdenom="${COSMOS_IFT_DENOM##*/}"
    local validator_addr
    validator_addr=$(run_in cosmos keys show validator -a \
      --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')
    if docker compose exec -T cosmos sandboxd query tokenfactory denoms-by-creator \
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
    log "  Registering Cosmos IFT bridge (client=$COSMOS_CLIENT_ID → evm=$ift_addr_checksum)..."
    cosmos_tx_and_wait tx ift register-bridge \
      "$COSMOS_IFT_DENOM" "$COSMOS_CLIENT_ID" "$ift_addr_checksum" evm \
      --from validator >/dev/null
    log "Cosmos IFT bridge registered"
  fi

  # EVM-side registration is done in a separate phase (register_evm_ift_bridge)
  # because it needs the ICA address derived from ICS26Router + TestIFT proxy,
  # and then deploys the CosmosIFTSendCallConstructor parameterised with it.

  state_set COSMOS_IFT_DENOM "$COSMOS_IFT_DENOM"

  # Default the demo to transfer IFT instead of uatom. Persist so it survives
  # across invocations (`./setup.sh demo cosmos-evm` on a later run).
  local num="1000000"
  [[ "$DEMO_TRANSFER_AMOUNT" =~ ^([0-9]+) ]] && num="${BASH_REMATCH[1]}"
  DEMO_TRANSFER_AMOUNT="${num}${COSMOS_IFT_DENOM}"
  state_set DEMO_TRANSFER_AMOUNT "$DEMO_TRANSFER_AMOUNT"
  log "DEMO_TRANSFER_AMOUNT → $DEMO_TRANSFER_AMOUNT"
}

# Lazy mint helper called from lib/demo.sh (demo_cosmos_to_evm_transfer) when
# the sender's IFT balance would be insufficient — NOT called by setup_ibc.
mint_ift_tokens() {
  if [[ -z "${COSMOS_IFT_DENOM:-}" ]]; then
    warn "COSMOS_IFT_DENOM not set — skipping IFT mint"
    return 0
  fi

  # Mint via tokenfactory (IFT module has no mint; it wraps tokenfactory).
  # Signature: tx tokenfactory mint [address] [amount]
  local validator_addr mint_amount="${IFT_MINT_AMOUNT:-1000000000}"
  validator_addr=$(run_in cosmos keys show validator -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')

  log "  Minting ${mint_amount}${COSMOS_IFT_DENOM} to ${validator_addr}..."
  cosmos_tx_and_wait tx tokenfactory mint \
    "$validator_addr" "${mint_amount}${COSMOS_IFT_DENOM}" \
    --from validator >/dev/null
  log "  Mint committed."
}

# ─── Phase 4F3a ──────────────────────────────────────────────────────────────
# EVM side of the IFT bridge. Three steps, all shell-only:
#   1. Ask sandboxd for the ICA address the Cosmos GMP module will use to
#      sign MsgIFTMint when a packet arrives from the EVM TestIFT proxy.
#   2. Deploy CosmosIFTSendCallConstructor from compiled bytecode, wiring the
#      ICA + type URL + denom into it (MinimalDeploy skipped this contract
#      because IFT_ICA_ADDRESS wasn't known at forge-deploy time).
#   3. Call TestIFT.registerIFTBridge(clientId, icaAddress, constructor) so
#      TestIFT.iftTransfer can wrap iftTransfer → ICS27GMP.sendCall with a
#      correctly-signed MsgIFTMint payload.
register_evm_ift_bridge() {
  [[ -n "$IFT_CONTRACT_ADDR" ]]      || { warn "IFT_CONTRACT_ADDR not set — skipping EVM IFT bridge"; return 0; }
  [[ -n "$EVM_CLIENT_ID" ]]   || { warn "EVM_CLIENT_ID not set — skipping EVM IFT bridge"; return 0; }
  [[ -n "$COSMOS_CLIENT_ID" ]]  || { warn "COSMOS_CLIENT_ID not set — skipping EVM IFT bridge"; return 0; }
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

  log "  Computing ICA for (client=$COSMOS_CLIENT_ID, sender=$ift_addr_checksum)..."
  local ica
  ica=$(docker compose exec -T cosmos sandboxd query gmp get-address \
    "$COSMOS_CLIENT_ID" "$ift_addr_checksum" "" -o json 2>/dev/null \
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
  cosmos_ift_module=$(docker compose exec -T cosmos sandboxd query auth module-account ift \
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

  # MsgIFTMint type URL + tokenfactory denom match sandbox's x/ift + tokenfactory
  # wiring; keeping them together here so the constructor matches what
  # CosmosIFTSendCallConstructor expects on the other side.
  local type_url="/sandbox.ift.MsgIFTMint"

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
  log "  TestIFT.registerIFTBridge(client=$EVM_CLIENT_ID, module=$cosmos_ift_module, ctor=$ctor_addr)..."
  cast_in_net send "$IFT_CONTRACT_ADDR" \
    "registerIFTBridge(string,string,address)" \
    "$EVM_CLIENT_ID" "$cosmos_ift_module" "$ctor_addr" \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" 2>/dev/null \
    || die "TestIFT.registerIFTBridge failed — check authority / access control on TestIFT"

  IFT_ICA_ADDRESS="$ica"
  IFT_CTOR_ADDR="$ctor_addr"
  COSMOS_IFT_MODULE_ADDR="$cosmos_ift_module"
  state_set IFT_ICA_ADDRESS "$ica"
  state_set IFT_CTOR_ADDR "$ctor_addr"
  state_set COSMOS_IFT_MODULE_ADDR "$cosmos_ift_module"
  log "EVM IFT bridge registered"
}

# ─── Phase 4F4 ───────────────────────────────────────────────────────────────
# Re-render config.yml now that both client IDs are known and restart relayer.
finalize_relayer_config() {
  log "Finalising relayer config with counterparty client mappings..."
  generate_relayer_config
  log "Restarting relayer to pick up updated config..."
  docker compose restart relayer
  log "Relayer restarted"
}

# ─── Phase 4 driver ──────────────────────────────────────────────────────────
# Each phase function above is idempotent; this orchestrator wires them in
# order. State.env survives across runs so re-runs are fast.
setup_ibc() {
  log "╔══════════════════════════════════════════════════╗"
  log "║  IBC Setup: Cosmos ↔ Besu (Ethereum)             ║"
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
  run_phase "Phase 4C:  Resolve relayer wallet"           setup_relayer_key
  run_phase "Phase 4B5: Reconcile IBC client pair"        reconcile_ibc_client_pair
  run_phase "Phase 4B5: Create attestation IBC client"    create_ibc_clients
  run_phase "Phase 4D:  Generate relayer config"          generate_relayer_config
  # Render config files for everything the relayer transitively pulls in
  # (proof-api → attestor + attestor-cosmos) BEFORE start_relayer. Otherwise
  # `docker compose up -d relayer` starts those services with bind-mounted
  # config files that don't yet exist on the host, and they crash-loop until
  # the later phase renders them. attestor-config.toml is also already
  # rendered as a side effect of create_ibc_clients above; the cosmos one
  # has no equivalent early call, so its absence here is what triggered the
  # observed crash loop.
  log "--- Phase 4D1: Generate proof-api + attestor configs ---"
  generate_proof_api_config
  generate_attestor_config
  generate_attestor_cosmos_config

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
  info " ICS27GMP             : ${ICS27_GMP_ADDR:-<not deployed>}"
  info " AttestationLightClient (EVM-side Cosmos LC) : ${EVM_ATTESTATION_LC_ADDR:-<not found>}"
  info " IFT ERC20            : ${IFT_CONTRACT_ADDR:-<not deployed>}"
  info " Cosmos IFT denom     : ${COSMOS_IFT_DENOM:-<not set>}"
  info " Cosmos attestations LC : ${COSMOS_CLIENT_ID:-<none>}"
  info " EVM Cosmos client    : ${EVM_CLIENT_ID:-<none>}"
  info " Relayer logs         : docker compose logs -f relayer"
  info " Attestor logs        : docker compose logs -f attestor"
  info " State file           : $IBC_STATE_FILE"
  info "════════════════════════════════════════════════════════"
  echo ""
}
