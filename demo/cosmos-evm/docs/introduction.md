# Cosmos<>EVM Interoperability Tutorial

This tutorial walks you through setting up a live IBC connection between a Cosmos chain and an EVM (Besu) chain. This demo uses IFT token transfers to transfer tokens directly between the two chains. 

By the end, you will have a fully wired IBC-connection: contracts deployed, attestors and relayer running, light clients created on both sides, and token transfers verified end-to-end.

You can find the tutorial demo repo here: [https://github.com/cosmos/ibc-e2e-docs-example](https://github.com/cosmos/ibc-e2e-docs-example)

The tutorial is built around a working demo that runs a [Cosmos sandbox chain](https://github.com/cosmos/sandbox-ledger) and a [Besu](https://github.com/hyperledger/besu) EVM node locally. You can use this demo as an example implementation for integrating Cosmos to EVM IBC functionality into your own chains.

For conceptual background on how the system works before diving in, see the [architecture overview](./overview.md).

<!-- todo: update link above -->

## What you will set up

The tutorial covers these steps in order:

1. Starting the chains. The demo brings up a Cosmos sandbox chain and a Besu EVM node. For a real integration, your chains are already running and this step describes what state and endpoints the rest of the setup depends on.

2. Deploy EVM contracts. The IBC stack on the EVM side is a set of Solidity contracts deployed to the chain. This includes the ICS-26 Router, ICS-27 GMP, and the IFT token contract.

3. Configure and start the attestors. Two attestor instances run per deployment, one watching each chain. They sign packet state on demand for the Proof API.

4. Configure and start the Proof API and relayer. The Proof API aggregates attestor signatures into relay-ready proofs. The relayer uses those proofs to submit packet delivery and timeout transactions on both chains.

5. Create attestation light clients. Each chain needs a light client that can verify packets arriving from the other side. Both are initialized with the same attestor signer set.

6. Wire the bridge. This links the two light clients as counterparties and registers the IFT token contract on each side so the bridge knows what to burn and mint.

7. Validate. Run token transfers in both directions and verify the final balances. The demo also covers packet tracking, the timeout and refund path, and how to read relayer and attestor logs.

<!-- todo: link the above to their respective pages -->

## About this example

The demo is designed to run end-to-end with minimal setup. It should be used as reference-only. For ease of use and demonstration purposes, several things are simplified or preconfigured: keys, quorum thresholds, finality offsets, and access controls. For example, the EVM deployer uses the well-known Hardhat test key which should not be used with real funds. For a full production deployment, each of these should be reviewed and configured appropriately for your environment. 