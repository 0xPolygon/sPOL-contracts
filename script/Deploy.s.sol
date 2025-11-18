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

contract Deploy is Script {
    // Network configuration variables
    string public networkName;
    uint256 public chainIdL1;
    uint256 public chainIdL2;
    address public polTokenL1;
    address public polTokenL2;
    address public withdrawManager;
    address public erc20predicate;
    address public childChainManager;
    address public rootChainManager;
    address public stateSyncer;
    address public maticToken;
    address public polygonMigration;
    address public stakeManager;
    address public admin;
    address public feeReceiver;
    uint8 public rewardFee;
    uint8 public maxDivergence;

    // Deployed contracts
    sPOL public sPOLImpl;
    sPOLController public sPOLControllerImpl;
    TransparentUpgradeableProxy public sPOLProxy;
    TransparentUpgradeableProxy public sPOLControllerProxy;
    ProxyAdmin public sPOLproxyAdmin;
    ProxyAdmin public sPOLControllerproxyAdmin;
    AccessManager public accessManagerL1;
    AccessManager public accessManagerL2;
    PolBridger public polBridger;
    sPOLChild public sPOLChildImpl;
    sPOLMessenger public sPOLMessengerImpl;
    TransparentUpgradeableProxy public sPOLChildProxy;
    ProxyAdmin public sPOLChildproxyAdmin;
    TransparentUpgradeableProxy public sPOLMessengerProxy;
    ProxyAdmin public sPOLMessengerproxyAdmin;

    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        deployFromJson(vm.addr(pk));
        vm.stopBroadcast();
    }

    function loadMockConfig() public {
        networkName = "mock-network";
        polTokenL1 = makeAddr("polToken");
        polTokenL2 = makeAddr("polTokenL2");
        chainIdL1 = 1;
        chainIdL2 = 2;
        maticToken = makeAddr("maticToken");
        polygonMigration = makeAddr("polygonMigration");
        stakeManager = makeAddr("stakeManager");
        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        rewardFee = 100; // 10%
        maxDivergence = 10; // 10%
    }

    // Load configuration from JSON file for specific chain ID
    function loadConfigFromJson(uint256 chainId) public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/input.json");
        string memory json = vm.readFile(path);

        string memory chainIdStr = vm.toString(chainId);
        string memory networkKey = string.concat(".networks.", chainIdStr);

        // Check if network exists in JSON
        bytes memory networkData = vm.parseJson(json, networkKey);
        require(networkData.length > 0, string.concat("Network configuration not found for chain ID: ", chainIdStr));

        // Parse network configuration
        networkName = vm.parseJsonString(json, string.concat(networkKey, ".name"));
        polTokenL1 = vm.parseJsonAddress(json, string.concat(networkKey, ".polTokenL1"));
        polTokenL2 = vm.parseJsonAddress(json, string.concat(networkKey, ".polTokenL2"));
        chainIdL1 = vm.parseJsonUint(json, string.concat(networkKey, ".chainIdL1"));
        chainIdL2 = vm.parseJsonUint(json, string.concat(networkKey, ".chainIdL2"));

        maticToken = vm.parseJsonAddress(json, string.concat(networkKey, ".maticToken"));
        polygonMigration = vm.parseJsonAddress(json, string.concat(networkKey, ".polygonMigration"));
        stakeManager = vm.parseJsonAddress(json, string.concat(networkKey, ".stakeManager"));
        admin = vm.parseJsonAddress(json, string.concat(networkKey, ".admin"));
        feeReceiver = vm.parseJsonAddress(json, string.concat(networkKey, ".feeReceiver"));
        rewardFee = uint8(vm.parseJsonUint(json, string.concat(networkKey, ".rewardFee")));
        maxDivergence = uint8(vm.parseJsonUint(json, string.concat(networkKey, ".maxDivergence")));

        console.log("Loaded configuration for network:", networkName);
        console.log("Chain ID:", chainId);
    }

    // Set custom configuration (for advanced usage)
    function setCustomConfig(
        address _polToken,
        address _maticToken,
        address _polygonMigration,
        address _stakeManager,
        address _admin,
        address _feeReceiver,
        uint8 _rewardFee,
        uint8 _maxDivergence
    ) public {
        networkName = "custom";
        polTokenL1 = _polToken;
        maticToken = _maticToken;
        polygonMigration = _polygonMigration;
        stakeManager = _stakeManager;
        admin = _admin;
        feeReceiver = _feeReceiver;
        rewardFee = _rewardFee;
        maxDivergence = _maxDivergence;
        console.log("Using custom configuration");
    }

    // Deploy using configuration loaded from JSON file for current chain
    function deployFromJson(address _deployer) public {
        loadConfigFromJson(block.chainid);
        _deployL1(_deployer);
    }

    // Deploy using mock configuration (for testing)
    function deployWithMockConfig(address _deployer) public {
        loadMockConfig();
        _deployL1(_deployer);
    }

    function _deployL1(address _deployer) internal {
        console.log("Starting deployment...");
        console.log("Network:", networkName);
        console.log("Deployer:", _deployer);
        console.log("Chain ID:", block.chainid);

        // Validate configuration
        require(polTokenL1 != address(0), "POL token L1 address not set");
        require(polTokenL2 != address(0), "POL token L2 address not set");
        require(chainIdL1 != 0, "Chain ID L1 not set");
        require(chainIdL2 != 0, "Chain ID L2 not set");
        require(erc20predicate != address(0), "ERC20Predicate address not set");
        require(withdrawManager != address(0), "WithdrawManager address not set");
        require(maticToken != address(0), "Matic token address not set");
        require(polygonMigration != address(0), "PolygonMigration address not set");
        require(stakeManager != address(0), "StakeManager address not set");
        require(admin != address(0), "Admin address not set");
        require(feeReceiver != address(0), "Fee receiver address not set");
        require(rewardFee <= 1000, "Reward fee too high"); // Max 100%
        require(maxDivergence <= 100, "Max divergence too high"); // Max 100%

        // Step 0: Deploy dummyImpl
        address dummyImpl = address(new DummyImpl());

        // Step 0.1: Deploy bridger
        polBridger = new PolBridger(polTokenL1, polTokenL2, chainIdL1, chainIdL2, erc20predicate, withdrawManager);

        // Step 1: Deploy AccessManager
        accessManagerL1 = new AccessManager{salt: "polygon-access-manager"}(admin);

        // Step 2: Deploy sPOLController proxy with temporary implementation (no initialization)
        sPOLControllerProxy = new TransparentUpgradeableProxy(dummyImpl, _deployer, "");
        console.log("sPOLController proxy deployed at:", address(sPOLControllerProxy));

        // Get the proxy admin address from EIP-1967 admin slot
        sPOLControllerproxyAdmin = getProxyAdmin(sPOLControllerProxy);
        console.log("Proxy admin deployed at:", address(sPOLControllerproxyAdmin));

        // Step 3: Deploy sPOL implementation with the controller proxy address
        sPOLImpl = new sPOL(address(sPOLControllerProxy));
        console.log("sPOL implementation deployed at:", address(sPOLImpl));

        // Step 4: Deploy sPOL proxy
        bytes memory tokenInitData = abi.encodeCall(sPOL.initialize, ());
        sPOLProxy = new TransparentUpgradeableProxy(address(sPOLImpl), _deployer, tokenInitData);
        console.log("sPOL proxy deployed at:", address(sPOLProxy));

        sPOLproxyAdmin = getProxyAdmin(sPOLProxy);
        console.log("Proxy admin deployed at:", address(sPOLProxy));

        // Step 5: Deploy sPOLController implementation with the real sPOL proxy address
        sPOLControllerImpl =
            new sPOLController(polTokenL1, maticToken, polygonMigration, address(sPOLProxy), stakeManager);
        console.log("sPOLController implementation deployed at:", address(sPOLControllerImpl));

        // Step 6: Use the proxy admin to upgrade sPOLController proxy
        bytes memory controllerInitData = abi.encodeCall(
            sPOLController.initialize, (rewardFee, feeReceiver, maxDivergence, address(accessManagerL1))
        );

        sPOLControllerproxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(sPOLControllerProxy)), address(sPOLControllerImpl), controllerInitData
        );
        console.log("sPOLController proxy upgraded to new implementation");

        // Step 6: Transfer ProxyAdmin ownership to the designated admin
        sPOLControllerproxyAdmin.transferOwnership(admin);
        console.log("sPOL ProxyAdmin ownership transferred to:", admin);
        sPOLproxyAdmin.transferOwnership(admin);
        console.log("sPOL Controller ProxyAdmin ownership transferred to:", admin);

        // Verify deployment
        _verifyDeployment();

        console.log("Deployment completed successfully!");
        console.log("sPOL Token (proxy):", address(sPOLProxy));
        console.log("sPOL Token (implementation):", address(sPOLImpl));
        console.log("sPOLController (proxy):", address(sPOLControllerProxy));
        console.log("sPOLController (implementation):", address(sPOLControllerImpl));
        console.log("sPOL Proxy Admin Address:", address(sPOLproxyAdmin));
        console.log("sPOL Controller Proxy Admin Address:", address(sPOLControllerproxyAdmin));
    }

    function _deployL2(address _deployer) internal {
        console.log("Starting deployment...");
        console.log("Network:", networkName);
        console.log("Deployer:", _deployer);
        console.log("Chain ID:", block.chainid);

        // Validate configuration
        require(polTokenL1 != address(0), "POL token L1 address not set");
        require(polTokenL2 != address(0), "POL token L2 address not set");
        require(chainIdL1 != 0, "Chain ID L1 not set");
        require(chainIdL2 != 0, "Chain ID L2 not set");
        require(erc20predicate != address(0), "ERC20Predicate address not set");
        require(withdrawManager != address(0), "WithdrawManager address not set");
        require(maticToken != address(0), "Matic token address not set");
        require(polygonMigration != address(0), "PolygonMigration address not set");
        require(stakeManager != address(0), "StakeManager address not set");
        require(admin != address(0), "Admin address not set");
        require(address(sPOLMessengerProxy) != address(0), "sPOLMessengerProxy address not set");
        require(childChainManager != address(0), "ChildChainManager address not set");

        // Step 0.1: Deploy bridger
        polBridger = new PolBridger(polTokenL1, polTokenL2, chainIdL1, chainIdL2, erc20predicate, withdrawManager);

        // Step 1: Deploy AccessManager
        accessManagerL2 = new AccessManager{salt: "polygon-access-manager"}(admin);

        // Step 2: Deploy sPOLChild implementation
        sPOLChildImpl = new sPOLChild(stateSyncer);
        console.log("sPOLChild implementation deployed at:", address(sPOLChildImpl));

        // Step 3: Deploy sPOLChild proxy and initialize
        bytes memory childInitData = abi.encodeCall(
            sPOLChild.initialize,
            (address(accessManagerL2), address(sPOLMessengerProxy), address(polBridger), childChainManager)
        );
        sPOLChildProxy =
            new TransparentUpgradeableProxy(address(sPOLChildImpl), address(accessManagerL2), childInitData);
        console.log("sPOLChild proxy deployed at:", address(sPOLControllerProxy));

        sPOLChildproxyAdmin = getProxyAdmin(sPOLChildProxy);
        console.log("sPOLChild ProxyAdmin deployed at:", address(sPOLChildproxyAdmin));

        // Verify deployment
        _verifyDeploymentL2();

        console.log("Deployment completed successfully!");
        console.log("polBridger Address:", address(polBridger));
        console.log("AccessManager L2 Address:", address(accessManagerL2));
        console.log("sPOLChild Token (proxy):", address(sPOLChildProxy));
        console.log("sPOLChild Token (implementation):", address(sPOLChildImpl));
        console.log("sPOLChild Proxy Admin Address:", address(sPOLChildproxyAdmin));
    }

    function _verifyDeployment() internal view {
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
        sPOLChild child = sPOLChild(address(sPOLChildProxy));

        // Verify sPOLChild
        require(child.stateSyncer() == stateSyncer, "sPOLChild state syncer incorrect");
        require(address(child.bridgeHelper()) == address(polBridger), "sPOLChild bridger incorrect");
        require(child.authority() == address(accessManagerL1), "sPOLChild admin incorrect");
        require(child.childChainManager() == childChainManager, "sPOLChild child chain manager incorrect");
        require(child.l1Messenger() == address(sPOLMessengerProxy), "sPOLChild messenger incorrect");
        require(
            vm.load(address(child), hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
                == bytes32(uint256(uint160(address(sPOLChildImpl)))),
            "sPOLChild implementation address incorrect"
        );
        require(getProxyAdmin(sPOLChildProxy).owner() == address(accessManagerL2), "sPOLChild ProxyAdmin wrong owner");
        console.log("All verifications passed for L2!");
    }

    function deployWithParams(
        address _polToken,
        address _maticToken,
        address _polygonMigration,
        address _stakeManager,
        uint8 _rewardFee,
        address _feeReceiver,
        uint8 _maxDivergence,
        address _admin,
        address _deployer
    ) external {
        setCustomConfig(
            _polToken, _maticToken, _polygonMigration, _stakeManager, _admin, _feeReceiver, _rewardFee, _maxDivergence
        );
        _deployL1(_deployer);
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
}
