// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface MRC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external payable returns (bool);
    function withdraw(uint256 amount) external payable;
}
