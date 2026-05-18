# Tutorial Outline: Cosmos ↔ EVM IBC Integration

## 1. Introduction
- What you'll build: a live IBC v2 bridge with IFT token transfers in both directions
- How to use this tutorial: follow along with the demo as the reference implementation, or apply each step to your own chains
- Link to architecture doc for conceptual background

---

## 2. Prerequisites

### Tools
- Docker + Compose
- Foundry (`forge`) + `bun`

### Infrastructure
- A running Cosmos chain
- A running EVM-compatible chain with a funded deployer account (needs ETH to deploy contracts; the demo uses the pre-funded Hardhat test key)
- A Postgres instance (for the relayer)

---

## 3. Start the Chains
- `./setup.sh chains`
- In the demo: starts Cosmos sandbox + Besu containers
- For a real integration: your chains are already running — this section describes what endpoints and chain state the rest of the setup expects
- What to verify: both chains producing blocks, RPC endpoints reachable

---

## 4. Deploy EVM Contracts
- `./setup.sh deploy`
- What the script does: prepares the committed forge workspace at `ibc/forge/`, downloads prebuilt contract bytecode from the solidity-ibc-eureka release, runs `MinimalDeploy.s.sol`
- Contracts deployed and why (brief — full detail in contract-deployment.md)
- Output: `ics26Router`, `ics27Gmp`, `ift` addresses used in all subsequent steps
- → See contract-deployment.md

---

## 5. Configure and Start Attestors
- `./setup.sh attestors`
- What attestors do: watch each chain and sign state for the proof API
- Two instances: EVM watcher, Cosmos watcher
- Key generation: `attestor key generate` — one keystore shared by both instances
- EVM attestor config fields (from `ibc/attestor-config.toml.tmpl`):
  - `adapter.url` — EVM RPC endpoint
  - `adapter.router_address` — ICS26Router address (from section 4)
  - `adapter.finality_offset` — blocks to wait before attesting (demo: `0`; production: set based on chain reorg depth)
  - `signer.keystore_path` — path to generated keystore
- Cosmos attestor config fields (from `ibc/attestor-cosmos-config.toml.tmpl`):
  - `adapter.url` — CometBFT RPC endpoint
  - `signer.keystore_path` — same keystore as EVM attestor

---

## 6. Configure and Start the Relayer and Proof API
- `./setup.sh relayer`

### Relayer key funding
- The relayer submits transactions on the Cosmos side and needs a funded key
- The script copies the validator key and funds the relayer account
- For a real deployment: create a dedicated relayer key and fund it with enough tokens to cover gas

### Proof API (from `ibc/proof-api.json.tmpl`)
- What it does: aggregates attestor signatures into relay-ready proofs
- Top-level structure: `server` block + `modules[]` array with two named directional modules
- Each module has its own `src_chain`, `dst_chain`, and config; they do not share a single flat field list
- Module names and directional routing:
  - `cosmos_to_eth` — queries the **Cosmos watcher** attestor (`http://attestor-cosmos:9101`)
  - `eth_to_cosmos` — queries the **EVM watcher** attestor (`http://attestor:9101`)
  - Each module's `attestor_endpoints` points to the attestor watching its *source* chain, not both
- Fields inside each module's `config`:
  - `src_chain` / `dst_chain` — chain IDs for the direction this module handles
  - `tm_rpc_url` — Cosmos CometBFT RPC
  - `ics26_address` — ICS26Router address (from section 4)
  - `eth_rpc_url` — EVM RPC
  - `signer_address` — relayer address (used to scope proof queries)
  - `mode.attested.attestor.attestor_endpoints` — single-element list with the source-chain attestor URL
  - `mode.attested.attestor.quorum_threshold` — signatures required (demo: `1`; production: set to majority of attestor set)
  - `mode.attested.attestor.attestor_query_timeout_ms` — attestor RPC timeout (demo: `10000`)

### Relayer (from `ibc/relayer-config.yml.tmpl`)
- What it does: submits `RecvPacket` and `MsgTimeout` transactions
- Config fields:
  - `postgres` — DB connection (hostname, port, database)
  - `signing.keys_path` — relayer key file
  - `relayer_api.address` — gRPC relay API endpoint (default `0.0.0.0:3000`; used by `demo track` and on-demand relay requests)
  - `metrics.prometheus_address` — Prometheus scrape endpoint (default `0.0.0.0:9100`; used by `demo observe`)
  - `ibcv2_proof_api.grpc_address` — proof API endpoint
  - Per chain (`chains.<name>`): RPC/gRPC endpoints, chain ID, address prefix, fee denom
  - `chains.besu.evm.contracts.ics_26_router_address` — ICS26Router address (from section 4)
  - `chains.<name>.ibcv2.counterparty_chains` — client ID mappings (added in section 8 after wire; each chain's `ibcv2` block gets its own entry)
- DB setup: migrations run automatically on startup

---

## 7. Create Attestation Light Clients
- `./setup.sh create-clients`
- What an attestation light client is (not ZK, not Tendermint — off-chain signers)

### Cosmos-side client
- Template variables: attestor address, current EVM block height, current EVM block timestamp
- Renders `client-state.json` and `consensus-state.json` from these values
- Command: `tx ibc client create client-state.json consensus-state.json`
- Output: `COSMOS_CLIENT_ID` (format: `attestations-N`)

### EVM-side client
- Template variables: attestor address, current Cosmos block height, current Cosmos block timestamp
- Deploys `AttestationLightClient` contract with constructor args:
  `(attestors[], quorum, initHeight, initTs, roleManager)`
- Registers it: `ICS26Router.addClient((clientId, []), lcAddress)`
- Output: `EVM_CLIENT_ID` (format: `client-N`)

---

## 8. Wire the Bridge
- `./setup.sh wire`

### Register counterparty clients
- Cosmos side: `tx ibc client add-counterparty <COSMOS_CLIENT_ID> <EVM_CLIENT_ID>`
- Links the two light clients so each chain knows its peer

### Register IFT bridges
- Cosmos side: `tx ift register-bridge <denom> <client_id> <ift_addr_checksummed> evm`
  - Denom: full tokenfactory denom (`factory/<creator>/uift`)
  - IFT address must be EIP-55 checksummed — Cosmos GMP derives the account address by hashing the exact sender string; lowercase produces a different address and mints silently fail
- EVM side:
  1. Query the GMP-derived account address for the IFT contract: `query gmp get-address <client_id> <ift_addr_checksummed>`
     - This is the Cosmos account the GMP module uses to authorize `MsgIFTMint` on inbound packets
  2. Query Cosmos IFT module account: `query auth module-account ift`
  3. Deploy `CosmosIFTSendCallConstructor(typeUrl, denom, gmpDerivedAddress)`
  4. Call `IFTOwnable.registerIFTBridge(evm_client_id, cosmos_ift_module_addr, ctor_addr)`

### Finalize relayer config
- Re-render `config.yml` with `counterparty_chains` mappings now that both client IDs are known
- Restart relayer to pick up updated config

---

## 9. Validate

### Mint IFT tokens (Cosmos → EVM prerequisite)
- Before running a Cosmos → EVM transfer, the sender needs IFT tokens
- The demo mints automatically; for a real deployment: `tx tokenfactory mint <address> <amount><denom>`
- Denom is the full tokenfactory denom: `factory/<creator>/uift`

### Transfer demos
- `demo cosmos-evm`: Cosmos → EVM (tokenfactory burn → ERC20 mint)
- `demo evm-cosmos`: EVM → Cosmos (ERC20 burn → tokenfactory mint)
- `demo all`: runs all demos in sequence (transfers, track, failure, observe)
- What to look for: packet hash, transfer state, final balances

### Packet tracking
- `demo track`: polls relayer status API by tx hash
- Requires a prior transfer in the same session

### Timeout path
- `demo failure`: sends a packet with short timeout, pauses relayer, lets it expire
- What success looks like: `TRANSFER_STATE_COMPLETE` with `timeoutTx` field

---

## 10. Observability
- `demo observe`
- Metrics: `relayerapi_*` prefix — per-method RPC call counts with status codes
- Relayer logs: `msg`, `source_chain_id`, `tx_hash`, `state`
- Attestor logs: `spans` array — `name`, `height`, `durationMs`, `status`

---

## Appendix A — Cosmos Chain Requirements
Reference only — not required to run the demo. The demo uses the sandbox chain which has all of these modules pre-installed.

### Required modules
- tokenfactory, IFT module, GMP module, attestation light client module
- How they're wired: `app.go` reference (link to sandbox-ledger repo — placeholder until public)
  - Module imports (Go package paths + versions)
  - `ModuleBasics` registration
  - Keeper fields and initialization order
  - Module manager registration
  - Genesis parameters that matter

### EVM chain
- No special chain-level requirements — any EVM-compatible node works
- What gets added at the contract layer (covered in section 4)

---

## Appendix B — Utility Commands
- `./setup.sh status` — check RPC endpoints and block heights
- `./setup.sh clean` — stop containers and wipe all state
