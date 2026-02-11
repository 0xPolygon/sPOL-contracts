// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.30;

import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IPolygonMigration} from "./interfaces/IPolygonMigration.sol";
import {StakeManager as IStakeManager} from "./interfaces/IStakeManager.sol";
import {ValidatorShare as IValidatorShare} from "./interfaces/IValidatorShare.sol";
import {sPOL} from "./sPOL.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

/// @title sPOL Controller
/// @notice L1 controller for the sPOL liquid staking token of POL
/// @dev Manages validator delegations, POL/sPOL conversions, and coordinates with L2 via sPOLMessenger on L1.
///      Handles staking rewards, fee collection, and the unbonding process for redemptions.
contract sPOLController is Initializable, PausableUpgradeable, AccessManagedUpgradeable, ReentrancyGuardTransient {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

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
        DEACTIVATED
    }

    // External contracts
    ERC20Permit public immutable polToken;
    ERC20 public immutable maticToken;
    IPolygonMigration public immutable polygonMigration;
    IStakeManager public immutable stakeManager;
    sPOL public immutable sPOLToken;

    // Validator management
    mapping(uint16 => ValidatorInfo) public validators;
    uint16[] public validatorList;
    uint16[] public activeValidators;

    // in percentage points
    uint8 public constant MAX_DIVERGENCE = 100;
    uint8 public maxDivergence;

    // Total dPOL balance managed by the controller, including outstanding fees
    uint256 public totaldPOLBalance;

    // In per mill, so 100 = 10%
    uint16 public rewardFee;
    uint16 public constant MAX_FEE = 1000;
    address public feeReceiver;
    uint256 public feedPOLBalance;

    struct NonceDetails {
        uint16 validatorId;
        uint128 amount;
        uint96 validatorNonce;
    }

    struct FullNonceDetails {
        uint16 validatorId;
        uint128 amount;
        uint96 validatorNonce;
        uint256 nonce;
    }

    // User withdraw nonce management
    mapping(address => DoubleEndedQueue.Bytes32Deque) public userNonces;
    mapping(uint256 => NonceDetails) public withdrawNonceDetails;
    // Global user withdraw nonce counter
    uint256 public globalWithdrawNonce;

    // Validator management events
    event ValidatorAdded(uint16 validatorId);
    event ValidatorRemoved(uint16 validatorId);
    event ValidatorTargetShareChanged(uint16 validatorId, uint8 newTargetShare);
    event ValidatorMigrated(uint16 oldValidator, uint16 newValidator, uint256 amount);
    // sPOL exchange events
    event sPOLMinted(address indexed user, uint256 amountPOL, uint256 amountSPOL);
    event sPOLBurned(address indexed user, uint256 amountSPOL, uint256 amountPOL, uint256 nonce);
    event POLWithdrawn(address indexed user, uint256 amountPOL, uint256 nonce);
    event ExchangeRateSnapshot(uint256 totalsPOLSupply, uint256 totalbPOLBalance);
    // Fee management events
    event FeeCollected(address feeReceiver, uint256 feePOLAmount, uint256 feesPOLAmount);
    event FeeReceiverChanged(address oldReceiver, address newReceiver);
    event RewardFeeChanged(uint16 oldFee, uint16 newFee);
    // Configuration events
    event MaxDivergenceChanged(uint8 oldDivergence, uint8 newDivergence);
    // Cleanup events
    event MaticTokensCleaned(uint256 maticAmount);
    event POLTokensCleaned(uint16 validatorId, uint256 polAmount);

    error AmountZero();
    error ArrayLengthMismatch(uint256 validatorLength, uint256 shareLength);
    error BuySharesMismatch(uint256 expected, uint256 actual);
    error DepositSharesTotalNotOneHundred(uint8 totalPercent);
    error DPOLRestakeTransferFromFailed();
    error FeeTooLarge(uint16 provided, uint16 maxAllowed);
    error IncorrectValidatorShareExchangeRate(uint256 expected, uint256 actual);
    error MaxDivergenceTooLarge(uint8 provided, uint8 maxAllowed);
    error InvalidPermit();
    error NoOpenNonces(address user);
    error NoNoncesReady(address user);
    error NotEnoughStake(uint256 remaining);
    error ValidatorDepositShareNotZero(uint16 validatorId, uint8 depositShare);
    error ValidatorNotActive(uint16 validatorId);
    error ValidatorNotInactive(uint16 validatorId);
    error ValidatorNotDelegating(uint16 validatorId);
    error ValidatorOverfunded(uint256 amount, uint256 maxAmount);
    error ValidatorRewardsPending(uint16 validatorId, uint256 rewards);
    error ValidatorSharesPending(uint16 validatorId, uint256 shares);
    error ValidatorStillFunded(uint16 validatorId, uint256 totalStaked);
    error ValidatorUnderfunded(uint256 amount, uint256 maxAmount);
    error NoUnlockedValidators();
    error ZeroAddress();

    constructor(
        address _polToken,
        address _maticToken,
        address _polygonMigration,
        address _sPOLToken,
        address _stakeManager
    ) {
        require(_polToken != address(0), ZeroAddress());
        require(_maticToken != address(0), ZeroAddress());
        require(_polygonMigration != address(0), ZeroAddress());
        require(_sPOLToken != address(0), ZeroAddress());
        require(_stakeManager != address(0), ZeroAddress());

        polToken = ERC20Permit(_polToken);
        maticToken = ERC20(_maticToken);
        polygonMigration = IPolygonMigration(_polygonMigration);
        sPOLToken = sPOL(_sPOLToken);
        stakeManager = IStakeManager(_stakeManager);

        _disableInitializers();
    }

    /// @notice Initializes the controller with fee and access control settings
    /// @dev Must be called once after proxy deployment.
    /// @param _rewardFee Protocol fee on staking rewards in per mill (100 = 10%)
    /// @param _feeReceiver Address that receives collected protocol fees as sPOL
    /// @param _maxDivergence Max allowed deviation from target validator allocation in percentage points
    /// @param _authority AccessManager contract that controls restricted functions
    function initialize(uint16 _rewardFee, address _feeReceiver, uint8 _maxDivergence, address _authority)
        external
        initializer
    {
        require(_rewardFee <= MAX_FEE, FeeTooLarge(_rewardFee, MAX_FEE));
        require(_maxDivergence <= MAX_DIVERGENCE, MaxDivergenceTooLarge(_maxDivergence, MAX_DIVERGENCE));
        require(_feeReceiver != address(0), ZeroAddress());
        require(_authority != address(0), ZeroAddress());

        __Pausable_init();
        __AccessManaged_init(_authority);

        rewardFee = _rewardFee;
        feeReceiver = _feeReceiver;
        maxDivergence = _maxDivergence;
        globalWithdrawNonce = 1;
        polToken.approve(address(stakeManager), type(uint256).max);
    }

    ///////////////////////////////
    ///  Validator Management   ///
    ///////////////////////////////

    /// @notice Adds a new validator to the sPOL staking pool
    /// @dev Validator must be active in StakeManager and accepting delegations. Starts with 0% deposit share.
    /// @param _validatorID Polygon validator ID from the StakeManager contract
    function addValidator(uint16 _validatorID) external restricted {
        require(stakeManager.isValidator(_validatorID), ValidatorNotActive(_validatorID));
        require(validators[_validatorID].status == ValidatorStatus.INACTIVE, ValidatorNotInactive(_validatorID));

        IValidatorShare validatorContract = IValidatorShare(stakeManager.getValidatorContract(_validatorID));
        require(address(validatorContract) != address(0), ValidatorNotDelegating(_validatorID));

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

    /// @notice Permanently removes a validator from the pool
    /// @dev Validator must have 0% deposit share, no staked funds, no pending shares, and no liquid rewards.
    ///      Once removed, the validator cannot be re-added.
    /// @param _removedValidator Polygon validator ID to remove
    function removeValidator(uint16 _removedValidator) external restricted {
        ValidatorInfo storage removedValidator = validators[_removedValidator];
        require(
            removedValidator.depositShare == 0,
            ValidatorDepositShareNotZero(_removedValidator, removedValidator.depositShare)
        );
        require(
            removedValidator.totalStaked == 0, ValidatorStillFunded(_removedValidator, removedValidator.totalStaked)
        );
        require(removedValidator.status == ValidatorStatus.ACTIVE, ValidatorNotActive(_removedValidator));
        IValidatorShare validatorContract = removedValidator.validatorContract;
        uint256 shares = validatorContract.balanceOf(address(this));
        require(shares == 0, ValidatorSharesPending(_removedValidator, shares));
        uint256 rewards = validatorContract.getLiquidRewards(address(this));
        require(rewards == 0, ValidatorRewardsPending(_removedValidator, rewards));

        removedValidator.status = ValidatorStatus.DEACTIVATED;
        _removeFromActiveValidators(_removedValidator);
        emit ValidatorRemoved(_removedValidator);
    }

    function _removeFromActiveValidators(uint16 _validator) internal {
        uint256 activeValidatorsLength = activeValidators.length;
        for (uint256 i = 0; i < activeValidatorsLength; i++) {
            if (activeValidators[i] == _validator) {
                activeValidators[i] = activeValidators[activeValidatorsLength - 1];
                activeValidators.pop();
                break;
            }
        }
    }

    /// @notice Updates target stake allocation percentages across validators
    /// @dev All active validators' shares must sum to exactly 100%. Validators not in the array keep
    ///      their current share. Used to rebalance stake distribution.
    /// @param _validatorID Array of validator IDs to update
    /// @param _newTargetShare Array of new target percentages (0-100) for each validator
    function updateValidatorTargetShare(uint16[] calldata _validatorID, uint8[] calldata _newTargetShare)
        external
        restricted
    {
        require(
            _validatorID.length == _newTargetShare.length,
            ArrayLengthMismatch(_validatorID.length, _newTargetShare.length)
        );
        for (uint256 i = 0; i < _validatorID.length; i++) {
            require(validators[_validatorID[i]].status == ValidatorStatus.ACTIVE, ValidatorNotActive(_validatorID[i]));
            validators[_validatorID[i]].depositShare = _newTargetShare[i];
            emit ValidatorTargetShareChanged(_validatorID[i], _newTargetShare[i]);
        }
        uint8 totalPercent;
        uint256 activeValidatorsLength = activeValidators.length;
        for (uint256 i = 0; i < activeValidatorsLength; i++) {
            totalPercent += validators[activeValidators[i]].depositShare;
        }
        require(totalPercent == 100, DepositSharesTotalNotOneHundred(totalPercent));
    }

    /// @notice Claims and restakes liquid rewards for a single validator
    /// @dev Anyone can call to compound rewards. Protocol fee is taken on claimed rewards.
    /// @param _validator Polygon validator ID to restake rewards for
    function restakeValidator(uint16 _validator) external whenNotPaused nonReentrant {
        _restakeValidator(_validator);
    }

    /// @notice Claims and restakes liquid rewards across all active validators
    /// @dev Gas-intensive operation that compounds rewards for the entire pool. Protocol fee taken on rewards.
    function restakeAllActiveValidators() external whenNotPaused nonReentrant {
        uint256 activeValidatorsLength = activeValidators.length;
        for (uint256 i = 0; i < activeValidatorsLength; i++) {
            _restakeValidator(activeValidators[i]);
        }
    }

    function _restakeValidator(uint16 _validator) internal {
        require(validators[_validator].status == ValidatorStatus.ACTIVE, ValidatorNotActive(_validator));
        (uint256 amountRestaked,) = validators[_validator].validatorContract.restakePOL();
        _adddPOLBalanceFee(amountRestaked);
        validators[_validator].totalStaked += amountRestaked;
        _emitExchangeRateUpdate();
    }

    /// @notice Moves stake between validators using StakeManager's migration mechanism
    /// @dev When _restake=true, both validators must be active. When _restake=false, no status checks
    ///      are enforced — this is intentional to allow recovery migrations (e.g. from deactivated
    ///      validators), but the caller must ensure correctness to avoid breaking accounting.
    /// @param _oldValidator Source validator ID to move stake from
    /// @param _newValidator Destination validator ID to receive stake
    /// @param _amount Amount of POL to migrate between validators
    /// @param _restake If true, claims and restakes rewards on both validators before migrating
    function migrateValidator(uint16 _oldValidator, uint16 _newValidator, uint256 _amount, bool _restake)
        external
        restricted
    {
        if (_restake) {
            _restakeValidator(_oldValidator);
            _restakeValidator(_newValidator);
        }

        stakeManager.migrateDelegation(_oldValidator, _newValidator, _amount);
        validators[_oldValidator].totalStaked -= _amount;
        validators[_newValidator].totalStaked += _amount;
        emit ValidatorMigrated(_oldValidator, _newValidator, _amount);
    }

    /// @notice Resyncs internal stake tracking with current validator share balances
    /// @dev Emergency function to fix accounting discrepancies. Only use if properly prepared.
    ///      Reads actual share balances from all active validators and updates totaldPOLBalance accordingly.
    function reloadAllActiveValidatorInfo() external restricted {
        uint256 amountToReduce;
        uint256 amountToAdd;
        uint256 activeValidatorsLength = activeValidators.length;
        for (uint256 i = 0; i < activeValidatorsLength; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            amountToReduce += validator.totalStaked;
            uint256 newStaked = validator.validatorContract.balanceOf(address(this));
            validator.totalStaked = newStaked;
            amountToAdd += newStaked;
        }
        totaldPOLBalance = totaldPOLBalance - amountToReduce + amountToAdd;
        _emitExchangeRateUpdate();
    }

    /// @notice Resyncs stake tracking for a single validator with on-chain balance
    /// @dev Emergency function to fix accounting for one validator without affecting others.
    ///      WARNING: Reloading a deactivated or inactive validator adds its shares to totaldPOLBalance
    ///      without a way to sell them, inflating the exchange rate. Only use on active validators
    ///      unless you intend to migrate the shares afterward.
    /// @param _validator Validator ID to resync
    function reloadValidatorInfo(uint16 _validator) external restricted {
        ValidatorInfo storage validator = validators[_validator];
        uint256 amountToReduce = validator.totalStaked;
        uint256 amountToAdd = validator.validatorContract.balanceOf(address(this));
        validator.totalStaked = amountToAdd;
        totaldPOLBalance = totaldPOLBalance - amountToReduce + amountToAdd;
        _emitExchangeRateUpdate();
    }

    ///////////////////////////////
    ///  General Exchange       ///
    ///////////////////////////////

    /// @notice Calculates sPOL amount received for a given POL deposit
    /// @param _amountPOL Amount of POL to convert
    /// @return Amount of sPOL that would be minted
    function convertPOLtoSPOL(uint256 _amountPOL) public view returns (uint256) {
        uint256 currentTotalsPOLBalance = totalsPOLBalance();
        if (_amountPOL == 0) {
            return 0;
        }
        if (currentTotalsPOLBalance == 0) {
            return _amountPOL;
        }
        return _amountPOL * currentTotalsPOLBalance / (totaldPOLBalance - feedPOLBalance);
    }

    /// @notice Calculates POL amount received for burning sPOL
    /// @param _amountSPOL Amount of sPOL to convert
    /// @return Amount of POL that would be redeemed
    function convertSPOLtoPOL(uint256 _amountSPOL) public view returns (uint256) {
        uint256 currentTotalsPOLBalance = totalsPOLBalance();
        if (_amountSPOL == 0) {
            return 0;
        }
        if (currentTotalsPOLBalance == 0) {
            return _amountSPOL;
        }
        return _amountSPOL * (totaldPOLBalance - feedPOLBalance) / currentTotalsPOLBalance;
    }

    /// @notice Returns total sPOL supply used for exchange rate calculation
    /// @return Total supply of sPOL tokens
    function totalsPOLBalance() public view returns (uint256) {
        return sPOLToken.totalSupply();
    }

    ///////////////////////////////
    ///  POL -> sPOL Exchange   ///
    ///////////////////////////////

    /// @notice Stakes POL and receives sPOL using automatic validator selection
    /// @dev Distributes deposit across validators based on capacity and target allocation. Requires prior approval.
    /// @param _amount Amount of POL to stake
    /// @return Amount of sPOL minted to caller
    function buySPOL(uint256 _amount) external whenNotPaused nonReentrant returns (uint256) {
        return _buySPOLMulti(_amount, msg.sender);
    }

    /// @notice Stakes POL using EIP-2612 permit for gasless approval
    /// @dev Combines approval and stake in one transaction. Distributes across validators automatically.
    /// @param _amount Amount of POL to stake
    /// @param _user Address that signed the permit and will receive sPOL
    /// @param _deadline Timestamp after which the permit expires
    /// @param _v Recovery byte of the permit signature
    /// @param _r First 32 bytes of the permit signature
    /// @param _s Second 32 bytes of the permit signature
    /// @return Amount of sPOL minted to user
    function buySPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _applyPermit(address(polToken), _amount, _user, _deadline, _v, _r, _s);
        return _buySPOLMulti(_amount, _user);
    }

    /// @notice Finds the validator with highest deposit capacity relative to target allocation
    /// @dev Skips locked validators. Use with single-validator buySPOL to optimize gas usage.
    /// @return validatorId ID of the most underfunded active validator
    /// @return maxDeposit Maximum POL that can be deposited to bring validator within divergence limit
    function getMostUnderfundedValidator() external view returns (uint16, uint256) {
        return _validatorWithHighestTotalStakeDistance(true);
    }

    /// @notice Stakes POL to a specific validator, saves gas compared to auto-selection
    /// @dev Deposit must not exceed validator's capacity. Requires prior approval.
    /// @param _amount Amount of POL to stake
    /// @param _validator Target validator ID for the deposit
    /// @return Amount of sPOL minted to caller
    function buySPOL(uint256 _amount, uint16 _validator) external whenNotPaused nonReentrant returns (uint256) {
        return _buySPOLSingle(_amount, _validator, msg.sender);
    }

    /// @notice Stakes POL to specific validator using EIP-2612 permit
    /// @dev Combines approval and single-validator stake in one transaction.
    /// @param _amount Amount of POL to stake
    /// @param _validator Target validator ID for the deposit
    /// @param _user Address that signed the permit and will receive sPOL
    /// @param _deadline Timestamp after which the permit expires
    /// @param _v Recovery byte of the permit signature
    /// @param _r First 32 bytes of the permit signature
    /// @param _s Second 32 bytes of the permit signature
    /// @return Amount of sPOL minted to user
    function buySPOLPermit(
        uint256 _amount,
        uint16 _validator,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external whenNotPaused nonReentrant returns (uint256) {
        _applyPermit(address(polToken), _amount, _user, _deadline, _v, _r, _s);
        return _buySPOLSingle(_amount, _validator, _user);
    }

    /// @notice Converts existing delegated POL (validator shares) to sPOL
    /// @dev Requires prior approval of validator share tokens. Migrates existing delegation into sPOL pool.
    ///      If validator is active and has capacity, stake stays; otherwise it's redistributed to other validators via migration.
    /// @param _amount Amount of delegated POL to convert
    /// @param _validatorOfDPOL Validator ID where the dPOL is currently staked
    /// @return Amount of sPOL minted to caller
    function buySPOLWithDPOL(uint256 _amount, uint16 _validatorOfDPOL)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return _buySPOLWithDPOLMulti(_amount, _validatorOfDPOL, msg.sender);
    }

    /// @notice Converts existing delegated POL (validator shares) to sPOL using permit
    /// @dev Combines approval and dPOL conversion in one transaction. Migrates delegation into sPOL pool.
    /// @param _amount Amount of delegated POL to convert
    /// @param _validatorOfDPOL Validator ID where the dPOL is currently staked
    /// @param _user Address that owns the dPOL and will receive sPOL
    /// @param _deadline Timestamp after which the permit expires
    /// @param _v Recovery byte of the permit signature
    /// @param _r First 32 bytes of the permit signature
    /// @param _s Second 32 bytes of the permit signature
    /// @return Amount of sPOL minted to user
    function buySPOLWithDPOLPermit(
        uint256 _amount,
        uint16 _validatorOfDPOL,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external whenNotPaused nonReentrant returns (uint256) {
        _applyPermit(stakeManager.getValidatorContract(_validatorOfDPOL), _amount, _user, _deadline, _v, _r, _s);
        return _buySPOLWithDPOLMulti(_amount, _validatorOfDPOL, _user);
    }

    function _buySPOLSingle(uint256 _amount, uint16 _validator, address _user) internal returns (uint256) {
        require(_amount > 0, AmountZero());
        uint256 toMint = convertPOLtoSPOL(_amount);
        ValidatorInfo storage validator = validators[_validator];
        require(validator.status == ValidatorStatus.ACTIVE, ValidatorNotActive(_validator));
        uint256 maxAmount = _maxDeposit(validator);
        require(_amount <= maxAmount, ValidatorOverfunded(_amount, maxAmount));
        _takePOL(_amount, _user);

        _buySharesFromValidator(validator, _amount);
        _mintSPOL(_user, _amount, toMint);
        _emitExchangeRateUpdate();
        return toMint;
    }

    function _buySPOLMulti(uint256 _amount, address _user) internal returns (uint256) {
        require(_amount > 0, AmountZero());
        uint256 toMint = convertPOLtoSPOL(_amount);
        (uint16[] memory validator, uint256[] memory amount) = _selectValidators(_amount, true);
        _takePOL(_amount, _user);
        uint256 totalShares;
        for (uint256 i = 0; i < amount.length; i++) {
            if (amount[i] == 0) {
                continue;
            }
            totalShares += _buySharesFromValidator(validators[validator[i]], amount[i]);
        }
        require(totalShares == _amount, BuySharesMismatch(_amount, totalShares));
        _mintSPOL(_user, _amount, toMint);
        _emitExchangeRateUpdate();
        return toMint;
    }

    function _buySPOLWithDPOLMulti(uint256 _amount, uint16 _validatorOfDPOL, address _user) internal returns (uint256) {
        require(_amount > 0, AmountZero());
        uint256 sPOLToMint = convertPOLtoSPOL(_amount);
        ValidatorInfo storage incomingValidator = validators[_validatorOfDPOL];

        if (incomingValidator.status == ValidatorStatus.ACTIVE && _amount <= _maxDeposit(incomingValidator)) {
            (bool success, uint256 restakedAmount) =
                incomingValidator.validatorContract.restakeAndTransferFrom(_user, _amount);
            require(success, DPOLRestakeTransferFromFailed());

            _adddPOLBalanceFee(restakedAmount);
            incomingValidator.totalStaked += restakedAmount + _amount;
        } else {
            (uint16[] memory selectedValidators, uint256[] memory selectedAmounts) = _selectValidators(_amount, true);

            // here we use transferFrom, without restake as we don't want to change state of inactive validators
            bool success = IValidatorShare(stakeManager.getValidatorContract(_validatorOfDPOL))
                .transferFrom(_user, address(this), _amount);
            require(success, DPOLRestakeTransferFromFailed());

            for (uint256 i = 0; i < selectedAmounts.length; i++) {
                if (selectedAmounts[i] == 0) {
                    continue;
                }
                _restakeValidator(selectedValidators[i]);
                if (validators[selectedValidators[i]].index != _validatorOfDPOL) {
                    stakeManager.migrateDelegation(_validatorOfDPOL, selectedValidators[i], selectedAmounts[i]);
                }
                validators[selectedValidators[i]].totalStaked += selectedAmounts[i];
            }
        }
        _adddPOLBalance(_amount);
        _mintSPOL(_user, _amount, sPOLToMint);
        _emitExchangeRateUpdate();
        return sPOLToMint;
    }

    function _buySharesFromValidator(ValidatorInfo storage _validator, uint256 _amount) internal returns (uint256) {
        (uint256 amountDeposited, uint256 liquidReward) = _validator.validatorContract.restakeAndStakePOL(_amount);
        uint256 userDeposit = amountDeposited - liquidReward;
        require(userDeposit == _amount, IncorrectValidatorShareExchangeRate(_amount, userDeposit));
        _adddPOLBalanceFee(liquidReward);
        _adddPOLBalance(userDeposit);
        validators[_validator.index].totalStaked += amountDeposited;
        return userDeposit;
    }

    ///////////////////////////////
    ///  sPOL -> POL Exchange   ///
    ///////////////////////////////

    /// @notice Burns sPOL to initiate POL redemption with automatic validator selection
    /// @dev Creates withdrawal nonces subject to StakeManager's unbonding period. Call withdrawPOL after unbonding.
    /// @param _amount Amount of sPOL to burn
    /// @return nonces Array of withdrawal nonces for tracking unbonding progress
    function sellSPOL(uint256 _amount) external whenNotPaused nonReentrant returns (uint256[] memory) {
        return _sellSPOLMulti(_amount, msg.sender);
    }

    /// @notice Burns sPOL using EIP-2612 permit for gasless burn
    /// @dev Use the permit as owner intent to sell. Creates withdrawal nonces for unbonding.
    /// @param _amount Amount of sPOL to burn
    /// @param _user Address that signed the permit and will receive POL after unbonding
    /// @param _deadline Timestamp after which the permit expires
    /// @param _v Recovery byte of the permit signature
    /// @param _r First 32 bytes of the permit signature
    /// @param _s Second 32 bytes of the permit signature
    /// @return nonces Array of withdrawal nonces for tracking unbonding progress
    function sellSPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory)
    {
        _applyPermit(address(sPOLToken), _amount, _user, _deadline, _v, _r, _s);
        return _sellSPOLMulti(_amount, _user);
    }

    /// @notice Finds the validator with highest redemption capacity relative to target allocation
    /// @dev Use with single-validator sellSPOL to optimize gas cost.
    /// @return validatorId ID of the most overfunded active validator
    /// @return maxRedeem Maximum POL that can be redeemed
    function getMostOverfundedValidator() external view returns (uint16, uint256) {
        return _validatorWithHighestTotalStakeDistance(false);
    }

    /// @notice Burns sPOL to redeem from a specific validator, saves gas compared to auto-selection
    /// @dev Redemption must not exceed validator's capacity.
    /// @param _amount Amount of sPOL to burn
    /// @param _validator Target validator ID to redeem from
    /// @return nonce Withdrawal nonce for tracking unbonding progress
    function sellSPOL(uint256 _amount, uint16 _validator) external whenNotPaused nonReentrant returns (uint256) {
        return _sellSPOLSingle(_amount, _validator, msg.sender);
    }

    /// @notice Burns sPOL from specific validator using EIP-2612 permit
    /// @dev Combines intent proof and single-validator redemption in one transaction.
    /// @param _amount Amount of sPOL to burn
    /// @param _validator Target validator ID to redeem from
    /// @param _user Address that signed the permit and will receive POL after unbonding
    /// @param _deadline Timestamp after which the permit expires
    /// @param _v Recovery byte of the permit signature
    /// @param _r First 32 bytes of the permit signature
    /// @param _s Second 32 bytes of the permit signature
    /// @return nonce Withdrawal nonce for tracking unbonding progress
    function sellSPOLPermit(
        uint256 _amount,
        uint16 _validator,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external whenNotPaused nonReentrant returns (uint256) {
        _applyPermit(address(sPOLToken), _amount, _user, _deadline, _v, _r, _s);
        return _sellSPOLSingle(_amount, _validator, _user);
    }

    function _sellSPOLSingle(uint256 _amount, uint16 _validator, address _user) internal returns (uint256) {
        ValidatorInfo storage validator = validators[_validator];
        require(validator.status == ValidatorStatus.ACTIVE, ValidatorNotActive(_validator));

        uint256 maxRedeem = _maxRedeem(validator);
        uint256 dPOLAmount = convertSPOLtoPOL(_amount);
        require(dPOLAmount > 0, AmountZero());
        require(dPOLAmount <= maxRedeem, ValidatorUnderfunded(dPOLAmount, maxRedeem));
        _takeSPOL(_amount, _user);

        uint256 userNonce = _sellSharesFromValidator(validator, dPOLAmount);
        uint256 nonce = _addUserWithdrawNonceDetails(_user, _validator, uint128(dPOLAmount), uint96(userNonce));

        emit sPOLBurned(_user, _amount, dPOLAmount, nonce);
        _emitExchangeRateUpdate();
        return nonce;
    }

    function _sellSPOLMulti(uint256 _amount, address _user) internal returns (uint256[] memory) {
        uint256 dPOLAmount = convertSPOLtoPOL(_amount);
        require(dPOLAmount > 0, AmountZero());
        (uint16[] memory validator, uint256[] memory amount) = _selectValidators(dPOLAmount, false);
        uint256[] memory sPOLAmounts = new uint256[](validator.length);
        for (uint256 i = 0; i < validator.length; i++) {
            sPOLAmounts[i] = convertPOLtoSPOL(amount[i]);
        }
        uint256[] memory nonces = new uint256[](validator.length);
        for (uint256 i = 0; i < validator.length; i++) {
            if (amount[i] == 0) {
                continue;
            }
            uint256 userNonce = _sellSharesFromValidator(validators[validator[i]], amount[i]);
            uint256 nonce = _addUserWithdrawNonceDetails(_user, validator[i], uint128(amount[i]), uint96(userNonce));
            nonces[i] = nonce;
            emit sPOLBurned(_user, sPOLAmounts[i], amount[i], nonce);
        }
        _takeSPOL(_amount, _user);
        _emitExchangeRateUpdate();
        return nonces;
    }

    function _sellSharesFromValidator(ValidatorInfo storage _validator, uint256 _amount) internal returns (uint256) {
        try _validator.validatorContract.restakeAndUnstakePOL(_amount) returns (uint256 liquidRewards) {
            _adddPOLBalanceFee(liquidRewards);
            validators[_validator.index].totalStaked += liquidRewards;
        } catch {
            _validator.validatorContract.sellVoucher_newPOL(_amount, _amount);
        }
        _removedPOLBalance(_amount);
        validators[_validator.index].totalStaked -= _amount;

        uint256 userNonce = _validator.validatorContract.unbondNonces(address(this));
        return userNonce;
    }

    /// @notice Returns all pending withdrawal nonces for a user
    /// @dev Each nonce represents an unbonding position. Check epoch progress to determine withdrawability.
    /// @param _user Address to query withdrawals for
    /// @return Array of withdrawal details including validator, amount, and nonce info
    function getUserOpenNonces(address _user) external view returns (FullNonceDetails[] memory) {
        DoubleEndedQueue.Bytes32Deque storage outstandingNonces = userNonces[_user];
        uint256 length = outstandingNonces.length();
        FullNonceDetails[] memory fullDetails = new FullNonceDetails[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 nonce = uint256(outstandingNonces.at(i));
            NonceDetails storage details = withdrawNonceDetails[nonce];
            fullDetails[i] = FullNonceDetails({
                validatorId: details.validatorId,
                amount: details.amount,
                validatorNonce: details.validatorNonce,
                nonce: nonce
            });
        }
        return fullDetails;
    }

    /// @notice Claims all matured POL withdrawals for the caller
    /// @dev Processes all ready nonces in FIFO order. Reverts if no withdrawals are ready.
    function withdrawPOL() external whenNotPaused nonReentrant {
        _withdrawPOL(msg.sender);
    }

    /// @notice Claims all matured POL withdrawals on behalf of another user
    /// @dev Anyone can call to process withdrawals for a user. POL sent to the user, not caller.
    /// @param _user Address to claim withdrawals for
    function withdrawPOL(address _user) external whenNotPaused nonReentrant {
        _withdrawPOL(_user);
    }

    function _withdrawPOL(address _user) internal {
        DoubleEndedQueue.Bytes32Deque storage outstandingNonces = userNonces[_user];
        require(outstandingNonces.length() > 0, NoOpenNonces(_user));

        uint256 totalToWithdraw;
        while (!outstandingNonces.empty()) {
            uint256 currentUserNonce = uint256(outstandingNonces.front());
            NonceDetails storage currentDetails = withdrawNonceDetails[currentUserNonce];
            IValidatorShare validatorContract = validators[currentDetails.validatorId].validatorContract;
            uint96 validatorNonce = currentDetails.validatorNonce;
            (uint256 shares, uint256 withdrawEpoch) = validatorContract.unbonds_new(address(this), validatorNonce);
            if (withdrawEpoch + stakeManager.withdrawalDelay() > stakeManager.epoch()) {
                break;
            }
            validatorContract.unstakeClaimTokens_newPOL(validatorNonce);
            totalToWithdraw += shares;
            emit POLWithdrawn(_user, shares, currentUserNonce);
            delete withdrawNonceDetails[currentUserNonce];
            outstandingNonces.popFront();
        }
        require(totalToWithdraw > 0, NoNoncesReady(_user));
        polToken.transfer(_user, totalToWithdraw);
    }

    ////////////////////////////////
    ///  Validator Selection     ///
    ////////////////////////////////

    function _validatorWithHighestTotalStakeDistance(bool _positive) internal view returns (uint16, uint256) {
        uint16 selectedValidator = activeValidators[0];
        uint256 maxDistance;
        uint256 activeValidatorsLength = activeValidators.length;
        for (uint256 i = 0; i < activeValidatorsLength; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];

            // Skip locked validators when looking for deposit capacity
            if (_positive && validator.validatorContract.locked()) {
                continue;
            }

            uint256 distance = _validatorMaxTotalStakeDistance(validator, _positive);

            if (maxDistance < distance) {
                maxDistance = distance;
                selectedValidator = validator.index;
            }
        }
        if (_positive && maxDistance == 0) {
            maxDistance = type(uint256).max;
        }
        return (selectedValidator, maxDistance);
    }

    function _maxDeposit(ValidatorInfo storage _validator) internal view returns (uint256) {
        uint8 myBigShare = _validator.depositShare + maxDivergence;
        if (myBigShare >= 100) {
            return type(uint256).max;
        }
        uint256 validatorStaked = _validator.totalStaked;
        uint256 theOtherShare = totaldPOLBalance - validatorStaked;
        uint8 restShare = 100 - myBigShare;
        uint256 myactualMaxShare = (theOtherShare * myBigShare) / restShare;
        if (myactualMaxShare <= validatorStaked) {
            return 0;
        }
        return myactualMaxShare - validatorStaked;
    }

    function _maxRedeem(ValidatorInfo storage _validator) internal view returns (uint256) {
        uint256 validatorStaked = _validator.totalStaked;
        uint8 validatorShare = _validator.depositShare;
        uint8 currentMaxDivergence = maxDivergence;
        if (validatorShare <= currentMaxDivergence) {
            return validatorStaked;
        }
        uint8 mySmallShare = validatorShare - currentMaxDivergence;

        uint256 theOtherShare = totaldPOLBalance - validatorStaked;
        uint8 restShare = 100 - mySmallShare;
        uint256 myactualMinShare = (theOtherShare * mySmallShare) / restShare;
        if (myactualMinShare >= validatorStaked) {
            return 0;
        }
        return validatorStaked - myactualMinShare;
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

    function _selectValidators(uint256 _amount, bool _buy) internal view returns (uint16[] memory, uint256[] memory) {
        uint256 activeValidatorsLength = activeValidators.length;
        uint16[] memory selectedValidators = new uint16[](activeValidatorsLength);
        uint256[] memory amounts = new uint256[](activeValidatorsLength);
        uint256 remainingAmount = _amount;
        uint256 assignedIndex = 0;

        for (uint256 i = 0; i < activeValidatorsLength; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];

            // Skip locked validators when buying
            if (_buy && validator.validatorContract.locked()) {
                continue;
            }

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
                selectedValidators[assignedIndex] = validator.index;
                amounts[assignedIndex] = remainingAmount;
                // memory cut to size assignedIndex+1 both arrays
                assembly {
                    mstore(selectedValidators, add(assignedIndex, 1))
                    mstore(amounts, add(assignedIndex, 1))
                }
                return (selectedValidators, amounts);
            } else {
                selectedValidators[assignedIndex] = validator.index;
                amounts[assignedIndex] = maxAmount;
                remainingAmount -= maxAmount;
            }
            assignedIndex++;
        }
        // in this case not enough theoretical capacity, so we just distribute to all equally
        if (_buy) {
            uint256 unlockedCount = assignedIndex;
            require(unlockedCount > 0, NoUnlockedValidators());

            uint256 perValidator = _amount / unlockedCount;
            for (uint256 i = 0; i < unlockedCount; i++) {
                amounts[i] = perValidator;
            }
            // Assign remainder to first validator
            amounts[0] += _amount % unlockedCount;

            // Trim arrays to unlocked count
            assembly {
                mstore(selectedValidators, unlockedCount)
                mstore(amounts, unlockedCount)
            }
        } else {
            uint256 remaining = _amount;
            // assignedIndex is length of selectedValidators here
            for (uint256 i = 0; i < assignedIndex; i++) {
                uint256 staked = validators[selectedValidators[i]].totalStaked;
                if (remaining > staked) {
                    amounts[i] = staked;
                    remaining -= staked;
                } else {
                    amounts[i] = remaining;
                    remaining = 0;
                    assembly {
                        mstore(selectedValidators, add(i, 1))
                        mstore(amounts, add(i, 1))
                    }
                    break;
                }
            }
            require(remaining == 0, NotEnoughStake(remaining));
        }
        return (selectedValidators, amounts);
    }

    ///////////////////////////////
    ///  Fee Management         ///
    ///////////////////////////////

    /// @notice Updates the address that receives protocol fees
    /// @dev Automatically collects any outstanding fees before changing receiver.
    /// @param _newFeeReceiver New address to receive future fee distributions
    function changeFeeReceiver(address _newFeeReceiver) external restricted {
        require(_newFeeReceiver != address(0), ZeroAddress());
        _takeFee();
        address oldReceiver = feeReceiver;
        feeReceiver = _newFeeReceiver;
        emit FeeReceiverChanged(oldReceiver, feeReceiver);
    }

    /// @notice Updates the protocol fee rate on staking rewards
    /// @dev Fee is in per mill (100 = 10%, max 1000). Does not collect outstanding fees.
    /// @param _newFee New fee rate in per mill
    function changeRewardFee(uint16 _newFee) external restricted {
        require(_newFee <= MAX_FEE, FeeTooLarge(_newFee, MAX_FEE));
        uint16 oldFee = rewardFee;
        rewardFee = _newFee;
        emit RewardFeeChanged(oldFee, rewardFee);
    }

    /// @notice Mints accumulated protocol fees as sPOL to the fee receiver
    /// @dev Fees accrue in feedPOLBalance as rewards are restaked.
    function takeFee() external restricted {
        _takeFee();
    }

    function _takeFee() internal {
        uint256 currentFeedPOLBalance = feedPOLBalance;
        if (currentFeedPOLBalance == 0) {
            return;
        }
        uint256 feeInsPOL = convertPOLtoSPOL(currentFeedPOLBalance);
        feedPOLBalance = 0;
        sPOLToken.mint(feeReceiver, feeInsPOL);
        emit FeeCollected(feeReceiver, currentFeedPOLBalance, feeInsPOL);
        _emitExchangeRateUpdate();
    }

    /////////////////////////////////
    ///  Internal Helper          ///
    /////////////////////////////////

    function _takeSPOL(uint256 _amount, address _user) internal {
        sPOLToken.burn(_user, _amount);
    }

    function _takePOL(uint256 _amount, address _user) internal {
        polToken.transferFrom(_user, address(this), _amount);
    }

    function _mintSPOL(address _user, uint256 amountPOL, uint256 amountSPOL) internal {
        sPOLToken.mint(_user, amountSPOL);
        emit sPOLMinted(_user, amountPOL, amountSPOL);
    }

    function _applyPermit(
        address _token,
        uint256 _amount,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) internal {
        ERC20Permit token = ERC20Permit(_token);
        uint256 nonceBefore = token.nonces(_user);
        if (_token == address(sPOLToken)) {
            // consume permit resets allowance to 0 after use, as we don't want any leftover allowance
            // allowance should have no negative downsides, we do this to be safe
            sPOLToken.consumePermit(_user, address(this), _amount, _deadline, _v, _r, _s);
        } else {
            ERC20Permit(_token).permit(_user, address(this), _amount, _deadline, _v, _r, _s);
        }
        require(token.nonces(_user) == nonceBefore + 1, InvalidPermit());
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

    // side effect: increases globalWithdrawNonce
    function _addUserWithdrawNonceDetails(address _user, uint16 _validatorId, uint128 _amount, uint96 _validatorNonce)
        internal
        returns (uint256)
    {
        uint256 nonce = globalWithdrawNonce++;
        userNonces[_user].pushBack(bytes32(nonce));
        NonceDetails storage details = withdrawNonceDetails[nonce];
        details.amount = _amount;
        details.validatorId = _validatorId;
        details.validatorNonce = _validatorNonce;
        return nonce;
    }

    function _emitExchangeRateUpdate() internal {
        emit ExchangeRateSnapshot(totalsPOLBalance(), totaldPOLBalance - feedPOLBalance);
    }

    ///////////////////////////////
    ///  Config                 ///
    ///////////////////////////////

    /// @notice Updates the maximum allowed stake divergence from target allocation
    /// @dev Higher values allow more flexibility but reduce rebalancing pressure. Affects deposit/redeem limits.
    /// @param _newDivergence New max divergence in percentage points
    function changeMaxDivergence(uint8 _newDivergence) external restricted {
        require(_newDivergence <= MAX_DIVERGENCE, MaxDivergenceTooLarge(_newDivergence, MAX_DIVERGENCE));
        uint8 oldDivergence = maxDivergence;
        maxDivergence = _newDivergence;
        emit MaxDivergenceChanged(oldDivergence, maxDivergence);
    }

    /// @notice Pauses all user-facing functions (buy, sell, withdraw, restake)
    /// @dev Admin functions remain available.
    function pauseUserFunctions() external restricted {
        _pause();
    }

    /// @notice Resumes all user-facing functions after a pause
    function unpauseUserFunctions() external restricted {
        _unpause();
    }

    ///////////////////////////////
    ///  Other                  ///
    ///////////////////////////////

    /// @notice Converts any MATIC/POL dust in the contract to staked POL
    /// @dev Migrates MATIC to POL, then stakes any POL balance to the specified validator.
    ///      The staked amount is treated as fee (benefits all holders). Use sparingly to avoid overfunding.
    /// @param _validator Active validator to receive the staked dust
    function cleanUpMaticPOL(uint16 _validator) external restricted {
        ValidatorInfo storage validator = validators[_validator];
        require(validator.status == ValidatorStatus.ACTIVE, ValidatorNotActive(_validator));

        uint256 maticBalance = maticToken.balanceOf(address(this));
        if (maticBalance > 0) {
            maticToken.approve(address(polygonMigration), maticBalance);
            polygonMigration.migrate(maticBalance);
            emit MaticTokensCleaned(maticBalance);
        }
        uint256 polBalance = polToken.balanceOf(address(this));
        require(polBalance > 0, AmountZero());

        uint256 actualShares = _buySharesFromValidator(validator, polBalance);
        // Apply fee fully
        _removedPOLBalance(actualShares);
        _adddPOLBalanceFee(actualShares);

        emit POLTokensCleaned(_validator, polBalance);

        _emitExchangeRateUpdate();
    }
}
