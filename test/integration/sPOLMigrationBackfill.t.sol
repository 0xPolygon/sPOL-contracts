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
import {MsgCoder} from "../../src/MsgCoder.sol";

contract sPOLMigrationBackfillTest is Test, Deploy, CheckpointData {
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

    IValidatorShare validator1;
    IValidatorShare validator2;

    // Use unique labels to avoid collisions with accounts that have code on forked chains (EIP-7702 delegation)
    address user1 = makeAddr("user1no7702delegation");
    address user2 = makeAddr("user2no7702delegation");
    address user3 = makeAddr("user3no7702delegation");

    uint256 smallAmount = 1 ether;
    uint256 mediumAmount = 300 ether;
    uint256 largeAmount = 5000 ether;
    uint256 hugeAmount = 2000000 ether;

    function setUp() public {
        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"), FORK_BLOCK_L1);
        networkL2 = vm.createFork(vm.envString("L2_RPC_URL"));
        nonAdmin = makeAddr("nonAdmin");

        loadConfigFromJson("ethereum-polygon");
        saltPrefix = "mainnet-test-";

        // Setup L1
        vm.selectFork(networkL1);
        deployContractsL1(address(this));

        sPOLToken = sPOL(address(sPOLProxy));
        controller = sPOLController(address(sPOLControllerProxy));
        messenger = sPOLMessenger(address(sPOLMessengerProxy));
        testAdmin = admin;
        validator1 = IValidatorShare(IStakeManager(stakeManager).getValidatorContract(validator1ID));
        validator2 = IValidatorShare(IStakeManager(stakeManager).getValidatorContract(validator2ID));

        // Setup L2
        vm.selectFork(networkL2);
        deployContractsL2(address(this));
        child = sPOLChild(payable(sPOLChildProxy));

        // Finish chain config
        vm.deal(admin, 1000000 ether);
        vm.selectFork(networkL1);

        // Map sPOL on root chain manager
        vm.prank(
            IRootChainManager(rootChainManager).getRoleMember(IRootChainManager(rootChainManager).MAPPER_ROLE(), 0)
        );
        IRootChainManager(rootChainManager).mapToken(address(sPOLToken), address(child), keccak256("ERC20"));

        // Register messenger in StateSender
        vm.prank(IStateSender(stateSenderL1).owner());
        IStateSender(stateSenderL1).register(address(messenger), address(child));

        erc20predicatePortal = IRootChainManager(rootChainManager).typeToPredicate(keccak256("ERC20"));
    }

    ///////////////////////////////
    ///  Helper Functions       ///
    ///////////////////////////////

    function _setupL1Validator() internal {
        vm.selectFork(networkL1);
        vm.prank(testAdmin);
        controller.addValidator(validator1ID);

        uint16[] memory validatorIDs = new uint16[](1);
        validatorIDs[0] = validator1ID;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        vm.prank(testAdmin);
        controller.updateValidatorTargetShare(validatorIDs, shares);
    }

    function _buyL1sPOL(address user, uint256 amount) internal returns (uint256 sPOLReceived) {
        vm.selectFork(networkL1);
        deal(polTokenL1, user, amount);
        vm.prank(user);
        IERC20(polTokenL1).approve(address(controller), amount);
        sPOLReceived = controller.convertPOLtoSPOL(amount);
        vm.prank(user);
        controller.buySPOL(amount);
    }

    function _sendExchangeRateToL2() internal returns (bytes memory stateSyncData) {
        vm.selectFork(networkL1);
        vm.recordLogs();
        vm.prank(testAdmin);
        messenger.updateL2ExchangeRate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find StateSynced event
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("StateSynced(uint256,address,bytes)")) {
                stateSyncData = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
    }

    function _receiveExchangeRateOnL2(bytes memory stateSyncData) internal {
        vm.selectFork(networkL2);
        vm.prank(stateSyncerL2);
        child.onStateReceive(0, stateSyncData);
    }

    function _unpauseL2() internal {
        vm.selectFork(networkL2);
        vm.prank(admin);
        child.unpauseBuy();
    }

    function _deployMockMessenger() internal returns (MocksPOLMessenger) {
        vm.selectFork(networkL1);
        MocksPOLMessenger mockMessenger = new MocksPOLMessenger(
            polTokenL1,
            address(sPOLProxy),
            address(sPOLControllerProxy),
            rootChainManager,
            depositManager,
            stateSenderL1,
            checkpointManager,
            precalcedsPOLChildProxyAddress
        );

        bytes memory upgradeAndCallData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(sPOLMessengerProxy)), address(mockMessenger), "")
        );
        vm.prank(admin);
        accessManagerL1.execute(address(sPOLMessengerproxyAdmin), upgradeAndCallData);

        return MocksPOLMessenger(address(sPOLMessengerProxy));
    }

    ///////////////////////////////
    ///  Migration Tests        ///
    ///////////////////////////////

    function test_migrationFlow_basicMigration() public {
        // Setup L1 with validator and initial stake
        _setupL1Validator();
        _buyL1sPOL(user1, largeAmount);

        // Send exchange rate to L2
        bytes memory stateSyncData = _sendExchangeRateToL2();
        _receiveExchangeRateOnL2(stateSyncData);
        _unpauseL2();

        // User buys sPOL on L2 (creates surplus POL)
        vm.selectFork(networkL2);
        deal(user1, largeAmount);
        uint256 expectedSPOL = child.convertPOLToSPOL(largeAmount);
        vm.prank(user1);
        child.buySPOL{value: largeAmount}(largeAmount);
        assertEq(child.balanceOf(user1), expectedSPOL, "User should receive expected sPOL");

        // Check L2 state before balancing
        uint256 locallyMintedBefore = child.locallyMintedSPOL();
        uint256 polBalanceBefore = child.polBalance();
        assertEq(locallyMintedBefore, expectedSPOL, "locallyMintedSPOL should equal minted amount");
        assertEq(polBalanceBefore, largeAmount, "polBalance should equal deposited amount");

        // Trigger migration via balanceWithL1
        vm.recordLogs();
        vm.prank(admin);
        child.balanceWithL1();

        // Verify migration was requested
        assertTrue(child.onGoingMigration(), "Migration should be ongoing");
        assertEq(child.backMigratingSPOL(), expectedSPOL, "backMigratingSPOL should equal minted sPOL");
        assertEq(child.polBalance(), 0, "polBalance should be 0 after migration");
        assertEq(child.locallyMintedSPOL(), 0, "locallyMintedSPOL should be reset");

        // Verify MigrationRequested event with correct values
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundMigrationEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("MigrationRequested(uint256,uint256)")) {
                (uint256 emittedPOL, uint256 emittedSPOL) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(emittedPOL, largeAmount, "MigrationRequested POL mismatch");
                assertEq(emittedSPOL, expectedSPOL, "MigrationRequested sPOL mismatch");
                foundMigrationEvent = true;
                break;
            }
        }
        assertTrue(foundMigrationEvent, "MigrationRequested event should be emitted");
    }

    function test_migrationFlow_completeMigration() public {
        // Setup L1 with validator and initial stake
        _setupL1Validator();
        _buyL1sPOL(user1, hugeAmount);

        // Send exchange rate to L2 and buy sPOL
        bytes memory stateSyncData = _sendExchangeRateToL2();
        _receiveExchangeRateOnL2(stateSyncData);
        _unpauseL2();

        vm.selectFork(networkL2);
        deal(user1, largeAmount);
        uint256 expectedSPOL = child.convertPOLToSPOL(largeAmount);
        vm.prank(user1);
        child.buySPOL{value: largeAmount}(largeAmount);

        // Construct expected migration message before triggering
        bytes memory expectedMigrationMsg =
            abi.encode(MsgCoder.MsgType.L2_MIGRATION_REQUEST, abi.encode(largeAmount, expectedSPOL));

        // Trigger migration and verify event
        vm.recordLogs();
        vm.prank(admin);
        child.balanceWithL1();
        Vm.Log[] memory balanceLogs = vm.getRecordedLogs();

        // Verify MigrationRequested event emits expected values
        bool foundMigrationRequested = false;
        for (uint256 i = 0; i < balanceLogs.length; i++) {
            if (balanceLogs[i].topics[0] == keccak256("MigrationRequested(uint256,uint256)")) {
                (uint256 emittedPOL, uint256 emittedSPOL) = abi.decode(balanceLogs[i].data, (uint256, uint256));
                assertEq(emittedPOL, largeAmount, "MigrationRequested POL amount mismatch");
                assertEq(emittedSPOL, expectedSPOL, "MigrationRequested sPOL amount mismatch");
                foundMigrationRequested = true;
                break;
            }
        }
        assertTrue(foundMigrationRequested, "MigrationRequested event should be emitted");

        // Deploy mock messenger to bypass proof verification
        MocksPOLMessenger mockMessenger = _deployMockMessenger();

        // Give polBridger the POL that would come from bridge exit
        deal(polTokenL1, address(polBridgerProxy), largeAmount);

        // Process migration on L1
        vm.selectFork(networkL1);
        vm.recordLogs();
        mockMessenger.expose_processMessageFromChild(expectedMigrationMsg);

        // Verify messenger's MigrationProcessed event with correct values
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundMigrationProcessed = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("MigrationProcessed(uint256,uint256)")) {
                (uint256 emittedPOL, uint256 emittedSPOL) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(emittedPOL, largeAmount, "Messenger MigrationProcessed POL mismatch");
                assertEq(emittedSPOL, expectedSPOL, "Messenger MigrationProcessed sPOL mismatch");
                foundMigrationProcessed = true;
                break;
            }
        }
        assertTrue(foundMigrationProcessed, "Messenger MigrationProcessed event should be emitted");

        // Complete migration on L2 by simulating deposit
        vm.selectFork(networkL2);
        uint256 childBalanceBefore = child.balanceOf(address(child));
        uint256 totalSupplyBefore = child.totalSupply();

        vm.prank(childChainManager);
        child.deposit(address(child), abi.encode(expectedSPOL));

        // Migration should be complete
        assertFalse(child.onGoingMigration(), "Migration should be complete");
        assertEq(child.backMigratingSPOL(), 0, "backMigratingSPOL should be reset");
        // sPOL wasn't minted since it was migration completion
        assertEq(child.balanceOf(address(child)), childBalanceBefore, "child sPOL balance unchanged");
        assertEq(child.totalSupply(), totalSupplyBefore, "total supply unchanged");
    }

    function test_cannotBalanceWhileMigrationOngoing() public {
        // Setup L1 with validator and initial stake
        _setupL1Validator();
        _buyL1sPOL(user1, hugeAmount);

        // Send exchange rate to L2
        bytes memory stateSyncData = _sendExchangeRateToL2();
        _receiveExchangeRateOnL2(stateSyncData);
        _unpauseL2();

        // Buy sPOL on L2 to create migration situation
        vm.selectFork(networkL2);
        deal(user1, largeAmount);
        vm.prank(user1);
        child.buySPOL{value: largeAmount}(largeAmount);

        // Trigger migration
        vm.prank(admin);
        child.balanceWithL1();
        assertTrue(child.onGoingMigration(), "Migration should be ongoing");

        // Try to balance again
        vm.prank(admin);
        vm.expectRevert(sPOLChild.MigrationAlreadyOngoing.selector);
        child.balanceWithL1();
    }
}
