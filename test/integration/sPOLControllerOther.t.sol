// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/Script.sol";
import "../../src/sPOL.sol";
import "../../src/sPOLController.sol";
import "../../script/Deploy.s.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Registry as IRegistry} from "../../src/interfaces/IRegistry.sol";
import {ERC20PredicateBurnOnly as IERC20PredicateBurnOnly} from "../../src/interfaces/IERC20Predicate.sol";
import {WithdrawManager as IWithdrawManager} from "../../src/interfaces/IWithdrawManager.sol";

contract sPOLControllerCleanupTest is Test, Deploy {
    sPOL public sPOLToken;
    sPOLController public controller;
    sPOLMessenger public messenger;
    sPOLChild public child;
    address erc20predicatePortal;

    address nonAdmin;
    uint256 networkL1;
    uint256 networkL2;
    address testAdmin;

    uint16 validator1ID = 91;
    uint16 validator2ID = 122;
    uint16 validatorInactiveID = 67;

    IValidatorShare validator1;
    IValidatorShare validator2;

    address user1 = makeAddr("user1no7702delegation");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    uint256 smallAmount = 1 ether;
    uint256 mediumAmount = 300 ether;
    uint256 mediumAmount2 = 2000 ether;
    uint256 largeAmount = 5000 ether;
    uint256 hugeAmount = 2000000 ether;

    function setUp() public {
        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"));
        // Create test addresses
        nonAdmin = makeAddr("nonAdmin");

        // Set values
        loadConfigFromJson("ethereum-polygon");
        // Custom config

        //setup L1
        vm.selectFork(networkL1);
        // Deploy contracts
        deployContractsL1(address(this));

        // Get deployed contract instances
        sPOLToken = sPOL(address(sPOLProxy));
        controller = sPOLController(address(sPOLControllerProxy));
        messenger = sPOLMessenger(address(sPOLMessengerProxy));
        // Get config values
        testAdmin = admin;
        validator1 = IValidatorShare(IStakeManager(stakeManager).getValidatorContract(validator1ID));
        validator2 = IValidatorShare(IStakeManager(stakeManager).getValidatorContract(validator2ID));

        vm.selectFork(networkL1);

        // set validator1 deposit share to 100%
        vm.prank(testAdmin);
        controller.addValidator(validator1ID);
        uint16[] memory validatorIDs = new uint16[](1);
        validatorIDs[0] = validator1ID;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIDs, shares);
    }

    ///////////////////////////////////
    /// Cleanup Function            ///
    ///////////////////////////////////

    function test_cleanupMaticTokens_maticOnly() public {
        uint256 userAmount = 5e18;

        deal(polTokenL1, user1, userAmount);
        vm.prank(user1);
        ERC20(polTokenL1).approve(address(controller), userAmount);
        vm.prank(user1);
        controller.buySPOL(userAmount);

        uint256 maticAmount = 5e18;
        deal(maticTokenL1, address(controller), maticAmount);
        assertEq(controller.convertSPOLtoPOL(userAmount), userAmount, "user owns all POL equivalent of sPOL");

        vm.prank(testAdmin);
        controller.cleanUpMaticPOL(validator1ID);

        assertEq(ERC20(maticTokenL1).balanceOf(address(controller)), 0);
        assertEq(ERC20(polTokenL1).balanceOf(address(controller)), 0);
        assertEq(validator1.balanceOf(address(controller)), maticAmount + userAmount);
        uint256 fee = (maticAmount * controller.rewardFee()) / 1000;
        assertEq(
            controller.convertSPOLtoPOL(userAmount),
            maticAmount + userAmount - fee,
            "user still owns POL equivalent of sPOL minus fee"
        );
        assertEq(controller.feedPOLBalance(), fee, "total fee balance was applied to entire cleaned amount");
    }

    function test_cleanupMaticTokens_maticAndPOL() public {
        uint256 maticAmount = 5e18;
        uint256 polAmount = 10e18;
        deal(maticTokenL1, address(controller), maticAmount);
        deal(polTokenL1, address(controller), polAmount);

        uint256 userAmount = 5e18;

        deal(polTokenL1, user1, userAmount);
        vm.prank(user1);
        ERC20(polTokenL1).approve(address(controller), userAmount);
        vm.prank(user1);
        controller.buySPOL(userAmount);

        assertEq(controller.convertSPOLtoPOL(userAmount), userAmount, "user owns all POL equivalent of sPOL");

        vm.prank(testAdmin);
        controller.cleanUpMaticPOL(validator1ID);

        assertEq(ERC20(maticTokenL1).balanceOf(address(controller)), 0);
        assertEq(ERC20(polTokenL1).balanceOf(address(controller)), 0);
        assertEq(validator1.balanceOf(address(controller)), maticAmount + polAmount + userAmount);
        uint256 fee = ((maticAmount + polAmount) * controller.rewardFee()) / 1000;
        assertEq(
            controller.convertSPOLtoPOL(userAmount),
            maticAmount + polAmount + userAmount - fee,
            "user still owns POL equivalent of sPOL minus fee"
        );
        assertEq(controller.feedPOLBalance(), fee, "total fee balance was applied to entire cleaned amount");
    }
}
