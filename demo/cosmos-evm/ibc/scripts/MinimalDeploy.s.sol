// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

// Minimal deployment of the IBC stack used by this demo.
// Auth model: deployer (msg.sender) is the AccessManager admin AND the
// relayer EOA (lib/ibc.sh::generate_relayer_config uses ETH_VALIDATOR_PRIVKEY
// for both). With no setTargetFunctionRole calls, OpenZeppelin AccessManager
// defaults `restricted` functions to ADMIN_ROLE — which the deployer holds —
// so addIBCApp / recvPacket / ackPacket / timeoutPacket all succeed without
// explicit role grants. Sufficient for this single-validator devnet; a real
// deployment needs proper role wiring (see scripts/MinimalDeploy.s.sol's
// accessManagerSetTargetRoles + accessManagerSetRoles helpers).

import { stdJson } from "forge-std/StdJson.sol";
import { Script } from "forge-std/Script.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";

import { ICS26Router } from "../contracts/ICS26Router.sol";
import { ICS27GMP } from "../contracts/ICS27GMP.sol";
import { ICS27Account } from "../contracts/utils/ICS27Account.sol";
import { ICS27Lib } from "../contracts/utils/ICS27Lib.sol";
import { TestIFT } from "../test/solidity-ibc/mocks/TestIFT.sol";

contract MinimalDeploy is Script {
    using stdJson for string;

    string internal constant IFT_TOKEN_NAME   = "Test IFT";
    string internal constant IFT_TOKEN_SYMBOL = "TIFT";

    struct Deployed {
        address ics26Router;
        address ics27Gmp;
        address ift;
    }

    /// @notice Deploys ICS26Router + ICS27GMP + TestIFT (minimal stack).
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

        address routerLogic = address(new ICS26Router());
        d.ics26Router = address(
            new ERC1967Proxy(routerLogic, abi.encodeCall(ICS26Router.initialize, (address(am))))
        );

        address account  = address(new ICS27Account());
        address gmpLogic = address(new ICS27GMP());
        d.ics27Gmp = address(
            new ERC1967Proxy(
                gmpLogic, abi.encodeCall(ICS27GMP.initialize, (d.ics26Router, account, address(am)))
            )
        );

        // Deployer is the AccessManager admin, which satisfies addIBCApp's
        // `restricted` modifier in the absence of a setTargetFunctionRole
        // binding (default = ADMIN_ROLE).
        ICS26Router(d.ics26Router).addIBCApp(ICS27Lib.DEFAULT_PORT_ID, d.ics27Gmp);

        address iftLogic = address(new TestIFT());
        d.ift = address(
            new ERC1967Proxy(
                iftLogic,
                abi.encodeCall(
                    TestIFT.initialize, (msg.sender, IFT_TOKEN_NAME, IFT_TOKEN_SYMBOL, d.ics27Gmp)
                )
            )
        );
    }

    function _toJson(Deployed memory d) internal returns (string memory) {
        string memory json = "json";
        json.serialize("ics26Router", Strings.toHexString(d.ics26Router));
        json.serialize("ics27Gmp",    Strings.toHexString(d.ics27Gmp));
        return json.serialize("ift",  Strings.toHexString(d.ift));
    }
}
