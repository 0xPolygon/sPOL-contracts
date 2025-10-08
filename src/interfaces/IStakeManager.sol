// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

library StakeManagerStorage {
    type Status is uint8;
}

interface StakeManager {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RootChainChanged(address indexed previousRootChain, address indexed newRootChain);

    function CHECKPOINT_REWARD() external view returns (uint256);
    function NFTContract() external view returns (address);
    function NFTCounter() external view returns (uint256);
    function WITHDRAWAL_DELAY() external view returns (uint256);
    function accountStateRoot() external view returns (bytes32);
    function auctionPeriod() external view returns (uint256);
    function changeRootChain(address newRootChain) external;
    function checkPointBlockInterval() external view returns (uint256);
    function checkSignatures(
        uint256 blockInterval,
        bytes32 voteHash,
        bytes32 stateRoot,
        address proposer,
        uint256[3][] memory sigs
    ) external returns (uint256);
    function checkpointRewardDelta() external view returns (uint256);
    function claimFee(uint256 accumFeeAmount, uint256 index, bytes memory proof) external;
    function convertMaticToPOL(uint256 amount) external;
    function currentEpoch() external view returns (uint256);
    function currentValidatorSetSize() external view returns (uint256);
    function currentValidatorSetTotalStake() external view returns (uint256);
    function decreaseValidatorDelegatedAmount(uint256 validatorId, uint256 amount) external;
    function delegatedAmount(uint256 validatorId) external view returns (uint256);
    function delegationDeposit(uint256 validatorId, uint256 amount, address delegator) external returns (bool);
    function delegationDepositPOL(uint256 validatorId, uint256 amount, address delegator) external returns (bool);
    function delegationEnabled() external view returns (bool);
    function delegatorsReward(uint256 validatorId) external view returns (uint256);
    function dynasty() external view returns (uint256);
    function epoch() external view returns (uint256);
    function eventsHub() external view returns (address);
    function extensionCode() external view returns (address);
    function forceUnstake(uint256 validatorId) external;
    function forceUnstakePOL(uint256 validatorId) external;
    function getRegistry() external view returns (address);
    function getValidatorContract(uint256 validatorId) external view returns (address);
    function getValidatorId(address user) external view returns (uint256);
    function governance() external view returns (address);
    function initialize(
        address _registry,
        address _rootchain,
        address _tokenLegacy,
        address _NFTContract,
        address _stakingLogger,
        address _validatorShareFactory,
        address _governance,
        address _owner,
        address _extensionCode,
        address _token,
        address _migration
    ) external;
    function insertSigners(address[] memory _signers) external;
    function isOwner() external view returns (bool);
    function isValidator(uint256 validatorId) external view returns (bool);
    function latestSignerUpdateEpoch(uint256) external view returns (uint256);
    function lock() external;
    function locked() external view returns (bool);
    function logger() external view returns (address);
    function maxRewardedCheckpoints() external view returns (uint256);
    function migrateDelegation(uint256 fromValidatorId, uint256 toValidatorId, uint256 amount) external;
    function migrateValidatorsData(uint256 validatorIdFrom, uint256 validatorIdTo) external;
    function migration() external view returns (address);
    function minDeposit() external view returns (uint256);
    function minHeimdallFee() external view returns (uint256);
    function owner() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function prevBlockInterval() external view returns (uint256);
    function proposerBonus() external view returns (uint256);
    function registry() external view returns (address);
    function renounceOwnership() external;
    function replacementCoolDown() external view returns (uint256);
    function restake(uint256 validatorId, uint256 amount, bool stakeRewards) external;
    function restakePOL(uint256 validatorId, uint256 amount, bool stakeRewards) external;
    function rewardDecreasePerCheckpoint() external view returns (uint256);
    function rewardPerStake() external view returns (uint256);
    function rootChain() external view returns (address);
    function setCurrentEpoch(uint256 _currentEpoch) external;
    function setDelegationEnabled(bool enabled) external;
    function signerToValidator(address) external view returns (uint256);
    function signerUpdateLimit() external view returns (uint256);
    function signers(uint256) external view returns (address);
    function stakeFor(
        address user,
        uint256 amount,
        uint256 heimdallFee,
        bool acceptDelegation,
        bytes memory signerPubkey
    ) external;
    function stakeForPOL(
        address user,
        uint256 amount,
        uint256 heimdallFee,
        bool acceptDelegation,
        bytes memory signerPubkey
    ) external;
    function token() external view returns (address);
    function tokenMatic() external view returns (address);
    function topUpForFee(address user, uint256 heimdallFee) external;
    function totalHeimdallFee() external view returns (uint256);
    function totalRewards() external view returns (uint256);
    function totalRewardsLiquidated() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function totalStakedFor(address user) external view returns (uint256);
    function transferFunds(uint256 validatorId, uint256 amount, address delegator) external returns (bool);
    function transferFundsPOL(uint256 validatorId, uint256 amount, address delegator) external returns (bool);
    function transferOwnership(address newOwner) external;
    function unlock() external;
    function unstake(uint256 validatorId) external;
    function unstakeClaim(uint256 validatorId) external;
    function unstakeClaimPOL(uint256 validatorId) external;
    function unstakePOL(uint256 validatorId) external;
    function updateCheckPointBlockInterval(uint256 _blocks) external;
    function updateCheckpointReward(uint256 newReward) external;
    function updateCheckpointRewardParams(
        uint256 _rewardDecreasePerCheckpoint,
        uint256 _maxRewardedCheckpoints,
        uint256 _checkpointRewardDelta
    ) external;
    function updateCommissionRate(uint256 validatorId, uint256 newCommissionRate) external;
    function updateDynastyValue(uint256 newDynasty) external;
    function updateMinAmounts(uint256 _minDeposit, uint256 _minHeimdallFee) external;
    function updateProposerBonus(uint256 newProposerBonus) external;
    function updateSigner(uint256 validatorId, bytes memory signerPubkey) external;
    function updateSignerUpdateLimit(uint256 _limit) external;
    function updateValidatorContractAddress(uint256 validatorId, address newContractAddress) external;
    function updateValidatorDelegation(bool delegation) external;
    function updateValidatorState(uint256 validatorId, int256 amount) external;
    function updateValidatorThreshold(uint256 newThreshold) external;
    function userFeeExit(address) external view returns (uint256);
    function validatorAuction(uint256)
        external
        view
        returns (uint256 amount, uint256 startEpoch, address user, bool acceptDelegation, bytes memory signerPubkey);
    function validatorReward(uint256 validatorId) external view returns (uint256);
    function validatorShareFactory() external view returns (address);
    function validatorStake(uint256 validatorId) external view returns (uint256);
    function validatorState() external view returns (uint256 amount, uint256 stakerCount);
    function validatorStateChanges(uint256) external view returns (int256 amount, int256 stakerCount);
    function validatorThreshold() external view returns (uint256);
    function validators(uint256)
        external
        view
        returns (
            uint256 amount,
            uint256 reward,
            uint256 activationEpoch,
            uint256 deactivationEpoch,
            uint256 jailTime,
            address signer,
            address contractAddress,
            StakeManagerStorage.Status status,
            uint256 commissionRate,
            uint256 lastCommissionUpdate,
            uint256 delegatorsReward,
            uint256 delegatedAmount,
            uint256 initialRewardPerStake
        );
    function withdrawDelegatorsReward(uint256 validatorId) external returns (uint256);
    function withdrawRewards(uint256 validatorId) external;
    function withdrawRewardsPOL(uint256 validatorId) external;
    function withdrawalDelay() external view returns (uint256);
}
