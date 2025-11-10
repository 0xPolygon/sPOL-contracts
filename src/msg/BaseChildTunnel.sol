// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

/**
 * @notice Abstract child tunnel contract to receive and send message from L2
 */
abstract contract BaseChildTunnel {
    // MessageTunnel on L1 will get data from this event
    event MessageSent(bytes message);

    address public immutable stateSyncer;

    modifier onlyStateSyncer() {
        require(msg.sender == stateSyncer, "ChildTunnel: ONLY_STATE_SYNCER_ALLOWED");
        _;
    }

    constructor(address _stateSyncer) {
        stateSyncer = _stateSyncer;
    }

    /**
     * @notice Receive state sync from polygon contracts
     * @dev This method will be called by polygon chain internally.
     * This is executed without transaction using a system call.
     */
    function onStateReceive(uint256, bytes calldata message) external onlyStateSyncer {
        _processMessageFromRoot(message);
    }

    /**
     * @notice Emit message that can be received on Root Tunnel
     * @dev Call the internal function when need to emit message
     * @param message bytes message that will be sent to Root Tunnel
     * some message examples -
     *   abi.encode(tokenId);
     *   abi.encode(tokenId, tokenMetadata);
     *   abi.encode(messageType, messageData);
     */
    function _sendMessageToRoot(bytes memory message) internal {
        emit MessageSent(message);
    }

    /**
     * @notice Process message received from Root Tunnel
     * @dev function needs to be implemented to handle message as per requirement
     * This is called by onStateReceive function.
     * Since it is called via a system call, any event will not be emitted during its execution.
     * @param message bytes message that was sent from Root Tunnel
     */
    function _processMessageFromRoot(bytes memory message) internal virtual;
}
