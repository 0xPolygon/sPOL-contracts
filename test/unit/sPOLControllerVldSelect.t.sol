// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sPOLController.sol";

contract sPOLControllerVLDSelectTest is Test, sPOLController {
    address testAdmin = makeAddr("testAdmin");
    address testFeeReceiver = makeAddr("testFeeReceiver");
    address testPolToken = makeAddr("testPolToken");
    address testMaticToken = makeAddr("testMaticToken");
    address testPolygonMigration = makeAddr("testPolygonMigration");
    address testStakeManager = makeAddr("testStakeManager");
    address testSPOLToken = makeAddr("testSPOLToken");
    address testValidatorShare = makeAddr("testValidatorShare");
    uint8 testMaxDivergence = 20;
    uint8 testRewardFeee = 10;

    constructor() sPOLController(testPolToken, testMaticToken, testPolygonMigration, testSPOLToken, testStakeManager) {}

    function setUp() public {
        // initialize sPOLController
        // can't use .initialize as we aren't the proxy
        rewardFee = testRewardFeee;
        feeReceiver = testFeeReceiver;
        maxDivergence = testMaxDivergence;
        admin = testAdmin;
        // Mocks
        // We don't test adding, so all validators are valid
        vm.mockCall(testStakeManager, abi.encodeWithSelector(IStakeManager.isValidator.selector), abi.encode(true));
        // We don't use VS info, so just return an address
        vm.mockCall(
            testStakeManager,
            abi.encodeWithSelector(IStakeManager.getValidatorContract.selector),
            abi.encode(testValidatorShare)
        );
    }

    function test_buy_single_val(uint256 _amountToBuy) public {
        uint16[] memory valIds = new uint16[](1);
        valIds[0] = 1;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        uint16[] memory stakes = new uint16[](1);
        stakes[0] = 1000;
        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToBuy(_amountToBuy);

        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertEq(amounts[0], _amountToBuy);
    }

    function test_buy_single_val_nostake(uint256 _amountToBuy) public {
        uint16[] memory valIds = new uint16[](1);
        valIds[0] = 1;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        uint16[] memory stakes = new uint16[](1);
        stakes[0] = 0;
        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToBuy(_amountToBuy);

        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertEq(amounts[0], _amountToBuy);
    }

    function test_buy_two_equal_val(uint256 _amountToBuy) public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 35;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 50;
        shares[1] = 50;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 1000;
        stakes[1] = 1000;

        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToBuy(_amountToBuy);
        console.log(ids.length);
        console.log("Amount to buy:", _amountToBuy);

        // calced as others stake == (100 - share + maxdivergence )
        // my stake == others stake * their share / (100 - share + maxdivergence)
        // here 1000 is 30% (we are 70%) so our potential stake is 1000/30 *70 = 2333
        // take full other stake / their min share * our max share minus our current stake
        uint256 cutOffFirstValidator = 2333 - 1000;
        uint256 cutOffSecondValidator = 2333 - 1000;

        if (_amountToBuy > cutOffFirstValidator) {
            if (_amountToBuy < cutOffFirstValidator + cutOffSecondValidator) {
                assertEq(ids.length, 2, "should select two validators");
                assertEq(ids[0], 1);
                assertEq(ids[1], 35);
                assertEq(amounts[0], cutOffFirstValidator);
                assertEq(amounts[1], _amountToBuy - cutOffFirstValidator);
            } else {
                assertEq(ids.length, 2, "should select two validators equally");
                assertEq(ids[0], 1);
                assertEq(ids[1], 35);
                assertEq(amounts[0], _amountToBuy / 2 + _amountToBuy % 2);
                assertEq(amounts[1], _amountToBuy / 2);
            }
        } else {
            assertEq(ids.length, 1, "should select one validator");
            assertEq(ids[0], 1);
            assertEq(amounts[0], _amountToBuy);
        }
    }

    function test_buy_two_different_val(uint256 _amountToBuy) public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 35;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 75;
        shares[1] = 25;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 7500;
        stakes[1] = 2500;

        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToBuy(_amountToBuy);

        // take full other stake / their min share * our max share minus our current stake
        uint256 cutOffFirstValidator = (2500 / (25 - 20) * (75 + 20)) - 7500; //2000
        uint256 cutOffSecondValidator = (uint256(7500 * 45) / 55) - 2500; //2000

        if (_amountToBuy > cutOffFirstValidator) {
            if (_amountToBuy < (cutOffFirstValidator + cutOffSecondValidator)) {
                assertEq(ids.length, 2, "should select two validators");
                assertEq(ids[0], 1);
                assertEq(ids[1], 35);
                assertEq(amounts[0], cutOffFirstValidator);
                assertEq(amounts[1], _amountToBuy - cutOffFirstValidator);
            } else {
                assertEq(ids.length, 2, "should select two validators equal");
                assertEq(ids[0], 1);
                assertEq(ids[1], 35);
                assertEq(amounts[0], _amountToBuy / 2 + _amountToBuy % 2);
                assertEq(amounts[1], _amountToBuy / 2);
            }
        } else {
            assertEq(ids.length, 1, "should select one validator");
            assertEq(ids[0], 1);
            assertEq(amounts[0], _amountToBuy);
        }
    }

    function test_buy_two_very_different_Val(uint256 _amountToBuy) public {
        vm.assume(_amountToBuy < 1e30 * 1e18); // prevent overflow in test, 18 decimals, 100 bil max pol
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 35;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 99;
        shares[1] = 1;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 9900;
        stakes[1] = 100;

        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToBuy(_amountToBuy);

        assertEq(ids.length, 1, "should select one validator");
        assertEq(ids[0], 1);
        assertEq(amounts[0], _amountToBuy);
    }

    function test_buy_two_very_different_val_reverse(uint256 _amountToBuy) public {
        vm.assume(_amountToBuy < 1e30 * 1e18); // prevent overflow in test, 18 decimals, 100 bil max pol
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 35;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 1;
        shares[1] = 99;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 100;
        stakes[1] = 9900;

        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToBuy(_amountToBuy);

        // take full other stake / their min share * our max share minus our current stake
        uint256 cutOffFirstValidator = uint256(9900 * 21) / 79 - 100; //2000

        if (_amountToBuy > cutOffFirstValidator) {
            assertEq(ids.length, 1, "should select one validator primary");
            assertEq(ids[0], 35);
            assertEq(amounts[0], _amountToBuy);
        } else {
            assertEq(ids.length, 1, "should select one validator secondary");
            assertEq(ids[0], 1);
            assertEq(amounts[0], _amountToBuy);
        }
    }
    // select sellers

    function test_sell_single_val(uint256 _amountToSell) public {
        // can't exceed stake, check for this happens before _selectValidatorToSell call
        vm.assume(_amountToSell <= 1000);
        uint16[] memory valIds = new uint16[](1);
        valIds[0] = 1;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        uint16[] memory stakes = new uint16[](1);
        stakes[0] = 1000;
        addValidators(valIds, shares, stakes);

        (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToSell(_amountToSell);
        console.log(amounts[0]);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertEq(amounts[0], _amountToSell > 1000 ? 1000 : _amountToSell);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_sell_two_equal_val(uint256 _amountToSell) public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 35;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 50;
        shares[1] = 50;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 1000;
        stakes[1] = 1000;

        addValidators(valIds, shares, stakes);

        uint256 cutOffFirstValidator = 1000 - 428;
        uint256 cutOffSecondValidator = 1000 - 428;

        if (_amountToSell > 2000) {
            vm.expectRevert("Not enough stake");
            _selectValidatorToSell(_amountToSell);
        } else {
            (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToSell(_amountToSell);

            if (_amountToSell > cutOffFirstValidator) {
                if (_amountToSell < cutOffFirstValidator + cutOffSecondValidator) {
                    assertEq(ids.length, 2, "should select two validators");
                    assertEq(ids[0], 1);
                    assertEq(ids[1], 35);
                    assertEq(amounts[0], cutOffFirstValidator);
                    assertEq(amounts[1], _amountToSell - cutOffFirstValidator);
                } else {
                    if (_amountToSell > 1000) {
                        assertEq(ids.length, 2, "should select two validators to empty");
                        assertEq(ids[0], 1);
                        assertEq(ids[1], 35);
                        assertEq(amounts[0], 1000);
                        assertEq(amounts[1], _amountToSell - 1000);
                    } else {
                        assertEq(ids.length, 1, "should select one validator to empty");
                        assertEq(ids[0], 1);
                        assertEq(amounts[0], _amountToSell);
                    }
                }
            } else {
                assertEq(ids.length, 1, "should select one validator");
                assertEq(ids[0], 1);
                assertEq(amounts[0], _amountToSell);
            }
        }
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_sell_two_diff_val(uint256 _amountToSell) public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 35;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 30;
        shares[1] = 70;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 7000;
        stakes[1] = 2000;

        addValidators(valIds, shares, stakes);

        uint256 cutOffFirstValidator = 7000 - 222;
        // uint256 cutOffSecondValidator = 0;

        if (_amountToSell > 9000) {
            vm.expectRevert("Not enough stake");
            _selectValidatorToSell(_amountToSell);
        } else {
            (uint16[] memory ids, uint256[] memory amounts) = _selectValidatorToSell(_amountToSell);

            if (_amountToSell > cutOffFirstValidator) {
                if (_amountToSell > 7000) {
                    assertEq(ids.length, 2, "should select two validators to empty");
                    assertEq(ids[0], 1);
                    assertEq(ids[1], 35);
                    assertEq(amounts[0], 7000);
                    assertEq(amounts[1], _amountToSell - 7000);
                } else {
                    assertEq(ids.length, 1, "should select one validator to empty");
                    assertEq(ids[0], 1);
                    assertEq(amounts[0], _amountToSell);
                }
            } else {
                assertEq(ids.length, 1, "should select one validator");
                assertEq(ids[0], 1);
                assertEq(amounts[0], _amountToSell);
            }
        }
    }

    function test_getMostOverfunded_single() public {
        uint16[] memory valIds = new uint16[](1);
        valIds[0] = 1;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        uint16[] memory stakes = new uint16[](1);
        stakes[0] = 1000;
        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 1);
        assertEq(amount, 1000);
    }

    function test_getMostOverfunded_two_equal() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 101;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 50;
        shares[1] = 50;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 1000;
        stakes[1] = 1000;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 1);
        // take full other stake / their max share * our min share and deduct it from our current stake
        // 1000 is 70% (we are 30%) so our potential min stake is 1000/70 *30 = 428
        assertEq(amount, 1000 - 428);
    }

    function test_getMostOverfunded_two_diff() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 101;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 10;
        shares[1] = 90;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 1000;
        stakes[1] = 9000;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 101);
        // take full other stake / their max share * our min share and deduct it from our current stake
        //1000 is 30 % (we are 70%) so our potential min stake is 1000/30 *70 = 2333
        assertEq(amount, 9000 - 2333);
    }

    function test_getMostOverfunded_two_diff_no_stake() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 101;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 10;
        shares[1] = 90;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 0;
        stakes[1] = 0;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 1);
        // totalStake  * stakeShare + divergence /100 - currentStake
        assertEq(amount, 0);
    }

    function test_getMostOverfunded_two_diff_weird_stake() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 101;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 10;
        shares[1] = 90;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 5000;
        stakes[1] = 0;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 1);
        // totalStake  * stakeShare + divergence /100 - currentStake
        assertEq(amount, 5000);
    }

    function test_getMostOverfunded_two_diff_both_weird_stake() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 101;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 95;
        shares[1] = 5;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 100;
        stakes[1] = 5000;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 101);
        // totalStake  * stakeShare + divergence /100 - currentStake
        assertEq(amount, 5000);
    }

    function test_getMostOverfunded_two_diff_both_weird_stake_divergence() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 1;
        valIds[1] = 101;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 75;
        shares[1] = 25;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 100;
        stakes[1] = 5000;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostOverfundedValidator();
        assertEq(val, 101);
        // take full other stake / their max share * our min share and deduct it from our current stake
        //100 is 95% (we are 5%) so our potential min stake is 100/95 * 5 = 5
        assertEq(amount, 5000 - 5);
    }

    function test_getMostUnderfunded_single(uint256 _amount) public {
        uint16[] memory valIds = new uint16[](1);
        valIds[0] = 1;
        uint8[] memory shares = new uint8[](1);
        shares[0] = 100;
        uint16[] memory stakes = new uint16[](1);
        stakes[0] = uint16(_amount);

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostUnderfundedValidator();
        assertEq(val, 1);
        // totalStake  * stakeShare + divergence /100 - currentStake
        assertEq(amount, type(uint256).max);
    }

    function test_getMostUnderfunded_two() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 10;
        valIds[1] = 74;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 30;
        shares[1] = 70;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 3000;
        stakes[1] = 7000;

        addValidators(valIds, shares, stakes);

        (uint16 val, uint256 amount) = this.getMostUnderfundedValidator();
        assertEq(val, 74);
        // take full other stake / their min share * our max share and deduct our current stake
        // 3000 is 10% (we are 90%) so our potential max stake is 3000/10 *90 = 27000
        assertEq(amount, 27000 - 7000);
    }

    function test_getMostUnderfunded_two_nostake() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 10;
        valIds[1] = 74;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 30;
        shares[1] = 70;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 0;
        stakes[1] = 0;

        addValidators(valIds, shares, stakes);
        (uint16 val, uint256 amount) = this.getMostUnderfundedValidator();
        assertEq(val, 10);
        // totalStake  * stakeShare + divergence /100 - currentStake
        assertEq(amount, type(uint256).max);
    }

    function test_getMostUnderfunded_two_weird_stake() public {
        uint16[] memory valIds = new uint16[](2);
        valIds[0] = 10;
        valIds[1] = 74;
        uint8[] memory shares = new uint8[](2);
        shares[0] = 30;
        shares[1] = 70;
        uint16[] memory stakes = new uint16[](2);
        stakes[0] = 6000;
        stakes[1] = 2000;

        addValidators(valIds, shares, stakes);
        (uint16 val, uint256 amount) = this.getMostUnderfundedValidator();
        assertEq(val, 74);
        // take full other stake / their min share * our max share and deduct our current stake
        // 6000 is 10% (we are 90%) so our potential max stake is 6000/10 *90 = 54000
        assertEq(amount, 54000 - 2000);
    }

    function addValidators(uint16[] memory _ids, uint8[] memory _shares, uint16[] memory _stakes) internal {
        for (uint256 i = 0; i < _ids.length; i++) {
            address validatorShare = makeAddr(string(abi.encodePacked("ValidatorShare", _ids[i])));
            vm.mockCall(
                testStakeManager,
                abi.encodeWithSelector(IStakeManager.getValidatorContract.selector, _ids[i]),
                abi.encode(validatorShare)
            );
            vm.prank(testAdmin);
            this.addValidator(_ids[i]);

            // mock for future reloadInfo call
            vm.mockCall(
                validatorShare,
                abi.encodeWithSelector(IValidatorShare.balanceOf.selector, address(this)),
                abi.encode(_stakes[i])
            );
        }
        vm.prank(testAdmin);
        this.updateValidatorTargetShare(_ids, _shares);
        vm.prank(testAdmin);
        this.reloadAllValidatorInfo();
    }
}
