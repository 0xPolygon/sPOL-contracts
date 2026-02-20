// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {MocksPOLMessenger} from "../mocks/MocksPOLMessenger.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {MsgCoder} from "../../src/MsgCoder.sol";

contract sPOLMessengerTest is Test {
    MocksPOLMessenger public messenger;

    function setUp() public {
        messenger = new MocksPOLMessenger(
            makeAddr("polToken"),
            makeAddr("sPOLToken"),
            makeAddr("sPOLController"),
            makeAddr("rootChainManager"),
            makeAddr("depositManager"),
            makeAddr("stateSender"),
            makeAddr("checkpointManager"),
            makeAddr("childTunnel"),
            makeAddr("polBridger")
        );
    }

    function test_processMessageFromChild_emitsOnInvalidMessageType() public {
        bytes memory invalidMessage = abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(1e18, 1e18));

        vm.record();
        vm.expectEmit(true, true, true, true, address(messenger));
        emit sPOLMessenger.InvalidMessageType(uint8(MsgCoder.MsgType.EXCHANGE_UPDATE));
        messenger.expose_processMessageFromChild(invalidMessage);
        (, bytes32[] memory writes) = vm.accesses(address(messenger));
        assertEq(writes.length, 0, "Invalid message should not modify storage");
    }
}
