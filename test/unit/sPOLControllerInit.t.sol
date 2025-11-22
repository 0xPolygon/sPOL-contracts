// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sPOLController.sol";
import "../../src/sPOL.sol";
import "../../script/Deploy.s.sol";
import "../../src/interfaces/IStakeManager.sol";
import "../../src/interfaces/IValidatorShare.sol";
import "../../src/interfaces/IPolygonMigration.sol";

contract sPOLControllerInitTest is Test {
    sPOLController controller; // This will be the proxy
    sPOLController controllerImpl; // Implementation for direct testing

    // Test addresses
    address testAdmin = makeAddr("testAdmin");
    address testFeeReceiver = makeAddr("testFeeReceiver");
    address testPolToken = makeAddr("testPolToken");
    address testMaticToken = makeAddr("testMaticToken");
    address testPolygonMigration = makeAddr("testPolygonMigration");
    address testStakeManager = makeAddr("testStakeManager");
    address testSPOLToken = makeAddr("testSPOLToken");
    uint8 testMaxDivergence = 20;

    function setUp() public {
        vm.etch(testPolToken, type(DummyImpl).runtimeCode);
        controllerImpl =
            new sPOLController(testPolToken, testMaticToken, testPolygonMigration, testSPOLToken, testStakeManager);
    }

    function test_Constructor_SetsImmutableVariables() public {
        // Deploy a new implementation to test constructor directly
        sPOLController testController =
            new sPOLController(testPolToken, testMaticToken, testPolygonMigration, testSPOLToken, testStakeManager);

        // Verify immutable variables are set correctly
        assertEq(address(testController.polToken()), testPolToken, "POL token not set correctly");
        assertEq(address(testController.maticToken()), testMaticToken, "MATIC token not set correctly");
        assertEq(address(testController.polygonMigration()), testPolygonMigration, "PolygonMigration not set correctly");
        assertEq(address(testController.sPOLToken()), testSPOLToken, "sPOL token not set correctly");
        assertEq(address(testController.stakeManager()), testStakeManager, "StakeManager not set correctly");
    }

    function test_Initialize_SetsAllParameters() public {
        uint16 testRewardFee = 150; // 15%

        // Initialize the contract
        bytes memory data = abi.encodeWithSelector(
            sPOLController.initialize.selector, testRewardFee, testFeeReceiver, testMaxDivergence, testAdmin
        );

        controller =
            sPOLController(address(new TransparentUpgradeableProxy(address(controllerImpl), address(this), data)));
        // Verify all parameters are set correctly
        assertEq(controller.rewardFee(), testRewardFee, "Reward fee not set correctly");
        assertEq(controller.feeReceiver(), testFeeReceiver, "Fee receiver not set correctly");
        assertEq(controller.maxDivergence(), testMaxDivergence, "Max divergence not set correctly");
        assertEq(controller.authority(), testAdmin, "Admin not set correctly");
    }

    function test_Initialize_WithZeroFee() public {
        // Initialize the contract
        bytes memory data = abi.encodeWithSelector(
            sPOLController.initialize.selector, 0, testFeeReceiver, testMaxDivergence, testAdmin
        );

        controller =
            sPOLController(address(new TransparentUpgradeableProxy(address(controllerImpl), address(this), data)));

        assertEq(controller.rewardFee(), 0, "Zero fee should be allowed");
    }

    function test_Initialize_WithMaxFee() public {
        // Initialize the contract
        bytes memory data = abi.encodeWithSelector(
            sPOLController.initialize.selector, 1001, testFeeReceiver, testMaxDivergence, testAdmin
        );

        vm.expectRevert("FEE_TOO_LARGE");
        controller =
            sPOLController(address(new TransparentUpgradeableProxy(address(controllerImpl), address(this), data)));
    }

    function test_Initialize_CanBeCalledOnlyOnce() public {
        bytes memory data = abi.encodeWithSelector(
            sPOLController.initialize.selector, 0, testFeeReceiver, testMaxDivergence, testAdmin
        );
        controller =
            sPOLController(address(new TransparentUpgradeableProxy(address(controllerImpl), address(this), data)));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        controller.initialize(0, testFeeReceiver, 10, testAdmin);
    }

    function test_ConstantsAreSetCorrectly() public {
        bytes memory data = abi.encodeWithSelector(
            sPOLController.initialize.selector, 0, testFeeReceiver, testMaxDivergence, testAdmin
        );
        controller =
            sPOLController(address(new TransparentUpgradeableProxy(address(controllerImpl), address(this), data)));

        // Test that MAX_FEE constant is correct
        assertEq(controller.MAX_FEE(), 1000, "MAX_FEE should be 1000");
    }
}
