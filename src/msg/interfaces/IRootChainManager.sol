// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

interface IRootChainManager {
    function depositFor(address user, address rootToken, bytes calldata depositData) external;

    function exit(bytes calldata inputData) external;
    function mapToken(address rootToken, address childToken, bytes32 tokenType) external;
    function getRoleMember(bytes32 role, uint256 index) external returns (address);
    function MAPPER_ROLE() external pure returns (bytes32);
}
