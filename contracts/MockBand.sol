// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOracle.sol";

/// @dev Mock Band Protocol oracle implementing IStdReference for test fixtures.
///      setPrice accepts a uint256 in 18-decimal $/kg (matching Band's native format).
contract MockBand is IStdReference {
    uint256 private price;

    constructor() {}

    /// @param _price 18-decimal $/kg price (e.g. 144395e18 for $144,395/kg)
    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getReferenceData(string calldata, string calldata)
        external
        view
        override
        returns (ReferenceData memory)
    {
        return ReferenceData({
            rate: price,
            lastUpdatedBase: block.timestamp,
            lastUpdatedQuote: block.timestamp
        });
    }
}
