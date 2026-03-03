// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./VPAYToken.sol";

// Inline Interface
interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract GoldRedemption is AccessControl {
    VPAYToken public immutable vpay;
    IERC20 public immutable usdc;
    AggregatorV3Interface public goldOracle;

    uint256 public constant REDEMPTION_FEE_BPS = 200; // 2%
    
    event Redeemed(address indexed user, uint256 vpayBurned, uint256 usdcPaid);

    constructor(address _vpay, address _usdc, address _oracle) {
        vpay = VPAYToken(_vpay);
        usdc = IERC20(_usdc);
        goldOracle = AggregatorV3Interface(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // BURN VPAY -> GET USDC (Floor Price Enforcement)
    function redeem(uint256 vpayAmount) external {
        require(vpay.balanceOf(msg.sender) >= vpayAmount, "Insufficient VPAY balance");

        // 1. Get Gold Price ($ per oz * 10^8)
        (, int256 price, , , ) = goldOracle.latestRoundData();
        require(price > 0, "Invalid Oracle Price");

        // 2. Calculate Payout
        // Simplified Logic for Demo:
        // Assume 1 VPAY represents a fraction of the gold reserve.
        // Floor Price Logic: 1 VPAY >= $0.01 (mock floor)
        // In Production: Payout = (vpayAmount / totalSupply) * GoldReserveValue
        
        // For this demo: Let's fix the floor at $0.01 USDC per VPAY
        // User burns 100 VPAY -> gets 1 USDC (minus fees)
        
        uint256 floorPrice = 10000; // $0.01 in USDC 6-decimals (10000 micro-usdc)
        uint256 grossPayout = vpayAmount * floorPrice; 
        uint256 fee = (grossPayout * REDEMPTION_FEE_BPS) / 10000;
        uint256 netPayout = grossPayout - fee;

        // 3. Burn VPAY from User
        // User must Approve Redemption Contract to spend VPAY first
        vpay.burn(vpayAmount);

        // 4. Transfer USDC
        require(usdc.balanceOf(address(this)) >= netPayout, "Insufficient Redemption Reserves");
        usdc.transfer(msg.sender, netPayout);

        emit Redeemed(msg.sender, vpayAmount, netPayout);
    }

    // Admin: Fund the pool
    function fundReserves(uint256 usdcAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
    }
}
