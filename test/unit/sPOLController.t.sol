// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {sPOL} from "../../src/sPOL.sol";
import {sPOLController} from "../../src/sPOLController.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPolygonMigration} from "../../src/interfaces/IPolygonMigration.sol";
import {StakeManager as IStakeManager} from "../../src/interfaces/IStakeManager.sol";
import {ValidatorShare as IValidatorShare} from "../../src/interfaces/IValidatorShare.sol";

contract sPOLControllerTest is Test, Deploy {
    sPOL public sPOLToken;
    sPOLController public controller;

    address public testAdmin;
    address public testFeeReceiver;
    address public newFeeReceiver;
    address public nonAdmin;
    address public user;

    uint8 public constant INITIAL_REWARD_FEE = 100; // 10%
    uint8 public constant MAX_DIVERGENCE = 10; // 10%
    uint16 public constant MAX_FEE = 1000; // 100%

    event FeeReceiverChanged(address indexed oldReceiver, address indexed newReceiver);
    event RewardFeeChanged(uint8 oldFee, uint8 newFee);
    event FeeTaken(address indexed receiver, uint256 amount);

    function setUp() public {
        // Create test addresses
        testAdmin = makeAddr("testAdmin");
        testFeeReceiver = makeAddr("testFeeReceiver");
        newFeeReceiver = makeAddr("newFeeReceiver");
        nonAdmin = makeAddr("nonAdmin");
        user = makeAddr("user");

        // Deploy using the existing deploy script but with custom config
        setCustomConfig(
            makeAddr("polToken"),
            makeAddr("maticToken"),
            makeAddr("polygonMigration"),
            makeAddr("stakeManager"),
            testAdmin,
            testFeeReceiver,
            INITIAL_REWARD_FEE,
            MAX_DIVERGENCE
        );
        _deploy(address(this));

        // Get deployed contract instances
        sPOLToken = sPOL(address(sPOLProxy));
        controller = sPOLController(address(sPOLControllerProxy));

        // Verify initial state
        assertEq(controller.admin(), testAdmin);
        assertEq(controller.feeReceiver(), testFeeReceiver);
        assertEq(controller.rewardFee(), INITIAL_REWARD_FEE);
    }

    ///////////////////////////////////
    ///       changeFeeReceiver     ///
    ///////////////////////////////////

    function test_changeFeeReceiver_Success() public {
        vm.prank(testAdmin);
        controller.changeFeeReceiver(newFeeReceiver);

        assertEq(controller.feeReceiver(), newFeeReceiver);
    }

    function test_changeFeeReceiver_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert("ONLY_ADMIN");
        controller.changeFeeReceiver(newFeeReceiver);
    }

    function test_changeFeeReceiver_ZeroAddress() public {
        vm.prank(testAdmin);

        vm.expectRevert("ZERO_ADDRESS");
        controller.changeFeeReceiver(address(0));
    }

    ///////////////////////////////////
    ///       changeRewardFee       ///
    ///////////////////////////////////

    function test_changeRewardFee_Success() public {
        uint16 newFee = 200; // 20%

        vm.prank(testAdmin);
        controller.changeRewardFee(newFee);

        assertEq(controller.rewardFee(), newFee);
    }

    function test_changeRewardFee_OnlyAdmin() public {
        uint16 newFee = 200;

        vm.prank(nonAdmin);
        vm.expectRevert("ONLY_ADMIN");
        controller.changeRewardFee(newFee);
    }

    function test_changeRewardFee_MaxFee() public {
        vm.prank(testAdmin);
        controller.changeRewardFee(MAX_FEE);
        assertEq(controller.rewardFee(), MAX_FEE);
    }

    function test_changeRewardFee_ExceedsMaxFee() public {
        vm.expectRevert("FEE_TOO_LARGE");
        vm.prank(testAdmin);
        controller.changeRewardFee(MAX_FEE + 1);
    }

    function test_changeRewardFee_ZeroFee() public {
        vm.prank(testAdmin);
        controller.changeRewardFee(0);

        assertEq(controller.rewardFee(), 0);
    }

    ///////////////////////////////////
    ///           takeFee           ///
    ///////////////////////////////////

    function test_takeFee_Success() public {
        uint256 feePOLBalance = 1000e18;
        uint256 dPOLBalance = 10000e18;
        uint256 totalsPOLSupply = 50e18;

        vm.store(address(controller), bytes32(uint256(7)), bytes32(feePOLBalance));
        vm.store(address(controller), bytes32(uint256(5)), bytes32(dPOLBalance));
        vm.mockCall(address(sPOLToken), abi.encodeWithSelector(ERC20.totalSupply.selector), abi.encode(totalsPOLSupply));

        uint256 expectedSPOLMint = feePOLBalance * totalsPOLSupply / (dPOLBalance - feePOLBalance);

        vm.expectEmit(true, true, true, true, address(sPOLToken));
        emit IERC20.Transfer(address(0), testFeeReceiver, expectedSPOLMint);

        vm.prank(testAdmin);
        controller.takeFee();

        assertEq(controller.feedPOLBalance(), 0);
        assertEq(sPOLToken.balanceOf(testFeeReceiver), expectedSPOLMint);
    }

    function test_takeFee_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert("ONLY_ADMIN");
        controller.takeFee();
    }

    function test_takeFee_ZeroFeeBalance() public {
        assertEq(controller.feedPOLBalance(), 0);

        vm.prank(testAdmin);
        controller.takeFee();

        assertEq(controller.feedPOLBalance(), 0);
    }

    ///////////////////////////////////
    /// Validator Info Reload Tests ///
    ///////////////////////////////////

    function test_reloadAllActiveValidatorInfo_Success() public {
        _addTestValidators();

        uint256 validator1Balance = 1000e18;
        uint256 validator2Balance = 2000e18;

        vm.mockCall(
            makeAddr("testValidatorShare1"),
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator1Balance)
        );
        vm.mockCall(
            makeAddr("testValidatorShare2"),
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator2Balance)
        );

        vm.prank(testAdmin);
        controller.reloadAllActiveValidatorInfo();

        uint16 validator1Id = 35;
        uint16 validator2Id = 120;
        (,,,, uint256 validator1TotalStaked) = controller.validators(validator1Id);
        (,,,, uint256 validator2TotalStaked) = controller.validators(validator2Id);

        assertEq(validator1TotalStaked, validator1Balance);
        assertEq(validator2TotalStaked, validator2Balance);
        assertTrue(controller.totaldPOLBalance() == validator1Balance + validator2Balance);
    }

    function test_reloadActiveValidatorInfo_WithFrozenValidator() public {
        _addTestValidators();

        uint16 validator1Id = 35;
        uint16 validator2Id = 120;

        vm.prank(testAdmin);
        controller.freezeValidator(validator2Id);

        // Set up balances
        uint256 validator1Balance = 1000e18;
        uint256 validator2Balance = 500e18;

        address testValidatorShare1 = makeAddr("testValidatorShare1");
        address testValidatorShare2 = makeAddr("testValidatorShare2");

        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator1Balance)
        );
        vm.mockCall(
            testValidatorShare2,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator2Balance)
        );

        vm.prank(testAdmin);
        controller.reloadAllActiveValidatorInfo();

        (,,,, uint256 validator1TotalStaked) = controller.validators(validator1Id);
        (,,,, uint256 validator2TotalStaked) = controller.validators(validator2Id);

        assertEq(controller.totaldPOLBalance(), validator1Balance);
        assertEq(validator1TotalStaked, validator1Balance);
        assertEq(validator2TotalStaked, 0);
    }

    function test_reloadAllActiveValidatorInfo_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert("ONLY_ADMIN");
        controller.reloadAllActiveValidatorInfo();
    }

    function test_reloadAllValidatorInfo_Success() public {
        _addTestValidators();

        uint256 validator1Balance = 1500e18;
        uint256 validator2Balance = 2500e18;

        address testValidatorShare1 = makeAddr("testValidatorShare1");
        address testValidatorShare2 = makeAddr("testValidatorShare2");

        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator1Balance)
        );
        vm.mockCall(
            testValidatorShare2,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator2Balance)
        );

        vm.prank(testAdmin);
        controller.reloadAllValidatorInfo();

        uint16 validator1Id = 35;
        uint16 validator2Id = 120;
        (,,,, uint256 validator1TotalStaked) = controller.validators(validator1Id);
        (,,,, uint256 validator2TotalStaked) = controller.validators(validator2Id);

        assertEq(controller.totaldPOLBalance(), validator1Balance + validator2Balance);
        assertEq(validator1TotalStaked, validator1Balance);
        assertEq(validator2TotalStaked, validator2Balance);
    }

    function test_reloadAllValidatorInfo_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert("ONLY_ADMIN");
        controller.reloadAllValidatorInfo();
    }

    function test_reloadAllValidatorInfo_WithFrozenValidator() public {
        _addTestValidators();

        uint16 validator1Id = 35;
        uint16 validator2Id = 120;

        vm.prank(testAdmin);
        controller.freezeValidator(validator2Id);

        // Set up balances
        uint256 validator1Balance = 1000e18;
        uint256 validator2Balance = 500e18;

        address testValidatorShare1 = makeAddr("testValidatorShare1");
        address testValidatorShare2 = makeAddr("testValidatorShare2");

        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator1Balance)
        );
        vm.mockCall(
            testValidatorShare2,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(validator2Balance)
        );

        vm.prank(testAdmin);
        controller.reloadAllValidatorInfo();

        (,,,, uint256 validator1TotalStaked) = controller.validators(validator1Id);
        (,,,, uint256 validator2TotalStaked) = controller.validators(validator2Id);

        assertEq(controller.totaldPOLBalance(), validator1Balance + validator2Balance);
        assertEq(validator1TotalStaked, validator1Balance);
        assertEq(validator2TotalStaked, validator2Balance);
    }

    ///////////////////////////////////
    ///      Helper Functions       ///
    ///////////////////////////////////

    function _addTestValidators() internal {
        uint16 validator1Id = 35;
        uint16 validator2Id = 120;

        address testStakeManager = address(stakeManager);
        address testValidatorShare1 = makeAddr("testValidatorShare1");
        address testValidatorShare2 = makeAddr("testValidatorShare2");

        // Mock stakeManager calls for validator 1
        vm.mockCall(
            testStakeManager, abi.encodeWithSelector(IStakeManager.isValidator.selector, validator1Id), abi.encode(true)
        );
        vm.mockCall(
            testStakeManager,
            abi.encodeWithSelector(IStakeManager.getValidatorContract.selector, validator1Id),
            abi.encode(testValidatorShare1)
        );

        // Mock stakeManager calls for validator 2
        vm.mockCall(
            testStakeManager, abi.encodeWithSelector(IStakeManager.isValidator.selector, validator2Id), abi.encode(true)
        );
        vm.mockCall(
            testStakeManager,
            abi.encodeWithSelector(IStakeManager.getValidatorContract.selector, validator2Id),
            abi.encode(testValidatorShare2)
        );

        // Mock validator share default responses
        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(0)
        );
        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.getLiquidRewards.selector, address(controller)),
            abi.encode(0)
        );

        vm.mockCall(
            testValidatorShare2,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(0)
        );
        vm.mockCall(
            testValidatorShare2,
            abi.encodeWithSelector(IValidatorShare.getLiquidRewards.selector, address(controller)),
            abi.encode(0)
        );

        // Add validators
        vm.prank(testAdmin);
        controller.addValidator(validator1Id);

        vm.prank(testAdmin);
        controller.addValidator(validator2Id);
    }
}
