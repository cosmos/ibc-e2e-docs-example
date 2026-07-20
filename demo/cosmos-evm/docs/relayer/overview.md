# IBC v2 Relayer

IBC v2 Relayer is a relaying service for the IBC v2 Protocol. The relayer supports interoperating between a Cosmos-based chain and major EVM networks.

## Relaying Sequence

![Relaying Sequence](./relaying-sequence.png)

<!-- todo: add image -->

1. A client submits a transfer transaction to the source chain.
2. The client calls the relayer's Relay API with the resulting transaction hash.
3. The relayer queries the source chain for the packet events emitted by that transaction.
4. The relayer calls the Proof API to generate an attestation proof for the packet.
5. The relayer submits a relay transaction to the destination chain.
6. The destination chain emits a `WriteAcknowledgement` event. The relayer fetches a proof from the Proof API and submits the acknowledgement back to the source chain to finalize the packet lifecycle.


## Supported Features

- **Multi-chain EVM support** — compatible with Ethereum, Base, Optimism, Arbitrum, Polygon, and other EVM-compatible networks.
- **Request-driven relaying** — packets are relayed on demand when a client submits a transaction hash. The relayer does not scan chains continuously.
- **Automatic retry** — failed relay transactions are retried automatically, covering common failure modes including re-orgs, out-of-gas, inadequate gas price, propagation failures, and node-specific validation errors.
- **Transaction Tracking API** — clients can poll the relayer's Status API with a transaction hash to follow a packet through its full lifecycle: pending, delivered, acknowledged, or timed out.
- **Remote signing** — the relayer can delegate transaction signing to an external gRPC signer service, keeping private keys isolated from the relayer process.
- **Batching** — recv, ack, and timeout packets can be accumulated and submitted in batches, with configurable size and timeout thresholds to tune delivery latency vs. cost.
- **Address blacklisting** — specific sender or receiver addresses (e.g. OFAC-sanctioned addresses) can be blocked from having their packets relayed.
- **Gas cost tracking** — transaction costs are tracked per chain and exposed as Prometheus metrics.

## Design

![Design](./relayer-design.png)

The relayer has three main components:

- **gRPC API server** — the public interface for clients. Accepts `Relay` requests (a source transaction hash to relay) and `Status` requests (current state of a packet). When a relay request arrives, the server looks up the packet events on-chain and writes the resulting packet records to the database.
- **Postgres database** — the shared state store. Packet records are written by the API server and read by the relay dispatcher. The database persists packet state across restarts, so in-flight packets survive process failures.
- **Relay dispatcher** — the core processing loop. Monitors the database for packets that need action, queries the Proof API to generate attestation proofs, submits relay transactions to the destination chain, and updates packet state as each step completes.
