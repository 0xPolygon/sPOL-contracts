// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable-5.5.0/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

contract sPOL is ERC20PermitUpgradeable {
    address public immutable sPOLController;

    modifier onlyController() {
        require(msg.sender == sPOLController, "Only sPOL controller can call this function");
        _;
    }

    constructor(address _sPOLController) {
        sPOLController = _sPOLController;
        _disableInitializers();
    }

    function initialize() external initializer {
        __ERC20_init("Staked POL", "sPOL");
        __ERC20Permit_init("Staked POL");
    }

    function mint(address to, uint256 amount) external onlyController {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }
}
