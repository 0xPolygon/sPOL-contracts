// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IRootChainManager} from "../src/msg/interfaces/IRootChainManager.sol";
import {IStateSender} from "../src/msg/interfaces/IStateSender.sol";

/// @notice Generates calldata for governance proposals to map sPOL on bridge infrastructure
contract BridgeMappingCalldata is Script {
    function run() public view {
        string memory json = vm.readFile("script/deployment-mainnet.json");
        string memory configJson = vm.readFile("script/input.json");

        address spolProxy = vm.parseJsonAddress(json, ".sPOL_L1.sPOLProxy");
        address spolChildProxy = vm.parseJsonAddress(json, ".sPOL_L2.sPOLChildProxy");
        address messengerProxy = vm.parseJsonAddress(json, ".sPOL_L1.sPOLMessengerProxy");

        address rootChainManager = vm.parseJsonAddress(configJson, ".ethereum-polygon.rootChainManager");
        address stateSenderL1 = vm.parseJsonAddress(configJson, ".ethereum-polygon.stateSenderL1");
        address rcmERC20Predicate = vm.parseJsonAddress(configJson, ".ethereum-polygon.rcmERC20Predicate");

        console.log("=== Bridge Mapping Calldata ===");
        console.log("");

        // 1. RootChainManager.mapToken(sPOL L1, sPOLChild L2, tokenType)
        bytes32 tokenType = 0x8ae85d849167ff996c04040c44924fd364217285e4cad818292c7ac37c0a345b;
        bytes memory mapTokenCalldata =
            abi.encodeCall(IRootChainManager.mapToken, (spolProxy, spolChildProxy, tokenType));
        console.log("1. RootChainManager.mapToken");
        console.log("   Target: %s", rootChainManager);
        console.log("   rootToken (sPOL L1): %s", spolProxy);
        console.log("   childToken (sPOLChild L2): %s", spolChildProxy);
        console.log("   tokenType: keccak256('MintableERC20')");
        console.log("   Expected predicate: %s", rcmERC20Predicate);
        console.log("   Calldata:");
        console.logBytes(mapTokenCalldata);
        console.log("");

        // 2. StateSender.register(messenger L1, sPOLChild L2)
        //    Registers the L1 -> L2 state sync tunnel pair
        bytes memory registerCalldata = abi.encodeCall(IStateSender.register, (messengerProxy, spolChildProxy));
        console.log("2. StateSender.register");
        console.log("   Target: %s", stateSenderL1);
        console.log("   sender (sPOLMessenger L1): %s", messengerProxy);
        console.log("   receiver (sPOLChild L2): %s", spolChildProxy);
        console.log("   Calldata:");
        console.logBytes(registerCalldata);
        console.log("");

        console.log("=== Verify before submitting ===");
        console.log("- RootChainManager.typeToPredicate(tokenType) should return: %s", rcmERC20Predicate);
        console.log("- StateSender.owner() must execute the register call");
    }
}
