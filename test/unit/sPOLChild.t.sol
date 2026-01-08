// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MsgCoder} from "../../src/MsgCoder.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract sPOLChildTest is Test, Deploy {
    sPOLChild public sPOLChildToken;

    // Test constants
    uint256 constant INITIAL_L1_SPOL_BALANCE = 1;
    uint256 constant INITIAL_L1_DPOL_BALANCE = 1;

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
    }

    function _sendExchangeRateUpdate(uint256 _l1SPOLBalance, uint256 _l1DPOLBalance) internal {
        bytes memory message = abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(_l1SPOLBalance, _l1DPOLBalance));
        vm.prank(stateSyncerL2);
        sPOLChildToken.onStateReceive(0, message);
    }

    function test_exchangeRateUpdate() public {
        uint256 l1SPOLBalance = 1000e18;
        uint256 l1DPOLBalance = 1000e18;
        bytes memory message = abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(l1SPOLBalance, l1DPOLBalance));

        vm.prank(stateSyncerL2);
        sPOLChildToken.onStateReceive(0, message);

        assertEq(sPOLChildToken.l1SPOLBalance(), l1SPOLBalance);
        assertEq(sPOLChildToken.l1DPOLBalance(), l1DPOLBalance);
    }

    function test_exchangeRateUpdate_ImprovesConversionRate() public {
        uint256 oldConversionRate = sPOLChildToken.convertSPOLToPOL(1e18);

        uint256 newL1SPOLBalance = 1000e18;
        uint256 newL1DPOLBalance = 1100e18;

        _sendExchangeRateUpdate(newL1SPOLBalance, newL1DPOLBalance);

        uint256 newConversionRate = sPOLChildToken.convertSPOLToPOL(1e18);

        assertEq(sPOLChildToken.l1SPOLBalance(), newL1SPOLBalance);
        assertEq(sPOLChildToken.l1DPOLBalance(), newL1DPOLBalance);
        assertGt(newConversionRate, oldConversionRate, "Conversion rate should improve");
        assertEq(newConversionRate, 1.1e18); // 10% better rate
    }

    function test_exchangeRateUpdate_UpdatesTimestamp() public {
        uint256 timestampBefore = sPOLChildToken.lastExchangeRateUpdate();

        vm.warp(block.timestamp + 1 hours);

        _sendExchangeRateUpdate(1000e18, 1050e18);

        uint256 timestampAfter = sPOLChildToken.lastExchangeRateUpdate();
        assertEq(timestampAfter, block.timestamp, "Should update to current timestamp");
        assertGt(timestampAfter, timestampBefore, "Timestamp should increase");
    }

    function test_exchangeRateUpdate_RevertsOnDecliningRate() public {
        uint256 worseL1SPOLBalance = 1000e18;
        uint256 worseL1DPOLBalance = 950e18;

        bytes memory message =
            abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(worseL1SPOLBalance, worseL1DPOLBalance));

        uint256 currentRate = sPOLChildToken.convertSPOLToPOL(1e18);
        uint256 newRate = (1e18 * worseL1DPOLBalance) / worseL1SPOLBalance;
        vm.prank(stateSyncerL2);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.ExchangeRateDeclined.selector, newRate, currentRate));
        sPOLChildToken.onStateReceive(0, message);

        // Verify balances remain unchanged
        assertEq(sPOLChildToken.l1SPOLBalance(), INITIAL_L1_SPOL_BALANCE);
        assertEq(sPOLChildToken.l1DPOLBalance(), INITIAL_L1_DPOL_BALANCE);
    }

    function test_exchangeRateUpdate_AllowsSameRate() public {
        // Update with exactly the same rate should work
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE);

        assertEq(sPOLChildToken.l1SPOLBalance(), INITIAL_L1_SPOL_BALANCE);
        assertEq(sPOLChildToken.l1DPOLBalance(), INITIAL_L1_DPOL_BALANCE);
    }

    function test_exchangeRateUpdate_OnlyStateSyncerCanUpdate() public {
        address unauthorizedUser = makeAddr("unauthorized");
        bytes memory message = abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(1000e18, 1100e18));

        vm.prank(unauthorizedUser);
        vm.expectRevert("ChildTunnel: ONLY_STATE_SYNCER_ALLOWED");
        sPOLChildToken.onStateReceive(0, message);
    }

    function test_convertSPOLToPOL_AfterExchangeRateUpdate() public {
        // Test conversion with initial rate
        uint256 sPOLAmount = 100e18;
        uint256 initialConversion = sPOLChildToken.convertSPOLToPOL(sPOLAmount);
        assertEq(initialConversion, 100e18); // 1:1 ratio

        // Update to better rate (20% yield)
        _sendExchangeRateUpdate(1000e18, 1200e18);

        uint256 newConversion = sPOLChildToken.convertSPOLToPOL(sPOLAmount);
        assertEq(newConversion, 120e18); // 1.2:1 ratio
    }

    function test_convertPOLToSPOL_WithSafetyFee() public view {
        uint256 polAmount = 100e18;
        uint256 safetyFee = sPOLChildToken.safetyFee();
        uint256 safetyFeeDenominator = 10_000;

        uint256 expectedSPOL = (polAmount * INITIAL_L1_SPOL_BALANCE / INITIAL_L1_DPOL_BALANCE)
            * (safetyFeeDenominator - safetyFee) / safetyFeeDenominator;

        assertEq(sPOLChildToken.convertPOLToSPOL(polAmount), expectedSPOL);
        assertLt(sPOLChildToken.convertPOLToSPOL(polAmount), polAmount);
    }

    function test_buySPOL_RequiresRecentExchangeRate() public {
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        // Warp beyond maxExchangeRateUpdateDelay (30 days)
        vm.warp(block.timestamp + 31 days);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.ExchangeRateUpdateTooOld.selector, 0, 2592000, 2678401));
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_WorksWithRecentExchangeRate() public {
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);
        uint256 initialBalance = sPOLChildToken.balanceOf(buyer);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.balanceOf(buyer), initialBalance + expectedSPOL);
        assertEq(sPOLChildToken.locallyMintedSPOL(), expectedSPOL);
    }

    function test_exchangeRateUpdate_MultipleUpdates() public {
        uint256 startingConversion = sPOLChildToken.convertSPOLToPOL(1e18);

        // First update: 5% yield
        _sendExchangeRateUpdate(1000e18, 1050e18);
        uint256 firstConversion = sPOLChildToken.convertSPOLToPOL(1e18);

        // Second update: 10% total yield
        _sendExchangeRateUpdate(1000e18, 1100e18);
        uint256 secondConversion = sPOLChildToken.convertSPOLToPOL(1e18);

        // Third update: 15% total yield
        _sendExchangeRateUpdate(1000e18, 1150e18);
        uint256 thirdConversion = sPOLChildToken.convertSPOLToPOL(1e18);

        // Each should be better than the previous
        assertGe(firstConversion, startingConversion);
        assertGe(secondConversion, firstConversion);
        assertGe(thirdConversion, secondConversion);

        // Check exact values
        assertEq(firstConversion, 1.05e18);
        assertEq(secondConversion, 1.1e18);
        assertEq(thirdConversion, 1.15e18);
    }

    function test_exchangeRateUpdate_LargeNumbers() public {
        // Test with very large balances to ensure no overflow
        uint256 largeL1SPOL = type(uint128).max;
        uint256 largeL1DPOL = largeL1SPOL + (largeL1SPOL / 10); // 10% yield

        _sendExchangeRateUpdate(largeL1SPOL, largeL1DPOL);

        assertEq(sPOLChildToken.l1SPOLBalance(), largeL1SPOL);
        assertEq(sPOLChildToken.l1DPOLBalance(), largeL1DPOL);

        // Test conversion doesn't overflow
        uint256 testAmount = 1e18;
        uint256 conversion = sPOLChildToken.convertSPOLToPOL(testAmount);
        uint256 expectedAmount = 11e17;
        assertApproxEqAbs(conversion, expectedAmount, 1);
        // make sure rounding error is in expected direction
        assertLt(conversion, expectedAmount);
    }

    function test_exchangeRateUpdate_MinimalImprovement() public {
        uint256 oldConversion = sPOLChildToken.convertSPOLToPOL(1e18);

        // Update with minimal improvement (1 wei better)
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE + 1);

        uint256 newConversion = sPOLChildToken.convertSPOLToPOL(1e18);
        assertGe(newConversion, oldConversion);
    }

    // TODO think about this
    // should keep this in mind, there might be a way to generate failing statesyncs
    // so it could be possible to extend the time where buying is possible but at the old (better) rate
    // but his requires that no one update the rate in the mean time
    function test_exchangeRateUpdate_AfterMaxDelay() public {
        vm.warp(block.timestamp + sPOLChildToken.maxExchangeRateUpdateDelay() - 1);

        // Should still work just before expiry
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount * 2);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        // But should fail after expiry
        vm.warp(block.timestamp + 2);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.ExchangeRateUpdateTooOld.selector, 0, 2592000, 2592002));
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        _sendExchangeRateUpdate(1, 1); // Update exchange rate to reset timer
        // Should work again after update
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_EmitsCorrectEvent() public {
        uint256 polAmount = 5e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLMinted(buyer, polAmount, expectedSPOL);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_UpdatesCorrectBalances() public {
        uint256 polAmount = 2e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 initialLocallyMinted = sPOLChildToken.locallyMintedSPOL();
        uint256 initialPolBalance = sPOLChildToken.polBalance();
        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.locallyMintedSPOL(), initialLocallyMinted + expectedSPOL);
        assertEq(sPOLChildToken.polBalance(), initialPolBalance + polAmount);
        assertEq(sPOLChildToken.balanceOf(buyer), expectedSPOL);
    }

    function test_buySPOL_RevertsWhenPaused() public {
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(admin);
        sPOLChildToken.pauseUserFunctions();

        vm.prank(buyer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_RevertsOnIncorrectPOLAmount() public {
        uint256 polAmount = 1e18;
        uint256 incorrectAmount = 0.5e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.IncorrectPOLAmount.selector, incorrectAmount, polAmount));
        sPOLChildToken.buySPOL{value: incorrectAmount}(polAmount);
    }

    function test_buySPOL_withZeroAmount() public {
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);

        vm.prank(buyer);
        vm.expectRevert(sPOLChild.POLAmountMustBeGreaterThanZero.selector);
        sPOLChildToken.buySPOL{value: 0}(0);
    }

    function test_buySPOL_WithDifferentExchangeRates() public {
        address buyer = makeAddr("buyer");
        uint256 polAmount = 1e18;
        vm.deal(buyer, polAmount * 3);

        uint256 firstExpected = sPOLChildToken.convertPOLToSPOL(polAmount);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
        assertEq(sPOLChildToken.balanceOf(buyer), firstExpected);
        assertLt(firstExpected, polAmount);

        // Update exchange rate to better rate
        _sendExchangeRateUpdate(1000e18, 1200e18);
        uint256 secondExpected = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
        assertEq(sPOLChildToken.balanceOf(buyer), firstExpected + secondExpected);
        assertLt(secondExpected, firstExpected); // Should get less sPOL for same POL at better rate
    }

    function test_buySPOL_MultipleBuyers() public {
        uint256 polAmount = 1e18;
        address buyer1 = makeAddr("buyer1");
        address buyer2 = makeAddr("buyer2");
        vm.deal(buyer1, polAmount);
        vm.deal(buyer2, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer1);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        vm.prank(buyer2);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.balanceOf(buyer1), expectedSPOL);
        assertEq(sPOLChildToken.balanceOf(buyer2), expectedSPOL);
        assertEq(sPOLChildToken.locallyMintedSPOL(), expectedSPOL * 2);
    }

    function test_buySPOL_LargeAmount() public {
        uint256 polAmount = 1000000000e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.balanceOf(buyer), expectedSPOL);
    }

    function test_buySPOL_SmallAmount() public {
        uint256 polAmount = 1000; // Very small amount
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.balanceOf(buyer), expectedSPOL);
    }

    function test_convertPOLToSPOL_PrecisionImprovement() public {
        _sendExchangeRateUpdate(1000e18, 1001e18);

        uint256 polAmount = 1000000;
        uint256 convertedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        assertGt(convertedSPOL, 0, "Should convert small amounts without precision loss to zero");

        uint256 largePOLAmount = 12345e18;
        uint256 largeSPOL = sPOLChildToken.convertPOLToSPOL(largePOLAmount);
        assertGt(largeSPOL, 0, "Should handle large amounts");

        uint256 convertedBack = sPOLChildToken.convertSPOLToPOL(largeSPOL);
        assertGt(convertedBack, largePOLAmount * 995 / 1000, "Round-trip conversion should be reasonable");
    }

    function test_sellSPOL() public {
        address user = makeAddr("user");
        vm.prank(childChainManager);
        sPOLChildToken.deposit(user, abi.encode(10e18));

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);
        uint256 expectedPOLRedeem = sPOLChildToken.convertSPOLToPOL(sPOLBalance);

        uint256 initialMissingBalance = sPOLChildToken.missingWithdrawPOLBalance();
        uint256 initialNonce = sPOLChildToken.globalWithdrawNonce();

        vm.prank(user);

        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit IERC20.Transfer(user, address(sPOLChildToken), sPOLBalance);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLBurned(user, sPOLBalance, expectedPOLRedeem, initialNonce + 1);

        sPOLChildToken.sellSPOL(sPOLBalance);

        // Verify slow sell behavior - sPOL is burned but no immediate POL
        assertEq(user.balance, 0, "User should not receive POL immediately");
        assertEq(sPOLChildToken.missingWithdrawPOLBalance(), initialMissingBalance + sPOLBalance);
        assertEq(sPOLChildToken.globalWithdrawNonce(), initialNonce + 1);
        assertEq(sPOLChildToken.balanceOf(user), 0, "User sPOL balance should be zero");
        assertEq(sPOLChildToken.locallyToBeBurnedSPOL(), sPOLBalance);
        assertEq(sPOLChildToken.balanceOf(address(sPOLChildToken)), sPOLBalance, "Contract should take token to self");

        // Check user outstanding POL was recorded
        sPOLChild.UserOutstandingFull[] memory outstanding = sPOLChildToken.getUserOutstandingNonces(user);
        assertEq(outstanding.length, 1, "Should have one outstanding withdraw record");
        assertEq(outstanding[0].outstandingPOL, expectedPOLRedeem);
        assertEq(outstanding[0].backFillCycle, 1);
        assertEq(outstanding[0].nonce, initialNonce + 1);
    }
}
