// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";

/// @notice Outputs calldata for enabling L2 buy operations.
///         Step 1 (L1): Push the current exchange rate to L2 via sPOLMessenger.updateL2ExchangeRate().
///         Step 2 (L2): After the state sync arrives (~15-30 min), unpause buys via sPOLChild.unpauseBuy().
///         Output is markdown-formatted for pasting into a GitHub issue.
///
/// @dev Usage:
///         forge script script/operations/EnableL2.s.sol
///
///      Reads deployed addresses from script/deployment-mainnet.json and the admin Safe
///      from script/input.json (ethereum-polygon.admin). No env vars required.
contract EnableL2 is Script {
    function run() public view {
        string memory deployJson = vm.readFile("script/deployment-mainnet.json");
        string memory inputJson = vm.readFile("script/input.json");

        address messengerAddr = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLMessengerProxy");
        address childAddr = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxy");
        address adminSafe = vm.parseJsonAddress(inputJson, ".ethereum-polygon.admin");

        console.log("# Enable L2 sPOL Buys");
        console.log("");
        console.log("**Executor (admin Safe):** `%s`", adminSafe);
        console.log("");

        // ─── Step 1: L1 ──────────────────────────────────────────────────────

        console.log("## Step 1 -- L1 (Ethereum): Push exchange rate to L2");
        console.log("");
        console.log("**From:** `%s` (admin Safe)", adminSafe);
        console.log("**To:** `%s` (sPOLMessenger)", messengerAddr);
        console.log("");
        console.log("Calls `updateL2ExchangeRate()` which reads the current L1 exchange rate");
        console.log("from sPOLController and sends it to sPOLChild via Polygon state sync.");
        console.log("");

        _logCalldata("### updateL2ExchangeRate()", abi.encodeCall(sPOLMessenger.updateL2ExchangeRate, ()));

        console.log("> **Wait** for the state sync to arrive on L2 (~15-30 min).");
        console.log("> Verify it arrived by checking `lastExchangeRateUpdate` is non-zero:");
        console.log(">");
        console.log("> ```");
        console.log(
            string.concat(
                "> cast call ", vm.toString(childAddr), " 'lastExchangeRateUpdate()(uint256)' --rpc-url $L2_RPC_URL"
            )
        );
        console.log("> ```");
        console.log(">");
        console.log("> Once this returns a recent timestamp, proceed to step 2.");
        console.log("");

        // ─── Step 2: L2 ──────────────────────────────────────────────────────

        console.log("---");
        console.log("");
        console.log("## Step 2 -- L2 (Polygon): Unpause buys");
        console.log("");
        console.log("**From:** `%s` (admin Safe)", adminSafe);
        console.log("**To:** `%s` (sPOLChild)", childAddr);
        console.log("");
        console.log("Calls `unpauseBuy()` which will revert if the exchange rate has not been");
        console.log("received yet or is stale (older than `maxExchangeRateUpdateDelay`).");
        console.log("");

        _logCalldata("### unpauseBuy()", abi.encodeCall(sPOLChild.unpauseBuy, ()));
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
