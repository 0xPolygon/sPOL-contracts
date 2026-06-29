// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {sPOLMessenger} from "../../src/sPOLMessenger.sol";
import {ExitPayloadReader} from "../../src/msg/lib/ExitPayloadReader.sol";

contract ProductionMigrationForkTest is Test {
    using ExitPayloadReader for bytes;
    using ExitPayloadReader for ExitPayloadReader.ExitPayload;

    bytes32 internal constant ERC1967_IMPL_SLOT = hex"360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    bytes32 internal constant MIGRATION_PROCESSED_TOPIC = keccak256("MigrationProcessed(uint256,uint256)");

    // Burn tx: 0xc637d1bc7cb02ea9bf55f2bfaef75170794f4616f99b28659ddab915db0eb69f.
    // Fixture source:
    // https://proof-generator.polygon.technology/api/v1/matic/exit-payload/<burn-tx>
    //   ?eventSignature=0x8c5261668696ce22758910d05bab8f186d6eb247ceac2af2e82c7dc17669b036
    // The L1 fork block is after the CM #220 implementation deploy and before the proxy upgrade.
    uint256 internal constant MAINNET_FORK_BLOCK = 25_423_200;
    uint256 internal constant L2_BURN_BLOCK = 88_806_784;
    uint256 internal constant EXIT_PAYLOAD_SIZE = 33_500;
    uint256 internal constant RECEIPT_SIZE = 16_065;
    uint256 internal constant RECEIPT_LOG_INDEX = 19;
    uint256 internal constant EXPECTED_POL_AMOUNT = 3_793_714_212_734_160_224_349;
    uint256 internal constant EXPECTED_MINTED_SPOL = 3_755_917_267_510_164_012_019;

    address internal constant POL_TOKEN = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address internal constant SPOL_MESSENGER_PROXY = 0x0356e303B375D5a11D9Eb7d57DBF544FeE6972C9;
    address internal constant OLD_MESSENGER_IMPL = 0xA724b410D711D7BE51f466220e065C6Ee303Ff86;
    address internal constant CM_220_MESSENGER_IMPL = 0x36B2886CF233b72cbc3d12299e82a44696eA604a;
    address internal constant SPOL_MESSENGER_PROXY_ADMIN = 0x4338BA90a41D415936CB2e34345FC821E393550B;
    address internal constant ACCESS_MANAGER_L1 = 0x2c91c02793a50f6D55168a88183da687F572d350;
    address internal constant ACCESS_MANAGER_ADMIN = 0x619D553686958A873A62B336b2DD97C3b25134EA;
    address internal constant POL_BRIDGER_PROXY = 0x67a40D016EFE809a5BFcd942a8FAf2D9cF0758E2;
    address internal constant DEPOSIT_MANAGER = 0x401F6c983eA34274ec46f84D70b31C151321188b;

    IERC20 internal constant polToken = IERC20(POL_TOKEN);
    sPOLMessenger internal constant messenger = sPOLMessenger(SPOL_MESSENGER_PROXY);

    function setUp() public {
        vm.createSelectFork(vm.envString("L1_RPC_URL"), MAINNET_FORK_BLOCK);
    }

    function test_stuckProductionMigration_recoversAfterCM220Upgrade() public {
        bytes memory exitPayload = _loadExitPayload();

        assertEq(_implementation(), OLD_MESSENGER_IMPL, "setup: proxy should still use old impl");
        assertGt(CM_220_MESSENGER_IMPL.code.length, 0, "setup: CM #220 impl must be deployed");
        assertEq(polToken.balanceOf(POL_BRIDGER_PROXY), EXPECTED_POL_AMOUNT, "setup: stuck POL balance");
        assertEq(
            polToken.allowance(SPOL_MESSENGER_PROXY, DEPOSIT_MANAGER),
            type(uint256).max,
            "setup: legacy DepositManager approval should still exist"
        );

        vm.expectRevert(stdError.arithmeticError);
        messenger.receiveMessage(exitPayload);

        _applyCM220Upgrade();

        assertEq(_implementation(), CM_220_MESSENGER_IMPL, "upgrade: proxy impl");
        assertEq(polToken.allowance(SPOL_MESSENGER_PROXY, DEPOSIT_MANAGER), 0, "upgrade: approval revoked");

        vm.recordLogs();
        messenger.receiveMessage(exitPayload);
        _assertMigrationProcessed(vm.getRecordedLogs());

        assertEq(polToken.balanceOf(POL_BRIDGER_PROXY), 0, "post-fix: polBridger should be drained");
    }

    function _loadExitPayload() internal view returns (bytes memory exitPayload) {
        exitPayload = vm.parseBytes(vm.readFile("test/fixtures/copybug_real_exit_payload.hex"));
        assertEq(exitPayload.length, EXIT_PAYLOAD_SIZE, "fixture: exit payload size");

        ExitPayloadReader.ExitPayload memory decoded = exitPayload.toExitPayload();
        assertEq(decoded.getBlockNumber(), L2_BURN_BLOCK, "fixture: L2 block");
        assertEq(decoded.getReceiptLogIndex(), RECEIPT_LOG_INDEX, "fixture: receipt log index");

        ExitPayloadReader.Receipt memory receipt = decoded.getReceipt();
        assertEq(receipt.raw.length, RECEIPT_SIZE, "fixture: receipt size");
        assertEq(uint8(receipt.raw[0]), 0x7f, "fixture: Bor typed receipt");
    }

    function _applyCM220Upgrade() internal {
        bytes memory upgradeAndCallData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(SPOL_MESSENGER_PROXY),
                CM_220_MESSENGER_IMPL,
                abi.encodeCall(sPOLMessenger.reinitializeV3, ())
            )
        );

        vm.prank(ACCESS_MANAGER_ADMIN);
        AccessManager(ACCESS_MANAGER_L1).execute(SPOL_MESSENGER_PROXY_ADMIN, upgradeAndCallData);
    }

    function _assertMigrationProcessed(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MIGRATION_PROCESSED_TOPIC && logs[i].emitter == SPOL_MESSENGER_PROXY) {
                (uint256 polAmount, uint256 mintedSPOL) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(polAmount, EXPECTED_POL_AMOUNT, "event: POL amount");
                assertEq(mintedSPOL, EXPECTED_MINTED_SPOL, "event: minted sPOL");
                return;
            }
        }

        fail("MigrationProcessed not emitted");
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(SPOL_MESSENGER_PROXY, ERC1967_IMPL_SLOT))));
    }
}
