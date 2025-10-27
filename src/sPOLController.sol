// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable-5.5.0/proxy/utils/Initializable.sol";
import {IPolygonMigration} from "./interfaces/IPolygonMigration.sol";
import {StakeManager as IStakeManager, StakeManagerStorage as StakeManagerStatus} from "./interfaces/IStakeManager.sol";
import {ValidatorShare as IValidatorShare} from "./interfaces/IValidatorShare.sol";
import {sPOL} from "./sPOL.sol";
import "forge-std/console.sol";

contract sPOLController is Initializable {
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

    mapping(uint16 => ValidatorInfo) public validators;
    uint16[] public validatorList;
    uint16[] public activeValidators;
    uint16 public lastSuccessfulBuyValidator;
    uint16 public lastSuccessfulSellValidator;

    uint256 public totaldPOLBalance;

    // in percentage points
    uint8 public maxDivergence;

    uint16 public rewardFee;
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

    event ValidatorAdded(uint16 validatorId);
    event ValidatorRemoved(uint16 validatorId);
    event ValidatorFrozen(uint16 validatorId);
    event ValidatorUnfrozen(uint16 validatorId);
    event ValidatorTargetShareChanged(uint16 validatorId, uint8 newTargetShare);
    event sPOLMinted(address user, uint256 amountPOL, uint256 amountSPOL);
    event sPOLBurned(address user, uint256 amountSPOL, uint256 amountPOL, uint256 nonce);
    event POLWithdrawn(address user, uint256 amountPOL, uint256 nonce);

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
        _disableInitializers();
    }

    function initialize(uint16 _rewardFee, address _feeReceiver, uint8 _maxDivergence, address _admin)
        external
        initializer
    {
        require(_rewardFee <= MAX_FEE, "FEE_TOO_LARGE");
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

        emit ValidatorAdded(_validatorID);
    }

    function removeValidator(uint16 _removedValidator) external onlyAdmin {
        ValidatorInfo storage removedValidator = validators[_removedValidator];
        require(removedValidator.totalStaked == 0, "STILL_FUNDED");
        require(removedValidator.status == ValidatorStatus.ACTIVE, "NOT_ACTIVE");
        require(removedValidator.validatorContract.balanceOf(address(this)) == 0, "SHARES_PENDING");
        require(removedValidator.validatorContract.getLiquidRewards(address(this)) == 0, "REWARDS_PENDING");

        removedValidator.status = ValidatorStatus.DEACTIVATED;
        removedValidator.depositShare = 0;
        _removeFromActiveValidators(_removedValidator);
        emit ValidatorRemoved(_removedValidator);
    }

    function freezeValidator(uint16 _validator) external onlyAdmin {
        require(validators[_validator].status == ValidatorStatus.ACTIVE, "NOT_ACTIVE");
        require(validators[_validator].depositShare == 0, "SHARE_NOT_ZERO");

        validators[_validator].status = ValidatorStatus.FROZEN;
        _removeFromActiveValidators(_validator);
        emit ValidatorFrozen(_validator);
    }

    function unfreezeValidator(uint16 _validator) external onlyAdmin {
        require(validators[_validator].status == ValidatorStatus.FROZEN, "NOT_FROZEN");
        validators[_validator].status = ValidatorStatus.ACTIVE;
        activeValidators.push(_validator);
        emit ValidatorUnfrozen(_validator);
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
    }

    function changeMaxDivergence(uint8 newDivergence) external onlyAdmin {
        maxDivergence = newDivergence;
    }

    function updateValidatorTargetShare(uint16[] calldata _validatorID, uint8[] calldata _newTargetShare)
        external
        onlyAdmin
    {
        require(_validatorID.length == _newTargetShare.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < _validatorID.length; i++) {
            require(validators[_validatorID[i]].status == ValidatorStatus.ACTIVE, "NOT_ACTIVE");
            validators[_validatorID[i]].depositShare = _newTargetShare[i];
            emit ValidatorTargetShareChanged(_validatorID[i], _newTargetShare[i]);
        }
        uint8 totalPercent;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            totalPercent += validators[activeValidators[i]].depositShare;
        }
        require(totalPercent == 100, "TOTAL_NOT_100");
    }

    function migrateValidator(uint16 _oldValidator, uint16 _newValidator) external onlyAdmin {
        uint256 amount = validators[_oldValidator].totalStaked;
        amount += validators[_oldValidator].validatorContract.getLiquidRewards(address(this));
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
        _adddPOLBalanceFee(amountRestaked);
        validators[_validator].totalStaked += amountRestaked;
    }

    function restakeAllActiveValidators() external {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            (uint256 amountRestaked,) = validators[activeValidators[i]].validatorContract.restakePOL();
            _adddPOLBalanceFee(amountRestaked);
            validators[activeValidators[i]].totalStaked += amountRestaked;
        }
    }

    function reloadAllActiveValidatorInfo() external onlyAdmin {
        uint256 amountToReduce;
        uint256 amountToAdd;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            amountToReduce += validator.totalStaked;
            validator.totalStaked = validator.validatorContract.balanceOf(address(this));
            amountToAdd += validator.totalStaked;
        }
        totaldPOLBalance = totaldPOLBalance - amountToReduce + amountToAdd;
    }

    // very expensive, includes frozen validators
    function reloadAllValidatorInfo() external onlyAdmin {
        uint256 totalDPOL;
        for (uint256 i = 0; i < validatorList.length; i++) {
            ValidatorInfo storage validator = validators[validatorList[i]];
            validator.totalStaked = validator.validatorContract.balanceOf(address(this));
            totalDPOL += validator.totalStaked;
        }
        totaldPOLBalance = totalDPOL;
    }

    ///////////////////////////////
    ///  General Exchange       ///
    ///////////////////////////////

    // limit by maxDeposit?
    function convertPOLtoSPOL(uint256 _amountPOL) public view returns (uint256) {
        if (_amountPOL == 0) {
            return 0;
        }
        if (totalsPOLBalance() == 0) {
            return _amountPOL;
        }
        return _amountPOL * totalsPOLBalance() / (totaldPOLBalance - feedPOLBalance);
    }

    // limit by maxRedeem?
    function convertSPOLtoPOL(uint256 _amountSPOL) public view returns (uint256) {
        if (_amountSPOL == 0) {
            return 0;
        }
        if (totalsPOLBalance() == 0) {
            return _amountSPOL;
        }
        return _amountSPOL * (totaldPOLBalance - feedPOLBalance) / totalsPOLBalance();
    }

    function totalsPOLBalance() public view returns (uint256) {
        return sPOLToken.totalSupply();
    }

    ///////////////////////////////
    ///  POL -> sPOL Exchange   ///
    ///////////////////////////////

    function buySPOL(uint256 _amount) external returns (uint256) {
        return _buySPOLMulti(_amount, msg.sender);
    }

    function buySPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256)
    {
        uint256 nonceBefore = polToken.nonces(_user);
        polToken.permit(_user, address(this), _amount, _deadline, _v, _r, _s);
        require(polToken.nonces(_user) == nonceBefore + 1, "Invalid permit");
        return _buySPOLMulti(_amount, _user);
    }

    function buySPOL(uint256 _amount, uint16 _validator) public returns (uint256) {
        return _buySPOLSingle(_amount, _validator, msg.sender);
    }

    function buySPOLPermit(
        uint256 _amount,
        uint16 _validator,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public returns (uint256) {
        uint256 nonceBefore = polToken.nonces(_user);
        polToken.permit(_user, address(this), _amount, _deadline, _v, _r, _s);
        require(polToken.nonces(_user) == nonceBefore + 1, "Invalid permit");
        return _buySPOLSingle(_amount, _validator, _user);
    }

    function _buySPOLSingle(uint256 _amount, uint16 _validator, address _user) internal returns (uint256) {
        ValidatorInfo storage validator = validators[_validator];
        require(_amount <= _validatorMaxTotalStakeDistance(validator, true), "VALIDATOR_OVERFUNDED");
        require(validator.status == ValidatorStatus.ACTIVE, "VALIDATOR_NOT_ACTIVE");
        _takePOL(_amount, _user);

        uint256 gotShares = _buySharesFromValidator(validator, _amount);
        return _mintSPOL(gotShares, _user);
    }

    function _buySPOLMulti(uint256 _amount, address _user) internal returns (uint256) {
        (uint16[] memory validator, uint256[] memory amount) = _selectValidatorToBuy(_amount);
        _takePOL(_amount, _user);
        uint256 totalShares;
        for (uint256 i = 0; i < amount.length; i++) {
            totalShares += _buySharesFromValidator(validators[validator[i]], amount[i]);
        }
        lastSuccessfulBuyValidator = validator[validator.length - 1];
        require(totalShares == _amount, "BUY_SHARES_MISMATCH");
        return _mintSPOL(totalShares, _user);
    }

    function _takePOL(uint256 _amount, address _user) internal {
        require(polToken.transferFrom(_user, address(this), _amount), "TRANSFER_FAILED");
    }

    function _mintSPOL(uint256 _amount, address _user) internal returns (uint256) {
        uint256 toMint = convertPOLtoSPOL(_amount);
        sPOLToken.mint(_user, toMint);
        emit sPOLMinted(_user, _amount, toMint);
        return toMint;
    }

    function getMostUnderfundedValidator() external view returns (uint16, uint256) {
        uint16 selectedValidator = activeValidators[0];
        uint256 maxFundsDepositable;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            uint256 amount = _validatorMaxTotalStakeDistance(validator, true);
            if (maxFundsDepositable < amount) {
                maxFundsDepositable = amount;
                selectedValidator = validator.index;
            }
        }
        if (maxFundsDepositable == 0) {
            maxFundsDepositable = type(uint256).max;
        }
        return (selectedValidator, maxFundsDepositable);
    }

    function _buySharesFromValidator(ValidatorInfo storage _validator, uint256 _amount) internal returns (uint256) {
        (uint256 amountDeposited, uint256 liquidReward) = _validator.validatorContract.restakeAndStakePOL(_amount);
        require(amountDeposited == _amount, "INCORRECT_EXCHANGE_RATE");
        _adddPOLBalanceFee(liquidReward);
        _adddPOLBalance(amountDeposited);
        validators[_validator.index].totalStaked += amountDeposited + liquidReward;
        return amountDeposited;
    }

    function _maxDeposit(ValidatorInfo storage _validator) internal view returns (uint256) {
        uint8 myBigShare = _validator.depositShare + maxDivergence;
        if (myBigShare >= 100) {
            return type(uint256).max;
        }
        uint256 theOtherShare = totaldPOLBalance - _validator.totalStaked;
        uint8 restShare = 100 - myBigShare;
        uint256 myactualMaxSahre = (theOtherShare * myBigShare) / restShare;
        if (myactualMaxSahre <= _validator.totalStaked) {
            return 0;
        }
        return myactualMaxSahre - _validator.totalStaked;
    }

    function _maxRedeem(ValidatorInfo storage _validator) internal view returns (uint256) {
        if (_validator.depositShare <= maxDivergence) {
            return _validator.totalStaked;
        }
        uint8 mySmallShare = _validator.depositShare - maxDivergence;

        uint256 theOtherShare = totaldPOLBalance - _validator.totalStaked;
        uint8 restShare = 100 - mySmallShare;
        uint256 myactualMinSahre = (theOtherShare * mySmallShare) / restShare;
        if (myactualMinSahre >= _validator.totalStaked) {
            return 0;
        }
        return _validator.totalStaked - myactualMinSahre;
    }

    // positive to check how much can be added, negative to check how much can be removed
    function _validatorMaxTotalStakeDistance(ValidatorInfo storage _validator, bool _positive)
        internal
        view
        returns (uint256)
    {
        if (_positive) {
            return _maxDeposit(_validator);
        } else {
            return _maxRedeem(_validator);
        }
    }

    // can't take storage array of full vals, so we take index to avoid costly copying
    function _selectValidatorToBuy(uint256 _amount) internal view returns (uint16[] memory, uint256[] memory) {
        return _selectValidators(_amount, true);
    }

    ///////////////////////////////
    ///  sPOL -> POL Exchange   ///
    ///////////////////////////////

    function initSellSPOL(uint256 _amount) external returns (uint256[] memory) {
        return _sellSPOLMulti(_amount, msg.sender);
    }

    function initSellSPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256[] memory)
    {
        // consume permit resets allowance to 0 after use, as we don't want any leftover allowance
        // allowance should have no negative downsides, we do this to be safe
        uint256 nonceBefore = sPOLToken.nonces(_user);
        sPOLToken.consumePermit(_user, address(this), _amount, _deadline, _v, _r, _s);
        require(sPOLToken.nonces(_user) == nonceBefore + 1, "Invalid permit");
        return _sellSPOLMulti(_amount, _user);
    }

    function sellSPOL(uint256 _amount, uint16 _validator) external returns (uint256) {
        return _sellSPOLSingle(_amount, _validator, msg.sender);
    }

    function sellSPOLPermit(
        uint256 _amount,
        uint16 _validator,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256) {
        // consume permit resets allowance to 0 after use, as we don't want any leftover allowance
        // allowance should have no negative downsides, we do this to be safe
        uint256 nonceBefore = sPOLToken.nonces(_user);
        sPOLToken.consumePermit(_user, address(this), _amount, _deadline, _v, _r, _s);
        require(sPOLToken.nonces(_user) == nonceBefore + 1, "Invalid permit");
        return _sellSPOLSingle(_amount, _validator, _user);
    }

    function _sellSPOLSingle(uint256 _amount, uint16 _validator, address _user) internal returns (uint256) {
        ValidatorInfo storage validator = validators[_validator];
        require(validator.status == ValidatorStatus.ACTIVE, "VALIDATOR_NOT_ACTIVE");
        require(_amount <= _maxRedeem(validator), "VALIDATOR_UNDERFUNDED");
        _takeSPOL(_amount, _user);

        uint256 dPOLAmount = convertSPOLtoPOL(_amount);
        uint256 userNonce = _sellSharesFromValidator(validator, dPOLAmount);

        globalWithdrawNonce++;
        userNonces[_user].push(globalWithdrawNonce);

        NonceDetails storage details = withdrawNonceDetails[globalWithdrawNonce];
        details.amount = uint128(dPOLAmount);
        details.validatorId = uint16(validator.index);
        details.validatorNonce = uint96(userNonce);
        emit sPOLBurned(_user, _amount, dPOLAmount, globalWithdrawNonce);

        return globalWithdrawNonce;
    }

    // can't take storage array of full vals, so we take index to avoid costly copying
    function _selectValidatorToSell(uint256 _amount) internal view returns (uint16[] memory, uint256[] memory) {
        return _selectValidators(_amount, false);
    }

    function _takeSPOL(uint256 _amount, address _user) internal {
        try sPOLToken.burn(_user, _amount) {}
        catch {
            revert("BURN_FAILED");
        }
    }

    function _sellSPOLMulti(uint256 _amount, address _user) internal returns (uint256[] memory) {
        _takeSPOL(_amount, _user);
        uint256 dPOLAmount = convertSPOLtoPOL(_amount);
        (uint16[] memory validator, uint256[] memory amount) = _selectValidatorToSell(dPOLAmount);
        uint256[] memory nonces = new uint256[](validator.length);
        for (uint256 i = 0; i < validator.length; i++) {
            uint256 userNonce = _sellSharesFromValidator(validators[validator[i]], amount[i]);
            globalWithdrawNonce++;
            userNonces[_user].push(globalWithdrawNonce);

            NonceDetails storage details = withdrawNonceDetails[globalWithdrawNonce];
            details.amount = uint128(amount[i]);
            details.validatorId = validator[i];
            details.validatorNonce = uint96(userNonce);
            emit sPOLBurned(_user, convertPOLtoSPOL(amount[i]), amount[i], globalWithdrawNonce);
        }
        return nonces;
    }

    function _sellSharesFromValidator(ValidatorInfo storage _validator, uint256 _amount) internal returns (uint256) {
        (uint256 unstaked, uint256 liquidRewards) = _validator.validatorContract.restakeAndUnstakePOL(_amount);
        require(unstaked == _amount, "INCORRECT_EXCHANGE_RATE");
        _adddPOLBalanceFee(liquidRewards);
        _removedPOLBalance(_amount);
        validators[_validator.index].totalStaked -= _amount;
        validators[_validator.index].totalStaked += liquidRewards;

        uint256 userNonce = _validator.validatorContract.unbondNonces(address(this));
        return userNonce;
    }

    function getMostOverfundedValidator() external view returns (uint16, uint256) {
        uint16 selectedValidator = activeValidators[0];
        uint256 maxFundsRedeemable = 0;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            uint256 unstakeable = _validatorMaxTotalStakeDistance(validator, false);

            if (maxFundsRedeemable < unstakeable) {
                maxFundsRedeemable = unstakeable;
                selectedValidator = validator.index;
            }
        }
        return (selectedValidator, maxFundsRedeemable);
    }

    function withdrawPOL(uint256 _nonce) external {
        _withdrawPOL(msg.sender, _nonce);
    }

    function withdrawPOL(address _user, uint256 _nonce) external {
        _withdrawPOL(_user, _nonce);
    }

    function _withdrawPOL(address _user, uint256 _nonce) internal {
        for (uint256 i = 0; i < userNonces[_user].length; i++) {
            if (userNonces[_user][i] == _nonce) {
                NonceDetails storage nonce = withdrawNonceDetails[_nonce];
                ValidatorInfo storage validator = validators[nonce.validatorId];
                (uint256 shares,) = validator.validatorContract.unbonds_new(address(this), nonce.validatorNonce);

                try validator.validatorContract.unstakeClaimTokens_newPOL(nonce.validatorNonce) {}
                catch Error(string memory errorMsg) {
                    revert(errorMsg);
                } catch {
                    revert("UNSTAKE_CLAIM_FAILED");
                }

                if (userNonces[_user].length > 1) {
                    userNonces[_user][i] = userNonces[_user][userNonces[_user].length - 1];
                }
                userNonces[_user].pop();

                polToken.transfer(_user, shares);
                emit POLWithdrawn(_user, shares, _nonce);
                return;
            }
        }
        revert("NONCE_NOT_FOUND");
    }

    function withdrawPOL() external {
        _withdrawPOL(msg.sender);
    }

    function withdrawPOL(address _user) external {
        _withdrawPOL(_user);
    }

    function _withdrawPOL(address _user) internal {
        require(0 != userNonces[_user].length, "NO_OPEN_NONCES");

        uint256 totalAmount;
        //create a copy of the array in memory to avoid SStores
        uint256[] memory memNonces = userNonces[_user];
        for (uint256 i = 0; i < memNonces.length; i++) {
            NonceDetails storage nonce = withdrawNonceDetails[memNonces[i]];
            ValidatorInfo storage validator = validators[nonce.validatorId];
            (uint256 shares, uint256 withdrawEpoch) =
                validator.validatorContract.unbonds_new(address(this), nonce.validatorNonce);

            if (withdrawEpoch + stakeManager.withdrawalDelay() <= stakeManager.epoch()) {
                try validator.validatorContract.unstakeClaimTokens_newPOL(nonce.validatorNonce) {
                    totalAmount += shares;
                    memNonces[i] = 0;
                    emit POLWithdrawn(_user, totalAmount, nonce.validatorNonce);
                } catch {
                    // Nonce wasn't ready for some reason, so we skip it
                    // Consider reverting here, because in case this happens it's not the delay, but maybe something serious
                    continue;
                }
            }
        }
        // shrink the array in storage as needed
        uint256 foundNonces;
        for (uint256 i = 0; i < memNonces.length; i++) {
            if (memNonces[i] == 0) {
                userNonces[_user].pop();
            } else {
                userNonces[_user][foundNonces] = memNonces[i];
                foundNonces++;
            }
        }
        // bundle transfer to save gas, separate events inform about multi withdraws
        polToken.transfer(_user, totalAmount);
    }

    ///////////////////////////////
    ///  Fee Management         ///
    ///////////////////////////////

    function changeFeeReceiver(address newFeeReceiver) external onlyAdmin {
        require(newFeeReceiver != address(0), "ZERO_ADDRESS");
        takeFee();
        feeReceiver = newFeeReceiver;
    }

    function changeRewardFee(uint16 newFee) external onlyAdmin {
        require(newFee <= MAX_FEE, "FEE_TOO_LARGE");
        rewardFee = newFee;
    }

    function takeFee() public onlyAdmin {
        if (feedPOLBalance == 0) {
            return;
        }
        uint256 feeInsPOL = convertPOLtoSPOL(feedPOLBalance);
        feedPOLBalance = 0;
        sPOLToken.mint(feeReceiver, feeInsPOL);
    }

    function _adddPOLBalanceFee(uint256 _amount) internal {
        uint256 feeTaken = (_amount * rewardFee) / 1000;
        feedPOLBalance += feeTaken;
        totaldPOLBalance += _amount;
    }

    function _adddPOLBalance(uint256 _amount) internal {
        totaldPOLBalance += _amount;
    }

    function _removedPOLBalance(uint256 _amount) internal {
        totaldPOLBalance -= _amount;
    }

    ///////////////////////////////
    ///  Other                  ///
    ///////////////////////////////

    function _selectValidators(uint256 _amount, bool _buy) internal view returns (uint16[] memory, uint256[] memory) {
        uint16[] memory selectedValidators = new uint16[](activeValidators.length);
        uint256[] memory amounts = new uint256[](activeValidators.length);
        uint256 remainingAmount = _amount;

        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator =
                validators[activeValidators[(lastSuccessfulBuyValidator + i) % activeValidators.length]];

            uint256 maxAmount = _validatorMaxTotalStakeDistance(validator, _buy);
            if (_amount <= maxAmount) {
                selectedValidators[0] = validator.index;
                amounts[0] = _amount;
                // memory cut to size 1 both arrays
                assembly {
                    mstore(selectedValidators, 1)
                    mstore(amounts, 1)
                }
                return (selectedValidators, amounts);
            } else if (remainingAmount <= maxAmount) {
                selectedValidators[i] = validator.index;
                amounts[i] = remainingAmount;
                // memory cut to size i+1 both arrays
                assembly {
                    mstore(selectedValidators, add(i, 1))
                    mstore(amounts, add(i, 1))
                }
                return (selectedValidators, amounts);
            } else {
                selectedValidators[i] = validator.index;
                amounts[i] = maxAmount;
                remainingAmount -= maxAmount;
            }
        }
        // in this case not enough theoretical capacity, so we just distribute to all equally
        // for buy this is a fine approximation, for sell it can be really bad, so extra logic
        if (_buy) {
            uint256 perValidator = _amount / activeValidators.length;
            uint256 remainder = _amount % activeValidators.length;
            for (uint256 i = 0; i < activeValidators.length; i++) {
                selectedValidators[i] = validators[activeValidators[i]].index;
                amounts[i] = perValidator;
            }
            amounts[0] += remainder;
        } else {
            uint256 remaining = _amount;
            for (uint256 i = 0; i < activeValidators.length; i++) {
                if (remaining > validators[activeValidators[i]].totalStaked) {
                    amounts[i] = validators[activeValidators[i]].totalStaked;
                    remaining -= validators[activeValidators[i]].totalStaked;
                } else {
                    amounts[i] = remaining;
                    remaining = 0;
                    assembly {
                        mstore(selectedValidators, add(i, 1))
                        mstore(amounts, add(i, 1))
                    }
                    selectedValidators[i] = validators[activeValidators[i]].index;
                    break;
                }
                selectedValidators[i] = validators[activeValidators[i]].index;
            }
            require(remaining == 0, "Not enough stake");
        }
        return (selectedValidators, amounts);
    }

    function cleanUpMaticPOL(uint16 _validator, address _receiver) external onlyAdmin {
        require(validators[_validator].status == ValidatorStatus.ACTIVE, "VALIDATOR_NOT_ACTIVE");

        uint256 maticBalance = maticToken.balanceOf(address(this));
        if (maticBalance > 0) {
            polygonMigration.migrate(maticBalance);
        }
        uint256 polBalance = polToken.balanceOf(address(this));
        if (polBalance > 0) {
            if (_receiver == address(0)) {
                _buySharesFromValidator(validators[_validator], polBalance);
            } else {
                uint256 mintedSPOL = buySPOL(polBalance, _validator);
                sPOLToken.transfer(_receiver, mintedSPOL);
            }
        }
    }
}
