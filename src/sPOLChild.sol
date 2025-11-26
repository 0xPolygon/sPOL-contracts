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

contract sPOLChild is
    Initializable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    ERC20PermitUpgradeable,
    BaseChildTunnel,
    MsgCoder
{
    // exchange info
    uint256 public l1SPOLBalance;
    uint256 public l1DPOLBalance;

    // Safety parameters for the delayed exchange rate from L1
    // fee in 1/100 of a percent
    uint16 public safetyFee;
    uint16 public constant SAFETY_FEE_DENOMINATOR = 10_000;
    uint256 public maxExchangeRateUpdateDelay;
    uint256 public lastExchangeRateUpdate;

    // local info
    // This should always be equal to reservedWithdrawPOLBalance + actualQuickRedeemReserve
    uint256 public polBalance;
    // Slow redeem
    // These three together should always be equal to the sum of outstanding POL in userOutstandingPOL
    uint256 public missingWithdrawPOLBalance;
    uint256 public reservedWithdrawPOLBalance;
    uint256 public pendingWithdrawPOLBalance;

    // Redeem reserve
    uint256 public targetQuickRedeemReserve;
    // This should be equal to polBalance - reservedWithdrawPOLBalance
    uint256 public actualQuickRedeemReserve;

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
        uint256 nonce;
    }

    mapping(address => UserOutstanding[]) public userOutstandingPOL;
    uint256 public globalWithdrawNonce;

    modifier onlyChildChainManager() {
        require(msg.sender == childChainManager, "Only Child Chain Manager can call this function");
        _;
    }

    event sPOLMinted(address user, uint256 amountPOL, uint256 amountSPOL);
    event sPOLBurned(address user, uint256 amountSPOL, uint256 amountPOL, uint256 nonce);
    event POLWithdrawn(address user, uint256 amountPOL, uint256 nonce);

    constructor(address _stateSyncer) BaseChildTunnel(_stateSyncer) {
        _disableInitializers();
    }

    function initialize(address _authority, address _l1Messenger, address _bridgeHelper, address _childChainManager)
        external
        initializer
    {
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

        // Should be 0, changing it requires a pol deposit
        targetQuickRedeemReserve = 0;

        // Init so update can work
        // we leave lastExchangeRateUpdate at 0 so no one can buy sPOL before first update
        // sell still works, but with this exchange rate it's very unfavorable
        l1DPOLBalance = 1;
        l1SPOLBalance = 1;
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
        require(lastExchangeRateUpdate + maxExchangeRateUpdateDelay >= block.timestamp, "Exchange rate update too old");
        require(msg.value == _polAmount, "Incorrect POL amount sent");
        require(_polAmount > 0, "POL amount must be greater than 0");
        uint256 spolToMint = convertPOLToSPOL(_polAmount);
        locallyMintedSPOL += spolToMint;
        actualQuickRedeemReserve += _polAmount;
        polBalance += _polAmount;
        _mint(msg.sender, spolToMint);
        emit sPOLMinted(msg.sender, _polAmount, spolToMint);
    }

    function sellSPOL(uint256 _sPOLAmount) external whenNotPaused {
        _transfer(msg.sender, address(this), _sPOLAmount);
        locallyToBeBurnedSPOL += _sPOLAmount;
        uint256 polToReturn = convertSPOLToPOL(_sPOLAmount);
        emit sPOLBurned(msg.sender, _sPOLAmount, polToReturn, ++globalWithdrawNonce);
        if (actualQuickRedeemReserve >= polToReturn) {
            _quickSellSPOL(polToReturn);
        } else {
            _slowSellSPOL(polToReturn);
        }
    }

    function _quickSellSPOL(uint256 _polAmount) internal {
        actualQuickRedeemReserve -= _polAmount;
        polBalance -= _polAmount;
        (bool success,) = payable(msg.sender).call{value: _polAmount}("");
        require(success, "POL transfer failed");
        emit POLWithdrawn(msg.sender, _polAmount, globalWithdrawNonce);
    }

    function _slowSellSPOL(uint256 _polAmount) internal {
        missingWithdrawPOLBalance += _polAmount;
        UserOutstanding memory userOutstanding =
            UserOutstanding({outstandingPOL: _polAmount, backFillCycle: backFillCycle + 1, nonce: globalWithdrawNonce});
        userOutstandingPOL[msg.sender].push(userOutstanding);
    }

    function withdrawPOL() external whenNotPaused {
        UserOutstanding[] storage outstandings = userOutstandingPOL[msg.sender];
        uint256 totalToWithdraw = 0;
        bool reordered;
        for (uint256 i = 0; i < outstandings.length; i++) {
            if (reordered) {
                reordered = false;
                i--;
            }
            if (completedBackfills[outstandings[i].backFillCycle]) {
                reservedWithdrawPOLBalance -= outstandings[i].outstandingPOL;
            } else if (outstandings[i].backFillCycle == backFillCycle) {
                pendingWithdrawPOLBalance -= outstandings[i].outstandingPOL;
            } else if (outstandings[i].outstandingPOL <= actualQuickRedeemReserve) {
                actualQuickRedeemReserve -= outstandings[i].outstandingPOL;
                missingWithdrawPOLBalance -= outstandings[i].outstandingPOL;
            } else {
                continue;
            }
            totalToWithdraw += outstandings[i].outstandingPOL;
            emit POLWithdrawn(msg.sender, outstandings[i].outstandingPOL, outstandings[i].nonce);

            outstandings[i] = outstandings[outstandings.length - 1];
            outstandings.pop();
            reordered = true;
        }
        require(totalToWithdraw > 0, "No POL to withdraw");
        polBalance -= totalToWithdraw;
        payable(msg.sender).transfer(totalToWithdraw);
    }

    /////////////////////////////////
    ///  Token Bridging           ///
    /////////////////////////////////

    function deposit(address user, bytes calldata depositData) external onlyChildChainManager {
        uint256 amount = abi.decode(depositData, (uint256));
        if (user == address(this) && onGoingMigration && amount == backMigratingSPOL) {
            onGoingMigration = false;
            backMigratingSPOL = 0;
            // this means the bridged sPOL from the current migration has arrived
            // we don't mint it, as the needed burn would generate an exit event again
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
            revert("Migration response handling for portal disabled");
            //handleMigrationResponse(actualMessage);
        } else if (msgType == MsgType.L1_BACKFILL_RESPONSE) {
            _handleBackfillResponse(actualMessage);
        } else {
            // maybe don't revert here to avoid failedStateSync issues
            revert("Invalid message type");
        }
    }

    function _handleExchangeRateUpdate(bytes memory _msg) internal {
        (uint256 updatedl1SPOLBalance, uint256 updatedl1DPOLBalance) = _decodeExchangeUpdateMessage(_msg);
        uint256 currentConversion = convertSPOLToPOL(1e18);
        l1SPOLBalance = updatedl1SPOLBalance;
        l1DPOLBalance = updatedl1DPOLBalance;
        uint256 newConversion = convertSPOLToPOL(1e18);
        // this then stays in failedstatesync, maybe don't revert, but ignore?
        require(newConversion >= currentConversion, "Exchange rate declined");
        lastExchangeRateUpdate = block.timestamp;
    }

    //////////////////////////////
    ///  Migration/Backfill    ///
    //////////////////////////////

    function _handleBackfillResponse(bytes memory _msg) internal {
        (uint256 _returnedPOL, uint256 _backFillCycle) = _decodeL1BackfillResponseMessage(_msg);
        if (_returnedPOL > pendingWithdrawPOLBalance) {
            uint256 leftOver = _returnedPOL - pendingWithdrawPOLBalance;
            actualQuickRedeemReserve += leftOver;
            reservedWithdrawPOLBalance += pendingWithdrawPOLBalance;
            pendingWithdrawPOLBalance = 0;
        } else {
            pendingWithdrawPOLBalance -= _returnedPOL;
            reservedWithdrawPOLBalance += _returnedPOL;
        }
        polBalance += _returnedPOL;
        completedBackfills[_backFillCycle] = true;
        onGoingBackfill = false;
    }

    function requestMigration() external whenNotPaused {
        require(!onGoingMigration, "Migration already ongoing");
        require(targetQuickRedeemReserve <= actualQuickRedeemReserve, "Nothing to migrate");
        onGoingMigration = true;

        uint256 polToMigrate = polBalance - targetQuickRedeemReserve - reservedWithdrawPOLBalance;
        actualQuickRedeemReserve -= polToMigrate;
        polBalance -= polToMigrate;

        uint256 sPOLToAddToBridge;
        // maybe do this on response
        if (locallyMintedSPOL > locallyToBeBurnedSPOL) {
            sPOLToAddToBridge = locallyMintedSPOL - locallyToBeBurnedSPOL;
            locallyMintedSPOL -= locallyToBeBurnedSPOL;
            locallyToBeBurnedSPOL = 0;
        } else {
            locallyToBeBurnedSPOL -= locallyMintedSPOL;
            locallyMintedSPOL = 0;
        }
        backMigratingSPOL = sPOLToAddToBridge;
        _exitPOLforMessenger(polToMigrate);
        _sendMessageToRoot(
            abi.encode(MsgType.L2_MIGRATION_REQUEST, _encodeL2MigrationRequestMessage(polToMigrate, sPOLToAddToBridge))
        );
    }

    function requestBackfill() external whenNotPaused {
        require(!onGoingBackfill, "Backfill already ongoing");
        onGoingBackfill = true;
        backFillCycle += 1;
        pendingWithdrawPOLBalance += missingWithdrawPOLBalance;

        missingWithdrawPOLBalance = 0;
        uint256 bridgeMissingSPOL;
        if (locallyMintedSPOL > locallyToBeBurnedSPOL) {
            bridgeMissingSPOL = locallyMintedSPOL - locallyToBeBurnedSPOL;
            _burnSPOLForMessenger(bridgeMissingSPOL);
            locallyMintedSPOL -= locallyToBeBurnedSPOL;
            locallyToBeBurnedSPOL = 0;
        }
        _sendMessageToRoot(
            abi.encode(
                MsgType.L2_BACKFILL_REQUEST,
                _encodeL2BackfillRequestMessage(pendingWithdrawPOLBalance, bridgeMissingSPOL, backFillCycle)
            )
        );
    }

    ///////////////////////////////
    ///  Config                 ///
    ///////////////////////////////

    function setQuickRedeemBufferSize(uint256 _newSize) external restricted {
        targetQuickRedeemReserve = _newSize;
    }

    function setSafetyFee(uint16 _newFee) external restricted {
        require(_newFee <= SAFETY_FEE_DENOMINATOR / 10, "Fee too high");
        safetyFee = _newFee;
    }

    function setMaxExchangeRateUpdateDelay(uint256 _newDelay) external restricted {
        maxExchangeRateUpdateDelay = _newDelay;
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

