// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface MRC20 {
    event Withdraw(address indexed token, address indexed from, uint256 amount, uint256 input1, uint256 output1);

    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external payable returns (bool);
    function withdraw(uint256 amount) external payable;
}
