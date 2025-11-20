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

        vm.prank(stateSyncerL2);
        vm.expectRevert("Exchange rate declined");
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
        vm.expectRevert("Exchange rate update too old");
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
        vm.expectRevert("Exchange rate update too old");
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        _sendExchangeRateUpdate(1, 1); // Update exchange rate to reset timer
        // Should work again after update
        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);
    }

    // Additional buySPOL tests
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
        uint256 initialQuickRedeemReserve = sPOLChildToken.actualQuickRedeemReserve();
        uint256 initialPolBalance = sPOLChildToken.polBalance();
        uint256 expectedSPOL = sPOLChildToken.convertPOLToSPOL(polAmount);

        vm.prank(buyer);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        assertEq(sPOLChildToken.locallyMintedSPOL(), initialLocallyMinted + expectedSPOL);
        assertEq(sPOLChildToken.actualQuickRedeemReserve(), initialQuickRedeemReserve + polAmount);
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
        vm.expectRevert("Incorrect POL amount sent");
        sPOLChildToken.buySPOL{value: incorrectAmount}(polAmount);
    }

    function test_buySPOL_withZeroAmount() public {
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);

        vm.prank(buyer);
        vm.expectRevert("POL amount must be greater than 0");
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

    // Quick sell tests (sellSPOL with sufficient actualQuickRedeemReserve)
    function test_sellSPOL_QuickSell_Success() public {
        uint256 polAmount = 2e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);
        uint256 expectedPOL = sPOLChildToken.convertSPOLToPOL(sPOLBalance);
        uint256 initialUserETH = user.balance;
        uint256 initialQuickRedeemReserve = sPOLChildToken.actualQuickRedeemReserve();
        uint256 initialPolBalance = sPOLChildToken.polBalance();
        uint256 initialLocallyToBeBurned = sPOLChildToken.locallyToBeBurnedSPOL();

        vm.prank(user);
        sPOLChildToken.sellSPOL(sPOLBalance);

        // Check balances updated correctly
        assertEq(sPOLChildToken.balanceOf(user), 0);
        assertEq(user.balance, initialUserETH + expectedPOL);
        assertEq(sPOLChildToken.actualQuickRedeemReserve(), initialQuickRedeemReserve - expectedPOL);
        assertEq(sPOLChildToken.polBalance(), initialPolBalance - expectedPOL);
        assertEq(sPOLChildToken.locallyToBeBurnedSPOL(), initialLocallyToBeBurned + sPOLBalance);
    }

    function test_sellSPOL_QuickSell_EmitsCorrectEvents() public {
        uint256 polAmount = 1e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);
        uint256 expectedPOL = sPOLChildToken.convertSPOLToPOL(sPOLBalance);
        uint256 expectedNonce = sPOLChildToken.globalWithdrawNonce() + 1;

        // Expect both events
        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit sPOLBurned(user, sPOLBalance, expectedPOL, expectedNonce);

        vm.expectEmit(true, true, true, true, address(sPOLChildToken));
        emit POLWithdrawn(user, expectedPOL, expectedNonce);

        vm.prank(user);
        sPOLChildToken.sellSPOL(sPOLBalance);
    }

    function test_sellSPOL_QuickSell_UpdatesNonce() public {
        uint256 polAmount = 1e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 initialNonce = sPOLChildToken.globalWithdrawNonce();
        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);

        vm.prank(user);
        sPOLChildToken.sellSPOL(sPOLBalance);

        assertEq(sPOLChildToken.globalWithdrawNonce(), initialNonce + 1); // +1 for the sellSPOL operation
    }

    function test_sellSPOL_QuickSell_RevertsWhenPaused() public {
        uint256 polAmount = 1e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        // Pause the contract
        vm.prank(admin);
        sPOLChildToken.pauseUserFunctions();

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);

        vm.prank(user);
        vm.expectRevert();
        sPOLChildToken.sellSPOL(sPOLBalance);
    }

    function test_sellSPOL_QuickSell_RevertsOnInsufficientBalance() public {
        uint256 polAmount = 1e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, sPOLBalance, sPOLBalance + 1)
        );
        sPOLChildToken.sellSPOL(sPOLBalance + 1);
    }

    function test_sellSPOL_QuickSell_PartialSell() public {
        uint256 polAmount = 2e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);
        uint256 sellAmount = sPOLBalance / 2;
        uint256 expectedPOL = sPOLChildToken.convertSPOLToPOL(sellAmount);
        uint256 initialUserETH = user.balance;

        vm.prank(user);
        sPOLChildToken.sellSPOL(sellAmount);

        assertEq(sPOLChildToken.balanceOf(user), sPOLBalance - sellAmount);
        assertEq(user.balance, initialUserETH + expectedPOL);
    }

    function test_sellSPOL_QuickSell_MultipleSells() public {
        uint256 polAmount = 3e18;
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);
        uint256 sellAmount1 = sPOLBalance / 3;
        uint256 sellAmount2 = sPOLBalance / 3;
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(sellAmount1);
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(sellAmount2);
        uint256 initialUserETH = user.balance;

        vm.prank(user);
        sPOLChildToken.sellSPOL(sellAmount1);

        vm.prank(user);
        sPOLChildToken.sellSPOL(sellAmount2);

        assertApproxEqAbs(sPOLChildToken.balanceOf(user), sPOLBalance - sellAmount1 - sellAmount2, 1);
        assertEq(user.balance, initialUserETH + expectedPOL1 + expectedPOL2);
    }

    function test_sellSPOL_QuickSell_WithDifferentExchangeRates() public {
        uint256 polAmount = 10e18; // Use larger amount to ensure sufficient quick redeem reserve
        address user = makeAddr("user");
        vm.deal(user, polAmount);

        vm.prank(user);
        sPOLChildToken.buySPOL{value: polAmount}(polAmount);

        uint256 sPOLBalance = sPOLChildToken.balanceOf(user);
        uint256 sellAmount = sPOLBalance / 4; // Sell quarter at a time to avoid depleting reserve
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(sellAmount);

        // First sell at initial rate
        vm.prank(user);
        sPOLChildToken.sellSPOL(sellAmount);
        uint256 userETHAfterFirst = user.balance;

        // Update exchange rate to better rate
        _sendExchangeRateUpdate(1000e18, 1200e18);

        // Sell same amount at better rate
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(sellAmount);

        vm.prank(user);
        sPOLChildToken.sellSPOL(sellAmount);

        // At better exchange rate, same sPOL amount should convert to more POL
        assertGt(expectedPOL2, expectedPOL1, "Should get more POL at better exchange rate");
        assertEq(user.balance, userETHAfterFirst + expectedPOL2);
    }

    function test_sellSPOL_QuickSell_ZeroAmount() public {
        address user = makeAddr("user");
        uint256 initialBalance = user.balance;
        uint256 initialSPOLBalance = sPOLChildToken.balanceOf(user);

        vm.prank(user);
        sPOLChildToken.sellSPOL(0);

        // Should work but not change any balances meaningfully
        assertEq(sPOLChildToken.balanceOf(user), initialSPOLBalance);
        assertEq(user.balance, initialBalance);
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

    function test_sellSPOL_SlowSell_InsufficientReserve() public {
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
        (uint256 outstandingPOL, uint256 backfillCycle, uint256 nonce) =
            sPOLChildToken.userOutstandingPOL(user, initialNonce);
        assertEq(outstandingPOL, expectedPOLRedeem);
        assertEq(backfillCycle, 0);
        assertEq(nonce, initialNonce + 1);
    }

    function test_sellSPOL_SlowSell_PartialPOL_PartialWithdraw() public {
        address slowSeller1 = makeAddr("slowSeller1");
        address slowSeller2 = makeAddr("slowSeller2");
        uint256 initialBalance1 = slowSeller1.balance;
        uint256 initialBalance2 = slowSeller2.balance;

        vm.prank(childChainManager);
        sPOLChildToken.deposit(slowSeller1, abi.encode(3e18));
        vm.prank(childChainManager);
        sPOLChildToken.deposit(slowSeller2, abi.encode(4e18));

        uint256 sPOL1 = sPOLChildToken.balanceOf(slowSeller1);
        uint256 sPOL2 = sPOLChildToken.balanceOf(slowSeller2);
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(sPOL1);
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(sPOL2);

        vm.prank(slowSeller1);
        sPOLChildToken.sellSPOL(sPOL1);
        vm.prank(slowSeller2);
        sPOLChildToken.sellSPOL(sPOL2);

        vm.prank(slowSeller1);
        vm.expectRevert("No POL to withdraw");
        sPOLChildToken.withdrawPOL();
        vm.prank(slowSeller2);
        vm.expectRevert("No POL to withdraw");
        sPOLChildToken.withdrawPOL();

        // Add POL only enough for first seller
        address polProvider = makeAddr("polProvider");
        uint256 partialPOL = expectedPOL1 + 0.5e18;
        vm.deal(polProvider, partialPOL);

        vm.prank(polProvider);
        sPOLChildToken.buySPOL{value: partialPOL}(partialPOL);

        // First seller should be able to withdraw
        vm.prank(slowSeller1);
        sPOLChildToken.withdrawPOL();
        assertEq(slowSeller1.balance, initialBalance1 + expectedPOL1, "First seller should receive POL");

        // Second seller still can't withdraw (insufficient remaining reserve)
        vm.prank(slowSeller2);
        vm.expectRevert("No POL to withdraw");
        sPOLChildToken.withdrawPOL();

        // Add more POL for second seller
        uint256 morePOL = expectedPOL2 + 0.5e18;
        vm.deal(polProvider, morePOL);
        vm.prank(polProvider);
        sPOLChildToken.buySPOL{value: morePOL}(morePOL);

        // Now second seller can withdraw
        vm.prank(slowSeller2);
        sPOLChildToken.withdrawPOL();
        assertEq(slowSeller2.balance, initialBalance2 + expectedPOL2, "Second seller should receive POL");
    }

    function test_sellSPOL_SlowSell_MultipleOutstanding_AutoSelectiveWithdraw() public {
        address user = makeAddr("user");

        vm.prank(childChainManager);
        sPOLChildToken.deposit(user, abi.encode(5e18));
        uint256 firstSell = 1e18;
        uint256 secondSell = 2e18;
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(firstSell);
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(secondSell);

        vm.prank(user);
        sPOLChildToken.sellSPOL(firstSell);
        vm.prank(user);
        sPOLChildToken.sellSPOL(secondSell);

        (uint256 outstanding1,,) = sPOLChildToken.userOutstandingPOL(user, 0);
        (uint256 outstanding2,,) = sPOLChildToken.userOutstandingPOL(user, 1);
        assertEq(outstanding1, expectedPOL1);
        assertEq(outstanding2, expectedPOL2);

        // Add enough POL to cover only the first withdrawal
        address polProvider = makeAddr("polProvider");
        uint256 partialPOL = expectedPOL1 + 0.1e18;
        vm.deal(polProvider, partialPOL);
        vm.prank(polProvider);
        sPOLChildToken.buySPOL{value: partialPOL}(partialPOL);

        // Withdraw should only process first outstanding
        uint256 initialBalance = user.balance;
        vm.prank(user);
        sPOLChildToken.withdrawPOL();

        assertEq(user.balance, initialBalance + expectedPOL1, "Should only withdraw first amount");

        // Second outstanding should remain
        (uint256 remainingOutstanding,,) = sPOLChildToken.userOutstandingPOL(user, 0);
        assertEq(remainingOutstanding, expectedPOL2, "Second outstanding should remain");

        // Should revert accessing index 1 now
        vm.expectRevert();
        sPOLChildToken.userOutstandingPOL(user, 1);
    }

    function test_sellSPOL_SlowSell_MultipleOutstanding_LaterFirstWithdraw() public {
        address user = makeAddr("user");

        vm.prank(childChainManager);
        sPOLChildToken.deposit(user, abi.encode(5e18));
        uint256 firstSell = 2e18;
        uint256 secondSell = 1e18;
        uint256 expectedPOL1 = sPOLChildToken.convertSPOLToPOL(firstSell);
        uint256 expectedPOL2 = sPOLChildToken.convertSPOLToPOL(secondSell);

        vm.prank(user);
        sPOLChildToken.sellSPOL(firstSell);
        vm.prank(user);
        sPOLChildToken.sellSPOL(secondSell);

        (uint256 outstanding1,,) = sPOLChildToken.userOutstandingPOL(user, 0);
        (uint256 outstanding2,,) = sPOLChildToken.userOutstandingPOL(user, 1);
        assertEq(outstanding1, expectedPOL1);
        assertEq(outstanding2, expectedPOL2);

        // Add enough POL to cover only the second withdrawal
        address polProvider = makeAddr("polProvider");
        uint256 partialPOL = expectedPOL1 + 0.1e18;
        vm.deal(polProvider, partialPOL);
        vm.prank(polProvider);
        sPOLChildToken.buySPOL{value: partialPOL}(partialPOL);

        // Withdraw should only process first outstanding
        uint256 initialBalance = user.balance;
        vm.prank(user);
        sPOLChildToken.withdrawPOL();

        assertEq(user.balance, initialBalance + expectedPOL1, "Should only withdraw first amount");

        // Second outstanding should remain
        (uint256 remainingOutstanding,,) = sPOLChildToken.userOutstandingPOL(user, 0);
        assertEq(remainingOutstanding, expectedPOL2, "Second outstanding should remain");

        // Should revert accessing index 1 now
        vm.expectRevert();
        sPOLChildToken.userOutstandingPOL(user, 1);
    }
}
