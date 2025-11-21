pragma solidity ^0.8.0;

contract MockValidatorShare {
    constructor() {}

    mapping(address => uint256) public unbondNonces;

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

    function restakePOL() public pure returns (uint256, uint256) {
        return (0, 0);
    }

    function restakeAndStakePOL(uint256 a) public pure returns (uint256, uint256) {
        return (a, 0);
    }

    function restakeAndUnstakePOL(uint256 a) public pure returns (uint256, uint256) {
        return (a, 0);
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
}

