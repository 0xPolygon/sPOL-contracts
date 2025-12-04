pragma solidity ^0.8.0;

contract MockValidatorShare {
    constructor() {}

    mapping(address => uint256) public unbondNonces;
    uint256 reward;

    function buyVoucher(
        uint256 a,
        uint256 /* b */
    )
        public
        pure
        returns (uint256)
    {
        return a;
    }

    function restakePOL() public returns (uint256, uint256) {
        uint256 currentReward = reward;
        reward = 0;
        return (currentReward, currentReward);
    }

    function restakeAndStakePOL(uint256 a) public returns (uint256, uint256) {
        uint256 currentReward = reward;
        reward = 0;
        return (a + currentReward, currentReward);
    }

    function restakeAndUnstakePOL(uint256 a) public returns (uint256) {
        uint256 currentReward = reward;
        reward = 0;
        return (currentReward);
    }

    function sellVoucher_newPOL(
        uint256,
        /* a */
        uint256 /* b */
    )
        public
    {
        unbondNonces[msg.sender]++;
    }

    function addReward(uint256 _reward) public {
        reward += _reward;
    }
}

