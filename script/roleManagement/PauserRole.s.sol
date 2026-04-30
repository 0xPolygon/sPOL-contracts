// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {sPOLController} from "../../src/sPOLController.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {PolBridger} from "../../src/polBridger.sol";

/// @notice Outputs calldata for creating the SPOL_PAUSER_ROLE on both L1 and L2 AccessManagers.
///         The pauser can pause (but not unpause): sPOLController (L1), sPOLChild (L2), polBridger (both).
///         Output is markdown-formatted for pasting into a GitHub issue.
///
/// @dev Usage:
///         PAUSER_ADDRESS=0x... forge script script/roleManagement/PauserRole.s.sol
///
///      Reads deployed addresses from script/deployment-mainnet.json and the admin Safe
///      from script/input.json (ethereum-polygon.admin). The PAUSER_ADDRESS env var is the
///      address that will receive the pauser role.
contract PauserRole is Script {
    uint64 constant SPOL_PAUSER_ROLE = 1;

    function run() public view {
        string memory deployJson = vm.readFile("script/deployment-mainnet.json");
        string memory inputJson = vm.readFile("script/input.json");

        address adminSafe = vm.parseJsonAddress(inputJson, ".ethereum-polygon.admin");
        address pauser = vm.envAddress("PAUSER_ADDRESS");

        console.log("# SPOL_PAUSER_ROLE Setup");
        console.log("");
        console.log("**Executor (admin Safe):** `%s`", adminSafe);
        console.log("**Pauser address:** `%s`", pauser);
        console.log("**Role ID:** %d", SPOL_PAUSER_ROLE);
        console.log("");

        _outputL1(deployJson, adminSafe, pauser);
        _outputL2(deployJson, adminSafe, pauser);
    }

    function _outputL1(string memory deployJson, address adminSafe, address pauser) internal pure {
        address accessManager = vm.parseJsonAddress(deployJson, ".sPOL_L1.accessManagerL1");
        address controllerAddr = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLControllerProxy");
        address polBridgerAddr = vm.parseJsonAddress(deployJson, ".sPOL_L1.polBridgerProxy");

        console.log("## L1 (Ethereum) -- AccessManager `%s`", accessManager);
        console.log("");
        console.log("All L1 transactions are sent **from** `%s` **to** `%s`.", adminSafe, accessManager);
        console.log("");

        // 1. Label the role
        _logCalldata(
            "### 1. labelRole(1, 'SPOL_PAUSER')",
            abi.encodeCall(AccessManager.labelRole, (SPOL_PAUSER_ROLE, "SPOL_PAUSER"))
        );

        // 2. Grant role to pauser
        _logCalldata(
            string.concat("### 2. grantRole(1, `", vm.toString(pauser), "`, 0)"),
            abi.encodeCall(AccessManager.grantRole, (SPOL_PAUSER_ROLE, pauser, 0))
        );

        // 3. sPOLController.pauseUserFunctions
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = sPOLController.pauseUserFunctions.selector;
            _logCalldata(
                string.concat(
                    "### 3. setTargetFunctionRole(`", vm.toString(controllerAddr), "`, [pauseUserFunctions], 1)"
                ),
                abi.encodeCall(AccessManager.setTargetFunctionRole, (controllerAddr, selectors, SPOL_PAUSER_ROLE))
            );
        }

        // 4. PolBridger.pause (L1)
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PolBridger.pause.selector;
            _logCalldata(
                string.concat("### 4. setTargetFunctionRole(`", vm.toString(polBridgerAddr), "`, [pause], 1)"),
                abi.encodeCall(AccessManager.setTargetFunctionRole, (polBridgerAddr, selectors, SPOL_PAUSER_ROLE))
            );
        }

        // 5. Grant role to admin Safe
        _logCalldata(
            string.concat("### 5. grantRole(1, `", vm.toString(adminSafe), "`, 0) -- admin Safe"),
            abi.encodeCall(AccessManager.grantRole, (SPOL_PAUSER_ROLE, adminSafe, 0))
        );
    }

    function _outputL2(string memory deployJson, address adminSafe, address pauser) internal pure {
        address accessManager = vm.parseJsonAddress(deployJson, ".sPOL_L2.accessManagerL2");
        address childAddr = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxy");
        address polBridgerAddr = vm.parseJsonAddress(deployJson, ".sPOL_L2.polBridgerProxy");

        console.log("---");
        console.log("");
        console.log("## L2 (Polygon) -- AccessManager `%s`", accessManager);
        console.log("");
        console.log("All L2 transactions are sent **from** `%s` **to** `%s`.", adminSafe, accessManager);
        console.log("");

        // 6. Label the role
        _logCalldata(
            "### 6. labelRole(1, 'SPOL_PAUSER')",
            abi.encodeCall(AccessManager.labelRole, (SPOL_PAUSER_ROLE, "SPOL_PAUSER"))
        );

        // 7. Grant role to pauser
        _logCalldata(
            string.concat("### 7. grantRole(1, `", vm.toString(pauser), "`, 0)"),
            abi.encodeCall(AccessManager.grantRole, (SPOL_PAUSER_ROLE, pauser, 0))
        );

        // 8. sPOLChild.pauseBuy
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = sPOLChild.pauseBuy.selector;
            _logCalldata(
                string.concat("### 8. setTargetFunctionRole(`", vm.toString(childAddr), "`, [pauseBuy], 1)"),
                abi.encodeCall(AccessManager.setTargetFunctionRole, (childAddr, selectors, SPOL_PAUSER_ROLE))
            );
        }

        // 9. PolBridger.pause (L2)
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PolBridger.pause.selector;
            _logCalldata(
                string.concat("### 9. setTargetFunctionRole(`", vm.toString(polBridgerAddr), "`, [pause], 1)"),
                abi.encodeCall(AccessManager.setTargetFunctionRole, (polBridgerAddr, selectors, SPOL_PAUSER_ROLE))
            );
        }

        // 10. Grant role to admin Safe
        _logCalldata(
            string.concat("### 10. grantRole(1, `", vm.toString(adminSafe), "`, 0) -- admin Safe"),
            abi.encodeCall(AccessManager.grantRole, (SPOL_PAUSER_ROLE, adminSafe, 0))
        );
    }

    function _logCalldata(string memory header, bytes memory data) internal pure {
        console.log(header);
        console.log("");
        console.log("```");
        console.logBytes(data);
        console.log("```");
        console.log("");
    }
}
