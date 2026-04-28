#!/usr/bin/env bash
# Chain bring-up: start the 3 Besu QBFT services and wait for each RPC to
# come up. Genesis + keys are baked into chains/{A,hub,B}/ so there's no
# init step beyond docker compose up.

start_chains() {
  log "Bringing up besu-a, besu-hub, besu-b..."
  docker compose up -d besu-a besu-hub besu-b
}

wait_for_chains() {
  wait_for_rpc "besu-a"   "http://localhost:8545"
  wait_for_rpc "besu-hub" "http://localhost:8645"
  wait_for_rpc "besu-b"   "http://localhost:8745"
}

print_status() {
  local a_block hub_block b_block
  a_block=$(eth_block_number "http://localhost:8545"   2>/dev/null || echo "?")
  hub_block=$(eth_block_number "http://localhost:8645" 2>/dev/null || echo "?")
  b_block=$(eth_block_number "http://localhost:8745"   2>/dev/null || echo "?")

  log "Chain status:"
  log "  besu-a   (chain-id 41001) RPC=http://localhost:8545  WS=ws://localhost:8546  block=${a_block}"
  log "  besu-hub (chain-id 41000) RPC=http://localhost:8645  WS=ws://localhost:8646  block=${hub_block}"
  log "  besu-b   (chain-id 41002) RPC=http://localhost:8745  WS=ws://localhost:8746  block=${b_block}"
}

clean() {
  log "Stopping containers and removing volumes..."
  docker compose down -v --remove-orphans 2>/dev/null || true

  # Drop fetched sources, rendered configs, attestor keystores, and persisted
  # contract addresses so the next run starts from a clean slate. The committed
  # ibc/scripts/ tree and *.tmpl files are left alone.
  rm -rf "$IBC_DIR"/solidity-ibc-eureka-* 2>/dev/null || true
  rm -rf "$IBC_DIR"/ibc-relayer-*         2>/dev/null || true
  rm -rf "$IBC_DIR/local"                 2>/dev/null || true
  rm -f  "$IBC_DIR/state.env"             2>/dev/null || true

  log "Clean complete"
}
