// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IOracle.sol";

contract OracleTriad is AccessControl {

    AggregatorV3Interface public chainlinkOracle;
    IUniswapV3Pool public uniswapPool;
    IStdReference public bandOracle;

    uint256 public constant MAX_DEVIATION = 500; // 5%
    uint256 public constant STALENESS_THRESHOLD = 3 hours;

    event PriceUpdated(uint256 finalPrice);

    constructor(
        address _chainlink,
        address _uniswapPool,
        address _band
    ) {
        chainlinkOracle = AggregatorV3Interface(_chainlink);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        bandOracle = IStdReference(_band);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function getSafePrice() external view returns (uint256) {
        (uint256 clPrice, bool clValid) = getChainlinkPrice();
        (uint256 bandPrice, bool bandValid) = getBandPrice();

        require(clValid || bandValid, "All oracles failed");

        if (clValid && bandValid) {
            if (diff(clPrice, bandPrice) > MAX_DEVIATION) {
                return min(clPrice, bandPrice);
            }
            return (clPrice + bandPrice) / 2;
        }

        return clValid ? clPrice : bandPrice;
    }

    function getChainlinkPrice() internal view returns (uint256, bool) {
        try chainlinkOracle.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) return (0, false);
            return (uint256(answer) * 1e10, true);
        } catch {
            return (0, false);
        }
    }

    function getBandPrice() internal view returns (uint256, bool) {
        try bandOracle.getReferenceData("XAU", "USD") returns (IStdReference.ReferenceData memory data) {
            if (block.timestamp - data.lastUpdatedBase > STALENESS_THRESHOLD) return (0, false);
            return (data.rate, true);
        } catch {
            return (0, false);
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? ((a - b) * 10000) / a : ((b - a) * 10000) / a;
    }
}
