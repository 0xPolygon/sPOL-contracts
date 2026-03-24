// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";

/// @notice Outputs calldata for creating the Exchange Rate Updater role via the L1 AccessManager.
///         The service EOA can call updateL2ExchangeRate on the sPOLMessenger.
///         Output is markdown-formatted for pasting into a GitHub issue.
///
/// @dev Usage:
///         SERVICE_EOA=0x... forge script script/roleManagement/ExchangeRateUpdaterRole.s.sol
///
///      Reads deployed addresses from script/deployment-mainnet.json and the admin Safe
///      from script/input.json (ethereum-polygon.admin). The SERVICE_EOA env var is the
///      address that will receive the exchange rate updater role.
contract ExchangeRateUpdaterRole is Script {
    uint64 constant SPOL_EXCHANGE_RATE_UPDATER_ROLE = 2;

    function run() public view {
        string memory deployJson = vm.readFile("script/deployment-mainnet.json");
        string memory inputJson = vm.readFile("script/input.json");

        address accessManagerAddr = vm.parseJsonAddress(deployJson, ".sPOL_L1.accessManagerL1");
        address messengerAddr = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLMessengerProxy");
        address adminSafe = vm.parseJsonAddress(inputJson, ".ethereum-polygon.admin");
        address serviceEOA = vm.envAddress("SERVICE_EOA");

        console.log("# SPOL_EXCHANGE_RATE_UPDATER Role Setup");
        console.log("");
        console.log("**Executor (admin Safe):** `%s`", adminSafe);
        console.log("**Service EOA:** `%s`", serviceEOA);
        console.log("**Role ID:** %d", SPOL_EXCHANGE_RATE_UPDATER_ROLE);
        console.log("");
        console.log("## L1 (Ethereum) -- AccessManager `%s`", accessManagerAddr);
        console.log("");
        console.log("All transactions are sent **from** `%s` **to** `%s`.", adminSafe, accessManagerAddr);
        console.log("");

        // 1. Label the role
        _logCalldata(
            "### 1. labelRole(2, 'SPOL_EXCHANGE_RATE_UPDATER')",
            abi.encodeCall(AccessManager.labelRole, (SPOL_EXCHANGE_RATE_UPDATER_ROLE, "SPOL_EXCHANGE_RATE_UPDATER"))
        );

        // 2. Grant role to service EOA
        _logCalldata(
            string.concat("### 2. grantRole(2, `", vm.toString(serviceEOA), "`, 0)"),
            abi.encodeCall(AccessManager.grantRole, (SPOL_EXCHANGE_RATE_UPDATER_ROLE, serviceEOA, 0))
        );

        // 3. Assign messenger updateL2ExchangeRate to the role
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = sPOLMessenger.updateL2ExchangeRate.selector;
            _logCalldata(
                string.concat(
                    "### 3. setTargetFunctionRole(`", vm.toString(messengerAddr), "`, [updateL2ExchangeRate], 2)"
                ),
                abi.encodeCall(
                    AccessManager.setTargetFunctionRole, (messengerAddr, selectors, SPOL_EXCHANGE_RATE_UPDATER_ROLE)
                )
            );
        }

        // 4. Grant the same role to the admin Safe
        //    Once functions are assigned to SPOL_EXCHANGE_RATE_UPDATER_ROLE, the ADMIN_ROLE can no longer
        //    call them directly. Granting the role upfront avoids needing an extra tx in emergencies.
        _logCalldata(
            string.concat(
                "### 4. grantRole(2, `",
                vm.toString(adminSafe),
                "`, 0) -- allows admin Safe to also call updateL2ExchangeRate"
            ),
            abi.encodeCall(AccessManager.grantRole, (SPOL_EXCHANGE_RATE_UPDATER_ROLE, adminSafe, 0))
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
