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
    address public initializer;
    address public sPOLMessengerL1;
    address public sPOLMessengerL2;

    constructor(
        address _polTokenL1,
        address _polTokenL2,
        uint256 _chainIDL1,
        uint256 _chainIDL2,
        address _erc20predicate,
        address _withdrawManager
    ) AccessManaged(address(0)) {
        polTokenL1 = _polTokenL1;
        polTokenL2 = _polTokenL2;
        chainIDL1 = _chainIDL1;
        chainIDL2 = _chainIDL2;
        erc20predicate = _erc20predicate;
        withdrawManager = _withdrawManager;
        initializer = msg.sender;
    }

    function initialize(address _sPOLMessengerL1, address _sPOLMessengerL2, address _authority) external {
        require(!initialized, "Already initialized");
        require(msg.sender == initializer, "Only initializer can call");
        require(_sPOLMessengerL1 != address(0), "Invalid sPOL Messenger L1");
        require(_sPOLMessengerL2 != address(0), "Invalid sPOL Messenger L2");
        require(_authority != address(0), "Invalid authority address");
        sPOLMessengerL1 = _sPOLMessengerL1;
        sPOLMessengerL2 = _sPOLMessengerL2;
        initialized = true;
        _setAuthority(_authority);
    }

    function bridgePOLToL1(uint256 _amount) external payable whenNotPaused {
        require(msg.value == _amount, "Insufficient POL sent");
        require(msg.sender == sPOLMessengerL2, "Only sPOL Messenger can call");
        require(block.chainid == chainIDL2, "Invalid origin chain");
        IMRC20(polTokenL2).withdraw(_amount);
    }

    function exitPOL(bytes memory proof) external whenNotPaused {
        require(block.chainid == chainIDL1, "Invalid origin chain");
        IERC20PredicateBurnOnly(erc20predicate).startExitWithBurntTokens(proof);
    }

    function finalizeExitPOL() external whenNotPaused {
        require(block.chainid == chainIDL1, "Invalid origin chain");
        IWithdrawManager(withdrawManager).processExits(polTokenL1);
    }

    function takePOLL1(uint256 _amount) external whenNotPaused {
        require(msg.sender == sPOLMessengerL1, "Only sPOL Messenger can call");
        require(block.chainid == chainIDL1, "Invalid origin chain");
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
