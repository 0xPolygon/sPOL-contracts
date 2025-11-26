// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {sPOLController as IsPOLController} from "./sPOLController.sol";
import {IRootChainManager} from "./msg/interfaces/IRootChainManager.sol";
import {DepositManager as IDepositManager} from "./interfaces/IDepositManager.sol";
import {BaseRootTunnel} from "./msg/BaseRootTunnel.sol";
import {MsgCoder} from "./MsgCoder.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {PolBridger} from "./polBridger.sol";

contract sPOLMessenger is Initializable, PausableUpgradeable, AccessManagedUpgradeable, BaseRootTunnel, MsgCoder {
    IERC20 public immutable polToken;
    IERC20 public immutable sPOLToken;
    address public child;

    IRootChainManager public immutable rootChainManager;
    IDepositManager public immutable depositManager;
    IsPOLController public immutable sPOLController;
    PolBridger public immutable polBridger;

    mapping(uint256 => uint256[]) public backfillNonces;
    mapping(uint256 => bool) public completedBackfill;

    constructor(
        address _polToken,
        address _sPOLToken,
        address _sPOLController,
        address _rootChainManager,
        address _depositManager,
        address _stateSender,
        address _checkpointManager,
        address _childTunnel,
        address _polBridger
    ) BaseRootTunnel(_stateSender, _checkpointManager, _childTunnel) {
        polToken = IERC20(_polToken);
        sPOLToken = IERC20(_sPOLToken);
        sPOLController = IsPOLController(_sPOLController);
        rootChainManager = IRootChainManager(_rootChainManager);
        depositManager = IDepositManager(_depositManager);
        polBridger = PolBridger(_polBridger);
        _disableInitializers();
    }

    function initialize(address _authority, address _rcmERC20Predicate) external initializer {
        __Pausable_init();
        __AccessManaged_init(_authority);
        polToken.approve(address(sPOLController), type(uint256).max);
        polToken.approve(address(depositManager), type(uint256).max);
        sPOLToken.approve(_rcmERC20Predicate, type(uint256).max);
    }

    function _processMessageFromChild(bytes memory _message) internal override {
        (MsgType msgType, bytes memory actualMessage) = abi.decode(_message, (MsgType, bytes));
        if (msgType == MsgType.L2_MIGRATION_REQUEST) {
            handleMigration(actualMessage);
        } else if (msgType == MsgType.L2_BACKFILL_REQUEST) {
            handleBackfill(actualMessage);
        } else {
            revert("Invalid message type");
        }

        // stake the POL using custom exchange logic?
        // basically pass the POL and the SPOL and if sPOL minted is lower than expected just mint the low amount
        // Then take the sPOL and send it to the L2, with a message that the amount can be burned
        // _sendMessageToChild(abi.encode(mintedSPOL));
    }

    function handleMigration(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _mintedSPOL) = decodeL2MigrationRequestMessage(_msg);
        polBridger.takePOLL1(_polAmount);
        require(polToken.balanceOf(address(this)) >= _polAmount, "Not enough POL in messenger");

        sPOLController.completeMigration(_polAmount, _mintedSPOL);
        rootChainManager.depositFor(childTunnel, address(sPOLToken), abi.encodePacked(_mintedSPOL));
        // disabled for portal because of cyclical exit issue, should be activated for lxly
        //_sendMessageToChild(abi.encode(MsgType.L1_MIGRATION_RESPONSE, encodeL1MigrationResponseMessage(_mintedSPOL)));
    }

    function handleBackfill(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle) = decodeL2BackfillRequestMessage(_msg);
        require(sPOLToken.balanceOf(address(this)) >= _sPOLAmount, "Not enough sPOL in messenger");
        uint256[] memory nonces = sPOLController.startBackfillSell(_polAmount, _sPOLAmount);
        backfillNonces[_backFillCycle] = nonces;
    }

    function completeBackfill(uint256 _backFillCycle) external whenNotPaused {
        require(!completedBackfill[_backFillCycle], "Backfill already completed");
        uint256 balanceBefore = polToken.balanceOf(address(this));
        for (uint256 i = 0; i < backfillNonces[_backFillCycle].length; i++) {
            sPOLController.withdrawPOL(backfillNonces[_backFillCycle][i]);
        }
        uint256 balanceAfter = polToken.balanceOf(address(this));
        uint256 totalWithdraw = balanceAfter - balanceBefore;
        depositManager.depositERC20ForUser(address(polToken), child, totalWithdraw);
        _sendMessageToChild(
            abi.encode(MsgType.L1_BACKFILL_RESPONSE, encodeL1BackfillResponseMessage(totalWithdraw, _backFillCycle))
        );
        completedBackfill[_backFillCycle] = true;
    }

    function updateL2ExchangeRate() external whenNotPaused {
        _sendMessageToChild(
            abi.encode(
                MsgType.EXCHANGE_UPDATE,
                encodeExchangeUpdateMessage(
                    sPOLController.totalsPOLBalance(),
                    (sPOLController.totaldPOLBalance() - sPOLController.feedPOLBalance())
                )
            )
        );
    }

    function pauseUserFunctions() external {
        _pause();
    }

    function unpauseUserFunctions() external {
        _unpause();
    }
}
