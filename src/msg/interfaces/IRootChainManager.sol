// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

interface IRootChainManager {
    function depositFor(address user, address rootToken, bytes calldata depositData) external;

    function exit(bytes calldata inputData) external;
}
