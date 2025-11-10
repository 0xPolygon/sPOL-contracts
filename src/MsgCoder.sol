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

    function decodeExchangeUpdateMessage(bytes memory message)
        internal
        pure
        returns (uint256 _l1SPOLBalance, uint256 _l1DPOLBalance)
    {
        (_l1SPOLBalance, _l1DPOLBalance) = abi.decode(message, (uint256, uint256));
    }

    function encodeExchangeUpdateMessage(uint256 _l1SPOLBalance, uint256 _l1DPOLBalance)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_l1SPOLBalance, _l1DPOLBalance);
    }

    function encodeL2MigrationRequestMessage(uint256 _polAmount, uint256 _sPOLAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_polAmount, _sPOLAmount);
    }

    function decodeL2MigrationRequestMessage(bytes memory message)
        internal
        pure
        returns (uint256 _polAmount, uint256 _sPOLAmount)
    {
        (_polAmount, _sPOLAmount) = abi.decode(message, (uint256, uint256));
    }

    function encodeL1MigrationResponseMessage(uint256 _sPOLAmount) internal pure returns (bytes memory) {
        return abi.encode(_sPOLAmount);
    }

    function decodeL1MigrationResponseMessage(bytes memory message) internal pure returns (uint256 _sPOLAmount) {
        (_sPOLAmount) = abi.decode(message, (uint256));
    }

    function encodeL2BackfillRequestMessage(uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_polAmount, _sPOLAmount, _backFillCycle);
    }

    function decodeL2BackfillRequestMessage(bytes memory message)
        internal
        pure
        returns (uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle)
    {
        (_polAmount, _sPOLAmount, _backFillCycle) = abi.decode(message, (uint256, uint256, uint256));
    }

    function encodeL1BackfillResponseMessage(uint256 _polAmount, uint256 _backFillCycle)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_polAmount, _backFillCycle);
    }

    function decodeL1BackfillResponseMessage(bytes memory message)
        internal
        pure
        returns (uint256 _polAmount, uint256 _backFillCycle)
    {
        (_polAmount, _backFillCycle) = abi.decode(message, (uint256, uint256));
    }
}
