// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {sPOLController} from "../../src/sPOLController.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {PolBridger} from "../../src/polBridger.sol";

/// @notice Outputs calldata for creating the SPOL_PAUSER_ROLE on both L1 and L2 AccessManagers.
///         The pauser can pause (but not unpause): sPOLController (L1), sPOLChild (L2), polBridger (both).
contract PauserRole is Script {
    uint64 constant SPOL_PAUSER_ROLE = 1;

    function run() public view {
        string memory json = vm.readFile("script/deployment-mainnet.json");

        address accessManagerL1 = vm.parseJsonAddress(json, ".sPOL_L1.accessManagerL1");
        address accessManagerL2 = vm.parseJsonAddress(json, ".sPOL_L2.accessManagerL2");
        address controllerAddr = vm.parseJsonAddress(json, ".sPOL_L1.sPOLControllerProxy");
        address childAddr = vm.parseJsonAddress(json, ".sPOL_L2.sPOLChildProxy");
        address polBridgerL1 = vm.parseJsonAddress(json, ".sPOL_L1.polBridger");
        address polBridgerL2 = vm.parseJsonAddress(json, ".sPOL_L2.polBridger");
        address pauser = vm.envAddress("PAUSER_ADDRESS");

        // ─── L1 AccessManager ───────────────────────────────────────────────

        console.log("========================================");
        console.log("  L1 AccessManager Calldata");
        console.log("========================================");
        console.log("Target for all L1 calls: %s (AccessManager)", accessManagerL1);
        console.log("");

        // 1. Label the role
        bytes memory labelCalldata = abi.encodeCall(AccessManager.labelRole, (SPOL_PAUSER_ROLE, "SPOL_PAUSER"));
        console.log("1. labelRole(%d, 'SPOL_PAUSER')", SPOL_PAUSER_ROLE);
        console.log("   Calldata:");
        console.logBytes(labelCalldata);
        console.log("");

        // 2. Grant role to pauser
        bytes memory grantCalldata = abi.encodeCall(AccessManager.grantRole, (SPOL_PAUSER_ROLE, pauser, 0));
        console.log("2. grantRole(%d, %s, 0)", SPOL_PAUSER_ROLE, pauser);
        console.log("   Calldata:");
        console.logBytes(grantCalldata);
        console.log("");

        // 3. Assign sPOLController pause to the role
        bytes4[] memory controllerSelectors = new bytes4[](1);
        controllerSelectors[0] = sPOLController.pauseUserFunctions.selector;
        bytes memory controllerRoleCalldata = abi.encodeCall(
            AccessManager.setTargetFunctionRole, (controllerAddr, controllerSelectors, SPOL_PAUSER_ROLE)
        );
        console.log("3. setTargetFunctionRole(%s, [pauseUserFunctions], %d)", controllerAddr, SPOL_PAUSER_ROLE);
        console.log("   Calldata:");
        console.logBytes(controllerRoleCalldata);
        console.log("");

        // 4. Assign polBridger (L1) pause to the role
        bytes4[] memory bridgerSelectors = new bytes4[](1);
        bridgerSelectors[0] = PolBridger.pause.selector;
        bytes memory bridgerL1RoleCalldata =
            abi.encodeCall(AccessManager.setTargetFunctionRole, (polBridgerL1, bridgerSelectors, SPOL_PAUSER_ROLE));
        console.log("4. setTargetFunctionRole(%s, [pause], %d)", polBridgerL1, SPOL_PAUSER_ROLE);
        console.log("   Calldata:");
        console.logBytes(bridgerL1RoleCalldata);
        console.log("");

        // 5. Grant the role to the admin Safe so it can also pause directly
        address adminSafe = 0x619D553686958A873A62B336b2DD97C3b25134EA;
        bytes memory grantAdminCalldata = abi.encodeCall(AccessManager.grantRole, (SPOL_PAUSER_ROLE, adminSafe, 0));
        console.log("5. grantRole(%d, %s, 0) -- admin Safe", SPOL_PAUSER_ROLE, adminSafe);
        console.log("   Calldata:");
        console.logBytes(grantAdminCalldata);
        console.log("");

        // ─── L2 AccessManager ───────────────────────────────────────────────

        console.log("========================================");
        console.log("  L2 AccessManager Calldata");
        console.log("========================================");
        console.log("Target for all L2 calls: %s (AccessManager)", accessManagerL2);
        console.log("");

        // 6. Label the role (L2)
        console.log("6. labelRole(%d, 'SPOL_PAUSER')", SPOL_PAUSER_ROLE);
        console.log("   Calldata:");
        console.logBytes(labelCalldata); // same encoding as L1
        console.log("");

        // 7. Grant role to pauser (L2)
        console.log("7. grantRole(%d, %s, 0)", SPOL_PAUSER_ROLE, pauser);
        console.log("   Calldata:");
        console.logBytes(grantCalldata); // same encoding as L1
        console.log("");

        // 8. Assign sPOLChild pauseBuy to the role
        bytes4[] memory childSelectors = new bytes4[](1);
        childSelectors[0] = sPOLChild.pauseBuy.selector;
        bytes memory childRoleCalldata =
            abi.encodeCall(AccessManager.setTargetFunctionRole, (childAddr, childSelectors, SPOL_PAUSER_ROLE));
        console.log("8. setTargetFunctionRole(%s, [pauseBuy], %d)", childAddr, SPOL_PAUSER_ROLE);
        console.log("   Calldata:");
        console.logBytes(childRoleCalldata);
        console.log("");

        // 9. Assign polBridger (L2) pause to the role
        bytes memory bridgerL2RoleCalldata =
            abi.encodeCall(AccessManager.setTargetFunctionRole, (polBridgerL2, bridgerSelectors, SPOL_PAUSER_ROLE));
        console.log("9. setTargetFunctionRole(%s, [pause], %d)", polBridgerL2, SPOL_PAUSER_ROLE);
        console.log("   Calldata:");
        console.logBytes(bridgerL2RoleCalldata);
        console.log("");

        // 10. Grant the role to the admin Safe on L2
        console.log("10. grantRole(%d, %s, 0) -- admin Safe", SPOL_PAUSER_ROLE, adminSafe);
        console.log("    Calldata:");
        console.logBytes(grantAdminCalldata); // same encoding as L1
        console.log("");
    }
}
