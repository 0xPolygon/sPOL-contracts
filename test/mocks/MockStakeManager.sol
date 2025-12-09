// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;
import {MockValidatorShare} from "./MockValidatorShare.sol";

import "forge-std/console.sol";

contract MockStakeManager {
    mapping(uint256 => address) public validatorContracts;
    constructor() {}

    function setValidatorContract(uint16 _validatorId, address _validatorContract) public {
        validatorContracts[_validatorId] = _validatorContract;
    }

    function migrateDelegation(uint256 _fromValidatorId, uint256 _toValidatorId, uint256 _amount) external {
        console.log("from", _fromValidatorId, "to", _toValidatorId);
        console.log("amount", _amount);
        MockValidatorShare(validatorContracts[_fromValidatorId]).migrateOut(msg.sender, _amount);
        MockValidatorShare(validatorContracts[_toValidatorId]).migrateIn(msg.sender, _amount);
    }

    function isValidator(uint256 _validatorId) external view returns (bool) {
        return validatorContracts[_validatorId] != address(0);
    }

    function getValidatorContract(uint256 _validatorId) external view returns (address) {
        return validatorContracts[_validatorId];
    }
}
