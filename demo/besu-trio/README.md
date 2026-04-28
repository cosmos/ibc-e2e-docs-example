# besu-trio

Three single-validator Besu QBFT chains running side-by-side, intended as the
substrate for two IBC pairs:

```
       A  ◀──IBC──▶  hub  ◀──IBC──▶  B
```

A and B never talk to each other directly — they each have an IBC link only
to `hub`. The current scope:

1. **Chains** — 3 single-validator Besu QBFT chains
2. **Contracts** — solidity-ibc-eureka stack (ICS26Router + ICS27GMP + TestIFT) deployed on each chain
3. **Services** — local proof-api image build + postgres (with DB migrations) + 4 directional attestors + proof-api + a single relayer
4. **Wire** — 4 `BesuQBFTLightClient` deploys (counterparty router + initial trusted height/timestamp/storage-root + counterparty's QBFT validator set), `ICS26Router.addClient` on both sides of each pair (passing the counterparty's predicted client ID), then the relayer config is re-rendered with populated `counterparty_chains` and the relayer is restarted
5. **Transfer** — exercises an end-to-end IFT flow over a wired pair: lazy-deploys `EVMIFTSendCallConstructor`, registers IFT bridges on **both** sides, lazy-mints, calls `TestIFT.iftTransfer`, drives the relay via gRPC, and waits for the destination balance to settle

## Layout

```
demo/besu-trio/
├── README.md
├── setup.sh                — entrypoint: chains | contracts | build-proof-api |
│                             services | wire | transfer | status | clean
├── docker-compose.yml      — 3 Besu + postgres + 4 attestors + proof-api + relayer
├── lib/
│   ├── common.sh           — logging, prerequisite checks, RPC waiter,
│   │                         render_template (perl-based)
│   ├── chains.sh           — start_chains / wait_for_chains / print_status / clean
│   └── ibc.sh              — fetch eureka source; forge deploy per chain;
│                             local proof-api image build; render configs;
│                             generate attestor keystores; postgres + DB
│                             migrations; BesuQBFTLightClient deploy +
│                             addClient (Phase 4); EVMIFTSendCallConstructor
│                             deploy + IFT bridge registration + iftTransfer
│                             + relay submit + balance wait (Phase 5)
├── chains/
│   ├── A/{besu.toml, el-genesis.json, key}     — chain-id 41001
│   ├── hub/{besu.toml, el-genesis.json, key}   — chain-id 41000
│   └── B/{besu.toml, el-genesis.json, key}     — chain-id 41002
└── ibc/
    ├── scripts/MinimalDeploy.s.sol      — staged into the fetched eureka tree
    │                                       before each forge run
    ├── attestor-config.toml.tmpl        — single template, rendered 4× (one per
    │                                       direction) into ibc/local/attestor-*.toml
    ├── relayer-config.yml.tmpl          — 3-EVM-chain layout, single relayer
    ├── relayer-keys.json.tmpl           — 3 chain entries, all using the deployer key
    ├── proof-api.json.tmpl              — 4 modules (all `name: besu_to_besu`)
    ├── solidity-ibc-eureka-gjermund-besu-poc/   — fetched on first run
    ├── ibc-relayer-v0.0.2/              — fetched for db/migrations
    ├── state.env                        — per-chain addresses + attestor
    │                                       addresses + LC addresses + LC IDs
    │                                       + EVM IFT ctor addresses
    └── local/                           — generated at run time:
        ├── attestor-{A-to-hub,hub-to-A,hub-to-B,B-to-hub}.toml
        ├── config.yml                   — relayer
        ├── keys.json                    — relayer signing keys (per chain)
        ├── relayer.json                 — proof-api modules
        └── keys/<attestor-name>/.ibc-attestor/ibc-attestor-keystore
```

Each chain has one validator. Validator keys are the first three Anvil/Hardhat
default accounts (well-known dev keys, never use these on a public network):

| Chain | Chain ID | Validator address                            | Account |
|-------|---------:|---------------------------------------------|---------|
| A     |    41001 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | dev #0  |
| hub   |    41000 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | dev #1  |
| B     |    41002 | `0x3C44CdDdB6a900fA2b585dd299e03d12FA4293BC` | dev #2  |

The matching QBFT `extraData` blob in each `el-genesis.json` is the RLP
encoding of `[vanity, [validator], votes=[], round=0, committedSeals=[]]`.

All three validator addresses are pre-funded on every chain (1 000 000 ETH
each) so dev txs from any of them work everywhere.

## Ports

Each Besu container uses the same internal ports (8545 RPC, 8546 WS, 9545
metrics). Only the host-side mappings differ:

| Service  | RPC (host) | WS (host) | Metrics (host) |
|----------|-----------:|----------:|---------------:|
| besu-a   |       8545 |      8546 |           9545 |
| besu-hub |       8645 |      8646 |           9645 |
| besu-b   |       8745 |      8746 |           9745 |

## Usage

```bash
./setup.sh                # chains + contracts + services + wire (end-to-end)
./setup.sh chains         # start all 3 chains and wait for RPC
./setup.sh contracts      # deploy IBC contracts to all 3 chains (chains must be up)
./setup.sh build-proof-api # build local proof-api image from gjermund/besu-poc
                          # source (Rust compile, ~5–15 min cold). Idempotent.
./setup.sh services       # build proof-api image if missing, render configs,
                          # generate keystores, start postgres + 4 attestors +
                          # proof-api + relayer (contracts must be deployed)
./setup.sh wire           # deploy BesuQBFTLightClient on each chain, register
                          # counterparties via ICS26Router.addClient, re-render
                          # relayer config + restart relayer (services must be up)
./setup.sh transfer DIR [AMOUNT]
                          # IFT transfer (DIR ∈ a-to-hub | hub-to-a | hub-to-b |
                          # b-to-hub | a-hub-b). Lazy-deploys EVMIFTSendCallConstructor
                          # per chain, registers IFT bridges, mints initial supply,
                          # calls TestIFT.iftTransfer, submits the source tx to the
                          # relayer's gRPC Relay API, polls dst balance until it
                          # changes. Default amount 1000.
./setup.sh status         # RPC endpoints, block heights, deployed addresses
./setup.sh clean          # stop containers, remove volumes + fetched source
                          # + rendered configs + attestor keystores
                          # (the local proof-api image is left intact —
                          # remove with `docker rmi besu-trio/proof-api:local`)
```

## Local proof-api image

`PROOF_API_IMAGE` defaults to `besu-trio/proof-api:local`, built from the
`gjermund/besu-poc` solidity-ibc-eureka branch. The published
`ghcr.io/cosmos/proof-api:latest` image was compiled **without** the
`besu-to-besu` Rust module — its module registry only contains
`cosmos_to_*`, `eth_to_*`, `solana_to_*`. With `name: "besu_to_besu"` in
`relayer.json`, that binary errors out as `Module besu_to_besu not found in
relayer builder`.

`./setup.sh build-proof-api` invokes `docker build` against
`ibc/solidity-ibc-eureka-gjermund-besu-poc/programs/relayer/Dockerfile`
(build context = the eureka source root). The build is idempotent — if a
`besu-trio/proof-api:local` image is already present, it's reused. To force
a rebuild, drop the image first: `docker rmi besu-trio/proof-api:local`.

A `logs/` directory is created on first run and each invocation writes a
timestamped log file there.

Quick smoke check once chains are up:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://localhost:8645   # → 0xa028  (= 41000, hub)
```

## IBC contract deploy

`./setup.sh contracts` does three things:

1. Downloads the `cosmos/solidity-ibc-eureka` archive at `SOLIDITY_IBC_TAG`
   (default `gjermund/besu-poc` — the branch with `BesuQBFTLightClient`,
   `EVMIFTSendCallConstructor`, and the `besu-to-besu` relayer module) into
   `ibc/solidity-ibc-eureka-<tag-with-slashes-as-dashes>/`. Skipped if
   `SOLIDITY_IBC_DIR` is set or the directory already exists.
2. Stages every `*.s.sol` from `ibc/scripts/` into the fetched tree's
   `scripts/` dir (lets `MinimalDeploy.s.sol` live in this repo without
   editing the gitignored eureka checkout).
3. Runs `forge script <DEPLOY_SCRIPT>` against each chain's internal RPC
   (`besu-a:8545`, `besu-hub:8545`, `besu-b:8545`) using the Anvil dev
   account #0 key as deployer (pre-funded on all three chains). Resolved
   contract addresses are written to `ibc/state.env`, keyed by chain name
   verbatim (`A_*`, `hub_*`, `B_*`):

   ```
   A_ICS26_ROUTER_ADDR=0x…
   A_ICS27_GMP_ADDR=0x…
   A_IFT_CONTRACT_ADDR=0x…
   hub_ICS26_ROUTER_ADDR=0x…
   hub_ICS27_GMP_ADDR=0x…
   hub_IFT_CONTRACT_ADDR=0x…
   B_ICS26_ROUTER_ADDR=0x…
   …
   ```

`MinimalDeploy.s.sol` covers `ICS26Router + ICS27GMP + TestIFT`. It does
**not** deploy `BesuQBFTLightClient` (handled in Phase 4) or
`EVMIFTSendCallConstructor` (handled lazily in Phase 5).

The deploy is idempotent — a chain is skipped if its recorded `ICS26Router`
still has bytecode at the recorded address. To force redeploy on a single
chain, drop just that chain's lines from `ibc/state.env`. To redeploy
everything, run `./setup.sh clean` first.

## Attestor topology

Four directional attestors are spun up by `./setup.sh services` and run for
the lifetime of the demo:

| Attestor             | Watches    |
|----------------------|------------|
| `attestor-A-to-hub`  | `besu-a`   |
| `attestor-hub-to-A`  | `besu-hub` |
| `attestor-hub-to-B`  | `besu-hub` |
| `attestor-B-to-hub`  | `besu-b`   |

Each has its own Web3 v3 keystore at
`ibc/local/keys/<name>/.ibc-attestor/ibc-attestor-keystore`, generated on
first run. Addresses persist to `ibc/state.env` as `ATTESTOR_A_TO_HUB_ADDR`,
`ATTESTOR_HUB_TO_A_ADDR`, etc.

**Note on load-bearing:** with the current proof-api module (`besu_to_besu`)
and LC type (`BesuQBFTLightClient`), the attestors are **not** load-bearing
for client trust — QBFT proofs are verified on-chain from the validator
signature set and storage proofs. The attestors stay configured so the demo
matches the wider eureka relayer topology and so a future switch to
`eth_to_eth` (attestor-aggregator) mode is a config flip.

## Relayer + proof-api

A **single** Go relayer (`ghcr.io/cosmos/ibc-relayer:v0.0.2`) handles both
pairs. Its `chains:` map has three entries (`chain-a`, `chain-hub`,
`chain-b`); the hub's `counterparty_chains:` lists two clients (one per
spoke):

```yaml
chains:
  chain-hub:
    ibcv2:
      counterparty_chains:
        client-0: "41001"   # hub → A
        client-1: "41002"   # hub → B
```

The proof-api is a **locally-built** Rust image (`besu-trio/proof-api:local`,
see [Local proof-api image](#local-proof-api-image)). Its
`ibc/local/relayer.json` has four modules — one per direction — all named
`besu_to_besu`. Uniqueness across directions is carried by the
`(src_chain, dst_chain)` pair (the relayer-builder hashmap key), not by the
module name. Per-module config matches `BesuToBesuConfig`:

```json
{
  "name": "besu_to_besu",
  "enabled": true,
  "src_chain": "41001",
  "dst_chain": "41000",
  "config": {
    "src_chain_id": "41001",
    "src_rpc_url": "http://besu-a:8545",
    "src_ics26_address": "0x…",
    "dst_rpc_url": "http://besu-hub:8545",
    "dst_ics26_address": "0x…",
    "consensus_type": "qbft"
  }
}
```

`docker compose logs proof-api` should show four `Service added successfully`
lines on startup.

## Wire (Phase 4)

`./setup.sh wire` deploys a `BesuQBFTLightClient` on each chain and calls
`ICS26Router.addClient` on both sides of each pair. The QBFT LC verifies
counterparty headers + storage proofs cryptographically — trust comes from
the QBFT validator set, not from an attestor address. (The 4 attestors stay
configured for proof-api packet flow, but they are not load-bearing for LC
trust.)

Default source branch is `gjermund/besu-poc` (`SOLIDITY_IBC_TAG`), the
solidity-ibc-eureka branch where `BesuQBFTLightClient` lives. `fetch_solidity_ibc`
flattens slashes in the tag to dashes for the cache directory.

Per pair (A↔hub, B↔hub):

1. Read each chain's current head height + timestamp (`eth_getBlockByNumber`).
2. Read each chain's `ICS26Router` storage root (`eth_getProof` → `.storageHash`).
3. Predict the next client ID on each side (`ICS26Router.getNextClientSeq()` → `client-N`).
4. Deploy on the **hub**:
   ```
   BesuQBFTLightClient(
     ibcRouter=<spoke router>,
     initHeight=<spoke head>,
     initTimestamp=<spoke ts>,
     initStorageRoot=<spoke router storageHash>,
     initValidators=[<spoke's QBFT validator>],
     trustingPeriod=86400,
     maxClockDrift=30,
     roleManager=0x0
   )
   ```
5. Deploy the mirror on the **spoke** with hub's state.
6. `hub.ICS26Router.addClient((spoke_predicted_id, [0x]), hub_side_lc)`
7. `spoke.ICS26Router.addClient((hub_predicted_id, [0x]), spoke_side_lc)`
8. Persist `${SPOKE}_LC_ADDR`, `${SPOKE}_LC_ID`, `HUB_LC_FOR_${SPOKE}_ADDR`,
   `HUB_LC_FOR_${SPOKE}_ID` to `ibc/state.env`.

After both pairs are wired, `generate_relayer_config` re-runs against the
populated `*_LC_ID` vars so the relayer's `counterparty_chains` blocks fill
in:

```yaml
chain-hub:
  ibcv2:
    counterparty_chains:
      client-0: "41001"   # hub → A
      client-1: "41002"   # hub → B
```

The relayer is then restarted to pick the new config up. The deployer key
(Anvil dev #0) holds AccessManager admin via `MinimalDeploy`, so `addClient`
succeeds without explicit role grants.

Tunables (export before `./setup.sh wire`):
- `QBFT_LC_TRUSTING_PERIOD` (default `86400` = 1 day)
- `QBFT_LC_MAX_CLOCK_DRIFT` (default `30` seconds)

## Transfer (Phase 5)

`./setup.sh transfer <direction> [amount]` exercises end-to-end IFT flow over
a wired pair. Each invocation:

1. Lazy-deploys `EVMIFTSendCallConstructor` on each chain (one-time per
   chain, persisted as `A_EVM_IFT_CTOR_ADDR`, `hub_EVM_IFT_CTOR_ADDR`,
   `B_EVM_IFT_CTOR_ADDR` in `state.env`) — `MinimalDeploy.s.sol` doesn't
   include it.
2. Registers IFT bridges on **both** sides of the pair (idempotent —
   `getIFTBridge` reverts when missing, register on revert):
   - **Source:** `bridge[src_lc_id] = (dst_TestIFT_checksummed, src_ctor)` —
     used by the outbound `iftTransfer` to compute the cross-chain payload
     and look up the counterparty TestIFT address.
   - **Destination:** `bridge[dst_lc_id] = (src_TestIFT_checksummed, dst_ctor)` —
     `iftMint` on the destination compares
     `bridge.counterpartyIFTAddress == accountId.sender` byte-for-byte; the
     destination needs its own entry keyed by *its* local client ID for the
     source chain. Without this, the packet delivers but the app-layer mint
     reverts → `COMPLETE_WITH_WRITE_ACK_ERROR`.
3. Mints enough TestIFT to the deployer on the source chain to cover the
   amount (deployer is owner per `MinimalDeploy`; mint is a no-op if the
   balance already suffices).
4. Calls `TestIFT.iftTransfer(clientId, deployer, amount, now+1200s)` —
   burns on source, emits an IBC packet via `ICS27GMP.sendCall` on
   `gmpport`.
5. Submits the resulting source tx hash to the Go relayer at
   `relayer:3000` over `skip.relayer.RelayerApiService/Relay` (gRPC).
6. Polls the destination's TestIFT balance for the receiver until it
   differs from the pre-transfer baseline (180s default cap).

Directions:
- `a-to-hub`, `hub-to-a` — A↔hub pair
- `hub-to-b`, `b-to-hub` — B↔hub pair
- `a-hub-b` — sequential A→hub then hub→B (single command, two transfers)

Counterparty TestIFT addresses are normalised via `cast --to-checksum-address`
before registration — `accountId.sender` from `ICS27GMP` arrives in EIP-55
checksum form, and the `iftMint` equality check is exact bytes.

## state.env keys

After a full end-to-end run, `ibc/state.env` contains:

```
# Phase 2 (contracts)
{A,hub,B}_ICS26_ROUTER_ADDR
{A,hub,B}_ICS27_GMP_ADDR
{A,hub,B}_IFT_CONTRACT_ADDR

# Phase 3 (services — attestor keystore addresses)
ATTESTOR_{A_TO_HUB,HUB_TO_A,HUB_TO_B,B_TO_HUB}_ADDR

# Phase 4 (wire — BesuQBFTLightClient deploys + addClient)
A_LC_ADDR              # LC contract on A (tracking hub)
A_LC_ID                # local client ID on A
B_LC_ADDR              # LC contract on B (tracking hub)
B_LC_ID                # local client ID on B
HUB_LC_FOR_A_ADDR      # LC contract on hub (tracking A)
HUB_LC_FOR_A_ID        # local client ID on hub for the A pair
HUB_LC_FOR_B_ADDR      # LC contract on hub (tracking B)
HUB_LC_FOR_B_ID        # local client ID on hub for the B pair

# Phase 5 (transfer — EVM IFT send-call constructors)
{A,hub,B}_EVM_IFT_CTOR_ADDR
```

Note the casing convention is intentionally mixed: chain prefixes are kept
verbatim (`A_*`, `hub_*`, `B_*`) so they match the relayer-config.yml.tmpl
substitution names; everything else is uppercase.

## What's not here

- Multi-attestor quorums.
- Application-layer recvPacket retries / observability flows beyond
  `_wait_for_ift_balance_change`.
- A separate `eth_to_eth` proof-api module path (would need switching the
  on-chain LC back to `AttestationLightClient` and reconnecting attestor
  endpoints in `relayer.json`).
