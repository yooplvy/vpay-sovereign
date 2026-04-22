// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

/**
 * @title ICircuitBreaker
 * @notice Interface for the CircuitBreaker emergency pause contract.
 *         Used by SovereignNode, VPAYVault, and AttestationBridge to
 *         check pause status before executing operations.
 */
interface ICircuitBreaker {
    function globalPaused() external view returns (bool);
    function nodePaused(bytes32 nodeId) external view returns (bool);
}
