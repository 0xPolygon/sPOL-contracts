// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {sPOLController as IsPOLController} from "./sPOLController.sol";
import {IRootChainManager} from "./msg/interfaces/IRootChainManager.sol";
import {BaseRootTunnel} from "./msg/BaseRootTunnel.sol";
import {MsgCoder} from "./MsgCoder.sol";

contract sPOLMessenger is BaseRootTunnel, MsgCoder {
    IERC20 public immutable polToken;
    IERC20 public immutable sPOLToken;
    address public child;

    IRootChainManager public immutable rootChainManager;
    IsPOLController public immutable sPOLController;

    constructor(address _polToken, address _sPOLToken, address _sPOLController, address _rootChainManager)
        BaseRootTunnel(msg.sender)
    {
        polToken = IERC20(_polToken);
        sPOLToken = IERC20(_sPOLToken);
        sPOLController = IsPOLController(_sPOLController);
        rootChainManager = IRootChainManager(_rootChainManager);
    }

    function _processMessageFromChild(bytes memory _message) internal override {
        (MsgType msgType, bytes memory actualMessage) = abi.decode(_message, (MsgType, bytes));
        if (msgType == MsgType.L2_MIGRATION_REQUEST) {
            handleMigration(actualMessage);
        } else if (msgType == MsgType.L2_BACKFILL_REQUEST) {
            handleBackfill(actualMessage);
        } else {
            revert("Invalid message type");
        }

        // stake the POL using custom exchange logic?
        // basically pass the POL and the SPOL and if sPOL minted is lower than expected just mint the low amount
        // Then take the sPOL and send it to the L2, with a message that the amount can be burned
        // _sendMessageToChild(abi.encode(mintedSPOL));
    }

    function handleMigration(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _mintedSPOL) = decodeL2MigrationRequestMessage(_msg);
        sPOLController.completeMigration(_polAmount, _mintedSPOL);
        rootChainManager.depositFor(child, address(sPOLToken), abi.encodePacked(_mintedSPOL));
        // maybe make it so that if the target of the deposit is the child it doesn't need a msg and just burns directly
        _sendMessageToChild(abi.encode(_mintedSPOL));
    }

    function handleBackfill(bytes memory _msg) internal {
        (uint256 _polAmount, uint256 _sPOLAmount, uint256 _backFillCycle) = decodeL2BackfillRequestMessage(_msg);
    }

    function updateL2ExchangeRate() external {
        _sendMessageToChild(
            abi.encode(
                MsgType.EXCHANGE_UPDATE,
                encodeExchangeUpdateMessage(
                    sPOLController.totalsPOLBalance(),
                    (sPOLController.totaldPOLBalance() - sPOLController.feedPOLBalance())
                )
            )
        );
    }
}
