# Getting Started — Cosmos ↔ EVM IBC Demo

A friendlier walkthrough of the demo in this directory. If you want
architecture diagrams, phase tables, or skip-and-reuse knobs, jump to
[README.md](README.md) — this doc is for understanding *what's running and
why*.

The demo wires together two blockchains and lets a single token move
back and forth between them. Both sides use **attestation-based** light
clients — no ZK proofs, no Tendermint header validation in Solidity. A
small set of off-chain "attestor" processes watch each chain and sign
statements about its state, and the light client on the other side
trusts those signatures.

---

## What you're spinning up

```
┌─────────────────────────────┐                ┌─────────────────────────────┐
│  Chain A: Cosmos (wfchain)  │   ◄────────►   │  Chain B: Ethereum (Besu)   │
│  CometBFT consensus         │  IBC v2 over   │  Besu (EL) + Teku (CL)      │
│  uatom + uift tokens        │   attestation  │  TestIFT ERC20 (UIFT/uift)  │
└─────────────────────────────┘                └─────────────────────────────┘
```

A user on either side asks their chain to send IFT tokens to the other.
The token is burned on the source chain, a relayer carries the proof
across, and the same amount is minted to the recipient on the
destination chain. No bridge custodian, no wrapped-token escrow — just a
mint/burn pair coordinated over IBC v2.

---

## The two chains

### Chain A — Cosmos (`wfchain`)

A single-validator Cosmos SDK chain built from
[`cosmos/wfchain`](https://github.com/cosmos/wfchain). One container,
running CometBFT for consensus.

| Endpoint | Port | What for |
|----------|------|----------|
| CometBFT RPC | `localhost:26657` | Block + tx queries, broadcast |
| REST API | `localhost:1317` | LCD/gRPC-gateway for clients + tools |
| gRPC | `localhost:9090` | Native SDK gRPC |

Tokens that exist on this chain:
- `uatom` — staking + gas denom (the validator stakes it, you pay fees in it)
- `uift` — created at runtime by the **tokenfactory** module under the
  validator as creator. Stored as a bare subdenom (just `uift`), not the
  full `factory/<creator>/uift` form some other chains use.

### Chain B — Ethereum (Besu + Teku)

A single-validator Ethereum devnet, but Ethereum needs **two** processes
because it's a two-layer stack:

| Service | What it does |
|---------|--------------|
| `besu` | Execution layer (EL). Runs the EVM, holds account state, exposes JSON-RPC. |
| `teku`  | Consensus layer (CL). Runs the beacon chain + an embedded validator client; produces blocks and finality. |

| Endpoint | Port | What for |
|----------|------|----------|
| Besu JSON-RPC | `localhost:8545` | `cast`, web3 clients, the relayer |
| Besu WebSocket | `localhost:8546` | Subscriptions (used by attestor) |
| Teku Beacon REST | `localhost:5051` | Finality status, beacon state |

Tokens on this chain:
- ETH for gas (pre-funded validator account)
- `TestIFT` — an ERC20-style proxy contract deployed at startup; this is
  what gets minted when IFT packets arrive from Cosmos.

---

## What runs **on-chain**

### On Cosmos: built-in SDK modules

These are compiled into `wfchaind`. You don't deploy them; they're part
of the chain's app.

| Module | Role |
|--------|------|
| `bank` | Holds account balances. `uatom` (gas), `uift` (the bridged token). |
| `staking` | Validator + delegation logic. One validator in this devnet. |
| `tokenfactory` | Lets the validator mint/burn the `uift` denom. |
| `ift` | **Interchain Fungible Token.** Wraps tokenfactory with bridge semantics: `register-bridge`, `transfer`, mint-on-receive. Authority is set to the validator at genesis (so `--from validator` works without a gov proposal). |
| `27-gmp` | **General Message Passing** on port `gmpport`. Both directions of IFT route through here — IFT packets are *not* ICS-20. |
| `26-router` (ibc-go IBC v2) | Packet router; dispatches inbound packets to the right app (here: GMP). |
| `02-client` + `08-wasm` | The light client framework. The actual LC for EVM is a CosmWasm contract loaded at genesis (`cw_ics08_wasm_eth.wasm`) — it verifies attestor signatures over EVM state. |

### On EVM: Solidity contracts on Besu

These get deployed by `forge script MinimalDeploy` in Phase 4A, with one
exception (`AttestationLightClient`) that's deployed standalone in Phase
4E3 because its constructor needs runtime values (current Cosmos
height/timestamp).

| Contract | Role |
|----------|------|
| `ICS26Router` | The IBC entry point. Relayer calls `recvPacket` here. ERC1967 proxy. |
| `AttestationLightClient` | Verifies Cosmos state. Trusts an `m-of-n` attestor set; `verifyMembership` checks signatures over packet commitments. Replaces the SP1ICS07Tendermint contract used in earlier setups. |
| `ICS27GMP` | The GMP app on port `gmpport`. Receives packets from `ICS26Router`, dispatches them to an Interchain Account. |
| `ICS27Account` (CREATE2 proxy) | The Interchain Account itself — a per-(client, sender, salt) contract that executes the actual call on the EVM side. |
| `TestIFT` | The ERC20-style IFT token. ERC20 surface: `name() = "Test uift"`, `symbol() = "UIFT"` — same letters as the Cosmos `uift` denom so balances on both sides surface matching names. Has `iftTransfer` (outbound) and `iftMint` (called via the Interchain Account when a Cosmos→EVM packet arrives). |
| `CosmosIFTSendCallConstructor` | Helper deployed once, baked with `(typeUrl, denom, ICA address)`. Encodes the `cosmostx` payload that EVM→Cosmos transfers send. |

---

## What runs **off-chain**

These are the docker-compose services beyond the chains themselves.

### Per-side

| Service | Side | Role |
|---------|------|------|
| `attestor` | EVM watcher | Reads Besu state, signs attestations the **Cosmos** 08-wasm LC consumes. Used for EVM→Cosmos packets. |
| `attestor-cosmos` | Cosmos watcher | Reads Cosmos state, signs attestations the **EVM** `AttestationLightClient` consumes. Used for Cosmos→EVM packets. |

The `ibc-attestor` binary takes a singular `--chain-type` at startup —
one process can watch only one chain. So we run two. Both mount the
same keystore (`./ibc/local/.ibc-attestor/`), so they sign with the same
Ethereum address, and that single address is registered with both light
clients.

### Shared (chain-agnostic plumbing)

| Service | Role |
|---------|------|
| `relayer` | The actual packet relay daemon (`cosmos/ibc-relayer`). Watches both chains for `SendPacket` events, asks `proof-api` for proofs, submits `MsgRecvPacket` on the destination. |
| `proof-api` | Sits between the relayer and the attestors. Exposes a gRPC API; given a source tx, it fetches commitment data + attestation signatures, builds a multicall transaction (`updateClient` + `recvPacket`) and hands the bytes back to the relayer. |
| `postgres` | Relayer's persistent state store (which packets have been seen, acked, timed out). |

---

## How a transfer flows

### Cosmos → EVM (you have `uift`, want IFT on EVM)

```
1. wfchaind tx ift transfer uift attestations-0 0xRECIPIENT 1000000 <timeout>
   └─ ift module burns 1000000 uift from your account
   └─ ift module asks 27-gmp to send a packet on port "gmpport"
   └─ Cosmos emits SendPacket(sequence=N, srcClient=attestations-0, dstClient=client-0)

2. Relayer sees the SendPacket event
   └─ Asks proof-api: "build me a recv tx for this packet"

3. proof-api fetches:
   - the packet commitment from cosmos:26657
   - a signed StateAttestation(height=H, timestamp=T) from attestor-cosmos
   - a signed PacketAttestation(height=H, packets=[...]) from attestor-cosmos
   └─ Bundles all three into a single multicall tx targeting ICS26Router

4. Relayer signs + submits the multicall to besu:8545
   ▼
   ICS26Router.multicall:
     [a] updateClient(client-0, AttestationProof{StateAttestation, sigs})
         └─ AttestationLightClient records _consensusTimestampAtHeight[H] = T
     [b] recvPacket(packet, AttestationProof{PacketAttestation, sigs})
         └─ AttestationLightClient.verifyMembership: checks sigs at height H
         └─ ICS27GMP.onRecvPacket
              └─ ICS27Account (CREATE2'd from clientId+sender+salt) executes:
                  TestIFT.iftMint(0xRECIPIENT, 1000000)

5. 0xRECIPIENT now holds 1000000 TestIFT on EVM.
```

### EVM → Cosmos (mirror)

```
1. cast send TestIFT "iftTransfer(string,string,uint256,uint64)"
              client-0 wf1...recipient 1000000 <timeout>
   └─ TestIFT burns 1000000 from msg.sender
   └─ Builds a cosmostx payload via CosmosIFTSendCallConstructor
        (encodes MsgIFTMint{coin, receiver, signer: ICA})
   └─ Calls ICS27GMP.sendCall on port "gmpport"
   └─ ICS26Router emits SendPacket

2. Relayer sees SendPacket on EVM
   └─ Asks proof-api for proofs

3. proof-api fetches:
   - the packet commitment from besu:8545
   - beacon finality from teku:5051
   - signed attestations from attestor (the EVM watcher)
   └─ Builds a Cosmos MsgRecvPacket

4. Relayer submits the tx to cosmos:26657
   ▼
   IBC core verifies proof through the 08-wasm LC
     └─ The wasm LC checks the attestor signatures
   IBC core dispatches to 27-gmp
     └─ Decodes the inner MsgIFTMint
     └─ The ICA (signer) is authorised, MsgIFTMint runs
        └─ tokenfactory mints 1000000 uift to wf1...recipient

5. wf1...recipient now holds 1000000 uift on Cosmos.
```

The two key addresses to keep separate in the EVM→Cosmos direction
(easy to confuse, breaks minting silently if you swap them):

- **ICA** (queried via `wfchaind query gmp get-address <client> <TestIFT> ""`)
  is the *signer* of MsgIFTMint on Cosmos. Baked into
  `CosmosIFTSendCallConstructor`.
- **Cosmos IFT module account** (queried via
  `wfchaind query auth module-account ift`) is the `.sender` field in
  GMP packets *from* Cosmos. Stored as `counterpartyIFTAddress` in
  `TestIFT.registerIFTBridge` so the auth check on the EVM side passes.

---

## Running it

From this directory:

```bash
# Full bring-up: init both chains, deploy contracts, set up IBC, run a demo transfer.
./setup.sh

# Just the chains (no IBC wiring) — useful if you want to poke at them manually.
./setup.sh chains

# IBC wiring on chains that are already running.
./setup.sh ibc

# Run individual demo scenarios.
./setup.sh demo cosmos-evm   # Cosmos → EVM IFT transfer
./setup.sh demo evm-cosmos   # EVM → Cosmos IFT transfer
./setup.sh demo all          # the full set

# Print current RPC endpoints and block heights.
./setup.sh status

# Stop containers and wipe data.
./setup.sh clean
```

First run pulls ~14 docker images and downloads two source tarballs
(solidity-ibc-eureka, ibc-relayer); subsequent runs are fully offline.
Plan for ~5 GB of disk, 4 GB of RAM. Host needs `docker` (with the
compose plugin), `jq`, `curl`, `openssl`, `perl`, and `bash`.

---

## Where to look next

- [README.md](README.md) — full architecture diagrams, phase-by-phase
  setup table, all skip-and-reuse environment knobs, the directory
  layout under `cosmos/`, `evm/`, `ibc/`.
- [spec.md](spec.md) — IBC v2 protocol reference (general, not specific
  to this demo).
- [`lib/`](lib/) — the actual shell modules. `lib/ibc.sh` is the meat
  (Phase 4: contract deploys, client creation, IFT bridge wiring).
- [`ibc/`](ibc/) — config templates (rendered into `ibc/local/` at
  runtime) and downloaded source tarballs.

If something breaks during setup, `logs/setup-YYYYMMDD-HHMMSS.log`
captures the full stdout/stderr of the run. Live service logs are at
`docker compose logs -f <service>` (e.g. `relayer`, `attestor-cosmos`,
`proof-api`).
