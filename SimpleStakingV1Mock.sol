// SPDX-License-Identifier: MIT

pragma solidity =0.8.6;

import "./SimpleStakingV1.sol";

contract SimpleStakingV1Mock is SimpleStakingV1 {
    constructor(uint256[] memory poolTimer, uint256[] memory poolLimit, IERC20 token, uint256 startBlock)
    SimpleStakingV1(poolTimer, poolLimit)
    {
        setTokenAddress(token);
        setStartBlock(startBlock);
    }
}
