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

    function test_buySPOLSingle_() public {
        // buying a whole POL fill up both validators. This prevents triggering the Overfunded error
        controller.buySPOL(1e18);
        controller.buySPOL(1, VALIDATOR_1);

        assertEq(controller.totaldPOLBalance(), 1e18 + 1, "Total dPOL balance should be 1");
        assertEq(controller.totalsPOLBalance(), 1e18 + 1, "Total POL balance should be 1");
        assertEq(sPOLToken.balanceOf(address(this)), 1e18 + 1, "Balance should be 1");
    }

    function test_buySPOLMulti() public {
        controller.buySPOL(1e18);

        assertEq(sPOLToken.balanceOf(address(this)), 1e18, "Balance should be 1");
        // should have selected #2. Both have 0 balance, but as it was addded last
        assertEq(controller.totaldPOLBalance(), 1e18, "Total dPOL balance should be 1");
        assertEq(controller.totalsPOLBalance(), 1e18, "Total POL balance should be 1");
    }

    function test_buySPOLMulti_Consecutive() public {
        controller.buySPOL(1e18);
        controller.buySPOL(1e18);

        assertEq(controller.feedPOLBalance(), 0, "Feed POL balance should be 0");

        assertEq(controller.totaldPOLBalance(), 2e18, "Total dPOL balance should be 2");
        assertEq(controller.totalsPOLBalance(), 2e18, "Total POL balance should be 2");
        assertEq(sPOLToken.balanceOf(address(this)), 2e18, "Balance should be 2");
    }

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

    ////////////////////////////////////////
    ///  Buy Tests                       ///
    ////////////////////////////////////////

    function test_sellSPOLMulti() public {
        uint256 amount = 1e18;
        controller.buySPOL(amount);
        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be amount");

        controller.sellSPOL(amount);

        assertEq(controller.totaldPOLBalance(), 0, "Total dPOL balance should be 0");
        assertEq(controller.totalsPOLBalance(), 0, "Total sPOL balance should be 0");
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
    }

    function test_sellSPOL_withdrawNonce_no_zero() public {
        assertEq(controller.globalWithdrawNonce(), 1, "Global withdraw nonce should be 0");
        uint256 amount = 1e18;
        controller.buySPOL(amount);
        assertEq(controller.totalsPOLBalance(), amount, "Total sPOL balance should be amount");

        controller.sellSPOL(amount);
        assertEq(1, controller.userNonces(address(this), 0), "First nonce should be 1");
    }

    function test_sellSPOL_withdrawNonce_increases() public {
        assertEq(controller.globalWithdrawNonce(), 1, "Global withdraw nonce should be 0");
        uint256 amount = 1e18;
        controller.buySPOL(amount * 2);
        assertEq(controller.totalsPOLBalance(), amount * 2, "Total sPOL balance should be amount");

        controller.sellSPOL(amount);
        assertEq(1, controller.userNonces(address(this), 0), "First nonce should be 1");
        controller.sellSPOL(amount);
        assertEq(2, controller.userNonces(address(this), 1), "Second nonce should be 2");
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
            amount,
            "Validator 2 controller balance should be amount"
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

        console.log(MockValidatorShare(testValidatorShare1).balanceOf(address(controller)));
        console.log(MockValidatorShare(testValidatorShare2).balanceOf(address(controller)));


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
}

