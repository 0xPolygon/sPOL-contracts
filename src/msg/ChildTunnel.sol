// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {BaseChildTunnel} from "./BaseChildTunnel.sol";

contract ChildTunnel is BaseChildTunnel {
    constructor(address _stateSyncer) BaseChildTunnel(_stateSyncer) {}
    function _processMessageFromRoot(bytes memory message) internal override {
        // you can implement custom message processing logic here
    }
}
