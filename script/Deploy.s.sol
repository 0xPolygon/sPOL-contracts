// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {DummyImpl} from "./DummyImpl.sol";
import {PolBridger} from "../src/polBridger.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {sPOL} from "../src/sPOL.sol";
import {sPOLController} from "../src/sPOLController.sol";
import {sPOLChild} from "../src/sPOLChild.sol";
import {sPOLMessenger} from "../src/sPOLMessenger.sol";

import {ConfigLoader} from "./ConfigLoader.s.sol";

contract Deploy is Script, ConfigLoader {
    // Deployed contracts
    sPOL public sPOLImpl;
    sPOLController public sPOLControllerImpl;
    sPOLChild public sPOLChildImpl;
    sPOLMessenger public sPOLMessengerImpl;
    PolBridger public polBridgerImplL1;
    PolBridger public polBridgerImplL2;

    TransparentUpgradeableProxy public sPOLProxy;
    TransparentUpgradeableProxy public sPOLControllerProxy;
    TransparentUpgradeableProxy public sPOLChildProxy;
    TransparentUpgradeableProxy public sPOLMessengerProxy;
    TransparentUpgradeableProxy public polBridgerProxy;

    ProxyAdmin public sPOLproxyAdmin;
    ProxyAdmin public sPOLControllerproxyAdmin;
    ProxyAdmin public sPOLChildproxyAdmin;
    ProxyAdmin public sPOLMessengerproxyAdmin;
    ProxyAdmin public polBridgerProxyAdmin;

    AccessManager public accessManagerL1;
    AccessManager public accessManagerL2;

    address precalcedsPOLChildProxyAddress;
    address dummyImplL1;
    address dummyImplL2;

    function run(string memory _scenarioName) public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        loadConfigFromJson(_scenarioName);
        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        vm.startBroadcast(pk);
        deployContractsL1(vm.addr(pk));
        vm.stopBroadcast();
        vm.createSelectFork(vm.envString("L2_RPC_URL"));
        vm.startBroadcast(pk);
        deployContractsL2(vm.addr(pk));
        vm.stopBroadcast();
        writeDeploymentInfoToJSON();
    }

    // Deploy using configuration loaded from JSON file for current chain
    function deployFromJson(address _deployer, string memory _scenarioName) public {
        loadConfigFromJson(_scenarioName);
        deployContractsL1(_deployer);
        deployContractsL2(_deployer);
    }

    function deployL1WithMockConfig(address _deployer) public {
        loadMockConfig();
        deployContractsL1(_deployer);
    }

    function deployL2WithMockConfig(address _deployer) public {
        loadMockConfig();
        deployContractsL2(_deployer);
    }

    function deployFullWithMockConfig(address _deployer) public {
        loadMockConfig();
        deployContractsL1(_deployer);
        deployContractsL2(_deployer);
    }

    function deployContractsL1(address _deployer) public {
        dummyImplL1 = address(new DummyImpl{salt: getSalt("dummy-impl")}());

        accessManagerL1 = new AccessManager{salt: getSalt("polygon-access-manager")}(_deployer);

        polBridgerImplL1 = new PolBridger{salt: getSalt("pol-bridger-impl")}(
            polTokenL1, polTokenL2, maticTokenL1, chainIdL1, chainIdL2, registry
        );

        polBridgerProxy = new TransparentUpgradeableProxy{salt: getSalt("pol-bridger-proxy")}(
            dummyImplL1, address(accessManagerL1), ""
        );
        polBridgerProxyAdmin = getProxyAdmin(polBridgerProxy);

        sPOLControllerProxy = new TransparentUpgradeableProxy{salt: getSalt("spol-controller-proxy")}(
            dummyImplL1, address(accessManagerL1), ""
        );
        sPOLControllerproxyAdmin = getProxyAdmin(sPOLControllerProxy);

        sPOLProxy =
            new TransparentUpgradeableProxy{salt: getSalt("spol-proxy")}(dummyImplL1, address(accessManagerL1), "");
        sPOLproxyAdmin = getProxyAdmin(sPOLProxy);

        sPOLMessengerProxy = new TransparentUpgradeableProxy{salt: getSalt("spol-messenger-proxy")}(
            dummyImplL1, address(accessManagerL1), ""
        );
        sPOLMessengerproxyAdmin = getProxyAdmin(sPOLMessengerProxy);

        sPOLControllerImpl = new sPOLController{salt: getSalt("spol-controller-impl")}(
            polTokenL1, maticTokenL1, polygonMigration, address(sPOLProxy), stakeManager
        );

        sPOLImpl = new sPOL{salt: getSalt("spol-impl")}(address(sPOLControllerProxy));

        precalcedsPOLChildProxyAddress = precalcsPOLChildProxyAddress();
        sPOLMessengerImpl = new sPOLMessenger{salt: getSalt("spol-messenger-impl")}(
            polTokenL1,
            address(sPOLProxy),
            address(sPOLControllerProxy),
            rootChainManager,
            depositManager,
            stateSenderL1,
            checkpointManager,
            precalcedsPOLChildProxyAddress
        );

        _configureDeploymentL1(_deployer);
    }

    function deployContractsL2(address _deployer) public {
        dummyImplL2 = address(new DummyImpl{salt: getSalt("dummy-impl")}());

        accessManagerL2 = new AccessManager{salt: getSalt("polygon-access-manager")}(_deployer);

        polBridgerImplL2 = new PolBridger{salt: getSalt("pol-bridger-impl")}(
            polTokenL1, polTokenL2, maticTokenL1, chainIdL1, chainIdL2, registry
        );
        polBridgerProxy = new TransparentUpgradeableProxy{salt: getSalt("pol-bridger-proxy")}(
            dummyImplL2, address(accessManagerL2), ""
        );
        polBridgerProxyAdmin = getProxyAdmin(polBridgerProxy);

        sPOLChildImpl = new sPOLChild{salt: getSalt("spol-child-impl")}(stateSyncerL2);
        sPOLChildProxy = new TransparentUpgradeableProxy{salt: getSalt("spol-child-proxy")}(
            dummyImplL2, address(accessManagerL2), ""
        );
        sPOLChildproxyAdmin = getProxyAdmin(sPOLChildProxy);

        _configureDeploymentL2(_deployer);
    }

    function _configureDeploymentL1(address _deployer) internal {
        // Upgrade PolBridger proxy to real impl and initialize.
        bytes memory upgradeAndCallPolBridgerData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(polBridgerProxy)),
                address(polBridgerImplL1),
                abi.encodeCall(
                    PolBridger.initialize,
                    (address(accessManagerL1), address(sPOLMessengerProxy), precalcedsPOLChildProxyAddress)
                )
            )
        );
        accessManagerL1.execute(address(polBridgerProxyAdmin), upgradeAndCallPolBridgerData);

        bytes memory upgradeAndCallsPOLdata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(sPOLProxy)), address(sPOLImpl), abi.encodeCall(sPOL.initialize, ()))
        );
        accessManagerL1.execute(address(sPOLproxyAdmin), upgradeAndCallsPOLdata);

        // Upgrade messenger and run v1 `initialize` (no polBridger arg).
        bytes memory upgradeAndCallsPOLMessengerdata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLMessengerProxy)),
                address(sPOLMessengerImpl),
                abi.encodeCall(sPOLMessenger.initialize, (address(accessManagerL1), rcmERC20Predicate))
            )
        );
        accessManagerL1.execute(address(sPOLMessengerproxyAdmin), upgradeAndCallsPOLMessengerdata);

        // Wire the PolBridger pointer via reinitialize. Must go through the ProxyAdmin so the
        // ERC1967 admin check inside `reinitialize` passes (a direct call would frontrun-vulnerable).
        bytes memory reinitMessengerData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLMessengerProxy)),
                address(sPOLMessengerImpl),
                abi.encodeCall(sPOLMessenger.reinitialize, (address(polBridgerProxy)))
            )
        );
        accessManagerL1.execute(address(sPOLMessengerproxyAdmin), reinitMessengerData);

        bytes memory upgradeAndCallsPOLControllerdata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLControllerProxy)),
                address(sPOLControllerImpl),
                abi.encodeCall(
                    sPOLController.initialize, (rewardFee, feeReceiver, maxDivergence, address(accessManagerL1))
                )
            )
        );
        accessManagerL1.execute(address(sPOLControllerproxyAdmin), upgradeAndCallsPOLControllerdata);

        if (_deployer != admin) {
            accessManagerL1.grantRole(accessManagerL1.ADMIN_ROLE(), admin, 0);
        }
        _verifyDeploymentL1();
    }

    function _configureDeploymentL2(address _deployer) internal {
        bytes memory upgradeAndCallPolBridgerData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(polBridgerProxy)),
                address(polBridgerImplL2),
                abi.encodeCall(
                    PolBridger.initialize,
                    (address(accessManagerL2), address(sPOLMessengerProxy), address(sPOLChildProxy))
                )
            )
        );
        accessManagerL2.execute(address(polBridgerProxyAdmin), upgradeAndCallPolBridgerData);

        // Upgrade child and run v1 `initialize` (no polBridger arg).
        bytes memory upgradeAndCalldata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLChildProxy)),
                address(sPOLChildImpl),
                abi.encodeCall(sPOLChild.initialize, (address(accessManagerL2), childChainManager))
            )
        );
        accessManagerL2.execute(address(sPOLChildproxyAdmin), upgradeAndCalldata);

        // Wire the PolBridger pointer via reinitialize. See L1 messenger for the rationale.
        bytes memory reinitChildData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLChildProxy)),
                address(sPOLChildImpl),
                abi.encodeCall(sPOLChild.reinitialize, (address(polBridgerProxy)))
            )
        );
        accessManagerL2.execute(address(sPOLChildproxyAdmin), reinitChildData);

        if (_deployer != admin) {
            accessManagerL2.grantRole(accessManagerL2.ADMIN_ROLE(), admin, 0);
        }
        _verifyDeploymentL2();
    }

    function writeDeploymentInfoToJSON() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/deployment.json");
        string memory json = "{";

        json = string.concat(json, '"sPOL_L1": {');
        json = string.concat(json, '"sPOLProxy": "', vm.toString(address(sPOLProxy)), '",');
        json = string.concat(json, '"sPOLImpl": "', vm.toString(address(sPOLImpl)), '",');
        json = string.concat(json, '"sPOLControllerProxy": "', vm.toString(address(sPOLControllerProxy)), '",');
        json = string.concat(json, '"sPOLControllerImpl": "', vm.toString(address(sPOLControllerImpl)), '",');
        json = string.concat(json, '"sPOLMessengerProxy": "', vm.toString(address(sPOLMessengerProxy)), '",');
        json = string.concat(json, '"sPOLMessengerImpl": "', vm.toString(address(sPOLMessengerImpl)), '",');
        json = string.concat(json, '"sPOLProxyAdmin": "', vm.toString(address(sPOLproxyAdmin)), '",');
        json =
            string.concat(json, '"sPOLControllerProxyAdmin": "', vm.toString(address(sPOLControllerproxyAdmin)), '",');
        json = string.concat(json, '"sPOLMessengerProxyAdmin": "', vm.toString(address(sPOLMessengerproxyAdmin)), '",');
        json = string.concat(json, '"accessManagerL1": "', vm.toString(address(accessManagerL1)), '",');
        json = string.concat(json, '"polBridgerProxy": "', vm.toString(address(polBridgerProxy)), '",');
        json = string.concat(json, '"polBridgerImpl": "', vm.toString(address(polBridgerImplL1)), '",');
        json = string.concat(json, '"polBridgerProxyAdmin": "', vm.toString(address(polBridgerProxyAdmin)), '"');
        json = string.concat(json, "},");

        json = string.concat(json, '"sPOL_L2": {');
        json = string.concat(json, '"sPOLChildProxy": "', vm.toString(address(sPOLChildProxy)), '",');
        json = string.concat(json, '"sPOLChildImpl": "', vm.toString(address(sPOLChildImpl)), '",');
        json = string.concat(json, '"sPOLChildProxyAdmin": "', vm.toString(address(sPOLChildproxyAdmin)), '",');
        json = string.concat(json, '"accessManagerL2": "', vm.toString(address(accessManagerL2)), '",');
        json = string.concat(json, '"polBridgerProxy": "', vm.toString(address(polBridgerProxy)), '",');
        json = string.concat(json, '"polBridgerImpl": "', vm.toString(address(polBridgerImplL2)), '",');
        json = string.concat(json, '"polBridgerProxyAdmin": "', vm.toString(address(polBridgerProxyAdmin)), '"');
        json = string.concat(json, "}");

        json = string.concat(json, "}");

        vm.writeFile(path, json);
    }

    function _verifyDeploymentL1() internal view {
        sPOL token = sPOL(address(sPOLProxy));
        sPOLController controller = sPOLController(address(sPOLControllerProxy));
        sPOLMessenger messenger = sPOLMessenger(address(sPOLMessengerProxy));
        PolBridger bridger = PolBridger(address(polBridgerProxy));

        // Verify sPOL
        require(keccak256(bytes(token.name())) == keccak256(bytes("Staked POL")), "sPOL name incorrect");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes("sPOL")), "sPOL symbol incorrect");
        require(token.sPOLController() == address(sPOLControllerProxy), "sPOL controller address incorrect");
        require(
            vm.load(address(token), hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
                == bytes32(uint256(uint160(address(sPOLImpl)))),
            "sPOL implementation address incorrect"
        );

        // Verify sPOLController
        require(controller.authority() == address(accessManagerL1), "Controller authority incorrect");
        require(address(controller.polToken()) == polTokenL1, "Controller POL token incorrect");
        require(address(controller.sPOLToken()) == address(sPOLProxy), "Controller sPOL token incorrect");
        require(controller.rewardFee() == rewardFee, "Controller reward fee incorrect");
        require(controller.feeReceiver() == feeReceiver, "Controller fee receiver incorrect");
        require(controller.maxDivergence() == maxDivergence, "Controller max divergence incorrect");
        require(
            vm.load(address(controller), hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
                == bytes32(uint256(uint160(address(sPOLControllerImpl)))),
            "sPOL implementation address incorrect"
        );

        // Verify messenger
        require(messenger.authority() == address(accessManagerL1), "Messenger authority incorrect");
        require(address(messenger.polBridger()) == address(polBridgerProxy), "Messenger polBridger incorrect");

        // Verify PolBridger (L1 side)
        require(bridger.authority() == address(accessManagerL1), "PolBridger L1 authority incorrect");
        require(bridger.sPOLMessengerL1() == address(sPOLMessengerProxy), "PolBridger sPOLMessengerL1 incorrect");
        require(
            bridger.sPOLMessengerL2() == precalcsPOLChildProxyAddress(),
            "PolBridger sPOLMessengerL2 (child proxy) incorrect"
        );

        // Verify AccessManager is the admin of every L1 proxy.
        require(sPOLproxyAdmin.owner() == address(accessManagerL1), "sPOL ProxyAdmin not owned by AccessManager");
        require(
            sPOLControllerproxyAdmin.owner() == address(accessManagerL1),
            "sPOLController ProxyAdmin not owned by AccessManager"
        );
        require(
            sPOLMessengerproxyAdmin.owner() == address(accessManagerL1),
            "sPOLMessenger ProxyAdmin not owned by AccessManager"
        );
        require(
            polBridgerProxyAdmin.owner() == address(accessManagerL1),
            "PolBridger L1 ProxyAdmin not owned by AccessManager"
        );

        // Verify the final admin multisig has ADMIN_ROLE on the AccessManager.
        (bool adminHasRoleL1,) = accessManagerL1.hasRole(accessManagerL1.ADMIN_ROLE(), admin);
        require(adminHasRoleL1, "admin (multisig) not granted ADMIN_ROLE on AccessManager L1");

        console.log("All verifications passed!");
    }

    function _verifyDeploymentL2() internal view {
        sPOLChild child = sPOLChild(payable(sPOLChildProxy));
        PolBridger bridger = PolBridger(address(polBridgerProxy));

        // Verify sPOLChild
        require(address(child) == precalcsPOLChildProxyAddress(), "sPOLChild proxy address incorrect");
        require(child.stateSyncer() == stateSyncerL2, "sPOLChild state syncer incorrect");
        require(address(child.polBridger()) == address(polBridgerProxy), "sPOLChild polBridger incorrect");
        require(child.authority() == address(accessManagerL2), "sPOLChild authority incorrect");
        require(child.childChainManager() == childChainManager, "sPOLChild child chain manager incorrect");
        require(
            vm.load(address(child), hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
                == bytes32(uint256(uint160(address(sPOLChildImpl)))),
            "sPOLChild implementation address incorrect"
        );

        // Verify PolBridger (L2 side)
        require(bridger.authority() == address(accessManagerL2), "PolBridger L2 authority incorrect");
        require(bridger.sPOLMessengerL1() == address(sPOLMessengerProxy), "PolBridger sPOLMessengerL1 incorrect");
        require(bridger.sPOLMessengerL2() == address(sPOLChildProxy), "PolBridger sPOLMessengerL2 incorrect");

        // Verify AccessManager is the admin of every L2 proxy. L2 only has two: sPOLChild
        // and polBridger (the messenger/controller/sPOL live on L1). So four admin checks
        // (authority + ProxyAdmin.owner, once per proxy) covers every L2 contract.
        require(
            sPOLChildproxyAdmin.owner() == address(accessManagerL2), "sPOLChild ProxyAdmin not owned by AccessManager"
        );
        require(
            polBridgerProxyAdmin.owner() == address(accessManagerL2),
            "PolBridger L2 ProxyAdmin not owned by AccessManager"
        );

        // Verify the final admin multisig has ADMIN_ROLE on the AccessManager.
        (bool adminHasRoleL2,) = accessManagerL2.hasRole(accessManagerL2.ADMIN_ROLE(), admin);
        require(adminHasRoleL2, "admin (multisig) not granted ADMIN_ROLE on AccessManager L2");

        // If L1 was deployed then cross-chain invariants should hold.
        if (address(accessManagerL1) != address(0)) {
            require(address(accessManagerL1) == address(accessManagerL2), "Access managers should be same");
            require(address(dummyImplL1) == address(dummyImplL2), "Dummy impls should be same");
        }
        console.log("All verifications passed for L2!");
    }

    function getProxyAdmin(TransparentUpgradeableProxy proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(
            address(
                uint160(
                    uint256(
                        vm.load(address(proxy), hex"b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103")
                    )
                )
            )
        );
    }

    function precalcsPOLChildProxyAddress() public view returns (address) {
        address accessManagerAddress;
        address dummyImplAddress;
        // in this case L1 was deployed
        if (address(accessManagerL1) != address(0)) {
            accessManagerAddress = address(accessManagerL1);
            dummyImplAddress = address(dummyImplL1);
        } else if (address(accessManagerL2) != address(0)) {
            accessManagerAddress = address(accessManagerL2);
            dummyImplAddress = address(dummyImplL2);
        } else {
            revert("Access manager not deployed");
        }
        return vm.computeCreate2Address(
            getSalt("spol-child-proxy"),
            keccak256(
                abi.encodePacked(
                    type(TransparentUpgradeableProxy).creationCode,
                    abi.encode(dummyImplAddress, address(accessManagerAddress), "")
                )
            )
        );
    }

    function getSalt(string memory _name) public view returns (bytes32) {
        return bytes32(bytes(string.concat(string(saltPrefix), _name)));
    }
}
