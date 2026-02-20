// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {sPOLMessenger} from "../src/sPOLMessenger.sol";

/// @notice Outputs calldata for creating the Exchange Rate Updater role via the AccessManager
contract ExchangeRateUpdaterRole is Script {
    uint64 constant EXCHANGE_RATE_UPDATER_ROLE = 1;

    function run() public view {
        string memory json = vm.readFile("script/deployment-mainnet.json");

        address accessManagerAddr = vm.parseJsonAddress(json, ".sPOL_L1.accessManagerL1");
        address messengerAddr = vm.parseJsonAddress(json, ".sPOL_L1.sPOLMessengerProxy");
        address serviceEOA = vm.envAddress("SERVICE_EOA");

        console.log("=== Exchange Rate Updater Role Calldata ===");
        console.log("Target for all calls: %s (AccessManager)", accessManagerAddr);
        console.log("");

        // 1. Label the role
        bytes memory labelCalldata = abi.encodeCall(
            AccessManager.labelRole, (EXCHANGE_RATE_UPDATER_ROLE, "EXCHANGE_RATE_UPDATER")
        );
        console.log("1. labelRole(%d, 'EXCHANGE_RATE_UPDATER')", EXCHANGE_RATE_UPDATER_ROLE);
        console.log("   Calldata:");
        console.logBytes(labelCalldata);
        console.log("");

        // 2. Grant role to service EOA
        bytes memory grantCalldata = abi.encodeCall(
            AccessManager.grantRole, (EXCHANGE_RATE_UPDATER_ROLE, serviceEOA, 0)
        );
        console.log("2. grantRole(%d, %s, 0)", EXCHANGE_RATE_UPDATER_ROLE, serviceEOA);
        console.log("   Calldata:");
        console.logBytes(grantCalldata);
        console.log("");

        // 3. Assign messenger functions to the role
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = sPOLMessenger.updateL2ExchangeRate.selector;
        selectors[1] = sPOLMessenger.completeBackfill.selector;
        bytes memory setRoleCalldata = abi.encodeCall(
            AccessManager.setTargetFunctionRole, (messengerAddr, selectors, EXCHANGE_RATE_UPDATER_ROLE)
        );
        console.log("3. setTargetFunctionRole(%s, [updateL2ExchangeRate, completeBackfill], %d)", messengerAddr, EXCHANGE_RATE_UPDATER_ROLE);
        console.log("   Calldata:");
        console.logBytes(setRoleCalldata);
        console.log("");

        // 4. (Optional) Grant the same role to the admin Safe
        //    Once functions are assigned to EXCHANGE_RATE_UPDATER_ROLE, the ADMIN_ROLE can no longer
        //    call them directly. The admin can always re-grant itself the role or reassign the functions
        //    back to ADMIN_ROLE, but granting the role upfront avoids needing an extra tx in emergencies.
        address adminSafe = 0x619D553686958A873A62B336b2DD97C3b25134EA;
        bytes memory grantAdminCalldata = abi.encodeCall(
            AccessManager.grantRole, (EXCHANGE_RATE_UPDATER_ROLE, adminSafe, 0)
        );
        console.log("4. (Optional) grantRole(%d, %s, 0) -- allows admin Safe to also call these functions", EXCHANGE_RATE_UPDATER_ROLE, adminSafe);
        console.log("   Calldata:");
        console.logBytes(grantAdminCalldata);
        console.log("");
    }
}
