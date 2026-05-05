# ibc-e2e-docs-example

End-to-end demos for IBC v2 token transfers between Cosmos chains and EVM networks using attestation-based light clients and the IFT (Interchain Fungible Token) protocol.

## Demos

| Demo | Directory | What it shows |
|------|-----------|---------------|
| Cosmos ↔ single Besu | `demo/cosmos-evm/` | Cosmos chain ↔ single-validator QBFT EVM; attestation LCs |
| Three Besu chains | `demo/besu-trio/` | Hub-and-spoke: A ↔ hub ↔ B; QBFT light clients |

Each demo is self-contained with its own `docker-compose.yml`, `setup.sh`, and `lib/`.

## Quick Start

```bash
cd demo/cosmos-evm

# One command — full pipeline
./setup.sh

# Or step by step (good for tutorials and debugging)
./setup.sh chains           # start Cosmos + Besu
./setup.sh deploy           # deploy IBC/IFT contracts on Besu
./setup.sh attestors        # start attestor services
./setup.sh relayer          # start relayer + proof-api
./setup.sh create-clients   # create light clients on both chains
./setup.sh wire             # register counterparties + IFT bridges

./setup.sh demo cosmos-evm  # Cosmos → EVM IFT transfer
./setup.sh demo evm-cosmos  # EVM → Cosmos IFT transfer
./setup.sh demo all         # run all demos
./setup.sh status           # print endpoints and block heights
./setup.sh clean            # stop and wipe
```

See [demo/cosmos-evm/README.md](demo/cosmos-evm/README.md) for the full architecture, phase reference, and troubleshooting guide.