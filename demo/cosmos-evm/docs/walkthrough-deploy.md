# Step 2: Deploy EVM Contracts

The IBC stack on the EVM side is a set of Solidity contracts deployed to Besu. This step deploys the core contracts (the IBC router, the GMP application, and the IFT token) and registers the GMP port on the router so it can route packets.

Two additional contracts are deployed in later steps: `AttestationLightClient` in `create-clients` once the attestor address is known, and `CosmosIFTSendCallConstructor` in `wire` once the client-derived account address is derived.

Run [`setup.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/setup.sh):

```bash
./setup.sh deploy
```

## What it does

The script fetches [`cosmos/solidity-ibc-eureka`](https://github.com/cosmos/solidity-ibc-eureka), installs dependencies, then runs the following inside a Foundry container on the Docker network (RPC target is `http://besu:8545` internally):

```bash
forge script scripts/MinimalDeploy.s.sol \
  --rpc-url <YOUR_EVM_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY> \
  --broadcast \
  --chain-id <YOUR_CHAIN_ID>
```

The deployer address is both the `AccessManager` admin and the relayer EOA. OpenZeppelin `AccessManager` defaults unset `restricted` functions to `ADMIN_ROLE`, which the deployer holds, so `addIBCApp`, `recvPacket`, `ackPacket`, and `timeoutPacket` all work without additional role grants. This is sufficient for a single-validator devnet; production deployments need explicit role wiring (see [Access control](#access-control) below).

See the table below for the full deploy order and constructor arguments.

## Deployed Contracts

The following steps are run by [`MinimalDeploy.s.sol`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/scripts/MinimalDeploy.s.sol) in order. Each contract's constructor or initializer depends on addresses from the steps before it.

| Step | Source | Purpose | Notes |
| --- | --- | --- | --- |
| 1. `AccessManager` | [OpenZeppelin AccessManager](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/manager/AccessManager.sol) | Role-based access control for the IBC contract suite | Deployer becomes the `ADMIN_ROLE` holder |
| 2. `ICS26Router` (ERC1967 proxy) | [contracts/ICS26Router.sol](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/ICS26Router.sol) | IBC packet hub: validates packet sequencing and timeouts, routes packets to app contracts | Initialized with the `AccessManager` address |
| 3. `ICS27Account` | [contracts/utils/ICS27Account.sol](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/utils/ICS27Account.sol) | CREATE2 proxy account used by `ICS27GMP` to derive and hold a client-derived account address | No constructor arguments |
| 4. `ICS27GMP` (ERC1967 proxy) | [contracts/ICS27GMP.sol](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/ICS27GMP.sol) | ICS-27 General Message Passing app: parses GMP payloads and dispatches calls to target contracts | Initialized with the `ICS26Router`, `ICS27Account`, and `AccessManager` addresses |
| 5. `ICS26Router.addIBCApp` | - | Registers `ICS27GMP` as the handler for `gmpport` | Must be called before any packets can be routed to GMP |
| 6. `TestIFT` (ERC-20, ERC1967 proxy) | [test/solidity-ibc/mocks/TestIFT.sol](https://github.com/cosmos/solidity-ibc-eureka/blob/main/test/solidity-ibc/mocks/TestIFT.sol) | IFT token: `iftTransfer` burns tokens and emits an IBC packet; `iftMint` mints on packet receive | Initialized with the deployer address, token name/symbol, and the `ICS27GMP` address |

Two more contracts are deployed in later steps:

| Contract | Source | Deployed in | Role |
| --- | --- | --- | --- |
| `AttestationLightClient` | [contracts/light-clients/attestation/AttestationLightClient.sol](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/light-clients/attestation/AttestationLightClient.sol) | `create-clients` | Verifies Cosmos packet state via m-of-n attestor ECDSA signatures; registered with `ICS26Router.addClient` |
| `CosmosIFTSendCallConstructor` | [contracts/utils/CosmosIFTSendCallConstructor.sol](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/utils/CosmosIFTSendCallConstructor.sol) | `wire` | Encodes the `MsgIFTMint` GMP payload for EVM-to-Cosmos transfers |

### Resolving the IFT Contract Address

After the Forge script completes, the script reads the broadcast artifacts (`broadcast/<script>/<chain-id>/run-latest.json`) to extract the deployed `TestIFT` proxy address and persists it as `IFT_CONTRACT_ADDR` in `ibc/state.env`. This address is used in the `wire` step to register the EVM contract as the counterparty for the Cosmos-side `uift` denom.

### Deployed Address Usage

The three core addresses produced by this step are used throughout the rest of the setup:

- `ICS26Router`: referenced by the attestor config (`router_address`), relayer config (`ics_26_router_address`), and proof API config (`ics26_address`)
- `ICS27GMP`: passed as an initializer argument to `TestIFT` at deploy time
- `TestIFT`: registered in the `wire` step as the EVM counterparty for the Cosmos `uift` denom

## Applying this to your own chain

### Deploy order

The order is fixed because each contract's initializer takes addresses from contracts deployed before it. The table above lists the required sequence. The key constraints are:

- `AccessManager` first: both `ICS26Router` and `ICS27GMP` take its address in `initialize`
- `ICS27Account` before `ICS27GMP`: GMP's initializer takes the account implementation address
- `addIBCApp` before `TestIFT`: packets cannot be routed to GMP until the port is registered
- `TestIFT` last: initialized with the `ICS27GMP` address

### Access control

The demo uses the deployer address as both the AccessManager admin and the relayer EOA. For production, grant roles explicitly:

- The relayer address should hold a role that covers only `recvPacket`, `ackPacket`, and `timeoutPacket` on `ICS26Router`.
- The admin should be a multisig or governance contract, not a deployer EOA.
- Use `setTargetFunctionRole` and `setRoles` on the `AccessManager` to configure this before transferring ownership.

### IFT contract

The demo deploys `TestIFT`, a minimal implementation used for testing. For production, extend [`IFTBaseUpgradeable`](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/utils/IFTBaseUpgradeable.sol) and implement `_onlyAuthority()` with your access control logic. The full interface is defined in [`IIFT.sol`](https://github.com/cosmos/solidity-ibc-eureka/blob/main/contracts/interfaces/IIFT.sol).

The ERC-20 name and symbol should match your Cosmos denom for consistency. The demo uses `"Test uift"` / `"UIFT"` to match the Cosmos-side `uift` denom.
