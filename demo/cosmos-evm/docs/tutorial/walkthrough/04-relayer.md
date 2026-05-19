# Step 4: Configure and Start the Relayer and Proof API

This step starts two services: the relayer ([cosmos/ibc-relayer](https://github.com/cosmos/ibc-relayer)) and the Proof API ([cosmos/solidity-ibc-eureka/programs/relayer](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/relayer)). Both need configs rendered from templates. The relayer also needs a funded signing key on both chains and a Postgres database for packet state.

Run the following:

```bash
./setup.sh relayer
```

The logic for this command is in [`lib/ibc.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/lib/ibc.sh)

## Relayer

The relayer delivers IBC packets between chains. For each packet, it submits a `RecvPacket` transaction to the destination chain to deliver it, or a `MsgTimeout` transaction to the source chain if the packet expires before delivery. It is request-driven: a client submits a source transaction hash, the relayer identifies the packets created by that transaction by reading IBC events from the chain, queries the Proof API for attestation proofs, and submits the relay transaction.

The relayer has three components: a gRPC API server (used to trigger relays and track packet status), a Postgres database (packet state persistence), and a core relay dispatcher (monitors the database and processes relay jobs).

## Proof API

The Proof API aggregates attestor signatures into relay-ready proofs. When the relayer needs a proof for a packet, it queries the Proof API, which collects signatures from the relevant attestor, verifies the quorum threshold is met, and returns a proof bundle.

The Proof API is configured with two directional modules: `cosmos_to_eth` and `eth_to_cosmos`. Each module queries the attestor watching its source chain — `cosmos_to_eth` queries the Cosmos attestor, and `eth_to_cosmos` queries the EVM attestor.

## What the relayer script does

1. Resolve the relayer wallet: reads the relayer's bech32 address from the Cosmos keyring. This address is used in the Proof API config so the proof API can scope proof queries to this signer.
2. Render the relayer config: exports the Cosmos private key and renders `keys.json` and `config.yml` from templates.
3. Render the Proof API config: renders `relayer.json` from its template.
4. Start Postgres and run migrations: waits for the database to be ready, then runs schema migrations.
5. Start the relayer and Proof API.

> The relayer config is rendered here without `counterparty_chains` mappings. These are added in the `wire` step once both client IDs are known, and the relayer is restarted at that point.

## Relayer key setup

The relayer signs transactions on both chains and needs funded accounts on each.

In the demo, the relayer reuses the Cosmos validator key.

For a production deployment, you'll need to create a dedicated relayer key on each chain and fund it with enough gas to cover relay transactions:

- **Cosmos side**: the relayer submits `MsgRecvPacket`, `MsgAcknowledgement`, and `MsgTimeout` transactions. Fund the account with the chain's fee denom.
- **EVM side**: the relayer calls `recvPacket`, `ackPacket`, and `timeoutPacket` on the `ICS26Router` contract. Fund the account with the chain's native token (ETH or equivalent).

## Configuration

### Relayer

The relayer config is rendered from [`ibc/relayer-config.yml.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/relayer-config.yml.tmpl). The signing keys file is rendered from [`ibc/relayer-keys.json.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/relayer-keys.json.tmpl). For EVM chains the key is a hex-encoded ECDSA private key; for Cosmos chains it is a hex-encoded secp256k1 private key.

### Proof API

The Proof API config is rendered from [`ibc/proof-api.json.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/proof-api.json.tmpl). Each entry in `modules` is a directional routing unit that handles one transfer direction and knows which attestor to query for that direction's source chain. The `cosmos_to_eth` module queries the Cosmos attestor for Cosmos state; `eth_to_cosmos` queries the EVM attestor for EVM state.

## Applying this to your own setup

### Relayer key funding

The relayer needs sufficient gas on both chains to submit transactions continuously. The relayer exposes gas balance metrics and supports configurable alert thresholds (`signer_gas_alert_thresholds`) per chain.

### Signing

The demo uses local signing via `keys.json`. For production, the relayer supports a remote gRPC signing service that keeps private keys isolated from the relayer process:

```yaml
signing:
  grpc_address: "localhost:50052"
  cosmos_wallet_key: "my-cosmos-wallet"
  evm_wallet_key: "my-evm-wallet"
```

If `grpc_address` is set, it takes precedence over `keys_path`. See the [ibc-relayer README](https://github.com/cosmos/ibc-relayer) for the signer service proto interface.

### Finality offset

The EVM chain config supports `finality_offset`. Set it to the number of blocks to subtract from latest when the chain does not support the `finalized` block tag. The demo sets this to `0` because Besu's single-validator QBFT produces instant finality.

### counterparty_chains

The `ibcv2.counterparty_chains` field maps client IDs on a chain to their counterparty chain IDs. The relayer only relays packets for connections listed here. This field is left empty in this step and filled in during the `wire` step once both client IDs are known.

## Next steps

<!-- todo: add links -->

With the relayer and Proof API running, the next step creates the attestation light clients on both chains.
