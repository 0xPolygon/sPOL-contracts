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

    TransparentUpgradeableProxy public sPOLProxy;
    TransparentUpgradeableProxy public sPOLControllerProxy;
    TransparentUpgradeableProxy public sPOLChildProxy;
    TransparentUpgradeableProxy public sPOLMessengerProxy;

    ProxyAdmin public sPOLproxyAdmin;
    ProxyAdmin public sPOLControllerproxyAdmin;
    ProxyAdmin public sPOLChildproxyAdmin;
    ProxyAdmin public sPOLMessengerproxyAdmin;

    AccessManager public accessManagerL1;
    AccessManager public accessManagerL2;
    PolBridger public polBridger;

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

    /// @notice Deploy both L1 and L2 contracts reading config from SPOL_* env vars.
    /// Used by the kurtosis devnet deployer.
    function runFromEnv() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        loadConfigFromEnv();
        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        vm.startBroadcast(pk);
        deployContractsL1(deployer);
        vm.stopBroadcast();
        vm.createSelectFork(vm.envString("L2_RPC_URL"));
        vm.startBroadcast(pk);
        deployContractsL2(deployer);
        vm.stopBroadcast();
        writeDeploymentInfoToJSON();
    }

    function deployL1FromEnvConfig(address _deployer) public {
        loadConfigFromEnv();
        deployContractsL1(_deployer);
    }

    function deployL2FromEnvConfig(address _deployer) public {
        loadConfigFromEnv();
        deployContractsL2(_deployer);
    }

    function deployContractsL1(address _deployer) public {
        dummyImplL1 = address(new DummyImpl{salt: getSalt("dummy-impl")}());

        accessManagerL1 = new AccessManager{salt: getSalt("polygon-access-manager")}(_deployer);

        polBridger = new PolBridger{salt: getSalt("pol-bridger")}(
            polTokenL1,
            polTokenL2,
            maticTokenL1,
            chainIdL1,
            chainIdL2,
            erc20predicate,
            withdrawManager,
            address(accessManagerL1)
        );

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
            precalcedsPOLChildProxyAddress,
            address(polBridger)
        );

        _configureDeploymentL1(_deployer);
    }

    function deployContractsL2(address _deployer) public {
        dummyImplL2 = address(new DummyImpl{salt: getSalt("dummy-impl")}());

        accessManagerL2 = new AccessManager{salt: getSalt("polygon-access-manager")}(_deployer);

        polBridger = new PolBridger{salt: getSalt("pol-bridger")}(
            polTokenL1,
            polTokenL2,
            maticTokenL1,
            chainIdL1,
            chainIdL2,
            erc20predicate,
            withdrawManager,
            address(accessManagerL2)
        );
        sPOLChildImpl = new sPOLChild{salt: getSalt("spol-child-impl")}(stateSyncerL2);
        sPOLChildProxy = new TransparentUpgradeableProxy{salt: getSalt("spol-child-proxy")}(
            dummyImplL2, address(accessManagerL2), ""
        );
        sPOLChildproxyAdmin = getProxyAdmin(sPOLChildProxy);

        _configureDeploymentL2(_deployer);
    }

    function _configureDeploymentL1(address _deployer) internal {
        polBridger.initialize(address(sPOLMessengerProxy), precalcedsPOLChildProxyAddress);

        bytes memory upgradeAndCallsPOLdata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(sPOLProxy)), address(sPOLImpl), abi.encodeCall(sPOL.initialize, ()))
        );
        accessManagerL1.execute(address(sPOLproxyAdmin), upgradeAndCallsPOLdata);

        bytes memory upgradeAndCallsPOLMessengerdata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLMessengerProxy)),
                address(sPOLMessengerImpl),
                abi.encodeCall(sPOLMessenger.initialize, (address(accessManagerL1), rcmERC20Predicate))
            )
        );
        accessManagerL1.execute(address(sPOLMessengerproxyAdmin), upgradeAndCallsPOLMessengerdata);

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
        polBridger.initialize(address(sPOLMessengerProxy), address(sPOLChildProxy));

        bytes memory upgradeAndCalldata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(sPOLChildProxy)),
                address(sPOLChildImpl),
                abi.encodeCall(sPOLChild.initialize, (address(accessManagerL2), address(polBridger), childChainManager))
            )
        );
        accessManagerL2.execute(address(sPOLChildproxyAdmin), upgradeAndCalldata);

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
        json = string.concat(json, '"polBridger": "', vm.toString(address(polBridger)), '"');
        json = string.concat(json, "},");

        json = string.concat(json, '"sPOL_L2": {');
        json = string.concat(json, '"sPOLChildProxy": "', vm.toString(address(sPOLChildProxy)), '",');
        json = string.concat(json, '"sPOLChildImpl": "', vm.toString(address(sPOLChildImpl)), '",');
        json = string.concat(json, '"sPOLChildProxyAdmin": "', vm.toString(address(sPOLChildproxyAdmin)), '",');
        json = string.concat(json, '"accessManagerL2": "', vm.toString(address(accessManagerL2)), '",');
        json = string.concat(json, '"polBridger": "', vm.toString(address(polBridger)), '"');
        json = string.concat(json, "}");

        json = string.concat(json, "}");

        vm.writeFile(path, json);
    }

    function _verifyDeploymentL1() internal view {
        sPOL token = sPOL(address(sPOLProxy));
        sPOLController controller = sPOLController(address(sPOLControllerProxy));

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
        require(controller.authority() == address(accessManagerL1), "Controller admin incorrect");
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
        console.log("All verifications passed!");
    }

    function _verifyDeploymentL2() internal view {
        sPOLChild child = sPOLChild(payable(sPOLChildProxy));

        // Verify sPOLChild
        require(address(child) == precalcsPOLChildProxyAddress(), "sPOLChild proxy address incorrect");
        require(child.stateSyncer() == stateSyncerL2, "sPOLChild state syncer incorrect");
        require(address(child.bridgeHelper()) == address(polBridger), "sPOLChild bridger incorrect");
        require(child.authority() == address(accessManagerL2), "sPOLChild admin incorrect");
        require(child.childChainManager() == childChainManager, "sPOLChild child chain manager incorrect");
        require(
            vm.load(address(child), hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
                == bytes32(uint256(uint160(address(sPOLChildImpl)))),
            "sPOLChild implementation address incorrect"
        );
        require(getProxyAdmin(sPOLChildProxy).owner() == address(accessManagerL2), "sPOLChild ProxyAdmin wrong owner");
        // If L1 was deployed then addresses should match
        if (address(accessManagerL1) != address(0)) {
            require(address(accessManagerL1) == address(accessManagerL2), "Access managers should be same");
            require(address(dummyImplL1) == address(dummyImplL2), "Access managers should be same");
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
