# Step 7: Run a Transfer

With the bridge wired, the demo runs four scenarios end-to-end:

- **Cosmos → EVM**: burns IFT tokens on Cosmos and mints the equivalent ERC-20 balance on Besu.
- **EVM → Cosmos**: burns the ERC-20 on Besu and mints IFT tokens back on Cosmos.
- **Packet tracking**: polls the relayer's status API by transaction hash to show transfer state as it progresses.
- **Timeout path**: sends a packet with a short timeout while the relayer is paused, lets it expire, then resumes the relayer so it submits `MsgTimeout` and refunds the sender.

Run [`setup.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/setup.sh):

```bash
./setup.sh demo cosmos-evm   # Cosmos → EVM only
./setup.sh demo evm-cosmos   # EVM → Cosmos only
./setup.sh demo all          # all scenarios in sequence
```

## What the script does

### Cosmos → EVM transfer


1. Submit the transfer

```bash
sandboxd tx ift transfer $COSMOS_IFT_DENOM $COSMOS_CLIENT_ID $EVM_RECIPIENT $AMOUNT $TIMEOUT_TS
```

The Cosmos IFT module burns the tokens from the sender's account, wraps the transfer details into an ICS-27 GMP packet payload, and commits the packet on `gmpport`.

2. Submit to relayer

The script posts the transaction hash to the relayer's gRPC Relay API:

```
skip.relayer.RelayerApiService/Relay { tx_hash, chain_id }
```

This triggers the relayer to pick up the packet immediately rather than waiting for its next poll cycle.

3. Relay delivery

The relayer fetches a proof from the Proof API, constructs a `RecvPacket` transaction, and submits it to Besu. The ICS-27 GMP contract on the EVM side decodes the packet payload and calls `iftMint` on the `IFTAccessManaged` contract, minting ERC-20 tokens to the recipient address.

4. Balance snapshot

The script polls the Cosmos bank balance (packet commit) and the ERC-20 balance (relay delivery) in a loop and prints before/after snapshots when both change.

### EVM → Cosmos transfer

1. Submit the transfer

```
IFTAccessManaged.iftTransfer(
  clientId:         EVM_CLIENT_ID,
  receiver:         <cosmos_bech32_address>,
  amount:           1000000,
  timeoutTimestamp: <now + 1200s>
)
```

`iftTransfer` burns the ERC-20 tokens from the sender, uses the registered `CosmosIFTSendCallConstructor` to encode a `MsgIFTMint` GMP payload, and calls `ICS27GMP.sendCall` on `gmpport`. The packet is committed in the `ICS26Router`.

2. Submit to relayer

The EVM transaction hash is posted to the relayer's Relay API to trigger immediate pickup.

3. Relay delivery

The relayer fetches an attestation proof from the Proof API, submits `RecvPacket` to the Cosmos chain, and the GMP module executes the embedded `MsgIFTMint`, minting `COSMOS_IFT_DENOM` tokens to the receiver.

### Packet tracking

After either transfer, the script polls the relayer's status API with the transaction hash:

```
skip.relayer.RelayerApiService/Status { tx_hash, chain_id }
```

The response includes the current transfer state. The script polls until the state reaches `TRANSFER_STATE_COMPLETE` or `TRANSFER_STATE_FAILED` and prints the full status JSON.

Typical state progression for Cosmos → EVM:

1. `TRANSFER_STATE_PENDING` — packet committed, not yet picked up
2. `TRANSFER_STATE_RELAYED` — `RecvPacket` submitted to EVM
3. `TRANSFER_STATE_COMPLETE` — acknowledgement submitted to Cosmos

### Timeout path

1. The relayer container is paused (`docker compose pause relayer`).
2. A transfer is submitted with a 60-second timeout.
3. The script waits for the timeout to expire.
4. The relayer is resumed (`docker compose unpause relayer`).
5. The relayer sees an expired packet, fetches a timeout proof from the Proof API, and submits `MsgTimeout` to Cosmos.
6. The Cosmos IFT module refunds the sender.

The script confirms the timeout path by checking that the status response includes a non-empty `timeoutTx.txHash`.

### Observability

The script samples the following without any additional setup:

| Endpoint | Content |
| --- | --- |
| `relayer:3000/health` | Relayer gRPC health check |
| `relayer:9100/metrics` | Prometheus metrics (packet counts, relay latency) |
| `attestor:9101` | Attestor gRPC server (used by Proof API) |
| `docker compose logs relayer` | Structured JSON logs (fields: `msg`, `source_chain_id`, `tx_hash`, `state`) |
| `docker compose logs attestor` | OpenTelemetry spans (fields: `name`, `height`, `durationMs`, `status`) |

