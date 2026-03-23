// SPDX-License-Identifier: MIT
// @title OracleTriad (Production v5.1)
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IOracle.sol";

contract OracleTriad is AccessControl {

    AggregatorV3Interface public chainlinkOracle;
    IStdReference         public bandOracle;
    // NOTE: Uniswap TWAP integration deferred until Solana deployment.
    //       Uniswap is EVM-only and incompatible with planned Solana architecture.

    /// @dev Chainlink XAU/USD heartbeat is 1 hour — never accept staler data.
    uint256 public constant STALENESS_THRESHOLD = 1 hours;
    uint256 public constant MAX_DEVIATION       = 500;  // 5% in bps

    /// @dev Price bounds for XAU/USD in 18-decimal ($/kg). Prevents accepting
    ///      obviously manipulated prices ($0 or $100M/kg).
    uint256 public constant MIN_PRICE = 100_000e18;   // $100,000/kg  (~$3,100/oz floor)
    uint256 public constant MAX_PRICE = 200_000e18;   // $200,000/kg  (~$6,200/oz ceiling)

    event PriceUpdated(uint256 finalPrice);
    event OracleCircuitBreaker(uint256 clPrice, uint256 bandPrice, uint256 deviation, uint256 priceUsed);

    constructor(address _chainlink, address _band) {
        chainlinkOracle = AggregatorV3Interface(_chainlink);
        bandOracle      = IStdReference(_band);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // TODO (mainnet): transfer DEFAULT_ADMIN_ROLE to Gnosis Safe immediately after deploy
    }

    function getSafePrice() external returns (uint256) {
        (uint256 clPrice, bool clValid)     = getChainlinkPrice();
        (uint256 bandPrice, bool bandValid) = getBandPrice();

        require(clValid || bandValid, "All oracles failed");

        uint256 finalPrice;

        if (clValid && bandValid) {
            uint256 deviation = _diff(clPrice, bandPrice);
            if (deviation > MAX_DEVIATION) {
                // Circuit breaker: prices diverged — use the lower (more conservative)
                finalPrice = clPrice < bandPrice ? clPrice : bandPrice;
                emit OracleCircuitBreaker(clPrice, bandPrice, deviation, finalPrice);
            } else {
                finalPrice = (clPrice + bandPrice) / 2;
            }
        } else {
            finalPrice = clValid ? clPrice : bandPrice;
        }

        require(finalPrice >= MIN_PRICE && finalPrice <= MAX_PRICE, "Price out of bounds");
        emit PriceUpdated(finalPrice);
        return finalPrice;
    }

    function getChainlinkPrice() internal view returns (uint256, bool) {
        try chainlinkOracle.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0)                                       return (0, false);
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) return (0, false);
            // Chainlink XAU/USD returns 8 decimals ($/oz). Convert to 18-decimal $/kg.
            // 1 troy oz = 32.1507 g = 0.0321507 kg → multiply by ~31.1035 to get $/kg
            // Exact: answer (8 dec, $/oz) * 1e10 (→18 dec) * 32.1507 / 1 = $/kg 18-dec
            // Simplified multiply by 321507 / 10000 with the 1e10 factor:
            return (uint256(answer) * 1e10 * 321507 / 10000, true);
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

    /// @dev Returns deviation in bps between two prices, always dividing by the larger.
    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 larger = a > b ? a : b;
        uint256 delta  = a > b ? a - b : b - a;
        return (delta * 10000) / larger;
    }
}
