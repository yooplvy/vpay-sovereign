// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./VPAYToken.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/**
 * @title GoldRedemption v2
 * @notice Burns VPAY for USDC at an oracle-enforced gold floor price.
 *
 * Payout logic:
 *   - pro-rata  = (vpayAmount / totalSupply) × usdcPool
 *   - floor     = vpayAmount × goldGramsPerVPAY × chainlinkPrice / conversion_factor
 *   - grossPayout = max(proRata, floor)   ← richer of the two
 *   - netPayout = grossPayout × (1 - REDEMPTION_FEE_BPS / 10000)
 *
 * Caller must approve this contract to spend their VPAY before calling redeem().
 * Admin must set goldGramsPerVPAY and fund the USDC reserve pool before opening redemptions.
 */
contract GoldRedemption is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    VPAYToken public immutable vpay;
    IERC20    public immutable usdc;
    AggregatorV3Interface public goldOracle;

    /// @dev 0.5% OTC fee — matches RedemptionManager spec.
    uint256 public constant REDEMPTION_FEE_BPS = 50;
    /// @dev Chainlink XAU/USD heartbeat is 1 hour.
    uint256 public constant ORACLE_STALENESS   = 1 hours;

    /// @dev Grams of XAU backing one whole VPAY token. 4 implicit decimals.
    ///      e.g., 100 = 0.0100g per VPAY,  10000 = 1.0000g per VPAY.
    ///      Must be set by admin before redemptions open (starts at 0 = locked).
    uint256 public goldGramsPerVPAY;

    event Redeemed(address indexed user, uint256 vpayBurned, uint256 usdcPaid, uint256 oraclePrice);
    event ReserveFunded(uint256 amount);
    event ReserveWithdrawn(uint256 amount);
    event OracleUpdated(address indexed newOracle);
    event GoldBackingUpdated(uint256 gramsPerVPAY);

    constructor(address _vpay, address _usdc, address _oracle) {
        require(_vpay  != address(0), "Zero vpay");
        require(_usdc  != address(0), "Zero usdc");
        require(_oracle != address(0), "Zero oracle");
        vpay       = VPAYToken(_vpay);
        usdc       = IERC20(_usdc);
        goldOracle = AggregatorV3Interface(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function setOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_oracle != address(0), "Zero address");
        goldOracle = AggregatorV3Interface(_oracle);
        emit OracleUpdated(_oracle);
    }

    /// @notice Set how many grams of gold back one VPAY. 4 implicit decimals.
    ///         e.g., setGoldBacking(100) → 0.01g per VPAY.
    ///         Must be > 0 to open redemptions.
    function setGoldBacking(uint256 _gramsPerVPAY) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_gramsPerVPAY > 0, "Zero backing");
        goldGramsPerVPAY = _gramsPerVPAY;
        emit GoldBackingUpdated(_gramsPerVPAY);
    }

    /// @notice Deposit USDC into the redemption reserve pool.
    function fundReserves(uint256 usdcAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit ReserveFunded(usdcAmount);
    }

    /// @notice Withdraw USDC from the reserve pool (emergency or rebalance).
    function withdrawReserves(uint256 usdcAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdc.safeTransfer(msg.sender, usdcAmount);
        emit ReserveWithdrawn(usdcAmount);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    /// @notice Oracle floor price (USDC, 6-dec) for one whole VPAY token.
    ///         Returns 0 if backing not configured or oracle is stale.
    function getFloorPerVPAY() public view returns (uint256) {
        if (goldGramsPerVPAY == 0) return 0;
        (, int256 price, , uint256 updatedAt, ) = goldOracle.latestRoundData();
        if (price <= 0 || block.timestamp - updatedAt > ORACLE_STALENESS) return 0;
        // Chainlink XAU/USD: 8-decimal $/troy-oz
        // floor (USDC 6-dec) per VPAY = goldGramsPerVPAY × price × 1e6
        //                                / (1e4 × 31.1035 × 1e8)
        //                             = goldGramsPerVPAY × price / 311_035_000
        return (goldGramsPerVPAY * uint256(price)) / 311_035_000;
    }

    // ── Core ───────────────────────────────────────────────────────────────────

    /// @notice Burn VPAY and receive USDC.
    ///         Caller must approve this contract to spend their VPAY first.
    function redeem(uint256 vpayAmount) external nonReentrant whenNotPaused {
        require(vpayAmount > 0, "Zero amount");
        require(goldGramsPerVPAY > 0, "Gold backing not configured");

        // 1. Fetch and validate oracle price
        (, int256 price, , uint256 updatedAt, ) = goldOracle.latestRoundData();
        require(price > 0, "Invalid oracle price");
        require(block.timestamp - updatedAt <= ORACLE_STALENESS, "Oracle stale");

        // 2. Oracle floor for this redemption
        //    floorPerVPAY is USDC (6-dec) per 1 full VPAY (1e18 wei)
        uint256 floorPerVPAY = (goldGramsPerVPAY * uint256(price)) / 311_035_000;
        uint256 floorTotal   = (floorPerVPAY * vpayAmount) / 1e18;
        require(floorTotal > 0, "Redemption too small");

        // 3. Pro-rata share of USDC reserve pool
        uint256 poolBalance = usdc.balanceOf(address(this));
        uint256 totalSupply = vpay.totalSupply();
        require(totalSupply > 0, "Zero supply");
        uint256 proRata = (vpayAmount * poolBalance) / totalSupply;

        // 4. Use whichever is richer: floor or pro-rata
        uint256 grossPayout = proRata > floorTotal ? proRata : floorTotal;

        // 5. Apply redemption fee
        uint256 fee       = (grossPayout * REDEMPTION_FEE_BPS) / 10000;
        uint256 netPayout = grossPayout - fee;

        // 6. Pool must cover the net payout
        require(poolBalance >= netPayout, "Insufficient reserves");

        // 7. Burn VPAY from caller (effect before external interactions — CEI)
        //    Requires caller to have approved this contract for >= vpayAmount
        vpay.burnFrom(msg.sender, vpayAmount);

        // 8. Transfer USDC to caller
        usdc.safeTransfer(msg.sender, netPayout);

        emit Redeemed(msg.sender, vpayAmount, netPayout, uint256(price));
    }
}
