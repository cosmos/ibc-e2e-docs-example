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
│  Chain A: Cosmos (sandbox)  │   ◄────────►   │  Chain B: Ethereum (Besu)   │
│  CometBFT consensus         │  IBC v2 over   │  QBFT consensus (1 sealer)  │
│  uatom + uift tokens        │   attestation  │  IFTOwnable ERC20 (UIFT)    │
└─────────────────────────────┘                └─────────────────────────────┘
```

A user on either side asks their chain to send IFT tokens to the other.
The token is burned on the source chain, a relayer carries the proof
across, and the same amount is minted to the recipient on the
destination chain. No bridge custodian, no wrapped-token escrow — just a
mint/burn pair coordinated over IBC v2.

---

## The two chains

### Chain A — Cosmos (`sandbox`)

A single-validator Cosmos SDK chain built from
[`cosmos/sandbox`](https://github.com/cosmos/sandbox). One container,
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

The cosmos service has its **whole `/data/config/` directory bind-mounted
from `./cosmos/local/config/`** on the host, so all the genesis/keys/etc
files `sandboxd init` writes are visible to you on disk:
`./cosmos/local/config/genesis.json`, `app.toml`, `config.toml`,
`priv_validator_key.json`, etc. The jq patches that customize genesis
(bond_denom → uatom, IFT authority → validator)
run directly against the host file — no `docker cp` roundtrip. Other
runtime state (keyring, blockchain state) stays in the `cosmos-data`
named volume.

### Chain B — Ethereum (Besu)

A single-node Ethereum devnet running Besu in **QBFT** mode — Besu's
built-in IBFT 2.0 / QBFT consensus, so there's no separate consensus
layer process. One container produces blocks and serves the EVM.

| Service | What it does |
|---------|--------------|
| `besu` | Single-node Ethereum: runs the EVM, holds account state, exposes JSON-RPC, and seals QBFT blocks itself using the validator key in `evm/key`. |

| Endpoint | Port | What for |
|----------|------|----------|
| Besu JSON-RPC | `localhost:8545` | `cast`, web3 clients, the relayer |
| Besu WebSocket | `localhost:8546` | Subscriptions (used by attestor) |

Tokens on this chain:
- ETH for gas (pre-funded validator account)
- `IFTOwnable` — an ERC20-style proxy contract deployed at startup
  (`name() = "Test uift"`, `symbol() = "UIFT"`); this is what gets minted
  when IFT packets arrive from Cosmos.

---

## What runs **on-chain**

### On Cosmos: built-in SDK modules

These are compiled into `sandboxd`. You don't deploy them; they're part
of the chain's app.

| Module | Role |
|--------|------|
| `bank` | Holds account balances. `uatom` (gas), `uift` (the bridged token). |
| `staking` | Validator + delegation logic. One validator in this devnet. |
| `tokenfactory` | Lets the validator mint/burn the `uift` denom. |
| `ift` | **Interchain Fungible Token.** Wraps tokenfactory with bridge semantics: `register-bridge`, `transfer`, mint-on-receive. Authority is set to the validator at genesis (so `--from validator` works without a gov proposal). |
| `27-gmp` | **General Message Passing** on port `gmpport`. Both directions of IFT route through here — IFT packets are *not* ICS-20. |
| `26-router` (ibc-go IBC v2) | Packet router; dispatches inbound packets to the right app (here: GMP). |
| `02-client` + `attestations` | The light client framework. The actual LC for EVM is a native module compiled into sandboxd — its `ClientState` verifies attestor signatures over EVM packet commitments. |

### On EVM: Solidity contracts on Besu

These get deployed by `forge script "$DEPLOY_SCRIPT"` in Phase 4A. The
default script is
[`ibc/forge/scripts/MinimalDeploy.s.sol`](ibc/forge/scripts/MinimalDeploy.s.sol) —
a self-contained deploy that pulls eureka contract bytecode from a
**prebuilt release tarball** (`solidity-contracts-$SOLIDITY_RELEASE_TAG.tar.gz`)
and deploys it via `vm.getCode` + the `CREATE` opcode. No
`solidity-ibc-eureka` source clone is needed; the forge project is the
committed skeleton at `ibc/forge/` (foundry.toml + package.json with
just OpenZeppelin and forge-std).

One contract is **not** in the deploy script: `AttestationLightClient`
is deployed standalone in Phase 4B6 (during `create-clients`) because its constructor needs
runtime values (current Cosmos height/timestamp + attestor address).
It's also loaded from `release-bytecode/AttestationLightClient.json`.

| Contract | Role |
|----------|------|
| `ICS26Router` | The IBC entry point. Relayer calls `recvPacket` here. ERC1967 proxy. |
| `AttestationLightClient` | Verifies Cosmos state. Trusts an `m-of-n` attestor set; `verifyMembership` checks signatures over packet commitments. Replaces the SP1ICS07Tendermint contract used in earlier setups. |
| `ICS27GMP` | The GMP app on port `gmpport`. Receives packets from `ICS26Router`, dispatches them to an Interchain Account. |
| `ICS27Account` (CREATE2 proxy) | The Interchain Account itself — a per-(client, sender, salt) contract that executes the actual call on the EVM side. |
| `IFTOwnable` | The ERC20-style IFT token. ERC20 surface: `name() = "Test uift"`, `symbol() = "UIFT"` — same letters as the Cosmos `uift` denom so balances on both sides surface matching names. Has `iftTransfer` (outbound) and `iftMint` (called via the Interchain Account when a Cosmos→EVM packet arrives). |
| `CosmosIFTSendCallConstructor` | Helper deployed once, baked with `(typeUrl, denom, ICA address)`. Encodes the `cosmostx` payload that EVM→Cosmos transfers send. |

---

## What runs **off-chain**

These are the docker-compose services beyond the chains themselves.

### Per-side

| Service | Side | Role |
|---------|------|------|
| `attestor` | EVM watcher | Reads Besu state, signs attestations the **Cosmos** attestations LC consumes. Used for EVM→Cosmos packets. |
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
1. sandboxd tx ift transfer uift attestations-0 0xRECIPIENT 1000000 <timeout>
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
                  IFTOwnable.iftMint(0xRECIPIENT, 1000000)

5. 0xRECIPIENT now holds 1000000 UIFT on EVM.
```

### EVM → Cosmos (mirror)

```
1. cast send IFTOwnable "iftTransfer(string,string,uint256,uint64)"
              client-0 cosmos1...recipient 1000000 <timeout>
   └─ IFTOwnable burns 1000000 from msg.sender
   └─ Builds a cosmostx payload via CosmosIFTSendCallConstructor
        (encodes MsgIFTMint{coin, receiver, signer: ICA})
   └─ Calls ICS27GMP.sendCall on port "gmpport"
   └─ ICS26Router emits SendPacket

2. Relayer sees SendPacket on EVM
   └─ Asks proof-api for proofs

3. proof-api fetches:
   - the packet commitment from besu:8545
   - signed attestations from attestor (the EVM watcher)
   └─ Builds a Cosmos MsgRecvPacket

4. Relayer submits the tx to cosmos:26657
   ▼
   IBC core verifies proof through the attestations LC
     └─ The attestations LC checks the attestor signatures
   IBC core dispatches to 27-gmp
     └─ Decodes the inner MsgIFTMint
     └─ The ICA (signer) is authorised, MsgIFTMint runs
        └─ tokenfactory mints 1000000 uift to cosmos1...recipient

5. cosmos1...recipient now holds 1000000 uift on Cosmos.
```

The demo's status tracker polls for ≤120 s on Cosmos→EVM and ≤300 s
on EVM→Cosmos.

The two key addresses to keep separate in the EVM→Cosmos direction
(easy to confuse, breaks minting silently if you swap them):

- **ICA** (queried via `sandboxd query gmp get-address <client> <IFTOwnable> ""`)
  is the *signer* of MsgIFTMint on Cosmos. Baked into
  `CosmosIFTSendCallConstructor`.
- **Cosmos IFT module account** (queried via
  `sandboxd query auth module-account ift`) is the `.sender` field in
  GMP packets *from* Cosmos. Stored as `counterpartyIFTAddress` in
  `IFTOwnable.registerIFTBridge` so the auth check on the EVM side passes.

---

## Running it

From this directory:

```bash
# Print all available commands and environment variables.
./setup.sh help

# Full bring-up: init both chains, deploy contracts, set up IBC, run a demo transfer.
./setup.sh

# Just the chains (no IBC wiring) — useful if you want to poke at them manually.
./setup.sh chains

# IBC wiring on chains that are already running (all steps in one go).
./setup.sh ibc
```

### Step-by-step (recommended for tutorials)

Each step is idempotent — safe to re-run if something fails.

```bash
./setup.sh chains           # 1. start Cosmos + Besu

./setup.sh deploy           # Step 1/5: prepare forge workspace + fetch release bytecode + deploy IBC/IFT contracts on Besu
./setup.sh attestors        # Step 2/5: generate keystore + configs, start attestors
./setup.sh create-clients   # Step 3/5: create attestation light clients on both chains
./setup.sh relayer          # Step 4/5: copy keys, render configs (client IDs now known), run DB migrations, start relayer + proof-api
./setup.sh wire             # Step 5/5: register counterparties + IFT bridges
```

### Demos

```bash
./setup.sh transfer          # cosmos↔evm IFT transfers (alias for `demo transfer`)
./setup.sh demo cosmos-evm   # Cosmos → EVM IFT transfer
./setup.sh demo evm-cosmos   # EVM → Cosmos IFT transfer
./setup.sh demo track        # packet status tracking
./setup.sh demo failure      # timeout + retry flow
./setup.sh demo observe      # Prometheus metrics + logs
./setup.sh demo all          # run all demos (default)

# Print current RPC endpoints and block heights.
./setup.sh status

# Stop containers and wipe data.
./setup.sh clean
```

### Environment variables

Optional overrides — pre-set any of these to skip the corresponding phase or
swap in a different artifact:

| Variable | Purpose |
|----------|---------|
| `SOLIDITY_IBC_DIR` | Forge workspace path override (default: `ibc/forge/`) |
| `SOLIDITY_RELEASE_TAG` | Pin a different solidity-ibc-eureka release for the prebuilt bytecode tarball (default: `solidity-v3.0.0-rc.1`) |
| `ICS26_ROUTER_ADDR` | Skip forge deploy (use a pre-deployed router) |
| `EVM_ATTESTATION_LC_ADDR` | Skip AttestationLightClient deploy |
| `DEPLOY_SCRIPT` | Forge deploy script (default: `scripts/MinimalDeploy.s.sol` inside `ibc/forge/`) |

```bash
# Pin a specific solidity-ibc-eureka release for the prebuilt bytecode:
SOLIDITY_RELEASE_TAG=solidity-v3.0.0-rc.1 ./setup.sh

# Use a pre-deployed contract set (skips Phase 4A entirely):
ICS26_ROUTER_ADDR=0x… ICS27_GMP_ADDR=0x… IFT_CONTRACT_ADDR=0x… ./setup.sh
```

First run pulls ~14 docker images and downloads two GitHub tarballs
(the `solidity-ibc-eureka` release-bytecode bundle and ibc-relayer
migrations); subsequent runs are fully offline. Plan for ~5 GB of disk,
4 GB of RAM. Host needs `docker` (with the compose plugin), `jq`,
`curl`, `openssl`, `perl`, and `bash`.

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
  runtime), the committed forge workspace at `ibc/forge/`, and runtime
  state in `ibc/state.env`.

## Inspecting balances yourself

Each transfer demo prints copy-pasteable curl commands before
broadcasting, so you can re-query balances on either side from another
terminal while the demo polls:

```bash
# Cosmos (REST → JSON object {denom, amount}):
curl -s 'http://localhost:1317/cosmos/bank/v1beta1/balances/<addr>/by_denom?denom=uift' | jq .balance

# EVM (eth_call → hex result, piped through printf for decimal):
curl -s -X POST http://localhost:8545 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"<IFT_CONTRACT_ADDR>","data":"0x70a08231<padded-addr>"},"latest"],"id":1}' \
  | jq -r .result | xargs printf '%d\n'
```

The Cosmos REST is straightforward; the EVM side is verbose because
ERC20 balances live in contract storage, not at the top-level account
state. `eth_getBalance` only returns *native ETH*, not ERC20 token
balances — that's why the demo always uses `eth_call → balanceOf` for
the IFTOwnable (UIFT) token.

---

## Where things live (gitignored runtime artifacts)

After a setup run, you'll find:

| Path | Created by | Contents |
|------|-----------|---------|
| `cosmos/local/config/` | `sandboxd init` (bind-mounted) | genesis, app.toml, config.toml, priv_validator_key, etc |
| `cosmos/local/ibc_*_state.json` | Phase 4B5b | rendered LC ClientState + ConsensusState |
| `ibc/local/{config.yml,keys.json,relayer.json,attestor*.toml,.ibc-attestor/}` | Phase 4D/4D1/keystore generator | relayer + attestor + proof-api configs |
| `ibc/state.env` | every phase via `state_set` | accumulated addresses + IDs (no duplicates — `state_set` does in-place key replace) |
| `ibc/forge/release-bytecode/` | Phase 4A0b | prebuilt eureka contract artifacts (~150 KB) from the `solidity-contracts-$SOLIDITY_RELEASE_TAG.tar.gz` release |
| `ibc/forge/node_modules/` | Phase 4A0 (`bun install`) | OpenZeppelin + forge-std (~200 MB) |
| `ibc/forge/{out,cache,broadcast}/` | Phase 4A (forge) | compile output + broadcast receipts |
| `evm/key` | Phase 1B | Besu node private key — derives the QBFT validator address |

`./setup.sh clean` removes all of these and wipes the docker volumes.

---

## Troubleshooting

- **Setup logs**: `logs/setup-YYYYMMDD-HHMMSS.log` captures full
  stdout/stderr of every run.
- **Live service logs**: `docker compose logs -f <service>` (e.g.
  `relayer`, `attestor-cosmos`, `proof-api`).
- **State file**: `cat ibc/state.env` — every phase appends here, last
  value of each key wins.
- **Packet status via gRPC**: `docker run --rm --network cosmos-evm_ibc-net
  fullstorydev/grpcurl:latest -plaintext -d '{"tx_hash":"<hash>","chain_id":"<id>"}'
  relayer:3000 skip.relayer.RelayerApiService/Status` (replace `<hash>`
  with `COSMOS_TO_EVM_TX_HASH` or `EVM_TO_COSMOS_TX_HASH` from `state.env`).
- **Genesis on disk**: `cat cosmos/local/config/genesis.json | jq` — fully
  visible since the cosmos service bind-mounts this dir.
