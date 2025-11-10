// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface sPOLController {
    // Shows how much one sPOL is worth in POL
    function actualExchangeRatePOLsPOL() external view returns (uint256);
    // Buys sPOL with POL, amount is the POL amount, returns received sPOL amount
    function buySPOL(uint256 _amount) external returns (uint256);
    // Same as above, just with permit
    function buySPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256);
    // Gets the active user nonces to be used for withdraws
    function getReadyUserNonces(address _user) external view returns (uint256[] memory);
    // Initiates the sell of a certain amount of sPOL for POL, returns the nonce id
    function initSellSPOL(uint256 _amount) external returns (uint256);
    // Same as above, just with permit
    function initSellSPOLPermit(uint256 _amount, address _user, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256);
    // Maximum amount of POL that can be deposited into the contract in one tx
    // More is possible with multi tx, maybe this will be changed to allow more in one tx
    function maxDeposit() external view returns (uint256);
    // Maximum amount of POL that can be redeemed from the contract in one tx
    // More is possible with multi tx, maybe this will be changed to allow more in one tx
    function maxRedeem() external view returns (uint256);
    // Restakes all active validators, increases sPOL value, but is very gas heavy (maybe interesting for very wealthy users)
    function restakeAllActiveValidators() external;
    // Restakes a specific validator, increases sPOL value, much cheaper than restakeAllActiveValidators
    function restakeValidator(uint16 _validator) external;
    // Current fee taken by Polygon, fee is on rewards only
    function rewardFee() external view returns (uint16);
    // Address of the sPOL token
    function sPOLToken() external view returns (address);
    // Total backing of sPOL the contract has in dPOL (minus rewards)
    function totaldPOLBalance() external view returns (uint256);
    // Total amount of sPOL in circulation
    function totalsPOLBalance() external view returns (uint256);
    // sPOL value in POL, should restakeAllValidators be called now
    function virtualExchangeRatePOLsPOL() external view returns (uint256);
    // Withdraws all available POL for the msg.sender
    function withdrawPOL() external;
    // Withdraws the POL for a specific nonce
    function withdrawPOL(uint256 _nonce) external;
}
