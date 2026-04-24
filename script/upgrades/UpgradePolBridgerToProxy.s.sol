// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {DummyImpl} from "../DummyImpl.sol";
import {PolBridger} from "../../src/polBridger.sol";
import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";

import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice Migrates PolBridger from non-proxy to proxy and points the existing messenger/child
///         at the new proxy. The deployer autonomously sets up the new PolBridger proxy
///         (deploy + atomically upgrade-and-initialise + transfer ProxyAdmin ownership to the
///         AccessManager), then prints a 2-step multisig plan per chain — 4 Safe txs total.
///
///         Flow on each chain:
///           1. Deploy upgrade dummy impl, PolBridger impl, and PolBridger proxy (deployer is
///              the ProxyAdmin's initial owner so it can self-drive the next two steps).
///           2. `proxyAdmin.upgradeAndCall(proxy, polBridgerImpl, initialize(...))` — swaps
///              the dummy impl for the real one and runs initialize in one call.
///           3. `proxyAdmin.transferOwnership(accessManager)` — hands over upgrade rights.
///           4. Deploy new sPOLMessenger impl (L1) / new sPOLChild impl (L2) via CREATE2.
///           5. Assert the PolBridger proxy address matches across L1/L2 (Plasma requirement).
///           6. Print the remaining multisig calldata: upgrade messenger/child + updateBridgeHelper.
///
/// @dev    Usage:
///         forge script script/upgrades/UpgradePolBridgerToProxy.s.sol \
///             --sig "runBoth(string)" "mainnet" --broadcast
///         (forks both RPCs from L1_RPC_URL / L2_RPC_URL)
///
///         Pass "mainnet" or "testnet" as the argument.
contract UpgradePolBridgerToProxy is Script {
    struct Config {
        address polTokenL1;
        address polTokenL2;
        address maticTokenL1;
        uint256 chainIdL1;
        uint256 chainIdL2;
        address registry;
        address stateSyncerL2;
        string saltPrefix;
        // deployed addresses
        address accessManagerL1;
        address accessManagerL2;
        address sPOLProxy;
        address sPOLControllerProxy;
        address sPOLMessengerProxy;
        address sPOLMessengerProxyAdmin;
        address sPOLChildProxy;
        address sPOLChildProxyAdmin;
        address rootChainManager;
        address depositManager;
        address stateSenderL1;
        address checkpointManager;
    }

    struct DeployedL1 {
        address dummy;
        address polBridgerImpl;
        address polBridgerProxy;
        address polBridgerProxyAdmin;
        address sPOLMessengerImpl;
    }

    struct DeployedL2 {
        address dummy;
        address polBridgerImpl;
        address polBridgerProxy;
        address polBridgerProxyAdmin;
        address sPOLChildImpl;
    }

    bytes32 internal constant PROXY_ADMIN_SLOT = hex"b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

    /// @notice Full two-chain run. Expects L1_RPC_URL and L2_RPC_URL env vars.
    function runBoth(string calldata _network) external {
        Config memory cfg = _loadConfig(_network);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        vm.startBroadcast(pk);
        DeployedL1 memory d1 = _deployL1(cfg, deployer);
        vm.stopBroadcast();

        vm.createSelectFork(vm.envString("L2_RPC_URL"));
        vm.startBroadcast(pk);
        DeployedL2 memory d2 = _deployL2(cfg, deployer);
        vm.stopBroadcast();

        require(d1.polBridgerProxy == d2.polBridgerProxy, "PolBridger proxy address mismatch between chains");

        _printOutput(_network, cfg, d1, d2);
        _recordDeploymentJsonL1(_network, d1);
        _recordDeploymentJsonL2(_network, d2);
    }

    /// @notice L1-only run. Useful when L2 has already been deployed or vice versa.
    function runL1(string calldata _network) external {
        Config memory cfg = _loadConfig(_network);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        DeployedL1 memory d1 = _deployL1(cfg, deployer);
        vm.stopBroadcast();

        address predictedL2Proxy = _predictProxyAddress(cfg.saltPrefix, deployer, d1.dummy);
        require(d1.polBridgerProxy == predictedL2Proxy, "PolBridger proxy L1 address != predicted L2 address");

        _printL1(_network, cfg, d1, predictedL2Proxy);
        _recordDeploymentJsonL1(_network, d1);
    }

    /// @notice L2-only run.
    function runL2(string calldata _network) external {
        Config memory cfg = _loadConfig(_network);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        DeployedL2 memory d2 = _deployL2(cfg, deployer);
        vm.stopBroadcast();

        address predictedL1Proxy = _predictProxyAddress(cfg.saltPrefix, deployer, d2.dummy);
        require(d2.polBridgerProxy == predictedL1Proxy, "PolBridger proxy L2 address != predicted L1 address");

        _printL2(_network, cfg, d2, predictedL1Proxy);
        _recordDeploymentJsonL2(_network, d2);
    }

    bytes32 internal constant ERC1967_IMPL_SLOT = hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

    /// @notice Post-upgrade verification for L1. Computes every expected CREATE2 address from
    ///         the config (so operator passes no impl addresses), checks each has code, then
    ///         verifies proxy impl slots, authority, wiring, ProxyAdmin ownership, PolBridger
    ///         immutables, and the messenger's bridgeHelper pointer. Mirrors the spirit of
    ///         Deploy.s.sol::_verifyDeploymentL1 for the newly-initialized contracts.
    /// @dev    Usage: forge script script/upgrades/UpgradePolBridgerToProxy.s.sol \
    ///                   --sig "verifyL1(string,address)" "mainnet" <polBridgerProxy> \
    ///                   --rpc-url $L1_RPC_URL
    ///         Pass the polBridgerProxy address printed by `runBoth`/`runL1`.
    function verifyL1(string calldata _network, address polBridgerProxyAddr) external view {
        Config memory cfg = _loadConfig(_network);

        // 1. Impl deployments: dummy, PolBridger impl, and sPOLMessenger impl must be at their
        //    predicted CREATE2 addresses. The proxy address is passed in.
        address expectedDummy =
            _computeCreate2(_salt(cfg.saltPrefix, "pol-bridger-upgrade-dummy-v1.2"), type(DummyImpl).creationCode);
        address expectedPolBridgerImpl = _computeCreate2(
            _salt(cfg.saltPrefix, "pol-bridger-impl-v1.2"),
            abi.encodePacked(
                type(PolBridger).creationCode,
                abi.encode(cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry)
            )
        );
        address expectedPolBridgerProxy = polBridgerProxyAddr;
        address expectedMessengerImpl = _expectedMessengerImplAddress(cfg);

        require(expectedDummy.code.length > 0, "upgrade dummy impl not deployed on L1");
        require(expectedPolBridgerImpl.code.length > 0, "PolBridger impl not deployed on L1");
        require(expectedPolBridgerProxy.code.length > 0, "PolBridger proxy not deployed on L1");
        require(expectedMessengerImpl.code.length > 0, "sPOLMessenger new impl not deployed on L1");

        // 2. Proxy impl slots point at the newly-deployed impls.
        require(_implOf(expectedPolBridgerProxy) == expectedPolBridgerImpl, "PolBridger proxy impl slot wrong");
        require(_implOf(cfg.sPOLMessengerProxy) == expectedMessengerImpl, "sPOLMessenger proxy impl slot wrong");

        // 3. PolBridger state + wiring.
        PolBridger bridger = PolBridger(expectedPolBridgerProxy);
        require(bridger.authority() == cfg.accessManagerL1, "PolBridger L1 authority incorrect");
        require(bridger.sPOLMessengerL1() == cfg.sPOLMessengerProxy, "PolBridger sPOLMessengerL1 incorrect");
        require(bridger.sPOLMessengerL2() == cfg.sPOLChildProxy, "PolBridger sPOLMessengerL2 (child proxy) incorrect");
        require(bridger.polTokenL1() == cfg.polTokenL1, "PolBridger polTokenL1 immutable incorrect");
        require(bridger.polTokenL2() == cfg.polTokenL2, "PolBridger polTokenL2 immutable incorrect");
        require(bridger.maticTokenL1() == cfg.maticTokenL1, "PolBridger maticTokenL1 immutable incorrect");
        require(bridger.chainIDL1() == cfg.chainIdL1, "PolBridger chainIDL1 immutable incorrect");
        require(bridger.chainIDL2() == cfg.chainIdL2, "PolBridger chainIDL2 immutable incorrect");
        require(address(bridger.registry()) == cfg.registry, "PolBridger registry immutable incorrect");
        require(!bridger.paused(), "PolBridger should not be paused post-upgrade");

        // 4. ProxyAdmin ownership.
        address proxyAdmin = _getProxyAdmin(expectedPolBridgerProxy);
        require(
            ProxyAdmin(proxyAdmin).owner() == cfg.accessManagerL1, "PolBridger L1 ProxyAdmin not owned by AccessManager"
        );

        // 5. Messenger pointer.
        require(
            address(sPOLMessenger(cfg.sPOLMessengerProxy).bridgeHelper()) == expectedPolBridgerProxy,
            "Messenger bridgeHelper not pointing at new PolBridger proxy"
        );

        console.log("L1 verification passed.");
        console.log("  PolBridger impl:        %s", expectedPolBridgerImpl);
        console.log("  PolBridger proxy:       %s", expectedPolBridgerProxy);
        console.log("  sPOLMessenger new impl: %s", expectedMessengerImpl);
    }

    /// @notice Post-upgrade verification for L2.
    /// @dev    Usage: forge script script/upgrades/UpgradePolBridgerToProxy.s.sol \
    ///                   --sig "verifyL2(string,address)" "mainnet" <polBridgerProxy> \
    ///                   --rpc-url $L2_RPC_URL
    function verifyL2(string calldata _network, address polBridgerProxyAddr) external view {
        Config memory cfg = _loadConfig(_network);

        address expectedDummy =
            _computeCreate2(_salt(cfg.saltPrefix, "pol-bridger-upgrade-dummy-v1.2"), type(DummyImpl).creationCode);
        address expectedPolBridgerImpl = _computeCreate2(
            _salt(cfg.saltPrefix, "pol-bridger-impl-v1.2"),
            abi.encodePacked(
                type(PolBridger).creationCode,
                abi.encode(cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry)
            )
        );
        address expectedPolBridgerProxy = polBridgerProxyAddr;
        address expectedChildImpl = _computeCreate2(
            _salt(cfg.saltPrefix, "spol-child-impl-v1.2"),
            abi.encodePacked(type(sPOLChild).creationCode, abi.encode(cfg.stateSyncerL2))
        );

        require(expectedDummy.code.length > 0, "upgrade dummy impl not deployed on L2");
        require(expectedPolBridgerImpl.code.length > 0, "PolBridger impl not deployed on L2");
        require(expectedPolBridgerProxy.code.length > 0, "PolBridger proxy not deployed on L2");
        require(expectedChildImpl.code.length > 0, "sPOLChild new impl not deployed on L2");

        require(_implOf(expectedPolBridgerProxy) == expectedPolBridgerImpl, "PolBridger proxy impl slot wrong");
        require(_implOf(cfg.sPOLChildProxy) == expectedChildImpl, "sPOLChild proxy impl slot wrong");

        PolBridger bridger = PolBridger(expectedPolBridgerProxy);
        require(bridger.authority() == cfg.accessManagerL2, "PolBridger L2 authority incorrect");
        require(bridger.sPOLMessengerL1() == cfg.sPOLMessengerProxy, "PolBridger sPOLMessengerL1 incorrect");
        require(bridger.sPOLMessengerL2() == cfg.sPOLChildProxy, "PolBridger sPOLMessengerL2 (child proxy) incorrect");
        require(bridger.polTokenL1() == cfg.polTokenL1, "PolBridger polTokenL1 immutable incorrect");
        require(bridger.polTokenL2() == cfg.polTokenL2, "PolBridger polTokenL2 immutable incorrect");
        require(bridger.maticTokenL1() == cfg.maticTokenL1, "PolBridger maticTokenL1 immutable incorrect");
        require(bridger.chainIDL1() == cfg.chainIdL1, "PolBridger chainIDL1 immutable incorrect");
        require(bridger.chainIDL2() == cfg.chainIdL2, "PolBridger chainIDL2 immutable incorrect");
        require(!bridger.paused(), "PolBridger should not be paused post-upgrade");

        address proxyAdmin = _getProxyAdmin(expectedPolBridgerProxy);
        require(
            ProxyAdmin(proxyAdmin).owner() == cfg.accessManagerL2, "PolBridger L2 ProxyAdmin not owned by AccessManager"
        );

        require(
            address(sPOLChild(payable(cfg.sPOLChildProxy)).bridgeHelper()) == expectedPolBridgerProxy,
            "Child bridgeHelper not pointing at new PolBridger proxy"
        );

        console.log("L2 verification passed.");
        console.log("  PolBridger impl:    %s", expectedPolBridgerImpl);
        console.log("  PolBridger proxy:   %s", expectedPolBridgerProxy);
        console.log("  sPOLChild new impl: %s", expectedChildImpl);
    }

    function _expectedMessengerImplAddress(Config memory cfg) internal pure returns (address) {
        bytes32 salt = _salt(cfg.saltPrefix, "spol-messenger-impl-v1.2");
        bytes memory initCode = abi.encodePacked(
            type(sPOLMessenger).creationCode,
            abi.encode(
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
        return _computeCreate2(salt, initCode);
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPL_SLOT))));
    }

    function _deployL1(Config memory cfg, address deployer) internal returns (DeployedL1 memory d) {
        d.dummy = _deployOrReuseDummy(cfg);
        d.polBridgerImpl = _deployOrReusePolBridgerImpl(cfg);
        d.polBridgerProxy = _deployOrReusePolBridgerProxy(cfg, deployer, d.dummy);
        d.polBridgerProxyAdmin = _getProxyAdmin(d.polBridgerProxy);

        // Deployer owns the ProxyAdmin. Atomically upgrade dummy -> real impl + initialize,
        // then hand the ProxyAdmin to the AccessManager. Multisig only has to deal with the
        // messenger impl swap + bridgeHelper pointer afterwards.
        _finaliseBridger(
            d.polBridgerProxy,
            d.polBridgerProxyAdmin,
            d.polBridgerImpl,
            cfg.accessManagerL1,
            cfg.sPOLMessengerProxy,
            cfg.sPOLChildProxy
        );

        d.sPOLMessengerImpl = _deployMessengerImpl(cfg);
    }

    function _deployMessengerImpl(Config memory cfg) internal returns (address) {
        bytes32 salt = _salt(cfg.saltPrefix, "spol-messenger-impl-v1.2");
        bytes memory initCode = abi.encodePacked(
            type(sPOLMessenger).creationCode,
            abi.encode(
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
        address predicted = _computeCreate2(salt, initCode);
        if (predicted.code.length > 0) {
            console.log("  [reuse] sPOLMessenger impl at", predicted);
            return predicted;
        }
        return address(
            new sPOLMessenger{salt: salt}(
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

    function _deployL2(Config memory cfg, address deployer) internal returns (DeployedL2 memory d) {
        d.dummy = _deployOrReuseDummy(cfg);
        d.polBridgerImpl = _deployOrReusePolBridgerImpl(cfg);
        d.polBridgerProxy = _deployOrReusePolBridgerProxy(cfg, deployer, d.dummy);
        d.polBridgerProxyAdmin = _getProxyAdmin(d.polBridgerProxy);

        _finaliseBridger(
            d.polBridgerProxy,
            d.polBridgerProxyAdmin,
            d.polBridgerImpl,
            cfg.accessManagerL2,
            cfg.sPOLMessengerProxy,
            cfg.sPOLChildProxy
        );

        bytes32 childSalt = _salt(cfg.saltPrefix, "spol-child-impl-v1.2");
        bytes memory childInitCode = abi.encodePacked(type(sPOLChild).creationCode, abi.encode(cfg.stateSyncerL2));
        address predictedChild = _computeCreate2(childSalt, childInitCode);
        if (predictedChild.code.length > 0) {
            console.log("  [reuse] sPOLChild impl at", predictedChild);
            d.sPOLChildImpl = predictedChild;
        } else {
            d.sPOLChildImpl = address(new sPOLChild{salt: childSalt}(cfg.stateSyncerL2));
        }
    }

    function _deployOrReuseDummy(Config memory cfg) internal returns (address) {
        bytes32 dummySalt = _salt(cfg.saltPrefix, "pol-bridger-upgrade-dummy-v1.2");
        address predicted = _computeCreate2(dummySalt, type(DummyImpl).creationCode);
        if (predicted.code.length > 0) {
            console.log("  [reuse] upgrade dummy impl at", predicted);
            return predicted;
        }
        return address(new DummyImpl{salt: dummySalt}());
    }

    function _deployOrReusePolBridgerImpl(Config memory cfg) internal returns (address) {
        bytes32 salt = _salt(cfg.saltPrefix, "pol-bridger-impl-v1.2");
        bytes memory initCode = abi.encodePacked(
            type(PolBridger).creationCode,
            abi.encode(cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry)
        );
        address predicted = _computeCreate2(salt, initCode);
        if (predicted.code.length > 0) {
            console.log("  [reuse] PolBridger impl at", predicted);
            return predicted;
        }
        return address(
            new PolBridger{salt: salt}(
                cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry
            )
        );
    }

    function _deployOrReusePolBridgerProxy(Config memory cfg, address deployer, address dummy)
        internal
        returns (address)
    {
        bytes32 salt = _salt(cfg.saltPrefix, "pol-bridger-proxy-v1.2");
        bytes memory initCode =
            abi.encodePacked(type(TransparentUpgradeableProxy).creationCode, abi.encode(dummy, deployer, ""));
        address predicted = _computeCreate2(salt, initCode);
        if (predicted.code.length > 0) {
            console.log("  [reuse] PolBridger proxy at", predicted);
            return predicted;
        }
        return address(new TransparentUpgradeableProxy{salt: salt}(dummy, deployer, ""));
    }

    /// @dev Upgrade (from dummy to real impl) + initialize the PolBridger proxy in one call,
    ///      then transfer the ProxyAdmin ownership to the AccessManager. Idempotent — checks
    ///      state before each step so reruns after a partial first run just finish what's left.
    function _finaliseBridger(
        address polBridgerProxy,
        address proxyAdmin,
        address polBridgerImpl,
        address accessManager,
        address messengerProxy,
        address childProxy
    ) internal {
        address currentImpl = address(uint160(uint256(vm.load(polBridgerProxy, ERC1967_IMPL_SLOT))));
        if (currentImpl != polBridgerImpl) {
            ProxyAdmin(proxyAdmin)
                .upgradeAndCall(
                    ITransparentUpgradeableProxy(polBridgerProxy),
                    polBridgerImpl,
                    abi.encodeCall(PolBridger.initialize, (accessManager, messengerProxy, childProxy))
                );
            console.log("  PolBridger proxy upgraded + initialized.");
        } else {
            console.log("  [skip] PolBridger proxy impl already up to date.");
        }

        address currentOwner = ProxyAdmin(proxyAdmin).owner();
        if (currentOwner != accessManager) {
            ProxyAdmin(proxyAdmin).transferOwnership(accessManager);
            console.log("  PolBridger ProxyAdmin ownership transferred to AccessManager.");
        } else {
            console.log("  [skip] PolBridger ProxyAdmin already owned by AccessManager.");
        }
    }

    function _computeCreate2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        bytes32 initCodeHash = keccak256(initCode);
        // Arachnid CREATE2 deployer — same one foundry's `{salt:}` syntax uses.
        address deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
    }

    /// @dev Predict the PolBridger proxy CREATE2 address. `initialOwner` is whatever was passed
    ///      to the TransparentUpgradeableProxy ctor as the ProxyAdmin's initial owner — for the
    ///      v1.2 flow, that's the deployer EOA (which then transfers ownership to AccessManager).
    function _predictProxyAddress(string memory saltPrefix, address initialOwner, address dummy)
        internal
        pure
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(TransparentUpgradeableProxy).creationCode, abi.encode(dummy, initialOwner, ""))
        );
        bytes32 salt = _salt(saltPrefix, "pol-bridger-proxy-v1.2");
        // Arachnid CREATE2 deployer address used by foundry's {salt:} syntax
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", create2Deployer, salt, initCodeHash)))));
    }

    function _printOutput(string calldata _network, Config memory cfg, DeployedL1 memory d1, DeployedL2 memory d2)
        internal
        pure
    {
        console.log("=== PolBridger proxy migration (%s) ===", _network);
        console.log("");
        console.log("--- Deployed L1 ---");
        console.log("  PolBridger impl:        %s", d1.polBridgerImpl);
        console.log("  PolBridger proxy:       %s", d1.polBridgerProxy);
        console.log("  PolBridger proxyAdmin:  %s", d1.polBridgerProxyAdmin);
        console.log("  sPOLMessenger new impl: %s", d1.sPOLMessengerImpl);
        console.log("");
        console.log("--- Deployed L2 ---");
        console.log("  PolBridger impl:        %s", d2.polBridgerImpl);
        console.log("  PolBridger proxy:       %s", d2.polBridgerProxy);
        console.log("  PolBridger proxyAdmin:  %s", d2.polBridgerProxyAdmin);
        console.log("  sPOLChild new impl:     %s", d2.sPOLChildImpl);
        console.log("");

        _printL1Calldata(cfg, d1);
        _printL2Calldata(cfg, d2);
    }

    function _printL1(string calldata _network, Config memory cfg, DeployedL1 memory d1, address predictedL2Proxy)
        internal
        pure
    {
        console.log("=== PolBridger proxy migration L1 (%s) ===", _network);
        console.log("");
        console.log("--- Deployed L1 ---");
        console.log("  PolBridger impl:        %s", d1.polBridgerImpl);
        console.log("  PolBridger proxy:       %s", d1.polBridgerProxy);
        console.log("  PolBridger proxyAdmin:  %s", d1.polBridgerProxyAdmin);
        console.log("  sPOLMessenger new impl: %s", d1.sPOLMessengerImpl);
        console.log("  Predicted L2 proxy:     %s", predictedL2Proxy);
        console.log("");
        _printL1Calldata(cfg, d1);
    }

    function _printL2(string calldata _network, Config memory cfg, DeployedL2 memory d2, address predictedL1Proxy)
        internal
        pure
    {
        console.log("=== PolBridger proxy migration L2 (%s) ===", _network);
        console.log("");
        console.log("--- Deployed L2 ---");
        console.log("  PolBridger impl:        %s", d2.polBridgerImpl);
        console.log("  PolBridger proxy:       %s", d2.polBridgerProxy);
        console.log("  PolBridger proxyAdmin:  %s", d2.polBridgerProxyAdmin);
        console.log("  sPOLChild new impl:     %s", d2.sPOLChildImpl);
        console.log("  Predicted L1 proxy:     %s", predictedL1Proxy);
        console.log("");
        _printL2Calldata(cfg, d2);
    }

    /// @notice One admin-multisig action. `target`/`data` is the call the Safe should make.
    ///         When `viaAccessManager` is true (required for ProxyAdmin upgrades, since the
    ///         ProxyAdmin is `onlyOwner`-gated by the AccessManager), the Safe sends
    ///         `AccessManager.execute(target, data)` — `target` is then the *inner* target
    ///         (the ProxyAdmin). When false, the Safe calls `target.data` directly — admin
    ///         has ADMIN_ROLE so `canCall` passes without the extra hop.
    struct AdminStep {
        address target;
        bytes data;
        string label;
        bool viaAccessManager;
    }

    /// @dev Builds the two-step admin plan for L1. Consumed by both the print path and the
    ///      fork tests so a change in the plan can't desync the two.
    function _buildL1AdminPlan(Config memory cfg, DeployedL1 memory d1)
        internal
        pure
        returns (AdminStep[] memory steps)
    {
        // The PolBridger proxy is fully configured by the deployer before the multisig acts
        // (upgrade-from-dummy + initialize + ProxyAdmin ownership transfer). The multisig's
        // only job is the 2-step wiring on the existing messenger proxy.
        steps = new AdminStep[](2);
        // 1. Upgrade messenger impl (ProxyAdmin is onlyOwner-gated by the AccessManager → execute).
        steps[0] = AdminStep({
            target: cfg.sPOLMessengerProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(cfg.sPOLMessengerProxy), d1.sPOLMessengerImpl, "")
            ),
            label: "upgrade sPOLMessenger",
            viaAccessManager: true
        });
        // 2. Direct admin call (`restricted` check passes because admin has ADMIN_ROLE).
        steps[1] = AdminStep({
            target: cfg.sPOLMessengerProxy,
            data: abi.encodeCall(sPOLMessenger.updateBridgeHelper, (d1.polBridgerProxy)),
            label: "updateBridgeHelper on messenger",
            viaAccessManager: false
        });
    }

    function _buildL2AdminPlan(Config memory cfg, DeployedL2 memory d2)
        internal
        pure
        returns (AdminStep[] memory steps)
    {
        steps = new AdminStep[](2);
        steps[0] = AdminStep({
            target: cfg.sPOLChildProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(cfg.sPOLChildProxy), d2.sPOLChildImpl, "")
            ),
            label: "upgrade sPOLChild",
            viaAccessManager: true
        });
        steps[1] = AdminStep({
            target: cfg.sPOLChildProxy,
            data: abi.encodeCall(sPOLChild.updateBridgeHelper, (d2.polBridgerProxy)),
            label: "updateBridgeHelper on child",
            viaAccessManager: false
        });
    }

    function _printL1Calldata(Config memory cfg, DeployedL1 memory d1) internal pure {
        _printAdminPlan("L1", cfg.accessManagerL1, _buildL1AdminPlan(cfg, d1));
    }

    function _printL2Calldata(Config memory cfg, DeployedL2 memory d2) internal pure {
        _printAdminPlan("L2", cfg.accessManagerL2, _buildL2AdminPlan(cfg, d2));
    }

    function _printAdminPlan(string memory chainLabel, address accessManager, AdminStep[] memory steps) internal pure {
        console.log(string.concat("--- ", chainLabel, " Admin calldata ---"));
        console.log("  AccessManager (for steps that need it): %s", accessManager);
        console.log("");
        for (uint256 i = 0; i < steps.length; i++) {
            console.log("Step %s: %s", i + 1, steps[i].label);
            if (steps[i].viaAccessManager) {
                console.log("  Safe tx target: %s (AccessManager)", accessManager);
                console.log("  Inner target:   %s (ProxyAdmin)", steps[i].target);
                console.log("  Safe tx calldata (AccessManager.execute(target, data)):");
                console.logBytes(abi.encodeCall(AccessManager.execute, (steps[i].target, steps[i].data)));
            } else {
                console.log("  Safe tx target: %s", steps[i].target);
                console.log("  Safe tx calldata (direct admin call, no AccessManager wrap):");
                console.logBytes(steps[i].data);
            }
            console.log("");
        }
    }

    function _loadConfig(string memory _network) internal view returns (Config memory cfg) {
        string memory deployJson = vm.readFile(string.concat("script/deployment-", _network, ".json"));
        string memory inputJson = vm.readFile("script/input.json");
        string memory scenario = _isMainnet(_network) ? "ethereum-polygon" : "sepolia-amoy";

        cfg.accessManagerL1 = vm.parseJsonAddress(deployJson, ".sPOL_L1.accessManagerL1");
        cfg.accessManagerL2 = vm.parseJsonAddress(deployJson, ".sPOL_L2.accessManagerL2");
        cfg.sPOLProxy = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLProxy");
        cfg.sPOLControllerProxy = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLControllerProxy");
        cfg.sPOLMessengerProxy = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLMessengerProxy");
        cfg.sPOLMessengerProxyAdmin = vm.parseJsonAddress(deployJson, ".sPOL_L1.sPOLMessengerProxyAdmin");
        cfg.sPOLChildProxy = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxy");
        cfg.sPOLChildProxyAdmin = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxyAdmin");

        cfg.saltPrefix = vm.parseJsonString(inputJson, string.concat(".", scenario, ".saltPrefix"));
        cfg.polTokenL1 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".polTokenL1"));
        cfg.polTokenL2 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".polTokenL2"));
        cfg.maticTokenL1 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".maticTokenL1"));
        cfg.chainIdL1 = vm.parseJsonUint(inputJson, string.concat(".", scenario, ".chainIdL1"));
        cfg.chainIdL2 = vm.parseJsonUint(inputJson, string.concat(".", scenario, ".chainIdL2"));
        cfg.registry = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".registry"));
        cfg.stateSyncerL2 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".stateSyncerL2"));
        cfg.rootChainManager = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".rootChainManager"));
        cfg.depositManager = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".depositManager"));
        cfg.stateSenderL1 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".stateSenderL1"));
        cfg.checkpointManager = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".checkpointManager"));
    }

    function _getProxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, PROXY_ADMIN_SLOT))));
    }

    function _salt(string memory prefix, string memory name) internal pure returns (bytes32) {
        return bytes32(bytes(string.concat(prefix, name)));
    }

    function _isMainnet(string memory _network) internal pure returns (bool) {
        return keccak256(bytes(_network)) == keccak256(bytes("mainnet"));
    }

    /// @dev Patches the deployment JSON with the newly-deployed L1 addresses. Uses
    ///      `vm.writeJson` with a value-key (3-arg variant) so only the listed keys are
    ///      touched — the legacy `polBridger` key (pointing at the pre-upgrade non-proxy
    ///      bridger) is preserved untouched. New keys are added, existing impl/related keys
    ///      that the upgrade supersedes (`sPOLMessengerImpl`) are updated in-place.
    function _recordDeploymentJsonL1(string memory _network, DeployedL1 memory d1) internal {
        string memory path = string.concat("script/deployment-", _network, ".json");
        _writeJsonAddress(path, ".sPOL_L1.polBridgerProxy", d1.polBridgerProxy);
        _writeJsonAddress(path, ".sPOL_L1.polBridgerImpl", d1.polBridgerImpl);
        _writeJsonAddress(path, ".sPOL_L1.polBridgerProxyAdmin", d1.polBridgerProxyAdmin);
        _writeJsonAddress(path, ".sPOL_L1.sPOLMessengerImpl", d1.sPOLMessengerImpl);
        console.log("deployment JSON updated for L1:", path);
    }

    function _recordDeploymentJsonL2(string memory _network, DeployedL2 memory d2) internal {
        string memory path = string.concat("script/deployment-", _network, ".json");
        _writeJsonAddress(path, ".sPOL_L2.polBridgerProxy", d2.polBridgerProxy);
        _writeJsonAddress(path, ".sPOL_L2.polBridgerImpl", d2.polBridgerImpl);
        _writeJsonAddress(path, ".sPOL_L2.polBridgerProxyAdmin", d2.polBridgerProxyAdmin);
        _writeJsonAddress(path, ".sPOL_L2.sPOLChildImpl", d2.sPOLChildImpl);
        console.log("deployment JSON updated for L2:", path);
    }

    /// @dev `vm.writeJson` expects the value arg to be a valid JSON expression. An address
    ///      needs to be a quoted string — `"0x..."` — so we wrap here.
    function _writeJsonAddress(string memory path, string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), path, key);
    }
}
