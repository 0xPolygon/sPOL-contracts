// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface DepositManager {
    function depositERC20ForUser(address _token, address _user, uint256 _amount) external;
}
