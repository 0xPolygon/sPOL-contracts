// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {BaseChildTunnel} from "../../src/msg/BaseChildTunnel.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MsgCoder} from "../../src/MsgCoder.sol";

contract sPOLChildL1BalanceTest is Test, Deploy {
    sPOLChild public sPOLChildToken;

    // Events from sPOLChild contract
    event sPOLMinted(address user, uint256 amountPOL, uint256 amountSPOL);

    function setUp() public {
        // Create test addresses

        // Set mock values
        loadMockConfig();
        // Custom config
        sPOLMessengerProxy = TransparentUpgradeableProxy(payable(makeAddr("sPOLMessengerProxy")));
        // Deploy contracts
        deployContractsL2(address(this));
        vm.chainId(chainIdL2);

        // Get deployed contract instances
        sPOLChildToken = sPOLChild(payable(sPOLChildProxy));

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );

        bytes memory message = abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(1, 1));
        vm.prank(stateSyncerL2);
        sPOLChildToken.onStateReceive(0, message);
        vm.prank(admin);
        sPOLChildToken.unpauseBuy();
    }

    function test_balance_only_buy() public {
        uint256 polAmount = 10e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(admin);

        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit BaseChildTunnel.MessageSent("");
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.MigrationRequested(polAmount, expectedSPOL);

        vm.recordLogs();
        sPOLChildToken.balanceWithL1();

        assertEq(vm.getRecordedLogs().length, 2, "Should emit exactly 2 events");
        assertTrue(sPOLChildToken.onGoingMigration(), "Migration should be marked as ongoing");
    }
}
