// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.30;

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

/// @title sPOL Child
/// @notice L2 contract for the sPOL liquid staking protocol on Polygon
/// @dev Handles L2 buy operations using a cached L1 exchange rate. Coordinates migrations
///      (surplus POL to L1) to keep L1/L2 balances in sync.
///      Also serves as the sPOL ERC20 token on L2.
contract sPOLChild is
    Initializable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardTransient,
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
    uint16 public constant MAX_SAFETY_FEE = 100; // max 1%
    uint256 public maxExchangeRateUpdateDelay;
    uint256 public lastExchangeRateUpdate;

    // local info
    uint256 public polBalance;
    // Deprecated slots, that have always been zero
    uint256 deprecated_missingWithdrawPOLBalance;
    uint256 deprecated_reservedWithdrawPOLBalance;
    uint256 deprecated_requestedWithdrawPOLBalance;

    // sPOL originating on L2 needs to be locked in the bridge from L1 so it becomes "real"
    uint256 public locallyMintedSPOL;
    // Deprecated slot, that has always been zero
    uint256 deprecated_locallyBurnedSPOL;
    // Deprecated slot, not zero
    address deprecated_l1Messenger;
    // Bridge helper contract, because POL has no withdrawFor function
    PolBridger public bridgeHelper;

    // Depositor bridge contract of sPOL
    address public childChainManager;

    // Migration tracking
    bool public onGoingMigration;
    uint256 public backMigratingSPOL;

    // Stake event
    event sPOLMinted(address indexed user, uint256 amountPOL, uint256 amountSPOL);

    // Exchange rate and operational events
    event ExchangeRateDeclined(
        uint256 currentSPOLBalance, uint256 currentDPOLBalance, uint256 declinedSPOLBalance, uint256 declinedDPOLBalance
    );
    event ExchangeRateUpdated(
        uint256 oldSPOLBalance, uint256 oldDPOLBalance, uint256 newSPOLBalance, uint256 newDPOLBalance
    );
    event InvalidMessageType(uint8 msgType);
    event SafetyFeeChanged(uint16 oldFee, uint16 newFee);
    event MaxExchangeRateDelayChanged(uint256 oldDelay, uint256 newDelay);
    event BridgeHelperUpdated(address indexed oldBridgeHelper, address indexed newBridgeHelper);

    // Migration events
    event BalancedOnlyLocally();
    event BalancingAlreadyOngoing();
    event MigrationCompleted(uint256 backMigratingSPOL);
    event MigrationRequested(uint256 migratingPOLAmount, uint256 bridgeMissingSPOL);

    error AddressUnauthorized(address caller);
    error ExchangeRateUpdateTooOld(uint256 lastUpdate, uint256 maxAge, uint256 currentTime);
    error FeeCannotBeZero();
    error FeeTooHigh(uint16 provided, uint16 maxAllowed);
    error IncorrectPOLAmount(uint256 sent, uint256 expected);
    error MigrationAlreadyOngoing();
    error POLAmountMustBeGreaterThanZero();
    error ZeroAddress();

    modifier onlyChildChainManager() {
        require(msg.sender == childChainManager, AddressUnauthorized(msg.sender));
        _;
    }

    constructor(address _stateSyncer) BaseChildTunnel(_stateSyncer) {
        require(_stateSyncer != address(0), ZeroAddress());

        _disableInitializers();
    }

    /// @notice Initializes the L2 sPOL contract with bridge and access control settings
    /// @dev Starts paused until exchange rate is received from L1. Sets initial safety fee.
    /// @param _authority AccessManager contract for restricted function access
    /// @param _bridgeHelper Helper contract for bridging POL back to L1
    /// @param _childChainManager Polygon PoS bridge deposit manager
    function initialize(address _authority, address _bridgeHelper, address _childChainManager) external initializer {
        require(_authority != address(0), ZeroAddress());
        require(_bridgeHelper != address(0), ZeroAddress());
        require(_childChainManager != address(0), ZeroAddress());

        __Pausable_init();
        __ERC20_init("Staked POL", "sPOL");
        __ERC20Permit_init("Staked POL");
        __AccessManaged_init(_authority);

        maxExchangeRateUpdateDelay = 10 days;
        safetyFee = 30; // 0.3%
        bridgeHelper = PolBridger(_bridgeHelper);
        childChainManager = _childChainManager;

        // Init so update can work
        l1DPOLBalance = 1;
        l1SPOLBalance = 1;

        _pause();
    }

    ///////////////////////////////
    ///  Stake                  ///
    ///////////////////////////////

    /// @notice Calculates sPOL amount received for POL deposit on L2, including safety fee
    /// @dev Applies safety fee to protect against exchange rate lag from L1. Fee benefits all sPOL holders.
    /// @param _polAmount Amount of POL to convert
    /// @return Amount of sPOL that would be minted (after safety fee deduction)
    function convertPOLToSPOL(uint256 _polAmount) public view returns (uint256) {
        if (_polAmount == 0) {
            return 0;
        }
        return
            (_polAmount * l1SPOLBalance * (SAFETY_FEE_DENOMINATOR - safetyFee))
                / (l1DPOLBalance * SAFETY_FEE_DENOMINATOR);
    }

    /// @notice Stakes native POL on L2 and receives sPOL
    /// @dev Requires exact POL amount as msg.value. Reverts if exchange rate is stale.
    ///      sPOL minted locally and later synced to L1 via migration.
    /// @param _polAmount Amount of native POL to stake (must equal msg.value)
    function buySPOL(uint256 _polAmount) external payable whenNotPaused nonReentrant {
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

    /////////////////////////////////
    ///  Token Bridging           ///
    /////////////////////////////////

    /// @notice Handles sPOL deposits from L1 via PoS bridge
    /// @dev Called by ChildChainManager during state syncs. If deposit is the returning migration sPOL, it's not minted
    ///      (to avoid having to immediately burn it again, generating duplicate exit event).
    /// @param user Recipient of the bridged sPOL
    /// @param depositData ABI-encoded uint256 amount
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

    /// @notice Burns sPOL to initiate bridge withdrawal to L1
    /// @dev Creates a burn event that can be used to claim sPOL on L1 via PoS bridge exit.
    /// @param amount Amount of sPOL to burn and withdraw to L1
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
        } else {
            emit InvalidMessageType(uint8(msgType));
            return;
        }
    }

    function _handleExchangeRateUpdate(bytes memory _msg) internal {
        (uint256 updatedl1SPOLBalance, uint256 updatedl1DPOLBalance) = _decodeExchangeUpdateMessage(_msg);
        if (updatedl1DPOLBalance * l1SPOLBalance < l1DPOLBalance * updatedl1SPOLBalance) {
            emit ExchangeRateDeclined(l1SPOLBalance, l1DPOLBalance, updatedl1SPOLBalance, updatedl1DPOLBalance);
            return;
        }
        if (onGoingMigration) {
            emit BalancingAlreadyOngoing();
            return;
        }
        _balanceWithL1();
        uint256 oldSPOLBalance = l1SPOLBalance;
        uint256 oldDPOLBalance = l1DPOLBalance;
        l1SPOLBalance = updatedl1SPOLBalance;
        l1DPOLBalance = updatedl1DPOLBalance;
        lastExchangeRateUpdate = block.timestamp;
        emit ExchangeRateUpdated(oldSPOLBalance, oldDPOLBalance, updatedl1SPOLBalance, updatedl1DPOLBalance);
    }

    /// @notice Triggers L1/L2 balance synchronization
    /// @dev Initiates either migration (surplus POL to L1) or local balancing only.
    ///      Automatically called during exchange rate updates. Can be called manually if needed.
    function balanceWithL1() external restricted nonReentrant {
        _balanceWithL1();
    }

    function _balanceWithL1() internal {
        require(!onGoingMigration, MigrationAlreadyOngoing());

        if (polBalance > 0) {
            uint256 sPOLToBeMinted = locallyMintedSPOL;
            locallyMintedSPOL = 0;
            _requestMigration(polBalance, sPOLToBeMinted);
        } else {
            emit BalancedOnlyLocally();
        }
    }

    function _requestMigration(uint256 _polToMigrate, uint256 _spolToMint) internal {
        onGoingMigration = true;
        backMigratingSPOL = _spolToMint;
        polBalance -= _polToMigrate;

        _exitPOLforMessenger(_polToMigrate);
        _sendMessageToRoot(
            abi.encode(MsgType.L2_MIGRATION_REQUEST, _encodeL2MigrationRequestMessage(_polToMigrate, _spolToMint))
        );
        emit MigrationRequested(_polToMigrate, _spolToMint);
    }

    ///////////////////////////////
    ///  Config                 ///
    ///////////////////////////////

    /// @notice Updates the safety fee applied to L2 buys
    /// @dev Fee in basis points (30 = 0.3%). Protects against exchange rate lag arbitrage. Max 1%.
    ///      The fee must be large enough to cover the expected L1 exchange rate appreciation during
    ///      maxExchangeRateUpdateDelay. Must be re-evaluated if L1 StakeManager reward parameters change.
    /// @param _newFee New safety fee (max MAX_SAFETY_FEE = 100 = 1%, cannot be 0)
    function changeSafetyFee(uint16 _newFee) external restricted {
        require(_newFee > 0, FeeCannotBeZero());
        require(_newFee <= MAX_SAFETY_FEE, FeeTooHigh(_newFee, MAX_SAFETY_FEE));
        uint16 oldFee = safetyFee;
        safetyFee = _newFee;
        emit SafetyFeeChanged(oldFee, _newFee);
    }

    /// @notice Updates how long the exchange rate remains valid without L1 updates
    /// @dev If exceeded, buy operations pause automatically. Prevents exchange on stale rates.
    ///      WARNING: Setting to 0 blocks all buys. Setting too high allows trading on stale rates,
    ///      which weakens the safety fee protection. Must be aligned with the service's update frequency.
    /// @param _newDelay New maximum age in seconds for the exchange rate
    function setMaxExchangeRateUpdateDelay(uint256 _newDelay) external restricted {
        uint256 oldDelay = maxExchangeRateUpdateDelay;
        maxExchangeRateUpdateDelay = _newDelay;
        emit MaxExchangeRateDelayChanged(oldDelay, _newDelay);
    }

    /// @notice Sets or updates the PolBridger (bridge helper) address
    /// @dev Restricted to AccessManager.
    /// @param _bridgeHelper New PolBridger address
    function updateBridgeHelper(address _bridgeHelper) external restricted {
        require(_bridgeHelper != address(0), ZeroAddress());
        emit BridgeHelperUpdated(address(bridgeHelper), _bridgeHelper);
        bridgeHelper = PolBridger(_bridgeHelper);
    }

    /// @notice Pauses buy operations on L2
    function pauseBuy() external restricted {
        _pause();
    }

    /// @notice Resumes buy operations on L2
    /// @dev Only succeeds if exchange rate is fresh (within maxExchangeRateUpdateDelay).
    function unpauseBuy() external restricted {
        require(
            lastExchangeRateUpdate + maxExchangeRateUpdateDelay >= block.timestamp,
            ExchangeRateUpdateTooOld(lastExchangeRateUpdate, maxExchangeRateUpdateDelay, block.timestamp)
        );
        _unpause();
    }

    /////////////////////////////////
    ///  Internal Helpers       ///
    /////////////////////////////////

    function _exitPOLforMessenger(uint256 _polAmount) internal {
        bridgeHelper.bridgePOLToL1{value: _polAmount}(_polAmount);
    }
}

