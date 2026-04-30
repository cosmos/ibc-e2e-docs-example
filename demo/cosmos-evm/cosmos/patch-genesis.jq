# Patch freshly-initialised Cosmos genesis (sandbox PoA+EVM image).
#
# `sandboxd init --default-denom uatom` already wires bond_denom / mint_denom /
# gov.params.min_deposit / evm.params.evm_denom to uatom in the modules it
# initialises (the sandbox app doesn't ship `staking`, `mint`, or `crisis`
# at all — those are wfchain-only). What's still missing after init:
#
#   • IFT module authority is empty by default → set to the validator so
#     `tx ift register-bridge` works with --from validator. The default
#     authority is the gov module account, which would require a full
#     proposal + voting period to register a bridge — too heavy for a
#     devnet demo.
#   • PoA admin is hard-coded to a stand-in account → set to validator.
#   • PoA validators list is empty → inject one entry. PoA's genesis init
#     rejects total_power == 0, so we populate it before the chain boots.
#     The consensus_pubkey base64 must match priv_validator_key.json's
#     pub_key.value (the key sandboxd init wrote, which CometBFT signs
#     blocks with for this node — registering a different key would
#     deadlock at height 1).
#
# Required jq args:
#   --arg validator_addr   <bech32 validator address>
#   --arg consensus_pubkey <base64 ed25519 pubkey from priv_validator_key.json>

.app_state.ift.params.authority = $validator_addr |
.app_state.poa.params.admin     = $validator_addr |
.app_state.poa.validators = [{
  "pub_key": {
    "@type": "/cosmos.crypto.ed25519.PubKey",
    "key": $consensus_pubkey
  },
  "power": "1000",
  "metadata": {
    "operator_address": $validator_addr,
    "moniker": "sandbox-node"
  }
}] |
# Disable EIP-1559 base_fee. Sandbox's feemarket module ships with
# base_fee = 1e9 uatom by default; with that on, every tx requires a
# gas-price > 1e9 uatom and our 0.025uatom from --gas-prices fails
# CheckTx with "gas prices too low … required: 512908935.546…uatom".
# Setting no_base_fee=true reverts the chain to legacy gas pricing,
# so the floor becomes app.toml's min-gas-prices (0.025uatom).
.app_state.feemarket.params.no_base_fee = true
