// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {sPOLChild} from "../../src/sPOLChild.sol";
import {PolBridger} from "../../src/polBridger.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Unit tests for the messenger and child `reinitialize(address)` one-shot semantics.
///         Constructs a fresh proxy that has only had v1 `initialize` called (so `_initialized`
///         is at 1, ready to accept reinitializer(2)). Locks down:
///           - Direct calls from any caller other than the ProxyAdmin revert with OnlyProxyAdmin.
///           - Reinitialize via ProxyAdmin's upgradeAndCall succeeds and bumps `_initialized` to 2.
///           - A second reinitialize via the same path reverts with InvalidInitialization.
contract ReinitializeMessengerTest is Test {
    bytes32 internal constant ERC1967_IMPL_SLOT = hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    bytes32 internal constant PROXY_ADMIN_SLOT = hex"b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

    AccessManager internal accessManager;
    sPOLMessenger internal impl;
    TransparentUpgradeableProxy internal proxy;
    ProxyAdmin internal proxyAdmin;
    address internal admin = makeAddr("admin");
    address internal polBridger = makeAddr("polBridger");
    address internal polToken = makeAddr("polToken");
    address internal sPOLToken = makeAddr("sPOLToken");
    address internal sPOLController = makeAddr("sPOLController");
    address internal depositManager = makeAddr("depositManager");
    address internal rcmERC20Predicate = makeAddr("rcmERC20Predicate");

    function setUp() public {
        accessManager = new AccessManager(admin);

        // The messenger's initialize calls token.approve(...) on polToken / sPOLToken — those
        // are EOAs in this test, so stub the calls.
        vm.mockCall(polToken, abi.encodeWithSignature("approve(address,uint256)"), abi.encode(true));
        vm.mockCall(sPOLToken, abi.encodeWithSignature("approve(address,uint256)"), abi.encode(true));

        impl = new sPOLMessenger(
            polToken,
            sPOLToken,
            sPOLController,
            makeAddr("rootChainManager"),
            depositManager,
            makeAddr("stateSender"),
            makeAddr("checkpointManager"),
            makeAddr("childTunnel")
        );
        // Construct the proxy and run v1 initialize (no polBridger arg). _initialized = 1 after this.
        proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(sPOLMessenger.initialize, (address(accessManager), rcmERC20Predicate))
        );
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), PROXY_ADMIN_SLOT)))));
    }

    function test_reinitialize_directFromEOA_reverts() public {
        vm.expectRevert(sPOLMessenger.OnlyProxyAdmin.selector);
        sPOLMessenger(address(proxy)).reinitialize(polBridger);
    }

    function test_reinitialize_directFromAdminEOA_reverts() public {
        // Even the AccessManager admin can't bypass the ProxyAdmin gate by calling directly.
        vm.prank(admin);
        vm.expectRevert(sPOLMessenger.OnlyProxyAdmin.selector);
        sPOLMessenger(address(proxy)).reinitialize(polBridger);
    }

    function test_reinitialize_viaProxyAdmin_succeeds() public {
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLMessenger.reinitialize, (polBridger))
        );
        assertEq(address(sPOLMessenger(address(proxy)).polBridger()), polBridger);
    }

    function test_reinitialize_secondCallReverts() public {
        // First call wires polBridger and bumps _initialized to 2.
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLMessenger.reinitialize, (polBridger))
        );

        // Second call must revert with OZ Initializable's gate.
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLMessenger.reinitialize, (makeAddr("attackerBridger")))
        );

        // Pointer unchanged from the first reinitialize.
        assertEq(address(sPOLMessenger(address(proxy)).polBridger()), polBridger);
    }

    function test_reinitialize_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(sPOLMessenger.ZeroAddress.selector);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLMessenger.reinitialize, (address(0)))
        );
    }
}

contract ReinitializeChildTest is Test {
    bytes32 internal constant PROXY_ADMIN_SLOT = hex"b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

    AccessManager internal accessManager;
    sPOLChild internal impl;
    TransparentUpgradeableProxy internal proxy;
    ProxyAdmin internal proxyAdmin;
    address internal admin = makeAddr("admin");
    address internal polBridger = makeAddr("polBridger");

    function setUp() public {
        accessManager = new AccessManager(admin);
        impl = new sPOLChild(makeAddr("stateSyncer"));
        proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(sPOLChild.initialize, (address(accessManager), makeAddr("childChainManager")))
        );
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), PROXY_ADMIN_SLOT)))));
    }

    function test_reinitialize_directFromEOA_reverts() public {
        vm.expectRevert(sPOLChild.OnlyProxyAdmin.selector);
        sPOLChild(payable(address(proxy))).reinitialize(polBridger);
    }

    function test_reinitialize_viaProxyAdmin_succeeds() public {
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLChild.reinitialize, (polBridger))
        );
        assertEq(address(sPOLChild(payable(address(proxy))).polBridger()), polBridger);
    }

    function test_reinitialize_secondCallReverts() public {
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLChild.reinitialize, (polBridger))
        );

        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLChild.reinitialize, (makeAddr("attackerBridger")))
        );

        assertEq(address(sPOLChild(payable(address(proxy))).polBridger()), polBridger);
    }

    function test_reinitialize_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(sPOLChild.ZeroAddress.selector);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl),
            abi.encodeCall(sPOLChild.reinitialize, (address(0)))
        );
    }
}
