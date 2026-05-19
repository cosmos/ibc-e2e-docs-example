# Step 4: Configure and Start the Relayer and Proof API

This step starts two services: the relayer ([cosmos/ibc-relayer](https://github.com/cosmos/ibc-relayer)) and the Proof API ([cosmos/solidity-ibc-eureka/programs/relayer](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/relayer)). Both need configs rendered from templates. The relayer also needs a funded signing key on both chains and a Postgres database for packet state.

Run [`setup.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/setup.sh):

```bash
./setup.sh relayer
```

## Relayer

The relayer delivers IBC packets between chains. For each packet, it submits a `RecvPacket` transaction to the destination chain to deliver it, or a `MsgTimeout` transaction to the source chain if the packet expires before delivery. It is request-driven: a client submits a source transaction hash, the relayer identifies the packets created by that transaction by reading IBC events from the chain, queries the Proof API for attestation proofs, and submits the relay transaction.

The relayer has three components: a gRPC API server (used to trigger relays and track packet status), a Postgres database (packet state persistence), and a core relay dispatcher (monitors the database and processes relay jobs).

## Proof API

The Proof API aggregates attestor signatures into relay-ready proofs. When the relayer needs a proof for a packet, it queries the Proof API, which collects signatures from the relevant attestor, verifies the quorum threshold is met, and returns a proof bundle.

The Proof API is configured with two directional modules: `cosmos_to_eth` and `eth_to_cosmos`. Each module queries the attestor watching its source chain — `cosmos_to_eth` queries the Cosmos attestor, and `eth_to_cosmos` queries the EVM attestor.

## What the relayer script does

1. **Resolve the relayer wallet**: reads the relayer's bech32 address from the Cosmos keyring. This address is used in the Proof API config so the proof API can scope proof queries to this signer.
2. **Render the relayer config**: exports the Cosmos private key and renders `keys.json` and `config.yml` from templates.
3. **Render the Proof API config**: renders `relayer.json` from its template.
4. **Start Postgres and run migrations**: waits for the database to be ready, then runs schema migrations.
5. **Start the relayer and Proof API**.

> The relayer config is rendered here without `counterparty_chains` mappings. These are added in the `wire` step once both client IDs are known, and the relayer is restarted at that point.

## Relayer key setup

The relayer signs transactions on both chains and needs funded accounts on each.

In the demo, the relayer reuses the Cosmos validator key. The key is already in the Cosmos keyring, and the script reads its bech32 address and exports the raw private key to write into `keys.json`.

For a production deployment, you'll need to create a dedicated relayer key on each chain and fund it with enough gas to cover relay transactions:

- **Cosmos side**: the relayer submits `MsgRecvPacket`, `MsgAcknowledgement`, and `MsgTimeout` transactions. Fund the account with the chain's fee denom.
- **EVM side**: the relayer calls `recvPacket`, `ackPacket`, and `timeoutPacket` on the `ICS26Router` contract. Fund the account with the chain's native token (ETH or equivalent).

## Configuration

### Relayer

```yaml
postgres:
  hostname: postgres
  port: "5432"
  database: relayer

signing:
  keys_path: "/home/nonroot/config/local/keys.json"

relayer_api:
  address: "0.0.0.0:3000"       # gRPC — used by clients to trigger relays and check status

metrics:
  prometheus_address: "0.0.0.0:9100"   # Prometheus scrape endpoint

ibcv2_proof_api:
  grpc_address: "<PROOF_API_GRPC_ADDR>"
  grpc_tls_enabled: false

chains:
  cosmos:
    chain_name: cosmos
    chain_id: "<COSMOS_CHAIN_ID>"
    type: cosmos
    cosmos:
      rpc: "<COMETBFT_RPC_ENDPOINT>"
      grpc: "<COSMOS_GRPC_ENDPOINT>"
      address_prefix: "<BECH32_PREFIX>"
      ibcv2_tx_fee_denom: "<FEE_DENOM>"
      ibcv2_tx_fee_amount: 5000
    supported_bridges:
      - ibcv2
    ibcv2:
      counterparty_chains: {}   # filled in during the wire step

  besu:
    chain_name: besu
    chain_id: "<EVM_CHAIN_ID>"
    type: evm
    evm:
      rpc: "<EVM_JSON_RPC_ENDPOINT>"
      contracts:
        ics_26_router_address: "<ICS26_ROUTER_ADDR>"   # from the deploy step
    supported_bridges:
      - ibcv2
    ibcv2:
      finality_offset: 0         # see Applying this to your own setup
      counterparty_chains: {}    # filled in during the wire step
```

The signing keys file (`keys.json`) maps chain IDs to private keys:

```json
{
  "<EVM_CHAIN_ID>":    {"private_key": "<EVM_PRIVATE_KEY_HEX>"},
  "<COSMOS_CHAIN_ID>": {"private_key": "<COSMOS_PRIVATE_KEY_HEX>"}
}
```

For EVM chains the key is a hex-encoded ECDSA private key. For Cosmos chains it is a hex-encoded secp256k1 private key.

### Proof API


```json
{
  "server": {"log_level": "info", "address": "0.0.0.0", "port": 9090},
  "modules": [
    {
      "name": "cosmos_to_eth",
      "src_chain": "<COSMOS_CHAIN_ID>",
      "dst_chain": "<EVM_CHAIN_ID>",
      "config": {
        "tm_rpc_url": "<COMETBFT_RPC_ENDPOINT>",
        "ics26_address": "<ICS26_ROUTER_ADDR>",
        "eth_rpc_url": "<EVM_JSON_RPC_ENDPOINT>",
        "signer_address": "<RELAYER_ADDRESS>",
        "mode": {"attested": {
          "attestor": {
            "quorum_threshold": 1,
            "attestor_endpoints": ["<COSMOS_ATTESTOR_GRPC_ENDPOINT>"],
            "attestor_query_timeout_ms": 10000
          }
        }}
      }
    },
    {
      "name": "eth_to_cosmos",
      "src_chain": "<EVM_CHAIN_ID>",
      "dst_chain": "<COSMOS_CHAIN_ID>",
      "config": {
        "tm_rpc_url": "<COMETBFT_RPC_ENDPOINT>",
        "ics26_address": "<ICS26_ROUTER_ADDR>",
        "eth_rpc_url": "<EVM_JSON_RPC_ENDPOINT>",
        "signer_address": "<RELAYER_ADDRESS>",
        "mode": {"attested": {
          "attestor": {
            "quorum_threshold": 1,
            "attestor_endpoints": ["<EVM_ATTESTOR_GRPC_ENDPOINT>"],
            "attestor_query_timeout_ms": 10000
          }
        }}
      }
    }
  ]
}
```

Each entry in `modules` is a directional routing unit: it handles one transfer direction and knows which attestor to query for that direction's source chain.

Each module's `attestor_endpoints` points to the attestor watching that module's **source** chain. The `cosmos_to_eth` module queries the Cosmos attestor for Cosmos state; `eth_to_cosmos` queries the EVM attestor for EVM state.

### Config field reference

#### Relayer

| Field | Description |
| --- | --- |
| `postgres.*` | Database connection — host, port, database name. Credentials from `POSTGRES_USER` / `POSTGRES_PASSWORD` env vars (default: `relayer`/`relayer`) |
| `signing.keys_path` | Path to the local signing keys JSON file |
| `relayer_api.address` | gRPC address for the relay and status API |
| `metrics.prometheus_address` | Prometheus scrape endpoint |
| `ibcv2_proof_api.grpc_address` | gRPC address of the Proof API |
| `chains.<name>.type` | `cosmos` or `evm` |
| `chains.<name>.cosmos.rpc` | CometBFT RPC endpoint |
| `chains.<name>.cosmos.grpc` | Cosmos gRPC endpoint |
| `chains.<name>.cosmos.address_prefix` | Bech32 prefix (e.g. `cosmos`) |
| `chains.<name>.cosmos.ibcv2_tx_fee_denom` | Fee denom for relay transactions |
| `chains.<name>.cosmos.ibcv2_tx_fee_amount` | Fixed fee amount (in smallest denom units) |
| `chains.<name>.evm.rpc` | EVM JSON-RPC endpoint |
| `chains.<name>.evm.contracts.ics_26_router_address` | `ICS26Router` contract address |
| `chains.<name>.ibcv2.counterparty_chains` | Maps client IDs on this chain to counterparty chain IDs — determines which connections are relayed |
| `chains.<name>.ibcv2.finality_offset` | Blocks to subtract from latest when determining finality; omit to use the chain's native finality mechanism |

#### Proof API

| Field | Description |
| --- | --- |
| `modules[].name` | Module identifier (`cosmos_to_eth` or `eth_to_cosmos`) |
| `modules[].src_chain` | Source chain ID for this direction |
| `modules[].dst_chain` | Destination chain ID for this direction |
| `config.tm_rpc_url` | CometBFT RPC endpoint |
| `config.ics26_address` | `ICS26Router` contract address |
| `config.eth_rpc_url` | EVM JSON-RPC endpoint |
| `config.signer_address` | Cosmos address used for message construction metadata |
| `config.mode.attested.attestor.attestor_endpoints` | List of attestor gRPC endpoints for the source chain |
| `config.mode.attested.attestor.quorum_threshold` | Number of attestor signatures required |
| `config.mode.attested.attestor.attestor_query_timeout_ms` | Timeout for attestor gRPC calls |

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
