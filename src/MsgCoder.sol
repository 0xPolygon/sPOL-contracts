// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

abstract contract MsgCoder {
    enum MsgType {
        INVALID,
        EXCHANGE_UPDATE,
        L2_MIGRATION_REQUEST,
        L1_MIGRATION_RESPONSE,
        L2_BACKFILL_REQUEST,
        L1_BACKFILL_RESPONSE
    }

    function _decodeExchangeUpdateMessage(bytes memory _message)
        internal
        pure
        returns (uint256 _l1SPOLBalance, uint256 _l1DPOLBalance)
    {
        (_l1SPOLBalance, _l1DPOLBalance) = abi.decode(_message, (uint256, uint256));
    }

    function _encodeExchangeUpdateMessage(uint256 _l1SPOLBalance, uint256 _l1DPOLBalance)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_l1SPOLBalance, _l1DPOLBalance);
    }

    function _encodeL2MigrationRequestMessage(uint256 _polAmount, uint256 _sPOLAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_polAmount, _sPOLAmount);
    }

    function _decodeL2MigrationRequestMessage(bytes memory _message)
        internal
        pure
        returns (uint256 _polAmount, uint256 _sPOLAmount)
    {
        (_polAmount, _sPOLAmount) = abi.decode(_message, (uint256, uint256));
    }
}
