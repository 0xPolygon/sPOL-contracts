// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
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
        sPOLChildToken = sPOLChild(payable(sPOLChildProxy));
    }

    function _sendExchangeRateUpdate(uint256 _l1SPOLBalance, uint256 _l1DPOLBalance) internal {
        bytes memory message = abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(_l1SPOLBalance, _l1DPOLBalance));
        vm.prank(stateSyncerL2);
        sPOLChildToken.onStateReceive(0, message);
    }

    function _defaultUnpause() internal {
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE);
        vm.prank(admin);
        sPOLChildToken.unpauseBuySell();
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

    function test_exchangeRateUpdate_IgnoresDecliningRate() public {
        uint256 worseL1SPOLBalance = 1000e18;
        uint256 worseL1DPOLBalance = 950e18;

        bytes memory message =
            abi.encode(MsgCoder.MsgType.EXCHANGE_UPDATE, abi.encode(worseL1SPOLBalance, worseL1DPOLBalance));

        vm.prank(stateSyncerL2);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.ExchangeRateDeclined(
            INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE, worseL1SPOLBalance, worseL1DPOLBalance
        );
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

    function test_exchangeRateUpdate_SameRateRefreshesTimestamp() public {
        _defaultUnpause();
        uint256 initialTimestamp = sPOLChildToken.lastExchangeRateUpdate();

        // Warp close to expiry
        vm.warp(initialTimestamp + 9 days);

        // Same rate update should refresh the timestamp
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE);
        assertEq(sPOLChildToken.lastExchangeRateUpdate(), initialTimestamp + 9 days);

        // Warp another 9 days — would have expired without the refresh
        vm.warp(initialTimestamp + 18 days);

        // Buy should still work because the timer was refreshed
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 1e18}(1e18);
        assertGt(sPOLChildToken.balanceOf(buyer), 0);
    }

    function test_exchangeRateUpdate_DecliningRateDoesNotRefreshTimestamp() public {
        _defaultUnpause();
        
        // Set a real rate first
        _sendExchangeRateUpdate(1000e18, 1100e18);
        uint256 updatedTimestamp = sPOLChildToken.lastExchangeRateUpdate();

        // Warp forward
        vm.warp(updatedTimestamp + 5 days);

        // Send a declining rate — should be ignored, timestamp should NOT refresh
        _sendExchangeRateUpdate(1000e18, 1050e18);
        assertEq(sPOLChildToken.lastExchangeRateUpdate(), updatedTimestamp, "Timestamp should not refresh on decline");
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
        _defaultUnpause();
        uint256 timestampBefore = sPOLChildToken.lastExchangeRateUpdate();
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        // Warp beyond maxExchangeRateUpdateDelay (10 days)
        vm.warp(timestampBefore + 11 days);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                sPOLChild.ExchangeRateUpdateTooOld.selector, timestampBefore, 10 days, timestampBefore + 11 days
            )
        );
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_WorksWithRecentExchangeRate() public {
        _defaultUnpause();
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
        _defaultUnpause();
        uint256 initialTimestamp = vm.getBlockTimestamp();
        vm.warp(initialTimestamp + sPOLChildToken.maxExchangeRateUpdateDelay() - 1);

        // Should still work just before expiry
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount * 2);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        // But should fail after expiry
        vm.warp(initialTimestamp + sPOLChildToken.maxExchangeRateUpdateDelay() + 1);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                sPOLChild.ExchangeRateUpdateTooOld.selector, initialTimestamp, 10 days, initialTimestamp + 10 days + 1
            )
        );
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        _sendExchangeRateUpdate(1, 1); // Update exchange rate to reset timer
        // Should work again after update
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_EmitsCorrectEvent() public {
        _defaultUnpause();
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
        _defaultUnpause();
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
        _defaultUnpause();
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(admin);
        sPOLChildToken.pauseBuySell();

        vm.prank(buyer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_RevertsInitially() public {
        uint256 polAmount = 1e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(buyer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    function test_buySPOL_RevertsOnIncorrectPOLAmount() public {
        _defaultUnpause();
        uint256 polAmount = 1e18;
        uint256 incorrectAmount = 0.5e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.IncorrectPOLAmount.selector, incorrectAmount, polAmount));
        sPOLChildToken.buySPOL{value: incorrectAmount}(polAmount);
    }

    function test_buySPOL_withZeroAmount() public {
        _defaultUnpause();
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);

        vm.prank(buyer);
        vm.expectRevert(sPOLChild.POLAmountMustBeGreaterThanZero.selector);
        sPOLChildToken.buySPOL{value: 0}(0);
    }

    function test_buySPOL_WithDifferentExchangeRates() public {
        _defaultUnpause();
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
        _defaultUnpause();
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
        _defaultUnpause();
        uint256 polAmount = 1000000000e18;
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.balanceOf(buyer), expectedSPOL);
    }

    function test_buySPOL_SmallAmount() public {
        _defaultUnpause();
        uint256 polAmount = 1000; // Very small amount
        address buyer = makeAddr("buyer");
        vm.deal(buyer, polAmount);

        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.balanceOf(buyer), expectedSPOL);
    }

    function test_convertPOLToSPOL_PrecisionImprovement() public {
        _defaultUnpause();
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

    function test_sellSPOL_after_deposit() public {
        _defaultUnpause();
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

    function test_sellSPOL_simple() public {
        _defaultUnpause();
        uint256 polAmount = 10e18;
        address seller = makeAddr("seller");
        vm.deal(seller, polAmount);

        vm.prank(seller);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(seller);
        assertTrue(sPOLBalance > 0);

        uint256 initialPOLBalance = seller.balance;
        uint256 expectedPOLRedeem = sPOLChildToken.convertSPOLToPOL(sPOLBalance);
        uint256 initialNonce = sPOLChildToken.globalWithdrawNonce();
        uint256 initialLocallyToBeBurned = sPOLChildToken.locallyToBeBurnedSPOL();

        vm.prank(seller);
        sPOLChildToken.sellSPOL(sPOLBalance);

        assertEq(sPOLChildToken.balanceOf(seller), 0, "Seller sPOL balance should be zero");
        assertEq(seller.balance, initialPOLBalance, "Seller should not receive POL immediately");
        assertEq(sPOLChildToken.globalWithdrawNonce(), initialNonce + 1, "Nonce should increment");
        assertEq(
            sPOLChildToken.locallyToBeBurnedSPOL(),
            initialLocallyToBeBurned + sPOLBalance,
            "locallyToBeBurnedSPOL should increase"
        );

        sPOLChild.UserOutstandingFull[] memory outstanding = sPOLChildToken.getUserOutstandingNonces(seller);
        assertEq(outstanding.length, 1, "Should have one outstanding withdraw record");
        assertEq(
            outstanding[0].outstandingPOL, expectedPOLRedeem, "Outstanding POL should match expected redeem amount"
        );
        assertEq(outstanding[0].nonce, initialNonce + 1, "Outstanding nonce should match");
    }

    function test_sellSPOL_reverts_if_no_balance() public {
        _defaultUnpause();
        address user = makeAddr("userWithNoSPOL");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 0, 1e18));
        sPOLChildToken.sellSPOL(1e18);
    }

    function test_sellSPOL_reverts_if_amount_is_zero() public {
        _defaultUnpause();
        address user = makeAddr("user");
        vm.prank(user);
        vm.expectRevert(sPOLChild.POLAmountMustBeGreaterThanZero.selector);
        sPOLChildToken.sellSPOL(0);
    }

    function test_sellSPOL_reverts_if_paused() public {
        _defaultUnpause();
        uint256 polAmount = 10e18;
        address seller = makeAddr("seller");
        vm.deal(seller, polAmount);
        vm.prank(seller);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
        uint256 sPOLBalance = sPOLChildToken.balanceOf(seller);

        vm.prank(admin);
        sPOLChildToken.pauseBuySell();

        vm.prank(seller);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sPOLChildToken.sellSPOL(sPOLBalance);
    }

    function test_sellSPOL_multiple_sells() public {
        _defaultUnpause();
        uint256 polAmount = 20e18;
        address seller = makeAddr("seller");
        vm.deal(seller, polAmount);
        vm.prank(seller);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(seller);
        uint256 sellAmount1 = sPOLBalance / 2;
        uint256 sellAmount2 = sPOLBalance - sellAmount1;

        uint256 initialNonce = sPOLChildToken.globalWithdrawNonce();
        vm.prank(seller);
        sPOLChildToken.sellSPOL(sellAmount1);

        assertEq(sPOLChildToken.balanceOf(seller), sPOLBalance - sellAmount1);
        assertEq(sPOLChildToken.globalWithdrawNonce(), initialNonce + 1);

        vm.prank(seller);
        sPOLChildToken.sellSPOL(sellAmount2);

        assertEq(sPOLChildToken.balanceOf(seller), 0);
        assertEq(sPOLChildToken.globalWithdrawNonce(), initialNonce + 2);

        sPOLChild.UserOutstandingFull[] memory outstanding = sPOLChildToken.getUserOutstandingNonces(seller);
        assertEq(outstanding.length, 2, "Should have two outstanding withdraw records");
        assertEq(outstanding[0].nonce, initialNonce + 1);
        assertEq(outstanding[1].nonce, initialNonce + 2);
    }

    function test_sellSPOL_updates_correct_balances() public {
        _defaultUnpause();
        uint256 polAmount = 10e18;
        address seller = makeAddr("seller");
        vm.deal(seller, polAmount);
        vm.prank(seller);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(seller);
        uint256 sPOLBalanceToken = sPOLChildToken.balanceOf(address(sPOLChildToken));

        uint256 initialLocallyToBeBurned = sPOLChildToken.locallyToBeBurnedSPOL();
        uint256 initialContractSPOLBalance = sPOLChildToken.balanceOf(address(sPOLChildToken));

        vm.prank(seller);
        sPOLChildToken.sellSPOL(sPOLBalance);

        assertEq(sPOLChildToken.balanceOf(seller), 0, "User sPOL balance should be zero");
        assertEq(
            sPOLChildToken.balanceOf(address(sPOLChildToken)),
            initialContractSPOLBalance + sPOLBalance,
            "Contract sPOL balance should increase by sold amount"
        );
        assertEq(
            sPOLChildToken.locallyToBeBurnedSPOL(),
            initialLocallyToBeBurned + sPOLBalance,
            "locallyToBeBurnedSPOL should increase by sold amount"
        );
        assertEq(
            sPOLChildToken.balanceOf(address(sPOLChildToken)),
            initialContractSPOLBalance + sPOLBalance,
            "Contract sPOL balance should increase"
        );
    }

    function test_sellSPOL_emits_correct_event() public {
        _defaultUnpause();
        uint256 polAmount = 10e18;
        address seller = makeAddr("seller");
        vm.deal(seller, polAmount);
        vm.prank(seller);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(seller);
        uint256 expectedPOLRedeem = sPOLChildToken.convertSPOLToPOL(sPOLBalance);
        uint256 nonce = sPOLChildToken.globalWithdrawNonce() + 1;

        vm.prank(seller);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLBurned(seller, sPOLBalance, expectedPOLRedeem, nonce);
        sPOLChildToken.sellSPOL(sPOLBalance);
    }

    function _setupAndSell(address _seller, uint256 _polAmount) internal returns (uint256 sPOLAmount) {
        vm.deal(_seller, _polAmount);
        vm.prank(_seller);
        sPOLChildToken.buySPOL{value: _polAmount}(_polAmount);
        sPOLAmount = sPOLChildToken.balanceOf(_seller);
        vm.prank(_seller);
        sPOLChildToken.sellSPOL(sPOLAmount);
    }

    function test_withdrawPOL_single_claim() public {
        _defaultUnpause();
        address user = makeAddr("user");
        uint256 polAmount = 10e18;
        _setupAndSell(user, polAmount);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 100e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 100e18}(100e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );

        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        uint256 initialPOLBalance = user.balance;
        uint256 expectedPOL = sPOLChildToken.convertSPOLToPOL(sPOLChildToken.balanceOf(address(sPOLChildToken)));

        vm.prank(user);
        sPOLChildToken.withdrawPOL();

        assertEq(user.balance, initialPOLBalance + expectedPOL, "User should receive the correct amount of POL");
    }

    function test_withdrawPOL_multiple_claims_same_user() public {
        _defaultUnpause();
        address user = makeAddr("user");
        uint256 polAmount1 = 5e18;
        uint256 polAmount2 = 8e18;

        uint256 nonce1 = sPOLChildToken.globalWithdrawNonce() + 1;
        uint256 sPOLAmount1 = _setupAndSell(user, polAmount1);
        uint256 nonce2 = sPOLChildToken.globalWithdrawNonce() + 1;
        uint256 sPOLAmount2 = _setupAndSell(user, polAmount2);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 100e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 100e18}(100e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );
        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        uint256 initialPOLBalance = user.balance;
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(sPOLAmount1);
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(sPOLAmount2);
        uint256 totalExpectedPOL = expectedPOL1 + expectedPOL2;

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit POLWithdrawn(user, expectedPOL1, nonce1);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit POLWithdrawn(user, expectedPOL2, nonce2);
        sPOLChildToken.withdrawPOL();

        assertEq(user.balance, initialPOLBalance + totalExpectedPOL, "User should receive POL from all claims");
    }

    function test_withdrawPOL_multiple_users() public {
        _defaultUnpause();
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        uint256 polAmount1 = 6e18;
        uint256 polAmount2 = 9e18;

        uint256 nonce1 = sPOLChildToken.globalWithdrawNonce() + 1;
        uint256 sPOLAmount1 = _setupAndSell(user1, polAmount1);
        uint256 nonce2 = sPOLChildToken.globalWithdrawNonce() + 1;
        uint256 sPOLAmount2 = _setupAndSell(user2, polAmount2);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 100e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 100e18}(100e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );
        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        uint256 initialPOLBalance1 = user1.balance;
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(sPOLAmount1);
        vm.prank(user1);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit POLWithdrawn(user1, expectedPOL1, nonce1);
        sPOLChildToken.withdrawPOL();
        assertEq(user1.balance, initialPOLBalance1 + expectedPOL1, "User 1 should receive correct POL");

        uint256 initialPOLBalance2 = user2.balance;
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(sPOLAmount2);
        vm.prank(user2);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit POLWithdrawn(user2, expectedPOL2, nonce2);
        sPOLChildToken.withdrawPOL();
        assertEq(user2.balance, initialPOLBalance2 + expectedPOL2, "User 2 should receive correct POL");
    }

    function test_withdrawPOL_cannot_claim_twice() public {
        _defaultUnpause();
        address user = makeAddr("user");
        uint256 polAmount = 10e18;
        _setupAndSell(user, polAmount);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 100e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 100e18}(100e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );
        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        vm.prank(user);
        sPOLChildToken.withdrawPOL();

        vm.prank(user);
        vm.expectRevert(sPOLChild.POLAmountMustBeGreaterThanZero.selector);
        sPOLChildToken.withdrawPOL();
    }

    function test_withdrawPOL_reverts_if_nothing_to_claim() public {
        _defaultUnpause();
        address user = makeAddr("userWithNoClaims");
        vm.prank(user);
        vm.expectRevert(sPOLChild.POLAmountMustBeGreaterThanZero.selector);
        sPOLChildToken.withdrawPOL();
    }

    function test_withdrawPOL_partial_claim() public {
        _defaultUnpause();
        address user = makeAddr("user");
        uint256 polAmount1 = 5e18;
        uint256 polAmount2 = 8e18;

        uint256 nonce1 = sPOLChildToken.globalWithdrawNonce() + 1;
        uint256 sPOLAmount1 = _setupAndSell(user, polAmount1);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 100e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 100e18}(100e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );
        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        uint256 sPOLAmount2 = _setupAndSell(user, polAmount2);

        uint256 initialPOLBalance = user.balance;
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(sPOLAmount1);

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit POLWithdrawn(user, expectedPOL1, nonce1);
        sPOLChildToken.withdrawPOL();

        assertEq(user.balance, initialPOLBalance + expectedPOL1, "User should only receive POL from completed backfill");

        sPOLChild.UserOutstandingFull[] memory outstanding = sPOLChildToken.getUserOutstandingNonces(user);
        assertEq(outstanding.length, 1, "Should have one outstanding claim left");
        assertEq(outstanding[0].outstandingPOL, sPOLChildToken.convertSPOLToPOL(sPOLAmount2));
    }

    function test_deposit_mintsTokensToUser() public {
        address user = makeAddr("depositUser");
        uint256 depositAmount = 100e18;

        uint256 initialBalance = sPOLChildToken.balanceOf(user);

        vm.prank(childChainManager);
        sPOLChildToken.deposit(user, abi.encode(depositAmount));

        assertEq(sPOLChildToken.balanceOf(user), initialBalance + depositAmount, "User should receive deposited sPOL");
    }

    function test_deposit_onlyChildChainManager() public {
        address user = makeAddr("depositUser");
        address unauthorizedCaller = makeAddr("unauthorized");
        uint256 depositAmount = 100e18;

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.AddressUnauthorized.selector, unauthorizedCaller));
        sPOLChildToken.deposit(user, abi.encode(depositAmount));
    }

    function test_deposit_completesMigrationWhenConditionsMet() public {
        _defaultUnpause();

        // Setup: buy sPOL to create a migration scenario
        address buyer = makeAddr("buyer");
        uint256 polAmount = 10e18;
        vm.deal(buyer, polAmount);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );

        // Trigger migration
        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        assertTrue(sPOLChildToken.onGoingMigration(), "Migration should be ongoing");
        uint256 backMigratingSPOL = sPOLChildToken.backMigratingSPOL();

        // Complete migration by depositing to contract itself with exact amount
        vm.prank(childChainManager);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.MigrationCompleted(backMigratingSPOL);
        sPOLChildToken.deposit(address(sPOLChildToken), abi.encode(backMigratingSPOL));

        assertFalse(sPOLChildToken.onGoingMigration(), "Migration should be completed");
        assertEq(sPOLChildToken.backMigratingSPOL(), 0, "backMigratingSPOL should be reset");
    }

    function test_withdraw_burnsTokens() public {
        _defaultUnpause();
        address user = makeAddr("withdrawUser");

        // Deposit some tokens first
        vm.prank(childChainManager);
        sPOLChildToken.deposit(user, abi.encode(100e18));

        uint256 initialBalance = sPOLChildToken.balanceOf(user);
        uint256 withdrawAmount = 50e18;

        vm.prank(user);
        sPOLChildToken.withdraw(withdrawAmount);

        assertEq(sPOLChildToken.balanceOf(user), initialBalance - withdrawAmount, "User balance should decrease");
    }

    function test_withdraw_revertsIfInsufficientBalance() public {
        address user = makeAddr("withdrawUser");

        vm.prank(user);
        vm.expectRevert();
        sPOLChildToken.withdraw(100e18);
    }

    function test_sellSPOL_revertsWhenExchangeRateOutdated() public {
        _defaultUnpause();
        address seller = makeAddr("seller");
        uint256 polAmount = 10e18;
        vm.deal(seller, polAmount);

        // Buy some sPOL first
        vm.prank(seller);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(seller);
        uint256 timestampBefore = sPOLChildToken.lastExchangeRateUpdate();

        // Warp beyond maxExchangeRateUpdateDelay
        vm.warp(timestampBefore + 11 days);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                sPOLChild.ExchangeRateUpdateTooOld.selector, timestampBefore, 10 days, timestampBefore + 11 days
            )
        );
        sPOLChildToken.sellSPOL(sPOLBalance);
    }

    function test_onStateReceive_emitsOnInvalidMessageType() public {
        bytes memory invalidMessage = abi.encode(MsgCoder.MsgType.L1_MIGRATION_RESPONSE, abi.encode(100e18));

        vm.record();
        vm.prank(stateSyncerL2);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.InvalidMessageType();
        sPOLChildToken.onStateReceive(0, invalidMessage);
        (, bytes32[] memory writes) = vm.accesses(address(sPOLChildToken));
        assertEq(writes.length, 0, "Invalid message should not modify storage");
    }

    function test_onStateReceive_revertsOnOutOfBoundsMessageType() public {
        bytes memory invalidMessage = abi.encode(uint8(99), abi.encode(100e18));

        vm.prank(stateSyncerL2);
        vm.expectRevert();
        sPOLChildToken.onStateReceive(0, invalidMessage);
    }

    function test_balanceWithL1_revertsWhenMigrationOngoing() public {
        _defaultUnpause();

        // Setup migration
        address buyer = makeAddr("buyer");
        uint256 polAmount = 10e18;
        vm.deal(buyer, polAmount);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );

        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        assertTrue(sPOLChildToken.onGoingMigration(), "Migration should be ongoing");

        // Try to balance again - should revert
        vm.prank(admin);
        vm.expectRevert(sPOLChild.MigrationAlreadyOngoing.selector);
        sPOLChildToken.balanceWithL1();
    }

    function test_balanceWithL1_revertsWhenBackfillOngoing() public {
        _defaultUnpause();

        // Setup backfill scenario - deposit and sell without buying
        address user = makeAddr("user");
        vm.prank(childChainManager);
        sPOLChildToken.deposit(user, abi.encode(10e18));

        vm.prank(user);
        sPOLChildToken.sellSPOL(10e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );

        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        assertTrue(sPOLChildToken.onGoingBackfill(), "Backfill should be ongoing");

        // Try to balance again - should revert
        vm.prank(admin);
        vm.expectRevert(sPOLChild.BackfillAlreadyOngoing.selector);
        sPOLChildToken.balanceWithL1();
    }

    function test_balanceWithL1_onlyAdmin() public {
        _defaultUnpause();
        address nonAdmin = makeAddr("nonAdmin");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        sPOLChildToken.balanceWithL1();
    }

    function test_changeSafetyFee_success() public {
        uint16 newFee = 50; // 0.5%
        uint16 oldFee = sPOLChildToken.safetyFee();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.SafetyFeeChanged(oldFee, newFee);
        sPOLChildToken.changeSafetyFee(newFee);

        assertEq(sPOLChildToken.safetyFee(), newFee, "Safety fee should be updated");
    }

    function test_changeSafetyFee_revertsIfTooHigh() public {
        uint16 tooHighFee = 101; // > MAX_SAFETY_FEE (100)

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(sPOLChild.FeeTooHigh.selector, tooHighFee, 100));
        sPOLChildToken.changeSafetyFee(tooHighFee);
    }

    function test_changeSafetyFee_onlyAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        sPOLChildToken.changeSafetyFee(50);
    }

    function test_changeSafetyFee_allowsMaxFee() public {
        uint16 maxFee = 100; // MAX_SAFETY_FEE

        vm.prank(admin);
        sPOLChildToken.changeSafetyFee(maxFee);

        assertEq(sPOLChildToken.safetyFee(), maxFee, "Max fee should be allowed");
    }

    function test_changeSafetyFee_allowsZeroFee() public {
        vm.prank(admin);
        sPOLChildToken.changeSafetyFee(0);

        assertEq(sPOLChildToken.safetyFee(), 0, "Zero fee should be allowed");
    }

    function test_setMaxExchangeRateUpdateDelay_success() public {
        uint256 newDelay = 7 days;
        uint256 oldDelay = sPOLChildToken.maxExchangeRateUpdateDelay();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLChild.MaxExchangeRateDelayChanged(oldDelay, newDelay);
        sPOLChildToken.setMaxExchangeRateUpdateDelay(newDelay);

        assertEq(sPOLChildToken.maxExchangeRateUpdateDelay(), newDelay, "Delay should be updated");
    }

    function test_setMaxExchangeRateUpdateDelay_onlyAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        sPOLChildToken.setMaxExchangeRateUpdateDelay(7 days);
    }

    function test_pauseBuySell_onlyAdmin() public {
        _defaultUnpause();
        address nonAdmin = makeAddr("nonAdmin");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        sPOLChildToken.pauseBuySell();
    }

    function test_pauseBuySell_success() public {
        _defaultUnpause();

        vm.prank(admin);
        sPOLChildToken.pauseBuySell();

        assertTrue(sPOLChildToken.paused(), "Contract should be paused");
    }

    function test_unpauseBuySell_onlyAdmin() public {
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE);
        address nonAdmin = makeAddr("nonAdmin");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        sPOLChildToken.unpauseBuySell();
    }

    function test_unpauseBuySell_revertsIfExchangeRateOutdated() public {
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE);
        uint256 timestampBefore = sPOLChildToken.lastExchangeRateUpdate();

        // Warp beyond maxExchangeRateUpdateDelay
        vm.warp(timestampBefore + 11 days);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                sPOLChild.ExchangeRateUpdateTooOld.selector, timestampBefore, 10 days, timestampBefore + 11 days
            )
        );
        sPOLChildToken.unpauseBuySell();
    }

    function test_unpauseBuySell_success() public {
        _sendExchangeRateUpdate(INITIAL_L1_SPOL_BALANCE, INITIAL_L1_DPOL_BALANCE);

        assertTrue(sPOLChildToken.paused(), "Contract should start paused");

        vm.prank(admin);
        sPOLChildToken.unpauseBuySell();

        assertFalse(sPOLChildToken.paused(), "Contract should be unpaused");
    }

    function test_withdrawPOL_succeedsWhenPaused() public {
        _defaultUnpause();
        address user = makeAddr("user");
        uint256 polAmount = 10e18;
        _setupAndSell(user, polAmount);

        // Setup buyer and complete backfill
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 100e18);
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: 100e18}(100e18);

        vm.mockCall(
            address(sPOLChildToken.bridgeHelper()),
            abi.encodeWithSelector(sPOLChildToken.bridgeHelper().bridgePOLToL1.selector),
            abi.encode(true)
        );
        vm.prank(admin);
        sPOLChildToken.balanceWithL1();

        // Pause the contract
        vm.prank(admin);
        sPOLChildToken.pauseBuySell();
        assertTrue(sPOLChildToken.paused(), "Contract should be paused");

        // Withdraw should still succeed while paused
        uint256 balanceBefore = user.balance;
        vm.prank(user);
        sPOLChildToken.withdrawPOL();
        assertGt(user.balance, balanceBefore, "User should receive POL even when paused");
    }
}
