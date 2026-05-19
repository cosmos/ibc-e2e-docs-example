---
title: "Deployment"
description: "How to deploy and operate the IBC Attestor service"
---

## Overview

The IBC Attestor is a stateless gRPC service that produces cryptographic attestations of blockchain state for use in IBC v2 cross-chain communication. It connects to a chain via an adapter (EVM, Cosmos, or Solana) and signs state at requested heights using either a local keystore or a remote signing service.

Each attestor instance handles a single chain type. In production, multiple instances per chain are typical (each with a distinct signing key) to support m-of-n quorum verification by the light client.

## Components

### 1. IBC Attestor

The core attestation service. Exposes a gRPC API on port `8090` (configurable) and a metrics endpoint on port `9000`.

**Image**: `ghcr.io/cosmos/ibc-attestor:<version>` — see [releases](https://github.com/cosmos/ibc-attestor/releases) for available tags
**Binary**: `ibc_attestor`

### 2. Signer Service (external dependency)

The attestor requires a secp256k1 signing key. Two deployment modes are supported:

- **Local signer** — key is stored in an encrypted keystore file on disk, read directly by the attestor process
- **Remote signer** — the attestor delegates signing to an external gRPC signer service (e.g. `platform-signer`) over the network

For production deployments, the remote signer with KMS-backed keys is recommended. For simple or development deployments, a local keystore is sufficient.

### 3. Chain RPC Endpoint (external dependency)

Each attestor instance requires a live RPC endpoint for the chain it is attesting:

| Chain Type | Required Endpoint |
|------------|------------------|
| EVM | JSON-RPC HTTP endpoint (e.g. Alchemy, Infura, or self-hosted `geth`) |
| Cosmos | Tendermint RPC HTTP endpoint |
| Solana | Solana JSON-RPC HTTP endpoint |

## Configuration

The attestor is configured via a TOML file passed with `--config`. The chain type and signer mode are passed as CLI flags.

### Full configuration reference

```toml
[server]
listen_addr = "0.0.0.0:8090"   # gRPC — queried by the Proof API
health_addr = "0.0.0.0:9000"   # HTTP health check (GET /healthz) and metrics (GET /metrics)

[adapter]
# RPC endpoint of the chain being attested.
# EVM: HTTP or HTTPS JSON-RPC URL
# Cosmos: Tendermint RPC URL (http or https)
# Solana: Solana RPC URL
url = "https://your-rpc-endpoint"

# EVM only: address of the deployed ICS-26 router contract on the chain.
router_address = "0x..."

# EVM only (optional): number of blocks to subtract from `latest` to
# determine the finalized height. If omitted, the `finalized` block tag
# is used directly (requires the RPC to support it).
# Use 0 for local/test networks where `finalized` may lag indefinitely.
finality_offset = 64

[signer]
# --- Local signer (--signer-type local) ---
# Path to the keystore file or directory. Supports ~ expansion.
keystore_path = "~/.ibc-attestor/ibc-attestor-keystore"

# --- Remote signer (--signer-type remote) ---
# gRPC endpoint of the remote signer service.
endpoint = "http://signer-service:9006"
# Wallet ID to request from the signer. Leave empty for singleton signers.
wallet_id = ""
```

> **Note:** Only the fields relevant to the chosen `--signer-type` need to be present. The `[adapter]` fields that apply depend on the `--chain-type`.

### EVM example

This example is from the [`attestor-config.toml.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/attestor-config.toml.tmpl) file of the IBC demo repo.

```toml
[server]
listen_addr = "0.0.0.0:9101"
health_addr = "0.0.0.0:9102"

[adapter]
url = "<EVM_JSON_RPC_ENDPOINT>"
router_address = "<ICS26_ROUTER_ADDR>"
finality_offset = 0

[signer]
keystore_path = "/config/.ibc-attestor/ibc-attestor-keystore"
```

### Cosmos example

This example is from the [`attestor-cosmos-config.toml.tmpl`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/attestor-cosmos-config.toml.tmpl) file of the IBC demo repo.

```toml
[server]
listen_addr = "0.0.0.0:9101"
health_addr = "0.0.0.0:9102"

[adapter]
url = "<COMETBFT_RPC_ENDPOINT>"

[signer]
keystore_path = "/config/.ibc-attestor/ibc-attestor-keystore"
```

## CLI Reference

```
ibc_attestor server
  --config <PATH>                    Path to TOML config file (required)
  --chain-type <evm|cosmos|solana>   Chain adapter to use (required)
  --signer-type <local|remote>       Signing backend (default: local)

ibc_attestor key generate [--keystore <PATH>]
ibc_attestor key show [--keystore <PATH>] [--show-private]
```

## Key Management

Before running the attestor with a local signer, generate a keypair:

```bash
ibc_attestor key generate
# Writes to ~/.ibc-attestor/ibc-attestor-keystore by default

# Or specify a custom path:
ibc_attestor key generate --keystore /etc/ibc-attestor/keystore
```

Inspect the public key (and optionally the private key):

```bash
ibc_attestor key show
ibc_attestor key show --show-private
```

The **public key / Ethereum address** derived from this keypair must be registered with the IBC light client when the light client is created. Registration happens at creation time and cannot be updated after the fact.

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `8090` | gRPC (HTTP/2) | Attestation API — used by relayers and the fleet backend |
| `9000` | HTTP | Metrics (Prometheus) and observability |

> The `listen_addr` in your TOML config controls the gRPC port. `8090` matches the `EXPOSE` in the Dockerfile; adjust to match your config.


## Observability

The attestor emits structured JSON logs via `tracing`. Log level is controlled by the `RUST_LOG` environment variable:

```bash
RUST_LOG=info   # default recommended level
RUST_LOG=debug  # verbose, includes per-request details
RUST_LOG=warn   # only warnings and errors
```

OpenTelemetry tracing is built in. Configure an OTEL exporter via the standard `OTEL_EXPORTER_*` environment variables if you want distributed traces.

Prometheus metrics are exposed on the `health_addr` port at `GET /metrics`.

## Health Checking

```bash
curl http://localhost:9000/healthz
```

Returns `200 OK` when the gRPC server is accepting connections, `503 Service Unavailable` when it is not ready. Allow up to 30 seconds for startup.


## Multi-Chain Deployments

Each attestor instance handles one chain type. For multiple chains, deploy one instance per chain. For m-of-n quorum on a single chain, deploy multiple instances with distinct signing keys. All of their addresses must be registered with the light client. The quorum threshold set on the light client determines how many must sign for a packet to be accepted.

Multiple instances can share a single remote signer service using distinct `wallet_id` values.

## On-Chain Registration

The Ethereum address derived from the attestor's signing key must be provided when the IBC light client is created — it is baked into the light client at creation time and cannot be updated afterwards.

Retrieve the address before creating the light client:

```bash
ibc_attestor key show
```

For remote signers, retrieve the wallet's Ethereum address from the signer service's `GetWallet` RPC before creating the light client.
