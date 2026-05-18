# Step 1: Start the Chains

This page covers the two chains used in the demo. It walks you through what each one is, which modules the Cosmos chain needs for IBC v2 and IFT support, and what happens when you run the following command in the demo.

```bash
./setup.sh chains
```

Everything else in the tutorial depends on both chains being up and producing blocks before it runs.

## Cosmos: sandbox-ledger

The Cosmos chain in this demo is [sandbox-ledger](https://github.com/cosmos/sandbox-ledger), a Cosmos SDK chain built specifically for IBC v2 interoperability. It runs as a single-validator proof-of-authority (POA) chain using CometBFT consensus.

The chain includes standard Cosmos SDK modules plus the IBC-specific modules required for IFT transfers.

These are the standard Cosmos modules for the sandbox-ledger chain used in this demo:

| Module | Package | Purpose |
| --- | --- | --- |
| [`auth`](https://github.com/cosmos/cosmos-sdk/tree/main/x/auth), [`bank`](https://github.com/cosmos/cosmos-sdk/tree/main/x/bank) | `cosmos-sdk` | Account management and token transfers |
| [`gov`](https://github.com/cosmos/cosmos-sdk/tree/main/x/gov), [`upgrade`](https://github.com/cosmos/cosmos-sdk/tree/main/x/upgrade) | `cosmos-sdk` | On-chain governance and coordinated upgrades |
| [`poa`](https://github.com/cosmos/cosmos-sdk/tree/main/enterprise/poa) | `cosmos-sdk/enterprise/poa` | Proof-of-authority validator set management, replaces staking/distribution/slashing/mint |
| [`x/vm`](https://github.com/cosmos/evm/tree/main/x/vm), [`x/feemarket`](https://github.com/cosmos/evm/tree/main/x/feemarket), [`x/erc20`](https://github.com/cosmos/evm/tree/main/x/erc20) | `cosmos/evm` | EVM execution layer, ETH JSON-RPC, and ERC-20 token conversion |

The following are the IBC modules required for Cosmos-to-EVM IFT transfers that are included in the ledger-sandbox chain:

| Module | Package | Purpose |
| --- | --- | --- |
| [`ibc`](https://github.com/cosmos/ibc-go/tree/main/modules/core) (core) | `ibc-go/v11` | Core IBC packet routing |
| [`transfer`](https://github.com/cosmos/ibc-go/tree/main/modules/apps/transfer) (v1 + v2) | `ibc-go/v11` | Standard IBC token transfers |
| [`callbacks`](https://github.com/cosmos/ibc-go/tree/main/modules/apps/callbacks) (v1 + v2) | `ibc-go/v11` | Ack and timeout callbacks for transfer and GMP packets |
| [`27-gmp`](https://github.com/cosmos/ibc-go/tree/main/modules/apps/27-gmp) | `ibc-go/v11` | ICS-27 General Message Passing — carries cross-chain mint and burn instructions |
| [`attestations`](https://github.com/cosmos/ibc-go/tree/main/modules/light-clients/attestations) light client | `ibc-go/v11` | The only light client type registered on this chain — verifies packets via quorum-signed ECDSA attestations rather than Tendermint headers |
| [`tokenfactory`](https://github.com/cosmos/ibc-go/tree/prototype-ift-tokenfactory/modules/apps/prototypes/tokenfactory) | `ibc-go/v11` | Permissionless `factory/<creator>/<subdenom>` token creation with admin-gated mint and burn |
| [`ift`](https://github.com/cosmos/ibc-go/tree/prototype-ift-tokenfactory/modules/apps/prototypes/ift) | `ibc-go/v11` | The IFT bridge module — pairs a tokenfactory denom with a counterparty IFT contract and handles cross-chain burn/mint |

> **Note:** The `tokenfactory` and `ift` Cosmos modules are reference implementations and should be tested throughly before integrating into production. The IFT Solidity contracts on the EVM side are enterprise-ready.

### EVM: Hyperledger Besu

The EVM chain is a single-validator [Hyperledger Besu](https://github.com/hyperledger/besu) node running QBFT consensus. Unlike the Cosmos side, the EVM chain requires no custom chain-level modules: the IBC stack is deployed as Solidity contracts on top of a standard EVM node.

The demo uses:
- Chain ID: `32382`
- Block period: 2 seconds
- Consensus: QBFT (single-validator, no peer discovery)
- Funded account: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (This is a well-known Hardhat test key. Do not use this with real funds)

Besu is configured via [`evm/besu.toml`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/evm/besu.toml) and [`evm/el-genesis.json`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/evm/el-genesis.json). The genesis file encodes the single QBFT validator in the `extraData` field and sets all EVM hardfork blocks to 0 (Cancun-compatible from genesis).

## What `./setup.sh chains` does

### Cosmos initialization

The [`lib/chains.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/lib/chains.sh) script runs inside the sandbox-ledger container to initialize the chain, then patches the genesis before starting:

1. Creates the host config directories (`cosmos/local/config/`, `cosmos/local/keyring-test/`) so the bind mounts in `docker-compose.yml` resolve correctly.
2. Copies the customized [`app.toml`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/cosmos/app.toml) and [`config.toml`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/cosmos/config.toml) from `cosmos/` into the config directory.
3. Runs `sandboxd init` to generate the initial genesis and key files.
4. Adds a `validator` key using `secp256k1` (not `eth_secp256k1` as the relayer requires standard Cosmos key derivation).
5. Adds a `relayer` key and funds both accounts in genesis.
6. Reads the CometBFT consensus pubkey from `priv_validator_key.json` and injects it into the POA validator set in genesis via [`patch-genesis.jq`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/cosmos/patch-genesis.jq). POA requires at least one validator in genesis or it rejects on startup.
7. Patches genesis denoms and sets the IFT module authority to the validator address.
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

For a real integration the chains are already running. What matters is that the Cosmos chain has all the IBC modules listed in the [table above](#cosmos-sandbox-ledger) installed and wired.

When wiring the keepers in `app.go`, the initialization order is fixed: `TokenFactoryKeeper` must be created before `GMPKeeper`, and both must exist before `IFTKeeper`, since the IFT keeper takes the other two as dependencies.

The IBC v2 port routing is set in [`app/app.go`](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go):

- [`gmpport`](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go#L549) routes to the GMP module, wrapped in callbacks-v2 middleware so the IFT keeper receives ack and timeout callbacks.
- The [`transfer` port](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go#L507) routes through transfer-v2 and erc20-v2 middleware.

Because this chain registers only the `attestations` light client, it cannot open an IBC connection to a standard Tendermint chain via `07-tendermint`. Every counterparty must support attestation-based verification.

You can refer to [PR #1](https://github.com/cosmos/sandbox-ledger/pull/1/files#diff-d1a13e056897040ff4a79d865527c9964974cd376af3293d25ac045df8c6fa50) in the sandbox-ledger repo as a reference of the changes needed to add IBC v2 and IFT support to an existing Cosmos SDK chain.

The full wiring, including keeper initialization, module manager registration, and begin/end blocker ordering, is in [`app/app.go`](https://github.com/cosmos/sandbox-ledger/blob/main/app/app.go).

Below is a reference of the main changes:

```diff
@@ imports @@
+    "github.com/cosmos/ibc-go/v11/modules/apps/prototypes/ift"
+    iftkeeper "github.com/cosmos/ibc-go/v11/modules/apps/prototypes/ift/keeper"
+    ifttypes "github.com/cosmos/ibc-go/v11/modules/apps/prototypes/ift/types"
+    "github.com/cosmos/ibc-go/v11/modules/apps/prototypes/tokenfactory"
+    tokenfactorykeeper "github.com/cosmos/ibc-go/v11/modules/apps/prototypes/tokenfactory/keeper"
+    tokenfactorytypes "github.com/cosmos/ibc-go/v11/modules/apps/prototypes/tokenfactory/types"
+    gmp "github.com/cosmos/ibc-go/v11/modules/apps/27-gmp"
+    gmpkeeper "github.com/cosmos/ibc-go/v11/modules/apps/27-gmp/keeper"
+    gmptypes "github.com/cosmos/ibc-go/v11/modules/apps/27-gmp/types"
+    ibccallbacksv2 "github.com/cosmos/ibc-go/v11/modules/apps/callbacks/v2"
-    ibctm "github.com/cosmos/ibc-go/v11/modules/light-clients/07-tendermint"
+    ibcattestations "github.com/cosmos/ibc-go/v11/modules/light-clients/attestations"

@@ maccPerms @@
+    tokenfactorytypes.ModuleName: {authtypes.Minter, authtypes.Burner},
+    gmptypes.ModuleName:          nil,
+    ifttypes.ModuleName:          nil,

@@ SandboxApp struct @@
+    GMPKeeper          *gmpkeeper.Keeper
+    TokenFactoryKeeper tokenfactorykeeper.Keeper
+    IFTKeeper          iftkeeper.Keeper

@@ store keys @@
-    ibcexported.StoreKey, ibctransfertypes.StoreKey,
+    ibcexported.StoreKey, ibctransfertypes.StoreKey, gmptypes.StoreKey,
+    tokenfactorytypes.StoreKey, ifttypes.StoreKey,

@@ light client @@
-    tmLightClientModule := ibctm.NewLightClientModule(appCodec, storeProvider)
-    clientKeeper.AddRoute(ibctm.ModuleName, &tmLightClientModule)
+    attestationsLightClientModule := ibcattestations.NewLightClientModule(appCodec, storeProvider)
+    clientKeeper.AddRoute(ibcattestations.ModuleName, &attestationsLightClientModule)

@@ keeper construction (order matters) @@
+    app.GMPKeeper = gmpkeeper.NewKeeper(appCodec, ..., app.AccountKeeper, app.MsgServiceRouter(), govAddr)
+    app.TokenFactoryKeeper = tokenfactorykeeper.NewKeeper(appCodec, ..., app.AccountKeeper, app.BankKeeper)
+    app.IFTKeeper = iftkeeper.NewKeeper(appCodec, ..., &app.TokenFactoryKeeper, app.GMPKeeper, ...)
+    cbGMPModule := ibccallbacksv2.NewIBCMiddleware(gmp.NewIBCModule(app.GMPKeeper), ..., &app.IFTKeeper, ...)
+    ibcRouterV2.AddRoute(gmptypes.PortID, cbGMPModule)

@@ module manager @@
+    gmp.NewAppModule(app.GMPKeeper),
-    ibctm.NewAppModule(tmLightClientModule),
+    ibcattestations.NewAppModule(attestationsLightClientModule),
+    tokenfactory.NewAppModule(appCodec, app.TokenFactoryKeeper, app.AccountKeeper, app.BankKeeper),
+    ift.NewAppModule(appCodec, app.IFTKeeper),

@@ begin/end blockers and genesis order @@
+    gmptypes.ModuleName,
+    tokenfactorytypes.ModuleName,
+    ifttypes.ModuleName,

@@ DefaultGenesis — EVM bank denom metadata @@
+    var bankGen banktypes.GenesisState
+    app.appCodec.MustUnmarshalJSON(genesis[banktypes.ModuleName], &bankGen)
+    bankGen.DenomMetadata = append(bankGen.DenomMetadata, EVMBankDenomMetadata(evmGenState.Params.EvmDenom))
+    genesis[banktypes.ModuleName] = app.appCodec.MustMarshalJSON(&bankGen)
```

On the EVM side, no chain modifications are needed. Any EVM-compatible node works: the IBC stack for EVM is entirely at the contract layer, which is covered in the next step.
