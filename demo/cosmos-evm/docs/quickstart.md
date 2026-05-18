# Quickstart

This page gets the demo running end-to-end with a single command. For a step-by-step breakdown of what each phase does, see the walkthrough.

## Prerequisites

- [Docker and Docker Compose](https://docs.docker.com/get-started/get-docker/)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge` and `cast`) and [bun](https://bun.sh/docs/installation)
- [jq](https://jqlang.org/download/)

## Run the demo

Clone the repository and navigate to the demo directory:

```bash
git clone <repo-url>
cd demo/cosmos-evm
```

Run the full setup:

```bash
./setup.sh
```

This starts the Cosmos and Besu chains, deploys the IBC contracts, configures and starts the attestors, relayer, and Proof API, creates attestation light clients on both chains, and wires the IFT bridge. Once setup is complete, it runs the full demo suite:

- Cosmos to EVM transfer: burns IFT tokens on the Cosmos chain and mints the equivalent ERC20 balance on Besu.
- EVM to Cosmos transfer: burns the ERC20 on Besu and mints IFT tokens back on the Cosmos chain.
- Packet tracking: polls the relayer API by transaction hash and prints the transfer state as it progresses.
- Timeout path: sends a packet with a short timeout, pauses the relayer to let it expire, then resumes so the relayer can submit a `MsgTimeout`. The source chain refunds the sender.
- Observability: samples live Prometheus metrics from the relayer and prints recent log output from the relayer and attestors.

The full setup takes a few minutes. Progress is printed to the terminal and logged to `logs/`.

## What runs

Once complete, these containers are running:

| Container | Role |
| --- | --- |
| `cosmos` | Cosmos sandbox chain (CometBFT RPC on port 26657) |
| `besu` | Hyperledger Besu EVM node (JSON-RPC on port 8545) |
| `attestor` | Watches Besu, signs EVM state for the Cosmos light client |
| `attestor-cosmos` | Watches Cosmos, signs Cosmos state for the EVM light client |
| `proof-api` | Aggregates attestor signatures into relay-ready proofs |
| `relayer` | Submits RecvPacket and MsgTimeout transactions on both chains |
| `postgres` | Relayer packet state persistence |

## All Commands

```bash
./setup.sh            # full setup: chains + IBC + demos
./setup.sh chains     # start Cosmos and Besu only (skip IBC setup)
./setup.sh ibc        # run all IBC setup steps below on already-running chains

./setup.sh deploy           # Step 1/5: fetch solidity-ibc-eureka + deploy IBC/IFT contracts on Besu
./setup.sh attestors        # Step 2/5: generate keystore + configs, start attestors
./setup.sh relayer          # Step 3/5: copy keys, render configs, run DB migrations, start relayer + proof-api
./setup.sh create-clients   # Step 4/5: create attestation light clients on both chains
./setup.sh wire             # Step 5/5: register counterparties + IFT bridges + finalise relayer config

./setup.sh transfer          # Cosmos ↔ EVM transfers in both directions
./setup.sh demo all          # all demos in sequence
./setup.sh demo cosmos-evm   # Cosmos → EVM transfer
./setup.sh demo evm-cosmos   # EVM → Cosmos transfer
./setup.sh demo track        # packet status tracking
./setup.sh demo failure      # timeout and refund path
./setup.sh demo observe      # Prometheus metrics and logs

./setup.sh status     # print RPC endpoints and current block heights
./setup.sh clean      # stop all containers and wipe state
./setup.sh help       # list all commands and configurable environment variables
```

The next section of this tutorial walks you through each step of the demo, showing you how chains are set up, what each service does, and what to look for at each stage.

<!-- todo: add list of walkthrough sections and links -->