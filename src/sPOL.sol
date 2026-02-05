// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title sPOL Token
/// @notice ERC20 token representing staked POL in the liquid staking protocol
/// @dev Mint and burn controlled exclusively by sPOLController. Supports EIP-2612 permits.
contract sPOL is Initializable, ERC20PermitUpgradeable {
    address public immutable sPOLController;

    error AddressUnauthorized(address caller);
    error ZeroAddress();

    modifier onlyController() {
        require(msg.sender == sPOLController, AddressUnauthorized(msg.sender));
        _;
    }

    constructor(address _sPOLController) {
        require(_sPOLController != address(0), ZeroAddress());

        sPOLController = _sPOLController;

        _disableInitializers();
    }

    /// @notice Initializes the sPOL token with name, symbol, and EIP-2612 permit support
    /// @dev Must be called once after proxy deployment. Sets token name to "Staked POL" and symbol to "sPOL".
    function initialize() external initializer {
        __ERC20_init("Staked POL", "sPOL");
        __ERC20Permit_init("Staked POL");
    }

    /// @notice Applies a permit and immediately resets allowance to zero
    /// @dev Used for gasless sPOL sells. Resets allowance since controller burns directly, not via transferFrom.
    ///      Front-running with a normal permit invalidates the nonce and causes a safe revert.
    /// @param _owner Token owner who signed the permit
    /// @param _spender Address being approved (should be controller)
    /// @param _value Amount approved in the permit
    /// @param _deadline Timestamp after which the permit expires
    /// @param _v Recovery byte of the permit signature
    /// @param _r First 32 bytes of the permit signature
    /// @param _s Second 32 bytes of the permit signature
    function consumePermit(
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external onlyController {
        permit(_owner, _spender, _value, _deadline, _v, _r, _s);
        _approve(_owner, _spender, 0);
    }

    /// @notice Mints sPOL tokens to an address
    /// @dev Only callable by sPOLController. Used when users stake POL or fees are distributed.
    /// @param to Recipient of the minted tokens
    /// @param amount Amount of sPOL to mint
    function mint(address to, uint256 amount) external onlyController {
        _mint(to, amount);
    }

    /// @notice Burns sPOL tokens from an address
    /// @dev Only callable by sPOLController. Used when users redeem sPOL for POL.
    ///      No approval required - controller can burn from any address.
    /// @param from Address to burn tokens from
    /// @param amount Amount of sPOL to burn
    function burn(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }
}
