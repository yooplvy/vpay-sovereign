// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockBand {
    int256 private price;
    uint8 public decimals = 18;

    // FIX: No arguments, matches the test call .deploy()
    constructor() {}

    // Test suite calls this to set the price
    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestAnswer() external view returns (int256) {
        return price;
    }
}
