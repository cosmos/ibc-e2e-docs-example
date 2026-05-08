# ibc-e2e-docs-example

End-to-end demos for IBC v2 token transfers between Cosmos chains and EVM networks using attestation-based light clients and the IFT (Interchain Fungible Token) protocol.

## Demos

| Demo | Directory | What it shows |
|------|-----------|---------------|
| Cosmos ↔ single Besu | `demo/cosmos-evm/` | Cosmos chain ↔ single-validator QBFT EVM; attestation LCs |

Each demo is self-contained with its own `docker-compose.yml`, `setup.sh`, and `lib/`.

## Quick Start

```bash
cd demo/cosmos-evm

# Print all available commands and environment variables
./setup.sh help

# Full pipeline: init chains, deploy contracts, configure IBC
./setup.sh

# Or run the top-level phases on their own
./setup.sh chains           # init + start chains only (skip IBC)
./setup.sh ibc              # set up IBC on already-running chains (all steps)

# Or run the IBC steps individually (idempotent — safe to re-run)
./setup.sh deploy           # Step 1/5: fetch source + deploy IBC/IFT contracts on Besu
./setup.sh attestors        # Step 2/5: generate keystores/configs + start attestor services
./setup.sh relayer          # Step 3/5: copy keys, render configs, run DB migrations,
                            #           start relayer + proof-api
./setup.sh create-clients   # Step 4/5: create attestation light clients on both chains
./setup.sh wire             # Step 5/5: register counterparties + IFT bridges +
                            #           finalise relayer config

# Demos
./setup.sh transfer         # cosmos↔evm IFT transfers (alias for `demo transfer`)
./setup.sh demo cosmos-evm  # Cosmos → EVM IFT transfer
./setup.sh demo evm-cosmos  # EVM → Cosmos IFT transfer
./setup.sh demo track       # packet status tracking
./setup.sh demo failure     # timeout + retry flow
./setup.sh demo observe     # Prometheus metrics + logs
./setup.sh demo all         # run all demos (default)

# Inspection / cleanup
./setup.sh status           # print RPC endpoints and block heights
./setup.sh clean            # stop containers and remove all data
```

Optional environment variables:

| Variable | Purpose |
|----------|---------|
| `SOLIDITY_IBC_DIR` | Local checkout; otherwise auto-downloaded (`SOLIDITY_IBC_TAG`) |
| `ICS26_ROUTER_ADDR` | Skip forge deploy (use a pre-deployed router) |
| `EVM_ATTESTATION_LC_ADDR` | Skip AttestationLightClient deploy |

See [demo/cosmos-evm/README.md](demo/cosmos-evm/README.md) for the full architecture, phase reference, and troubleshooting guide.