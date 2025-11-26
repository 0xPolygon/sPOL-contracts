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

    function _encodeL1MigrationResponseMessage(uint256 _sPOLAmount) internal pure returns (bytes memory) {
        return abi.encode(_sPOLAmount);
    }

    function _decodeL1MigrationResponseMessage(bytes memory _message) internal pure returns (uint256 _sPOLAmount) {
        (_sPOLAmount) = abi.decode(_message, (uint256));
    }

    function _encodeL2BackfillRequestMessage(uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_polAmount, _sPOLAmount, _backFillCycle);
    }

    function _decodeL2BackfillRequestMessage(bytes memory _message)
        internal
        pure
        returns (uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle)
    {
        (_polAmount, _sPOLAmount, _backFillCycle) = abi.decode(_message, (uint256, uint256, uint256));
    }

    function _encodeL1BackfillResponseMessage(uint256 _polAmount, uint256 _backFillCycle)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_polAmount, _backFillCycle);
    }

    function _decodeL1BackfillResponseMessage(bytes memory _message)
        internal
        pure
        returns (uint256 _polAmount, uint256 _backFillCycle)
    {
        (_polAmount, _backFillCycle) = abi.decode(_message, (uint256, uint256));
    }
}
