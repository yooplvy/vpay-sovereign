// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockChainlink {
    int256 private price;
    uint8 public decimals = 8;

    // FIX: No arguments, matches the test call .deploy()
    constructor() {}

    // Test suite calls this to set the price
    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (0, price, 0, block.timestamp, 0);
    }
}
