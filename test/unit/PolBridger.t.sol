// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PolBridger} from "../../src/polBridger.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PolBridgerTest is Test, Deploy {
    PolBridger internal bridger;
    address internal recipient = makeAddr("rescueRecipient");

    function setUp() public {
        // L1-only mock deploy (full deploy would collide on single-chain CREATE2 since L1 and
        // L2 share the "Mock-" salt prefix).
        deployL1WithMockConfig(address(this));
        bridger = PolBridger(address(polBridgerProxy));
    }

    ///////////////////////////////
    ///  Rescue                 ///
    ///////////////////////////////

    function test_rescue_movesErc20ToRecipient() public {
        MockERC20 token = new MockERC20();
        token.mint(address(bridger), 500 ether);
        assertEq(token.balanceOf(address(bridger)), 500 ether);

        accessManagerL1.execute(
            address(bridger), abi.encodeCall(PolBridger.rescue, (address(token), recipient, 500 ether))
        );

        assertEq(token.balanceOf(address(bridger)), 0);
        assertEq(token.balanceOf(recipient), 500 ether);
    }

    function test_rescue_revertsFromUnauthorizedCaller() public {
        MockERC20 token = new MockERC20();
        token.mint(address(bridger), 100 ether);

        vm.prank(makeAddr("nobody"));
        vm.expectRevert();
        bridger.rescue(address(token), recipient, 100 ether);
    }

    function test_rescueNative_movesEthToRecipient() public {
        vm.deal(address(bridger), 3 ether);
        uint256 before_ = recipient.balance;

        accessManagerL1.execute(address(bridger), abi.encodeCall(PolBridger.rescueNative, (recipient, 3 ether)));

        assertEq(address(bridger).balance, 0);
        assertEq(recipient.balance - before_, 3 ether);
    }

    function test_rescueNative_revertsFromUnauthorizedCaller() public {
        vm.deal(address(bridger), 1 ether);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert();
        bridger.rescueNative(recipient, 1 ether);
    }

    ///////////////////////////////
    ///  Pause / Unpause        ///
    ///////////////////////////////

    function test_pause_blocksBridgePOLToL1() public {
        _pauseBridger();
        vm.chainId(chainIdL2);
        vm.deal(address(this), 1 ether);
        // bridgePOLToL1's whenNotPaused modifier runs before any body check, so it reverts
        // with Pausable's EnforcedPause regardless of caller / chain state.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bridger.bridgePOLToL1{value: 1 ether}(1 ether);
    }

    function test_pause_blocksExitPOL() public {
        _pauseBridger();
        vm.chainId(chainIdL1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bridger.exitPOL("");
    }

    function test_pause_blocksFinalizeExitPOL() public {
        _pauseBridger();
        vm.chainId(chainIdL1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bridger.finalizeExitPOL();
    }

    function test_pause_blocksTakePOLL1() public {
        _pauseBridger();
        vm.chainId(chainIdL1);
        // Even the authorised messenger can't pull POL while paused.
        vm.prank(bridger.sPOLMessengerL1());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bridger.takePOLL1(1 ether);
    }

    function test_unpause_restoresOperations() public {
        _pauseBridger();
        assertTrue(bridger.paused());

        accessManagerL1.execute(address(bridger), abi.encodeCall(PolBridger.unpause, ()));
        assertFalse(bridger.paused());

        // Post-unpause, the EnforcedPause short-circuit is gone. Verify by calling takePOLL1
        // from an unauthorised account: it now reaches the authorisation check and reverts
        // with AddressUnauthorized, not EnforcedPause.
        vm.chainId(chainIdL1);
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(PolBridger.AddressUnauthorized.selector, rando));
        bridger.takePOLL1(1 ether);
    }

    function test_pause_revertsFromUnauthorizedCaller() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert();
        bridger.pause();
    }

    function _pauseBridger() internal {
        accessManagerL1.execute(address(bridger), abi.encodeCall(PolBridger.pause, ()));
        assertTrue(bridger.paused());
    }
}
