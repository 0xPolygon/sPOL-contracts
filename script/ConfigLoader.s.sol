// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {DummyImpl} from "./DummyImpl.sol";

contract ConfigLoader is Script {
    // Network configuration variables
    string public scenarioName;
    string public saltPrefix;
    uint256 public chainIdL1;
    uint256 public chainIdL2;
    address public polTokenL1;
    address public polTokenL2;
    address public withdrawManager;
    address public erc20predicate;
    address public childChainManager;
    address public rootChainManager;
    address public rcmERC20Predicate;
    address public depositManager;
    address public stateSenderL1;
    address public maticTokenL1;
    address public polygonMigration;
    address public stakeManager;
    address public checkpointManager;
    address public feeReceiver;
    address public stateSyncerL2;
    uint8 public rewardFee;
    uint8 public maxDivergence;
    uint256 public childTargetQuickRedeemReserve;
    address public admin;

    function loadMockConfig() public {
        scenarioName = "mock-scenario";
        saltPrefix = "Mock-";
        polTokenL1 = makeAddr("polTokenL1");
        vm.etch(polTokenL1, type(DummyImpl).runtimeCode);
        //deployCodeTo("out/ERC20Permit.sol/ERC20Permit.json", abi.encode("POL Token L1", "POL L1", 18, 0), polTokenL1);
        polTokenL2 = makeAddr("polTokenL2");
        vm.etch(polTokenL2, type(DummyImpl).runtimeCode);
        chainIdL1 = 1;
        chainIdL2 = 2;
        maticTokenL1 = makeAddr("maticTokenL1");
        polygonMigration = makeAddr("polygonMigration");
        stakeManager = makeAddr("stakeManager");
        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        rewardFee = 100; // 10%
        maxDivergence = 10; // 10%
        withdrawManager = makeAddr("withdrawManager");
        erc20predicate = makeAddr("erc20predicate");
        childChainManager = makeAddr("childChainManager");
        rootChainManager = makeAddr("rootChainManager");
        rcmERC20Predicate = makeAddr("rcmERC20Predicate");
        depositManager = makeAddr("depositManager");
        stateSenderL1 = makeAddr("stateSender");
        checkpointManager = makeAddr("checkpointManager");
        stateSyncerL2 = makeAddr("stateSyncerL2");
        childTargetQuickRedeemReserve = 1_000_000 ether;

        validateConfig();
        console.log("Loaded configuration for scenario:", scenarioName);
    }

    // Load configuration from JSON file for specific chain ID
    function loadConfigFromJson(string memory _scenarioName) public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/input.json");
        string memory json = vm.readFile(path);

        scenarioName = string.concat(".", _scenarioName);
        require(bytes(scenarioName).length != 0, "Scenario name is empty");
        console.log("Loading configuration for scenario:", scenarioName);
        // Check if network exists in JSON
        bytes memory deployData = vm.parseJson(json, ".ethereum-polygon");
        require(deployData.length > 0, string.concat("Network configuration not found for scenario: ", _scenarioName));
        // Parse network configuration
        polTokenL1 = vm.parseJsonAddress(json, string.concat(scenarioName, ".polTokenL1"));
        polTokenL2 = vm.parseJsonAddress(json, string.concat(scenarioName, ".polTokenL2"));
        chainIdL1 = vm.parseJsonUint(json, string.concat(scenarioName, ".chainIdL1"));
        chainIdL2 = vm.parseJsonUint(json, string.concat(scenarioName, ".chainIdL2"));
        saltPrefix = vm.parseJsonString(json, string.concat(scenarioName, ".saltPrefix"));

        maticTokenL1 = vm.parseJsonAddress(json, string.concat(scenarioName, ".maticTokenL1"));
        polygonMigration = vm.parseJsonAddress(json, string.concat(scenarioName, ".polygonMigration"));
        stakeManager = vm.parseJsonAddress(json, string.concat(scenarioName, ".stakeManager"));
        admin = vm.parseJsonAddress(json, string.concat(scenarioName, ".admin"));
        feeReceiver = vm.parseJsonAddress(json, string.concat(scenarioName, ".feeReceiver"));
        rewardFee = uint8(vm.parseJsonUint(json, string.concat(scenarioName, ".rewardFee")));
        maxDivergence = uint8(vm.parseJsonUint(json, string.concat(scenarioName, ".maxDivergence")));
        childTargetQuickRedeemReserve =
            vm.parseJsonUint(json, string.concat(scenarioName, ".childTargetQuickRedeemReserve"));
        withdrawManager = vm.parseJsonAddress(json, string.concat(scenarioName, ".withdrawManager"));
        erc20predicate = vm.parseJsonAddress(json, string.concat(scenarioName, ".erc20predicate"));
        childChainManager = vm.parseJsonAddress(json, string.concat(scenarioName, ".childChainManager"));
        rootChainManager = vm.parseJsonAddress(json, string.concat(scenarioName, ".rootChainManager"));
        rcmERC20Predicate = vm.parseJsonAddress(json, string.concat(scenarioName, ".rcmERC20Predicate"));
        depositManager = vm.parseJsonAddress(json, string.concat(scenarioName, ".depositManager"));
        stateSenderL1 = vm.parseJsonAddress(json, string.concat(scenarioName, ".stateSenderL1"));
        checkpointManager = vm.parseJsonAddress(json, string.concat(scenarioName, ".checkpointManager"));
        stateSyncerL2 = vm.parseJsonAddress(json, string.concat(scenarioName, ".stateSyncerL2"));

        validateConfig();
        console.log("Loaded configuration for scenario:", scenarioName);
    }

    function validateConfig() public view {
        require(bytes(scenarioName).length != 0, "Scenario name is empty");
        require(bytes(saltPrefix).length != 0, "Salt prefix is empty");
        require(polTokenL1 != address(0), "POL Token L1 address is zero");
        require(polTokenL2 != address(0), "POL Token L2 address is zero");
        require(maticTokenL1 != address(0), "MATIC Token address is zero");
        require(polygonMigration != address(0), "Polygon Migration address is zero");
        require(stakeManager != address(0), "Stake Manager address is zero");
        require(chainIdL1 != 0, "Chain ID L1 is zero");
        require(chainIdL2 != 0, "Chain ID L2 is zero");
        require(feeReceiver != address(0), "Fee Receiver address is zero");
        require(rewardFee <= 1000, "Reward fee exceeds 1000 (10%)");
        require(maxDivergence <= 100, "Max divergence exceeds 100 (10%)");
        require(withdrawManager != address(0), "Withdraw Manager address is zero");
        require(erc20predicate != address(0), "ERC20 Predicate address is zero");
        require(childChainManager != address(0), "Child Chain Manager address is zero");
        require(rootChainManager != address(0), "Root Chain Manager address is zero");
        require(rcmERC20Predicate != address(0), "RCM ERC20 Predicate address is zero");
        require(depositManager != address(0), "Deposit Manager address is zero");
        require(stateSenderL1 != address(0), "State Syncer address is zero");
        require(checkpointManager != address(0), "Checkpoint Manager address is zero");
        require(stateSyncerL2 != address(0), "State Syncer L2 address is zero");
        require(admin != address(0), "Admin address is zero");
    }
}
