// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice Final step: verify Safe is admin, then revoke deployer's admin role on both chains
contract RevokeDeployer is Script {
    address constant ADMIN_SAFE = 0x619D553686958A873A62B336b2DD97C3b25134EA;

    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory json = vm.readFile("script/deployment.json");

        // --- L1 ---
        address accessManagerL1Addr = vm.parseJsonAddress(json, ".sPOL_L1.accessManagerL1");
        AccessManager accessManagerL1 = AccessManager(accessManagerL1Addr);

        // Pre-check: Safe must be admin on L1
        (bool safeIsAdminL1,) = accessManagerL1.hasRole(accessManagerL1.ADMIN_ROLE(), ADMIN_SAFE);
        require(safeIsAdminL1, "Safe is NOT admin on L1 - aborting");

        vm.createSelectFork(vm.envString("L1_RPC_URL"));
        vm.startBroadcast(pk);
        accessManagerL1.renounceRole(accessManagerL1.ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        (bool deployerStillAdminL1,) = accessManagerL1.hasRole(accessManagerL1.ADMIN_ROLE(), deployer);
        require(!deployerStillAdminL1, "Deployer still admin on L1");
        console.log("L1: deployer admin revoked");

        // --- L2 ---
        address accessManagerL2Addr = vm.parseJsonAddress(json, ".sPOL_L2.accessManagerL2");
        AccessManager accessManagerL2 = AccessManager(accessManagerL2Addr);

        // Pre-check: Safe must be admin on L2
        (bool safeIsAdminL2,) = accessManagerL2.hasRole(accessManagerL2.ADMIN_ROLE(), ADMIN_SAFE);
        require(safeIsAdminL2, "Safe is NOT admin on L2 - aborting");

        vm.createSelectFork(vm.envString("L2_RPC_URL"));
        vm.startBroadcast(pk);
        accessManagerL2.renounceRole(accessManagerL2.ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        (bool deployerStillAdminL2,) = accessManagerL2.hasRole(accessManagerL2.ADMIN_ROLE(), deployer);
        require(!deployerStillAdminL2, "Deployer still admin on L2");
        console.log("L2: deployer admin revoked");

        console.log("RevokeDeployer complete - deployer removed from admin on both chains");
    }
}
