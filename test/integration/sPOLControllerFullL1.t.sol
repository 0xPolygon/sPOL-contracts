// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/Script.sol";
import "../../src/sPOL.sol";
import "../../src/sPOLController.sol";
import "../../src/sPOLMessenger.sol";
import "../../src/sPOLChild.sol";
import "../../script/Deploy.s.sol";
import "../mocks/MocksPOLMessenger.sol";
import "./CheckpointData.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Registry as IRegistry} from "../../src/interfaces/IRegistry.sol";
import {ERC20PredicateBurnOnly as IERC20PredicateBurnOnly} from "../../src/interfaces/IERC20Predicate.sol";
import {WithdrawManager as IWithdrawManager} from "../../src/interfaces/IWithdrawManager.sol";
import {IStateSender} from "../../src/msg/interfaces/IStateSender.sol";
import {MRC20 as IMRC20} from "../../src/interfaces/IMRC20.sol";
import {BaseChildTunnel} from "../../src/msg/BaseChildTunnel.sol";

contract sPOLControllerFullL1Test is Test, Deploy, CheckpointData {
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
    IValidatorShare externalValidator;
    IValidatorShare knownValidator;

    address user1 = makeAddr("user1no7702delegation");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address user4;
    uint256 user4pk;
    uint8 currentV;
    bytes32 currentR;
    bytes32 currentS;

    uint256 smallAmount = 1 ether;
    uint256 mediumAmount = 300 ether;
    uint256 mediumAmount2 = 2000 ether;
    uint256 largeAmount = 5000 ether;
    uint256 hugeAmount = 2000000 ether;

    uint256 expectedSPOL = 0;
    uint256 expectedSPOL2 = 0;
    uint256 expectedPOL = 0;
    uint256 expectedPOL2 = 0;

    function setUp() public {
        (user4, user4pk) = makeAddrAndKey("user4");

        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"), FORK_BLOCK_L1);
        networkL2 = vm.createFork(vm.envString("L2_RPC_URL"));
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
        // Verify initial state

        //setup L2
        vm.selectFork(networkL2);
        // Deploy contracts
        deployContractsL2(address(this));

        // Get deployed contract instances
        child = sPOLChild(payable(sPOLChildProxy));
        // Get config values

        // Verify initial state

        // finish chain config
        vm.deal(admin, 1000000 ether);
        vm.selectFork(networkL1);
        // Map sPOL on root chain manager
        // no statesync in this test, so will remain unmapped in childchainManager, this is probably fine, as we will always be pranking as CCMs
        vm.prank(
            IRootChainManager(rootChainManager).getRoleMember(IRootChainManager(rootChainManager).MAPPER_ROLE(), 0)
        );
        IRootChainManager(rootChainManager).mapToken(address(sPOLToken), address(child), keccak256("ERC20"));

        // Register messenger in StateSender
        vm.prank(IStateSender(stateSenderL1).owner());
        IStateSender(stateSenderL1).register(address(messenger), address(child));

        erc20predicatePortal = IRootChainManager(rootChainManager).typeToPredicate(keccak256("ERC20"));
    }

    function test_fullL1_expected_usage() public {
        deal(polTokenL1, user1, 1000000000 ether);
        vm.prank(user1);
        IERC20(polTokenL1).approve(address(controller), type(uint256).max);

        vm.selectFork(networkL1);

        // user1 attempts to buy sPOL, no validators exist yet
        vm.prank(user1);
        vm.expectRevert();
        controller.buySPOL(1000 ether);

        // activate 1 validator
        vm.prank(testAdmin);
        controller.addValidator(validator1ID);

        // attempt to buy again, total depositshare 0
        // vm.prank(user1);
        // vm.expectRevert();
        // controller.buySPOL(1000 ether);

        // set validator1 deposit share to 100%
        uint16[] memory validatorIDs = new uint16[](1);
        validatorIDs[0] = validator1ID;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIDs, shares);
        // user1 buys sPOL
        vm.prank(user1);
        controller.buySPOL(largeAmount);
        assertEq(sPOLToken.balanceOf(user1), largeAmount);
        assertEq(validator1.balanceOf(address(controller)), largeAmount);

        // buy more
        vm.prank(user1);
        controller.buySPOL(hugeAmount);
        assertEq(sPOLToken.balanceOf(user1), hugeAmount + largeAmount);
        assertEq(validator1.balanceOf(address(controller)), hugeAmount + largeAmount);

        // sell some sPOL
        vm.prank(user1);
        uint256[] memory firstSellNonces = controller.sellSPOL(mediumAmount);
        assertEq(sPOLToken.balanceOf(user1), hugeAmount + largeAmount - mediumAmount);
        sPOLController.FullNonceDetails[] memory openUserNonces = controller.getUserOpenNonces(user1);
        assertEq(openUserNonces[0].nonce, firstSellNonces[0]);
        (uint16 firstSellId, uint128 firstSellamount, uint96 firstSellnonce) =
            controller.withdrawNonceDetails(firstSellNonces[0]);
        assertEq(firstSellamount, mediumAmount);
        assertEq(firstSellId, validator1ID);
        assertEq(firstSellnonce, 1);

        // attempt withdraw
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(sPOLController.NoNoncesReady.selector, user1));
        controller.withdrawPOL();

        uint256 beforeWithdrawPeriod = vm.snapshotState();

        // fast forward time past withdraw delay
        vm.startPrank(IStakeManager(stakeManager).governance());
        IStakeManager(stakeManager).setCurrentEpoch(IStakeManager(stakeManager).currentEpoch() + 80);
        vm.stopPrank();

        // withdraw successful
        uint256 user1BalanceBefore = IERC20(polTokenL1).balanceOf(user1);
        vm.prank(user1);
        controller.withdrawPOL();
        uint256 user1BalanceAfter = IERC20(polTokenL1).balanceOf(user1);
        assertEq(user1BalanceAfter - user1BalanceBefore, mediumAmount);

        vm.revertToState(beforeWithdrawPeriod);

        uint256 oldExchange = controller.convertPOLtoSPOL(10000 ether);
        assertEq(oldExchange, 10000 ether);

        _submitCheckpoint1();

        controller.restakeValidator(validator1ID);
        uint256 newExchange = controller.convertPOLtoSPOL(10000 ether);
        assertLt(newExchange, 10000 ether);

        // buy some with new exchange rate
        expectedSPOL = controller.convertPOLtoSPOL(largeAmount);
        vm.prank(user1);
        controller.buySPOL(largeAmount);
        assertLt(sPOLToken.balanceOf(user1), largeAmount + hugeAmount + largeAmount - mediumAmount);
        assertEq(sPOLToken.balanceOf(user1), expectedSPOL + hugeAmount + largeAmount - mediumAmount);

        // small sell after exchange rate change
        expectedPOL = controller.convertSPOLtoPOL(smallAmount);
        uint256 controllerValNonce = validator1.unbondNonces(address(controller));

        vm.prank(user1);
        uint256[] memory secondSellNonces = controller.sellSPOL(smallAmount);
        assertEq(sPOLToken.balanceOf(user1), expectedSPOL + hugeAmount + largeAmount - mediumAmount - smallAmount);
        openUserNonces = controller.getUserOpenNonces(user1);
        console.log(secondSellNonces.length);
        assertEq(openUserNonces[1].nonce, secondSellNonces[0]);
        (uint16 secondSellId, uint128 secondSellamount, uint96 secondSellnonce) =
            controller.withdrawNonceDetails(secondSellNonces[0]);
        assertEq(secondSellamount, expectedPOL);
        assertEq(secondSellId, validator1ID);
        assertEq(secondSellnonce, controllerValNonce + 1);

        // another reward increase
        _submitCheckpoint2();
        controller.restakeValidator(validator1ID);
        // another small sell after exchange rate change
        expectedPOL2 = controller.convertSPOLtoPOL(smallAmount);
        vm.prank(user1);
        uint256[] memory thirdSellNonces = controller.sellSPOL(smallAmount);
        openUserNonces = controller.getUserOpenNonces(user1);

        assertEq(
            sPOLToken.balanceOf(user1),
            expectedSPOL + hugeAmount + largeAmount - mediumAmount - smallAmount - smallAmount
        );
        assertEq(openUserNonces[2].nonce, thirdSellNonces[0]);
        (uint16 thirdSellId, uint128 thirdSellamount, uint96 thirdSellnonce) =
            controller.withdrawNonceDetails(thirdSellNonces[0]);
        assertEq(thirdSellamount, expectedPOL2);
        assertEq(thirdSellId, validator1ID);
        assertEq(thirdSellnonce, 3);
        assertGt(expectedPOL2, expectedPOL);
    }

    function test_buySPOLWithDPOL() public {
        vm.selectFork(networkL1);

        // Setup the system first
        deal(polTokenL1, user1, 10000 ether);
        deal(polTokenL1, user2, 10000 ether);
        deal(polTokenL1, user3, 10000 ether);
        deal(polTokenL1, user4, mediumAmount);

        vm.prank(user1);
        IERC20(polTokenL1).approve(address(controller), type(uint256).max);
        vm.prank(user2);
        IERC20(polTokenL1).approve(address(controller), type(uint256).max);
        vm.prank(user3);
        IERC20(polTokenL1).approve(address(controller), type(uint256).max);

        // Activate validators
        vm.prank(testAdmin);
        controller.addValidator(validator1ID);
        // Note: validator2ID is intentionally NOT added to make it an external validator

        // Set validator shares - our validator gets 100% since we only have one managed validator
        uint16[] memory validatorIDs = new uint16[](1);
        validatorIDs[0] = validator1ID;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIDs, shares);

        externalValidator = IValidatorShare(IStakeManager(stakeManager).getValidatorContract(validator2ID));

        // User1 buys dPOL
        vm.startPrank(user1);
        ERC20(polTokenL1).approve(address(stakeManager), largeAmount);
        externalValidator.buyVoucherPOL(largeAmount, largeAmount);
        externalValidator.approve(address(controller), largeAmount);
        vm.stopPrank();

        uint256 expectedSPOLFromDPOL = controller.convertPOLtoSPOL(largeAmount);

        // User1 uses dPOL to buy sPOL
        vm.prank(user1);
        controller.buySPOLWithDPOL(largeAmount, validator2ID);
        assertEq(sPOLToken.balanceOf(user1), expectedSPOLFromDPOL);

        // user2 - Buys dPOL from known validator and attempts to convert to sPOL
        knownValidator = IValidatorShare(IStakeManager(stakeManager).getValidatorContract(validator1ID));

        // user2 buys dPOL from the known validator
        vm.startPrank(user2);
        ERC20(polTokenL1).approve(address(stakeManager), mediumAmount);
        knownValidator.buyVoucherPOL(mediumAmount, mediumAmount);
        vm.stopPrank();

        // Check user2's dPOL balance
        uint256 user2DPOLBalance = knownValidator.balanceOf(user2);
        assertEq(user2DPOLBalance, mediumAmount, "user2 should have dPOL tokens");

        // user2 approves the controller to spend their dPOL
        vm.prank(user2);
        knownValidator.approve(address(controller), user2DPOLBalance);

        // Calculate expected sPOL from user2's dPOL
        uint256 expectedSPOLFromuser2DPOL = controller.convertPOLtoSPOL(user2DPOLBalance);

        // Record initial sPOL balance before conversion
        uint256 user2InitialSPOLBalance = sPOLToken.balanceOf(user2);

        // user2 attempts to convert dPOL to sPOL
        vm.prank(user2);
        controller.buySPOLWithDPOL(user2DPOLBalance, validator1ID);

        // Verify user2 received the expected sPOL tokens
        uint256 user2FinalSPOLBalance = sPOLToken.balanceOf(user2);
        assertEq(
            user2FinalSPOLBalance - user2InitialSPOLBalance,
            expectedSPOLFromuser2DPOL,
            "user2 should receive the correct amount of sPOL tokens"
        );

        // Verify user2's dPOL balance is now zero (all converted)
        assertEq(knownValidator.balanceOf(user2), 0, "user2 should have zero dPOL tokens after conversion");

        // user3 - Buys dPOL from known validator with liquid rewards and attempts to convert to sPOL
        // user3 buys dPOL from the known validator
        vm.startPrank(user3);
        ERC20(polTokenL1).approve(address(stakeManager), mediumAmount);
        knownValidator.buyVoucherPOL(mediumAmount, mediumAmount);
        vm.stopPrank();

        // Send rewards to increase dPOL balance
        _submitCheckpoint1();

        // Check user3's dPOL balance
        uint256 user3DPOLBalance = knownValidator.balanceOf(user3);
        assertEq(user3DPOLBalance, mediumAmount, "user3 should have dPOL tokens");
        // Should have rewards
        uint256 user3liquidRewards = knownValidator.getLiquidRewards(user3);
        assertGt(user3liquidRewards, 0, "user3 should have liquid rewards");
        uint256 controllerliquidRewards = knownValidator.getLiquidRewards(address(controller));
        assertGt(controllerliquidRewards, 0, "controller should have liquid rewards");
        uint256 controllerDPOLBalance = knownValidator.balanceOf(address(controller));
        uint256 user3POLBalance = IERC20(polTokenL1).balanceOf(user3);

        // user3 approves the controller to spend their dPOL
        vm.prank(user3);
        knownValidator.approve(address(controller), user3DPOLBalance);

        // Calculate expected sPOL from user3's dPOL
        uint256 expectedSPOLFromuser3DPOL = controller.convertPOLtoSPOL(user3DPOLBalance);

        // Record initial sPOL balance before conversion
        uint256 user3InitialSPOLBalance = sPOLToken.balanceOf(user3);

        // user3 attempts to convert dPOL to sPOL
        vm.prank(user3);
        controller.buySPOLWithDPOL(user3DPOLBalance, validator1ID);

        // Verify user3 received the expected sPOL tokens
        assertEq(
            sPOLToken.balanceOf(user3) - user3InitialSPOLBalance,
            expectedSPOLFromuser3DPOL,
            "user3 should receive the correct amount of sPOL tokens"
        );

        // Verify user3's dPOL balance is now zero (all converted)
        assertEq(knownValidator.balanceOf(user3), 0, "user3 should have zero dPOL tokens after conversion");
        // Verify user got POL
        assertEq(
            IERC20(polTokenL1).balanceOf(user3),
            user3liquidRewards + user3POLBalance,
            "user3 should have received their liquid rewards in POL"
        );
        assertEq(knownValidator.getLiquidRewards(user3), 0, "user3 should have no liquid rewards");
        // Verify that the controller's dPOL balance has increased due to liquid rewards being claimed
        assertEq(
            knownValidator.balanceOf(address(controller)),
            controllerDPOLBalance + controllerliquidRewards + mediumAmount,
            "controller should have increased dPOL balance from rewards"
        );
        assertEq(
            knownValidator.getLiquidRewards(address(controller)),
            0,
            "controller should have no liquid rewards from known validator"
        );

        // user4 buys using permit
        vm.startPrank(user4);
        ERC20(polTokenL1).approve(address(stakeManager), mediumAmount);
        externalValidator.buyVoucherPOL(mediumAmount, mediumAmount);
        vm.stopPrank();

        // Check user4's dPOL balance
        assertEq(externalValidator.balanceOf(user4), mediumAmount, "user4 should have dPOL tokens");

        uint256 expectedSPOLFromuser4DPOL = controller.convertPOLtoSPOL(mediumAmount);
        uint256 controllerDPOLBalance4 = knownValidator.balanceOf(address(controller));
        assertEq(
            knownValidator.getLiquidRewards(address(controller)),
            0,
            "controller should have no liquid rewards from known validator"
        );

        // user4 attempts to convert dPOL to sPOL using permit
        externalValidator._cacheDomainSeparatorV4();
        (currentV, currentR, currentS) = createPermit(
            address(externalValidator), user4, address(controller), mediumAmount, block.timestamp + 1 hours, user4pk
        );
        controller.buySPOLWithDPOLPermit(
            mediumAmount, validator2ID, user4, block.timestamp + 1 hours, currentV, currentR, currentS
        );

        assertEq(
            controllerDPOLBalance4 + mediumAmount,
            knownValidator.balanceOf(address(controller)),
            "controller should have gotten permit dPOL"
        );
        assertEq(0, externalValidator.balanceOf(address(controller)), "controller should not get external dPOL");
        assertEq(
            controller.totaldPOLBalance(), controllerDPOLBalance4 + mediumAmount, "total dPOL balance should update"
        );

        (,,,, uint256 dPOLval1TotalStaked) = controller.validators(validator1ID);
        assertEq(
            dPOLval1TotalStaked, knownValidator.balanceOf(address(controller)), "validator dPOL balance should update"
        );
        // Verify user4 received the expected sPOL tokens
        uint256 user4FinalSPOLBalance = sPOLToken.balanceOf(user4);
        assertEq(
            user4FinalSPOLBalance, expectedSPOLFromuser4DPOL, "user4 should receive the correct amount of sPOL tokens"
        );

        // Verify user4's dPOL balance is now zero (all converted)
        assertEq(externalValidator.balanceOf(user4), 0, "user4 should have zero dPOL tokens after conversion");
    }

    function test_multipleWithdrawNonces_ArrayManipulation() public {
        vm.selectFork(networkL1);
        deal(polTokenL1, user1, 10000 ether);
        vm.prank(user1);
        IERC20(polTokenL1).approve(address(controller), type(uint256).max);

        vm.prank(testAdmin);
        controller.addValidator(validator1ID);
        uint16[] memory validatorIDs = new uint16[](1);
        validatorIDs[0] = validator1ID;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIDs, shares);

        vm.prank(user1);
        controller.buySPOL(4000 ether);

        // Create 2 early withdrawal nonces
        vm.prank(user1);
        uint256 nonce0 = controller.sellSPOL(500 ether, validator1ID);
        vm.prank(user1);
        uint256 nonce1 = controller.sellSPOL(500 ether, validator1ID);

        // advance epoch
        vm.startPrank(IStakeManager(stakeManager).governance());
        IStakeManager(stakeManager).setCurrentEpoch(IStakeManager(stakeManager).currentEpoch() + 40);
        vm.stopPrank();

        // 2 more later withdrawal nonces
        vm.prank(user1);
        uint256 nonce2 = controller.sellSPOL(500 ether, validator1ID);
        vm.prank(user1);
        uint256 nonce3 = controller.sellSPOL(500 ether, validator1ID);

        sPOLController.FullNonceDetails[] memory openNonces = controller.getUserOpenNonces(user1);
        assertEq(openNonces.length, 4, "open nonces length mismatch");

        assertEq(nonce0, openNonces[0].nonce, "nonce0 mismatch");
        assertEq(nonce1, openNonces[1].nonce, "nonce1 mismatch");
        assertEq(nonce2, openNonces[2].nonce, "nonce2 mismatch");
        assertEq(nonce3, openNonces[3].nonce, "nonce3 mismatch");

        // advance epoch so two are ready
        vm.startPrank(IStakeManager(stakeManager).governance());
        IStakeManager(stakeManager).setCurrentEpoch(IStakeManager(stakeManager).currentEpoch() + 60);
        vm.stopPrank();

        // Call withdrawPOL, this will process the ready nonces (0,1)
        vm.prank(user1);
        controller.withdrawPOL();

        // remaining nonces
        sPOLController.FullNonceDetails[] memory openNonces2 = controller.getUserOpenNonces(user1);
        assertEq(openNonces2.length, 2, "open nonces length mismatch");
        uint256 rnonce0 = openNonces2[0].nonce;
        uint256 rnonce1 = openNonces2[1].nonce;

        assertEq(rnonce0, nonce2, "remaining nonce not the expected nonce2");
        assertEq(rnonce1, nonce3, "remaining nonce not the expected nonce3");
    }

    // Helper
    function createPermit(
        address _token,
        address _from,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint256 _pk
    ) internal view returns (uint8, bytes32, bytes32) {
        uint256 nonce = ERC20Permit(_token).nonces(_from);
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 dataToSign = keccak256(
            abi.encodePacked(
                "\x19\x01",
                ERC20Permit(_token).DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, _from, _spender, _value, nonce, _deadline))
            )
        );
        return vm.sign(_pk, dataToSign);
    }
}
