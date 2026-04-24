// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MRC20 as IMRC20} from "./interfaces/IMRC20.sol";
import {ERC20PredicateBurnOnly as IERC20PredicateBurnOnly} from "./interfaces/IERC20Predicate.sol";
import {WithdrawManager as IWithdrawManager} from "./interfaces/IWithdrawManager.sol";
import {Registry as IRegistry} from "./interfaces/IRegistry.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title POL Bridger
/// @notice Helper contract for bridging POL between L1 and L2 via Polygon PoS bridge
/// @dev Deployed on both chains behind a proxy. On L2, initiates withdrawals via MRC20 burn.
///      On L1, processes exits and transfers POL to the messenger for migration processing.
///      Predicate and withdraw manager addresses are resolved from the Plasma Registry on
///      every call so protocol upgrades do not require redeploys.
contract PolBridger is Initializable, AccessManagedUpgradeable, PausableUpgradeable, ReentrancyGuardTransient {
    address public immutable polTokenL1;
    address public immutable polTokenL2;
    address public immutable maticTokenL1;
    uint256 public immutable chainIDL1;
    uint256 public immutable chainIDL2;
    IRegistry public immutable registry;

    address public sPOLMessengerL1;
    address public sPOLMessengerL2;

    error AddressUnauthorized(address caller);
    error InsufficientPOLSent(uint256 sent, uint256 required);
    error InvalidOriginChain(uint256 currentChain, uint256 expectedChain);
    error RegistryReturnedZero();
    error ZeroAddress();

    constructor(
        address _polTokenL1,
        address _polTokenL2,
        address _maticTokenL1,
        uint256 _chainIDL1,
        uint256 _chainIDL2,
        address _registry
    ) {
        polTokenL1 = _polTokenL1;
        polTokenL2 = _polTokenL2;
        maticTokenL1 = _maticTokenL1;
        chainIDL1 = _chainIDL1;
        chainIDL2 = _chainIDL2;
        registry = IRegistry(_registry);

        _disableInitializers();
    }

    /// @notice Initializes the bridger with access control and messenger addresses
    /// @param _authority AccessManager contract for restricted function access
    /// @param _sPOLMessengerL1 Address of sPOLMessenger on Ethereum mainnet
    /// @param _sPOLMessengerL2 Address of sPOLChild on Polygon
    function initialize(address _authority, address _sPOLMessengerL1, address _sPOLMessengerL2) external initializer {
        require(_authority != address(0), ZeroAddress());
        require(_sPOLMessengerL1 != address(0), ZeroAddress());
        require(_sPOLMessengerL2 != address(0), ZeroAddress());

        __AccessManaged_init(_authority);
        __Pausable_init();

        sPOLMessengerL1 = _sPOLMessengerL1;
        sPOLMessengerL2 = _sPOLMessengerL2;
    }

    /// @notice Initiates POL bridge withdrawal from L2 to L1
    /// @dev Only callable by sPOLChild on Polygon. Burns POL via MRC20 withdraw to create exit event.
    /// @param _amount Amount of native POL to bridge (must equal msg.value)
    function bridgePOLToL1(uint256 _amount) external payable whenNotPaused nonReentrant {
        require(msg.value == _amount, InsufficientPOLSent(msg.value, _amount));
        require(msg.sender == sPOLMessengerL2, AddressUnauthorized(msg.sender));
        require(block.chainid == chainIDL2, InvalidOriginChain(block.chainid, chainIDL2));
        IMRC20(polTokenL2).withdraw{value: _amount}(_amount);
    }

    /// @notice Submits burn proof to start POL exit on L1
    /// @dev Anyone can call with valid proof. Proof is generated from L2 burn transaction after checkpoint.
    ///      Predicate address is resolved from the registry on every call.
    /// @param proof Merkle proof of the POL burn event on L2
    function exitPOL(bytes memory proof) external whenNotPaused nonReentrant {
        require(block.chainid == chainIDL1, InvalidOriginChain(block.chainid, chainIDL1));
        IERC20PredicateBurnOnly(_erc20Predicate()).startExitWithBurntTokens(proof);
    }

    /// @notice Processes pending POL(matic) exits and releases tokens to this contract
    /// @dev Anyone can call. Processes all exits in queue for POL token. POL stays in bridger until taken.
    ///      Withdraw manager address is resolved from the registry on every call.
    function finalizeExitPOL() external whenNotPaused nonReentrant {
        require(block.chainid == chainIDL1, InvalidOriginChain(block.chainid, chainIDL1));
        IWithdrawManager(_withdrawManager()).processExits(maticTokenL1);
    }

    /// @notice Transfers POL from bridger to messenger for migration processing
    /// @dev Only callable by sPOLMessenger on L1. Used when processing L2 migration requests.
    /// @param _amount Amount of POL to transfer to the messenger
    function takePOLL1(uint256 _amount) external whenNotPaused nonReentrant {
        require(msg.sender == sPOLMessengerL1, AddressUnauthorized(msg.sender));
        require(block.chainid == chainIDL1, InvalidOriginChain(block.chainid, chainIDL1));
        IERC20(polTokenL1).transfer(sPOLMessengerL1, _amount);
    }

    /// @notice Recovers tokens accidentally sent to the bridger
    /// @param _token ERC20 token address to rescue
    /// @param _to Recipient address for rescued tokens
    /// @param _amount Amount of tokens to transfer
    function rescue(address _token, address _to, uint256 _amount) external restricted {
        SafeERC20.safeTransfer(IERC20(_token), _to, _amount);
    }

    /// @notice Recovers native POL/ETH accidentally sent to the bridger on L2/L1
    /// @param _to Recipient address for rescued native POL/ETH
    /// @param _amount Amount of native POL/ETH to transfer
    function rescueNative(address _to, uint256 _amount) external restricted {
        (bool success,) = payable(_to).call{value: _amount}("");
        require(success, "Native transfer failed");
    }

    /// @notice Pauses all bridge operations
    function pause() external restricted {
        _pause();
    }

    /// @notice Resumes bridge operations after a pause
    function unpause() external restricted {
        _unpause();
    }

    function _erc20Predicate() internal view returns (address) {
        address predicate = registry.erc20Predicate();
        require(predicate != address(0), RegistryReturnedZero());
        return predicate;
    }

    function _withdrawManager() internal view returns (address) {
        address withdrawManager = registry.getWithdrawManagerAddress();
        require(withdrawManager != address(0), RegistryReturnedZero());
        return withdrawManager;
    }
}
