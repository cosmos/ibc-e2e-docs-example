# Patch freshly-initialised Cosmos genesis:
#   • bond_denom / mint_denom / crisis fee / gov min_deposit → uatom
#   • IFT module authority → the validator address, so `tx ift register-bridge`
#     can be called directly with --from validator. Out of the box the
#     authority is the gov module account, which would require a full
#     proposal + voting period to register a bridge — too heavy for a
#     devnet demo. Requires --arg validator_addr <wf1…>.
.app_state.staking.params.bond_denom = "uatom" |
.app_state.mint.params.mint_denom    = "uatom" |
.app_state.crisis.constant_fee.denom = "uatom" |
(.app_state.gov.params.min_deposit // []) |= map(if .denom == "stake" then .denom = "uatom" else . end) |
(if .app_state.ift and .app_state.ift.params
 then .app_state.ift.params.authority = $validator_addr
 else .
 end)
