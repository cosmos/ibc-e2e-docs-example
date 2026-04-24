# Embed the 08-wasm Ethereum light client binary directly in genesis, bypassing
# the governance store-code flow. The client is then available from block 0.
# Args (via --arg): code (base64 wasm), hash (base64 sha256 of wasm)
.app_state["08-wasm"].contracts += [{"code_hash": $hash, "contract_code": $code}]
