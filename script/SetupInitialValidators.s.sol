// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {sPOLController} from "../src/sPOLController.sol";
import {sPOL} from "../src/sPOL.sol";

/// @notice Post-deployment setup: add validators, set shares, initial deposit + lock
contract SetupInitialValidators is Script {
    uint16 constant VALIDATOR_1 = 188;
    uint16 constant VALIDATOR_2 = 92;
    uint8 constant SHARE_1 = 80;
    uint8 constant SHARE_2 = 20;
    uint256 constant INITIAL_DEPOSIT = 100 ether;
    address constant DEAD = address(0xdead);

    function run() public {
        string memory json = vm.readFile("script/deployment.json");

        address controllerAddr = vm.parseJsonAddress(json, ".sPOL_L1.sPOLControllerProxy");
        address spolAddr = vm.parseJsonAddress(json, ".sPOL_L1.sPOLProxy");

        sPOLController controller = sPOLController(controllerAddr);
        sPOL spolToken = sPOL(spolAddr);
        IERC20 polToken = IERC20(address(controller.polToken()));

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Add validators
        controller.addValidator(VALIDATOR_1);
        controller.addValidator(VALIDATOR_2);
        console.log("Validators added: %d and %d", VALIDATOR_1, VALIDATOR_2);

        // 2. Set deposit shares
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = VALIDATOR_1;
        valIds[1] = VALIDATOR_2;
        uint8[] memory shares = new uint8[](2);
        shares[0] = SHARE_1;
        shares[1] = SHARE_2;
        controller.updateValidatorTargetShare(valIds, shares);
        console.log("Deposit shares set: %d/%d", SHARE_1, SHARE_2);

        // 3. Approve POL and buy sPOL
        polToken.approve(controllerAddr, INITIAL_DEPOSIT);
        controller.buySPOL(INITIAL_DEPOSIT);
        uint256 spolBalance = spolToken.balanceOf(deployer);
        console.log("sPOL minted to deployer: %d", spolBalance);

        // 4. Lock sPOL by sending to dead address
        spolToken.transfer(DEAD, spolBalance);
        console.log("sPOL locked at 0xdead: %d", spolBalance);

        vm.stopBroadcast();

        // Verification
        require(controller.activeValidators(0) == VALIDATOR_1, "Validator 1 not at index 0");
        require(controller.activeValidators(1) == VALIDATOR_2, "Validator 2 not at index 1");
        require(spolToken.balanceOf(DEAD) > 0, "No sPOL at dead address");
        require(spolToken.balanceOf(deployer) == 0, "Deployer should have 0 sPOL");
        console.log("Setup verification passed!");
    }
}
