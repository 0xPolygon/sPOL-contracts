// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

interface IStateSender {
    event StateSynced(uint256 indexed id, address indexed contractAddress, bytes data);

    function syncState(address receiver, bytes calldata data) external;
    function register(address sender, address receiver) external;
    function owner() external view returns (address);
}
