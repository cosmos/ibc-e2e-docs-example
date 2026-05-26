// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

// Minimal deployment of the IBC stack used by this demo.
//
// Eureka contracts (ICS26Router, ICS27GMP, ICS27Account, IFTOwnable) are
// loaded from the prebuilt release bundle published at:
//   https://github.com/cosmos/solidity-ibc-eureka/releases/download/
//     solidity-v3.0.0/solidity-contracts-solidity-v3.0.0.tar.gz
// lib/ibc.sh::fetch_release_bytecode extracts the archive's `bytecode/`
// directory to `$SOLIDITY_IBC_DIR/release-bytecode/`; `vm.getCode` reads
// each JSON artifact and we deploy the raw runtime via the CREATE opcode.
// This removes any compile-time coupling to the solidity-ibc-eureka source
// tree — only OpenZeppelin (AccessManager, ERC1967Proxy) and forge-std are
// imported from Solidity.
//
// Auth model: deployer (msg.sender) is the AccessManager admin AND the
// relayer EOA (lib/ibc.sh::generate_relayer_config uses ETH_VALIDATOR_PRIVKEY
// for both). With no setTargetFunctionRole calls, OpenZeppelin AccessManager
// defaults `restricted` functions to ADMIN_ROLE — which the deployer holds —
// so addIBCApp / recvPacket / ackPacket / timeoutPacket all succeed without
// explicit role grants. Sufficient for this single-validator devnet.

import { stdJson } from "forge-std/StdJson.sol";
import { Script } from "forge-std/Script.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";

contract MinimalDeploy is Script {
    using stdJson for string;

    // Aligned with the Cosmos-side denom (`uift`, set in
    // lib/ibc.sh::register_ift_bridges) so EVM wallets and Cosmos REST
    // queries surface the same token under matching names. ERC20 ALL-CAPS
    // convention is preserved on the symbol (UIFT vs uift); the descriptive
    // name spells out the Cosmos linkage.
    string internal constant IFT_TOKEN_NAME   = "Test uift";
    string internal constant IFT_TOKEN_SYMBOL = "UIFT";

    // Matches ICS27Lib.DEFAULT_PORT_ID in solidity-ibc-eureka — hardcoded
    // here because the library is no longer imported as source.
    string internal constant DEFAULT_PORT_ID = "gmpport";

    // Foundry artifact paths, relative to the forge project root. Populated
    // by lib/ibc.sh::fetch_release_bytecode from the release tarball.
    string internal constant ARTIFACT_ROUTER  = "release-bytecode/ICS26Router.json";
    string internal constant ARTIFACT_GMP     = "release-bytecode/ICS27GMP.json";
    string internal constant ARTIFACT_ACCOUNT = "release-bytecode/ICS27Account.json";
    string internal constant ARTIFACT_IFT     = "release-bytecode/IFTOwnable.json";

    struct Deployed {
        address ics26Router;
        address ics27Gmp;
        address ift;
    }

    /// @notice Deploys ICS26Router + ICS27GMP + IFTOwnable (minimal stack)
    ///         from prebuilt release bytecode.
    /// @return JSON address map. Labels MUST match what
    ///         lib/ibc.sh::_forge_return_addr extracts:
    ///           ics26Router → ICS26_ROUTER_ADDR
    ///           ics27Gmp    → ICS27_GMP_ADDR
    ///           ift         → IFT_CONTRACT_ADDR
    function run() public returns (string memory) {
        vm.startBroadcast();
        Deployed memory d = _deploy();
        vm.stopBroadcast();
        return _toJson(d);
    }

    function _deploy() internal returns (Deployed memory d) {
        AccessManager am = new AccessManager(msg.sender);

        address routerLogic = _deployArtifact(ARTIFACT_ROUTER);
        d.ics26Router = address(
            new ERC1967Proxy(
                routerLogic,
                abi.encodeWithSignature("initialize(address)", address(am))
            )
        );

        address account  = _deployArtifact(ARTIFACT_ACCOUNT);
        address gmpLogic = _deployArtifact(ARTIFACT_GMP);
        d.ics27Gmp = address(
            new ERC1967Proxy(
                gmpLogic,
                abi.encodeWithSignature(
                    "initialize(address,address,address)",
                    d.ics26Router, account, address(am)
                )
            )
        );

        // Deployer is the AccessManager admin, which satisfies addIBCApp's
        // `restricted` modifier in the absence of a setTargetFunctionRole
        // binding (default = ADMIN_ROLE).
        (bool ok, bytes memory ret) = d.ics26Router.call(
            abi.encodeWithSignature(
                "addIBCApp(string,address)", DEFAULT_PORT_ID, d.ics27Gmp
            )
        );
        require(ok, _revertMessage("addIBCApp failed", ret));

        address iftLogic = _deployArtifact(ARTIFACT_IFT);
        d.ift = address(
            new ERC1967Proxy(
                iftLogic,
                abi.encodeWithSignature(
                    "initialize(address,string,string,address)",
                    msg.sender, IFT_TOKEN_NAME, IFT_TOKEN_SYMBOL, d.ics27Gmp
                )
            )
        );
    }

    function _deployArtifact(string memory path) internal returns (address addr) {
        bytes memory code = vm.getCode(path);
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), string.concat("create failed: ", path));
    }

    function _revertMessage(string memory prefix, bytes memory ret)
        internal pure returns (string memory)
    {
        if (ret.length == 0) return prefix;
        return string.concat(prefix, ": ", string(ret));
    }

    function _toJson(Deployed memory d) internal returns (string memory) {
        string memory json = "json";
        json.serialize("ics26Router", Strings.toHexString(d.ics26Router));
        json.serialize("ics27Gmp",    Strings.toHexString(d.ics27Gmp));
        return json.serialize("ift",  Strings.toHexString(d.ift));
    }
}
