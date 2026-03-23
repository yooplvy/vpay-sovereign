// SPDX-License-Identifier: MIT
// @title ReserveOracle — Sovereign Reserve Ratio Publisher
// @notice Tracks verified gold, pending procurement, and USDC reserve.
//         All ratios in basis points (0–10000 = 0–100%).
//         USDC tracked at market price (not par) — SVB-proof.
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract ReserveOracle is AccessControl {
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    uint256 public verifiedBps;
    uint256 public pendingBps;
    uint256 public usdcBalance;
    uint256 public usdcMarketPrice;
    uint256 public lastUpdated;

    event RatioUpdated(uint256 verified, uint256 pending, uint256 total);
    event ProcurementCompleted(uint256 amount);
    event USDCUpdated(uint256 balance, uint256 marketPrice);

    constructor(address admin) {
        require(admin != address(0), "ReserveOracle: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function updateVerified(uint256 _verifiedBps) external onlyRole(UPDATER_ROLE) {
        require(_verifiedBps <= 10000, "ReserveOracle: exceeds 100%");
        verifiedBps = _verifiedBps;
        lastUpdated = block.timestamp;
        emit RatioUpdated(verifiedBps, pendingBps, verifiedBps + pendingBps);
    }

    function updatePending(uint256 _pendingBps) external onlyRole(UPDATER_ROLE) {
        require(verifiedBps + _pendingBps <= 10000, "ReserveOracle: total exceeds 100%");
        pendingBps = _pendingBps;
        lastUpdated = block.timestamp;
        emit RatioUpdated(verifiedBps, pendingBps, verifiedBps + pendingBps);
    }

    function completeProcurement(uint256 _bps) external onlyRole(UPDATER_ROLE) {
        require(_bps <= pendingBps, "ReserveOracle: exceeds pending");
        pendingBps  -= _bps;
        verifiedBps += _bps;
        lastUpdated = block.timestamp;
        emit ProcurementCompleted(_bps);
        emit RatioUpdated(verifiedBps, pendingBps, verifiedBps + pendingBps);
    }

    function updateUSDC(uint256 _balance, uint256 _marketPrice) external onlyRole(UPDATER_ROLE) {
        usdcBalance     = _balance;
        usdcMarketPrice = _marketPrice;
        emit USDCUpdated(_balance, _marketPrice);
    }

    function reserveRatio() external view returns (uint256 verified, uint256 pending, uint256 total) {
        return (verifiedBps, pendingBps, verifiedBps + pendingBps);
    }

    function usdcReserve() external view returns (uint256 balance, uint256 marketPrice) {
        return (usdcBalance, usdcMarketPrice);
    }
}
