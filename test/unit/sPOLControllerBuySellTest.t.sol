// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sPOLController.sol";
import "../../src/sPOL.sol";
import "../../script/Deploy.s.sol";
import "../mocks/MockValidatorShare.sol";
import "../mocks/MockStakeManager.sol";
import "../mocks/MockPOLToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract sPOLControllerBuySellTest is Test, Deploy {
    sPOLController controller;
    IERC20 sPOLToken;

    uint8[] depositShares;
    uint16[] validators;

    // Test addresses
    address testAdmin;
    address testFeeReceiver = makeAddr("testFeeReceiver");
    address testValidatorShare1 = address(new MockValidatorShare());
    address testValidatorShare2 = address(new MockValidatorShare());
    address testValidatorShare3 = address(new MockValidatorShare());

    // Test validator IDs
    uint16 constant VALIDATOR_1 = 35;
    uint16 constant VALIDATOR_2 = 120;
    uint16 constant VALIDATOR_3 = 73;

    address user;
    uint256 privateKey;

    function setUp() public {
        (user, privateKey) = makeAddrAndKey("user");

        loadMockConfig();

        polTokenL1 = address(new MockPOLToken("POL", "POL"));
        stakeManager = _setUpMockStakeManager();

        deployContractsL1(address(this));
        testAdmin = admin;

        controller = sPOLController(address(sPOLControllerProxy));
        sPOLToken = IERC20(address(sPOLProxy));

        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_2);

        MockPOLToken(polTokenL1).approve(address(controller), type(uint256).max);

        validators = new uint16[](2);
        validators[0] = VALIDATOR_1;
        validators[1] = VALIDATOR_2;

        depositShares = new uint8[](2);
        depositShares[0] = 50;
        depositShares[1] = 50;

        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validators, depositShares);
    }

    function _setUpMockStakeManager() internal returns (address) {
        MockStakeManager mockStakeManager = new MockStakeManager();
        mockStakeManager.setValidatorContract(VALIDATOR_1, testValidatorShare1);
        mockStakeManager.setValidatorContract(VALIDATOR_2, testValidatorShare2);
        mockStakeManager.setValidatorContract(VALIDATOR_3, testValidatorShare3);
        return address(mockStakeManager);
    }

    ////////////////////////////////////////
    ///  Buy Tests                       ///
    ////////////////////////////////////////

    function test_buySPOLSingle_VALIDATOR_OVERFUNDED() public {
        vm.expectRevert(abi.encodeWithSelector(sPOLController.ValidatorOverfunded.selector, 1 ether, 0));
        controller.buySPOL(1 ether, VALIDATOR_1);
    }

    function test_buySPOLSingle_VALIDATOR_NOT_ACTIVE() public {
        controller.buySPOL(1e18);
        depositShares[0] = 0;
        depositShares[1] = 100;
        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validators, depositShares);
        vm.prank(testAdmin);
        controller.freezeValidator(VALIDATOR_1);
        vm.expectRevert(abi.encodeWithSelector(sPOLController.ValidatorNotActive.selector, VALIDATOR_1));
        controller.buySPOL(1 ether, VALIDATOR_1);
    }

    function test_buySPOLSingle_VS_failure() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount * 10);

        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndStakePOL.selector), "failure"
        );
        vm.expectRevert("failure");
        controller.buySPOL(amount, VALIDATOR_1);
    }

    function test_buySPOLMulti_VS_failure() public {
        uint256 amount = 1e18;

        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndStakePOL.selector), "failure"
        );
        vm.expectRevert("failure");
        controller.buySPOL(amount);
    }

    function test_buySPOLSingle_() public {
        // buying a whole POL fill up both validators. This prevents triggering the Overfunded error
        controller.buySPOL(1e18);
        controller.buySPOL(1, VALIDATOR_1);

        assertEq(controller.totaldPOLBalance(), 1e18 + 1, "Total dPOL balance should be 1");
        assertEq(controller.totalsPOLBalance(), 1e18 + 1, "Total POL balance should be 1");
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            1e18 / 2 + 1,
            "Validator 1 balance should be half plus 1"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            1e18 / 2,
            "Validator 2 balance should be half"
        );
        assertEq(controller.feedPOLBalance(), 0, "Feed POL balance should be 0");
        assertEq(sPOLToken.balanceOf(address(this)), 1e18 + 1, "Balance should be 1");
        matchBalanceWithTotalStake(1e18 + 1);
    }

    function test_buySPOLSingle_consecutive_with_rewards() public {
        uint256 amount = 1e18;
        uint256 reward = 1e16;
        uint256 zeroBuyReceived = controller.buySPOL(amount * 10);
        assertEq(controller.totalsPOLBalance(), amount * 10, "Total sPOL balance should be amount * 10");
        assertEq(controller.convertSPOLtoPOL(amount), amount, "Conversion rate should be 1:1");

        // rewards in both validators, only first one selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        uint256 firstBuyReceived = controller.buySPOL(amount, VALIDATOR_1);

        assertEq(zeroBuyReceived, firstBuyReceived * 10, "First buy should get favorable rate of 1:1");
        assertEq(
            controller.totaldPOLBalance(), amount * 11 + reward, "Total dPOL balance should be amount * 11 + reward"
        );
        assertEq(controller.totalsPOLBalance(), amount * 11, "Total sPOL balance should be amount * 11");
        assertEq(sPOLToken.balanceOf(address(this)), amount * 11, "Balance should be amount * 11");
        assertGt(controller.convertSPOLtoPOL(amount), amount, "Conversion rate should be improved");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount + 5 * amount + reward,
            "Validator 1 balance should be half first buy plus full second buy plus reward"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            5 * amount,
            "Validator 2 balance should be half first buy"
        );
        assertEq(MockValidatorShare(testValidatorShare2).reward(), reward, "Validator 2 reward untouched");
        matchBalanceWithTotalStake(amount * 11 + reward);

        // rewards in both validators, only second one selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        uint256 secondBuyReceived = controller.buySPOL(amount, VALIDATOR_2);

        assertGt(firstBuyReceived, secondBuyReceived, "Second buy should be less");

        assertLt(controller.totalsPOLBalance(), amount * 12, "Total sPOL balance should be less than amount * 12");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            5 * amount + amount + reward,
            "Validator 1 balance should not have changed"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            5 * amount + amount + 2 * reward,
            "Validator 2 balance reduced by second withdraw"
        );
        assertEq(MockValidatorShare(testValidatorShare1).reward(), reward, "Validator 1 reward");
        assertEq(MockValidatorShare(testValidatorShare2).reward(), 0, "Validator 2 reward redeemed");
        matchBalanceWithTotalStake(amount * 12 + reward * 3);
    }

    function test_buySPOLMulti() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount);

        assertEq(sPOLToken.balanceOf(address(this)), amount, "Balance should be 1");
        assertEq(controller.feedPOLBalance(), 0, "Feed POL balance should be 0");
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount / 2,
            "Validator 1 balance should be half"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount / 2,
            "Validator 2 balance should be half"
        );

        assertEq(controller.totaldPOLBalance(), 1e18, "Total dPOL balance should be 1");
        assertEq(controller.totalsPOLBalance(), 1e18, "Total POL balance should be 1");
        matchBalanceWithTotalStake(1e18);
    }

    function test_buySPOLMulti_Consecutive() public {
        controller.buySPOL(1e18);
        controller.buySPOL(1e18);

        assertEq(controller.feedPOLBalance(), 0, "Feed POL balance should be 0");
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            2e18 / 2,
            "Validator 1 balance should be half"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            2e18 / 2,
            "Validator 2 balance should be half"
        );
        assertEq(controller.totaldPOLBalance(), 2e18, "Total dPOL balance should be 2");
        assertEq(controller.totalsPOLBalance(), 2e18, "Total POL balance should be 2");
        assertEq(sPOLToken.balanceOf(address(this)), 2e18, "Balance should be 2");
        matchBalanceWithTotalStake(2e18);
    }

    function test_buySPOLMulti_consecutive_with_rewards() public {
        uint256 amount = 1e18;
        uint256 reward = 1e16;
        uint256 zeroBuyReceived = controller.buySPOL(amount);
        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be amount");
        assertEq(controller.convertSPOLtoPOL(amount), amount, "Conversion rate should be 1:1");

        // rewards in both validators, both selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        uint256 firstBuyReceived = controller.buySPOL(amount);

        assertEq(zeroBuyReceived, firstBuyReceived, "First buy should get favorable rate of 1:1");
        assertEq(
            controller.totaldPOLBalance(),
            2 * amount + 2 * reward,
            "Total dPOL balance should be amount * 2 + reward * 2"
        );
        assertEq(controller.totalsPOLBalance(), amount * 2, "Total sPOL balance should be amount * 2");
        assertEq(sPOLToken.balanceOf(address(this)), amount * 2, "Balance should be amount * 2");
        assertGt(controller.convertSPOLtoPOL(amount), amount, "Conversion rate should be improved");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount + reward,
            "Validator 1 balance should be half first buy plus half second buy plus reward"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount + reward,
            "Validator 2 balance should be half first buy plus half second buy plus reward"
        );
        assertEq(MockValidatorShare(testValidatorShare1).reward(), 0, "Validator 1 reward redeemed");
        assertEq(MockValidatorShare(testValidatorShare2).reward(), 0, "Validator 2 reward redeemed");
        matchBalanceWithTotalStake(amount * 2 + reward * 2);

        // rewards in both validators, only first one selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        uint256 secondBuyReceived = controller.buySPOL(amount / 2);

        assertGt(firstBuyReceived, secondBuyReceived, "Second buy should be less sPOL");

        assertLt(controller.totalsPOLBalance(), amount * 3, "Total sPOL balance should be less than amount * 3");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount + amount / 2 + reward * 2,
            "Validator 1 balance should not have changed"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount + reward,
            "Validator 2 balance reduced by second withdraw"
        );
        assertEq(MockValidatorShare(testValidatorShare1).reward(), 0, "Validator 1 reward redeemed");
        assertEq(MockValidatorShare(testValidatorShare2).reward(), reward, "Validator 2 reward");
        matchBalanceWithTotalStake(amount * 2 + amount / 2 + reward * 3);
    }

    ////////////////////////////////////////
    ///  Locked Validator Tests          ///
    ////////////////////////////////////////

    function test_buySPOLMulti_skipsLockedValidator_whenSingleValidatorHasCapacity() public {
        // When one validator is locked AND the unlocked validator has enough capacity,
        // the locked check in _validatorMaxTotalStakeDistance works correctly.
        // First, fund validators so they have some stake (makes one underfunded relative to target)
        controller.buySPOL(10e18);

        // Lock validator 1
        MockValidatorShare(testValidatorShare1).setLocked(true);

        // Buy a small amount that validator 2 can handle alone
        uint256 amount = 1e18;
        uint256 val1Before = MockValidatorShare(testValidatorShare1).balanceOf(address(controller));
        uint256 val2Before = MockValidatorShare(testValidatorShare2).balanceOf(address(controller));

        controller.buySPOL(amount);

        // Validator 1 (locked) should not receive new funds
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            val1Before,
            "Validator 1 (locked) balance should not change"
        );
        // Validator 2 should receive all
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            val2Before + amount,
            "Validator 2 should receive all new stake"
        );
    }

    function test_buySPOLMulti_skipsLockedValidator_inFallbackDistribution() public {
        // Verify that locked validators are skipped even in fallback distribution
        // (when no single validator has enough capacity, e.g., on empty state)
        MockValidatorShare(testValidatorShare1).setLocked(true);

        uint256 amount = 1e18;
        // On empty state, the fallback distribution kicks in
        // Locked validator should be skipped, all goes to validator 2
        controller.buySPOL(amount);

        // Locked validator receives nothing
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            0,
            "Locked validator should receive nothing"
        );
        // Unlocked validator receives everything
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount,
            "Unlocked validator receives all"
        );
    }

    function test_buySPOLMulti_allLockedReverts() public {
        // When all validators are locked, multi-buy should revert
        MockValidatorShare(testValidatorShare1).setLocked(true);
        MockValidatorShare(testValidatorShare2).setLocked(true);

        uint256 amount = 1e18;
        vm.expectRevert(abi.encodeWithSelector(sPOLController.NoUnlockedValidators.selector));
        controller.buySPOL(amount);
    }

    function test_buySPOLSingle_lockedValidatorReverts() public {
        // Single buy with explicit validator ID will fail on the validator contract itself
        // The locked check in _validatorMaxTotalStakeDistance doesn't protect this path
        // because _buySPOLSingle uses _maxDeposit directly
        controller.buySPOL(1e18); // First buy to allow subsequent single buys

        MockValidatorShare(testValidatorShare1).setLocked(true);

        uint256 amount = 1;
        // This will revert on the validator share contract when attempting to stake
        // The exact error depends on the validator share implementation
        vm.mockCallRevert(
            testValidatorShare1,
            abi.encodeWithSelector(MockValidatorShare.restakeAndStakePOL.selector),
            "validator locked"
        );
        vm.expectRevert("validator locked");
        controller.buySPOL(amount, VALIDATOR_1);
    }

    function test_getMostUnderfundedValidator_skipsLockedValidator() public {
        // Verify the getMostUnderfundedValidator function skips locked validators
        controller.buySPOL(1e18);

        // Lock validator 1 (which should be equally funded)
        MockValidatorShare(testValidatorShare1).setLocked(true);

        (uint16 validatorId, uint256 maxDeposit) = controller.getMostUnderfundedValidator();
        assertEq(validatorId, VALIDATOR_2, "Should return validator 2 since validator 1 is locked");
        assertGt(maxDeposit, 0, "Max deposit should be positive");
    }

    ////////////////////////////////////////
    ///  Permit Tests                    ///
    ////////////////////////////////////////

    function test_buySPOLPermit() public {
        uint256 amount = 1e18;
        uint256 deadline = block.timestamp + 100;

        // Transfer POL to user
        IERC20(polTokenL1).transfer(user, amount + 1);

        // Create permit signature
        (uint8 v, bytes32 r, bytes32 s) =
            _createPermitSignature(ERC20Permit(polTokenL1), user, address(controller), amount, deadline, privateKey);

        // Call buySPOLPermit
        controller.buySPOLPermit(amount, user, deadline, v, r, s);

        // Verify sPOL was minted to user
        assertEq(sPOLToken.balanceOf(user), amount, "User should have received sPOL");
        assertEq(IERC20(polTokenL1).balanceOf(user), 1, "User's POL should be spent");
        assertEq(controller.totaldPOLBalance(), amount, "Total dPOL balance should be 2");
        assertEq(controller.totalsPOLBalance(), amount, "Total POL balance should be 2");

        // Create permit signature
        (v, r, s) = _createPermitSignature(ERC20Permit(polTokenL1), user, address(controller), 1, deadline, privateKey);

        controller.buySPOLPermit(1, VALIDATOR_1, user, deadline, v, r, s);
        assertEq(sPOLToken.balanceOf(user), amount + 1, "User should have received sPOL");
        assertEq(IERC20(polTokenL1).balanceOf(user), 0, "User's POL should be spent");
        assertEq(controller.totaldPOLBalance(), amount + 1, "Total dPOL balance should be 2");
        assertEq(controller.totalsPOLBalance(), amount + 1, "Total POL balance should be 2");
    }

    ////////////////////////////////////////
    ///  Sell Tests                      ///
    ////////////////////////////////////////

    function test_sellSPOLSingle_underfunded() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount);

        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be 2 * amount");
        (, uint256 maxUnstake) = controller.getMostOverfundedValidator();
        vm.expectRevert(abi.encodeWithSelector(sPOLController.ValidatorUnderfunded.selector, amount, maxUnstake));
        controller.sellSPOL(amount, VALIDATOR_1);
    }

    function test_sellSPOLSingle_VS_fallback_success() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount * 100);

        // Add reward to validator 1
        uint256 reward = 1e16;
        MockValidatorShare(testValidatorShare1).addReward(reward);

        // Mock restakeAndUnstakePOL to fail - fallback to sellVoucher_newPOL should succeed
        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );

        uint256 dPOLBefore = controller.totaldPOLBalance();
        uint256 sPOLBefore = controller.totalsPOLBalance();
        (,,,, uint256 val1StakeBefore) = controller.validators(VALIDATOR_1);

        controller.sellSPOL(amount, VALIDATOR_1);

        // Verify sell succeeded via fallback
        assertEq(controller.totaldPOLBalance(), dPOLBefore - amount, "Total dPOL balance should decrease by amount");
        assertEq(controller.totalsPOLBalance(), sPOLBefore - amount, "Total sPOL balance should decrease by amount");

        // Verify validator stake decreased but reward was NOT restaked (fallback doesn't restake)
        (,,,, uint256 val1StakeAfter) = controller.validators(VALIDATOR_1);
        assertEq(val1StakeAfter, val1StakeBefore - amount, "Validator 1 stake should decrease by amount only");

        // Reward gets dropped when selling without restaking (not captured by controller)
        assertEq(MockValidatorShare(testValidatorShare1).reward(), 0, "Reward should be dropped");
    }

    function test_sellSPOLMulti_VS_fallback_success() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount);

        // Add rewards to both validators
        uint256 reward = 1e16;
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        // Mock restakeAndUnstakePOL to fail on both validators - fallback should succeed
        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );
        vm.mockCallRevert(
            testValidatorShare2, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );

        controller.sellSPOL(amount);

        // Verify sell succeeded via fallback
        assertEq(controller.totaldPOLBalance(), 0, "Total dPOL balance should be 0");
        assertEq(controller.totalsPOLBalance(), 0, "Total sPOL balance should be 0");

        // Rewards get dropped when selling without restaking (not captured by controller)
        assertEq(MockValidatorShare(testValidatorShare1).reward(), 0, "Validator 1 reward should be dropped");
        assertEq(MockValidatorShare(testValidatorShare2).reward(), 0, "Validator 2 reward should be dropped");
    }

    function test_sellSPOLSingle_VS_fallback_also_fails() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount * 100);

        // Mock both restakeAndUnstakePOL AND sellVoucher_newPOL to fail
        vm.mockCallRevert(
            testValidatorShare1,
            abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector),
            "restake failed"
        );
        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.sellVoucher_newPOL.selector), "sell failed"
        );

        vm.expectRevert("sell failed");
        controller.sellSPOL(amount, VALIDATOR_1);
    }

    function test_sellSPOLMulti_VS_fallback_also_fails() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount);

        // Mock both restakeAndUnstakePOL AND sellVoucher_newPOL to fail on first validator
        vm.mockCallRevert(
            testValidatorShare1,
            abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector),
            "restake failed"
        );
        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.sellVoucher_newPOL.selector), "sell failed"
        );

        vm.expectRevert("sell failed");
        controller.sellSPOL(amount);
    }

    function test_sellSPOLMulti_VS_partial_fallback() public {
        // Test where validator 1 needs fallback but validator 2 works normally
        uint256 amount = 1e18;
        controller.buySPOL(amount * 6);

        uint256 reward = 1e16;
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        // Mock restakeAndUnstakePOL to fail ONLY on validator 1
        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );

        uint256 feedPOLBefore = controller.feedPOLBalance();

        // Sell enough to use both validators
        controller.sellSPOL(amount * 2);

        // Validator 2 should have restaked rewards and added to fee
        // Validator 1 should have used fallback (no restake, no fee from v1 rewards)
        assertGt(controller.feedPOLBalance(), feedPOLBefore, "Fee should increase from validator 2 rewards");

        // Validator 1 reward dropped (fallback path)
        assertEq(MockValidatorShare(testValidatorShare1).reward(), 0, "Validator 1 reward should be dropped");
        // Validator 2 reward should be claimed (normal path)
        assertEq(MockValidatorShare(testValidatorShare2).reward(), 0, "Validator 2 reward should be claimed");
    }

    function test_sellSPOLSingle_VS_fallback_nonce_tracking() public {
        // Verify nonce is correctly tracked even when using fallback
        uint256 amount = 1e18;
        controller.buySPOL(amount * 100);

        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );

        uint256 nonceBefore = controller.globalWithdrawNonce();

        uint256 returnedNonce = controller.sellSPOL(amount, VALIDATOR_1);

        // Verify nonce was returned and tracked
        assertEq(returnedNonce, nonceBefore, "Returned nonce should match global nonce before");
        assertEq(controller.globalWithdrawNonce(), nonceBefore + 1, "Global nonce should increment");

        // Verify nonce details are stored
        (uint16 validatorId, uint128 withdrawAmount,) = controller.withdrawNonceDetails(returnedNonce);
        assertEq(validatorId, VALIDATOR_1, "Nonce should track validator 1");
        assertEq(withdrawAmount, amount, "Nonce should track correct amount");
    }

    function test_sellSPOLSingle_VS_fallback_balance_consistency() public {
        // Verify balance consistency when using fallback
        uint256 amount = 1e18;
        controller.buySPOL(amount * 100);

        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );

        controller.sellSPOL(amount, VALIDATOR_1);

        // Verify balances remain consistent
        matchBalanceWithTotalStake(amount * 99);
    }

    function test_sellSPOLMulti_VS_fallback_consecutive() public {
        // Test consecutive sells with fallback
        uint256 amount = 1e18;
        controller.buySPOL(amount * 10);

        // First sell: normal path
        controller.sellSPOL(amount);
        assertEq(controller.totaldPOLBalance(), amount * 9, "Balance after first sell");

        // Mock failure for second sell
        vm.mockCallRevert(
            testValidatorShare1, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );
        vm.mockCallRevert(
            testValidatorShare2, abi.encodeWithSelector(MockValidatorShare.restakeAndUnstakePOL.selector), "failure"
        );

        // Second sell: fallback path
        controller.sellSPOL(amount);
        assertEq(controller.totaldPOLBalance(), amount * 8, "Balance after second sell with fallback");

        // Clear mocks for third sell
        vm.clearMockedCalls();

        // Third sell: back to normal path
        controller.sellSPOL(amount);
        assertEq(controller.totaldPOLBalance(), amount * 7, "Balance after third sell");
    }

    function test_sellSPOLSingle() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount * 10);
        assertEq(controller.totalsPOLBalance(), amount * 10, "Total sPOL balance should be 10 * amount");

        controller.sellSPOL(amount, VALIDATOR_2);

        assertEq(controller.totaldPOLBalance(), amount * 9, "Total dPOL balance should be 9 * amount");
        assertEq(controller.totalsPOLBalance(), amount * 9, "Total sPOL balance should be 9 * amount");
        assertEq(sPOLToken.balanceOf(address(this)), amount * 9, "Balance should be 9 * amount");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            5 * amount,
            "Validator 1 balance should be 5 * amount"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            4 * amount,
            "Validator 2 balance should be 4 * amount"
        );
        matchBalanceWithTotalStake(amount * 9);
    }

    function test_sellSPOLSingle_consecutive_with_rewards() public {
        uint256 amount = 1e18;
        uint256 reward = 1e16;
        controller.buySPOL(amount * 11);
        assertEq(controller.totalsPOLBalance(), amount * 11, "Total sPOL balance should be 11 * amount");
        assertEq(controller.convertSPOLtoPOL(amount), amount, "Conversion rate should be 1:1");

        // rewards in both validators, only first one selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        controller.sellSPOL(amount, VALIDATOR_1);

        assertEq(
            controller.totaldPOLBalance(), amount * 10 + reward, "Total dPOL balance should be amount * 10 + reward"
        );
        assertEq(controller.totalsPOLBalance(), amount * 10, "Total sPOL balance should be amount * 10");
        assertEq(sPOLToken.balanceOf(address(this)), amount * 10, "Balance should be amount * 10");
        (, uint128 firstWithdraw,) = controller.withdrawNonceDetails(1);
        assertEq(firstWithdraw, amount, "First withdraw amount should be amount");
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            4 * amount + amount / 2 + reward,
            "Validator 1 balance should be have lost amount, but received reward"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            5 * amount + amount / 2,
            "Validator 2 balance untouched"
        );
        assertEq(MockValidatorShare(testValidatorShare2).reward(), reward, "Validator 2 reward untouched");
        matchBalanceWithTotalStake(amount * 10 + reward);

        // rewards in both validators, both selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        controller.sellSPOL(amount, VALIDATOR_2);

        (, uint128 secondWithdraw,) = controller.withdrawNonceDetails(2);
        assertGt(secondWithdraw, firstWithdraw, "Second withdraw should be larger than first");
        assertEq(
            controller.totaldPOLBalance() + secondWithdraw,
            10 * amount + 3 * reward,
            "Total dPOL balance plus withdraws should match 10 * amount + 3 * reward"
        );
        assertEq(controller.totalsPOLBalance(), amount * 9, "Total sPOL balance should be amount * 9");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            4 * amount + amount / 2 + reward,
            "Validator 1 balance should not have changed"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            5 * amount + amount / 2 + 2 * reward - secondWithdraw,
            "Validator 2 balance reduced by second withdraw"
        );
        assertEq(MockValidatorShare(testValidatorShare1).reward(), reward, "Validator 1 reward");
        assertEq(MockValidatorShare(testValidatorShare2).reward(), 0, "Validator 2 reward redeemed");
        // TODO: calc dPOL balance properly in the test
        matchBalanceWithTotalStake(controller.totaldPOLBalance());
    }

    function test_sellSPOLMulti() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount);
        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be amount");

        controller.sellSPOL(amount);

        assertEq(controller.totaldPOLBalance(), 0, "Total dPOL balance should be 0");
        assertEq(controller.totalsPOLBalance(), 0, "Total sPOL balance should be 0");
        assertEq(sPOLToken.balanceOf(address(this)), 0, "Balance should be 0");
        matchBalanceWithTotalStake(0);
    }

    function test_sellSPOLMulti_consecutive() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount * 3);
        assertEq(controller.totalsPOLBalance(), amount * 3, "Total sPOL balance should be 3 * amount");

        controller.sellSPOL(amount);
        controller.sellSPOL(amount * 2);

        assertEq(controller.totaldPOLBalance(), 0, "Total dPOL balance should be 0");
        assertEq(controller.totalsPOLBalance(), 0, "Total sPOL balance should be 0");
        assertEq(sPOLToken.balanceOf(address(this)), 0, "Balance should be 0");
        matchBalanceWithTotalStake(0);
    }

    function test_sellSPOLMulti_consecutive_with_rewards() public {
        uint256 amount = 1e18;
        uint256 reward = 1e16;
        controller.buySPOL(amount * 11);
        assertEq(controller.totalsPOLBalance(), amount * 11, "Total sPOL balance should be 11 * amount");
        assertEq(controller.convertSPOLtoPOL(amount), amount, "Conversion rate should be 1:1");

        // rewards in both validators, only first one selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);

        controller.sellSPOL(amount);

        assertEq(
            controller.totaldPOLBalance(), amount * 10 + reward, "Total dPOL balance should be amount * 3 + reward"
        );
        assertEq(controller.totalsPOLBalance(), amount * 10, "Total sPOL balance should be amount * 3");
        assertEq(sPOLToken.balanceOf(address(this)), amount * 10, "Balance should be amount * 3");
        (, uint128 firstWithdraw,) = controller.withdrawNonceDetails(1);
        assertEq(firstWithdraw, amount, "First withdraw amount should be amount");
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            4 * amount + amount / 2 + reward,
            "Validator 1 balance should be have lost amount, but received reward"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            5 * amount + amount / 2,
            "Validator 2 balance untouched"
        );
        assertEq(MockValidatorShare(testValidatorShare2).reward(), reward, "Validator 2 reward untouched");
        matchBalanceWithTotalStake(amount * 10 + reward);

        // rewards in both validators, both selected
        MockValidatorShare(testValidatorShare1).addReward(reward);
        MockValidatorShare(testValidatorShare2).addReward(reward);
        controller.sellSPOL(5 * amount);

        (, uint128 secondWithdraw,) = controller.withdrawNonceDetails(2);
        (, uint128 thirdWithdraw,) = controller.withdrawNonceDetails(3);
        assertGt(secondWithdraw + thirdWithdraw, firstWithdraw * 5, "Second total withdraw should be larger than first");
        assertEq(
            controller.totaldPOLBalance() + secondWithdraw + thirdWithdraw,
            10 * amount + 4 * reward,
            "Total dPOL balance plus withdraws should match 10 * amount + 4 * reward"
        );
        assertEq(controller.totalsPOLBalance(), amount * 5, "Total sPOL balance should be amount * 5");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            4 * amount + amount / 2 + 2 * reward - secondWithdraw,
            "Validator 1 balance should be have lost amount, but received reward"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            5 * amount + amount / 2 + 2 * reward - thirdWithdraw,
            "Validator 2 balance untouched"
        );
        assertEq(MockValidatorShare(testValidatorShare1).reward(), 0, "Validator 1 reward redeemed");
        assertEq(MockValidatorShare(testValidatorShare2).reward(), 0, "Validator 2 reward redeemed");
        // TODO: calc dPOL balance properly in the test
        matchBalanceWithTotalStake(controller.totaldPOLBalance());
    }

    function test_sellSPOLMulti_consecutive_remain() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount * 6);
        assertEq(controller.totalsPOLBalance(), amount * 6, "Total sPOL balance should be 6 * amount");

        controller.sellSPOL(amount);
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            2 * amount,
            "Validator 1 balance should be half total minus amount"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            3 * amount,
            "Validator 2 balance should be 3 * amount"
        );
        controller.sellSPOL(amount * 2);

        assertEq(controller.totaldPOLBalance(), amount * 3, "Total dPOL balance should be 3 * amount");
        assertEq(controller.totalsPOLBalance(), amount * 3, "Total sPOL balance should be 3 * amount");
        assertEq(sPOLToken.balanceOf(address(this)), amount * 3, "Balance should be 3 * amount");

        // can't split, so it starts taking everything from first validator
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)), 0, "Validator 1 balance should be 0"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            3 * amount,
            "Validator 2 balance should be 3 * amount"
        );
        matchBalanceWithTotalStake(amount * 3);
    }

    function test_sellSPOLPermit_single() public {
        uint256 amount = 1e18;
        uint256 deadline = block.timestamp + 100;
        controller.buySPOL(amount * 10);
        assertEq(controller.totalsPOLBalance(), 10 * amount, "Total sPOL balance should be 10 * amount");

        // Transfer sPOL to user
        sPOLToken.transfer(user, amount);

        (uint8 v, bytes32 r, bytes32 s) = _createPermitSignature(
            ERC20Permit(address(sPOLToken)), user, address(controller), amount / 4, deadline, privateKey
        );

        controller.sellSPOLPermit(amount / 4, VALIDATOR_2, user, deadline, v, r, s);

        assertEq(
            controller.totaldPOLBalance(),
            9 * amount + amount * 3 / 4,
            "Total dPOL balance should be 9 * amount + amount * 3 / 4"
        );
        assertEq(
            controller.totalsPOLBalance(),
            9 * amount + amount * 3 / 4,
            "Total sPOL balance should be 9 * amount + amount * 3 / 4"
        );

        (v, r, s) = _createPermitSignature(
            ERC20Permit(address(sPOLToken)), user, address(controller), amount * 3 / 4, deadline, privateKey
        );
        controller.sellSPOLPermit(amount * 3 / 4, VALIDATOR_1, user, deadline, v, r, s);

        assertEq(controller.totaldPOLBalance(), 9 * amount, "Total dPOL balance should be 9 * amount");
        assertEq(controller.totalsPOLBalance(), 9 * amount, "Total sPOL balance should be 9 * amount");
        matchBalanceWithTotalStake(9 * amount);
    }

    function test_sellSPOLPermit() public {
        uint256 amount = 1e18;
        uint256 deadline = block.timestamp + 100;
        controller.buySPOL(amount);
        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be amount");

        // Transfer sPOL to user
        sPOLToken.transfer(user, amount);

        (uint8 v, bytes32 r, bytes32 s) = _createPermitSignature(
            ERC20Permit(address(sPOLToken)), user, address(controller), amount / 4, deadline, privateKey
        );

        controller.sellSPOLPermit(amount / 4, user, deadline, v, r, s);

        assertEq(controller.totaldPOLBalance(), amount * 3 / 4, "Total dPOL balance should be amount * 3 / 4");
        assertEq(controller.totalsPOLBalance(), amount * 3 / 4, "Total sPOL balance should be amount * 3 / 4");

        (v, r, s) = _createPermitSignature(
            ERC20Permit(address(sPOLToken)), user, address(controller), amount * 3 / 4, deadline, privateKey
        );
        controller.sellSPOLPermit(amount * 3 / 4, user, deadline, v, r, s);

        assertEq(controller.totaldPOLBalance(), 0, "Total dPOL balance should be 0");
        assertEq(controller.totalsPOLBalance(), 0, "Total sPOL balance should be 0");
        matchBalanceWithTotalStake(0);
    }

    function test_sellSPOL_withdrawNonce_no_zero() public {
        assertEq(controller.globalWithdrawNonce(), 1, "Global withdraw nonce should be 1");
        uint256 amount = 1e18;
        controller.buySPOL(amount);
        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be amount");

        controller.sellSPOL(amount);
        sPOLController.FullNonceDetails[] memory nonces = controller.getUserOpenNonces(address(this));
        assertEq(nonces.length, 2, "Nonce queue length should be 2");
        assertEq(nonces[0].nonce, 1, "First nonce should be 1");
        assertEq(nonces[1].nonce, 2, "Second nonce should be 2");
    }

    function test_sellSPOL_withdrawNonce_increases() public {
        assertEq(controller.globalWithdrawNonce(), 1, "Global withdraw nonce should be 1");
        uint256 amount = 1e18;
        controller.buySPOL(amount * 2);
        assertEq(controller.totalsPOLBalance(), amount * 2, "Total sPOL balance should be amount");

        controller.sellSPOL(amount);
        sPOLController.FullNonceDetails[] memory nonces = controller.getUserOpenNonces(address(this));
        assertEq(nonces[0].nonce, 1, "First nonce should be 1");
        assertEq(nonces.length, 1, "Nonce queue length should be 1");
        controller.sellSPOL(amount);
        nonces = controller.getUserOpenNonces(address(this));
        assertEq(nonces[0].nonce, 1, "First nonce should be 1");
        assertEq(nonces[1].nonce, 2, "Second nonce should be 2");
        assertEq(nonces.length, 2, "Nonce queue length should be 2");
        assertEq(3, controller.globalWithdrawNonce(), "Global withdraw nonce should be 3");
    }

    function test_buySharesFromValidatorBug_LiquidRewardsIncludedInAmountDeposited() public {
        uint256 stakeAmount = 2 ether;
        uint256 liquidRewards = 0.01 ether;

        controller.buySPOL(50 ether);

        MockValidatorShare(testValidatorShare1).addReward(liquidRewards);

        uint256 dPOLBalanceBefore = controller.totaldPOLBalance();
        uint256 feedPOLBalanceBefore = controller.feedPOLBalance();

        controller.buySPOL(stakeAmount);

        assertEq(controller.totaldPOLBalance(), dPOLBalanceBefore + stakeAmount + liquidRewards);
        assertEq(controller.feedPOLBalance(), (feedPOLBalanceBefore + (liquidRewards * controller.rewardFee() / 1000)));
    }

    function test_buySharesFromValidatorBug_LiquidRewardsIncludedInAmountDeposited_twoVal() public {
        uint256 stakeAmount = 500 ether;
        uint256 liquidRewards = 0.01 ether;

        controller.buySPOL(50 ether);

        MockValidatorShare(testValidatorShare1).addReward(liquidRewards);
        MockValidatorShare(testValidatorShare2).addReward(liquidRewards);

        uint256 dPOLBalanceBefore = controller.totaldPOLBalance();
        uint256 feedPOLBalanceBefore = controller.feedPOLBalance();

        controller.buySPOL(stakeAmount);

        assertEq(controller.totaldPOLBalance(), dPOLBalanceBefore + stakeAmount + 2 * liquidRewards);
        assertEq(
            controller.feedPOLBalance(), (feedPOLBalanceBefore + (liquidRewards * 2 * controller.rewardFee() / 1000))
        );
    }

    ////////////////////////////////////////
    ///  Buy with dPOL Tests             ///
    ////////////////////////////////////////

    function test_buySPOLWithDPOL_externalVal_totalstake_no_split() public {
        uint256 amount = 50e18;

        MockValidatorShare(testValidatorShare3).buyVoucherPOL(amount, 0);
        controller.buySPOL(amount * 2);

        // Now, use that dPOL to buy more sPOL
        controller.buySPOLWithDPOL(amount / 2, VALIDATOR_3);

        uint256 totalStakedAmount = amount * 2 + (amount / 2);

        assertEq(sPOLToken.balanceOf(address(this)), totalStakedAmount, "Balance should be 2.5 amount");
        assertEq(controller.totaldPOLBalance(), totalStakedAmount, "Total dPOL balance should be 2.5 amount");
        assertEq(controller.totalsPOLBalance(), totalStakedAmount, "Total sPOL balance should be 2.5 amount");
        (,,,, uint256 dPOLTotalStakeVal1) = controller.validators(VALIDATOR_1);
        (,,,, uint256 dPOLTotalStakeVal2) = controller.validators(VALIDATOR_2);
        assertEq(
            dPOLTotalStakeVal1 + dPOLTotalStakeVal2,
            totalStakedAmount,
            "dPOL total stake val1 + val2 should be 2.5 amount"
        );
        assertEq(dPOLTotalStakeVal1, amount + amount / 2, "val1 dPOL total stake should be first stake plus dPOL stake");
        assertEq(dPOLTotalStakeVal2, amount, "val2 dPOL total stake should be first stake");
        assertEq(
            MockValidatorShare(testValidatorShare3).balanceOf(address(this)),
            amount / 2,
            "Validator 3 user balance should be half amount"
        );
        assertEq(
            MockValidatorShare(testValidatorShare3).balanceOf(address(controller)),
            0,
            "Validator 1 controller balance should be 0"
        );
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount + amount / 2,
            "Validator 1 controller balance should be half amount plus amount"
        );

        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount,
            "Validator 2 controller balance should be amount"
        );
    }

    function test_buySPOLWithDPOL_externalVal_totalstake_split() public {
        uint256 amount = 50e18;
        uint256 largeAmount = 500e18;

        MockValidatorShare(testValidatorShare3).buyVoucherPOL(largeAmount, 0);
        controller.buySPOL(amount * 2);

        // Now, use that dPOL to buy more sPOL
        controller.buySPOLWithDPOL(largeAmount, VALIDATOR_3);

        uint256 totalStakedAmount = amount * 2 + largeAmount;

        assertEq(sPOLToken.balanceOf(address(this)), totalStakedAmount, "Balance should be 2 amount + largeAmount");
        assertEq(
            controller.totaldPOLBalance(), totalStakedAmount, "Total dPOL balance should be 2 amount + largeAmount"
        );
        assertEq(
            controller.totalsPOLBalance(), totalStakedAmount, "Total sPOL balance should be 2 amount + largeAmount"
        );
        (,,,, uint256 dPOLTotalStakeVal1) = controller.validators(VALIDATOR_1);
        (,,,, uint256 dPOLTotalStakeVal2) = controller.validators(VALIDATOR_2);
        assertEq(
            dPOLTotalStakeVal1 + dPOLTotalStakeVal2,
            totalStakedAmount,
            "dPOL total stake val1 + val2 should be 2 amount + largeAmount"
        );
        assertEq(
            dPOLTotalStakeVal1,
            amount + largeAmount / 2,
            "val1 dPOL total stake should be first stake plus half dPOL stake"
        );
        assertEq(
            dPOLTotalStakeVal2,
            amount + largeAmount / 2,
            "val2 dPOL total stake should be first stake plus half dPOL stake"
        );
        assertEq(MockValidatorShare(testValidatorShare3).balanceOf(address(this)), 0, "Validator 3 balance should be 0");
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount + largeAmount / 2,
            "Validator 1 controller balance should be half largeAmount plus amount"
        );
        assertEq(
            MockValidatorShare(testValidatorShare3).balanceOf(address(controller)), 0, "Validator 3 balance should be 0"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount + largeAmount / 2,
            "Validator 2 controller balance should be amount plus half largeAmount"
        );
    }

    function test_buySPOLWithDPOL_internalVal_totalstake_no_split() public {
        uint256 amount = 50e18;

        MockValidatorShare(testValidatorShare2).buyVoucherPOL(amount, 0);
        controller.buySPOL(amount * 2);

        // Now, use that dPOL to buy more sPOL
        controller.buySPOLWithDPOL(amount / 2, VALIDATOR_2);

        uint256 totalStakedAmount = amount * 2 + (amount / 2);

        assertEq(sPOLToken.balanceOf(address(this)), totalStakedAmount, "Balance should be 2.5 amount");
        assertEq(controller.totaldPOLBalance(), totalStakedAmount, "Total dPOL balance should be 2.5 amount");
        assertEq(controller.totalsPOLBalance(), totalStakedAmount, "Total sPOL balance should be 2.5 amount");
        (,,,, uint256 dPOLTotalStakeVal1) = controller.validators(VALIDATOR_1);
        (,,,, uint256 dPOLTotalStakeVal2) = controller.validators(VALIDATOR_2);
        assertEq(
            dPOLTotalStakeVal1 + dPOLTotalStakeVal2,
            totalStakedAmount,
            "dPOL total stake val1 + val2 should be 2.5 amount"
        );
        assertEq(dPOLTotalStakeVal1, amount, "val1 dPOL total stake should be first stake");
        assertEq(dPOLTotalStakeVal2, amount + amount / 2, "val2 dPOL total stake should be first stake plus dPOL stake");
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(this)),
            amount / 2,
            "Validator 2 user balance should be half amount"
        );
        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount,
            "Validator 1 controller balance should be half amount "
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount + amount / 2,
            "Validator 2 controller balance should be amount plus half amount"
        );
    }

    function test_buySPOLWithDPOL_internalVal_totalstake_split() public {
        uint256 amount = 50e18;
        uint256 largeAmount = 500e18;

        MockValidatorShare(testValidatorShare2).buyVoucherPOL(largeAmount, 0);
        controller.buySPOL(amount * 2);

        // Now, use that dPOL to buy more sPOL
        controller.buySPOLWithDPOL(largeAmount, VALIDATOR_2);

        uint256 totalStakedAmount = amount * 2 + largeAmount;

        assertEq(sPOLToken.balanceOf(address(this)), totalStakedAmount, "Balance should be 2 amount + largeAmount");
        assertEq(
            controller.totaldPOLBalance(), totalStakedAmount, "Total dPOL balance should be 2 amount + largeAmount"
        );
        assertEq(
            controller.totalsPOLBalance(), totalStakedAmount, "Total sPOL balance should be 2 amount + largeAmount"
        );
        (,,,, uint256 dPOLTotalStakeVal1) = controller.validators(VALIDATOR_1);
        (,,,, uint256 dPOLTotalStakeVal2) = controller.validators(VALIDATOR_2);

        assertEq(
            dPOLTotalStakeVal1 + dPOLTotalStakeVal2,
            totalStakedAmount,
            "dPOL total stake val1 + val2 should be 2 amount + largeAmount"
        );
        assertEq(
            dPOLTotalStakeVal1,
            amount + largeAmount / 2,
            "val1 dPOL total stake should be first stake plus half dPOL stake"
        );
        assertEq(
            dPOLTotalStakeVal2,
            amount + largeAmount / 2,
            "val2 dPOL total stake should be first stake plus half dPOL stake"
        );
        assertEq(MockValidatorShare(testValidatorShare2).balanceOf(address(this)), 0, "Validator 2 balance should be 0");

        assertEq(
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            amount + largeAmount / 2,
            "Validator 1 controller balance should be half largeAmount plus amount"
        );
        assertEq(
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            amount + largeAmount / 2,
            "Validator 2 controller balance should be half largeAmount plus amount"
        );
    }

    ////////////////////////////////////////////
    ///  Generic Test Functions              ///
    ////////////////////////////////////////////

    function matchBalanceWithTotalStake(uint256 _totalExpectedStake) internal view {
        (,,,, uint256 dPOLTotalStakeVal1) = controller.validators(VALIDATOR_1);
        (,,,, uint256 dPOLTotalStakeVal2) = controller.validators(VALIDATOR_2);

        assertEq(
            dPOLTotalStakeVal1,
            MockValidatorShare(testValidatorShare1).balanceOf(address(controller)),
            "dPOL total stake should be balance of val1"
        );
        assertEq(
            dPOLTotalStakeVal2,
            MockValidatorShare(testValidatorShare2).balanceOf(address(controller)),
            "dPOL total stake should be balance of val2"
        );
        assertEq(
            dPOLTotalStakeVal1 + dPOLTotalStakeVal2,
            controller.totaldPOLBalance(),
            "dPOL total stake val1 + val2 should be total dPOL balance"
        );
        assertEq(
            dPOLTotalStakeVal1 + dPOLTotalStakeVal2,
            _totalExpectedStake,
            "dPOL total stake val1 + val2 should be expected total stake"
        );
    }

    ////////////////////////////////////////
    ///  Helper Functions                ///
    ////////////////////////////////////////

    function _createPermitSignature(
        ERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint256 pk
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        return vm.sign(pk, digest);
    }
}

