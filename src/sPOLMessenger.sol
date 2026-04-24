// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRootChainManager} from "./msg/interfaces/IRootChainManager.sol";
import {DepositManager as IDepositManager} from "./interfaces/IDepositManager.sol";
import {PolBridger} from "./polBridger.sol";
import {sPOLController as IsPOLController} from "./sPOLController.sol";

import {BaseRootTunnel} from "./msg/BaseRootTunnel.sol";
import {MsgCoder} from "./MsgCoder.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title sPOL Messenger
/// @notice L1 bridge coordinator for cross-chain sPOL operations
/// @dev Processes L2 migration and backfill requests via Polygon's state sync. Handles POL/sPOL
///      bridging between L1 and L2, and pushes exchange rate updates to L2.
contract sPOLMessenger is Initializable, AccessManagedUpgradeable, ReentrancyGuardTransient, BaseRootTunnel, MsgCoder {
    IERC20 public immutable polToken;
    IERC20 public immutable sPOLToken;

    IRootChainManager public immutable rootChainManager;
    IDepositManager public immutable depositManager;
    IsPOLController public immutable sPOLController;

    mapping(uint256 => bool) public completedBackfill;
    mapping(uint256 => uint256) public backfillAmounts;
    uint256 public currentActiveBackfillCycle;
    PolBridger public bridgeHelper;

    event BackfillCompleted(uint256 indexed backfillCycle, uint256 totalWithdraw);
    event BackfillStarted(uint256 indexed backfillCycle, uint256 polAmount, uint256 sPOLAmount);
    event ExchangeRateUpdateSent(uint256 totalsPOLBalance, uint256 totaldPOLBalance);
    event InvalidMessageType(uint8 msgType);
    event MigrationProcessed(uint256 polAmount, uint256 mintedSPOL);
    event BridgeHelperUpdated(address indexed oldBridger, address indexed newBridger);

    error BackfillAlreadyCompleted(uint256 backfillCycle);
    error BackfillAlreadyOngoing(uint256 backfillCycle);
    error BackfillNotActive(uint256 backfillCycle);
    error NotEnoughPOLInMessenger(uint256 required, uint256 available);
    error NotEnoughSPOLInMessenger(uint256 required, uint256 available);
    error ZeroAddress();

    constructor(
        address _polToken,
        address _sPOLToken,
        address _sPOLController,
        address _rootChainManager,
        address _depositManager,
        address _stateSender,
        address _checkpointManager,
        address _childTunnel
    ) BaseRootTunnel(_stateSender, _checkpointManager, _childTunnel) {
        require(_polToken != address(0), ZeroAddress());
        require(_sPOLToken != address(0), ZeroAddress());
        require(_sPOLController != address(0), ZeroAddress());
        require(_rootChainManager != address(0), ZeroAddress());
        require(_depositManager != address(0), ZeroAddress());
        require(_stateSender != address(0), ZeroAddress());
        require(_checkpointManager != address(0), ZeroAddress());
        require(_childTunnel != address(0), ZeroAddress());

        polToken = IERC20(_polToken);
        sPOLToken = IERC20(_sPOLToken);
        sPOLController = IsPOLController(_sPOLController);
        rootChainManager = IRootChainManager(_rootChainManager);
        depositManager = IDepositManager(_depositManager);

        _disableInitializers();
    }

    /// @notice Initializes the messenger with access control, bridge helper wiring, and token approvals
    /// @dev Sets up approvals for sPOLController (POL staking) and bridge contracts (POL/sPOL transfers).
    /// @param _authority AccessManager contract for restricted function access
    /// @param _rcmERC20Predicate RootChainManager ERC20 predicate for sPOL bridge deposits
    /// @param _bridgeHelper PolBridger proxy used to process L2 migration POL exits
    function initialize(address _authority, address _rcmERC20Predicate, address _bridgeHelper) external initializer {
        require(_authority != address(0), ZeroAddress());
        require(_rcmERC20Predicate != address(0), ZeroAddress());
        require(_bridgeHelper != address(0), ZeroAddress());

        __AccessManaged_init(_authority);

        bridgeHelper = PolBridger(_bridgeHelper);

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
            emit InvalidMessageType(uint8(msgType));
            return;
        }
    }

    function _handleMigration(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _mintedSPOL) = _decodeL2MigrationRequestMessage(_msg);
        bridgeHelper.takePOLL1(_polAmount);
        uint256 polBalance = polToken.balanceOf(address(this));
        require(polBalance >= _polAmount, NotEnoughPOLInMessenger(_polAmount, polBalance));

        // +1 to compensate for rounding loss in the sPOL->POL->sPOL round-trip,
        uint256 requiredPOL = sPOLController.convertSPOLtoPOL(_mintedSPOL) + 1;
        sPOLController.buySPOL(requiredPOL);
        // send surplus POL to controller, to be cleaned up later
        polToken.transfer(address(sPOLController), polBalance - requiredPOL);
        require(
            sPOLToken.balanceOf(address(this)) >= _mintedSPOL,
            NotEnoughSPOLInMessenger(_mintedSPOL, sPOLToken.balanceOf(address(this)))
        );

        rootChainManager.depositFor(childTunnel, address(sPOLToken), abi.encode(_mintedSPOL));
        // disabled for portal because of cyclical exit issue, should be activated for lxly
        //_sendMessageToChild(abi.encode(MsgType.L1_MIGRATION_RESPONSE, encodeL1MigrationResponseMessage(_mintedSPOL)));
        emit MigrationProcessed(_polAmount, _mintedSPOL);
    }

    function _handleBackfill(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle) = _decodeL2BackfillRequestMessage(_msg);
        uint256 sPOLBalance = sPOLToken.balanceOf(address(this));

        require(currentActiveBackfillCycle == 0, BackfillAlreadyOngoing(currentActiveBackfillCycle));
        require(!completedBackfill[_backFillCycle], BackfillAlreadyCompleted(_backFillCycle));
        require(backfillAmounts[_backFillCycle] == 0, BackfillAlreadyOngoing(_backFillCycle));
        require(sPOLBalance >= _sPOLAmount, NotEnoughSPOLInMessenger(_sPOLAmount, sPOLBalance));

        sPOLController.sellSPOL(sPOLBalance);
        backfillAmounts[_backFillCycle] = _polAmount;
        currentActiveBackfillCycle = _backFillCycle;
        emit BackfillStarted(_backFillCycle, _polAmount, _sPOLAmount);
    }

    /// @notice Completes an active backfill by withdrawing POL and bridging it to L2
    /// @dev Must be called after StakeManager's unbonding period. Attempts to withdraw from sPOLController,
    ///      then bridges the POL to L2 and notifies sPOLChild via state sync message.
    function completeBackfill() external restricted nonReentrant {
        uint256 processingBackfillCycle = currentActiveBackfillCycle;
        uint256 totalRequested = backfillAmounts[processingBackfillCycle];

        require(processingBackfillCycle != 0, BackfillNotActive(0));
        require(!completedBackfill[processingBackfillCycle], BackfillAlreadyCompleted(processingBackfillCycle));
        require(totalRequested > 0, BackfillNotActive(processingBackfillCycle));

        try sPOLController.withdrawPOL() {} catch {}

        uint256 polBalance = polToken.balanceOf(address(this));
        require(polBalance >= totalRequested, NotEnoughPOLInMessenger(totalRequested, polBalance));
        // send surplus POL to controller, to be cleaned up later
        polToken.transfer(address(sPOLController), polBalance - totalRequested);
        depositManager.depositERC20ForUser(address(polToken), childTunnel, totalRequested);
        _sendMessageToChild(
            abi.encode(
                MsgType.L1_BACKFILL_RESPONSE, _encodeL1BackfillResponseMessage(totalRequested, processingBackfillCycle)
            )
        );
        completedBackfill[processingBackfillCycle] = true;
        emit BackfillCompleted(processingBackfillCycle, totalRequested);
        currentActiveBackfillCycle = 0;
    }

    /// @notice Sends current L1 exchange rate to L2 via state sync
    /// @dev Reads totaldPOLBalance (minus fees) and totalsPOLBalance from controller, then sends to L2.
    ///      L2 uses this to calculate buy/sell operations.
    function updateL2ExchangeRate() external restricted nonReentrant {
        uint256 totalsPOLBalance = sPOLController.totalsPOLBalance();
        uint256 totaldPOLBalance = sPOLController.totaldPOLBalance() - sPOLController.feedPOLBalance();

        _sendMessageToChild(
            abi.encode(MsgType.EXCHANGE_UPDATE, _encodeExchangeUpdateMessage(totalsPOLBalance, totaldPOLBalance))
        );
        emit ExchangeRateUpdateSent(totalsPOLBalance, totaldPOLBalance);
    }

    /// @notice Sets or updates the BridgeHelper address
    /// @dev Restricted to AccessManager.
    /// @param _bridgeHelper New BridgeHelper address
    function updateBridgeHelper(address _bridgeHelper) external restricted {
        require(_bridgeHelper != address(0), ZeroAddress());
        emit BridgeHelperUpdated(address(bridgeHelper), _bridgeHelper);
        bridgeHelper = PolBridger(_bridgeHelper);
    }
}
