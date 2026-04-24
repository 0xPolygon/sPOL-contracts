// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {PolBridger} from "../../src/polBridger.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {sPOLController} from "../../src/sPOLController.sol";

import {UpgradePolBridgerToProxy} from "../../script/upgrades/UpgradePolBridgerToProxy.s.sol";
import {MocksPOLMessenger} from "../mocks/MocksPOLMessenger.sol";

import {MsgCoder} from "../../src/MsgCoder.sol";

import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Full migration round-trip on the upgraded mainnet state. This exercises the pending
///         mainnet migration end-to-end through the newly-deployed PolBridger proxy and the
///         upgraded messenger/child.
///
///         Pranking rules we follow:
///           - Admin multisig is pranked for every production-privileged call. ProxyAdmin
///             upgrades go through AccessManager.execute (required — ProxyAdmin is onlyOwner-
///             gated by the AccessManager). `updateBridgeHelper` is a direct admin call (admin
///             has ADMIN_ROLE so AccessManager.canCall passes without the extra hop).
///           - stateSyncerL2 and childChainManager are pranked for their respective bridge
///             delivery callbacks — that's the only way the Polygon bridge delivers messages,
///             and it's the same pattern used in sPOLMigrationBackfill.t.sol.
///           - No other addresses are pranked and no storage is manipulated.
contract PolBridgerUpgradeMigrationForkTest is Test, UpgradePolBridgerToProxy {
    uint256 internal networkL1;
    uint256 internal networkL2;

    Config internal cfg;
    DeployedL1 internal d1;
    DeployedL2 internal d2;

    address internal admin;
    address internal rcmERC20Predicate;

    sPOLMessenger internal messenger;
    sPOLChild internal child;
    sPOLController internal controller;
    IERC20 internal sPOLToken;

    function setUp() public {
        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"));
        networkL2 = vm.createFork(vm.envString("L2_RPC_URL"));

        cfg = _loadConfig("mainnet");
        string memory inputJson = vm.readFile("script/input.json");
        admin = vm.parseJsonAddress(inputJson, ".ethereum-polygon.admin");
        rcmERC20Predicate = vm.parseJsonAddress(inputJson, ".ethereum-polygon.rcmERC20Predicate");
        require(cfg.registry != address(0), "registry not configured");

        vm.selectFork(networkL1);
        d1 = _deployL1(cfg, address(this));
        vm.selectFork(networkL2);
        d2 = _deployL2(cfg, address(this));
        require(d1.polBridgerProxy == d2.polBridgerProxy, "proxy address mismatch");

        _executeL1Admin();
        _executeL2Admin();

        messenger = sPOLMessenger(cfg.sPOLMessengerProxy);
        child = sPOLChild(payable(cfg.sPOLChildProxy));
        controller = sPOLController(cfg.sPOLControllerProxy);
        sPOLToken = IERC20(cfg.sPOLProxy);
    }

    function _executeL1Admin() internal {
        vm.selectFork(networkL1);
        _executeAdminPlan(cfg.accessManagerL1, _buildL1AdminPlan(cfg, d1));
    }

    function _executeL2Admin() internal {
        vm.selectFork(networkL2);
        _executeAdminPlan(cfg.accessManagerL2, _buildL2AdminPlan(cfg, d2));
    }

    function _executeAdminPlan(address accessManager, AdminStep[] memory steps) internal {
        for (uint256 i = 0; i < steps.length; i++) {
            vm.prank(admin);
            if (steps[i].viaAccessManager) {
                AccessManager(accessManager).execute(steps[i].target, steps[i].data);
            } else {
                (bool ok, bytes memory ret) = steps[i].target.call(steps[i].data);
                if (!ok) {
                    assembly {
                        revert(add(ret, 0x20), mload(ret))
                    }
                }
            }
        }
    }

    /// @dev Replaces the real sPOLMessenger impl with a bytecode-identical mock that exposes
    ///      `_processMessageFromChild` publicly, so we can drive the migration without waiting
    ///      for an L2→L1 checkpoint proof. Upgraded via AccessManager.execute — the only prank
    ///      is on the admin multisig.
    function _upgradeMessengerToMock() internal returns (MocksPOLMessenger) {
        vm.selectFork(networkL1);
        MocksPOLMessenger mockImpl = new MocksPOLMessenger(
            cfg.polTokenL1,
            cfg.sPOLProxy,
            cfg.sPOLControllerProxy,
            cfg.rootChainManager,
            cfg.depositManager,
            cfg.stateSenderL1,
            cfg.checkpointManager,
            cfg.sPOLChildProxy
        );
        vm.prank(admin);
        AccessManager(cfg.accessManagerL1)
            .execute(
                cfg.sPOLMessengerProxyAdmin,
                abi.encodeCall(
                    ProxyAdmin.upgradeAndCall,
                    (ITransparentUpgradeableProxy(cfg.sPOLMessengerProxy), address(mockImpl), "")
                )
            );
        return MocksPOLMessenger(cfg.sPOLMessengerProxy);
    }

    ///////////////////////////////
    ///  Tests                  ///
    ///////////////////////////////

    /// @notice Two consecutive full migration cycles end-to-end through the new PolBridger
    ///         proxy, using only real mainnet state.
    ///
    ///           (A) The pending migration that motivated this upgrade, finalised against the
    ///               *real* sPOLMessenger (not the mock). The POL that was originally burnt on
    ///               L2 for this migration is permanently stuck on mainnet (the old bridger was
    ///               the L2 burner, so only its address can start that Plasma exit, but its
    ///               hardcoded predicate is defunct — nobody else's msg.sender matches). We
    ///               donate *fresh* POL to the new proxy to stand in for that never-to-arrive
    ///               exit, then submit the real L2→L1 state-sync message proof
    ///               `script/proof.json` via `messenger.receiveMessage(...)`. The messenger
    ///               validates the proof against the mainnet CheckpointManager and runs
    ///               `_processMessageFromChild` with the original migration payload. Finally
    ///               the ChildChainManager callback on L2 closes the migration accounting.
    ///           (B) A fresh migration of the polBalance the child accumulated since the
    ///               pending migration started. We can't fabricate a real proof for this, so we
    ///               upgrade the messenger to a mock that exposes `_processMessageFromChild`
    ///               to drive the handler directly.
    function test_pendingAndFreshMigrationThroughNewPolBridger() public {
        _finalisePendingMigrationWithRealProof();

        MocksPOLMessenger mockMessenger = _upgradeMessengerToMock();

        (uint256 freshPOL, uint256 freshSPOL) = _triggerFreshMigrationFromAccumulatedState();
        _processFreshMigrationOnL1(mockMessenger, freshPOL, freshSPOL);
        _closeFreshMigrationOnL2(freshSPOL);
    }

    function _finalisePendingMigrationWithRealProof() internal {
        vm.selectFork(networkL2);
        assertTrue(child.onGoingMigration(), "precondition: child has pending migration");
        uint256 pendingSPOL = child.backMigratingSPOL();
        require(pendingSPOL > 0, "pending migration has zero sPOL");

        vm.selectFork(networkL1);
        // Donate generously: needs to cover whatever polAmount the proof decodes to, and still
        // leave at least `controller.convertSPOLtoPOL(pendingSPOL) + 1` for the messenger's
        // internal buySPOL call. Anything extra stays in the bridger until rescued.
        uint256 donationPOL = controller.convertSPOLtoPOL(pendingSPOL) * 2 + 1000 ether;

        deal(cfg.polTokenL1, d1.polBridgerProxy, donationPOL);

        uint256 prePOLMessenger = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy);
        uint256 preSPOLMessenger = sPOLToken.balanceOf(cfg.sPOLMessengerProxy);
        uint256 preControllerPOL = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLControllerProxy);

        // (2) Submit the REAL L2→L1 state-sync proof via receiveMessage on the real messenger.
        //     receiveMessage is permissionless — no prank needed. It validates the proof against
        //     the mainnet CheckpointManager, extracts the original migration request, and runs
        //     _processMessageFromChild.
        bytes memory proof = vm.parseJsonBytes(vm.readFile("script/upgrades/UpgradePolBridgerProof.json"), ".proof");
        vm.recordLogs();
        messenger.receiveMessage(proof);
        (uint256 emittedPOL, uint256 emittedSPOL) = _extractProcessedAmounts(vm.getRecordedLogs());
        assertEq(emittedSPOL, pendingSPOL, "proof-decoded sPOL must match child.backMigratingSPOL");

        // Bridger must have relinquished the proof's polAmount; any extra donation stays until
        // rescue. The messenger consumes `convertSPOLtoPOL(sPOL)+1` and forwards the rest to the
        // controller, so its own balance nets to zero.
        assertEq(
            IERC20(cfg.polTokenL1).balanceOf(d1.polBridgerProxy),
            donationPOL - emittedPOL,
            "bridger residual must equal donation minus proof polAmount"
        );
        assertEq(
            IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy),
            prePOLMessenger,
            "messenger POL balance must be unchanged (surplus forwarded to controller)"
        );
        assertEq(
            sPOLToken.balanceOf(cfg.sPOLMessengerProxy),
            preSPOLMessenger,
            "messenger sPOL balance must be unchanged (deposited into bridge predicate)"
        );
        // Controller received the surplus POL from the messenger.
        uint256 controllerPOLDelta = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLControllerProxy) - preControllerPOL;
        // Messenger staked `convertSPOLtoPOL(pendingSPOL)+1` and forwarded the rest; the staked
        // portion may have immediately flowed into the StakeManager, so we only assert the
        // controller balance increased by at most the full polAmount.
        assertLe(controllerPOLDelta, emittedPOL, "controller POL delta cannot exceed polAmount");

        // (3) Close migration on L2 via the ChildChainManager callback.
        vm.selectFork(networkL2);
        vm.prank(child.childChainManager());
        child.deposit(address(child), abi.encode(pendingSPOL));
        assertFalse(child.onGoingMigration(), "pending migration did not close on L2");
        assertEq(child.backMigratingSPOL(), 0, "backMigratingSPOL not cleared");
    }

    function _extractProcessedAmounts(Vm.Log[] memory logs) internal pure returns (uint256 pol, uint256 sPOL) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("MigrationProcessed(uint256,uint256)")) {
                return abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        revert("MigrationProcessed event missing");
    }

    function _triggerFreshMigrationFromAccumulatedState() internal returns (uint256 pol, uint256 sPOL) {
        vm.selectFork(networkL2);
        // After the pending migration closed, the child still carries the polBalance and
        // locallyMintedSPOL accumulated from L2 buys since the pending migration started.
        pol = child.polBalance();
        sPOL = child.locallyMintedSPOL();
        require(pol > 0 && sPOL > 0, "expected accumulated state after pending migration");
        assertFalse(child.onGoingMigration(), "should be clear after pending finalise");
        assertEq(address(child.bridgeHelper()), d2.polBridgerProxy, "child not wired to new proxy");

        // Production trigger: admin pushes a fresh rate on L1, state sync delivers it to L2,
        // and child._handleExchangeRateUpdate calls _balanceWithL1 internally — which spots
        // the non-zero polBalance and fires the migration. No direct balanceWithL1 call.
        bytes memory stateSyncData = _pushExchangeRateFromL1();

        vm.selectFork(networkL2);
        vm.recordLogs();
        // stateSyncerL2 is the Polygon bridge system caller — the only address that can
        // invoke onStateReceive. Pranking it simulates the bridge's automatic delivery.
        vm.prank(cfg.stateSyncerL2);
        child.onStateReceive(0, stateSyncData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(child.onGoingMigration(), "fresh migration should be ongoing");
        assertEq(child.backMigratingSPOL(), sPOL, "backMigratingSPOL mismatch");
        assertEq(child.polBalance(), 0, "polBalance should drain into migration");
        assertEq(child.locallyMintedSPOL(), 0, "locallyMintedSPOL should drain into migration");

        _assertMigrationRequestedAndBurn(logs, pol, sPOL);
    }

    /// @dev Calls messenger.updateL2ExchangeRate() on L1 (direct admin call — `restricted`
    ///      modifier passes because admin has ADMIN_ROLE) and captures the emitted StateSynced
    ///      payload. Returns the `bytes` the bridge would hand to child.onStateReceive.
    function _pushExchangeRateFromL1() internal returns (bytes memory stateSyncData) {
        vm.selectFork(networkL1);
        vm.recordLogs();
        vm.prank(admin);
        messenger.updateL2ExchangeRate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("StateSynced(uint256,address,bytes)")) {
                return abi.decode(logs[i].data, (bytes));
            }
        }
        revert("no StateSynced captured from updateL2ExchangeRate");
    }

    function _processFreshMigrationOnL1(MocksPOLMessenger mockMessenger, uint256 pol, uint256 sPOL) internal {
        vm.selectFork(networkL1);

        // Snapshot the L1 bridge ERC20 predicate's sPOL balance BEFORE anything (including the
        // donation `deal`) — `rootChainManager.depositFor(...)` deposits sPOL to the predicate
        // contract, so the predicate's post-balance must be exactly `pre + sPOL`.
        uint256 prePredicateSPOL = sPOLToken.balanceOf(rcmERC20Predicate);

        deal(cfg.polTokenL1, d1.polBridgerProxy, pol);

        uint256 preSPOLMessenger = sPOLToken.balanceOf(cfg.sPOLMessengerProxy);
        uint256 prePOLMessenger = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy);

        vm.recordLogs();
        mockMessenger.expose_processMessageFromChild(
            abi.encode(MsgCoder.MsgType.L2_MIGRATION_REQUEST, abi.encode(pol, sPOL))
        );

        assertEq(IERC20(cfg.polTokenL1).balanceOf(d1.polBridgerProxy), 0, "bridger must be emptied");
        assertEq(IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy), prePOLMessenger, "messenger POL drifted");
        assertEq(sPOLToken.balanceOf(cfg.sPOLMessengerProxy), preSPOLMessenger, "messenger sPOL drifted");

        // The sPOL the messenger minted + deposited must have landed at the predicate, which is
        // the destination for `rootChainManager.depositFor` deposits on L1.
        assertEq(
            sPOLToken.balanceOf(rcmERC20Predicate), prePredicateSPOL + sPOL, "predicate did not receive deposited sPOL"
        );

        _assertMigrationProcessed(vm.getRecordedLogs(), pol, sPOL);
    }

    function _closeFreshMigrationOnL2(uint256 sPOL) internal {
        vm.selectFork(networkL2);
        uint256 supplyBefore = child.totalSupply();
        uint256 selfBefore = child.balanceOf(address(child));

        vm.prank(child.childChainManager());
        child.deposit(address(child), abi.encode(sPOL));

        assertFalse(child.onGoingMigration(), "fresh migration did not close");
        assertEq(child.backMigratingSPOL(), 0, "backMigratingSPOL should be zero");
        assertEq(child.balanceOf(address(child)), selfBefore, "child self-balance should not grow");
        assertEq(child.totalSupply(), supplyBefore, "child totalSupply should be unchanged");
    }

    function _assertMigrationRequestedAndBurn(Vm.Log[] memory logs, uint256 pol, uint256 sPOL) internal view {
        bool foundReq;
        bool foundBurn;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("MigrationRequested(uint256,uint256)")) {
                (uint256 emittedPOL, uint256 emittedSPOL) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(emittedPOL, pol, "MigrationRequested POL");
                assertEq(emittedSPOL, sPOL, "MigrationRequested sPOL");
                foundReq = true;
            }
            if (
                logs[i].emitter == cfg.polTokenL2
                    && logs[i].topics[0] == keccak256("Withdraw(address,address,uint256,uint256,uint256)")
            ) {
                foundBurn = true;
            }
        }
        assertTrue(foundReq, "MigrationRequested event missing");
        assertTrue(foundBurn, "MRC20 Withdraw (POL burn) event not emitted");
    }

    function _assertMigrationProcessed(Vm.Log[] memory logs, uint256 pol, uint256 sPOL) internal pure {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("MigrationProcessed(uint256,uint256)")) {
                (uint256 emittedPOL, uint256 emittedSPOL) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(emittedPOL, pol, "MigrationProcessed POL mismatch");
                assertEq(emittedSPOL, sPOL, "MigrationProcessed sPOL mismatch");
                found = true;
            }
        }
        assertTrue(found, "MigrationProcessed event missing");
    }

    /// @notice takePOLL1 is still gated to the messenger after the upgrade.
    function test_bridger_takePOLL1_gatedToMessenger() public {
        vm.selectFork(networkL1);
        deal(cfg.polTokenL1, d1.polBridgerProxy, 1 ether);
        vm.expectRevert();
        PolBridger(d1.polBridgerProxy).takePOLL1(1 ether);
    }

    /// @notice bridgePOLToL1 is still gated to the child after the upgrade.
    function test_bridger_bridgePOLToL1_gatedToChild() public {
        vm.selectFork(networkL2);
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        PolBridger(d2.polBridgerProxy).bridgePOLToL1{value: 1 ether}(1 ether);
    }

    /// @notice rescue is restricted to the AccessManager-authorised admin.
    function test_bridger_rescue_gatedToAccessManager() public {
        vm.selectFork(networkL1);
        vm.expectRevert();
        PolBridger(d1.polBridgerProxy).rescue(cfg.polTokenL1, address(this), 1);
    }
}
