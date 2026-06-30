// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {ConfigLoader} from "../ConfigLoader.s.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice L1-only cleanup upgrade for sPOLMessenger: deploys a new implementation (backfill
///         removed, DepositManager demoted to a plain address) and prints the single Safe tx that
///         upgrades the proxy and runs `reinitializeV3()` to revoke the stale DepositManager POL
///         approval left over from the original `initialize`.
///
///         The ProxyAdmin is owned by the AccessManager, so the Safe tx is
///         `AccessManager.execute(proxyAdmin, ProxyAdmin.upgradeAndCall(proxy, newImpl, reinitializeV3()))`.
///
/// @dev    Usage:
///           forge script script/upgrades/UpgradeMessengerCleanup.s.sol \
///             --sig "runL1(string)" "mainnet" --rpc-url $L1_RPC_URL --broadcast
///           forge script script/upgrades/UpgradeMessengerCleanup.s.sol \
///             --sig "verifyL1(string,address)" "mainnet" <newImpl> --rpc-url $L1_RPC_URL
///         Pass "mainnet" or "testnet".
contract UpgradeMessengerCleanup is ConfigLoader {
    bytes32 internal constant ERC1967_IMPL_SLOT = hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    bytes32 internal constant ERC1967_ADMIN_SLOT =
        hex"b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

    struct Config {
        uint256 chainIdL1;
        // sPOLMessenger constructor args (must match the originally-deployed impl exactly,
        // so the immutables — including `depositManager` — are identical to production)
        address polTokenL1;
        address sPOLProxy;
        address sPOLControllerProxy;
        address rootChainManager;
        address depositManager;
        address stateSenderL1;
        address checkpointManager;
        address sPOLChildProxy;
        // upgrade targets
        address sPOLMessengerProxy;
        address sPOLMessengerProxyAdmin;
        address accessManagerL1;
        address polBridgerProxy;
        address admin; // multisig that holds ADMIN_ROLE on the AccessManager
    }

    /// @notice Deploy the new impl and print the Safe calldata. Broadcasts the deploy only.
    function runL1(string calldata network) external {
        Config memory cfg = _loadConfig(network);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        address newImpl = _deployL1(cfg);
        vm.stopBroadcast();

        _printSafeCalldata(cfg, newImpl);
    }

    /// @notice Deploy logic only — no broadcast, no env reads. This is the test-callable entry point.
    function _deployL1(Config memory cfg) internal returns (address newImpl) {
        require(block.chainid == cfg.chainIdL1, "UpgradeMessengerCleanup: wrong chain for L1 deploy");

        // Deterministic CREATE2 via the project salt setup (saltPrefix + name). "impl" is dropped
        // from the name so `saltPrefix + name` stays within getSalt's 32-byte budget on both
        // networks (the "Testnet-7-" prefix leaves only 22 chars).
        newImpl = address(
            new sPOLMessenger{salt: getSalt("spol-messenger-v1.2.1")}(
                cfg.polTokenL1,
                cfg.sPOLProxy,
                cfg.sPOLControllerProxy,
                cfg.rootChainManager,
                cfg.depositManager,
                cfg.stateSenderL1,
                cfg.checkpointManager,
                cfg.sPOLChildProxy
            )
        );
    }

    /// @notice The exact bytes the Safe submits (to = AccessManager). Pure so the fork test can
    ///         replay it verbatim against the live AccessManager.
    function _safeCalldata(Config memory cfg, address newImpl) internal pure returns (bytes memory) {
        bytes memory upgradeAndCall = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(cfg.sPOLMessengerProxy),
                newImpl,
                abi.encodeCall(sPOLMessenger.reinitializeV3, ())
            )
        );
        return abi.encodeCall(AccessManager.execute, (cfg.sPOLMessengerProxyAdmin, upgradeAndCall));
    }

    function _printSafeCalldata(Config memory cfg, address newImpl) internal pure {
        console.log("=== sPOLMessenger cleanup upgrade - Safe transaction ===");
        console.log("new sPOLMessenger impl :", newImpl);
        console.log("Safe tx target (to)    :", cfg.accessManagerL1);
        console.log("Safe tx value          : 0");
        console.log("Safe tx data           :");
        console.logBytes(_safeCalldata(cfg, newImpl));
        console.log("--------------------------------------------------------");
        console.log("After execution, run verifyL1(network, newImpl) as the sanity gate.");
    }

    /// @notice Forked rehearsal: deploy the impl, print the Safe calldata, then apply that exact
    ///         calldata against the live AccessManager on an L1 fork and assert the upgrade worked --
    ///         the stale DepositManager POL approval is revoked. No broadcast; nothing touches the
    ///         real chain. This is the self-check the operator runs before signing the real Safe tx.
    /// @dev    forge script script/upgrades/UpgradeMessengerCleanup.s.sol \
    ///           --sig "dryRunL1(string)" "mainnet"      (reads L1_RPC_URL from .env)
    function dryRunL1(string calldata network) external {
        Config memory cfg = _loadConfig(network);

        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        require(block.chainid == cfg.chainIdL1, "UpgradeMessengerCleanup: dry run on wrong chain");

        // Pre-flight: the live (old) impl's immutables + wiring must match the config we deploy from,
        // otherwise the new impl would ship with wrong immutables (e.g. a stale childTunnel).
        _assertLiveMatchesConfig(cfg);

        // Deploy the new impl exactly as runL1 will, then print the Safe calldata, apply, and verify.
        address newImpl = _deployL1(cfg);
        _dryRunApplyAndVerify(cfg, newImpl);
    }

    /// @notice Like dryRunL1 but for an ALREADY-DEPLOYED impl: validates the provided impl was built
    ///         from the expected config, prints the Safe calldata for it, then forks/applies/verifies.
    ///         Use after the impl has been broadcast (e.g. by runL1) to produce the Safe tx and
    ///         rehearse it without redeploying.
    /// @dev    forge script script/upgrades/UpgradeMessengerCleanup.s.sol \
    ///           --sig "dryRunWithImplL1(string,address)" "mainnet" <newImpl>
    function dryRunWithImplL1(string calldata network, address newImpl) external {
        Config memory cfg = _loadConfig(network);

        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        require(block.chainid == cfg.chainIdL1, "UpgradeMessengerCleanup: dry run on wrong chain");

        // The provided impl must exist on this chain and be a messenger built from the same config
        // (catches a wrong/foreign address before it's ever wired into the proxy).
        require(newImpl.code.length > 0, "dryRunWithImplL1: newImpl has no code on this chain");
        _assertImmutablesMatchConfig(newImpl, cfg);

        // Pre-flight: the live (old) impl + wiring must match config too.
        _assertLiveMatchesConfig(cfg);

        _dryRunApplyAndVerify(cfg, newImpl);
    }

    /// @notice Shared by dryRunL1 / dryRunWithImplL1: prints the Safe calldata for `newImpl`, applies
    ///         it on the current fork, and asserts the DepositManager approval is revoked while the
    ///         rest of the wiring is preserved.
    function _dryRunApplyAndVerify(Config memory cfg, address newImpl) internal {
        uint256 allowanceBefore = IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.depositManager);
        console.log("DepositManager allowance before:", allowanceBefore);
        require(allowanceBefore > 0, "dry run: expected non-zero legacy DepositManager approval pre-upgrade");

        _printSafeCalldata(cfg, newImpl);

        // Apply the verbatim Safe tx: admin multisig -> AccessManager.execute(...). Prank only the
        // initial caller (the Safe); the AccessManager -> ProxyAdmin -> proxy -> reinitializeV3 chain
        // unfolds on its own.
        vm.prank(cfg.admin);
        (bool ok,) = cfg.accessManagerL1.call(_safeCalldata(cfg, newImpl));
        require(ok, "dry run: Safe upgrade calldata reverted on fork");

        // Verify the upgrade landed and the approval is revoked.
        _verifyL1(cfg, newImpl);

        // The new impl must still match config — immutables preserved, polBridger/authority/admin intact.
        _assertLiveMatchesConfig(cfg);

        // The sPOLController approval must be untouched by this upgrade.
        require(
            IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.sPOLControllerProxy) == type(uint256).max,
            "dry run: sPOLController approval changed unexpectedly"
        );
        console.log("dry run OK: upgrade applied on fork, DepositManager approval revoked.");
    }

    /// @notice Post-broadcast sanity gate: proxy points at newImpl, the immutable is wired, and the
    ///         legacy DepositManager approval is now zero. Run this after the real Safe tx executes.
    function verifyL1(string calldata network, address newImpl) external {
        Config memory cfg = _loadConfig(network);
        require(block.chainid == cfg.chainIdL1, "UpgradeMessengerCleanup: wrong chain for verify");
        _assertLiveMatchesConfig(cfg);
        _verifyL1(cfg, newImpl);
    }

    function _verifyL1(Config memory cfg, address newImpl) internal view {
        address implNow = address(uint160(uint256(vm.load(cfg.sPOLMessengerProxy, ERC1967_IMPL_SLOT))));
        require(implNow == newImpl, "verify: proxy impl slot != newImpl");

        require(
            sPOLMessenger(newImpl).depositManager() == cfg.depositManager, "verify: depositManager immutable mismatch"
        );

        require(
            IERC20(cfg.polTokenL1).allowance(cfg.sPOLMessengerProxy, cfg.depositManager) == 0,
            "verify: DepositManager approval not revoked"
        );

        console.log("verify OK: impl upgraded and DepositManager approval == 0");
    }

    /// @notice Input.json values come from the project `ConfigLoader`; deployed proxy addresses
    ///         (which ConfigLoader doesn't track) are read from `deployment-*.json`.
    /// @param network "mainnet" or "testnet"
    function _loadConfig(string memory network) internal returns (Config memory cfg) {
        string memory scenario;
        string memory depFile;
        if (keccak256(bytes(network)) == keccak256("mainnet")) {
            scenario = "ethereum-polygon";
            depFile = "script/deployment-mainnet.json";
        } else if (keccak256(bytes(network)) == keccak256("testnet")) {
            scenario = "sepolia-amoy";
            depFile = "script/deployment-testnet.json";
        } else {
            revert("UpgradeMessengerCleanup: network must be 'mainnet' or 'testnet'");
        }

        // Reuse the project ConfigLoader for all input.json-derived values (and its validation).
        loadConfigFromJson(scenario);
        cfg.chainIdL1 = chainIdL1;
        cfg.polTokenL1 = polTokenL1;
        cfg.rootChainManager = rootChainManager;
        cfg.depositManager = depositManager;
        cfg.stateSenderL1 = stateSenderL1;
        cfg.checkpointManager = checkpointManager;
        cfg.admin = admin;

        // Deployed proxy addresses live in deployment-*.json — ConfigLoader doesn't track these.
        string memory dep = vm.readFile(depFile);
        cfg.sPOLProxy = vm.parseJsonAddress(dep, ".sPOL_L1.sPOLProxy");
        cfg.sPOLControllerProxy = vm.parseJsonAddress(dep, ".sPOL_L1.sPOLControllerProxy");
        cfg.sPOLMessengerProxy = vm.parseJsonAddress(dep, ".sPOL_L1.sPOLMessengerProxy");
        cfg.sPOLMessengerProxyAdmin = vm.parseJsonAddress(dep, ".sPOL_L1.sPOLMessengerProxyAdmin");
        cfg.accessManagerL1 = vm.parseJsonAddress(dep, ".sPOL_L1.accessManagerL1");
        cfg.polBridgerProxy = vm.parseJsonAddress(dep, ".sPOL_L1.polBridgerProxy");
        cfg.sPOLChildProxy = vm.parseJsonAddress(dep, ".sPOL_L2.sPOLChildProxy");
    }

    /// @notice Asserts the 8 sPOLMessenger constructor immutables read off `messenger` (a proxy or a
    ///         raw impl address) match the loaded config. On a raw impl this proves it was built from
    ///         the expected constructor args.
    function _assertImmutablesMatchConfig(address messenger, Config memory cfg) internal view {
        sPOLMessenger m = sPOLMessenger(messenger);

        // sPOLMessenger constructor immutables
        require(address(m.polToken()) == cfg.polTokenL1, "immutable mismatch: polToken");
        require(address(m.sPOLToken()) == cfg.sPOLProxy, "immutable mismatch: sPOLToken");
        require(address(m.sPOLController()) == cfg.sPOLControllerProxy, "immutable mismatch: sPOLController");
        require(address(m.rootChainManager()) == cfg.rootChainManager, "immutable mismatch: rootChainManager");
        require(m.depositManager() == cfg.depositManager, "immutable mismatch: depositManager");

        // BaseRootTunnel immutables
        require(address(m.stateSender()) == cfg.stateSenderL1, "immutable mismatch: stateSender");
        require(address(m.checkpointManager()) == cfg.checkpointManager, "immutable mismatch: checkpointManager");
        require(m.childTunnel() == cfg.sPOLChildProxy, "immutable mismatch: childTunnel");
    }

    /// @notice Cross-checks every immutable and wired pointer the live messenger proxy exposes
    ///         against the loaded config. Run pre-upgrade it proves input.json / deployment-*.json
    ///         still match what's on chain (so the new impl, built from the same config, carries
    ///         identical immutables); run post-upgrade it confirms nothing shifted.
    function _assertLiveMatchesConfig(Config memory cfg) internal view {
        // Immutables baked into whatever impl the proxy currently delegates to.
        _assertImmutablesMatchConfig(cfg.sPOLMessengerProxy, cfg);

        sPOLMessenger m = sPOLMessenger(cfg.sPOLMessengerProxy);

        // Wired pointers / access control (storage). polBridger != 0 also proves the v2 reinitialize
        // already ran, which reinitializer(3) (reinitializeV3) silently depends on.
        require(
            address(m.polBridger()) == cfg.polBridgerProxy, "live: polBridger != polBridgerProxy (or v2 reinit not run)"
        );
        require(m.authority() == cfg.accessManagerL1, "live: authority != accessManagerL1");

        // ERC1967 proxy admin slot
        address proxyAdminNow = address(uint160(uint256(vm.load(cfg.sPOLMessengerProxy, ERC1967_ADMIN_SLOT))));
        require(proxyAdminNow == cfg.sPOLMessengerProxyAdmin, "live: proxyAdmin != sPOLMessengerProxyAdmin");

        console.log("live deployment matches config (immutables, polBridger, authority, proxyAdmin).");
    }
}
