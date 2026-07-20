# Step 1: Start the Chains

This page covers the two chains used in the demo. It walks you through what each one is, which modules the Cosmos chain needs for IBC v2 and IFT support, and what happens when you run the following command in the demo.

```bash
./setup.sh chains
```

The logic for this command is in [`lib/chains.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/lib/chains.sh)

Everything else in the tutorial depends on both chains being up and producing blocks before it runs.

## Cosmos: sandbox-ledger

The Cosmos chain in this demo is [sandbox-ledger](https://github.com/cosmos/sandbox-ledger), a Cosmos SDK chain built specifically for IBC v2 interoperability. It runs as a single-validator proof-of-authority (POA) chain using CometBFT consensus.

### EVM: Hyperledger Besu

The EVM chain is a single-validator [Hyperledger Besu](https://github.com/hyperledger/besu) node running QBFT consensus. Unlike the Cosmos side, the EVM chain requires no custom chain-level modules: the IBC stack is deployed as Solidity contracts on top of a standard EVM node.

The demo uses:

- Chain ID: `32382`
- Block period: 2 seconds
- Consensus: QBFT (single-validator, no peer discovery)
- Funded account: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (This is a test key. Do not use this with real funds)

Besu is configured via [`evm/besu.toml`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/evm/besu.toml) and [`evm/el-genesis.json`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/evm/el-genesis.json). 

## What `./setup.sh chains` does

### Cosmos initialization

The [`lib/chains.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/lib/chains.sh) script runs inside the sandbox-ledger container to initialize the chain, then patches the genesis before starting:

1. Creates the host config directories (`cosmos/local/config/`, `cosmos/local/keyring-test/`) so the bind mounts in `docker-compose.yml` resolve correctly.
2. Runs `sandboxd init` to generate the initial genesis and key files.
3. Adds a `validator` key using `secp256k1` (not `eth_secp256k1` as the relayer requires standard Cosmos key derivation).
4. Adds a `relayer` key and funds it in genesis.
5. Reads the CometBFT consensus pubkey from `priv_validator_key.json` and injects it into the POA validator set in genesis via [`patch-genesis.jq`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/cosmos/patch-genesis.jq). POA requires at least one validator in genesis or it rejects on startup.
6. Patches genesis denoms and sets the IFT module authority to the validator address.
7. Copies the customized [`app.toml`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/cosmos/app.toml) and [`config.toml`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/cosmos/config.toml) from `cosmos/` into the config directory, overwriting the defaults written by `init`.
8. Starts the `cosmos` container.

### Besu initialization

1. Starts the `besu` container with the pre-existing `evm/el-genesis.json` and `evm/key` files.

2. Polls `http://localhost:8545` until the JSON-RPC endpoint is reachable.

### Readiness check

After both containers start, the script polls each chain until it confirms blocks are being produced, then prints the endpoints and current block heights.

```
Cosmos (sandbox)
  CometBFT RPC : http://localhost:26657
  REST API      : http://localhost:1317
  gRPC          : localhost:9090

Besu (Ethereum EL)
  JSON-RPC HTTP : http://localhost:8545
  WebSocket     : ws://localhost:8546
```

## Applying this to your own chains

For a real integration, the chains are likely already running. The Cosmos chain must have IBC modules listed in the [table above](#cosmos-sandbox-ledger) installed and wired.

When wiring the keepers in `app.go`, the initialization order is fixed: both `GMPKeeper` and `TokenFactoryKeeper` must be created before `IFTKeeper`, since the IFT keeper takes both as dependencies.

The IBC v2 port routing is set in [`app/app.go`](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go):

- [`gmpport`](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go#L549) routes to the GMP module, wrapped in callbacks-v2 middleware so the IFT keeper receives ack and timeout callbacks.
- The [`transfer` port](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go#L507) routes through transfer-v2 and erc20-v2 middleware.

You can refer to [PR #1](https://github.com/cosmos/sandbox-ledger/pull/1/files#diff-d1a13e056897040ff4a79d865527c9964974cd376af3293d25ac045df8c6fa50) in the sandbox-ledger repo as a reference of the changes needed to add IBC v2 and IFT support to an existing Cosmos SDK chain.

The full wiring, including keeper initialization, module manager registration, and begin/end blocker ordering, is in [`app/app.go`](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go).


On the EVM side, no chain modifications are needed. The IBC stack for EVM is entirely at the contract layer, which is covered in the next step.

<!-- todo: add link -->