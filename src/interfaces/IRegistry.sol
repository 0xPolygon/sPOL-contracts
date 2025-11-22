// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface Registry {
    type Type is uint8;

    event ContractMapUpdated(bytes32 indexed key, address indexed previousContract, address indexed newContract);
    event PredicateAdded(address indexed predicate, address indexed from);
    event PredicateRemoved(address indexed predicate, address indexed from);
    event ProofValidatorAdded(address indexed validator, address indexed from);
    event ProofValidatorRemoved(address indexed validator, address indexed from);
    event TokenMapped(address indexed rootToken, address indexed childToken);

    function addErc20Predicate(address predicate) external;
    function addErc721Predicate(address predicate) external;
    function addPredicate(address predicate, Type _type) external;
    function childToRootToken(address) external view returns (address);
    function contractMap(bytes32) external view returns (address);
    function erc20Predicate() external view returns (address);
    function erc721Predicate() external view returns (address);
    function getChildChainAndStateSender() external view returns (address, address);
    function getDepositManagerAddress() external view returns (address);
    function getSlashingManagerAddress() external view returns (address);
    function getStakeManagerAddress() external view returns (address);
    function getValidatorShareAddress() external view returns (address);
    function getWethTokenAddress() external view returns (address);
    function getWithdrawManagerAddress() external view returns (address);
    function governance() external view returns (address);
    function isChildTokenErc721(address childToken) external view returns (bool);
    function isERC721(address) external view returns (bool);
    function isTokenMapped(address _token) external view returns (bool);
    function isTokenMappedAndGetPredicate(address _token) external view returns (address);
    function isTokenMappedAndIsErc721(address _token) external view returns (bool);
    function mapToken(address _rootToken, address _childToken, bool _isERC721) external;
    function predicates(address) external view returns (Type _type);
    function proofValidatorContracts(address) external view returns (bool);
    function removePredicate(address predicate) external;
    function rootToChildToken(address) external view returns (address);
    function updateContractMap(bytes32 _key, address _address) external;
}
