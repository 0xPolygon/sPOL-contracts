// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {PolBridger} from "../../src/polBridger.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {sPOL} from "../../src/sPOL.sol";
import {sPOLController} from "../../src/sPOLController.sol";

import {UpgradePolBridgerToProxy} from "../../script/upgrades/UpgradePolBridgerToProxy.s.sol";

import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Registry as IRegistry} from "../../src/interfaces/IRegistry.sol";

/// @notice Forks mainnet L1 + Polygon L2 with the currently-deployed sPOL system, then performs
///         the PolBridger proxy migration exactly as the admin multisig would. Asserts the
///         post-upgrade state end-to-end.
contract PolBridgerUpgradeForkTest is Test, UpgradePolBridgerToProxy {
    uint256 internal networkL1;
    uint256 internal networkL2;

    Config internal cfg;
    DeployedL1 internal d1;
    DeployedL2 internal d2;

    // Snapshots of pre-upgrade state so we can assert preservation.
    uint256 internal preUpgradeSPOLTotalSupply;
    uint256 internal preUpgradeControllerTotalSPOL;
    uint256 internal preUpgradeControllerTotalDPOL;
    uint256 internal preUpgradeControllerFeeDPOL;
    uint256 internal preUpgradeBackfillCycle;
    uint256 internal preUpgradeMessengerPOLAllowanceToController;
    uint256 internal preUpgradeMessengerPOLAllowanceToDepositMgr;
    uint256 internal preUpgradeMessengerSPOLAllowanceToPredicate;
    uint256 internal preUpgradeChildL1SPOLBalance;
    uint256 internal preUpgradeChildL1DPOLBalance;
    uint256 internal preUpgradeChildPOLBalance;
    uint256 internal preUpgradeChildTotalSupply;
    address internal preUpgradeChildChainManager;
    address internal preUpgradeOldBridger;

    address internal admin;
    address internal rcmERC20Predicate;

    function setUp() public {
        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"));
        networkL2 = vm.createFork(vm.envString("L2_RPC_URL"));

        cfg = _loadConfig("mainnet");
        string memory inputJson = vm.readFile("script/input.json");
        admin = vm.parseJsonAddress(inputJson, ".ethereum-polygon.admin");
        rcmERC20Predicate = vm.parseJsonAddress(inputJson, ".ethereum-polygon.rcmERC20Predicate");

        // Fail early if the mainnet registry config placeholder is zero.
        require(cfg.registry != address(0), "registry address not configured in input.json");

        // Snapshot pre-upgrade state on L1.
        vm.selectFork(networkL1);
        preUpgradeSPOLTotalSupply = IERC20(cfg.sPOLProxy).totalSupply();
        sPOLController ctrl = sPOLController(cfg.sPOLControllerProxy);
        preUpgradeControllerTotalSPOL = ctrl.totalsPOLBalance();
        preUpgradeControllerTotalDPOL = ctrl.totaldPOLBalance();
        preUpgradeControllerFeeDPOL = ctrl.feedPOLBalance();
        preUpgradeBackfillCycle = sPOLMessenger(cfg.sPOLMessengerProxy).currentActiveBackfillCycle();
        // The deployed messenger exposes this as `polBridger()` (the old immutable name); call
        // it via staticcall so this file doesn't need the old ABI. Selector = bytes4(keccak256("polBridger()")).
        (bool ok, bytes memory ret) = cfg.sPOLMessengerProxy.staticcall(abi.encodeWithSelector(0xf40047a7));
        require(ok && ret.length >= 32, "could not read old messenger.polBridger()");
        preUpgradeOldBridger = abi.decode(ret, (address));
        preUpgradeMessengerPOLAllowanceToController =
            IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.sPOLControllerProxy);
        preUpgradeMessengerPOLAllowanceToDepositMgr =
            IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.depositManager);
        preUpgradeMessengerSPOLAllowanceToPredicate =
            IERC20(cfg.sPOLProxy).allowance(cfg.sPOLMessengerProxy, rcmERC20Predicate);

        // Snapshot pre-upgrade state on L2.
        vm.selectFork(networkL2);
        sPOLChild childPre = sPOLChild(payable(cfg.sPOLChildProxy));
        preUpgradeChildL1SPOLBalance = childPre.l1SPOLBalance();
        preUpgradeChildL1DPOLBalance = childPre.l1DPOLBalance();
        preUpgradeChildPOLBalance = childPre.polBalance();
        preUpgradeChildTotalSupply = childPre.totalSupply();
        preUpgradeChildChainManager = childPre.childChainManager();

        // Deploy impls + proxies on both chains, asserting the proxy address matches. The
        // test contract is the "deployer" — it owns the new ProxyAdmin transiently during
        // _deployL1/_deployL2 to run `upgradeAndCall(initialize)` + `transferOwnership` in the
        // same broadcast, leaving the proxy fully configured before the multisig acts.
        vm.selectFork(networkL1);
        d1 = _deployL1(cfg, address(this));
        vm.selectFork(networkL2);
        d2 = _deployL2(cfg, address(this));
        require(d1.polBridgerProxy != address(0), "pre-exec: L1 proxy address is zero");
        require(d1.polBridgerProxy == d2.polBridgerProxy, "pre-exec: proxy address mismatch");

        // Execute the 2-step admin plan on each chain as the multisig would.
        vm.selectFork(networkL1);
        _executeAdminPlan(cfg.accessManagerL1, _buildL1AdminPlan(cfg, d1));
        vm.selectFork(networkL2);
        _executeAdminPlan(cfg.accessManagerL2, _buildL2AdminPlan(cfg, d2));
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
    ///  Proxy deployment       ///
    ///////////////////////////////

    function test_proxyAddressesMatchAcrossChains() public view {
        assertEq(d1.polBridgerProxy, d2.polBridgerProxy, "PolBridger proxy address mismatch across chains");
    }

    /// @notice Not required by the Plasma bridge (only the proxy itself has to match) but a
    ///         useful invariant: TransparentUpgradeableProxy deploys its ProxyAdmin via CREATE
    ///         inside its constructor, so given matching proxy addresses and matching nonces
    ///         at ProxyAdmin creation (both 1 per EIP-161 on fresh deploys), the ProxyAdmins
    ///         also end up at the same address on both chains. If this ever breaks, something
    ///         upstream changed the nonce semantics and we want to know before relying on it.
    function test_proxyAdminAddressesMatchAcrossChains() public view {
        assertEq(
            d1.polBridgerProxyAdmin, d2.polBridgerProxyAdmin, "PolBridger ProxyAdmin address mismatch across chains"
        );
    }

    function test_proxyAddressIsNewNotOldBridger() public view {
        // We must NOT be reusing the old non-proxy PolBridger at 0x7166...06E8.
        assertTrue(d1.polBridgerProxy != preUpgradeOldBridger, "new proxy collides with old PolBridger");
    }

    function test_proxyAddressPredictionMatches() public view {
        address predicted = _predictProxyAddress(cfg.saltPrefix, address(this), d1.dummy);
        assertEq(predicted, d1.polBridgerProxy, "prediction != L1 deploy");
        address predictedL2 = _predictProxyAddress(cfg.saltPrefix, address(this), d2.dummy);
        assertEq(predictedL2, d2.polBridgerProxy, "prediction != L2 deploy");
    }

    function test_dummyAddressesMatchAcrossChains() public view {
        assertEq(d1.dummy, d2.dummy, "dummy address mismatch across chains");
    }

    function test_implSlotsPointAtNewImpls_L1() public {
        vm.selectFork(networkL1);
        assertEq(_implOf(d1.polBridgerProxy), d1.polBridgerImpl, "PolBridger L1 impl slot wrong");
        assertEq(_implOf(cfg.sPOLMessengerProxy), d1.sPOLMessengerImpl, "sPOLMessenger impl slot wrong");
    }

    function test_implSlotsPointAtNewImpls_L2() public {
        vm.selectFork(networkL2);
        assertEq(_implOf(d2.polBridgerProxy), d2.polBridgerImpl, "PolBridger L2 impl slot wrong");
        assertEq(_implOf(cfg.sPOLChildProxy), d2.sPOLChildImpl, "sPOLChild impl slot wrong");
    }

    function test_proxyAdminsOwnedByAccessManagers() public {
        vm.selectFork(networkL1);
        assertEq(ProxyAdmin(d1.polBridgerProxyAdmin).owner(), cfg.accessManagerL1, "L1 PolBridger ProxyAdmin owner");
        vm.selectFork(networkL2);
        assertEq(ProxyAdmin(d2.polBridgerProxyAdmin).owner(), cfg.accessManagerL2, "L2 PolBridger ProxyAdmin owner");
    }

    /// @notice End-to-end: the script's post-upgrade verification functions must pass against
    ///         the forked, post-admin-execution state. Any break in impl deployment, proxy
    ///         impl slot, PolBridger state, ProxyAdmin ownership, or polBridger wiring will
    ///         revert inside these calls.
    function test_verifyL1_succeedsOnPostUpgradeState() public {
        vm.selectFork(networkL1);
        this.verifyL1("mainnet", d1.polBridgerProxy);
    }

    function test_verifyL2_succeedsOnPostUpgradeState() public {
        vm.selectFork(networkL2);
        this.verifyL2("mainnet", d2.polBridgerProxy);
    }

    ///////////////////////////////
    ///  PolBridger state       ///
    ///////////////////////////////

    function test_polBridgerImmutables_L1() public {
        vm.selectFork(networkL1);
        PolBridger b = PolBridger(d1.polBridgerProxy);
        assertEq(b.polTokenL1(), cfg.polTokenL1, "polTokenL1");
        assertEq(b.polTokenL2(), cfg.polTokenL2, "polTokenL2");
        assertEq(b.maticTokenL1(), cfg.maticTokenL1, "maticTokenL1");
        assertEq(b.chainIDL1(), cfg.chainIdL1, "chainIDL1");
        assertEq(b.chainIDL2(), cfg.chainIdL2, "chainIDL2");
        assertEq(b.registry(), cfg.registry, "registry");
    }

    function test_polBridgerImmutables_L2() public {
        vm.selectFork(networkL2);
        PolBridger b = PolBridger(d2.polBridgerProxy);
        assertEq(b.polTokenL1(), cfg.polTokenL1, "polTokenL1");
        assertEq(b.polTokenL2(), cfg.polTokenL2, "polTokenL2");
        assertEq(b.maticTokenL1(), cfg.maticTokenL1, "maticTokenL1");
        assertEq(b.chainIDL1(), cfg.chainIdL1, "chainIDL1");
        assertEq(b.chainIDL2(), cfg.chainIdL2, "chainIDL2");
        assertEq(b.registry(), cfg.registry, "registry");
    }

    function test_polBridgerMessengersSet_L1() public {
        vm.selectFork(networkL1);
        PolBridger b = PolBridger(d1.polBridgerProxy);
        assertEq(b.sPOLMessengerL1(), cfg.sPOLMessengerProxy, "sPOLMessengerL1");
        assertEq(b.sPOLMessengerL2(), cfg.sPOLChildProxy, "sPOLMessengerL2 (child proxy)");
        assertEq(b.authority(), cfg.accessManagerL1, "authority");
        assertFalse(b.paused(), "should start unpaused");
    }

    function test_polBridgerMessengersSet_L2() public {
        vm.selectFork(networkL2);
        PolBridger b = PolBridger(d2.polBridgerProxy);
        assertEq(b.sPOLMessengerL1(), cfg.sPOLMessengerProxy, "sPOLMessengerL1");
        assertEq(b.sPOLMessengerL2(), cfg.sPOLChildProxy, "sPOLMessengerL2 (child proxy)");
        assertEq(b.authority(), cfg.accessManagerL2, "authority");
        assertFalse(b.paused(), "should start unpaused");
    }

    function test_polBridgerCannotBeInitializedAgain_L1() public {
        vm.selectFork(networkL1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PolBridger(d1.polBridgerProxy).initialize(cfg.accessManagerL1, cfg.sPOLMessengerProxy, cfg.sPOLChildProxy);
    }

    function test_polBridgerCannotBeInitializedAgain_L2() public {
        vm.selectFork(networkL2);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PolBridger(d2.polBridgerProxy).initialize(cfg.accessManagerL2, cfg.sPOLMessengerProxy, cfg.sPOLChildProxy);
    }

    function test_polBridgerImplCannotBeInitialized_L1() public {
        vm.selectFork(networkL1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PolBridger(d1.polBridgerImpl).initialize(cfg.accessManagerL1, cfg.sPOLMessengerProxy, cfg.sPOLChildProxy);
    }

    function test_registryLookupsResolve_L1() public {
        vm.selectFork(networkL1);
        IRegistry reg = IRegistry(cfg.registry);
        address predicate = reg.erc20Predicate();
        address wm = reg.getWithdrawManagerAddress();
        assertTrue(predicate != address(0), "registry returned zero erc20 predicate");
        assertTrue(wm != address(0), "registry returned zero withdraw manager");
    }

    /// @notice This is the entire reason for the upgrade: the static erc20predicate that the old
    ///         PolBridger was deployed with no longer matches what the Registry currently reports,
    ///         which is why L1 exits were bricked. The new PolBridger reads from the Registry on
    ///         every call, so whichever value the Registry returns today is the one used.
    function test_registryErc20PredicateDiffersFromOldHardcoded() public {
        vm.selectFork(networkL1);
        address currentPredicate = IRegistry(cfg.registry).erc20Predicate();
        address oldHardcodedPredicate = 0x626fb210bf50e201ED62cA2705c16DE2a53DC966;
        assertTrue(
            currentPredicate != oldHardcodedPredicate,
            "registry predicate matches old hardcoded value; upgrade rationale invalid"
        );
    }

    function test_chainIdGuards() public {
        // bridgePOLToL1 on L1: pass the msg.sender == sPOLMessengerL2 gate by pranking the
        // stored child address; the chainid check is then the next gate to fire.
        vm.selectFork(networkL1);
        PolBridger b = PolBridger(d1.polBridgerProxy);
        vm.prank(b.sPOLMessengerL2());
        vm.expectRevert(abi.encodeWithSelector(PolBridger.InvalidOriginChain.selector, block.chainid, cfg.chainIdL2));
        b.bridgePOLToL1{value: 0}(0);

        // exitPOL / finalizeExitPOL on L2: chainid is the first gate, no prank needed.
        vm.selectFork(networkL2);
        PolBridger b2 = PolBridger(d2.polBridgerProxy);
        vm.expectRevert(abi.encodeWithSelector(PolBridger.InvalidOriginChain.selector, block.chainid, cfg.chainIdL1));
        b2.exitPOL("");
        vm.expectRevert(abi.encodeWithSelector(PolBridger.InvalidOriginChain.selector, block.chainid, cfg.chainIdL1));
        b2.finalizeExitPOL();

        // takePOLL1 on L2: pass the msg.sender == sPOLMessengerL1 gate by pranking; chainid
        // check is then the next gate to fire.
        vm.prank(b2.sPOLMessengerL1());
        vm.expectRevert(abi.encodeWithSelector(PolBridger.InvalidOriginChain.selector, block.chainid, cfg.chainIdL1));
        b2.takePOLL1(0);
    }

    ///////////////////////////////
    ///  Messenger / Child wiring
    ///////////////////////////////

    function test_messengerPointsAtNewProxy() public {
        vm.selectFork(networkL1);
        assertEq(address(sPOLMessenger(cfg.sPOLMessengerProxy).polBridger()), d1.polBridgerProxy);
    }

    function test_childPointsAtNewProxy() public {
        vm.selectFork(networkL2);
        assertEq(address(sPOLChild(payable(cfg.sPOLChildProxy)).polBridger()), d2.polBridgerProxy);
    }

    function test_updatePolBridgerOnMessenger_notCallableFromRandomCaller() public {
        vm.selectFork(networkL1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        sPOLMessenger(cfg.sPOLMessengerProxy).updatePolBridger(address(0xBEEF));
    }

    function test_updatePolBridgerOnChild_notCallableFromRandomCaller() public {
        vm.selectFork(networkL2);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        sPOLChild(payable(cfg.sPOLChildProxy)).updatePolBridger(address(0xBEEF));
    }

    function test_updatePolBridgerOnMessenger_rejectsZero() public {
        vm.selectFork(networkL1);
        vm.prank(admin);
        vm.expectRevert(sPOLMessenger.ZeroAddress.selector);
        sPOLMessenger(cfg.sPOLMessengerProxy).updatePolBridger(address(0));
    }

    function test_updatePolBridgerOnChild_rejectsZero() public {
        vm.selectFork(networkL2);
        vm.prank(admin);
        vm.expectRevert(sPOLChild.ZeroAddress.selector);
        sPOLChild(payable(cfg.sPOLChildProxy)).updatePolBridger(address(0));
    }

    function test_updatePolBridgerOnMessenger_canBeUpdated() public {
        vm.selectFork(networkL1);
        address newBridger = makeAddr("nextBridger");
        vm.prank(admin);
        sPOLMessenger(cfg.sPOLMessengerProxy).updatePolBridger(newBridger);
        assertEq(address(sPOLMessenger(cfg.sPOLMessengerProxy).polBridger()), newBridger);
    }

    ///////////////////////////////
    ///  Pre-existing state     ///
    ///////////////////////////////

    function test_preservesSPOLTotalSupply() public {
        vm.selectFork(networkL1);
        assertEq(IERC20(cfg.sPOLProxy).totalSupply(), preUpgradeSPOLTotalSupply);
    }

    function test_preservesControllerAccountingBalances() public {
        vm.selectFork(networkL1);
        sPOLController ctrl = sPOLController(cfg.sPOLControllerProxy);
        assertEq(ctrl.totalsPOLBalance(), preUpgradeControllerTotalSPOL, "totalsPOLBalance");
        assertEq(ctrl.totaldPOLBalance(), preUpgradeControllerTotalDPOL, "totaldPOLBalance");
        assertEq(ctrl.feedPOLBalance(), preUpgradeControllerFeeDPOL, "feedPOLBalance");
    }

    function test_preservesMessengerBackfillCycle() public {
        vm.selectFork(networkL1);
        assertEq(
            sPOLMessenger(cfg.sPOLMessengerProxy).currentActiveBackfillCycle(),
            preUpgradeBackfillCycle,
            "backfill cycle must not change during upgrade"
        );
    }

    /// @notice Approvals live in ERC20 contract storage (not messenger storage), but a
    ///         storage-layout regression on the messenger could corrupt the `polToken`/
    ///         `sPOLToken` immutable-looking pointers and effectively disable the allowances.
    ///         Lock them down here: post-upgrade allowances must equal pre-upgrade values.
    function test_preservesMessengerApprovals() public {
        vm.selectFork(networkL1);
        assertEq(
            IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.sPOLControllerProxy),
            preUpgradeMessengerPOLAllowanceToController,
            "polToken -> controller allowance drifted"
        );
        assertEq(
            IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.depositManager),
            preUpgradeMessengerPOLAllowanceToDepositMgr,
            "polToken -> depositManager allowance drifted"
        );
        assertEq(
            IERC20(cfg.sPOLProxy).allowance(cfg.sPOLMessengerProxy, rcmERC20Predicate),
            preUpgradeMessengerSPOLAllowanceToPredicate,
            "sPOL -> rcmERC20Predicate allowance drifted"
        );
    }

    /// @notice End-to-end regression for the messenger's storage layout post-upgrade. Probes
    ///         a synthetic `processedExits` entry, then upgrades the proxy a second time (same
    ///         bytecode, fresh deploy) and verifies the entry survived along with the new
    ///         `polBridger` slot introduced by this upgrade. Catches any accidental reorder
    ///         or slot-shift in `sPOLMessenger.sol` or its inherited chain.
    function test_preservesMessengerStorageThroughSecondUpgrade() public {
        vm.selectFork(networkL1);

        sPOLMessenger msgr = sPOLMessenger(cfg.sPOLMessengerProxy);
        bytes32 probeExitHash = keccak256("upgrade-regression-probe");
        // processedExits[probeExitHash] = true
        vm.store(cfg.sPOLMessengerProxy, keccak256(abi.encode(probeExitHash, uint256(0))), bytes32(uint256(1)));

        sPOLMessenger secondImpl = new sPOLMessenger(
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
                    (ITransparentUpgradeableProxy(cfg.sPOLMessengerProxy), address(secondImpl), "")
                )
            );

        assertTrue(msgr.processedExits(probeExitHash), "processedExits drifted");
        assertEq(address(msgr.polBridger()), d1.polBridgerProxy, "polBridger drifted");
    }

    function test_preservesChildExchangeRate() public {
        vm.selectFork(networkL2);
        sPOLChild c = sPOLChild(payable(cfg.sPOLChildProxy));
        assertEq(c.l1SPOLBalance(), preUpgradeChildL1SPOLBalance, "l1SPOLBalance");
        assertEq(c.l1DPOLBalance(), preUpgradeChildL1DPOLBalance, "l1DPOLBalance");
        assertEq(c.polBalance(), preUpgradeChildPOLBalance, "polBalance");
        assertEq(c.totalSupply(), preUpgradeChildTotalSupply, "child totalSupply");
        assertEq(c.childChainManager(), preUpgradeChildChainManager, "childChainManager");
    }
}

/// @notice Isolated slot-tracking tests. Wraps the admin plan in `vm.record()` so we can
///         enumerate exactly which storage slots the upgrade writes on the messenger and
///         child proxies — the "don't silently clobber unrelated state" guarantee.
///
///         Runs on independent forks from the main suite so `vm.record()` captures only the
///         upgrade's writes (no prior setUp admin noise). Deployer-driven PolBridger setup
///         is done pre-record; only the 2-step multisig sequence runs inside the recorder.
contract PolBridgerUpgradeSlotTrackingTest is Test, UpgradePolBridgerToProxy {
    // Storage-layout anchors — if either of these drifts, the corresponding `polBridger`
    // storage slot changes and the upgrade would write a different slot. Asserted explicitly.
    uint256 internal constant MESSENGER_BRIDGE_HELPER_SLOT = 4;
    uint256 internal constant CHILD_BRIDGE_HELPER_SLOT = 12;

    uint256 internal networkL1;
    uint256 internal networkL2;
    Config internal cfg;
    DeployedL1 internal d1;
    DeployedL2 internal d2;
    address internal admin;

    function setUp() public {
        networkL1 = vm.createFork(vm.envString("L1_RPC_URL"));
        networkL2 = vm.createFork(vm.envString("L2_RPC_URL"));

        cfg = _loadConfig("mainnet");
        admin = vm.parseJsonAddress(vm.readFile("script/input.json"), ".ethereum-polygon.admin");

        // Deploy + deployer-driven PolBridger proxy setup. Skip the admin plan here so the
        // tests can run it under vm.record().
        vm.selectFork(networkL1);
        d1 = _deployL1(cfg, address(this));
        vm.selectFork(networkL2);
        d2 = _deployL2(cfg, address(this));
    }

    function test_messengerUpgrade_writesOnlyImplAndPolBridgerSlots() public {
        vm.selectFork(networkL1);

        vm.record();
        AdminStep[] memory steps = _buildL1AdminPlan(cfg, d1);
        _runSteps(cfg.accessManagerL1, steps);
        (, bytes32[] memory writes) = vm.accesses(cfg.sPOLMessengerProxy);

        _assertOnlyExpectedSlotsWritten(writes, ERC1967_IMPL_SLOT, bytes32(MESSENGER_BRIDGE_HELPER_SLOT), "messenger");

        // Sanity: the slot we assert is actually where polBridger lives. If the storage
        // layout ever shifts polBridger to a different slot, this assertion surfaces it.
        assertEq(
            address(uint160(uint256(vm.load(cfg.sPOLMessengerProxy, bytes32(MESSENGER_BRIDGE_HELPER_SLOT))))),
            address(sPOLMessenger(cfg.sPOLMessengerProxy).polBridger()),
            "messenger polBridger slot drifted"
        );
    }

    function test_childUpgrade_writesOnlyImplAndPolBridgerSlots() public {
        vm.selectFork(networkL2);

        vm.record();
        AdminStep[] memory steps = _buildL2AdminPlan(cfg, d2);
        _runSteps(cfg.accessManagerL2, steps);
        (, bytes32[] memory writes) = vm.accesses(cfg.sPOLChildProxy);

        _assertOnlyExpectedSlotsWritten(writes, ERC1967_IMPL_SLOT, bytes32(CHILD_BRIDGE_HELPER_SLOT), "child");

        assertEq(
            address(uint160(uint256(vm.load(cfg.sPOLChildProxy, bytes32(CHILD_BRIDGE_HELPER_SLOT))))),
            address(sPOLChild(payable(cfg.sPOLChildProxy)).polBridger()),
            "child polBridger slot drifted"
        );
    }

    function _runSteps(address accessManager, AdminStep[] memory steps) internal {
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

    function _assertOnlyExpectedSlotsWritten(
        bytes32[] memory writes,
        bytes32 expectedImplSlot,
        bytes32 expectedPolBridgerSlot,
        string memory label
    ) internal pure {
        bool sawImpl;
        bool sawPolBridger;
        for (uint256 i = 0; i < writes.length; i++) {
            if (writes[i] == expectedImplSlot) {
                sawImpl = true;
            } else if (writes[i] == expectedPolBridgerSlot) {
                sawPolBridger = true;
            } else {
                // Any other slot means the upgrade touched unexpected state.
                revert(string.concat(label, " upgrade wrote unexpected slot"));
            }
        }
        require(sawImpl, string.concat(label, " upgrade did not write the ERC1967 impl slot"));
        require(sawPolBridger, string.concat(label, " upgrade did not write the polBridger slot"));
    }
}
