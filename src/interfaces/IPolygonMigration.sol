// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Polygon Migration
/// @author Polygon Labs (@DhairyaSethi, @gretzke, @qedk)
/// @notice This is the migration contract for Matic <-> Polygon ERC20 token on Ethereum L1
/// @dev The contract allows for a 1-to-1 conversion from $MATIC into $POL and vice-versa
interface IPolygonMigration {
    /// @notice emitted when MATIC are migrated to POL
    /// @param account the account that migrated MATIC
    /// @param recipient the account that received POL
    /// @param amount the amount of MATIC that was migrated
    event Migrated(address indexed account, address recipient, uint256 amount);

    /// @notice this function allows for migrating MATIC tokens to POL tokens
    /// @param amount amount of MATIC to migrate
    /// @dev the function does not do any validation since the migration is a one-way process
    function migrate(uint256 amount) external;
}
