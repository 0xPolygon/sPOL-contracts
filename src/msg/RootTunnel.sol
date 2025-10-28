// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import {BaseRootTunnel} from "./BaseRootTunnel.sol";

contract RootTunnel is BaseRootTunnel {
    constructor(address _admin) BaseRootTunnel(_admin) {}
    function _processMessageFromChild(bytes memory message) internal override {
        // you can implement custom message processing logic here
    }
}
