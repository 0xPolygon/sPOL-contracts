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

/// @notice Full migration round-trip on the upgraded mainnet state. Exercises the pending
///         mainnet migration end-to-end through the newly-deployed PolBridger proxy and the
///         upgraded messenger/child.
///
///         Pranking rules we follow:
///           - Admin multisig is pranked for every production-privileged call. ProxyAdmin
///             upgrades go through AccessManager.execute (required — ProxyAdmin is onlyOwner-
///             gated by the AccessManager). `updatePolBridger` is a direct admin call (admin
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
        require(d1.polBridgerProxy != address(0), "L1 proxy address is zero");
        require(d1.polBridgerProxy == d2.polBridgerProxy, "proxy address mismatch");

        // Execute the 2-step admin plan on each chain as the multisig would.
        vm.selectFork(networkL1);
        _executeAdminPlan(cfg.accessManagerL1, _buildL1AdminPlan(cfg, d1));
        vm.selectFork(networkL2);
        _executeAdminPlan(cfg.accessManagerL2, _buildL2AdminPlan(cfg, d2));

        messenger = sPOLMessenger(cfg.sPOLMessengerProxy);
        child = sPOLChild(payable(cfg.sPOLChildProxy));
        controller = sPOLController(cfg.sPOLControllerProxy);
        sPOLToken = IERC20(cfg.sPOLProxy);
    }

    /// @dev Drives each step of the multisig plan. ProxyAdmin upgrades go via AccessManager
    ///      (its ProxyAdmin is `onlyOwner`-gated); `updatePolBridger` is a direct admin call
    ///      (admin has ADMIN_ROLE → `restricted` check passes). Only address pranked is admin.
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

    ///////////////////////////////
    ///  Tests                  ///
    ///////////////////////////////

    /// @notice Two consecutive full migration cycles end-to-end through the new PolBridger
    ///         proxy, using only real mainnet state.
    ///
    ///         (A) The pending mainnet migration that motivated this upgrade, finalised against
    ///             the *real* sPOLMessenger (not the mock). The POL originally burnt on L2 for
    ///             that migration is permanently stuck on mainnet (the old bridger was the L2
    ///             burner, so only its address can start that Plasma exit, but its hardcoded
    ///             predicate is defunct — nobody else's msg.sender matches). We donate fresh
    ///             POL to the new proxy to stand in for the never-to-arrive exit, then submit
    ///             the real L2→L1 state-sync message proof via `messenger.receiveMessage(...)`.
    ///         (B) A fresh migration of the polBalance the child accumulated since the pending
    ///             migration started. Triggered by an L1 rate push that propagates to L2 via
    ///             state sync; the child auto-balances and the new bridger burns the POL on L2.
    ///             We can't fabricate a real L2→L1 proof for the fresh burn in a fork test, so
    ///             we swap the messenger to a mock that exposes `_processMessageFromChild` and
    ///             drive the handler directly with the same payload `_handleMigration` would
    ///             have decoded.
    function test_pendingAndFreshMigrationThroughNewPolBridger() public {
        // ---------------------------------------------------------------
        //  PART A — Finalise the pending mainnet migration via real proof
        // ---------------------------------------------------------------

        vm.selectFork(networkL2);
        assertTrue(child.onGoingMigration(), "precondition: child has pending migration");
        uint256 pendingSPOL = child.backMigratingSPOL();
        require(pendingSPOL > 0, "pending migration has zero sPOL");

        vm.selectFork(networkL1);
        // Donate generously: must cover whatever polAmount the proof decodes to and still leave
        // at least `convertSPOLtoPOL(pendingSPOL) + 1` for the messenger's internal buySPOL.
        // Anything extra stays in the bridger until rescued.
        uint256 donationPOL = controller.convertSPOLtoPOL(pendingSPOL) * 2 + 1000 ether;
        deal(cfg.polTokenL1, d1.polBridgerProxy, donationPOL);

        uint256 prePOLMessenger = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy);
        uint256 preSPOLMessenger = sPOLToken.balanceOf(cfg.sPOLMessengerProxy);
        uint256 preControllerPOL = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLControllerProxy);
        uint256 prePredicateSPOL = sPOLToken.balanceOf(rcmERC20Predicate);

        // Submit the REAL L2→L1 state-sync proof on the real messenger. `receiveMessage` is
        // permissionless — no prank needed. It validates the proof against the mainnet
        // CheckpointManager, extracts the original migration request, and runs
        // `_processMessageFromChild` → `_handleMigration`.
        bytes memory proof = vm.parseJsonBytes(vm.readFile("script/upgrades/UpgradePolBridgerProof.json"), ".proof");
        vm.recordLogs();
        messenger.receiveMessage(proof);
        Vm.Log[] memory pendingLogs = vm.getRecordedLogs();

        // Pull the proof-decoded amounts straight out of the MigrationProcessed event.
        uint256 emittedPOL;
        uint256 emittedSPOL;
        bool foundProcessed;
        for (uint256 i = 0; i < pendingLogs.length; i++) {
            if (pendingLogs[i].topics[0] == keccak256("MigrationProcessed(uint256,uint256)")) {
                (emittedPOL, emittedSPOL) = abi.decode(pendingLogs[i].data, (uint256, uint256));
                foundProcessed = true;
                break;
            }
        }
        assertTrue(foundProcessed, "MigrationProcessed event missing");
        assertEq(emittedSPOL, pendingSPOL, "proof-decoded sPOL must match child.backMigratingSPOL");

        // Bridger relinquished exactly the proof's polAmount; the residual is our overpaid
        // donation. Messenger consumed `convertSPOLtoPOL(sPOL)+1` and forwarded the rest to the
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
        // The controller picked up the surplus POL. The staked portion may have flowed through
        // to the StakeManager already, so we only assert the upper bound.
        uint256 controllerPOLDelta = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLControllerProxy) - preControllerPOL;
        assertLe(controllerPOLDelta, emittedPOL, "controller POL delta cannot exceed polAmount");
        // The sPOL the messenger minted + deposited must have landed at the predicate (the
        // destination for `rootChainManager.depositFor` deposits on L1).
        assertEq(
            sPOLToken.balanceOf(rcmERC20Predicate),
            prePredicateSPOL + pendingSPOL,
            "predicate did not receive deposited sPOL"
        );

        // ChildChainManager callback closes the pending migration on L2 (no admin action — the
        // bridge does this automatically after `rootChainManager.depositFor` lands).
        vm.selectFork(networkL2);
        vm.prank(child.childChainManager());
        child.deposit(address(child), abi.encode(pendingSPOL));
        assertFalse(child.onGoingMigration(), "pending migration did not close on L2");
        assertEq(child.backMigratingSPOL(), 0, "backMigratingSPOL not cleared");

        // ---------------------------------------------------------------
        //  PART B — Swap messenger to mock for the fresh-migration cycle
        // ---------------------------------------------------------------
        // We can't generate a real L2→L1 checkpoint proof for a freshly-burnt L2 migration in
        // a fork test, so we replace the messenger impl with a bytecode-identical mock that
        // exposes `_processMessageFromChild`. Storage (including polBridger) is preserved.

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
        MocksPOLMessenger mockMessenger = MocksPOLMessenger(cfg.sPOLMessengerProxy);

        // ---------------------------------------------------------------
        //  PART C — Trigger fresh migration via L1 rate push → L2 delivery
        // ---------------------------------------------------------------
        // Production trigger: admin pushes a fresh exchange rate on L1; state sync delivers it
        // to L2; child._handleExchangeRateUpdate calls _balanceWithL1 internally, which spots
        // the non-zero polBalance accumulated during the stuck period and fires the migration.

        vm.selectFork(networkL2);
        uint256 freshPOL = child.polBalance();
        uint256 freshSPOL = child.locallyMintedSPOL();
        require(freshPOL > 0 && freshSPOL > 0, "expected accumulated state after pending migration");
        assertFalse(child.onGoingMigration(), "should be clear after pending finalise");
        assertEq(address(child.polBridger()), d2.polBridgerProxy, "child not wired to new proxy");

        vm.selectFork(networkL1);
        vm.recordLogs();
        vm.prank(admin);
        messenger.updateL2ExchangeRate();
        Vm.Log[] memory rateLogs = vm.getRecordedLogs();

        // Pull the StateSynced payload — the bytes the bridge would relay to onStateReceive.
        bytes memory stateSyncData;
        {
            for (uint256 i = 0; i < rateLogs.length; i++) {
                if (rateLogs[i].topics[0] == keccak256("StateSynced(uint256,address,bytes)")) {
                    stateSyncData = abi.decode(rateLogs[i].data, (bytes));
                    break;
                }
            }
            require(stateSyncData.length > 0, "no StateSynced captured from updateL2ExchangeRate");
        }

        vm.selectFork(networkL2);
        vm.recordLogs();
        // stateSyncerL2 is the Polygon bridge system caller — only address that can invoke
        // onStateReceive. Pranking it simulates the bridge's automatic delivery.
        vm.prank(cfg.stateSyncerL2);
        child.onStateReceive(0, stateSyncData);
        Vm.Log[] memory burnLogs = vm.getRecordedLogs();

        assertTrue(child.onGoingMigration(), "fresh migration should be ongoing");
        assertEq(child.backMigratingSPOL(), freshSPOL, "backMigratingSPOL mismatch");
        assertEq(child.polBalance(), 0, "polBalance should drain into migration");
        assertEq(child.locallyMintedSPOL(), 0, "locallyMintedSPOL should drain into migration");

        // Confirm the bridger actually burned via MRC20.withdraw, MigrationRequested emitted
        // with the expected amounts, and capture the MessageSent payload — that's the exact
        // bytes a real L1 `receiveMessage(proof)` call would deliver to `_handleMigration`
        // after a checkpoint, so reusing it in Part D exercises the encoding/decoding path
        // end-to-end instead of a hand-rolled payload.
        bytes memory burntStateSyncMessage;
        {
            bool foundReq;
            bool foundBurn;
            bool foundMessage;
            for (uint256 i = 0; i < burnLogs.length; i++) {
                if (burnLogs[i].topics[0] == keccak256("MigrationRequested(uint256,uint256)")) {
                    (uint256 reqPOL, uint256 reqSPOL) = abi.decode(burnLogs[i].data, (uint256, uint256));
                    assertEq(reqPOL, freshPOL, "MigrationRequested POL");
                    assertEq(reqSPOL, freshSPOL, "MigrationRequested sPOL");
                    foundReq = true;
                }
                if (
                    burnLogs[i].emitter == cfg.polTokenL2
                        && burnLogs[i].topics[0] == keccak256("Withdraw(address,address,uint256,uint256,uint256)")
                ) {
                    foundBurn = true;
                }
                if (burnLogs[i].topics[0] == keccak256("MessageSent(bytes)")) {
                    burntStateSyncMessage = abi.decode(burnLogs[i].data, (bytes));
                    foundMessage = true;
                }
            }
            assertTrue(foundReq, "MigrationRequested event missing");
            assertTrue(foundBurn, "MRC20 Withdraw (POL burn) event not emitted");
            assertTrue(foundMessage, "MessageSent (L2->L1 state-sync payload) not emitted");
        }

        // ---------------------------------------------------------------
        //  PART D — Process fresh migration on L1 via mock messenger
        // ---------------------------------------------------------------

        vm.selectFork(networkL1);
        // Snapshot pre-balances and run the handler. Wrapped in a block so the snapshot vars
        // don't extend the parent scope (avoids stack-too-deep). Bridger pre-balance includes
        // Part A's leftover donation (donationPOL - emittedPOL); we top it up by exactly
        // `freshPOL` so takePOLL1 pulls only the new migration's amount and Part A's residual
        // stays where it was.
        {
            uint256 preBridgerPOLFresh = IERC20(cfg.polTokenL1).balanceOf(d1.polBridgerProxy);
            deal(cfg.polTokenL1, d1.polBridgerProxy, preBridgerPOLFresh + freshPOL);
            uint256 prePredicateSPOLFresh = sPOLToken.balanceOf(rcmERC20Predicate);
            uint256 preSPOLMessengerFresh = sPOLToken.balanceOf(cfg.sPOLMessengerProxy);
            uint256 prePOLMessengerFresh = IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy);

            // Drive the messenger handler with the EXACT bytes the child's BaseChildTunnel
            // emitted in Part C — this is the payload that `messenger.receiveMessage(proof)`
            // would extract and forward to `_processMessageFromChild` on a real L2→L1
            // checkpoint.
            vm.recordLogs();
            mockMessenger.expose_processMessageFromChild(burntStateSyncMessage);

            assertEq(
                IERC20(cfg.polTokenL1).balanceOf(d1.polBridgerProxy),
                preBridgerPOLFresh,
                "bridger residual mismatch (takePOLL1 should take exactly freshPOL)"
            );
            assertEq(
                IERC20(cfg.polTokenL1).balanceOf(cfg.sPOLMessengerProxy), prePOLMessengerFresh, "messenger POL drifted"
            );
            assertEq(sPOLToken.balanceOf(cfg.sPOLMessengerProxy), preSPOLMessengerFresh, "messenger sPOL drifted");
            assertEq(
                sPOLToken.balanceOf(rcmERC20Predicate),
                prePredicateSPOLFresh + freshSPOL,
                "predicate did not receive deposited sPOL"
            );
        }
        // Confirm MigrationProcessed event matches the fresh migration amounts.
        Vm.Log[] memory processedLogs = vm.getRecordedLogs();
        bool foundFreshProcessed;
        for (uint256 i = 0; i < processedLogs.length; i++) {
            if (processedLogs[i].topics[0] == keccak256("MigrationProcessed(uint256,uint256)")) {
                (uint256 emittedFreshPOL, uint256 emittedFreshSPOL) =
                    abi.decode(processedLogs[i].data, (uint256, uint256));
                assertEq(emittedFreshPOL, freshPOL, "MigrationProcessed POL mismatch");
                assertEq(emittedFreshSPOL, freshSPOL, "MigrationProcessed sPOL mismatch");
                foundFreshProcessed = true;
            }
        }
        assertTrue(foundFreshProcessed, "MigrationProcessed event missing");

        // ---------------------------------------------------------------
        //  PART E — Close fresh migration on L2 via ChildChainManager
        // ---------------------------------------------------------------

        vm.selectFork(networkL2);
        uint256 supplyBefore = child.totalSupply();
        uint256 selfBefore = child.balanceOf(address(child));

        vm.prank(child.childChainManager());
        child.deposit(address(child), abi.encode(freshSPOL));

        assertFalse(child.onGoingMigration(), "fresh migration did not close");
        assertEq(child.backMigratingSPOL(), 0, "backMigratingSPOL should be zero");
        assertEq(child.balanceOf(address(child)), selfBefore, "child self-balance should not grow");
        assertEq(child.totalSupply(), supplyBefore, "child totalSupply should be unchanged");
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
