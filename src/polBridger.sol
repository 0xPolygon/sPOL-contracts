// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MRC20 as IMRC20} from "./interfaces/IMRC20.sol";
import {ERC20PredicateBurnOnly as IERC20PredicateBurnOnly} from "./interfaces/IERC20Predicate.sol";
import {WithdrawManager as IWithdrawManager} from "./interfaces/IWithdrawManager.sol";

contract PolBridger {
    address public immutable polTokenL1;
    address public immutable polTokenL2;
    address public immutable sPOLMessengerL1;
    address public immutable sPOLMessengerL2;
    uint256 public immutable chainIDL1;
    uint256 public immutable chainIDL2;
    address public immutable erc20predicate;
    address public immutable withdrawManager;

    constructor(
        address _polTokenL1,
        address _polTokenL2,
        address _sPOLMessengerL1,
        address _sPOLMessengerL2,
        uint256 _chainIDL1,
        uint256 _chainIDL2,
        address _erc20predicate,
        address _withdrawManager
    ) {
        polTokenL1 = _polTokenL1;
        polTokenL2 = _polTokenL2;
        sPOLMessengerL1 = _sPOLMessengerL1;
        sPOLMessengerL2 = _sPOLMessengerL2;
        chainIDL1 = _chainIDL1;
        chainIDL2 = _chainIDL2;
        erc20predicate = _erc20predicate;
        withdrawManager = _withdrawManager;
    }

    function bridgePOL(uint256 _amount) external payable {
        require(msg.value == _amount, "Insufficient POL sent");
        require(msg.sender == sPOLMessengerL2, "Only sPOL Messenger can call");
        require(block.chainid == chainIDL2, "Invalid origin chain");
        IMRC20(polTokenL2).withdraw(_amount);
    }

    function exitPOL(bytes memory proof) external {
        require(block.chainid == chainIDL1, "Invalid origin chain");
        IERC20PredicateBurnOnly(erc20predicate).startExitWithBurntTokens(proof);
    }

    function finalizeExitPOL() external {
        require(block.chainid == chainIDL1, "Invalid origin chain");
        IWithdrawManager(withdrawManager).processExits(polTokenL1);
    }

    function takePOL(uint256 _amount) external {
        require(msg.sender == sPOLMessengerL1, "Only sPOL Messenger can call");
        require(block.chainid == chainIDL1, "Invalid origin chain");
        IERC20(polTokenL1).transfer(sPOLMessengerL1, _amount);
    }
}
