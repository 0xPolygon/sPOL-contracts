// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sPOLController.sol";
import "../../script/Deploy.s.sol";
import "../../src/interfaces/IStakeManager.sol";
import "../../src/interfaces/IValidatorShare.sol";

contract sPOLControllerVldMgnTest is Test, Deploy {
    sPOLController controller;

    // Test addresses
    address testAdmin;
    address nonAdmin = makeAddr("nonAdmin");
    address testStakeManager = makeAddr("testStakeManager");
    address testValidatorShare1 = makeAddr("testValidatorShare1");
    address testValidatorShare2 = makeAddr("testValidatorShare2");

    // Test validator IDs
    uint16 constant VALIDATOR_1 = 35;
    uint16 constant VALIDATOR_2 = 120;

    // Events
    event ValidatorAdded(uint16 validatorId);
    event ValidatorRemoved(uint16 validatorId);
    event ValidatorFrozen(uint16 validatorId);
    event ValidatorUnfrozen(uint16 validatorId);
    event ValidatorTargetShareChanged(uint16 validatorId, uint8 newTargetShare);

    function setUp() public {
        // Set mock values
        loadMockConfig();
        // Custom config
        stakeManager = testStakeManager;
        // Deploy contracts
        deployContractsL1(address(this));

        // Get config values
        testAdmin = admin;

        controller = sPOLController(address(sPOLControllerProxy));

        // Setup default mock calls
        _setupDefaultMocks();
    }

    function _setupDefaultMocks() internal {
        // Mock stakeManager.isValidator() calls
        vm.mockCall(
            testStakeManager, abi.encodeWithSelector(IStakeManager.isValidator.selector, VALIDATOR_1), abi.encode(true)
        );
        vm.mockCall(
            testStakeManager, abi.encodeWithSelector(IStakeManager.isValidator.selector, VALIDATOR_2), abi.encode(true)
        );

        // Mock stakeManager.getValidatorContract() calls
        vm.mockCall(
            testStakeManager,
            abi.encodeWithSelector(IStakeManager.getValidatorContract.selector, VALIDATOR_1),
            abi.encode(testValidatorShare1)
        );
        vm.mockCall(
            testStakeManager,
            abi.encodeWithSelector(IStakeManager.getValidatorContract.selector, VALIDATOR_2),
            abi.encode(testValidatorShare2)
        );

        // Mock validator share default responses (0 balance, 0 rewards)
        _mockValidatorShareDefaults(testValidatorShare1);
        _mockValidatorShareDefaults(testValidatorShare2);
    }

    function _mockValidatorShareDefaults(address validatorShare) internal {
        vm.mockCall(
            validatorShare,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(0)
        );
        vm.mockCall(
            validatorShare,
            abi.encodeWithSelector(IValidatorShare.getLiquidRewards.selector, address(controller)),
            abi.encode(0)
        );
    }

    ///////////////////////////////
    ///   Add Validator Tests   ///
    ///////////////////////////////

    function test_AddValidator_Success() public {
        vm.prank(testAdmin);
        vm.expectEmit(true, true, true, true, address(controller));
        emit ValidatorAdded(VALIDATOR_1);

        controller.addValidator(VALIDATOR_1);

        // Verify validator was added correctly
        (
            sPOLController.ValidatorStatus status,
            uint8 depositShare,
            uint16 index,
            IValidatorShare validatorContract,
            uint256 totalStaked
        ) = controller.validators(VALIDATOR_1);

        assertEq(uint8(status), uint8(sPOLController.ValidatorStatus.ACTIVE), "Status should be ACTIVE");
        assertEq(depositShare, 0, "Deposit share should be 0");
        assertEq(index, VALIDATOR_1, "Index should match validator ID");
        assertEq(address(validatorContract), testValidatorShare1, "Validator contract should match");
        assertEq(totalStaked, 0, "Total staked should be 0");

        // Check validator was added to lists
        assertEq(controller.validatorList(0), VALIDATOR_1, "Validator should be in validatorList");
        assertEq(controller.activeValidators(0), VALIDATOR_1, "Validator should be in activeValidators");
    }

    function test_AddValidator_RevertsForNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        controller.addValidator(VALIDATOR_1);
    }

    function test_AddValidator_RevertsForInactiveValidator() public {
        // Mock the validator as inactive
        vm.mockCall(
            testStakeManager, abi.encodeWithSelector(IStakeManager.isValidator.selector, VALIDATOR_1), abi.encode(false)
        );

        vm.prank(testAdmin);
        vm.expectRevert("NOT_ACTIVE_VALIDATOR");
        controller.addValidator(VALIDATOR_1);
    }

    function test_AddValidator_RevertsForZeroContract() public {
        // Mock validator contract as zero address
        vm.mockCall(
            testStakeManager,
            abi.encodeWithSelector(IStakeManager.getValidatorContract.selector, VALIDATOR_1),
            abi.encode(address(0))
        );

        vm.prank(testAdmin);
        vm.expectRevert("NO_DELEGATION");
        controller.addValidator(VALIDATOR_1);
    }

    ///////////////////////////////
    ///  Remove Validator Tests ///
    ///////////////////////////////

    function test_RemoveValidator_Success() public {
        // First add a validator
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        vm.prank(testAdmin);
        vm.expectEmit(true, true, true, true, address(controller));
        emit ValidatorRemoved(VALIDATOR_1);

        controller.removeValidator(VALIDATOR_1);

        // Verify validator status changed to DEACTIVATED
        (sPOLController.ValidatorStatus status, uint8 depositShare,,,) = controller.validators(VALIDATOR_1);
        assertEq(uint8(status), uint8(sPOLController.ValidatorStatus.DEACTIVATED), "Status should be DEACTIVATED");
        assertEq(depositShare, 0, "Deposit share should be reset to 0");
        assertEq(controller.validatorList(0), VALIDATOR_1, "validatorList should still contain the removed validator");
        // Verify validator removed from activeValidators
        vm.expectRevert(bytes(""));
        controller.activeValidators(0);
    }

    function test_RemoveValidator_RevertsForNonAdmin() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        controller.removeValidator(VALIDATOR_1);
    }

    function test_RemoveValidator_RevertsWhenSharesPending() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        // Mock validator share balance as non-zero
        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(controller)),
            abi.encode(100)
        );

        vm.prank(testAdmin);
        vm.expectRevert("SHARES_PENDING");
        controller.removeValidator(VALIDATOR_1);
    }

    function test_RemoveValidator_RevertsWhenRewardsPending() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        // Mock validator liquid rewards as non-zero
        vm.mockCall(
            testValidatorShare1,
            abi.encodeWithSelector(IValidatorShare.getLiquidRewards.selector, address(controller)),
            abi.encode(50)
        );

        vm.prank(testAdmin);
        vm.expectRevert("REWARDS_PENDING");
        controller.removeValidator(VALIDATOR_1);
    }

    ///////////////////////////////
    ///  Freeze Validator Tests ///
    ///////////////////////////////

    function test_FreezeValidator_Success() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        vm.prank(testAdmin);
        vm.expectEmit(true, true, true, true, address(controller));
        emit ValidatorFrozen(VALIDATOR_1);

        controller.freezeValidator(VALIDATOR_1);

        // Verify validator status changed to FROZEN
        (sPOLController.ValidatorStatus status,,,,) = controller.validators(VALIDATOR_1);
        assertEq(uint8(status), uint8(sPOLController.ValidatorStatus.FROZEN), "Status should be FROZEN");
    }

    function test_FreezeValidator_RevertsForNonAdmin() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        controller.freezeValidator(VALIDATOR_1);
    }

    function test_FreezeValidator_RevertsWhenShareNotZero() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        // Set target share for the validator
        uint16[] memory validatorIds = new uint16[](1);
        uint8[] memory targetShares = new uint8[](1);
        validatorIds[0] = VALIDATOR_1;
        targetShares[0] = 100;

        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIds, targetShares);

        // Now try to freeze - should revert because share is not zero
        vm.prank(testAdmin);
        vm.expectRevert("SHARE_NOT_ZERO");
        controller.freezeValidator(VALIDATOR_1);
    }

    ///////////////////////////////
    /// Unfreeze Validator Tests///
    ///////////////////////////////

    function test_UnfreezeValidator_Success() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        // First freeze the validator
        vm.prank(testAdmin);
        controller.freezeValidator(VALIDATOR_1);

        // Now unfreeze it
        vm.prank(testAdmin);
        vm.expectEmit(true, true, true, true, address(controller));
        emit ValidatorUnfrozen(VALIDATOR_1);

        controller.unfreezeValidator(VALIDATOR_1);

        // Verify validator status changed back to ACTIVE
        (sPOLController.ValidatorStatus status,,,,) = controller.validators(VALIDATOR_1);
        assertEq(uint8(status), uint8(sPOLController.ValidatorStatus.ACTIVE), "Status should be ACTIVE");
    }

    function test_UnfreezeValidator_RevertsForNonAdmin() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);
        vm.prank(testAdmin);
        controller.freezeValidator(VALIDATOR_1);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        controller.unfreezeValidator(VALIDATOR_1);
    }

    ///////////////////////////////
    /// Target Share Update Tests//
    ///////////////////////////////

    function test_UpdateValidatorTargetShare_Success() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        uint16[] memory validatorIds = new uint16[](1);
        uint8[] memory targetShares = new uint8[](1);
        validatorIds[0] = VALIDATOR_1;
        targetShares[0] = 100;

        vm.prank(testAdmin);
        vm.expectEmit(true, true, true, true, address(controller));
        emit ValidatorTargetShareChanged(VALIDATOR_1, 100);

        controller.updateValidatorTargetShare(validatorIds, targetShares);

        // Verify target share was updated
        (, uint8 depositShare,,,) = controller.validators(VALIDATOR_1);
        assertEq(depositShare, 100, "Deposit share should be updated to 100");
    }

    function test_UpdateValidatorTargetShare_MultipleValidators() public {
        vm.startPrank(testAdmin);
        controller.addValidator(VALIDATOR_1);
        controller.addValidator(VALIDATOR_2);
        vm.stopPrank();

        uint16[] memory validatorIds = new uint16[](2);
        uint8[] memory targetShares = new uint8[](2);
        validatorIds[0] = VALIDATOR_1;
        validatorIds[1] = VALIDATOR_2;
        targetShares[0] = 60;
        targetShares[1] = 40;

        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIds, targetShares);

        // Verify both shares were updated
        (, uint8 depositShare1,,,) = controller.validators(VALIDATOR_1);
        (, uint8 depositShare2,,,) = controller.validators(VALIDATOR_2);
        assertEq(depositShare1, 60, "Validator 1 share should be 60");
        assertEq(depositShare2, 40, "Validator 2 share should be 40");
    }

    function test_UpdateValidatorTargetShare_RevertsForNonAdmin() public {
        vm.prank(testAdmin);
        controller.addValidator(VALIDATOR_1);

        uint16[] memory validatorIds = new uint16[](1);
        uint8[] memory targetShares = new uint8[](1);
        validatorIds[0] = VALIDATOR_1;
        targetShares[0] = 100;

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        controller.updateValidatorTargetShare(validatorIds, targetShares);
    }

    function test_UpdateValidatorTargetShare_RevertsWhenTotalNot100() public {
        vm.startPrank(testAdmin);
        controller.addValidator(VALIDATOR_1);
        controller.addValidator(VALIDATOR_2);
        vm.stopPrank();

        uint16[] memory validatorIds = new uint16[](2);
        uint8[] memory targetShares = new uint8[](2);
        validatorIds[0] = VALIDATOR_1;
        validatorIds[1] = VALIDATOR_2;
        targetShares[0] = 60;
        targetShares[1] = 30; // Total = 90, not 100

        vm.prank(testAdmin);
        vm.expectRevert("TOTAL_NOT_100");
        controller.updateValidatorTargetShare(validatorIds, targetShares);
    }

    ///////////////////////////////
    /// Change Max Divergence Tests
    ///////////////////////////////

    function test_ChangeMaxDivergence_Success() public {
        uint8 newDivergence = 25;

        vm.prank(testAdmin);
        controller.changeMaxDivergence(newDivergence);

        assertEq(controller.maxDivergence(), newDivergence, "Max divergence should be updated");
    }

    function test_ChangeMaxDivergence_RevertsForNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonAdmin));
        controller.changeMaxDivergence(25);
    }
}
