// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sPOL.sol";
import "../../src/sPOLController.sol";
import "../../script/Deploy.s.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract sPOLTest is Test, Deploy {
    sPOL public token; // This will be the proxy
    sPOLController public controller; // This will be the proxy

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public spender = makeAddr("spender");
    address public maliciousUser = makeAddr("maliciousUser");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployWithMockConfig(address(this));

        // Get deployed contracts from deployer
        token = sPOL(address(sPOLProxy));
        controller = sPOLController(address(sPOLControllerProxy));
    }

    // Constructor Tests
    function test_constructor_setsController() public view {
        assertEq(token.sPOLController(), address(controller));
    }

    function test_constructor_disablesInitializers() public {
        // Deploy a new implementation to test constructor behavior
        sPOL newImpl = new sPOL(address(controller));
        vm.expectRevert();
        newImpl.initialize();
    }

    // Initialize Tests
    function test_initialize_setsNameAndSymbol() public view {
        assertEq(token.name(), "Staked POL");
        assertEq(token.symbol(), "sPOL");
        assertEq(token.decimals(), 18);
    }

    function test_initialize_onlyOnce() public {
        // Should revert if trying to initialize again
        vm.expectRevert();
        token.initialize();
    }

    function test_initialize_initialState() public view {
        // Verify initial state after initialization
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(user1, user2), 0);
    }

    // Modifier Tests
    function test_onlyController_allowsController() public {
        vm.prank(address(controller));
        token.mint(user1, 100 ether);
        assertEq(token.balanceOf(user1), 100 ether);
    }

    function test_onlyController_revertsForNonController() public {
        vm.expectRevert("Only sPOL controller can call this function");
        vm.prank(user1);
        token.mint(user1, 100 ether);
    }

    function test_onlyController_revertsForZeroAddress() public {
        vm.expectRevert("Only sPOL controller can call this function");
        vm.prank(address(0));
        token.mint(user1, 100 ether);
    }

    // Mint Tests
    function test_mint_increasesBalance() public {
        uint256 amount = 100 ether;
        uint256 initialSupply = token.totalSupply();

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(0), user1, amount);

        vm.prank(address(controller));
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), initialSupply + amount);
    }

    function test_mint_multipleTimes() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 50 ether;

        vm.startPrank(address(controller));
        token.mint(user1, amount1);
        token.mint(user1, amount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount1 + amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function test_mint_multipleUsers() public {
        uint256 amount = 100 ether;

        vm.startPrank(address(controller));
        token.mint(user1, amount);
        token.mint(user2, amount);
        token.mint(user3, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.balanceOf(user3), amount);
        assertEq(token.totalSupply(), amount * 3);
    }

    // Burn Tests
    function test_burn_onlyController() public {
        vm.prank(address(controller));
        token.mint(user1, 100 ether);

        vm.expectRevert("Only sPOL controller can call this function");
        vm.prank(user1);
        token.burn(user1, 50 ether);
    }

    function test_burn_decreasesBalance() public {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 30 ether;

        // First mint tokens
        vm.prank(address(controller));
        token.mint(user1, mintAmount);

        uint256 initialSupply = token.totalSupply();

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(user1, address(0), burnAmount);

        vm.prank(address(controller));
        token.burn(user1, burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), initialSupply - burnAmount);
    }

    function test_burn_revertsInsufficientBalance() public {
        vm.prank(address(controller));
        token.mint(user1, 50 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 50 ether, 100 ether)
        );
        vm.prank(address(controller));
        token.burn(user1, 100 ether);
    }

    function test_burn_multipleUsers() public {
        uint256 amount = 100 ether;

        vm.startPrank(address(controller));
        token.mint(user1, amount);
        token.mint(user2, amount);
        token.mint(user3, amount);

        token.burn(user1, amount / 2);
        token.burn(user2, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount / 2);
        assertEq(token.balanceOf(user2), 0);
        assertEq(token.balanceOf(user3), amount);
        assertEq(token.totalSupply(), amount + amount / 2);
    }

    // ConsumePermit Tests
    function test_consumePermit_onlyController() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (address userAddr, uint256 userKey) = makeAddrAndKey("permitUser");

        (uint8 v, bytes32 r, bytes32 s) = createPermit(userAddr, spender, amount, deadline, userKey);

        vm.expectRevert("Only sPOL controller can call this function");
        vm.prank(userAddr);
        token.consumePermit(userAddr, spender, amount, deadline, v, r, s);
    }

    function test_consumePermit_expiredDeadline() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp - 1; // Expired deadline
        (address userAddr, uint256 userKey) = makeAddrAndKey("permitUser");

        (uint8 v, bytes32 r, bytes32 s) = createPermit(userAddr, spender, amount, deadline, userKey);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        vm.prank(address(controller));
        token.consumePermit(userAddr, spender, amount, deadline, v, r, s);
    }

    // Integration tests
    function test_deployment_validation() public view {
        // Test that deployment was successful and contracts are properly linked
        assertTrue(address(token) != address(0));
        assertTrue(address(controller) != address(0));
        assertEq(token.sPOLController(), address(controller));
        assertEq(address(controller.sPOLToken()), address(token));
        // Verify initial token state
        assertEq(token.totalSupply(), 0);
        assertEq(token.name(), "Staked POL");
        assertEq(token.symbol(), "sPOL");
        assertEq(token.decimals(), 18);
    }

    // Fuzz tests
    function testFuzz_mint(address to, uint256 amount) public {
        vm.assume(to != address(0));

        uint256 initialSupply = token.totalSupply();

        vm.prank(address(controller));
        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), initialSupply + amount);
    }

    function testFuzz_burn(uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(burnAmount <= mintAmount);

        vm.prank(address(controller));
        token.mint(user1, mintAmount);
        uint256 initialSupply = token.totalSupply();

        if (burnAmount <= mintAmount) {
            vm.prank(address(controller));
            token.burn(user1, burnAmount);
            assertEq(token.balanceOf(user1), mintAmount - burnAmount);
            assertEq(token.totalSupply(), initialSupply - burnAmount);
        } else {
            vm.expectRevert(IERC20Errors.ERC20InsufficientBalance.selector);
            vm.prank(address(controller));
            token.burn(user1, burnAmount);
        }
    }

    // Helper
    function createPermit(address _from, address _spender, uint256 _value, uint256 _deadline, uint256 _pk)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 dataToSign = keccak256(
            abi.encodePacked(
                hex"1901",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        // keccak256(
                        //     "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                        // ),
                        hex"6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9",
                        _from,
                        _spender,
                        _value,
                        token.nonces(_from),
                        _deadline
                    )
                )
            )
        );
        return vm.sign(_pk, dataToSign);
    }
}
