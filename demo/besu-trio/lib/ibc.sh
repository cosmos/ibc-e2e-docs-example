#!/usr/bin/env bash
# IBC contract deploy for besu-trio. Fetches solidity-ibc-eureka source once,
# stages custom scripts from ibc/scripts/, then runs forge against each of
# besu-a / besu-hub / besu-b. Per-chain addresses are persisted to
# ibc/state.env keyed by uppercase chain name (A_, HUB_, B_).
#
# Idempotent: a chain is skipped if its recorded ICS26Router still has
# bytecode at the recorded address.

# ─── Source fetch ────────────────────────────────────────────────────────────
# SOLIDITY_IBC_TAG can be a tag (`v0.0.2`), a sha, or a branch with slashes
# (`gjermund/besu-poc`). GitHub's archive endpoint serves all three at
# `/archive/<ref>.tar.gz`; on extract, slashes in branch names are flattened
# to dashes, so the on-disk dir is named with dashes too.
fetch_solidity_ibc() {
  if [[ -n "$SOLIDITY_IBC_DIR" ]]; then
    [[ -d "$SOLIDITY_IBC_DIR" ]] || die "SOLIDITY_IBC_DIR='$SOLIDITY_IBC_DIR' not found"
    log "Using existing SOLIDITY_IBC_DIR: $SOLIDITY_IBC_DIR"
    return 0
  fi

  local tag_slug="${SOLIDITY_IBC_TAG//\//-}"
  SOLIDITY_IBC_DIR="$IBC_DIR/solidity-ibc-eureka-${tag_slug}"
  if [[ -d "$SOLIDITY_IBC_DIR" ]]; then
    log "solidity-ibc-eureka ${SOLIDITY_IBC_TAG} already fetched — reusing"
    return 0
  fi

  local url="https://github.com/cosmos/solidity-ibc-eureka/archive/${SOLIDITY_IBC_TAG}.tar.gz"
  local tarball="$IBC_DIR/${tag_slug}.tar.gz"
  log "Fetching $url..."
  mkdir -p "$IBC_DIR"
  curl -fsSL "$url" -o "$tarball" || die "Failed to download $url"
  tar -xzf "$tarball" -C "$IBC_DIR"
  rm -f "$tarball"
  if [[ ! -d "$SOLIDITY_IBC_DIR" ]]; then
    # GitHub flattens slashes to dashes when building the top-level dir,
    # which usually matches our $tag_slug already — but double-check via
    # the most-recently-extracted solidity-ibc-eureka-* and rename if not.
    local extracted
    extracted=$(find "$IBC_DIR" -maxdepth 1 -type d -name "solidity-ibc-eureka-*" \
                | head -1)
    [[ -d "$extracted" ]] || die "Extraction failed: no solidity-ibc-eureka-* dir at $IBC_DIR"
    [[ "$extracted" == "$SOLIDITY_IBC_DIR" ]] || mv "$extracted" "$SOLIDITY_IBC_DIR"
  fi
  log "solidity-ibc-eureka source ready at $SOLIDITY_IBC_DIR"
}

install_contract_deps() {
  mkdir -p "$SOLIDITY_IBC_DIR"/{out,cache,broadcast,node_modules}
  chmod 0777 "$SOLIDITY_IBC_DIR"/{out,cache,broadcast,node_modules} 2>/dev/null || true
  if [[ -z "$(ls -A "$SOLIDITY_IBC_DIR/node_modules" 2>/dev/null)" ]]; then
    log "Installing contract dependencies (bun install)..."
    docker run --rm \
      -v "$SOLIDITY_IBC_DIR":/contracts -w /contracts \
      "$BUN_IMAGE" bun install --frozen-lockfile
  fi
}

# Stage any committed forge scripts from ibc/scripts/ into the fetched source
# tree. Lets the in-repo MinimalDeploy.s.sol stay outside the gitignored
# eureka checkout. Idempotent.
stage_custom_scripts() {
  if compgen -G "$IBC_DIR/scripts/*.s.sol" > /dev/null; then
    cp -f "$IBC_DIR/scripts"/*.s.sol "$SOLIDITY_IBC_DIR/scripts/"
  fi
}

# Pull a contract address out of MinimalDeploy's returned JSON. Forge
# double-escapes the string, so strip backslashes before fromjson — same
# trick the cosmos-evm demo uses.
_forge_return_addr() {
  local script_name="$1" chain_id="$2" label="$3"
  local run_json="$SOLIDITY_IBC_DIR/broadcast/${script_name}/${chain_id}/run-latest.json"
  [[ -f "$run_json" ]] || die "Forge broadcast not found: $run_json"
  jq -r ".returns.\"0\".value | gsub(\"\\\\\\\\\"; \"\") | fromjson | .${label} // empty" \
    "$run_json" 2>/dev/null
}

# Run cast inside the compose network — used for the on-chain bytecode
# idempotency check.
_cast_in_net() {
  docker run --rm \
    --network "${COMPOSE_PROJECT}_besu-trio-net" \
    --entrypoint "" -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    "$FOUNDRY_IMAGE" cast "$@"
}

# Persist KEY=VAL into $IBC_STATE_FILE, replacing any prior line for KEY.
_state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$IBC_STATE_FILE")"
  if [[ -f "$IBC_STATE_FILE" ]]; then
    grep -v "^${key}=" "$IBC_STATE_FILE" > "${IBC_STATE_FILE}.tmp" 2>/dev/null || true
    mv "${IBC_STATE_FILE}.tmp" "$IBC_STATE_FILE"
  fi
  echo "${key}=${val}" >> "$IBC_STATE_FILE"
}

# deploy_to_chain <name> <rpc_url> <chain_id>
#   name     — A | hub | B (used as the state-file prefix, uppercased)
#   rpc_url  — internal docker DNS, e.g. http://besu-a:8545
#   chain_id — matching numeric chain ID
deploy_to_chain() {
  local name="$1" rpc_url="$2" chain_id="$3"
  local prefix="${name}"  # A | hub | B — kept verbatim so state.env keys
                          # match the template variable names exactly
  local existing_router_var="${prefix}_ICS26_ROUTER_ADDR"
  local existing_router="${!existing_router_var:-}"

  if [[ -n "$existing_router" ]]; then
    local code
    code=$(_cast_in_net code "$existing_router" --rpc-url "$rpc_url" 2>/dev/null \
      | tr -d '[:space:]') || code=""
    if [[ "${code:-0x}" != "0x" ]]; then
      log "[$name] IBC contracts already deployed at $existing_router — skipping"
      return 0
    fi
    warn "[$name] Recorded ICS26Router has no bytecode on-chain — redeploying"
  fi

  log "[$name] Deploying solidity-ibc-eureka contracts (chain-id $chain_id)..."

  docker run --rm --entrypoint "" \
    --network "${COMPOSE_PROJECT}_besu-trio-net" \
    -v "$SOLIDITY_IBC_DIR":/contracts -w /contracts \
    -e E2E_FAUCET_ADDRESS="$DEPLOYER_ADDR" \
    -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    "$FOUNDRY_IMAGE" \
    forge script "$DEPLOY_SCRIPT" \
      --rpc-url "$rpc_url" \
      --private-key "$DEPLOYER_PRIVKEY" \
      --broadcast --chain-id "$chain_id" 2>&1 | grep -v "^$"

  local s; s=$(basename "$DEPLOY_SCRIPT")
  local router gmp ift
  router=$(_forge_return_addr "$s" "$chain_id" ics26Router)
  gmp=$(   _forge_return_addr "$s" "$chain_id" ics27Gmp)
  ift=$(   _forge_return_addr "$s" "$chain_id" ift)

  [[ -n "$router" ]] || die "[$name] ics26Router not present in forge return"

  log "[$name] Deployed:"
  log "  ICS26Router : $router"
  log "  ICS27GMP    : ${gmp:-<n/a>}"
  log "  TestIFT     : ${ift:-<n/a>}"

  _state_set "${prefix}_ICS26_ROUTER_ADDR" "$router"
  [[ -n "$gmp" ]] && _state_set "${prefix}_ICS27_GMP_ADDR"     "$gmp"
  [[ -n "$ift" ]] && _state_set "${prefix}_IFT_CONTRACT_ADDR"  "$ift"
}

deploy_all_chains() {
  fetch_solidity_ibc
  stage_custom_scripts
  install_contract_deps

  deploy_to_chain A   http://besu-a:8545   41001
  deploy_to_chain hub http://besu-hub:8545 41000
  deploy_to_chain B   http://besu-b:8545   41002
}

print_deployed() {
  if [[ ! -f "$IBC_STATE_FILE" ]]; then
    log "No contracts deployed yet (no $IBC_STATE_FILE)"
    return 0
  fi
  log "Deployed contracts (from $IBC_STATE_FILE):"
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    log "  $k = $v"
  done < "$IBC_STATE_FILE"
}

# ─── Attestor keystores ──────────────────────────────────────────────────────
# Each of the 4 directional attestors gets its own Web3 v3 JSON keystore at
#   ibc/local/keys/<name>/.ibc-attestor/ibc-attestor-keystore
# generated by `ibc-attestor key generate` with HOME pointed at that dir.
# Idempotent.
_ensure_attestor_keystore() {
  local name="$1"
  local home_dir="$IBC_DIR/local/keys/$name"
  [[ -f "$home_dir/.ibc-attestor/ibc-attestor-keystore" ]] && return 0
  log "[$name] Generating attestor keystore..."
  mkdir -p "$home_dir"
  docker run --rm --user root \
    -v "$home_dir:/home/nonroot" \
    -e HOME=/home/nonroot \
    "$ATTESTOR_IMAGE" key generate
  [[ -f "$home_dir/.ibc-attestor/ibc-attestor-keystore" ]] \
    || die "[$name] keystore not generated at $home_dir/.ibc-attestor/"
}

# Read the 0x-prefixed EVM address out of an attestor's keystore.
_attestor_address() {
  local name="$1"
  local home_dir="$IBC_DIR/local/keys/$name"
  local addr
  addr="0x$(docker run --rm --user root \
    -v "$home_dir:/home/nonroot" \
    -e HOME=/home/nonroot \
    "$ATTESTOR_IMAGE" key show 2>/dev/null | tr -d '[:space:]')"
  [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "[$name] could not read keystore address (got: $addr)"
  echo "$addr"
}

ensure_all_attestor_keystores() {
  _ensure_attestor_keystore A-to-hub
  _ensure_attestor_keystore hub-to-A
  _ensure_attestor_keystore hub-to-B
  _ensure_attestor_keystore B-to-hub

  local a hb1 hb2 b
  a=$(_attestor_address A-to-hub)
  hb1=$(_attestor_address hub-to-A)
  hb2=$(_attestor_address hub-to-B)
  b=$(_attestor_address B-to-hub)

  _state_set ATTESTOR_A_TO_HUB_ADDR "$a"
  _state_set ATTESTOR_HUB_TO_A_ADDR "$hb1"
  _state_set ATTESTOR_HUB_TO_B_ADDR "$hb2"
  _state_set ATTESTOR_B_TO_HUB_ADDR "$b"

  log "Attestor addresses:"
  log "  A-to-hub : $a"
  log "  hub-to-A : $hb1"
  log "  hub-to-B : $hb2"
  log "  B-to-hub : $b"
}

# ─── Config rendering ────────────────────────────────────────────────────────
_render_one_attestor() {
  local name="$1" rpc_url="$2" router_addr="$3"
  ATTESTOR_NAME="$name" ATTESTOR_RPC_URL="$rpc_url" ATTESTOR_ROUTER_ADDR="$router_addr" \
    render_template "$IBC_DIR/attestor-config.toml.tmpl" \
                    "$IBC_DIR/local/attestor-${name}.toml"
}

generate_attestor_configs() {
  log "Rendering 4 attestor configs → ibc/local/attestor-*.toml"
  _render_one_attestor A-to-hub http://besu-a:8545   "$A_ICS26_ROUTER_ADDR"
  _render_one_attestor hub-to-A http://besu-hub:8545 "$hub_ICS26_ROUTER_ADDR"
  _render_one_attestor hub-to-B http://besu-hub:8545 "$hub_ICS26_ROUTER_ADDR"
  _render_one_attestor B-to-hub http://besu-b:8545   "$B_ICS26_ROUTER_ADDR"
}

# Build a `counterparty_chains:` YAML fragment from (client_id, chain_id) pairs.
# Pairs whose client_id is empty are dropped — call sites pass `${LC_ID:-}` /
# `${LC_ID:+chain-id}` so an unset LC produces ("", "") that we filter here.
# If no usable pairs remain, emit `{}` so the relayer sees a valid empty map
# instead of `counterparty_chains:\n        : ""`.
# Indentation: child entries get 8 spaces; the leading `counterparty_chains:`
# is positioned by the template's own indent at the substitution site.
_cp_block() {
  local pairs=()
  while [[ $# -ge 2 ]]; do
    [[ -n "$1" ]] && pairs+=("        $1: \"$2\"")
    shift 2
  done
  if [[ ${#pairs[@]} -eq 0 ]]; then
    printf 'counterparty_chains: {}'
  else
    printf 'counterparty_chains:\n'
    printf '%s\n' "${pairs[@]}"
  fi
}

generate_relayer_config() {
  log "Rendering relayer config → ibc/local/config.yml"

  # Until `./setup.sh wire` deploys BesuQBFTLightClients and registers the
  # client IDs, all blocks render as empty maps. The relayer boots fine but
  # has no clients to drive yet.
  A_CP_BLOCK=$(_cp_block "${A_LC_ID:-}"             "${A_LC_ID:+41000}")
  HUB_CP_BLOCK=$(_cp_block \
    "${HUB_LC_FOR_A_ID:-}" "${HUB_LC_FOR_A_ID:+41001}" \
    "${HUB_LC_FOR_B_ID:-}" "${HUB_LC_FOR_B_ID:+41002}")
  B_CP_BLOCK=$(_cp_block "${B_LC_ID:-}"             "${B_LC_ID:+41000}")
  export A_CP_BLOCK HUB_CP_BLOCK B_CP_BLOCK
  export PROOF_API_GRPC_ADDR="${PROOF_API_GRPC_ADDR:-proof-api:9090}"

  render_template "$IBC_DIR/relayer-config.yml.tmpl" "$IBC_DIR/local/config.yml"

  DEPLOYER_PRIVKEY_BARE="${DEPLOYER_PRIVKEY#0x}" \
    render_template "$IBC_DIR/relayer-keys.json.tmpl" "$IBC_DIR/local/keys.json"
  log "Relayer config + keys written"
}

generate_proof_api_config() {
  log "Rendering proof-api config → ibc/local/relayer.json"
  render_template "$IBC_DIR/proof-api.json.tmpl" "$IBC_DIR/local/relayer.json"
}

render_ibc_configs() {
  [[ -n "${A_ICS26_ROUTER_ADDR:-}"   ]] || die "A_ICS26_ROUTER_ADDR not set — run './setup.sh contracts' first"
  [[ -n "${hub_ICS26_ROUTER_ADDR:-}" ]] || die "hub_ICS26_ROUTER_ADDR not set — run './setup.sh contracts' first"
  [[ -n "${B_ICS26_ROUTER_ADDR:-}"   ]] || die "B_ICS26_ROUTER_ADDR not set — run './setup.sh contracts' first"

  ensure_all_attestor_keystores
  generate_attestor_configs
  generate_relayer_config
  generate_proof_api_config
}

# ─── Local proof-api image build ─────────────────────────────────────────────
# The published `ghcr.io/cosmos/proof-api:latest` was built from a tree that
# does NOT include the `besu-to-besu` relayer module — its symbol table only
# carries cosmos_to_*, eth_to_*, solana_to_*. The `gjermund/besu-poc` branch
# we fetch for contracts also carries the Rust relayer source with
# BesuToBesuRelayerModule, so we build a local image from that tree and use
# it instead of :latest.
#
# Build context = $SOLIDITY_IBC_DIR (eureka root). The Rust compile is the
# slow part — ~5–15 min cold cache, ~30s warm — so this is idempotent: skip
# entirely if the tagged image is already present.
build_proof_api_image() {
  local tag="${PROOF_API_IMAGE:-besu-trio/proof-api:local}"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    log "Proof-api image $tag already built — reusing"
    return 0
  fi
  fetch_solidity_ibc
  [[ -f "$SOLIDITY_IBC_DIR/programs/relayer/Dockerfile" ]] \
    || die "Dockerfile missing at $SOLIDITY_IBC_DIR/programs/relayer/Dockerfile"
  log "Building proof-api image $tag from $SOLIDITY_IBC_DIR"
  log "  (Rust compile — first run is ~5–15 min, subsequent ~30s)"
  docker build \
    -t "$tag" \
    -f "$SOLIDITY_IBC_DIR/programs/relayer/Dockerfile" \
    "$SOLIDITY_IBC_DIR" \
    || die "docker build of proof-api image failed"
  log "Proof-api image built: $tag"
}

# ─── Postgres + DB migrations ────────────────────────────────────────────────
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

# Fetch the cosmos/ibc-relayer source at $OPERATOR_IMAGE's tag (cached on
# disk under ibc/ibc-relayer-<tag>/), then run migrate/migrate up against the
# relayer DB. Idempotent — migrate up is a no-op if the schema is current.
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
    # `tar -xzf` lays the archive out as ibc-relayer-<sha>/; rename to
    # ibc-relayer-<tag>/ so subsequent runs find the cache.
    [[ "$extracted" == "$src_dir" ]] || mv "$extracted" "$src_dir"
  fi
  [[ -d "$src_dir/db/migrations" ]] \
    || die "Migrations dir not present in fetched source: $src_dir/db/migrations"

  log "Running DB migrations..."
  docker run --rm --network "${COMPOSE_PROJECT}_besu-trio-net" \
    -v "$src_dir/db/migrations":/migrations \
    migrate/migrate -path /migrations \
      -database "postgres://relayer:relayer@postgres:5432/relayer?sslmode=disable" up
  log "DB migrations complete"
}

# ─── Service bringup ─────────────────────────────────────────────────────────
# Two-step bringup: postgres + migrations have to land before the relayer
# starts, otherwise it fails to query/insert against an empty schema.
start_postgres() {
  log "Starting postgres..."
  docker compose up -d postgres
  _wait_for_postgres
}

start_other_services() {
  log "Starting 4 attestors + proof-api + relayer..."
  docker compose up -d \
    attestor-A-to-hub attestor-hub-to-A attestor-hub-to-B attestor-B-to-hub \
    proof-api relayer
}

start_ibc_services() {
  start_postgres
  run_db_migrations
  start_other_services
}

# ─── Phase 4: BesuQBFTLightClient deploy + counterparty registration ────────
#
# For each pair (A↔hub, B↔hub) we deploy two LCs and call addClient twice.
# Trust comes from QBFT validator signatures over headers + storage proofs of
# the counterparty's ICS26Router — the LC verifies them on-chain. No attestor
# is registered at the LC level (the attestors run for proof-api packet flow
# but aren't load-bearing for client trust).
#
# Per pair:
#   • LC on hub tracking SPOKE — counterparty router = SPOKE's ICS26Router.
#     Initial trusted state = SPOKE chain's current head + storage root +
#     SPOKE's QBFT validator set.
#   • LC on SPOKE tracking hub — mirror, with hub's state.
#   • Predict each side's next client ID via ICS26Router.getNextClientSeq()
#     BEFORE either addClient runs, so each side can reference the other's
#     predicted ID at registration time.
#   • addClient on hub: counterparty = SPOKE's predicted ID, lc = hub-side LC.
#   • addClient on SPOKE: counterparty = hub's predicted ID, lc = SPOKE-side LC.
#
# Persisted state (per spoke S ∈ {A, B}):
#   ${S}_LC_ADDR           — LC contract on S (tracking hub)
#   ${S}_LC_ID             — local client ID on S
#   HUB_LC_FOR_${S}_ADDR   — LC contract on hub (tracking S)
#   HUB_LC_FOR_${S}_ID     — local client ID on hub for this spoke
#
# These match the variable names generate_relayer_config consumes when
# building counterparty_chains blocks, so re-rendering after wiring populates
# the relayer config.

# Per-chain QBFT validator set. Each chain has one validator (the genesis
# extraData encodes a single address). These constants drive
# BesuQBFTLightClient's `initialTrustedValidators` argument.
A_VALIDATOR_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
HUB_VALIDATOR_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
B_VALIDATOR_ADDR="0x3C44CdDdB6a900fA2b585dd299e03d12FA4293BC"

# Trusting period (seconds) and max clock drift passed to the LC constructor.
# 1 day / 30 s are dev-friendly defaults — a real deployment would pin
# trusting period to ~validator-rotation frequency.
QBFT_LC_TRUSTING_PERIOD="${QBFT_LC_TRUSTING_PERIOD:-86400}"
QBFT_LC_MAX_CLOCK_DRIFT="${QBFT_LC_MAX_CLOCK_DRIFT:-30}"

# Echo "<height_dec> <ts_dec>" of latest block at the given EVM RPC. Falls
# back to height=1 if the chain hasn't produced any blocks yet.
_eth_head_height_ts() {
  local rpc="$1"
  local block_json
  block_json=$(curl -sf "$rpc" -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
    2>/dev/null) || die "$rpc not responsive — is the chain up?"
  local height_hex ts_hex height ts
  height_hex=$(jq -r '.result.number    // empty' <<<"$block_json")
  ts_hex=$(   jq -r '.result.timestamp // empty' <<<"$block_json")
  [[ -n "$height_hex" && -n "$ts_hex" ]] || die "Bad block response from $rpc"
  height=$(( height_hex ))
  (( height > 0 )) || height=1
  ts=$(( ts_hex ))
  (( ts > 0 )) || die "Block timestamp = 0 at $rpc"
  echo "$height $ts"
}

# Echo the 0x-prefixed bytes32 storage root of <addr> at the given RPC's
# `latest` block. Uses eth_getProof with an empty storage-key list — the
# response's .storageHash is the account's storage root.
_eth_storage_root() {
  local rpc="$1" addr="$2"
  local resp root
  resp=$(curl -sf "$rpc" -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getProof\",\"params\":[\"$addr\",[],\"latest\"],\"id\":1}" \
    2>/dev/null) || die "eth_getProof failed at $rpc for $addr"
  root=$(jq -r '.result.storageHash // empty' <<<"$resp")
  [[ "$root" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "Bad storageHash at $rpc for $addr: '$root'"
  echo "$root"
}

# Echo "client-N" where N = ICS26Router.getNextClientSeq().
_predicted_next_client_id() {
  local rpc="$1" router="$2"
  local seq
  seq=$(_cast_in_net call "$router" "getNextClientSeq()(uint256)" \
    --rpc-url "$rpc" 2>/dev/null | tr -d '[:space:]') || seq=0
  [[ "$seq" =~ ^[0-9]+$ ]] || seq=0
  echo "client-$seq"
}

# Deploy BesuQBFTLightClient against the given RPC. Echo the deployed
# contract address. Bytecode is pulled from the forge artifact produced by
# ./setup.sh contracts.
#
# Args: rpc counterparty_router init_height init_ts init_storage_root
#       counterparty_validator_addr
_deploy_qbft_lc() {
  local rpc="$1" cp_router="$2" init_height="$3" init_ts="$4" \
        init_root="$5" cp_validator="$6"
  local artifact="$SOLIDITY_IBC_DIR/out/BesuQBFTLightClient.sol/BesuQBFTLightClient.json"
  [[ -f "$artifact" ]] || die "BesuQBFTLightClient artifact missing: $artifact (re-run './setup.sh contracts')"
  local bytecode ctor_args receipt addr
  bytecode=$(jq -r '.bytecode.object' "$artifact")
  [[ -n "$bytecode" && "$bytecode" != "null" ]] || die "Empty bytecode in $artifact"
  # constructor(address ibcRouter, uint64 initHeight, uint64 initTs,
  #             bytes32 initStorageRoot, address[] initValidators,
  #             uint64 trustingPeriod, uint64 maxClockDrift, address roleManager)
  ctor_args=$(_cast_in_net abi-encode \
    "constructor(address,uint64,uint64,bytes32,address[],uint64,uint64,address)" \
    "$cp_router" "$init_height" "$init_ts" "$init_root" \
    "[$cp_validator]" "$QBFT_LC_TRUSTING_PERIOD" "$QBFT_LC_MAX_CLOCK_DRIFT" \
    "0x0000000000000000000000000000000000000000" 2>/dev/null \
    | sed 's/^0x//') || ctor_args=""
  [[ -n "$ctor_args" ]] || die "abi-encode of BesuQBFTLightClient constructor failed"
  receipt=$(_cast_in_net send \
    --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVKEY" \
    --json --create "${bytecode}${ctor_args}" 2>/dev/null) || receipt=""
  addr=$(jq -r '.contractAddress // empty' <<<"$receipt")
  [[ -n "$addr" && "$addr" != "null" ]] \
    || die "BesuQBFTLightClient deploy failed at $rpc — receipt was: $(head -c 200 <<<"$receipt")"
  echo "$addr"
}

# ICS26Router.addClient((counterpartyClientId, [0x]), lcAddr).
# The bytes[] merkle prefix is `[0x]` (one empty bytes entry) — same
# encoding the cosmos-evm demo uses for its EVM-side addClient.
_add_client() {
  local rpc="$1" router="$2" counterparty_id="$3" lc_addr="$4"
  local receipt status
  receipt=$(_cast_in_net send "$router" \
    "addClient((string,bytes[]),address)" \
    "($counterparty_id,[0x])" "$lc_addr" \
    --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVKEY" --json 2>/dev/null) || receipt=""
  status=$(jq -r '.status // empty' <<<"$receipt")
  [[ "$status" == "0x1" ]] \
    || die "ICS26Router.addClient failed at $rpc (status=$status, counterparty=$counterparty_id, lc=$lc_addr)"
}

# wire_pair <pair_label> <spoke_name>
#   pair_label: e.g. "A↔hub", used in log lines only
#   spoke_name: A | B (drives router/RPC/validator lookups)
wire_pair() {
  local pair="$1" spoke="$2"
  local spoke_rpc spoke_router spoke_validator
  local spoke_host_rpc
  case "$spoke" in
    A) spoke_rpc=http://besu-a:8545
       spoke_router="$A_ICS26_ROUTER_ADDR"
       spoke_validator="$A_VALIDATOR_ADDR"
       spoke_host_rpc="http://localhost:8545"
       ;;
    B) spoke_rpc=http://besu-b:8545
       spoke_router="$B_ICS26_ROUTER_ADDR"
       spoke_validator="$B_VALIDATOR_ADDR"
       spoke_host_rpc="http://localhost:8745"
       ;;
    *) die "wire_pair: unknown spoke '$spoke' (expected A or B)" ;;
  esac
  local hub_rpc=http://besu-hub:8545
  local hub_router="$hub_ICS26_ROUTER_ADDR"
  local hub_host_rpc="http://localhost:8645"

  # Idempotency: if both LC addresses are already persisted, skip.
  local cur_spoke_lc_addr_var="${spoke}_LC_ADDR"
  local cur_hub_lc_addr_var="HUB_LC_FOR_${spoke}_ADDR"
  if [[ -n "${!cur_spoke_lc_addr_var:-}" && -n "${!cur_hub_lc_addr_var:-}" ]]; then
    log "[$pair] LCs already wired (${!cur_spoke_lc_addr_var}, ${!cur_hub_lc_addr_var}) — skipping"
    return 0
  fi

  log "[$pair] Wiring BesuQBFTLightClients..."

  local spoke_height spoke_ts hub_height hub_ts
  read -r spoke_height spoke_ts < <(_eth_head_height_ts "$spoke_host_rpc")
  read -r hub_height   hub_ts   < <(_eth_head_height_ts "$hub_host_rpc")
  log "  $spoke head: $spoke_height (ts=$spoke_ts)   hub head: $hub_height (ts=$hub_ts)"

  local spoke_storage_root hub_storage_root
  spoke_storage_root=$(_eth_storage_root "$spoke_host_rpc" "$spoke_router")
  hub_storage_root=$(  _eth_storage_root "$hub_host_rpc"   "$hub_router")
  log "  $spoke router storageRoot: $spoke_storage_root"
  log "  hub router storageRoot:    $hub_storage_root"

  local spoke_predicted hub_predicted
  spoke_predicted=$(_predicted_next_client_id "$spoke_rpc" "$spoke_router")
  hub_predicted=$(  _predicted_next_client_id "$hub_rpc"   "$hub_router")
  log "  Predicted IDs: $spoke=$spoke_predicted, hub=$hub_predicted"

  log "  Deploying hub-side LC (tracking $spoke, validator=$spoke_validator)..."
  local hub_side_lc spoke_side_lc
  hub_side_lc=$(_deploy_qbft_lc "$hub_rpc" "$spoke_router" \
    "$spoke_height" "$spoke_ts" "$spoke_storage_root" "$spoke_validator")
  log "    → $hub_side_lc"

  log "  Deploying $spoke-side LC (tracking hub, validator=$HUB_VALIDATOR_ADDR)..."
  spoke_side_lc=$(_deploy_qbft_lc "$spoke_rpc" "$hub_router" \
    "$hub_height" "$hub_ts" "$hub_storage_root" "$HUB_VALIDATOR_ADDR")
  log "    → $spoke_side_lc"

  log "  hub.addClient(counterparty=$spoke_predicted, lc=$hub_side_lc)"
  _add_client "$hub_rpc" "$hub_router" "$spoke_predicted" "$hub_side_lc"

  log "  $spoke.addClient(counterparty=$hub_predicted, lc=$spoke_side_lc)"
  _add_client "$spoke_rpc" "$spoke_router" "$hub_predicted" "$spoke_side_lc"

  _state_set "${spoke}_LC_ADDR"          "$spoke_side_lc"
  _state_set "${spoke}_LC_ID"            "$spoke_predicted"
  _state_set "HUB_LC_FOR_${spoke}_ADDR"  "$hub_side_lc"
  _state_set "HUB_LC_FOR_${spoke}_ID"    "$hub_predicted"

  log "[$pair] Wired: $spoke($spoke_predicted) ↔ hub($hub_predicted)"
}

# ─── Phase 5: IFT transfers (A↔hub, hub↔B) ──────────────────────────────────
#
# MinimalDeploy puts ICS26Router + ICS27GMP + TestIFT on each chain but does
# NOT deploy the per-direction `IIFTSendCallConstructor`. For EVM↔EVM
# transfers we deploy `EVMIFTSendCallConstructor` (stateless, no ctor args)
# on each chain, then `TestIFT.registerIFTBridge` on each side wires:
#
#   <client_id_local>  →  (counterparty_TestIFT_addr_string, evm_ift_ctor)
#
# `iftMint` on the destination compares the registered string against
# accountId.sender (which ICS27GMP records in checksummed hex), so we
# normalise the counterparty TestIFT address to checksum form before
# registering. Initial supply is minted on the source via TestIFT.mint
# (deployer is owner per MinimalDeploy).
#
# Persisted (per chain X ∈ {A, hub, B}):
#   ${X}_EVM_IFT_CTOR_ADDR — the EVMIFTSendCallConstructor on X

# Deploy a stateless EVMIFTSendCallConstructor at the given RPC. Echoes addr.
_deploy_evm_ift_ctor() {
  local rpc="$1"
  local artifact="$SOLIDITY_IBC_DIR/out/EVMIFTSendCallConstructor.sol/EVMIFTSendCallConstructor.json"
  [[ -f "$artifact" ]] || die "EVMIFTSendCallConstructor artifact missing: $artifact"
  local bytecode receipt addr
  bytecode=$(jq -r '.bytecode.object' "$artifact")
  [[ -n "$bytecode" && "$bytecode" != "null" ]] || die "Empty bytecode in $artifact"
  receipt=$(_cast_in_net send \
    --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVKEY" \
    --json --create "$bytecode" 2>/dev/null) || receipt=""
  addr=$(jq -r '.contractAddress // empty' <<<"$receipt")
  [[ -n "$addr" && "$addr" != "null" ]] \
    || die "EVMIFTSendCallConstructor deploy failed at $rpc"
  echo "$addr"
}

# Ensure all 3 chains have an EVMIFTSendCallConstructor, persisting the
# address as ${name}_EVM_IFT_CTOR_ADDR. Idempotent.
ensure_evm_ift_ctors() {
  fetch_solidity_ibc
  local entries=( "A:http://besu-a:8545" "hub:http://besu-hub:8545" "B:http://besu-b:8545" )
  local entry name rpc var addr
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"; rpc="${entry#*:}"
    var="${name}_EVM_IFT_CTOR_ADDR"
    if [[ -n "${!var:-}" ]]; then
      log "[$name] EVMIFTSendCallConstructor already at ${!var} — skipping"
      continue
    fi
    log "[$name] Deploying EVMIFTSendCallConstructor..."
    addr=$(_deploy_evm_ift_ctor "$rpc")
    log "    → $addr"
    _state_set "$var" "$addr"
    eval "${var}=\"\$addr\""  # also visible to the rest of this run
  done
}

# Read the uint256 IFT balance of a holder. Echoes 0 on parse failure.
_get_ift_balance() {
  local rpc="$1" ift="$2" holder="$3"
  local raw
  raw=$(_cast_in_net call "$ift" "balanceOf(address)(uint256)" "$holder" \
    --rpc-url "$rpc" 2>/dev/null | tr -d '[:space:]') || raw=""
  if [[ -z "$raw" ]]; then echo 0; return; fi
  # cast may print balances as `1000 [1e3]` — strip suffix.
  echo "${raw%% *}"
}

# Mint enough IFT to bring holder's balance up to <amount>. Idempotent.
# Caller (deployer) is the TestIFT owner (per MinimalDeploy.initialize).
_ensure_ift_balance() {
  local rpc="$1" ift="$2" amount="$3" holder="$4"
  local cur
  cur=$(_get_ift_balance "$rpc" "$ift" "$holder")
  cur="${cur:-0}"
  if (( cur >= amount )); then
    log "    Holder $holder already has $cur IFT (≥ $amount) — no mint needed"
    return 0
  fi
  local need=$(( amount - cur ))
  log "    Minting $need IFT to $holder (current=$cur)..."
  local receipt status
  receipt=$(_cast_in_net send "$ift" "mint(address,uint256)" "$holder" "$need" \
    --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVKEY" --json 2>/dev/null) || receipt=""
  status=$(jq -r '.status // empty' <<<"$receipt")
  [[ "$status" == "0x1" ]] || die "TestIFT.mint failed at $rpc (receipt: $(head -c 200 <<<"$receipt"))"
}

# Echo an address in EIP-55 checksummed form.
_to_checksum_addr() {
  _cast_in_net --to-checksum-address "$1" 2>/dev/null | tr -d '[:space:]'
}

# Register an IFT bridge entry on the source TestIFT. Idempotent — checks
# getIFTBridge first (which reverts if not registered).
_ensure_ift_bridge() {
  local rpc="$1" ift="$2" client_id="$3" cp_ift="$4" ctor="$5"
  if _cast_in_net call "$ift" "getIFTBridge(string)((string,string,address))" "$client_id" \
       --rpc-url "$rpc" >/dev/null 2>&1; then
    log "    IFT bridge for clientId=$client_id already registered — skipping"
    return 0
  fi
  log "    Registering IFT bridge: clientId=$client_id, cp=$cp_ift, ctor=$ctor"
  local receipt status
  receipt=$(_cast_in_net send "$ift" \
    "registerIFTBridge(string,string,address)" "$client_id" "$cp_ift" "$ctor" \
    --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVKEY" --json 2>/dev/null) || receipt=""
  status=$(jq -r '.status // empty' <<<"$receipt")
  [[ "$status" == "0x1" ]] || die "TestIFT.registerIFTBridge failed at $rpc (receipt: $(head -c 200 <<<"$receipt"))"
}

# Submit a tx hash to the Go relayer's gRPC Relay API. Retries 3× before
# warning. The relayer container exposes :3000 inside the docker network.
_relay_via_grpc() {
  local tx_hash="$1" chain_id="$2"
  log "  Submitting tx $tx_hash (chain $chain_id) to relayer:3000..."
  local attempt resp
  for attempt in 1 2 3; do
    resp=$(docker run --rm --network "${COMPOSE_PROJECT}_besu-trio-net" \
      fullstorydev/grpcurl:latest -plaintext \
      -d "{\"tx_hash\":\"${tx_hash}\",\"chain_id\":\"${chain_id}\"}" \
      relayer:3000 skip.relayer.RelayerApiService/Relay 2>/dev/null) || resp=""
    if [[ -n "$resp" ]]; then
      log "    Relay accepted (attempt $attempt/3)"
      return 0
    fi
    (( attempt < 3 )) && { log "    Relay not ready — retrying in 10s"; sleep 10; }
  done
  warn "    Relay submission failed after 3 attempts. Check: docker compose logs relayer"
  return 1
}

# Poll dst IFT balance until it differs from baseline.
_wait_for_ift_balance_change() {
  local rpc="$1" ift="$2" holder="$3" baseline="$4"
  local max="${5:-180}" step="${6:-5}" elapsed=0 now
  log "  Waiting for relay to deliver (up to ${max}s)..."
  while (( elapsed < max )); do
    sleep "$step"; (( elapsed += step ))
    now=$(_get_ift_balance "$rpc" "$ift" "$holder")
    now="${now:-0}"
    if [[ "$now" != "$baseline" ]]; then
      log "    Balance changed at ${elapsed}s: $baseline → $now"
      return 0
    fi
  done
  warn "    No balance change after ${max}s. Check: docker compose logs relayer proof-api"
  return 1
}

# Resolve per-chain config from a name in {A, hub, B}. Sets these globals:
#   _CHAIN_RPC, _CHAIN_IFT, _CHAIN_CTOR, _CHAIN_ID
_resolve_chain() {
  case "$1" in
    A)   _CHAIN_RPC=http://besu-a:8545
         _CHAIN_IFT="$A_IFT_CONTRACT_ADDR"
         _CHAIN_CTOR="$A_EVM_IFT_CTOR_ADDR"
         _CHAIN_ID=41001 ;;
    hub) _CHAIN_RPC=http://besu-hub:8545
         _CHAIN_IFT="$hub_IFT_CONTRACT_ADDR"
         _CHAIN_CTOR="$hub_EVM_IFT_CTOR_ADDR"
         _CHAIN_ID=41000 ;;
    B)   _CHAIN_RPC=http://besu-b:8545
         _CHAIN_IFT="$B_IFT_CONTRACT_ADDR"
         _CHAIN_CTOR="$B_EVM_IFT_CTOR_ADDR"
         _CHAIN_ID=41002 ;;
    *)   die "_resolve_chain: unknown chain '$1' (expected A | hub | B)" ;;
  esac
}

# Resolve src's local IBC client ID for a given (src, dst). Only hub-spoke
# pairs are valid; A↔B has no direct LC.
_resolve_lc_id() {
  local src="$1" dst="$2"
  if [[ "$src" == "hub" ]]; then
    case "$dst" in
      A) echo "$HUB_LC_FOR_A_ID" ;;
      B) echo "$HUB_LC_FOR_B_ID" ;;
      *) die "no LC: hub→$dst" ;;
    esac
  elif [[ "$dst" == "hub" ]]; then
    case "$src" in
      A) echo "$A_LC_ID" ;;
      B) echo "$B_LC_ID" ;;
      *) die "no LC: $src→hub" ;;
    esac
  else
    die "transfer must involve hub (no direct $src↔$dst pair)"
  fi
}

# transfer_ift <src> <dst> <amount>
#   src/dst ∈ {A, hub, B}; one of them must be hub.
transfer_ift() {
  local src="$1" dst="$2" amount="$3"

  fetch_solidity_ibc
  ensure_evm_ift_ctors

  _resolve_chain "$src"
  local src_rpc="$_CHAIN_RPC" src_ift="$_CHAIN_IFT" src_ctor="$_CHAIN_CTOR" \
        src_chain_id="$_CHAIN_ID"
  _resolve_chain "$dst"
  local dst_rpc="$_CHAIN_RPC" dst_ift="$_CHAIN_IFT" dst_ctor="$_CHAIN_CTOR" \
        dst_chain_id="$_CHAIN_ID"

  local src_lc_id dst_lc_id
  src_lc_id=$(_resolve_lc_id "$src" "$dst")
  dst_lc_id=$(_resolve_lc_id "$dst" "$src")
  [[ -n "$src_lc_id" ]] || die "Source LC ID missing — run './setup.sh wire' first"
  [[ -n "$dst_lc_id" ]] || die "Destination LC ID missing — run './setup.sh wire' first"
  [[ -n "$src_ctor"  ]] || die "Source EVM IFT ctor missing for $src"
  [[ -n "$dst_ctor"  ]] || die "Destination EVM IFT ctor missing for $dst"

  local src_ift_cs dst_ift_cs
  src_ift_cs=$(_to_checksum_addr "$src_ift")
  dst_ift_cs=$(_to_checksum_addr "$dst_ift")

  log "╔══ Transfer $src → $dst ══════════════════════════════════════════════════"
  log "  src TestIFT       : $src_ift  (chain-id $src_chain_id)"
  log "  src clientId      : $src_lc_id"
  log "  src EVM IFT ctor  : $src_ctor"
  log "  dst TestIFT       : $dst_ift  (chain-id $dst_chain_id)"
  log "  dst clientId      : $dst_lc_id"
  log "  dst EVM IFT ctor  : $dst_ctor"
  log "  sender / receiver : $DEPLOYER_ADDR"
  log "  amount            : $amount"

  # Register bridges on BOTH sides. iftMint on the destination looks up
  # bridge[accountId.clientId] (= dst_lc_id) and verifies that
  # bridge.counterpartyIFTAddress == accountId.sender (the source TestIFT,
  # checksummed by ICS27GMP). Without the dst-side entry the inbound packet
  # delivers but the app-layer mint reverts → COMPLETE_WITH_WRITE_ACK_ERROR.
  log "  ── Pre-flight: bridge (src + dst) + balance ────────────────────────"
  _ensure_ift_bridge "$src_rpc" "$src_ift" "$src_lc_id" "$dst_ift_cs" "$src_ctor"
  _ensure_ift_bridge "$dst_rpc" "$dst_ift" "$dst_lc_id" "$src_ift_cs" "$dst_ctor"
  _ensure_ift_balance "$src_rpc" "$src_ift" "$amount" "$DEPLOYER_ADDR"

  local before_dst
  before_dst=$(_get_ift_balance "$dst_rpc" "$dst_ift" "$DEPLOYER_ADDR")
  log "  Before — dst balance($DEPLOYER_ADDR) = $before_dst"

  local timeout_ts=$(( $(date +%s) + 1200 ))
  log "  ── Calling iftTransfer ──────────────────────────────────────────────"
  local tx_out tx_hash
  tx_out=$(_cast_in_net send "$src_ift" \
    "iftTransfer(string,string,uint256,uint64)" \
    "$src_lc_id" "$DEPLOYER_ADDR" "$amount" "$timeout_ts" \
    --rpc-url "$src_rpc" --private-key "$DEPLOYER_PRIVKEY" --json 2>/dev/null) || tx_out=""
  tx_hash=$(jq -r '.transactionHash // empty' <<<"$tx_out")
  [[ -n "$tx_hash" ]] || die "iftTransfer failed (output: $(head -c 200 <<<"$tx_out"))"
  log "  tx_hash = $tx_hash"

  _relay_via_grpc "$tx_hash" "$src_chain_id" || true
  _wait_for_ift_balance_change "$dst_rpc" "$dst_ift" "$DEPLOYER_ADDR" "$before_dst" || true

  local after_dst
  after_dst=$(_get_ift_balance "$dst_rpc" "$dst_ift" "$DEPLOYER_ADDR")
  log "  After  — dst balance($DEPLOYER_ADDR) = $after_dst (Δ = $(( after_dst - before_dst )))"
  log "╚═════════════════════════════════════════════════════════════════════════"
}

wire_all_pairs() {
  [[ -n "${A_ICS26_ROUTER_ADDR:-}"   ]] || die "A_ICS26_ROUTER_ADDR missing — run './setup.sh contracts'"
  [[ -n "${hub_ICS26_ROUTER_ADDR:-}" ]] || die "hub_ICS26_ROUTER_ADDR missing — run './setup.sh contracts'"
  [[ -n "${B_ICS26_ROUTER_ADDR:-}"   ]] || die "B_ICS26_ROUTER_ADDR missing — run './setup.sh contracts'"

  # Use the eureka source's forge artifacts. fetch_solidity_ibc just resolves
  # SOLIDITY_IBC_DIR — we expect contracts to already be built into out/.
  fetch_solidity_ibc

  wire_pair "A↔hub" A
  wire_pair "B↔hub" B
}
