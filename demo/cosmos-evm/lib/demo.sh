#!/usr/bin/env bash
# User-story demos: transfers, tracking, failure/retry, observability.

# ERC20.balanceOf(address) → decimal string. Direct JSON-RPC eth_call via
# curl — symmetric with how Cosmos balances are read, and ~100× faster than
# `cast_in_net call …` in tight polling loops because there's no foundry
# container spawn per iteration.
# Echoes "0" if the call fails or the address has no bytecode.
evm_erc20_balance() {
  local contract="$1" addr="$2"
  local padded="000000000000000000000000${addr#0x}"
  local hex
  hex=$(curl -sf -X POST http://localhost:8545 \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$contract\",\"data\":\"0x70a08231${padded}\"},\"latest\"],\"id\":1}" 2>/dev/null \
        | jq -r '.result // empty' 2>/dev/null) || hex=""
  [[ -n "$hex" && "$hex" != "null" ]] || { echo "0"; return; }
  printf '%d\n' "$hex" 2>/dev/null || echo "0"
}

# Snapshot bank + ERC20 balances; results in _SNAP_COSMOS_BAL / _SNAP_EVM_BAL.
# Args: <label> <c_addr> <c_denom> <c_side> <e_contract> <e_addr> <e_side> <e_denom_display> [c_prev] [e_prev]
snapshot_transfer_balances() {
  local label="$1" c_addr="$2" c_denom="$3" c_side="$4"
  local e_contract="$5" e_addr="$6" e_side="$7" e_denom="$8"
  local c_prev="${9:-}" e_prev="${10:-}"

  _SNAP_COSMOS_BAL=""; _SNAP_EVM_BAL=""
  log "  ── Balances ${label} ──────────────────────────────────────────────"

  if [[ -n "$c_denom" && -n "$c_addr" ]]; then
    _SNAP_COSMOS_BAL=$(curl -sf \
      "http://localhost:1317/cosmos/bank/v1beta1/balances/${c_addr}/by_denom?denom=${c_denom}" 2>/dev/null \
      | jq -r '.balance.amount // "0"' 2>/dev/null || echo "0")
    if [[ -n "$c_prev" ]]; then
      log "  ${c_side} ($c_denom): $_SNAP_COSMOS_BAL  (was $c_prev)"
    else
      log "  ${c_side} ($c_denom): $_SNAP_COSMOS_BAL"
    fi
  fi

  if [[ "$e_contract" =~ ^0x[0-9a-fA-F]{40}$ && \
        "$e_contract" != "0x0000000000000000000000000000000000000000" ]]; then
    _SNAP_EVM_BAL=$(evm_erc20_balance "$e_contract" "$e_addr")
    if [[ -n "$e_prev" ]]; then
      log "  ${e_side} (${e_denom}): $_SNAP_EVM_BAL  (was $e_prev)"
    else
      log "  ${e_side} (${e_denom}): $_SNAP_EVM_BAL"
    fi
  elif [[ -n "$e_denom" ]]; then
    log "  ${e_side} (IBC ERC20 not yet minted for ${e_denom})"
  fi
}

# Send an IBC transfer via wfchain's IFT module. wfchain has no standard
# ibc-transfer module — `tx ift transfer` is the only path.
# Args: <source_client> <recipient> <amount-with-denom> <timeout_ts>
# Signature: tx ift transfer [denom] [client_id] [receiver] [amount] [timeout_timestamp]
# Echoes broadcast JSON on success; returns 1 on failure.
cosmos_ibc_transfer() {
  local source_client="$1" recipient="$2" amount="$3" timeout_ts="$4"

  # Split "<num><denom>" into the two positional args `tx ift transfer` expects.
  local amt_num amt_denom
  [[ "$amount" =~ ^([0-9]+)(.+)$ ]] || return 1
  amt_num="${BASH_REMATCH[1]}"
  amt_denom="${BASH_REMATCH[2]}"

  # Capture both streams so we can filter docker compose's "Container …
  # Creating/Created" status lines; callers jq-parse the output and they'd
  # otherwise choke.
  local out
  out=$(run_in cosmos "$COSMOS_BINARY" tx ift transfer \
    "$amt_denom" "$source_client" "$recipient" "$amt_num" "$timeout_ts" \
    --from validator --keyring-backend test --home "$COSMOS_HOME" \
    --chain-id "$COSMOS_CHAIN_ID" --node "tcp://cosmos:26657" \
    --gas 300000 --gas-prices 0.025uatom \
    --yes --output json 2>&1) || return 1
  echo "$out" | grep -E '^\{' | tail -1
}

# Submit a tx hash to the relayer's Relay API, retrying up to 3 times.
submit_to_relayer() {
  local tx_hash="$1" chain_id="$2"
  log "  ── Submitting tx to relayer (Relay API) ─────────────────────────────"
  local attempt relay_resp
  for attempt in 1 2 3; do
    relay_resp=$(grpc_call \
      -d "{\"tx_hash\":\"${tx_hash}\",\"chain_id\":\"${chain_id}\"}" \
      relayer:3000 skip.relayer.RelayerApiService/Relay 2>/dev/null) || relay_resp=""
    if [[ -n "$relay_resp" ]]; then
      log "  Relay accepted (attempt ${attempt}/3)"
      return 0
    fi
    (( attempt < 3 )) && { log "  Relayer not ready yet (attempt ${attempt}/3) — retrying in 10s"; sleep 10; }
  done
  warn "  Relay call failed after 3 attempts — check: docker compose logs relayer"
  return 1
}

# Resolve the IBC ERC20 contract for a denom path. Echoes empty if the denom
# isn't IFT — this demo is IFT-only, so any other path is unexpected.
resolve_ibc_erc20_addr() {
  local path="$1"
  if [[ -n "${COSMOS_IFT_DENOM:-}" && -n "${IFT_CONTRACT_ADDR:-}" && \
        "$path" == */"$COSMOS_IFT_DENOM" ]]; then
    echo "$IFT_CONTRACT_ADDR"
  fi
}

evm_erc20_approve() {
  local token="$1" spender="$2" amount="$3"
  cast_in_net send "$token" "approve(address,uint256)" "$spender" "$amount" \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" >/dev/null 2>&1 || true
}

# Poll a Cosmos bank balance until it differs from the baseline.
wait_for_cosmos_relay() {
  local addr="$1" denom="$2" before="$3" max="${4:-150}" step="${5:-5}"
  log "  ── Waiting for relay (up to ${max}s) ────────────────────────────────"
  local start elapsed=0
  start=$(date +%s)
  while (( elapsed < max )); do
    sleep "$step"; (( elapsed += step ))
    [[ -z "$denom" ]] && continue
    local now
    now=$(curl -sf "http://localhost:1317/cosmos/bank/v1beta1/balances/${addr}/by_denom?denom=${denom}" 2>/dev/null \
      | jq -r '.balance.amount // "0"' 2>/dev/null || echo "$before")
    if [[ "$now" != "$before" ]]; then
      log "  Cosmos balance changed at ${elapsed}s — relay complete in $(( $(date +%s) - start ))s"
      return 0
    fi
  done
  warn "  Relay not confirmed within ${max}s — check: docker compose logs relayer"
  return 1
}

# Print copy-pasteable curl commands so the user can re-query balances on
# both sides from their own shell — Cosmos REST + Besu JSON-RPC eth_call.
# Args: <cosmos_addr> <cosmos_denom> <evm_erc20> <evm_addr>
print_balance_curl_cmds() {
  local cosmos_addr="$1" cosmos_denom="$2" evm_erc20="$3" evm_addr="$4"
  log "  ── Re-query balances ────────────────────────────────────────────────"
  log "  Cosmos (bank REST):"
  log "    curl -s 'http://localhost:1317/cosmos/bank/v1beta1/balances/${cosmos_addr}/by_denom?denom=${cosmos_denom}' | jq .balance"
  if [[ -n "$evm_erc20" ]]; then
    # ERC20.balanceOf(address) calldata: selector 0x70a08231 || left-padded 32-byte address.
    local padded="000000000000000000000000${evm_addr#0x}"
    log "  EVM (ERC20.balanceOf via eth_call; result is hex, pipe to printf for decimal):"
    log "    curl -s -X POST http://localhost:8545 -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${evm_erc20}\",\"data\":\"0x70a08231${padded}\"},\"latest\"],\"id\":1}' | jq -r .result | xargs printf '%d' \\n"
  fi
}

demo_cosmos_to_evm_transfer() {
  log "╔══ Demo: Cosmos → EVM IFT transfer ══════════════════════════════════════╗"

  # Parse the tracking denom out of DEMO_TRANSFER_AMOUNT (e.g. "1000000uatom" →
  # "uatom"). If we tracked $COSMOS_IFT_DENOM instead of the sent denom, the
  # poll loop below would watch a balance that never changes and time out
  # after 90s even though the relay actually completed.
  [[ "$DEMO_TRANSFER_AMOUNT" =~ ^([0-9]+)(.+)$ ]] || \
    die "DEMO_TRANSFER_AMOUNT='$DEMO_TRANSFER_AMOUNT' must be <number><denom>"
  local amount="${BASH_REMATCH[1]}" denom="${BASH_REMATCH[2]}"

  local sender
  sender=$(run_in cosmos "$COSMOS_BINARY" keys show validator -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')

  log "  from   : $sender (Cosmos)"
  log "  to     : $DEMO_ETH_RECIPIENT (EVM)"
  log "  denom  : $denom   amount: $amount"
  log "  client : $COSMOS_WASM_CLIENT_ID"

  # Lazy mint: if transferring the IFT denom and the sender's balance is
  # short, mint just-in-time. Keeps setup free of auto-mints — tokens only
  # appear when a transfer actually needs them.
  if [[ -n "${COSMOS_IFT_DENOM:-}" && "$denom" == "$COSMOS_IFT_DENOM" ]]; then
    local sender_bal
    sender_bal=$(curl -sf "http://localhost:1317/cosmos/bank/v1beta1/balances/${sender}/by_denom?denom=${denom}" 2>/dev/null \
      | jq -r '.balance.amount // "0"' 2>/dev/null || echo "0")
    if (( sender_bal < amount )); then
      log "  Sender holds $sender_bal $denom < $amount required — minting JIT..."
      mint_ift_tokens
    fi
  fi

  # For IFT-routed packets the balance lands in TestIFT (IFT_CONTRACT_ADDR);
  # resolve_ibc_erc20_addr returns it via the COSMOS_IFT_DENOM shortcut.
  local path="transfer/${EVM_COSMOS_CLIENT_ID}/${denom}"
  local erc20
  erc20=$(resolve_ibc_erc20_addr "$path") || erc20=""

  snapshot_transfer_balances "before" \
    "$sender" "$denom" "Cosmos sender  " \
    "$erc20" "$DEMO_ETH_RECIPIENT" "EVM receiver  " "$path"
  local c_before="$_SNAP_COSMOS_BAL" e_before="$_SNAP_EVM_BAL"
  print_balance_curl_cmds "$sender" "$denom" "$erc20" "$DEMO_ETH_RECIPIENT"

  local timeout_ts=$(( $(date +%s) + 600 ))
  local tx_out
  tx_out=$(cosmos_ibc_transfer \
    "$COSMOS_WASM_CLIENT_ID" "$DEMO_ETH_RECIPIENT" "$DEMO_TRANSFER_AMOUNT" "$timeout_ts") || tx_out=""
  if [[ -z "$tx_out" ]]; then
    warn "Failed to prepare/broadcast transfer tx — check: docker compose logs cosmos"
    log "╚═════════════════════════════════════════════════════════════════════════╝"
    return 0
  fi

  COSMOS_TO_EVM_TX_HASH=$(echo "$tx_out" | jq -r '.txhash // empty' 2>/dev/null || echo "")
  if [[ -z "$COSMOS_TO_EVM_TX_HASH" ]]; then
    warn "Transfer tx hash not found — check: docker compose logs cosmos"
    log "╚═════════════════════════════════════════════════════════════════════════╝"
    return 0
  fi
  log "  tx hash: $COSMOS_TO_EVM_TX_HASH"
  echo "COSMOS_TO_EVM_TX_HASH=$COSMOS_TO_EVM_TX_HASH" >> "$IBC_STATE_FILE"

  submit_to_relayer "$COSMOS_TO_EVM_TX_HASH" "$COSMOS_CHAIN_ID"

  # Cosmos balance changes first (packet commit), then EVM balance (relay delivery).
  log "  ── Waiting for relay (up to 120s) ────────────────────────────────────"
  local start elapsed=0 step=5 max=120 c_committed=0 relayed=0
  start=$(date +%s)
  while (( elapsed < max )); do
    sleep "$step"; (( elapsed += step ))

    if [[ $c_committed -eq 0 ]]; then
      local c_now
      c_now=$(curl -sf "http://localhost:1317/cosmos/bank/v1beta1/balances/${sender}/by_denom?denom=${denom}" 2>/dev/null \
        | jq -r '.balance.amount // "0"' 2>/dev/null || echo "$c_before")
      if [[ "$c_now" != "$c_before" ]]; then
        log "  Cosmos balance changed at ${elapsed}s — packet committed, waiting for EVM relay..."
        c_committed=1
      fi
    fi

    [[ -z "$erc20" ]] && erc20=$(resolve_ibc_erc20_addr "$path" || echo "")
    if [[ -n "$erc20" ]]; then
      local e_now
      e_now=$(evm_erc20_balance "$erc20" "$DEMO_ETH_RECIPIENT")
      if [[ "$e_now" != "$e_before" ]]; then
        log "  EVM balance changed at ${elapsed}s — relay complete in $(( $(date +%s) - start ))s"
        e_before="$e_now"; relayed=1; break
      fi
    fi
    echo -n "."
  done
  (( relayed == 0 )) && warn "EVM balance unchanged after ${max}s — relay may be delayed"

  log ""
  snapshot_transfer_balances "after" \
    "$sender" "$denom" "Cosmos sender  " \
    "$erc20" "$DEMO_ETH_RECIPIENT" "EVM receiver  " "$path" \
    "$c_before" "$e_before"
  log "╚═════════════════════════════════════════════════════════════════════════╝"
}

demo_evm_to_cosmos_transfer() {
  log "╔══ Demo: EVM → Cosmos IFT transfer ══════════════════════════════════════╗"
  [[ -n "${EVM_COSMOS_CLIENT_ID:-}" ]] || {
    warn "EVM_COSMOS_CLIENT_ID not set — run setup first"
    log "╚═════════════════════════════════════════════════════════════════════════╝"; return 0; }
  [[ -n "${IFT_CONTRACT_ADDR:-}" ]] || {
    warn "IFT_CONTRACT_ADDR not set — run setup first"
    log "╚═════════════════════════════════════════════════════════════════════════╝"; return 0; }
  [[ -n "${IFT_ICA_ADDRESS:-}" ]] || {
    warn "IFT_ICA_ADDRESS not set — register_evm_ift_bridge didn't run"
    log "╚═════════════════════════════════════════════════════════════════════════╝"; return 0; }
  [[ -n "${COSMOS_IFT_DENOM:-}" ]] || {
    warn "COSMOS_IFT_DENOM not set — run setup first"
    log "╚═════════════════════════════════════════════════════════════════════════╝"; return 0; }

  local receiver amount=1000000
  receiver=$(run_in cosmos "$COSMOS_BINARY" keys show validator -a \
    --keyring-backend test --home "$COSMOS_HOME" 2>/dev/null | tr -d '[:space:]')

  local timeout_ts=$(( $(date +%s) + 1200 ))

  log "  from   : $ETH_VALIDATOR_ADDR (EVM)"
  log "  to     : $receiver (Cosmos)"
  log "  token  : TestIFT @ $IFT_CONTRACT_ADDR"
  log "  denom  : $COSMOS_IFT_DENOM"
  log "  amount : $amount"
  log "  client : $EVM_COSMOS_CLIENT_ID"

  snapshot_transfer_balances "before" \
    "$receiver" "$COSMOS_IFT_DENOM" "Cosmos receiver" \
    "$IFT_CONTRACT_ADDR" "$ETH_VALIDATOR_ADDR" "EVM sender    " "$COSMOS_IFT_DENOM"
  local c_before="$_SNAP_COSMOS_BAL" e_before="$_SNAP_EVM_BAL"
  print_balance_curl_cmds "$receiver" "$COSMOS_IFT_DENOM" "$IFT_CONTRACT_ADDR" "$ETH_VALIDATOR_ADDR"

  # TestIFT.iftTransfer(string clientId, string receiver, uint256 amount, uint64 timeoutTimestamp)
  # Burns on EVM, wraps payload via CosmosIFTSendCallConstructor, calls
  # ICS27GMP.sendCall on port "gmpport".
  local tx_out
  tx_out=$(cast_in_net send "$IFT_CONTRACT_ADDR" \
    "iftTransfer(string,string,uint256,uint64)" \
    "$EVM_COSMOS_CLIENT_ID" "$receiver" "$amount" "$timeout_ts" \
    --rpc-url "http://besu:8545" --private-key "$ETH_VALIDATOR_PRIVKEY" --json) || tx_out=""

  EVM_TO_COSMOS_TX_HASH=$(echo "$tx_out" | jq -r '.transactionHash // empty' 2>/dev/null || echo "")
  if [[ -z "$EVM_TO_COSMOS_TX_HASH" ]]; then
    warn "TestIFT.iftTransfer failed — check Besu logs and verify"
    warn "    - TestIFT.registerIFTBridge was called (IFT_ICA_ADDRESS / IFT_CTOR_ADDR set)"
    warn "    - ETH_VALIDATOR_ADDR has an IFT balance (lazy-mint happened)"
    log "╚═════════════════════════════════════════════════════════════════════════╝"
    return 0
  fi
  log "  tx hash: $EVM_TO_COSMOS_TX_HASH"
  echo "EVM_TO_COSMOS_TX_HASH=$EVM_TO_COSMOS_TX_HASH" >> "$IBC_STATE_FILE"

  submit_to_relayer "$EVM_TO_COSMOS_TX_HASH" "$ETH_CHAIN_ID"
  wait_for_cosmos_relay "$receiver" "$COSMOS_IFT_DENOM" "$c_before"

  log ""
  snapshot_transfer_balances "after" \
    "$receiver" "$COSMOS_IFT_DENOM" "Cosmos receiver" \
    "$IFT_CONTRACT_ADDR" "$ETH_VALIDATOR_ADDR" "EVM sender    " "$COSMOS_IFT_DENOM" \
    "$c_before" "$e_before"
  log "  Watch relay: docker compose logs -f relayer"
  log "╚═════════════════════════════════════════════════════════════════════════╝"
}

demo_track_packet_status() {
  log "╔══ Demo: Track packet status via relayer API ════════════════════════════╗"

  local tx_hash chain_id
  if [[ -n "$COSMOS_TO_EVM_TX_HASH" ]]; then
    tx_hash="$COSMOS_TO_EVM_TX_HASH"; chain_id="$COSMOS_CHAIN_ID"
  elif [[ -n "$EVM_TO_COSMOS_TX_HASH" ]]; then
    tx_hash="$EVM_TO_COSMOS_TX_HASH"; chain_id="$ETH_CHAIN_ID"
  else
    warn "No transfer tx hash recorded — run demo transfers first"
    log "╚═════════════════════════════════════════════════════════════════════════╝"
    return 0
  fi

  log "  tx hash  : $tx_hash"
  log "  chain_id : $chain_id"
  log "  Relayer API (gRPC) : relayer:3000 → skip.relayer.RelayerApiService/Status"

  # EVM→Cosmos relays wait on Ethereum beacon finality (~2 epochs even on this
  # devnet) before the 08-wasm LC will accept the proof, so they routinely
  # take 2-3 minutes. Cosmos→EVM uses AttestationLightClient (no finality
  # wait) and usually settles in under 30s.
  local max=120 step=5 elapsed=0
  [[ "$chain_id" == "$ETH_CHAIN_ID" ]] && max=300
  while true; do
    local status_json
    status_json=$(grpc_call \
      -d "{\"tx_hash\":\"${tx_hash}\",\"chain_id\":\"${chain_id}\"}" \
      relayer:3000 skip.relayer.RelayerApiService/Status 2>/dev/null) || status_json=""

    if [[ -n "$status_json" ]]; then
      local state
      state=$(echo "$status_json" | jq -r '.packetStatuses[0].state // "TRANSFER_STATE_PENDING"' 2>/dev/null || echo "TRANSFER_STATE_PENDING")
      log "  State: $state"
      echo "$status_json" | jq '.'
      [[ "$state" == "TRANSFER_STATE_COMPLETE" || "$state" == "TRANSFER_STATE_FAILED" ]] && break
    else
      warn "  Status API not yet reachable — grpcurl pull may be needed on first run"
    fi

    (( elapsed += step ))
    if (( elapsed >= max )); then
      warn "Packet not yet settled after ${max}s — check: docker compose logs relayer"
      break
    fi
    sleep "$step"; echo -n "."
  done

  log "╚═════════════════════════════════════════════════════════════════════════╝"
}

demo_failure_and_retry() {
  log "╔══ Demo: Failed transfer surfaces via relayer status API ════════════════╗"
  log "  Pausing relayer so the packet cannot be relayed before it times out..."
  docker compose pause relayer 2>/dev/null || true

  local short_ts=$(( $(date +%s) + 60 ))
  local tx_out
  # Use the IFT denom so `tx ift transfer` finds a registered bridge;
  # `uatom` isn't IFT-registered and would be rejected before the timeout fires.
  tx_out=$(cosmos_ibc_transfer "$COSMOS_WASM_CLIENT_ID" "$DEMO_ETH_RECIPIENT" "1${COSMOS_IFT_DENOM:-uatom}" "$short_ts") || tx_out=""
  local tx_hash
  tx_hash=$(echo "$tx_out" | jq -r '.txhash // empty' 2>/dev/null || echo "")

  if [[ -z "$tx_hash" ]]; then
    warn "  Transfer rejected at chain level — unparseable output"
    docker compose unpause relayer 2>/dev/null || true
    log "╚═════════════════════════════════════════════════════════════════════════╝"
    return 0
  fi

  log "  Timeout transfer submitted (60s TTL) — tx: $tx_hash"
  log "  Waiting 75s for packet timeout to expire on EVM..."
  sleep 75

  log "  Resuming relayer — it will submit MsgTimeout, burning the escrowed tokens"
  docker compose unpause relayer 2>/dev/null || true

  grpc_call -d "{\"tx_hash\":\"${tx_hash}\",\"chain_id\":\"${COSMOS_CHAIN_ID}\"}" \
    relayer:3000 skip.relayer.RelayerApiService/Relay 2>/dev/null || true
  sleep 20

  log "  Querying status for timed-out packet:"
  grpc_call -d "{\"tx_hash\":\"${tx_hash}\",\"chain_id\":\"${COSMOS_CHAIN_ID}\"}" \
    relayer:3000 skip.relayer.RelayerApiService/Status 2>/dev/null | jq '.' || \
    warn "  grpcurl not yet available — check: docker compose logs relayer"

  log "╚═════════════════════════════════════════════════════════════════════════╝"
}

demo_observability() {
  log "╔══ Demo: Prometheus metrics + structured logs ═══════════════════════════╗"

  log "  Relayer health (relayer:3000/health, via ibc-net)"
  if curl_in_net -sf http://relayer:3000/health >/dev/null 2>&1; then
    log "  → SERVING"
  else
    warn "  → not reachable yet"
  fi

  log ""
  log "  Relayer Prometheus metrics (relayer:9100/metrics) — sample:"
  local metrics
  metrics=$(curl_in_net -sf http://relayer:9100/metrics 2>/dev/null) || metrics=""
  if [[ -n "$metrics" ]]; then
    local ibc_lines
    ibc_lines=$(echo "$metrics" | grep -E "^(ibc_relay|ibc_gas|ibc_transfer|go_goroutines)" | head -20)
    if [[ -n "$ibc_lines" ]]; then
      echo "$ibc_lines"
    else
      echo "$metrics" | grep -v "^#" | head -10
    fi
  else
    warn "  Prometheus metrics not reachable at relayer:9100"
  fi

  if docker compose ps attestor 2>/dev/null | grep -q "Up"; then
    log ""
    log "  Attestor (EVM watcher) — container UP"
    log "    gRPC RPC server: attestor:9101 (used by proof-api)"
    log "    HTTP health server: attestor:9102 (probing common paths…)"
    local p code health_path=""
    for p in "/healthz" "/health" "/live" "/ready" "/"; do
      code=$(curl_in_net -s -o /dev/null -w "%{http_code}" "http://attestor:9102${p}" 2>/dev/null) || code=""
      if [[ "$code" =~ ^2 ]]; then
        health_path="$p"
        log "    → SERVING at attestor:9102${p} ($code)"
        break
      fi
    done
    [[ -z "$health_path" ]] && warn "    no 2xx on /, /healthz, /health, /live, /ready — image may not expose HTTP health"
  fi

  log ""
  log "  Recent relayer logs (structured JSON — look for 'trace_id' fields):"
  docker compose logs --no-log-prefix --tail 5 relayer 2>/dev/null | head -20

  if docker compose ps attestor 2>/dev/null | grep -q "Up"; then
    log ""
    log "  Recent attestor logs (OpenTelemetry spans with trace IDs):"
    docker compose logs --no-log-prefix --tail 5 attestor 2>/dev/null | head -20
  fi

  log ""
  log "  To browse metrics from your host: publish the ports in docker-compose.yml,"
  log "  e.g. add 'ports: [\"9100:9100\"]' to relayer, then visit http://localhost:9100/metrics."
  log "  Grafana / alerting: wire relayer:9100 + attestor:9102 into your Prometheus scrape config."
  log "╚═════════════════════════════════════════════════════════════════════════╝"
}

demo_all() {
  log "╔══════════════════════════════════════════════════════════════════════════╗"
  log "║  IBC Demo — running all user story demonstrations                        ║"
  log "╚══════════════════════════════════════════════════════════════════════════╝"
  demo_cosmos_to_evm_transfer
  demo_evm_to_cosmos_transfer
  demo_track_packet_status
  demo_failure_and_retry
  demo_observability
}
