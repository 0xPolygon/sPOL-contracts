// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface ERC20PredicateBurnOnly {
    function startExitWithBurntTokens(bytes memory data) external;
}
