// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sPOLController.sol";
import "../../src/sPOL.sol";
import "../../script/Deploy.s.sol";

contract sPOLControllerConversionTest is Test, Deploy {
    sPOLController controller;
    sPOL token;

    // Test addresses
    address testAdmin = makeAddr("testAdmin");
    address testFeeReceiver = makeAddr("testFeeReceiver");

    function setUp() public {
        // Deploy with minimal config just for conversion tests
        setCustomConfig(
            makeAddr("polToken"),
            makeAddr("maticToken"),
            makeAddr("polygonMigration"),
            makeAddr("stakeManager"),
            testAdmin,
            testFeeReceiver,
            100, // 10% fee
            10 // 10% max divergence
        );
        _deploy(address(this));

        controller = sPOLController(address(sPOLControllerProxy));
        token = sPOL(address(sPOLProxy));
    }

    ////////////////////////////////////////
    ///  Conversion Function Tests       ///
    ////////////////////////////////////////

    function test_ConvertPOLtoSPOL_InitialState() public {
        // When totalSupply is 0, should return 1:1 conversion
        uint256 polAmount = 100 ether;
        _setsPOLTotalSupply(0);

        uint256 result = controller.convertPOLtoSPOL(polAmount);
        assertEq(result, polAmount, "Should return 1:1 when no sPOL exists");
    }

    function test_ConvertPOLtoSPOL_EqualRate() public {
        uint256 polAmount = 100 ether;
        uint256 dpolAmount = 1000 ether;
        uint256 spolAmount = 1000 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(0);

        uint256 result = controller.convertPOLtoSPOL(polAmount);
        uint256 expected = polAmount * spolAmount / dpolAmount; // 100 * 1000 / 1000 = 100
        assertEq(result, expected, "Should convert 1:1 when backing equals supply");
        assertEq(result, polAmount, "Should equal input amount");
    }

    function test_ConvertPOLtoSPOL_HigherBacking() public {
        uint256 polAmount = 100 ether;
        uint256 dpolAmount = 2000 ether;
        uint256 spolAmount = 1000 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(0);

        uint256 result = controller.convertPOLtoSPOL(polAmount);
        uint256 expected = polAmount * spolAmount / dpolAmount; // 100 * 1000 / 2000 = 50
        assertEq(result, expected, "Should get less sPOL when backing is higher");
        assertEq(result, 50 ether, "Should get exactly 50 sPOL for 100 POL");
    }

    function test_ConvertPOLtoSPOL_WithFees() public {
        uint256 polAmount = 100 ether;
        uint256 dpolAmount = 1000 ether;
        uint256 spolAmount = 1000 ether;
        uint256 feeAmount = 100 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(feeAmount);

        uint256 result = controller.convertPOLtoSPOL(polAmount);
        uint256 effectiveBacking = dpolAmount - feeAmount; // 900 ether
        uint256 expected = polAmount * spolAmount / effectiveBacking; // 100 * 1000 / 900 = 111.111...
        assertEq(result, expected, "Should account for fees in conversion");
    }

    function test_ConvertSPOLtoPOL_InitialState() public {
        uint256 sPOLAmount = 100 ether;

        _setsPOLTotalSupply(0);

        uint256 result = controller.convertSPOLtoPOL(sPOLAmount);
        assertEq(result, sPOLAmount, "Should return 1:1 when no sPOL exists");
    }

    function test_ConvertSPOLtoPOL_EqualRate() public {
        uint256 sPOLAmount = 100 ether;
        uint256 dpolAmount = 1000 ether;
        uint256 spolAmount = 1000 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(0);

        uint256 result = controller.convertSPOLtoPOL(sPOLAmount);
        uint256 expected = sPOLAmount * dpolAmount / spolAmount; // 100 * 1000 / 1000 = 100
        assertEq(result, expected, "Should convert 1:1 when backing equals supply");
        assertEq(result, sPOLAmount, "Should equal input amount");
    }

    // this should never happen
    function test_ConvertSPOLtoPOL_HigherBacking() public {
        uint256 sPOLAmount = 100 ether;
        uint256 dpolAmount = 2000 ether;
        uint256 spolAmount = 1000 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(0);

        uint256 result = controller.convertSPOLtoPOL(sPOLAmount);
        uint256 expected = sPOLAmount * dpolAmount / spolAmount; // 100 * 2000 / 1000 = 200
        assertEq(result, expected, "Should get more POL when backing is higher");
        assertEq(result, 200 ether, "Should get exactly 200 POL for 100 sPOL");
    }

    function test_ConvertSPOLtoPOL_WithFees() public {
        uint256 sPOLAmount = 100 ether;
        uint256 dpolAmount = 1000 ether;
        uint256 spolAmount = 1000 ether;
        uint256 feeAmount = 100 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(feeAmount);

        uint256 result = controller.convertSPOLtoPOL(sPOLAmount);
        uint256 effectiveBacking = dpolAmount - feeAmount; // 900 ether
        uint256 expected = sPOLAmount * effectiveBacking / spolAmount; // 100 * 900 / 1000 = 90
        assertEq(result, expected, "Should account for fees in conversion");
        assertEq(result, 90 ether, "Should get 90 POL after fees");
    }

    ////////////////////////////////////////
    ///  Round Trip Tests                ///
    ////////////////////////////////////////

    function test_ConversionRoundTrip_EqualRate() public {
        uint256 originalPOL = 100 ether;
        uint256 dpolAmount = 1000 ether;
        uint256 spolAmount = 1000 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(0);

        uint256 sPOLAmount = controller.convertPOLtoSPOL(originalPOL);

        uint256 finalPOL = controller.convertSPOLtoPOL(sPOLAmount);

        assertEq(sPOLAmount, originalPOL);
        assertEq(finalPOL, originalPOL, "Round trip should preserve amount at 1:1 rate");
    }

    function test_ConversionRoundTrip_WithRewards() public {
        uint256 originalPOL = 100 ether;
        uint256 dpolAmount = 2000 ether;
        uint256 spolAmount = 1000 ether;

        _setTotaldPOLBalance(dpolAmount);
        _setsPOLTotalSupply(spolAmount);
        _setFeedPOLBalance(0);

        uint256 sPOLAmount = controller.convertPOLtoSPOL(originalPOL);
        assertEq(sPOLAmount, 50 ether, "Should get 50 sPOL for 100 POL at 2:1 rate");

        uint256 finalPOL = controller.convertSPOLtoPOL(sPOLAmount);
        assertEq(finalPOL, originalPOL, "Should get back original POL amount");
    }

    ////////////////////////////////////////
    ///  Edge Cases and Error Tests      ///
    ////////////////////////////////////////

    function test_ConversionFunctions_TinyAmounts_equal() public {
        _setTotaldPOLBalance(1000 ether);
        _setsPOLTotalSupply(1000 ether);

        uint256 zeroPOLResult = controller.convertPOLtoSPOL(1);
        uint256 zeroSPOLResult = controller.convertSPOLtoPOL(1);

        assertEq(zeroPOLResult, 1, "one POL should convert to one sPOL");
        assertEq(zeroSPOLResult, 1, "one sPOL should convert to one POL");
    }

    function test_ConversionFunctions_TinyAmounts_tinyNonEqual() public {
        _setTotaldPOLBalance(1000 ether + 1);
        _setsPOLTotalSupply(1000 ether);

        uint256 zeroPOLResult = controller.convertPOLtoSPOL(1);
        uint256 zeroSPOLResult = controller.convertSPOLtoPOL(1);

        assertEq(zeroPOLResult, 0, "one POL should convert to zero sPOL");
        assertEq(zeroSPOLResult, 1, "one sPOL should convert to one POL");
    }

    function test_ConversionFunctions_ZeroAmounts() public {
        _setTotaldPOLBalance(1000 ether);
        _setsPOLTotalSupply(1000 ether);

        uint256 zeroPOLResult = controller.convertPOLtoSPOL(0);
        uint256 zeroSPOLResult = controller.convertSPOLtoPOL(0);

        assertEq(zeroPOLResult, 0, "Zero POL should convert to zero sPOL");
        assertEq(zeroSPOLResult, 0, "Zero sPOL should convert to zero POL");
    }

    function test_ConversionFunctions_LargeAmounts_equal() public {
        _setTotaldPOLBalance(1000 ether);
        _setsPOLTotalSupply(1000 ether);

        uint256 largePOL = 1e6 ether; // 1 million pol
        uint256 largeSPOL = 1e6 ether;

        uint256 resultSPOL = controller.convertPOLtoSPOL(largePOL);
        uint256 resultPOL = controller.convertSPOLtoPOL(largeSPOL);

        assertEq(resultSPOL, largePOL, "Large POL conversion should work");
        assertEq(resultPOL, largeSPOL, "Large sPOL conversion should work");
    }

    function test_ConversionFunctions_LargeAmounts_nonEqual() public {
        _setTotaldPOLBalance(2000 ether);
        _setsPOLTotalSupply(1000 ether);

        uint256 largePOL = 1e6 ether; // 1 million pol
        uint256 largeSPOL = 1e6 ether;

        uint256 resultSPOL = controller.convertPOLtoSPOL(largePOL);
        uint256 resultPOL = controller.convertSPOLtoPOL(largeSPOL);

        assertEq(resultSPOL, largePOL / 2, "Large POL conversion should work");
        assertEq(resultPOL / 2, largeSPOL, "Large sPOL conversion should work");
    }

    function test_ConversionConsistency_MultipleRates() public {
        uint256 testAmount = 100 ether;

        uint256[] memory backings = new uint256[](3);
        backings[0] = 1000 ether; // 1:1 rate
        backings[1] = 2000 ether; // 2:1 rate
        backings[2] = 500 ether; // 0.5:1 rate

        uint256 supply = 1000 ether;

        for (uint256 i = 0; i < backings.length; i++) {
            _setTotaldPOLBalance(backings[i]);
            _setsPOLTotalSupply(supply);
            _setFeedPOLBalance(0);

            uint256 sPOLAmount = controller.convertPOLtoSPOL(testAmount);
            uint256 polAmountBack = controller.convertSPOLtoPOL(sPOLAmount);

            assertEq(polAmountBack, testAmount, "Round trip conversion should be consistent");
        }
    }

    ////////////////////////////////////////
    ///  Formula Verification Tests      ///
    ////////////////////////////////////////

    function test_ExpectedCorrectFormula_POLtoSPOL() public pure {
        uint256 polAmount = 100 ether;
        uint256 totaldPOLBalance = 1000 ether;
        uint256 feedPOLBalance = 100 ether;
        uint256 totalSupply = 800 ether;

        // Correct formula should be:
        // sPOL_amount = POL_amount * totalSupply / (totaldPOLBalance - feedPOLBalance)
        uint256 expectedSPOL = polAmount * totalSupply / (totaldPOLBalance - feedPOLBalance);

        // With values: 100 * 800 / (1000 - 100) = 100 * 800 / 900 = 88.888... ether
        assertEq(expectedSPOL, 88888888888888888888, "Correct conversion formula");
    }

    function test_ExpectedCorrectFormula_SPOLtoPOL() public pure {
        uint256 sPOLAmount = 100 ether;
        uint256 totaldPOLBalance = 1000 ether;
        uint256 feedPOLBalance = 100 ether;
        uint256 totalSupply = 800 ether;

        // Correct formula should be:
        // POL_amount = sPOL_amount * (totaldPOLBalance - feedPOLBalance) / totalSupply
        uint256 expectedPOL = sPOLAmount * (totaldPOLBalance - feedPOLBalance) / totalSupply;

        // With values: 100 * (1000 - 100) / 800 = 100 * 900 / 800 = 112.5 ether
        assertEq(expectedPOL, 112500000000000000000, "Correct conversion formula");
    }

    function test_ActualImplementation_MatchesExpected() public {
        // Test that the fixed implementation matches our expected formulas
        uint256 polAmount = 100 ether;
        uint256 sPOLAmount = 100 ether;
        uint256 totaldPOLBalance = 1000 ether;
        uint256 feedPOLBalance = 100 ether;
        uint256 totalSupply = 800 ether;

        _setTotaldPOLBalance(totaldPOLBalance);
        _setsPOLTotalSupply(totalSupply);
        _setFeedPOLBalance(feedPOLBalance);

        // Test POL to sPOL
        uint256 actualSPOL = controller.convertPOLtoSPOL(polAmount);
        uint256 expectedSPOL = polAmount * totalSupply / (totaldPOLBalance - feedPOLBalance);
        assertEq(actualSPOL, expectedSPOL, "Actual POL to sPOL should match expected formula");

        // Test sPOL to POL
        uint256 actualPOL = controller.convertSPOLtoPOL(sPOLAmount);
        uint256 expectedPOL = sPOLAmount * (totaldPOLBalance - feedPOLBalance) / totalSupply;
        assertEq(actualPOL, expectedPOL, "Actual sPOL to POL should match expected formula");
    }

    ////////////////////////////////////////
    ///  Helper Functions                ///
    ////////////////////////////////////////

    function _setTotaldPOLBalance(uint256 amount) internal {
        // Set totaldPOLBalance storage slot 5
        vm.store(address(controller), bytes32(uint256(5)), bytes32(amount));
    }

    function _setsPOLTotalSupply(uint256 amount) internal {
        // Mock sPOL token total supply
        vm.mockCall(address(token), abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))), abi.encode(amount));
    }

    function _setFeedPOLBalance(uint256 amount) internal {
        // Set feedPOLBalance storage slot 7
        vm.store(address(controller), bytes32(uint256(7)), bytes32(amount));
    }
}
