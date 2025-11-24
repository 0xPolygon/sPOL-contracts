// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "../../src/sPOLMessenger.sol";

contract MocksPOLMessenger is sPOLMessenger {
    constructor(
        address _polToken,
        address _sPOLToken,
        address _sPOLController,
        address _rootChainManager,
        address _depositManager,
        address _stateSender,
        address _checkpointManager,
        address _childTunnel,
        address _polBridger
    )
        sPOLMessenger(
            _polToken,
            _sPOLToken,
            _sPOLController,
            _rootChainManager,
            _depositManager,
            _stateSender,
            _checkpointManager,
            _childTunnel,
            _polBridger
        )
    {}

    function expose_processMessageFromChild(bytes memory _message) external {
        _processMessageFromChild(_message);
    }
}
