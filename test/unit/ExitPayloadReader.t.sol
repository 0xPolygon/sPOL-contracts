// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ExitPayloadReader} from "../../src/msg/lib/ExitPayloadReader.sol";

/// @dev Thin harness exposing the internal `getReceipt` path, which is the only
///      reachable caller of the private buggy `copy()` (typed-receipt branch).
contract ExitPayloadReaderHarness {
    using ExitPayloadReader for bytes;
    using ExitPayloadReader for ExitPayloadReader.ExitPayload;

    function getReceiptRawLength(bytes memory inputData) external pure returns (uint256) {
        ExitPayloadReader.ExitPayload memory payload = inputData.toExitPayload();
        ExitPayloadReader.Receipt memory receipt = payload.getReceipt();
        return receipt.raw.length;
    }
}

/// @title ExitPayloadReader.copy() 32-byte-alignment overflow
/// @notice Regression test for the missing `if (len > 0)` guard in
///         `ExitPayloadReader.copy()` (`src/msg/lib/ExitPayloadReader.sol:46`).
///
///         `getReceipt()` (typed-receipt branch) calls `copy(src, dest, len)` with
///         `len = receipt.raw.length - 1`. When `receipt.raw.length % 32 == 1`,
///         that `len` is a non-zero multiple of 32, so the word loop drains it to 0
///         and the unguarded tail computes `256 ** (32 - 0) - 1` = `256 ** 32`,
///         which overflows uint256 under 0.8 checked arithmetic and reverts (Panic 0x11).
///
///         Both tests should pass once the guard is added; the aligned case reverts
///         (test goes RED) without it. The sibling `RLPReader.copy()` already has the guard.
contract ExitPayloadReaderCopyTest is Test {
    ExitPayloadReaderHarness internal harness;

    function setUp() public {
        harness = new ExitPayloadReaderHarness();
    }

    /// @dev RLP list `0xf8 <payloadLen> <payloadLen zero bytes>`. The zero bytes each
    ///      decode as a single-byte RLP item, so the list parses cleanly. The long-list
    ///      header (0xf8) is used uniformly; RLPReader does not enforce minimal encoding.
    function _rlpListWithPayload(uint8 payloadLen) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0xf8), payloadLen, new bytes(payloadLen));
    }

    /// @dev Typed receipt: a leading type byte (0x02, EIP-1559) makes `isList()` false,
    ///      so `getReceipt` takes the typed branch that calls the buggy `copy`.
    ///      Total length = 1 (type) + 2 (list header) + listPayloadLen.
    function _typedReceipt(uint8 listPayloadLen) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x02), _rlpListWithPayload(listPayloadLen));
    }

    /// @dev Minimal 10-item exit payload. Only item[6] (receipt) and item[9] (log index)
    ///      are read by `getReceipt`; the rest are empty-string placeholders (0x80).
    function _buildExitPayload(bytes memory rawReceipt) internal pure returns (bytes memory) {
        require(rawReceipt.length < 56, "raw too long for short-string helper");
        bytes memory el6 = abi.encodePacked(uint8(0x80 + rawReceipt.length), rawReceipt);

        bytes memory inner = abi.encodePacked(
            uint8(0x80), uint8(0x80), uint8(0x80), uint8(0x80), uint8(0x80), uint8(0x80), // items 0..5
            el6, //                                                                          item 6 (receipt)
            uint8(0x80), uint8(0x80), //                                                     items 7..8
            uint8(0x80) //                                                                   item 9 (log index = 0)
        );
        require(inner.length < 56, "inner too long for short-list helper");
        return abi.encodePacked(uint8(0xc0 + inner.length), inner);
    }

    /// @notice RED before the fix: a typed receipt whose raw length is 32-aligned-plus-one
    ///         (33 = 1 mod 32) reverts in `copy()` with arithmetic overflow.
    function test_getReceipt_thirtyTwoByteAlignedReceipt_doesNotRevert() public view {
        // listPayloadLen 30 -> receipt.raw.length = 33 -> copy() len = 32 (multiple of WORD_SIZE).
        bytes memory rawReceipt = _typedReceipt(30);
        assertEq(rawReceipt.length, 33, "setup: expected raw length 33");
        assertEq(rawReceipt.length % 32, 1, "setup: this is the bricking residue");

        bytes memory inputData = _buildExitPayload(rawReceipt);

        uint256 rawLen = harness.getReceiptRawLength(inputData);
        assertEq(rawLen, 33, "32-byte-aligned typed receipt must parse without overflow");
    }

    /// @notice Control: a non-aligned typed receipt parses both before and after the fix,
    ///         proving the harness/payload construction is valid and only the 32-alignment
    ///         triggers the overflow.
    function test_getReceipt_nonAlignedReceipt_control() public view {
        // listPayloadLen 31 -> receipt.raw.length = 34 -> copy() len = 33 -> residual 1, no overflow.
        bytes memory rawReceipt = _typedReceipt(31);
        assertEq(rawReceipt.length, 34, "setup: expected raw length 34");
        assertEq(rawReceipt.length % 32, 2, "setup: safe residue");

        bytes memory inputData = _buildExitPayload(rawReceipt);

        uint256 rawLen = harness.getReceiptRawLength(inputData);
        assertEq(rawLen, 34);
    }
}
