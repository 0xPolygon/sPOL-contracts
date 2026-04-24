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
///         at the new proxy. Flow:
///           1. On L1: deploy upgrade dummy impl, PolBridger impl, PolBridger proxy, new sPOLMessenger impl.
///           2. On L2: deploy upgrade dummy impl, PolBridger impl, PolBridger proxy, new sPOLChild impl.
///           3. Assert the proxy address is identical on both chains (Plasma bridge requirement).
///           4. Print the AccessManager calldata for the admin (Safe) to execute. No admin action is
///              broadcast by this script.
///
/// @dev    Usage:
///         forge script script/upgrades/UpgradePolBridgerToProxy.s.sol \
///             --sig "run(string)" "mainnet" --rpc-url $L1_RPC_URL --broadcast
///         Then re-run with --rpc-url $L2_RPC_URL --broadcast for L2.
///         Or use the combined entrypoint runBoth() which forks both RPCs itself.
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

        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        vm.startBroadcast(pk);
        DeployedL1 memory d1 = _deployL1(cfg);
        vm.stopBroadcast();

        vm.createSelectFork(vm.envString("L2_RPC_URL"));
        vm.startBroadcast(pk);
        DeployedL2 memory d2 = _deployL2(cfg);
        vm.stopBroadcast();

        require(d1.polBridgerProxy == d2.polBridgerProxy, "PolBridger proxy address mismatch between chains");

        _printOutput(_network, cfg, d1, d2);
    }

    /// @notice L1-only run. Useful when L2 has already been deployed or vice versa.
    function runL1(string calldata _network) external {
        Config memory cfg = _loadConfig(_network);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        DeployedL1 memory d1 = _deployL1(cfg);
        vm.stopBroadcast();

        address predictedL2Proxy = _predictProxyAddress(cfg.saltPrefix, cfg.accessManagerL2, d1.dummy);
        require(d1.polBridgerProxy == predictedL2Proxy, "PolBridger proxy L1 address != predicted L2 address");

        _printL1(_network, cfg, d1, predictedL2Proxy);
    }

    /// @notice L2-only run.
    function runL2(string calldata _network) external {
        Config memory cfg = _loadConfig(_network);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        DeployedL2 memory d2 = _deployL2(cfg);
        vm.stopBroadcast();

        address predictedL1Proxy = _predictProxyAddress(cfg.saltPrefix, cfg.accessManagerL1, d2.dummy);
        require(d2.polBridgerProxy == predictedL1Proxy, "PolBridger proxy L2 address != predicted L1 address");

        _printL2(_network, cfg, d2, predictedL1Proxy);
    }

    function _deployL1(Config memory cfg) internal returns (DeployedL1 memory d) {
        bytes32 dummySalt = _salt(cfg.saltPrefix, "pol-bridger-upgrade-dummy-v1.2");
        address predictedDummy = _computeCreate2(dummySalt, type(DummyImpl).creationCode);
        if (predictedDummy.code.length > 0) {
            console.log("  [reuse] upgrade dummy impl at", predictedDummy);
            d.dummy = predictedDummy;
        } else {
            d.dummy = address(new DummyImpl{salt: dummySalt}());
        }

        bytes32 implSalt = _salt(cfg.saltPrefix, "pol-bridger-impl-v1.2");
        bytes memory implInitCode = abi.encodePacked(
            type(PolBridger).creationCode,
            abi.encode(cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry)
        );
        address predictedImpl = _computeCreate2(implSalt, implInitCode);
        if (predictedImpl.code.length > 0) {
            console.log("  [reuse] PolBridger impl (L1) at", predictedImpl);
            d.polBridgerImpl = predictedImpl;
        } else {
            d.polBridgerImpl = address(
                new PolBridger{salt: implSalt}(
                    cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry
                )
            );
        }

        bytes32 proxySalt = _salt(cfg.saltPrefix, "pol-bridger-proxy-v1.2");
        bytes memory proxyInitCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode, abi.encode(d.dummy, cfg.accessManagerL1, "")
        );
        address predictedProxy = _computeCreate2(proxySalt, proxyInitCode);
        if (predictedProxy.code.length > 0) {
            console.log("  [reuse] PolBridger proxy (L1) at", predictedProxy);
            d.polBridgerProxy = predictedProxy;
        } else {
            d.polBridgerProxy =
                address(new TransparentUpgradeableProxy{salt: proxySalt}(d.dummy, cfg.accessManagerL1, ""));
        }
        d.polBridgerProxyAdmin = _getProxyAdmin(d.polBridgerProxy);

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

    function _deployL2(Config memory cfg) internal returns (DeployedL2 memory d) {
        bytes32 dummySalt = _salt(cfg.saltPrefix, "pol-bridger-upgrade-dummy-v1.2");
        address predictedDummy = _computeCreate2(dummySalt, type(DummyImpl).creationCode);
        if (predictedDummy.code.length > 0) {
            console.log("  [reuse] upgrade dummy impl at", predictedDummy);
            d.dummy = predictedDummy;
        } else {
            d.dummy = address(new DummyImpl{salt: dummySalt}());
        }

        bytes32 implSalt = _salt(cfg.saltPrefix, "pol-bridger-impl-v1.2");
        bytes memory implInitCode = abi.encodePacked(
            type(PolBridger).creationCode,
            abi.encode(cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry)
        );
        address predictedImpl = _computeCreate2(implSalt, implInitCode);
        if (predictedImpl.code.length > 0) {
            console.log("  [reuse] PolBridger impl (L2) at", predictedImpl);
            d.polBridgerImpl = predictedImpl;
        } else {
            d.polBridgerImpl = address(
                new PolBridger{salt: implSalt}(
                    cfg.polTokenL1, cfg.polTokenL2, cfg.maticTokenL1, cfg.chainIdL1, cfg.chainIdL2, cfg.registry
                )
            );
        }

        bytes32 proxySalt = _salt(cfg.saltPrefix, "pol-bridger-proxy-v1.2");
        bytes memory proxyInitCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode, abi.encode(d.dummy, cfg.accessManagerL2, "")
        );
        address predictedProxy = _computeCreate2(proxySalt, proxyInitCode);
        if (predictedProxy.code.length > 0) {
            console.log("  [reuse] PolBridger proxy (L2) at", predictedProxy);
            d.polBridgerProxy = predictedProxy;
        } else {
            d.polBridgerProxy =
                address(new TransparentUpgradeableProxy{salt: proxySalt}(d.dummy, cfg.accessManagerL2, ""));
        }
        d.polBridgerProxyAdmin = _getProxyAdmin(d.polBridgerProxy);

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

    function _computeCreate2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        bytes32 initCodeHash = keccak256(initCode);
        // Arachnid CREATE2 deployer — same one foundry's `{salt:}` syntax uses.
        address deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
    }

    function _predictProxyAddress(string memory saltPrefix, address accessManager, address dummy)
        internal
        pure
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(TransparentUpgradeableProxy).creationCode, abi.encode(dummy, accessManager, ""))
        );
        bytes32 salt = _salt(saltPrefix, "pol-bridger-proxy-v1.2");
        // Arachnid CREATE2 deployer address used by foundry's {salt:} syntax
        address deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
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

    function _printL1Calldata(Config memory cfg, DeployedL1 memory d1) internal pure {
        // 1. Upgrade + initialize PolBridger proxy L1. `initialize` is an initializer (not
        //    restricted), so upgradeAndCall is safe: the access check is inside the initializer
        //    modifier, not the AccessManager.
        bytes memory polBridgerInitCall =
            abi.encodeCall(PolBridger.initialize, (cfg.accessManagerL1, cfg.sPOLMessengerProxy, cfg.sPOLChildProxy));
        bytes memory polBridgerUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(d1.polBridgerProxy), d1.polBridgerImpl, polBridgerInitCall)
        );
        bytes memory polBridgerExec =
            abi.encodeCall(AccessManager.execute, (d1.polBridgerProxyAdmin, polBridgerUpgrade));

        // 2. Upgrade messenger (no call — setPolBridger is restricted so the delegatecall-from-
        //    ProxyAdmin path would fail the AccessManager check; we do it in a separate execute).
        bytes memory messengerUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(cfg.sPOLMessengerProxy), d1.sPOLMessengerImpl, "")
        );
        bytes memory messengerUpgradeExec =
            abi.encodeCall(AccessManager.execute, (cfg.sPOLMessengerProxyAdmin, messengerUpgrade));

        // 3. setPolBridger on the messenger — msg.sender inside the call is AccessManager,
        //    which the OZ AccessManager treats as authorised.
        bytes memory setBridgerCall = abi.encodeCall(sPOLMessenger.updateBridgeHelper, (d1.polBridgerProxy));
        bytes memory messengerSetExec = abi.encodeCall(AccessManager.execute, (cfg.sPOLMessengerProxy, setBridgerCall));

        console.log("--- L1 Admin calldata (execute from AccessManager %s) ---", cfg.accessManagerL1);
        console.log("");
        console.log("Step 1: upgrade + initialize PolBridger proxy");
        console.log("  Target:   %s (AccessManager L1)", cfg.accessManagerL1);
        console.log("  ProxyAdmin inner target: %s", d1.polBridgerProxyAdmin);
        console.log("  Calldata:");
        console.logBytes(polBridgerExec);
        console.log("");
        console.log("Step 2: upgrade sPOLMessenger (no call)");
        console.log("  Target:   %s (AccessManager L1)", cfg.accessManagerL1);
        console.log("  ProxyAdmin inner target: %s", cfg.sPOLMessengerProxyAdmin);
        console.log("  Calldata:");
        console.logBytes(messengerUpgradeExec);
        console.log("");
        console.log("Step 3: setPolBridger on messenger");
        console.log("  Target:   %s (AccessManager L1)", cfg.accessManagerL1);
        console.log("  Inner target: %s (sPOLMessenger proxy)", cfg.sPOLMessengerProxy);
        console.log("  Calldata:");
        console.logBytes(messengerSetExec);
        console.log("");
    }

    function _printL2Calldata(Config memory cfg, DeployedL2 memory d2) internal pure {
        bytes memory polBridgerInitCall =
            abi.encodeCall(PolBridger.initialize, (cfg.accessManagerL2, cfg.sPOLMessengerProxy, cfg.sPOLChildProxy));
        bytes memory polBridgerUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(d2.polBridgerProxy), d2.polBridgerImpl, polBridgerInitCall)
        );
        bytes memory polBridgerExec =
            abi.encodeCall(AccessManager.execute, (d2.polBridgerProxyAdmin, polBridgerUpgrade));

        bytes memory childUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(cfg.sPOLChildProxy), d2.sPOLChildImpl, "")
        );
        bytes memory childUpgradeExec = abi.encodeCall(AccessManager.execute, (cfg.sPOLChildProxyAdmin, childUpgrade));

        bytes memory setHelperCall = abi.encodeCall(sPOLChild.setBridgeHelper, (d2.polBridgerProxy));
        bytes memory childSetExec = abi.encodeCall(AccessManager.execute, (cfg.sPOLChildProxy, setHelperCall));

        console.log("--- L2 Admin calldata (execute from AccessManager %s) ---", cfg.accessManagerL2);
        console.log("");
        console.log("Step 1: upgrade + initialize PolBridger proxy");
        console.log("  Target:   %s (AccessManager L2)", cfg.accessManagerL2);
        console.log("  ProxyAdmin inner target: %s", d2.polBridgerProxyAdmin);
        console.log("  Calldata:");
        console.logBytes(polBridgerExec);
        console.log("");
        console.log("Step 2: upgrade sPOLChild (no call)");
        console.log("  Target:   %s (AccessManager L2)", cfg.accessManagerL2);
        console.log("  ProxyAdmin inner target: %s", cfg.sPOLChildProxyAdmin);
        console.log("  Calldata:");
        console.logBytes(childUpgradeExec);
        console.log("");
        console.log("Step 3: setBridgeHelper on child");
        console.log("  Target:   %s (AccessManager L2)", cfg.accessManagerL2);
        console.log("  Inner target: %s (sPOLChild proxy)", cfg.sPOLChildProxy);
        console.log("  Calldata:");
        console.logBytes(childSetExec);
        console.log("");
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
}
