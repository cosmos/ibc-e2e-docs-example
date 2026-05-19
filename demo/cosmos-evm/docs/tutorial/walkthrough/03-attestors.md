# Step 3: Configure and Start Attestors

An attestor is a lightweight, stateless service ([cosmos/ibc-attestor](https://github.com/cosmos/ibc-attestor)) that watches a chain and signs statements about its state on demand. When the Proof API needs to prove that a packet was committed on a chain, it queries the attestor for a signed attestation over the relevant block state. The attestor does not store or push data; it reads the chain and signs only when asked.

In this demo, two instances run per deployment: one watching the EVM chain and one watching the Cosmos chain. Each attestor signs with a secp256k1 key; the corresponding Ethereum address is registered with the attestation light clients on both chains (this happens in a later step). When a packet arrives, the light client recovers the signer address from the attestation signature and checks it against its registered set. 

In this demo, both instances share a single signing key so only one address needs to be registered. In production, you would run multiple attestor operators with distinct keys and configure the light clients with a quorum threshold greater than one.

> The attestor address must exist before the `create-clients` step because it is baked into both light clients at creation time.

Run the following:

```bash
./setup.sh attestors
```

The logic for this command is in [`lib/ibc.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/lib/ibc.sh)


## What it does

### Key generation

If no keystore exists, the script generates a new secp256k1 signing key and stores it at `ibc/local/.ibc-attestor/ibc-attestor-keystore`. The Ethereum address can be retrieved at any time:

```bash
ibc_attestor key show
```

This address is what gets registered with both light clients in the `create-clients` step. In this demo, the same keystore is mounted into both attestor containers so both sign with the same address.

### Config rendering

The script renders two config files from templates:

- [`ibc/attestor-config.toml.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/attestor-config.toml.tmpl) into `ibc/local/attestor-config.toml` for the EVM watcher
- [`ibc/attestor-cosmos-config.toml.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/attestor-cosmos-config.toml.tmpl) into `ibc/local/attestor-cosmos-config.toml` for the Cosmos watcher

The EVM config requires `ICS26_ROUTER_ADDR` from the deploy step.

### Starting the containers

```
attestor        — ibc_attestor server --config /config/attestor-config.toml --chain-type evm --signer-type local
attestor-cosmos — ibc_attestor server --config /config/attestor-cosmos-config.toml --chain-type cosmos --signer-type local
```

Both containers mount the keystore from `ibc/local/.ibc-attestor/` and expose their gRPC server on port `9101`.

## Configuration

### EVM attestor

```toml
[server]
listen_addr = "0.0.0.0:9101"   # gRPC — queried by the Proof API
health_addr = "0.0.0.0:9102"   # HTTP health check

[adapter]
url = "<EVM_JSON_RPC_ENDPOINT>"
router_address = "<ICS26_ROUTER_ADDR>"   # ICS26Router address from the deploy step
finality_offset = 0                       # set to N to attest latest-N instead of the finalized tag

[signer]
keystore_path = "/config/.ibc-attestor/ibc-attestor-keystore"
```

### Cosmos attestor

The Cosmos adapter only requires the CometBFT RPC endpoint.

```toml
[server]
listen_addr = "0.0.0.0:9101"
health_addr = "0.0.0.0:9102"

[adapter]
url = "<COMETBFT_RPC_ENDPOINT>"

[signer]
keystore_path = "/config/.ibc-attestor/ibc-attestor-keystore"
```

### Config field reference

| Field | Required | Description |
| --- | --- | --- |
| `server.listen_addr` | Yes | gRPC address the Proof API connects to |
| `server.health_addr` | Yes | HTTP health endpoint (`GET /healthz`) |
| `adapter.url` | Yes | Chain RPC endpoint: EVM JSON-RPC or CometBFT RPC |
| `adapter.router_address` | EVM only | Address of the `ICS26Router` contract from the deploy step |
| `adapter.finality_offset` | No | Blocks to subtract from latest when determining finality (see below) |
| `signer.keystore_path` | Yes | Path to the keystore file or its parent directory |

## Production deployment

For production deployment (remote signers, key rotation, multi-instance quorum, finality configuration, and health checking), see the [IBC Attestor deployment guide](../../attestor/deploy-attestor.md).

<!-- todo: fix link above -->

## Next steps

The next step configures and starts the relayer and Proof API, which query these attestor instances to collect signatures for packet proofs.

<!-- todo: add link above -->
