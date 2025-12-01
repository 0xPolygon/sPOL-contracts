pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPOLToken is ERC20Permit {
    constructor(string memory name, string memory symbol) ERC20Permit(name) ERC20(name, symbol) {
        _mint(msg.sender, type(uint256).max);
    }
}

