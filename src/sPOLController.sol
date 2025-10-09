// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IPolygonMigration} from "./interfaces/IPolygonMigration.sol";
import {
    StakeManager as IStakeManager, StakeManagerStorage as StakeManagerStatus
} from "./interfaces/IStakeManager.sol";
import {ValidatorShare as IValidatorShare} from "./interfaces/IValidatorShare.sol";
import {sPOL} from "./sPOL.sol";

contract sPOLController {
    struct ValidatorInfo {
        ValidatorStatus status;
        uint8 depositShare;
        uint16 index;
        IValidatorShare validatorContract;
        uint256 totalStaked;
    }

    enum ValidatorStatus {
        INACTIVE,
        ACTIVE,
        DEACTIVATED,
        FROZEN
    }

    address public admin;

    ERC20Permit public immutable polToken;
    ERC20 public immutable maticToken;
    IPolygonMigration public immutable polygonMigration;
    IStakeManager public immutable stakeManager;
    sPOL public immutable sPOLToken;

    // in percentage points
    uint8 public maxDivergence;

    mapping(uint16 => ValidatorInfo) public validators;
    uint16[] public validatorList;
    uint16[] public activeValidators;
    uint16 public lastSuccessfulBuyValidator;
    uint16 public lastSuccessfulSellValidator;

    uint256 public totaldPOLBalance;
    // two functions add rewards to dPOL balance (here take a fee, as in add to accumulatedFees, but also add to totaldPOLBalance)
    // or maybe a new fPOL balance as dPOL after fees, and calc dPOL balance, saves some gas
    // and a add stake to dPOL balance (no fee)

    uint8 public rewardFee;
    // In per mill, so 100 = 10%
    uint16 public constant MAX_FEE = 1000;
    address public feeReceiver;
    uint256 public feedPOLBalance;

    struct NonceDetails {
        uint16 validatorId;
        uint128 amount;
        uint96 validatorNonce;
    }

    mapping(address => uint256[]) public userNonces;
    mapping(uint256 => NonceDetails) public withdrawNonceDetails;

    uint256 public globalWithdrawNonce;

    uint256 public maxUnstake;

    modifier onlyAdmin() {
        require(msg.sender == admin, "ONLY_ADMIN");
        _;
    }

    constructor(
        address _polToken,
        address _maticToken,
        address _polygonMigration,
        address _sPOLToken,
        address _stakeManager
    ) {
        polToken = ERC20Permit(_polToken);
        maticToken = ERC20(_maticToken);
        polygonMigration = IPolygonMigration(_polygonMigration);
        sPOLToken = sPOL(_sPOLToken);
        stakeManager = IStakeManager(_stakeManager);
    }

    function initialize(uint8 _rewardFee, address _feeReceiver, uint8 _maxDivergence, address _admin) external {
        require(rewardFee <= MAX_FEE, "FEE_TOO_LARGE");
        rewardFee = _rewardFee;
        feeReceiver = _feeReceiver;
        maxDivergence = _maxDivergence;
        admin = _admin;
    }

    ///////////////////////////////
    ///  Validator Management   ///
    ///////////////////////////////

    function addValidator(uint16 _validatorID) external onlyAdmin {
        require(stakeManager.isValidator(_validatorID), "NOT_ACTIVE_VALIDATOR");

        IValidatorShare validatorContract = IValidatorShare(stakeManager.getValidatorContract(_validatorID));
        require(address(validatorContract) != address(0), "NO_DELEGATION");

        validators[_validatorID] = ValidatorInfo({
            status: ValidatorStatus.ACTIVE,
            index: _validatorID,
            totalStaked: 0,
            validatorContract: validatorContract,
            depositShare: 0
        });
        validatorList.push(_validatorID);
        activeValidators.push(_validatorID);
    }

    function removeValidator(uint16 _removedValidator) external onlyAdmin {
        ValidatorInfo storage removedValidator = validators[_removedValidator];
        require(removedValidator.totalStaked == 0, "STILL_FUNDED");
        require(stakeManager.delegatorsReward(_removedValidator) == 0, "REWARDS_PENDING");
        require(removedValidator.status == ValidatorStatus.ACTIVE, "NOT_ACTIVE");

        require(removedValidator.validatorContract.balanceOf(address(this)) == 0, "SHARES_PENDING");
        require(removedValidator.validatorContract.getLiquidRewards(address(this)) == 0, "REWARDS_PENDING");

        removedValidator.status = ValidatorStatus.DEACTIVATED;
        removedValidator.depositShare = 0;
        _removeFromActiveValidators(_removedValidator);
    }

    function freezeValidator(uint16 _validator) external onlyAdmin {
        require(validators[_validator].status == ValidatorStatus.ACTIVE, "NOT_ACTIVE");
        require(validators[_validator].depositShare == 0, "SHARE_NOT_ZERO");
        validators[_validator].status = ValidatorStatus.FROZEN;
        _removeFromActiveValidators(_validator);
    }

    function unfreezeValidator(uint16 _validator) external onlyAdmin {
        require(validators[_validator].status == ValidatorStatus.FROZEN, "NOT_FROZEN");
        validators[_validator].status = ValidatorStatus.ACTIVE;
        activeValidators.push(_validator);
    }

    function _removeFromActiveValidators(uint16 _validator) internal {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            if (activeValidators[i] == _validator) {
                activeValidators[i] = activeValidators[activeValidators.length - 1];
                activeValidators.pop();
                if (lastSuccessfulBuyValidator >= i) {
                    lastSuccessfulBuyValidator = 0;
                }
                if (lastSuccessfulSellValidator >= i) {
                    lastSuccessfulSellValidator = 0;
                }
                break;
            }
        }
        revert("NOT_IN_ACTIVE_LIST");
    }

    function changeMaxDivergence(uint8 newDivergence) external onlyAdmin {
        maxDivergence = newDivergence;
    }

    function updateValidatorTargetShare(uint16[] calldata _validator, uint8[] calldata _newTargetShare)
        external
        onlyAdmin
    {
        require(_validator.length == _newTargetShare.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < _validator.length; i++) {
            validators[_validator[i]].depositShare = _newTargetShare[i];
        }
        uint8 totalPercent;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            totalPercent += validators[activeValidators[i]].depositShare;
        }
        require(totalPercent == 100, "TOTAL_NOT_100");
    }

    function migrateValidator(uint16 _oldValidator, uint16 _newValidator) external onlyAdmin {
        uint256 amount = validators[_oldValidator].totalStaked;
        _migrateValidator(_oldValidator, _newValidator, amount);
    }

    function migrateValidator(uint16 _oldValidator, uint16 _newValidator, uint256 _amount) external onlyAdmin {
        require(_amount <= validators[_oldValidator].totalStaked, "AMOUNT_TOO_LARGE");
        _migrateValidator(_oldValidator, _newValidator, _amount);
    }

    function _migrateValidator(uint16 _oldValidator, uint16 _newValidator, uint256 _amount) internal {
        restakeValidator(_oldValidator);
        restakeValidator(_newValidator);
        stakeManager.migrateDelegation(_oldValidator, _newValidator, _amount);
        validators[_oldValidator].totalStaked -= _amount;
        validators[_newValidator].totalStaked += _amount;
    }

    function restakeValidator(uint16 _validator) public {
        (uint256 amountRestaked,) = validators[_validator].validatorContract.restakePOL();
        adddPOLBalanceFee(amountRestaked);
        validators[_validator].totalStaked += amountRestaked;
    }

    function restakeAllActiveValidators() external {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            (uint256 amountRestaked,) = validators[activeValidators[i]].validatorContract.restakePOL();
            adddPOLBalanceFee(amountRestaked);
            validators[activeValidators[i]].totalStaked += amountRestaked;
        }
    }

    function reloadAllActiveValidatorInfo() external onlyAdmin {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            validator.totalStaked = validator.validatorContract.balanceOf(address(this));
        }
    }

    ///////////////////////////////
    ///  General Exchange       ///
    ///////////////////////////////

    function actualExchangeRatePOLsPOL() public view returns (uint256) {
        return (totaldPOLBalance - feedPOLBalance) / totalsPOLBalance();
    }

    function virtualExchangeRatePOLsPOL() external view returns (uint256) {
        uint256 totalRewards;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            totalRewards = validator.validatorContract.getLiquidRewards(address(this));
        }
        return (totaldPOLBalance + totalRewards - feedPOLBalance) / totalsPOLBalance();
    }

    function totalsPOLBalance() public view returns (uint256) {
        return sPOLToken.totalSupply();
    }

    ///////////////////////////////
    ///  POL -> sPOL Exchange   ///
    ///////////////////////////////

    function exchangeForsPOL(uint256 _amount) external returns (uint256) {
        return _exchangeTosPOL(_amount);
    }

    function exchangeForsPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256)
    {
        uint256 nonceBefore = polToken.nonces(_user);
        polToken.permit(_user, address(this), _amount, _deadline, _v, _r, _s);
        require(polToken.nonces(_user) == nonceBefore + 1, "Invalid permit");
        return _exchangeTosPOL(_amount);
    }

    function _exchangeTosPOL(uint256 _amount) internal returns (uint256) {
        require(_amount < maxDeposit(), "EXCEEDS_MAX_DEPOSIT");
        ValidatorInfo storage validator = _selectValidatorToBuy(_amount);
        uint256 gotShares = _buySharesFromValidator(validator, _amount);
        uint256 rate = actualExchangeRatePOLsPOL();
        uint256 toMint = gotShares * rate;
        sPOLToken.mint(msg.sender, toMint);
        return toMint;
    }

    function maxDeposit() public view returns (uint256) {
        return totaldPOLBalance / 100 * maxDivergence;
    }

    function _buySharesFromValidator(ValidatorInfo storage _validator, uint256 _amount) internal returns (uint256) {
        // use restake and buyVoucher in one
        (uint256 amountRestaked, uint256 rewards) = _validator.validatorContract.restakePOL();
        if (amountRestaked < rewards) {
            // dropped some rewards
        }
        adddPOLBalanceFee(amountRestaked);
        validators[_validator.index].totalStaked += amountRestaked;

        require(_validator.validatorContract.buyVoucher(_amount, _amount) == _amount, "BUY_FAILED");
        adddPOLBalance(_amount);
        validators[_validator.index].totalStaked += _amount;

        if (maxUnstake < validators[_validator.index].totalStaked) {
            maxUnstake = validators[_validator.index].totalStaked;
        }

        return _amount;
    }

    function _validatorMaxDeposit(uint16 _validator) internal view returns (uint256) {
        return ((totaldPOLBalance * validators[_validator].depositShare) / 100);
    }

    function _selectValidatorToBuy(uint256 amount) internal view returns (ValidatorInfo storage) {
        ValidatorInfo storage validator = validators[activeValidators[lastSuccessfulBuyValidator]];

        if (validator.totalStaked + amount <= _validatorMaxDeposit(validator.index)) {
            return validator;
        } else {}
        // then is underfunded?
        return validators[validatorList[0]];
    }

    ///////////////////////////////
    ///  sPOL -> POL Exchange   ///
    ///////////////////////////////

    function initExchangeToPOL(uint256 _amount) external returns (uint256) {
        require(_amount <= maxUnstake, "AMOUNT_TOO_LARGE");
        sPOLToken.burn(msg.sender, _amount);

        uint256 dPOLAmount = _amount * actualExchangeRatePOLsPOL();

        ValidatorInfo storage validator = _selectValidatorToSell(dPOLAmount);
        uint256 userNonce = _sellSharesFromValidator(validator, dPOLAmount);

        globalWithdrawNonce++;
        userNonces[msg.sender].push(globalWithdrawNonce);

        NonceDetails storage details = withdrawNonceDetails[globalWithdrawNonce];
        details.amount = uint128(dPOLAmount);
        details.validatorId = uint16(validator.index);
        details.validatorNonce = uint96(userNonce);

        return globalWithdrawNonce;
    }

    function withdrawExchangedPOL(uint256 _nonce) external {
        for (uint256 i = 0; i < userNonces[msg.sender].length; i++) {
            if (userNonces[msg.sender][i] == _nonce) {
                NonceDetails storage nonce = withdrawNonceDetails[_nonce];
                ValidatorInfo storage validator = validators[nonce.validatorId];
                (uint256 shares, uint256 withdrawEpoch) =
                    validator.validatorContract.unbonds_new(address(this), nonce.validatorNonce);

                require(
                    withdrawEpoch + stakeManager.withdrawalDelay() <= stakeManager.epoch(),
                    "WITHDRAWAL_DELAY_NOT_PASSED"
                );

                validator.validatorContract.unstakeClaimTokens_newPOL(nonce.validatorNonce);
                polToken.transfer(msg.sender, shares);
                if (userNonces[msg.sender].length > 1) {
                    userNonces[msg.sender][i] = userNonces[msg.sender][userNonces[msg.sender].length - 1];
                }
                userNonces[msg.sender].pop();

                return;
            }
        }
        revert("NONCE_NOT_FOUND");
    }

    function getReadyUserNonces(address _user) external view returns (uint256[] memory) {
        uint256[] memory nonces = new uint256[](userNonces[_user].length);
        for (uint256 i = 0; i < userNonces[_user].length; i++) {
            NonceDetails storage nonce = withdrawNonceDetails[userNonces[msg.sender][i]];
            ValidatorInfo storage validator = validators[nonce.validatorId];
            (, uint256 withdrawEpoch) = validator.validatorContract.unbonds_new(address(this), nonce.validatorNonce);

            if (withdrawEpoch + stakeManager.withdrawalDelay() <= stakeManager.epoch()) {
                nonces[i] = userNonces[_user][i];
            }
        }
        return nonces;
    }

    function withdrawExchangedPOL() external {
        require(0 != userNonces[msg.sender].length, "NO_OPEN_NONCES");

        uint256 totalAmount;
        for (uint256 i = 0; i < userNonces[msg.sender].length; i++) {
            NonceDetails storage nonce = withdrawNonceDetails[userNonces[msg.sender][i]];
            ValidatorInfo storage validator = validators[nonce.validatorId];
            (uint256 shares, uint256 withdrawEpoch) =
                validator.validatorContract.unbonds_new(address(this), nonce.validatorNonce);

            if (withdrawEpoch + stakeManager.withdrawalDelay() <= stakeManager.epoch()) {
                try validator.validatorContract.unstakeClaimTokens_newPOL(nonce.validatorNonce) {
                    totalAmount += shares;
                    if (userNonces[msg.sender].length > 1) {
                        userNonces[msg.sender][i] = userNonces[msg.sender][userNonces[msg.sender].length - 1];
                        i--;
                    }
                    userNonces[msg.sender].pop();
                } catch {
                    continue;
                }
            }
        }
        polToken.transfer(msg.sender, totalAmount);
    }

    function _selectValidatorToSell(uint256 amount) internal view returns (ValidatorInfo storage) {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator =
                validators[activeValidators[(i + lastSuccessfulSellValidator) % activeValidators.length]];
            if (validator.totalStaked >= amount) {
                if (totaldPOLBalance / validator.depositShare * 100 >= validator.totalStaked) {
                    return validator;
                }
            }
        }
        revert("NO_VALIDATOR_FOUND");
        // couldn't unstake all at once
    }

    function _sellSharesFromValidator(ValidatorInfo storage _validator, uint256 _amount) internal returns (uint256) {
        // use withdraw and sellVoucher in one
        (uint256 amountRestaked, uint256 rewards) = _validator.validatorContract.restakePOL();
        if (amountRestaked < rewards) {
            // dropped some rewards
        }

        _validator.validatorContract.sellVoucher_newPOL(_amount, _amount);
        uint256 userNonce = _validator.validatorContract.unbondNonces(address(this));

        validators[_validator.index].totalStaked -= _amount;
        validators[_validator.index].totalStaked += amountRestaked;
        totaldPOLBalance -= _amount;

        return userNonce;
    }

    // do multi claim per user

    ///////////////////////////////
    ///  Fee Management         ///
    ///////////////////////////////

    function changeFeeReceiver(address newFeeReceiver) external onlyAdmin {
        feeReceiver = newFeeReceiver;
    }

    function changeRewardFee(uint8 newFee) external onlyAdmin {
        rewardFee = newFee;
    }

    function takeFee() external onlyAdmin {
        uint256 feeInsPOL = feedPOLBalance * actualExchangeRatePOLsPOL();
        sPOLToken.mint(feeReceiver, feeInsPOL);
    }

    function adddPOLBalanceFee(uint256 _amount) internal {
        uint256 feeTaken = (_amount * rewardFee) / 1000;
        feedPOLBalance += feeTaken;
        totaldPOLBalance += _amount;
    }

    function adddPOLBalance(uint256 _amount) internal {
        totaldPOLBalance += _amount;
    }

    ///////////////////////////////
    ///  Other                  ///
    ///////////////////////////////

    function cleanUpMaticPOL(address _receiver) external onlyAdmin {
        uint256 maticBalance = maticToken.balanceOf(address(this));
        if (maticBalance > 0) {
            polygonMigration.migrate(maticBalance);
        }
        uint256 polBalance = polToken.balanceOf(address(this));
        if (polBalance > 0) {
            if (_receiver == address(0)) {
                // just stake, no sPOL creation
            } else {
                // buy Shares
            }
        }
    }
}
