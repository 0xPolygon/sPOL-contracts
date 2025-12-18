// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRootChainManager} from "./msg/interfaces/IRootChainManager.sol";
import {DepositManager as IDepositManager} from "./interfaces/IDepositManager.sol";
import {PolBridger} from "./polBridger.sol";
import {sPOLController as IsPOLController} from "./sPOLController.sol";

import {BaseRootTunnel} from "./msg/BaseRootTunnel.sol";
import {MsgCoder} from "./MsgCoder.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract sPOLMessenger is
    Initializable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    ReentrancyGuardTransient,
    BaseRootTunnel,
    MsgCoder
{
    IERC20 public immutable polToken;
    IERC20 public immutable sPOLToken;

    IRootChainManager public immutable rootChainManager;
    IDepositManager public immutable depositManager;
    IsPOLController public immutable sPOLController;
    PolBridger public immutable polBridger;

    mapping(uint256 => uint256[]) public backfillNonces;
    mapping(uint256 => bool) public completedBackfill;

    event MigrationProcessed(uint256 polAmount, uint256 mintedSPOL);
    event BackfillStarted(uint256 indexed backfillCycle, uint256 polAmount, uint256 sPOLAmount);
    event BackfillCompleted(uint256 indexed backfillCycle, uint256 totalWithdraw);
    event ExchangeRateUpdateSent(uint256 totalsPOLBalance, uint256 totaldPOLBalance);

    error InvalidMessageType(uint8 msgType);
    error NotEnoughPOLInMessenger(uint256 required, uint256 available);
    error NotEnoughSPOLInMessenger(uint256 required, uint256 available);
    error BackfillAlreadyCompleted(uint256 backfillCycle);
    error ZeroAddress();

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
        require(_polToken != address(0), ZeroAddress());
        require(_sPOLToken != address(0), ZeroAddress());
        require(_sPOLController != address(0), ZeroAddress());
        require(_rootChainManager != address(0), ZeroAddress());
        require(_depositManager != address(0), ZeroAddress());
        require(_stateSender != address(0), ZeroAddress());
        require(_checkpointManager != address(0), ZeroAddress());
        require(_childTunnel != address(0), ZeroAddress());
        require(_polBridger != address(0), ZeroAddress());

        polToken = IERC20(_polToken);
        sPOLToken = IERC20(_sPOLToken);
        sPOLController = IsPOLController(_sPOLController);
        rootChainManager = IRootChainManager(_rootChainManager);
        depositManager = IDepositManager(_depositManager);
        polBridger = PolBridger(_polBridger);

        _disableInitializers();
    }

    function initialize(address _authority, address _rcmERC20Predicate) external initializer {
        require(_authority != address(0), ZeroAddress());
        require(_rcmERC20Predicate != address(0), ZeroAddress());

        __Pausable_init();
        __AccessManaged_init(_authority);

        polToken.approve(address(sPOLController), type(uint256).max);
        polToken.approve(address(depositManager), type(uint256).max);
        sPOLToken.approve(_rcmERC20Predicate, type(uint256).max);
    }

    function _processMessageFromChild(bytes memory _message) internal override {
        (MsgType msgType, bytes memory actualMessage) = abi.decode(_message, (MsgType, bytes));
        if (msgType == MsgType.L2_MIGRATION_REQUEST) {
            _handleMigration(actualMessage);
        } else if (msgType == MsgType.L2_BACKFILL_REQUEST) {
            _handleBackfill(actualMessage);
        } else {
            revert InvalidMessageType(uint8(msgType));
        }
    }

    function _handleMigration(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _mintedSPOL) = _decodeL2MigrationRequestMessage(_msg);
        polBridger.takePOLL1(_polAmount);
        require(
            polToken.balanceOf(address(this)) >= _polAmount,
            NotEnoughPOLInMessenger(_polAmount, polToken.balanceOf(address(this)))
        );

        sPOLController.completeMigration(_polAmount, _mintedSPOL);
        rootChainManager.depositFor(childTunnel, address(sPOLToken), abi.encodePacked(_mintedSPOL));
        // disabled for portal because of cyclical exit issue, should be activated for lxly
        //_sendMessageToChild(abi.encode(MsgType.L1_MIGRATION_RESPONSE, encodeL1MigrationResponseMessage(_mintedSPOL)));
        emit MigrationProcessed(_polAmount, _mintedSPOL);
    }

    function _handleBackfill(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle) = _decodeL2BackfillRequestMessage(_msg);
        require(
            sPOLToken.balanceOf(address(this)) >= _sPOLAmount,
            NotEnoughSPOLInMessenger(_sPOLAmount, sPOLToken.balanceOf(address(this)))
        );
        uint256[] memory nonces = sPOLController.startBackfillSell(_polAmount, _sPOLAmount);
        backfillNonces[_backFillCycle] = nonces;
        emit BackfillStarted(_backFillCycle, _polAmount, _sPOLAmount);
    }

    function completeBackfill(uint256 _backFillCycle) external restricted whenNotPaused nonReentrant {
        require(!completedBackfill[_backFillCycle], BackfillAlreadyCompleted(_backFillCycle));
        uint256 balanceBefore = polToken.balanceOf(address(this));
        for (uint256 i = 0; i < backfillNonces[_backFillCycle].length; i++) {
            sPOLController.withdrawPOL(backfillNonces[_backFillCycle][i]);
        }
        uint256 balanceAfter = polToken.balanceOf(address(this));
        uint256 totalWithdraw = balanceAfter - balanceBefore;
        depositManager.depositERC20ForUser(address(polToken), childTunnel, totalWithdraw);
        _sendMessageToChild(
            abi.encode(MsgType.L1_BACKFILL_RESPONSE, _encodeL1BackfillResponseMessage(totalWithdraw, _backFillCycle))
        );
        completedBackfill[_backFillCycle] = true;
        emit BackfillCompleted(_backFillCycle, totalWithdraw);
    }

    function updateL2ExchangeRate() external restricted whenNotPaused nonReentrant {
        uint256 totalsPOLBalance = sPOLController.totalsPOLBalance();
        uint256 totaldPOLBalance = sPOLController.totaldPOLBalance() - sPOLController.feedPOLBalance();

        _sendMessageToChild(
            abi.encode(MsgType.EXCHANGE_UPDATE, _encodeExchangeUpdateMessage(totalsPOLBalance, totaldPOLBalance))
        );
        emit ExchangeRateUpdateSent(totalsPOLBalance, totaldPOLBalance);
    }

    function pauseUserFunctions() external restricted {
        _pause();
    }

    function unpauseUserFunctions() external restricted {
        _unpause();
    }
}
