// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ICircuitBreaker.sol";

/**
 * @title CircuitBreaker (v2 — ICircuitBreaker Interface)
 * @author ANO-YOOFI-AGYEI
 * @notice Emergency pause mechanism for VPAY Genesis protocol.
 *
 *         v2 adds: ICircuitBreaker interface for cross-contract integration,
 *         time-delayed resume (prevents flash-resume attacks), pause reason
 *         tracking, and batch node pause.
 *
 *         Used by: SovereignNode, VPAYVault, AttestationBridge.
 */
contract CircuitBreaker is AccessControl, ICircuitBreaker {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Minimum delay before a resume takes effect (prevents flash attacks).
    uint256 public constant RESUME_DELAY = 5 minutes;

    bool public override globalPaused;
    mapping(bytes32 => bool) public override nodePaused;

    /// @notice Timestamp of last global pause — resume requires delay after this.
    uint256 public globalPausedAt;
    mapping(bytes32 => uint256) public nodePausedAt;

    /// @notice Reason for pause (for audit trail).
    string public globalPauseReason;
    mapping(bytes32 => string) public nodePauseReason;

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event GlobalPause(address indexed guardian, string reason);
    event GlobalResume(address indexed guardian);
    event NodePaused(bytes32 indexed nodeId, address indexed guardian, string reason);
    event NodeResumed(bytes32 indexed nodeId, address indexed guardian);

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    // ════════════════════════════════════════
    // GLOBAL PAUSE
    // ════════════════════════════════════════

    /**
     * @notice Emergency global pause — immediate effect.
     */
    function setGlobalPause(string calldata _reason) external onlyRole(GUARDIAN_ROLE) {
        globalPaused = true;
        globalPausedAt = block.timestamp;
        globalPauseReason = _reason;
        emit GlobalPause(msg.sender, _reason);
    }

    /**
     * @notice Resume from global pause — requires RESUME_DELAY since pause.
     */
    function globalResume() external onlyRole(GUARDIAN_ROLE) {
        require(globalPaused, "Not paused");
        require(block.timestamp >= globalPausedAt + RESUME_DELAY, "Resume delay not met");
        globalPaused = false;
        globalPauseReason = "";
        emit GlobalResume(msg.sender);
    }

    // ════════════════════════════════════════
    // NODE PAUSE
    // ════════════════════════════════════════

    /**
     * @notice Pause a specific node — immediate effect.
     */
    function setNodePause(bytes32 _nodeId, string calldata _reason) external onlyRole(GUARDIAN_ROLE) {
        nodePaused[_nodeId] = true;
        nodePausedAt[_nodeId] = block.timestamp;
        nodePauseReason[_nodeId] = _reason;
        emit NodePaused(_nodeId, msg.sender, _reason);
    }

    /**
     * @notice Resume a specific node — requires RESUME_DELAY.
     */
    function nodeResume(bytes32 _nodeId) external onlyRole(GUARDIAN_ROLE) {
        require(nodePaused[_nodeId], "Node not paused");
        require(block.timestamp >= nodePausedAt[_nodeId] + RESUME_DELAY, "Resume delay not met");
        nodePaused[_nodeId] = false;
        nodePauseReason[_nodeId] = "";
        emit NodeResumed(_nodeId, msg.sender);
    }

    /**
     * @notice Batch pause multiple nodes.
     */
    function batchNodePause(bytes32[] calldata _nodeIds, string calldata _reason) external onlyRole(GUARDIAN_ROLE) {
        require(_nodeIds.length <= 100, "Batch too large");
        for (uint256 i = 0; i < _nodeIds.length; i++) {
            nodePaused[_nodeIds[i]] = true;
            nodePausedAt[_nodeIds[i]] = block.timestamp;
            nodePauseReason[_nodeIds[i]] = _reason;
            emit NodePaused(_nodeIds[i], msg.sender, _reason);
        }
    }

    // ════════════════════════════════════════
    // VIEW
    // ════════════════════════════════════════

    /**
     * @notice Check if operations are allowed for a given node.
     *         Returns true if both global and node-specific operations are unpaused.
     */
    function isOperational(bytes32 _nodeId) external view returns (bool) {
        return !globalPaused && !nodePaused[_nodeId];
    }
}
