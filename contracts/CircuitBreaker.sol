// SPDX-License-Identifier: MIT
// @title CircuitBreaker — Sovereign Reserve Circuit Breaker
// @notice 4 operational bands + 40% hard floor.
//         Hard floor (HARD_FLOOR = 4000 bps) is a constant — not governance-adjustable.
//         ALERT/PAUSED band thresholds are governance params with 48h timelock.
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

error TimelockNotExpired();
error NoPendingProposal();

contract CircuitBreaker is AccessControl {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @dev Hard floor is immutable — requires full contract upgrade to change.
    uint256 public constant HARD_FLOOR = 4000;   // 40% in basis points
    uint256 public constant TIMELOCK   = 48 hours;

    enum State { NORMAL, ALERT, PAUSED, RESUMING, REVERTED }

    // Governance-adjustable thresholds (with timelock)
    uint256 public alertThreshold  = 8000; // 80% — below this → ALERT
    uint256 public pauseThreshold  = 6000; // 60% — below this → PAUSED

    State   public state;
    uint256 public currentRatio;    // basis points (0–10000)
    uint256 public pausedAt;        // timestamp when PAUSED started (for RESUMING calc)

    // Timelock proposal
    struct ThresholdProposal {
        uint256 newAlertThreshold;
        uint256 newPauseThreshold;
        uint256 proposedAt;
        bool    active;
    }
    ThresholdProposal public pendingProposal;

    event StateChanged(State indexed previous, State indexed current, uint256 ratio);
    event CircuitBroken(uint256 ratio);
    event ThresholdUpdateProposed(uint256 alertBps, uint256 pauseBps, uint256 executeAfter);
    event ThresholdUpdated(uint256 alertBps, uint256 pauseBps);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Called by ReserveOracle whenever reserve ratios change.
    function updateRatio(uint256 verifiedBps, uint256 pendingBps) external onlyRole(ORACLE_ROLE) {
        uint256 totalBps = verifiedBps + pendingBps;
        currentRatio = totalBps;

        State previous = state;
        State next;

        if (totalBps < HARD_FLOOR) {
            next = State.REVERTED;
            emit CircuitBroken(totalBps);
        } else if (totalBps < pauseThreshold) {
            // Dropped back below pause threshold — reset to PAUSED regardless of prior state
            next = State.PAUSED;
            if (previous != State.PAUSED) pausedAt = block.timestamp;
        } else if (previous == State.PAUSED || previous == State.RESUMING) {
            // Coming out of PAUSED: RESUMING corridor requires ratio >= 7000 bps
            if (totalBps >= 7000) {
                if (block.timestamp >= pausedAt + 24 hours) {
                    next = State.NORMAL;
                } else {
                    next = State.RESUMING;
                    // Record when RESUMING started (only on entry from PAUSED)
                    if (previous == State.PAUSED) pausedAt = block.timestamp;
                }
            } else {
                next = State.ALERT;
            }
        } else if (totalBps < alertThreshold) {
            next = State.ALERT;
        } else {
            next = State.NORMAL;
        }

        if (next != previous) {
            state = next;
            emit StateChanged(previous, next, totalBps);
        }
    }

    /// @notice Returns true if minting is allowed in current state.
    function canMint() external view returns (bool) {
        return state == State.NORMAL || state == State.ALERT || state == State.RESUMING;
    }

    /// @notice Propose new band thresholds. 48h timelock before execution.
    function proposeThresholdUpdate(uint256 _alertBps, uint256 _pauseBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_alertBps > _pauseBps, "CircuitBreaker: alert must exceed pause");
        require(_pauseBps > HARD_FLOOR, "CircuitBreaker: pause must exceed hard floor");
        pendingProposal = ThresholdProposal({
            newAlertThreshold: _alertBps,
            newPauseThreshold: _pauseBps,
            proposedAt: block.timestamp,
            active: true
        });
        emit ThresholdUpdateProposed(_alertBps, _pauseBps, block.timestamp + TIMELOCK);
    }

    /// @notice Execute threshold update after 48h timelock.
    function executeThresholdUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!pendingProposal.active) revert NoPendingProposal();
        if (block.timestamp < pendingProposal.proposedAt + TIMELOCK) revert TimelockNotExpired();

        alertThreshold = pendingProposal.newAlertThreshold;
        pauseThreshold = pendingProposal.newPauseThreshold;
        pendingProposal.active = false;

        emit ThresholdUpdated(alertThreshold, pauseThreshold);
    }
}
