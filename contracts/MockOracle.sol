// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Define Interface locally to avoid dependency issues
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

contract MockOracle is AggregatorV3Interface {
    uint8 public override decimals;
    int256 private price;

    constructor(uint8 _decimals, int256 _price) {
        decimals = _decimals;
        price = _price;
    }

    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
