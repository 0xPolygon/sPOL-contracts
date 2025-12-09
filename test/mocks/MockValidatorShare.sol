// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.30;

contract MockValidatorShare {
    constructor() {}

    mapping(address => uint256) public unbondNonces;
    uint256 reward;
    mapping(address => uint256) public balanceOf;
    //mapping(address => mapping(address => uint256)) public allowance;

    function buyVoucherPOL(uint256 a, uint256) public returns (uint256) {
        balanceOf[msg.sender] += a;
        return a;
    }

    function restakePOL() public returns (uint256, uint256) {
        uint256 currentReward = reward;
        balanceOf[msg.sender] += currentReward;
        reward = 0;
        return (currentReward, currentReward);
    }

    function restakeAndStakePOL(uint256 a) public returns (uint256, uint256) {
        uint256 currentReward = reward;
        balanceOf[msg.sender] += a + currentReward;
        reward = 0;
        return (a + currentReward, currentReward);
    }

    function restakeAndUnstakePOL(uint256) public returns (uint256) {
        uint256 currentReward = reward;
        balanceOf[msg.sender] += currentReward;
        reward = 0;
        return (currentReward);
    }

    function restakeAndTransferFrom(address _from, address _to, uint256 _amount) public returns (bool, uint256) {
        require(balanceOf[_from] >= _amount, "Insufficient balance");

        uint256 currentReward = reward;
        balanceOf[_from] -= _amount;
        balanceOf[_from] += currentReward;
        balanceOf[_to] += _amount;
        reward = 0;
        return (true, currentReward);
    }

    function sellVoucher_newPOL(uint256, uint256) public {
        unbondNonces[msg.sender]++;
    }

    function addReward(uint256 _reward) public {
        reward += _reward;
    }

    function migrateIn(address _user, uint256 _amount) public {
        balanceOf[_user] += _amount;
    }

    function migrateOut(address _user, uint256 _amount) public {
        require(balanceOf[_user] >= _amount, "Insufficient balance");
        balanceOf[_user] -= _amount;
    }
}

