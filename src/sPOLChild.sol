// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseChildTunnel} from "./msg/BaseChildTunnel.sol";
import {MsgCoder} from "./MsgCoder.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin-contracts-upgradeable-5.5.0/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

contract sPOLChild is BaseChildTunnel, ERC20PermitUpgradeable, MsgCoder {
    // exchange info
    uint256 public l1SPOLBalance;
    uint256 public l1DPOLBalance;
    // fee in 1/100 of a percent
    uint16 public safetyFee;
    uint16 public constant SAFETY_FEE_DENOMINATOR = 10_000;

    // local info
    uint256 public polBalance;
    // Slow redeem
    uint256 public missingWithdrawPOLBalance;
    uint256 public reservedWithdrawPOLBalance;

    // Redeem reserve
    uint256 public targetQuickRedeemReserve;
    uint256 public actualQuickRedeemReserve;
    uint256 public pendingQuickRedeemReserveRefill;

    uint256 public locallyMintedSPOL;
    uint256 public locallyBurnedSPOL;
    uint256 public sPOLtoBeBurned;

    uint256 public backFillCycle;
    mapping(uint256 => bool) public completedBackfills;
    bool public onGoingMigration;

    struct UserOutstanding {
        uint256 outstandingPOL;
        uint256 backFillCycle;
        uint256 nonce;
    }

    mapping(address => UserOutstanding[]) public userOutstandingPOL;
    uint256 public globalNonce;

    address public admin;

    event sPOLMinted(address user, uint256 amountPOL, uint256 amountSPOL);
    event sPOLBurned(address user, uint256 amountSPOL, uint256 amountPOL, uint256 nonce);
    event POLWithdrawn(address user, uint256 amountPOL, uint256 nonce);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call");
        _;
    }

    constructor(address _admin, address _stateSyncer) BaseChildTunnel(_stateSyncer) {
        admin = _admin;
    }

    //   function _sendMessageToRoot(bytes memory message)

    function _processMessageFromRoot(bytes memory message) internal virtual override {
        (MsgType msgType, bytes memory actualMessage) = abi.decode(message, (MsgType, bytes));
        if (msgType == MsgType.EXCHANGE_UPDATE) {
            handleExchangeRateUpdate(actualMessage);
        } else if (msgType == MsgType.L1_MIGRATION_RESPONSE) {
            handleMigrationResponse(actualMessage);
        } else if (msgType == MsgType.L1_BACKFILL_RESPONSE) {
            handleBackfillResponse(actualMessage);
        } else {
            revert("Invalid message type");
        }
    }

    function handleExchangeRateUpdate(bytes memory _msg) internal {
        uint256 currentConversion = convertSPOLToPOL(1e18);
        (uint256 updatedl1SPOLBalance, uint256 updatedl1DPOLBalance) = decodeExchangeUpdateMessage(_msg);
        l1SPOLBalance = updatedl1SPOLBalance;
        l1DPOLBalance = updatedl1DPOLBalance;
        uint256 newConversion = convertSPOLToPOL(1e18);
        // this then stays in failedstatesync, maybe don't revert, but ignore?
        require(newConversion >= currentConversion, "Exchange rate declined");
    }

    function requestMigration() external {
        require(!onGoingMigration, "Migration already ongoing");
        require(targetQuickRedeemReserve <= actualQuickRedeemReserve, "Nothing to migrate");
        onGoingMigration = true;

        uint256 polToMigrate = polBalance - targetQuickRedeemReserve - reservedWithdrawPOLBalance;
        actualQuickRedeemReserve -= polToMigrate;
        polBalance -= polToMigrate;

        uint256 sPOLToAddToBridge;
        // maybe do this on response
        if (locallyMintedSPOL > locallyBurnedSPOL) {
            sPOLToAddToBridge = locallyMintedSPOL - locallyBurnedSPOL;
            locallyMintedSPOL -= locallyBurnedSPOL;
            locallyBurnedSPOL = 0;
        } else {
            locallyBurnedSPOL -= locallyMintedSPOL;
            locallyMintedSPOL = 0;
        }
        _sendMessageToRoot(
            abi.encode(MsgType.L2_MIGRATION_REQUEST, encodeL2MigrationRequestMessage(polToMigrate, sPOLToAddToBridge))
        );
    }

    // this could be skipped, if we detect on the deposit that it comes from the messenger, then just don't mint
    function handleMigrationResponse(bytes memory _msg) internal {
        // failedStateSync issue again
        require(onGoingMigration, "No migration ongoing");
        onGoingMigration = false;
        (uint256 returnedSPOL) = decodeL1MigrationResponseMessage(_msg);
        // if this fails we need to keep the statesync to perform it after the bridging completes
        _burn(address(this), returnedSPOL);
    }

    function requestBackfill() external {
        backFillCycle += 1;
        uint256 _backFillCycle = backFillCycle;
        uint256 amountToBackfill = missingWithdrawPOLBalance;
        if (targetQuickRedeemReserve > actualQuickRedeemReserve + pendingQuickRedeemReserveRefill) {
            uint256 missingQuickRedeem =
                targetQuickRedeemReserve - actualQuickRedeemReserve - pendingQuickRedeemReserveRefill;
            pendingQuickRedeemReserveRefill += missingQuickRedeem;
            amountToBackfill += missingQuickRedeem;
        }
        missingWithdrawPOLBalance = 0;
        uint256 bridgeMissingSPOL;
        if (locallyMintedSPOL > locallyBurnedSPOL) {
            bridgeMissingSPOL = locallyMintedSPOL - locallyBurnedSPOL;
        }
        // we need to create spol and bridge it back over to L1
        _sendMessageToRoot(
            abi.encode(
                MsgType.L2_BACKFILL_REQUEST,
                encodeL2BackfillRequestMessage(amountToBackfill, bridgeMissingSPOL, _backFillCycle)
            )
        );
    }

    function handleBackfillResponse(bytes memory _msg) internal {
        (uint256 _returnedPOL, uint256 _backFillCycle) = decodeL1BackfillResponseMessage(_msg);
        missingWithdrawPOLBalance -= _returnedPOL;
        polBalance += _returnedPOL;
        completedBackfills[_backFillCycle] = true;
    }

    // balances are delayed from L1, so converting to sPOL is better than on L1, to avoid this we add a small fee
    // this fee isn't separately collected, so it just benefits all sPOL holders
    // conversely the conversion from sPOL to POL is automatically worse than on L1
    // this way we always stay on the safe side regarding arbitraging
    function convertSPOLToPOL(uint256 _sPOLAmount) public view returns (uint256) {
        if (_sPOLAmount == 0) {
            return 0;
        }
        if (l1SPOLBalance == 0) {
            return _sPOLAmount;
        }
        return (_sPOLAmount * l1DPOLBalance / l1SPOLBalance);
    }

    function convertPOLToSPOL(uint256 _polAmount) public view returns (uint256) {
        if (_polAmount == 0) {
            return 0;
        }
        if (_polAmount == 0) {
            return _polAmount;
        }
        return
            (_polAmount * l1SPOLBalance / l1DPOLBalance) * (SAFETY_FEE_DENOMINATOR - safetyFee) / SAFETY_FEE_DENOMINATOR;
    }

    function buySPOL(uint256 _polAmount) external payable {
        require(msg.value == _polAmount, "Incorrect POL amount sent");
        uint256 spolToMint = convertPOLToSPOL(_polAmount);
        locallyMintedSPOL += spolToMint;
        actualQuickRedeemReserve += _polAmount;
        polBalance += _polAmount;
        _mint(msg.sender, spolToMint);
        emit sPOLMinted(msg.sender, _polAmount, spolToMint);
    }

    function sellSPOL(uint256 _sPOLAmount) external {
        //_burn(msg.sender, _sPOLAmount);
        _transfer(msg.sender, address(this), _sPOLAmount);
        sPOLtoBeBurned += _sPOLAmount;
        locallyBurnedSPOL += _sPOLAmount;
        uint256 polToReturn = convertSPOLToPOL(_sPOLAmount);
        emit sPOLBurned(msg.sender, _sPOLAmount, polToReturn, globalNonce++);
        if (actualQuickRedeemReserve >= polToReturn) {
            _quickSellSPOL(polToReturn);
        } else {
            _slowSellSPOL(polToReturn);
        }
    }

    function _quickSellSPOL(uint256 _polAmount) internal {
        actualQuickRedeemReserve -= _polAmount;
        polBalance -= _polAmount;
        payable(msg.sender).transfer(_polAmount);
        emit POLWithdrawn(msg.sender, _polAmount, globalNonce);
    }

    function _slowSellSPOL(uint256 _polAmount) internal {
        missingWithdrawPOLBalance += _polAmount;
        UserOutstanding memory userOutstanding =
            UserOutstanding({outstandingPOL: _polAmount, backFillCycle: backFillCycle, nonce: globalNonce});
        userOutstandingPOL[msg.sender].push(userOutstanding);
    }

    function withdrawPOL() external {
        UserOutstanding[] storage outstandings = userOutstandingPOL[msg.sender];
        uint256 totalToWithdraw = 0;
        for (uint256 i = 0; i < outstandings.length; i++) {
            if (completedBackfills[outstandings[i].backFillCycle]) {
                reservedWithdrawPOLBalance -= outstandings[i].outstandingPOL;
            } else if (outstandings[i].outstandingPOL >= actualQuickRedeemReserve) {
                actualQuickRedeemReserve -= outstandings[i].outstandingPOL;
                missingWithdrawPOLBalance -= outstandings[i].outstandingPOL;
            } else {
                continue;
            }
            totalToWithdraw += outstandings[i].outstandingPOL;
            outstandings[i] = outstandings[outstandings.length - 1];
            outstandings.pop();
            i--;
            emit POLWithdrawn(msg.sender, outstandings[i].outstandingPOL, outstandings[i].nonce);
        }
        require(totalToWithdraw > 0, "No POL to withdraw");
        polBalance -= totalToWithdraw;
        payable(msg.sender).transfer(totalToWithdraw);
    }

    function setQuickRedeemBufferSize(uint256 _newSize) external onlyAdmin {
        targetQuickRedeemReserve = _newSize;
    }
}

