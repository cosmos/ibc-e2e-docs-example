# Step 6: Wire the Bridge

After the previous step, both chains have a light client for the counterparty, but nothing yet connects them. This step does three things:

- **Links the two clients**: registers each client's counterparty on-chain so the IBC module knows which client to use when sending packets.
- **Wires the IFT application bridge**: tells each chain's IFT module which addresses and denoms correspond across chains, and what to mint or burn when a packet arrives.
- **Tells the relayer which connections to watch**: updates the relayer config with the client IDs it should relay for.

Run [`setup.sh`](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/setup.sh):

```bash
./setup.sh wire
```

## What the script does

### 1. Register the counterparty client

The Cosmos chain needs an on-chain record that its attestation client's counterparty is the EVM client. The script submits:

```bash
cosmos tx ibc client add-counterparty $COSMOS_CLIENT_ID $EVM_CLIENT_ID ""
```

The IBC module uses this record to route outgoing packets to the correct client when sending to the EVM chain.

### 2. Register the IFT bridge (Cosmos side)

Two transactions are submitted on the Cosmos chain.

First, if the tokenfactory denom does not yet exist, it is created:

```bash
cosmos tx tokenfactory create-denom $subdenom
```

The denom takes the form `factory/{creator_addr}/{subdenom}`.

Then the IFT bridge is registered:

```bash
cosmos tx ift register-bridge $COSMOS_IFT_DENOM $COSMOS_CLIENT_ID $IFT_CONTRACT_ADDR evm
```

This tells the Cosmos IFT module: packets arriving on `COSMOS_CLIENT_ID` correspond to the EVM IFT contract at `$IFT_CONTRACT_ADDR`. When a packet arrives from that contract, the module mints `$COSMOS_IFT_DENOM`. When tokens are sent in the other direction, the module burns them and sends a packet to that contract.

Output: `COSMOS_IFT_DENOM` in the format `factory/{creator_addr}/{subdenom}`.

### 3. Register the IFT bridge (EVM side)

The EVM side requires a constructor contract and a bridge registration on the IFT contract.

**Compute the GMP account address**

The GMP module derives a Cosmos account deterministically from the source client ID, the sender contract address, and a salt. This is the account that the GMP module uses to submit the embedded `MsgIFTMint` on Cosmos when a packet arrives from the EVM:

```bash
sandboxd query gmp get-address $COSMOS_CLIENT_ID $IFT_CONTRACT_ADDR ""
```

This address is baked into the `CosmosIFTSendCallConstructor` at deploy time.

**Deploy `CosmosIFTSendCallConstructor`**

This contract encodes the `MsgIFTMint` message for EVM-to-Cosmos transfers. It is initialized with:

- `typeUrl`: `/ibc.applications.prototypes.ift.v1.MsgIFTMint`
- `denom`: `COSMOS_IFT_DENOM`
- `icaAddress`: the GMP account address computed above

**Register the bridge on the IFT contract**

```
IFTOwnable.registerIFTBridge(
  client: EVM_CLIENT_ID,
  module: COSMOS_IFT_MODULE,
  ctor:   CTOR_ADDR
)
```

| Argument | Description |
| --- | --- |
| `client` | EVM client ID that routes Cosmos-to-EVM packets to this bridge |
| `module` | Cosmos IFT module account address -- the authorized sender for Cosmos-to-EVM packets |
| `ctor` | Address of the deployed `CosmosIFTSendCallConstructor` |

### 4. Finalize the relayer config

The relayer was started in the previous step with empty `counterparty_chains` mappings. Now that both client IDs are known, the script re-renders the config with the mappings filled in ([template](https://github.com/cosmos/ibc-e2e-docs-example/blob/main/demo/cosmos-evm/ibc/relayer-config.yml.tmpl)) and restarts the relayer:

```yaml
chains:
  cosmos:
    ibcv2:
      counterparty_chains:
        <COSMOS_CLIENT_ID>: <EVM_CHAIN_ID>

  besu:
    ibcv2:
      counterparty_chains:
        <EVM_CLIENT_ID>: <COSMOS_CHAIN_ID>
```

The relayer only relays packets for connections listed in `counterparty_chains`.

## Applying to your own setup

### Counterparty registration

`add-counterparty` only needs to be run once per client pair. If you recreate a client (for example, after a chain reset), you must re-register the counterparty.

### IFT denom

The tokenfactory denom is fixed to the creator address at creation time. If you deploy to a different chain or use a different key, the denom changes and existing balances are not migrated.

### GMP account address

The GMP account address is deterministically derived from `(client_id, contract_addr, salt)`. If the client ID or IFT contract address changes, the GMP account address changes and `CosmosIFTSendCallConstructor` must be redeployed and re-registered.

## Next steps

<!-- todo: add link -->

With the bridge wired, the next step sends a live token transfer and validates the full packet relay flow.
