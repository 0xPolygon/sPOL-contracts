// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Deploys a new sPOLChild implementation with targeted sell/withdraw pause
///         functionality and outputs the calldata needed to upgrade via the AccessManager.
/// @dev    Usage:
///         forge script script/upgrades/UpgradesPOLChildSellWithdrawPause.s.sol \
///             --sig "run(string)" "mainnet" --rpc-url $L2_RPC_URL --broadcast
///
///         Pass "mainnet" or "testnet" as the argument.
///         The script reads the matching deployment-*.json for addresses.
contract UpgradesPOLChildSellWithdrawPause is Script {
    struct Config {
        address sPOLChildProxy;
        address sPOLChildProxyAdmin;
        address accessManagerL2;
        address admin;
        address stateSyncerL2;
        bytes32 salt;
    }

    function run(string calldata _network) public {
        Config memory cfg = _loadConfig(_network);

        // --- deploy new implementation (CREATE2) ---
        vm.startBroadcast();
        sPOLChild newImpl = new sPOLChild{salt: cfg.salt}(cfg.stateSyncerL2);
        vm.stopBroadcast();

        _printOutput(_network, cfg, address(newImpl));
    }

    function _loadConfig(string calldata _network) internal view returns (Config memory cfg) {
        string memory deployJson = vm.readFile(string.concat("script/deployment-", _network, ".json"));
        string memory inputJson = vm.readFile("script/input.json");

        cfg.sPOLChildProxy = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxy");
        cfg.sPOLChildProxyAdmin = vm.parseJsonAddress(deployJson, ".sPOL_L2.sPOLChildProxyAdmin");
        cfg.accessManagerL2 = vm.parseJsonAddress(deployJson, ".sPOL_L2.accessManagerL2");

        string memory scenario = _isMainnet(_network) ? "ethereum-polygon" : "sepolia-amoy";
        string memory saltPrefix = vm.parseJsonString(inputJson, string.concat(".", scenario, ".saltPrefix"));
        cfg.stateSyncerL2 = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".stateSyncerL2"));
        cfg.admin = vm.parseJsonAddress(inputJson, string.concat(".", scenario, ".admin"));
        cfg.salt = bytes32(bytes(string.concat(saltPrefix, "spol-child-impl-v1.1")));
    }

    function _printOutput(string calldata _network, Config memory cfg, address _newImpl) internal pure {
        // --- build upgrade calldata ---
        bytes memory proxyAdminCalldata =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(cfg.sPOLChildProxy), _newImpl, ""));
        bytes memory accessManagerCalldata =
            abi.encodeCall(AccessManager.execute, (cfg.sPOLChildProxyAdmin, proxyAdminCalldata));

        console.log("=== sPOLChild Upgrade (%s) ===", _network);
        console.log("");

        console.log("--- Deployed ---");
        console.log("  New implementation: %s", _newImpl);
        console.log("");

        console.log("--- Addresses ---");
        console.log("  sPOLChildProxy:      %s", cfg.sPOLChildProxy);
        console.log("  sPOLChildProxyAdmin: %s", cfg.sPOLChildProxyAdmin);
        console.log("  AccessManager (L2):  %s", cfg.accessManagerL2);
        console.log("  Admin (Safe):        %s", cfg.admin);
        console.log("");

        console.log("--- Upgrade calldata ---");
        console.log("Target: %s (AccessManager L2)", cfg.accessManagerL2);
        console.log("Calldata (AccessManager.execute):");
        console.logBytes(accessManagerCalldata);
        console.log("");

        console.log("Inner calldata (ProxyAdmin.upgradeAndCall):");
        console.log("  Target: %s (ProxyAdmin)", cfg.sPOLChildProxyAdmin);
        console.logBytes(proxyAdminCalldata);
        console.log("");
    }

    function _isMainnet(string memory _network) internal pure returns (bool) {
        return keccak256(bytes(_network)) == keccak256(bytes("mainnet"));
    }
}
