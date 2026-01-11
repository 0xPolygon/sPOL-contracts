// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {BaseChildTunnel} from "../../src/msg/BaseChildTunnel.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MsgCoder} from "../../src/MsgCoder.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract sPOLChildTest is Test, Deploy {
    sPOLChild public sPOLChildToken;

    // Events from sPOLChild contract
    event sPOLMinted(address user, uint256 amountPOL, uint256 amountSPOL);
    event sPOLBurned(address user, uint256 amountSPOL, uint256 amountPOL, uint256 nonce);
    event POLWithdrawn(address user, uint256 amountPOL, uint256 nonce);

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
        sPOLChildToken = sPOLChild(address(sPOLChildProxy));

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );
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

    function test_balance_only_sell() public {
        uint256 spolAmount = 10e18;
        address buyer = makeAddr("buyer");
        vm.prank(childChainManager);
        sPOLChildToken.deposit(buyer, abi.encode(spolAmount));
        uint256 expectedBackfillcycle = sPOLChildToken.backFillCycle() + 1;

        vm.prank(buyer);
        sPOLChildToken.sellSPOL(spolAmount);
        uint256 expectedPOL = sPOLChildToken.convertSPOLToPOL(spolAmount);

        vm.prank(admin);

        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillStarted(expectedPOL, expectedBackfillcycle);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit IERC20.Transfer(address(sPOLChildToken), address(sPOLMessengerProxy), spolAmount);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit IERC20.Transfer(address(sPOLMessengerProxy), address(0), spolAmount);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit BaseChildTunnel.MessageSent("");
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillRequested(spolAmount, expectedPOL, expectedBackfillcycle);

        vm.recordLogs();
        sPOLChildToken.balanceWithL1();

        assertEq(vm.getRecordedLogs().length, 5, "Should emit exactly 5 events");
        assertTrue(sPOLChildToken.onGoingBackfill(), "Backfill should be marked as ongoing");
    }

    function test_balance_sell_smaller_buy() public {
        uint256 spolAmount = 10e18;
        uint256 polAmount = 5e18;
        address buyer = makeAddr("buyer");
        vm.prank(childChainManager);
        sPOLChildToken.deposit(buyer, abi.encode(spolAmount));
        uint256 expectedBackfillcycle = sPOLChildToken.backFillCycle() + 1;

        uint256 expectedSPOLBuy = sPOLChildToken.convertPOLToSPOL(polAmount);
        vm.deal(buyer, polAmount);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        vm.prank(buyer);
        sPOLChildToken.sellSPOL(spolAmount);
        uint256 expectedPOL = sPOLChildToken.convertSPOLToPOL(spolAmount);
        uint256 netSPOLAmount = spolAmount - expectedSPOLBuy;

        vm.prank(admin);

        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillStarted(expectedPOL, expectedBackfillcycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillLocalCompleted(expectedPOL - polAmount, expectedBackfillcycle);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit IERC20.Transfer(address(sPOLChildToken), address(sPOLMessengerProxy), netSPOLAmount);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit IERC20.Transfer(address(sPOLMessengerProxy), address(0), netSPOLAmount);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit BaseChildTunnel.MessageSent("");
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillRequested(expectedPOL - polAmount, netSPOLAmount, expectedBackfillcycle);
        vm.recordLogs();
        sPOLChildToken.balanceWithL1();

        assertEq(vm.getRecordedLogs().length, 6, "Should emit exactly 6 events");
        assertTrue(sPOLChildToken.onGoingBackfill(), "Backfill should be marked as ongoing");
    }

    // Case where the net sPOL balance wasn't changed, but due to safetyfee there is surplus POL
    function test_balance_equal_mint_burn() public {
        uint256 polAmount = 10e18;
        uint256 spolAmount = sPOLChildToken.convertPOLToSPOL(polAmount);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        vm.prank(buyer);
        sPOLChildToken.sellSPOL(spolAmount);

        assertEq(
            sPOLChildToken.locallyMintedSPOL(),
            sPOLChildToken.locallyToBeBurnedSPOL(),
            "Locally minted and to be burned sPOL should be equal"
        );
        assertGt(
            sPOLChildToken.polBalance(),
            sPOLChildToken.missingWithdrawPOLBalance(),
            "Due to the safety fee there should be some surplus POL"
        );

        uint256 expectedMigrationPOL = sPOLChildToken.polBalance() - sPOLChildToken.missingWithdrawPOLBalance();
        uint256 expectedLocalMigrationPOL = sPOLChildToken.missingWithdrawPOLBalance();
        uint256 backFillCycle = sPOLChildToken.backFillCycle() + 1;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillStarted(expectedLocalMigrationPOL, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillLocalCompleted(expectedLocalMigrationPOL, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillCompleted(0, backFillCycle);
        vm.expectEmit(true, false, false, false, address(sPOLChildToken));
        emit BaseChildTunnel.MessageSent("");
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.MigrationRequested(expectedMigrationPOL, 0);

        vm.recordLogs();
        sPOLChildToken.balanceWithL1();

        assertEq(vm.getRecordedLogs().length, 5, "Should emit exactly 5 events");
        assertTrue(sPOLChildToken.onGoingMigration(), "Migration should be marked as ongoing");
    }

    // Case where the net POL balance wasn't changed, but some sPOL burn/mint happened
    function test_balance_equal_sell_buy() public {
        uint256 polAmount = 10e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
        vm.prank(childChainManager);
        sPOLChildToken.deposit(buyer, abi.encode(polAmount));
        vm.prank(buyer);
        sPOLChildToken.sellSPOL(polAmount);

        assertLt(
            sPOLChildToken.locallyMintedSPOL(), sPOLChildToken.locallyToBeBurnedSPOL(), "Local mint is less than burn"
        );
        uint256 surplusBurnSPOL = sPOLChildToken.locallyToBeBurnedSPOL() - sPOLChildToken.locallyMintedSPOL();
        uint256 expectedMigrationPOL = sPOLChildToken.polBalance() - sPOLChildToken.missingWithdrawPOLBalance();

        assertEq(expectedMigrationPOL, 0, "No surplus POL should be present");
        uint256 backFillCycle = sPOLChildToken.backFillCycle() + 1;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillStarted(polAmount, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillLocalCompleted(polAmount, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillCompleted(0, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BalancedOnlyLocally();

        vm.recordLogs();
        sPOLChildToken.balanceWithL1();

        assertEq(vm.getRecordedLogs().length, 4, "Should emit exactly 4 events");
        assertFalse(sPOLChildToken.onGoingMigration(), "Migration should be marked as not ongoing");
        assertFalse(sPOLChildToken.onGoingBackfill(), "Backfill should be marked as not ongoing");
        assertEq(
            surplusBurnSPOL,
            sPOLChildToken.locallyToBeBurnedSPOL() - sPOLChildToken.locallyMintedSPOL(),
            "Local surplus burn sPOL should stay the same"
        );
    }

    // Case that happens in between the two above where each net balance is exactly zero
    function test_balance_between_both_0() public {
        uint256 polAmount = 10e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 spolAmount = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
        vm.prank(childChainManager);
        sPOLChildToken.deposit(buyer, abi.encode(polAmount));
        uint256 returnedPOLAmount = sPOLChildToken.convertSPOLToPOL(spolAmount + 1);
        vm.prank(buyer);
        sPOLChildToken.sellSPOL(spolAmount + 1);

        assertLt(
            sPOLChildToken.locallyMintedSPOL(), sPOLChildToken.locallyToBeBurnedSPOL(), "Local mint is less than burn"
        );
        uint256 surplusBurnSPOL = sPOLChildToken.locallyToBeBurnedSPOL() - sPOLChildToken.locallyMintedSPOL();
        uint256 expectedMigrationPOL = sPOLChildToken.polBalance() - sPOLChildToken.missingWithdrawPOLBalance();

        assertGt(expectedMigrationPOL, 0, "Some surplus POL should be present");
        uint256 backFillCycle = sPOLChildToken.backFillCycle() + 1;
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillStarted(returnedPOLAmount, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillLocalCompleted(returnedPOLAmount, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BackfillCompleted(0, backFillCycle);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.BalancedOnlyLocally();
        vm.recordLogs();
        sPOLChildToken.balanceWithL1();

        assertEq(vm.getRecordedLogs().length, 4, "Should emit exactly 4 events");
        assertFalse(sPOLChildToken.onGoingBackfill(), "Backfill should be marked as not ongoing");
        assertFalse(sPOLChildToken.onGoingMigration(), "Migration should be marked as not ongoing");
    }
}
