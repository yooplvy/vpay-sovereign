// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICircuitBreaker {
    enum State { NORMAL, ALERT, PAUSED, RESUMING, REVERTED }

    function state() external view returns (State);
    function canMint() external view returns (bool);
    function currentRatio() external view returns (uint256); // basis points
    function updateRatio(uint256 verifiedBps, uint256 pendingBps) external;

    event StateChanged(State indexed previous, State indexed current, uint256 ratio);
    event CircuitBroken(uint256 ratio);
}
