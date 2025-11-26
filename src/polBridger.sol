// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MRC20 as IMRC20} from "./interfaces/IMRC20.sol";
import {ERC20PredicateBurnOnly as IERC20PredicateBurnOnly} from "./interfaces/IERC20Predicate.sol";
import {WithdrawManager as IWithdrawManager} from "./interfaces/IWithdrawManager.sol";

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract PolBridger is AccessManaged, Pausable {
    address public immutable polTokenL1;
    address public immutable polTokenL2;
    uint256 public immutable chainIDL1;
    uint256 public immutable chainIDL2;
    address public immutable erc20predicate;
    address public immutable withdrawManager;

    bool public initialized;
    address public sPOLMessengerL1;
    address public sPOLMessengerL2;

    error AddressUnauthorized(address caller);
    error AlreadyInitialized();
    error InsufficientPOLSent(uint256 sent, uint256 required);
    error InvalidOriginChain(uint256 currentChain, uint256 expectedChain);
    error ZeroAddress();

    constructor(
        address _polTokenL1,
        address _polTokenL2,
        uint256 _chainIDL1,
        uint256 _chainIDL2,
        address _erc20predicate,
        address _withdrawManager,
        address _authority
    ) AccessManaged(_authority) {
        polTokenL1 = _polTokenL1;
        polTokenL2 = _polTokenL2;
        chainIDL1 = _chainIDL1;
        chainIDL2 = _chainIDL2;
        erc20predicate = _erc20predicate;
        withdrawManager = _withdrawManager;
    }

    function initialize(address _sPOLMessengerL1, address _sPOLMessengerL2) external restricted {
        require(!initialized, AlreadyInitialized());
        require(_sPOLMessengerL1 != address(0), ZeroAddress());
        require(_sPOLMessengerL2 != address(0), ZeroAddress());
        sPOLMessengerL1 = _sPOLMessengerL1;
        sPOLMessengerL2 = _sPOLMessengerL2;
        initialized = true;
    }

    function bridgePOLToL1(uint256 _amount) external payable whenNotPaused {
        require(msg.value == _amount, InsufficientPOLSent(msg.value, _amount));
        require(msg.sender == sPOLMessengerL2, AddressUnauthorized(msg.sender));
        require(block.chainid == chainIDL2, InvalidOriginChain(block.chainid, chainIDL2));
        IMRC20(polTokenL2).withdraw{value: _amount}(_amount);
    }

    function exitPOL(bytes memory proof) external whenNotPaused {
        require(block.chainid == chainIDL1, InvalidOriginChain(block.chainid, chainIDL1));
        IERC20PredicateBurnOnly(erc20predicate).startExitWithBurntTokens(proof);
    }

    function finalizeExitPOL() external whenNotPaused {
        require(block.chainid == chainIDL1, InvalidOriginChain(block.chainid, chainIDL1));
        IWithdrawManager(withdrawManager).processExits(polTokenL1);
    }

    function takePOLL1(uint256 _amount) external whenNotPaused {
        require(msg.sender == sPOLMessengerL1, AddressUnauthorized(msg.sender));
        require(block.chainid == chainIDL1, InvalidOriginChain(block.chainid, chainIDL1));
        IERC20(polTokenL1).transfer(sPOLMessengerL1, _amount);
    }

    function rescue(address _token, address _to, uint256 _amount) external restricted {
        IERC20(_token).transfer(_to, _amount);
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }
}
