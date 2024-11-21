// SPDX-License-Identifier: MIT

pragma solidity =0.8.6;

import "./FeeCollector.sol";

contract FeeCollectorMock is FeeCollector {

    constructor(string[] memory methods, uint256[] memory fees) {
        setFeesConfiguration(methods, fees);
    }

    function paidMethod() external payable collectFee('paidMethod') {
        // DOES NOTHING
    }

    function freeMethod() external {
        // DOES NOTHING
    }
}
