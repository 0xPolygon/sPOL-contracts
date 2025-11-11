// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {
    ERC20PermitUpgradeable
} from "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";

contract sPOL is Initializable, ERC20PermitUpgradeable {
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

    // only used for gasless sPOL -> POL exchanges
    // resets allowance to 0 as, the controller never needs allowance
    // can be front run by using normal permit function, makes the exchange fail
    function consumePermit(
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external onlyController {
        permit(_owner, _spender, _value, _deadline, _v, _r, _s);
        _approve(_owner, _spender, 0);
    }

    function mint(address to, uint256 amount) external onlyController {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }
}
