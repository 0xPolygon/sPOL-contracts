// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PolBridger} from "./polBridger.sol";

import {BaseChildTunnel} from "./msg/BaseChildTunnel.sol";
import {MsgCoder} from "./MsgCoder.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

contract sPOLChild is
    Initializable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardTransient,
    BaseChildTunnel,
    MsgCoder
{
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    // exchange info
    uint256 public l1SPOLBalance;
    uint256 public l1DPOLBalance;

    // Safety parameters for the delayed exchange rate from L1
    // fee in 1/100 of a percent
    uint16 public safetyFee;
    uint16 public constant SAFETY_FEE_DENOMINATOR = 10_000;
    uint16 public constant MAX_SAFETY_FEE = 100; // max 1%
    uint256 public maxExchangeRateUpdateDelay;
    uint256 public lastExchangeRateUpdate;

    // local info
    uint256 public polBalance;
    // These three together should always be equal to the sum of outstanding POL in userOutstandingPOL
    uint256 public missingWithdrawPOLBalance;
    uint256 public reservedWithdrawPOLBalance;
    uint256 public requestedWithdrawPOLBalance;

    // sPOL originating on L2 needs to be locked in the bridge from L1 so it becomes "real"
    uint256 public locallyMintedSPOL;
    // sPOL that was burned on L2 needs to be released from bridge on L1 and also burned there
    uint256 public locallyToBeBurnedSPOL;
    // L1 Messenger that needs to receive the sPOL to complete migrations/backfills
    address public l1Messenger;
    // Bridge helper contract, because POL has no withdrawFor function
    PolBridger public bridgeHelper;

    // Depositor bridge contract of sPOL
    address public childChainManager;

    // Migration and backfill tracking
    uint256 public backFillCycle;
    mapping(uint256 => bool) public completedBackfills;
    bool public onGoingMigration;
    bool public onGoingBackfill;
    uint256 public backMigratingSPOL;

    struct UserOutstanding {
        uint256 outstandingPOL;
        uint256 backFillCycle;
    }

    struct UserOutstandingFull {
        uint256 outstandingPOL;
        uint256 backFillCycle;
        uint256 nonce;
    }

    // Nonce to Outstanding
    mapping(uint256 => UserOutstanding) public userOutstandingWithdraw;
    // User to nonces
    mapping(address => DoubleEndedQueue.Bytes32Deque) public userOutstandingNonces;
    uint256 public globalWithdrawNonce;

    // Stake/unstake events
    event sPOLMinted(address user, uint256 amountPOL, uint256 amountSPOL);
    event sPOLBurned(address user, uint256 amountSPOL, uint256 amountPOL, uint256 nonce);
    event POLWithdrawn(address user, uint256 amountPOL, uint256 nonce);

    // Exchange rate and operational events
    event ExchangeRateUpdated(
        uint256 oldSPOLBalance, uint256 oldDPOLBalance, uint256 newSPOLBalance, uint256 newDPOLBalance
    );
    event SafetyFeeChanged(uint16 oldFee, uint16 newFee);
    event MaxExchangeRateDelayChanged(uint256 oldDelay, uint256 newDelay);

    // Migration and backfill events
    event BackfillCompleted(uint256 returnedPOL, uint256 backfillCycle);
    event BackfillLocalCompleted(uint256 reservedPOL, uint256 backfillCycle);
    event BackfillRequested(uint256 backfillPOLAmount, uint256 toBeBurnedSPOL, uint256 backfillCycle);
    event BackfillStarted(uint256 backfillPOLAmount, uint256 backfillCycle);
    event BalancedOnlyLocally();
    event MigrationCompleted(uint256 backMigratingSPOL);
    event MigrationRequested(uint256 migratingPOLAmount, uint256 bridgeMissingSPOL);

    error AddressUnauthorized(address caller);
    error BackfillAlreadyOngoing();
    error ExchangeRateDeclined(uint256 newRate, uint256 currentRate);
    error ExchangeRateUpdateTooOld(uint256 lastUpdate, uint256 maxAge, uint256 currentTime);
    error FeeTooHigh(uint16 provided, uint16 maxAllowed);
    error IncorrectPOLAmount(uint256 sent, uint256 expected);
    error InvalidMessageType();
    error MigrationAlreadyOngoing();
    error NothingToBackfill();
    error NothingToBalance();
    error NothingToMigrate();
    error POLAmountMustBeGreaterThanZero();
    error POLTransferFailed();
    error ZeroAddress();

    modifier onlyChildChainManager() {
        require(msg.sender == childChainManager, AddressUnauthorized(msg.sender));
        _;
    }

    constructor(address _stateSyncer) BaseChildTunnel(_stateSyncer) {
        require(_stateSyncer != address(0), ZeroAddress());

        _disableInitializers();
    }

    function initialize(address _authority, address _l1Messenger, address _bridgeHelper, address _childChainManager)
        external
        initializer
    {
        require(_authority != address(0), ZeroAddress());
        require(_l1Messenger != address(0), ZeroAddress());
        require(_bridgeHelper != address(0), ZeroAddress());
        require(_childChainManager != address(0), ZeroAddress());

        __Pausable_init();
        __ERC20_init("Staked POL", "sPOL");
        __ERC20Permit_init("Staked POL");
        __AccessManaged_init(_authority);

        maxExchangeRateUpdateDelay = 30 days;
        // we get about 0,25% rewards in a month, so if we pause after a month of no update
        // 0,3% should be safe so sPOL doesn't become cheaper than L1
        safetyFee = 30; // 0.3%
        l1Messenger = _l1Messenger;
        bridgeHelper = PolBridger(_bridgeHelper);
        childChainManager = _childChainManager;

        // Init so update can work
        // we leave lastExchangeRateUpdate at 0 so no one can buy sPOL before first update
        // sell still works, but with this exchange rate it's very unfavorable
        l1DPOLBalance = 1;
        l1SPOLBalance = 1;

        _pause();
    }

    ///////////////////////////////
    ///  Stake/Unstake          ///
    ///////////////////////////////

    // balances are delayed from L1, so converting to sPOL is better than on L1, to avoid this we add a small fee
    // this fee isn't separately collected, so it just benefits all sPOL holders
    // conversely the conversion from sPOL to POL is automatically worse than on L1
    // this way we always stay on the safe side regarding arbitraging
    function convertSPOLToPOL(uint256 _sPOLAmount) public view returns (uint256) {
        if (_sPOLAmount == 0) {
            return 0;
        }
        return (_sPOLAmount * l1DPOLBalance) / l1SPOLBalance;
    }

    function convertPOLToSPOL(uint256 _polAmount) public view returns (uint256) {
        if (_polAmount == 0) {
            return 0;
        }
        return
            (_polAmount * l1SPOLBalance * (SAFETY_FEE_DENOMINATOR - safetyFee))
                / (l1DPOLBalance * SAFETY_FEE_DENOMINATOR);
    }

    function buySPOL(uint256 _polAmount) external payable whenNotPaused {
        require(
            lastExchangeRateUpdate + maxExchangeRateUpdateDelay >= block.timestamp,
            ExchangeRateUpdateTooOld(lastExchangeRateUpdate, maxExchangeRateUpdateDelay, block.timestamp)
        );
        require(msg.value == _polAmount, IncorrectPOLAmount(msg.value, _polAmount));
        require(_polAmount > 0, POLAmountMustBeGreaterThanZero());
        uint256 spolToMint = convertPOLToSPOL(_polAmount);
        locallyMintedSPOL += spolToMint;
        polBalance += _polAmount;
        _mint(msg.sender, spolToMint);
        emit sPOLMinted(msg.sender, _polAmount, spolToMint);
    }

    function sellSPOL(uint256 _sPOLAmount) external whenNotPaused nonReentrant {
        require(_sPOLAmount > 0, POLAmountMustBeGreaterThanZero());
        _transfer(msg.sender, address(this), _sPOLAmount);
        locallyToBeBurnedSPOL += _sPOLAmount;
        uint256 polToReturn = convertSPOLToPOL(_sPOLAmount);
        missingWithdrawPOLBalance += polToReturn;

        UserOutstanding memory userOutstanding =
            UserOutstanding({outstandingPOL: polToReturn, backFillCycle: backFillCycle + 1});
        userOutstandingWithdraw[++globalWithdrawNonce] = userOutstanding;
        userOutstandingNonces[msg.sender].pushBack(bytes32(globalWithdrawNonce));
        emit sPOLBurned(msg.sender, _sPOLAmount, polToReturn, globalWithdrawNonce);
    }

    function getUserOutstandingNonces(address _user) external view returns (UserOutstandingFull[] memory) {
        DoubleEndedQueue.Bytes32Deque storage outstandingNonces = userOutstandingNonces[_user];
        uint256 length = outstandingNonces.length();
        UserOutstandingFull[] memory userOutstandings = new UserOutstandingFull[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 nonce = uint256(outstandingNonces.at(i));
            UserOutstanding storage currentOutstanding = userOutstandingWithdraw[nonce];
            userOutstandings[i] = UserOutstandingFull({
                outstandingPOL: currentOutstanding.outstandingPOL,
                backFillCycle: currentOutstanding.backFillCycle,
                nonce: nonce
            });
        }
        return userOutstandings;
    }

    function withdrawPOL() external whenNotPaused nonReentrant {
        DoubleEndedQueue.Bytes32Deque storage outstandingNonces = userOutstandingNonces[msg.sender];
        uint256 totalToWithdraw;
        while (!outstandingNonces.empty()) {
            uint256 currentNonce = uint256(outstandingNonces.front());
            UserOutstanding storage currentOutstanding = userOutstandingWithdraw[currentNonce];
            if (completedBackfills[currentOutstanding.backFillCycle]) {
                totalToWithdraw += currentOutstanding.outstandingPOL;
                emit POLWithdrawn(msg.sender, currentOutstanding.outstandingPOL, currentNonce);
                delete userOutstandingWithdraw[currentNonce];
                outstandingNonces.popFront();
            } else {
                break;
            }
        }
        require(totalToWithdraw > 0, POLAmountMustBeGreaterThanZero());
        reservedWithdrawPOLBalance -= totalToWithdraw;
        polBalance -= totalToWithdraw;
        (bool success,) = payable(msg.sender).call{value: totalToWithdraw}("");
        require(success, POLTransferFailed());
    }

    /////////////////////////////////
    ///  Token Bridging           ///
    /////////////////////////////////

    function deposit(address user, bytes calldata depositData) external onlyChildChainManager {
        uint256 amount = abi.decode(depositData, (uint256));
        if (user == address(this) && onGoingMigration && amount == backMigratingSPOL) {
            onGoingMigration = false;
            uint256 completedMigration = backMigratingSPOL;
            backMigratingSPOL = 0;
            // this means the bridged sPOL from the current migration has arrived
            // we don't mint it, as the needed burn would generate an exit event again
            emit MigrationCompleted(completedMigration);
        } else {
            _mint(user, amount);
        }
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    ///////////////////////////////
    ///  Message Handling       ///
    ///////////////////////////////

    function _processMessageFromRoot(bytes memory message) internal virtual override {
        (MsgType msgType, bytes memory actualMessage) = abi.decode(message, (MsgType, bytes));
        if (msgType == MsgType.EXCHANGE_UPDATE) {
            _handleExchangeRateUpdate(actualMessage);
        } else if (msgType == MsgType.L1_MIGRATION_RESPONSE) {
            revert InvalidMessageType();
            //handleMigrationResponse(actualMessage);
        } else if (msgType == MsgType.L1_BACKFILL_RESPONSE) {
            _handleBackfillResponse(actualMessage);
        } else {
            // maybe don't revert here to avoid failedStateSync issues
            revert InvalidMessageType();
        }
    }

    function _handleExchangeRateUpdate(bytes memory _msg) internal {
        _balanceWithL1();
        (uint256 updatedl1SPOLBalance, uint256 updatedl1DPOLBalance) = _decodeExchangeUpdateMessage(_msg);
        uint256 currentConversion = convertSPOLToPOL(1e18);
        uint256 oldSPOLBalance = l1SPOLBalance;
        uint256 oldDPOLBalance = l1DPOLBalance;
        l1SPOLBalance = updatedl1SPOLBalance;
        l1DPOLBalance = updatedl1DPOLBalance;
        uint256 newConversion = convertSPOLToPOL(1e18);
        // this then stays in failedstatesync, maybe don't revert, but ignore?
        require(newConversion >= currentConversion, ExchangeRateDeclined(newConversion, currentConversion));
        lastExchangeRateUpdate = block.timestamp;
        emit ExchangeRateUpdated(oldSPOLBalance, oldDPOLBalance, updatedl1SPOLBalance, updatedl1DPOLBalance);
    }

    //////////////////////////////
    ///  Migration/Backfill    ///
    //////////////////////////////

    function _handleBackfillResponse(bytes memory _msg) internal {
        (uint256 returnedPOL, uint256 returnedBackFillCycle) = _decodeL1BackfillResponseMessage(_msg);
        require(
            returnedPOL == requestedWithdrawPOLBalance, IncorrectPOLAmount(returnedPOL, requestedWithdrawPOLBalance)
        );
        reservedWithdrawPOLBalance += returnedPOL;
        requestedWithdrawPOLBalance = 0;
        polBalance += returnedPOL;
        _completeBackfill(returnedPOL, returnedBackFillCycle);
    }

    function balanceWithL1() external restricted nonReentrant {
        _balanceWithL1();
    }

    function _balanceWithL1() internal {
        require(!onGoingMigration, MigrationAlreadyOngoing());
        require(!onGoingBackfill, BackfillAlreadyOngoing());

        uint256 surplusPOL = polBalance - reservedWithdrawPOLBalance;
        // more surplus than missing withdraw balance -> full local backfill possible
        if (surplusPOL >= missingWithdrawPOLBalance) {
            if (missingWithdrawPOLBalance > 0) {
                _startBackfill(missingWithdrawPOLBalance);
                surplusPOL -= missingWithdrawPOLBalance;
                _localBackfill(missingWithdrawPOLBalance);
                _completeBackfill(0, backFillCycle);
            }
            if (surplusPOL > 0) {
                if (locallyMintedSPOL >= locallyToBeBurnedSPOL) {
                    uint256 sPOLToBeMinted = locallyMintedSPOL - locallyToBeBurnedSPOL;
                    locallyMintedSPOL = 0;
                    locallyToBeBurnedSPOL = 0;
                    _requestMigration(surplusPOL, sPOLToBeMinted);
                } else {
                    // special case where the safety fee surplus is also expressed as extra sPOL to be burned
                    emit BalancedOnlyLocally();
                }
            } else {
                // surplus matched exactly the missing withdraw balance, or both were zero
                emit BalancedOnlyLocally();
            }
        } else {
            // not enough surplus, so request backfill
            _startBackfill(missingWithdrawPOLBalance);
            if (surplusPOL > 0) {
                _localBackfill(surplusPOL);
            }
            uint256 sPOLToBeBurned = locallyToBeBurnedSPOL - locallyMintedSPOL;
            locallyToBeBurnedSPOL = 0;
            locallyMintedSPOL = 0;
            _requestBackfill(missingWithdrawPOLBalance, sPOLToBeBurned);
            missingWithdrawPOLBalance = 0;
        }
    }

    function _requestMigration(uint256 _polToMigrate, uint256 _spolToMint) internal {
        onGoingMigration = true;
        backMigratingSPOL = _spolToMint;

        _exitPOLforMessenger(_polToMigrate);
        _sendMessageToRoot(
            abi.encode(MsgType.L2_MIGRATION_REQUEST, _encodeL2MigrationRequestMessage(_polToMigrate, _spolToMint))
        );
        emit MigrationRequested(_polToMigrate, _spolToMint);
    }

    function _startBackfill(uint256 _polToBackfill) internal {
        onGoingBackfill = true;
        backFillCycle += 1;
        emit BackfillStarted(_polToBackfill, backFillCycle);
    }

    function _localBackfill(uint256 _polBackfilled) internal {
        missingWithdrawPOLBalance -= _polBackfilled;
        reservedWithdrawPOLBalance += _polBackfilled;
        emit BackfillLocalCompleted(_polBackfilled, backFillCycle);
    }

    function _requestBackfill(uint256 _polToBackfill, uint256 _spolToSell) internal {
        requestedWithdrawPOLBalance += missingWithdrawPOLBalance;

        _burnSPOLForMessenger(_spolToSell);
        _sendMessageToRoot(
            abi.encode(
                MsgType.L2_BACKFILL_REQUEST, _encodeL2BackfillRequestMessage(_polToBackfill, _spolToSell, backFillCycle)
            )
        );
        emit BackfillRequested(_polToBackfill, _spolToSell, backFillCycle);
    }

    function _completeBackfill(uint256 _returnedPOL, uint256 _completedBackFillCycle) internal {
        completedBackfills[_completedBackFillCycle] = true;
        onGoingBackfill = false;
        emit BackfillCompleted(_returnedPOL, _completedBackFillCycle);
    }

    ///////////////////////////////
    ///  Config                 ///
    ///////////////////////////////

    function changeSafetyFee(uint16 _newFee) external restricted {
        require(_newFee <= MAX_SAFETY_FEE, FeeTooHigh(_newFee, MAX_SAFETY_FEE));
        uint16 oldFee = safetyFee;
        safetyFee = _newFee;
        emit SafetyFeeChanged(oldFee, _newFee);
    }

    function setMaxExchangeRateUpdateDelay(uint256 _newDelay) external restricted {
        uint256 oldDelay = maxExchangeRateUpdateDelay;
        maxExchangeRateUpdateDelay = _newDelay;
        emit MaxExchangeRateDelayChanged(oldDelay, _newDelay);
    }

    function pauseUserFunctions() external restricted {
        _pause();
    }

    function unpauseUserFunctions() external restricted {
        _unpause();
    }

    /////////////////////////////////
    ///  Internal Helpers       ///
    /////////////////////////////////

    function _burnSPOLForMessenger(uint256 _sPOLAmount) internal {
        _transfer(address(this), l1Messenger, _sPOLAmount);
        _burn(l1Messenger, _sPOLAmount);
    }

    function _exitPOLforMessenger(uint256 _polAmount) internal {
        bridgeHelper.bridgePOLToL1{value: _polAmount}(_polAmount);
    }
}

