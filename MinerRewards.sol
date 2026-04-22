// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ISovereignToken.sol";

error REWARDS__NothingToClaim();
error REWARDS__NotOperator();
error REWARDS__AlreadyClaimed();

/**
 * @title MinerRewards (v2 — $SOV Integrated)
 * @author ANO-YOOFI-AGYEI
 * @notice Distributes $SOV rewards to GSU node operators.
 *
 *         The AttestationBridge mints a miner reward share to this contract
 *         with every confirmed attestation. Node operators can claim their
 *         accumulated rewards at any time.
 *
 *         Reward flow:
 *         1. GSU submits attestation → SovereignNode
 *         2. Relayer calls AttestationBridge.confirmAndMint()
 *         3. Bridge mints 5% to this MinerRewards pool
 *         4. Node operator calls claim() to withdraw their $SOV
 */
contract MinerRewards is AccessControl, ReentrancyGuard {
    string public constant ARCHITECT = "ANO-YOOFI-AGYEI";

    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    ISovereignToken public immutable sovToken;

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    /// @notice Node operator address for each nodeId.
    mapping(bytes32 => address) public nodeOperator;

    /// @notice Unclaimed $SOV balance per operator address.
    mapping(address => uint256) public unclaimedRewards;

    /// @notice Total $SOV earned (lifetime) per operator.
    mapping(address => uint256) public totalEarned;

    /// @notice Total $SOV distributed through this contract.
    uint256 public totalDistributed;

    /// @notice Total $SOV claimed by operators.
    uint256 public totalClaimed;

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event OperatorRegistered(bytes32 indexed nodeId, address indexed operator);
    event RewardCredited(bytes32 indexed nodeId, address indexed operator, uint256 amount);
    event RewardClaimed(address indexed operator, uint256 amount);

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    /**
     * @param _sovToken SovereignToken ($SOV) contract address.
     */
    constructor(address _sovToken) {
        sovToken = ISovereignToken(_sovToken);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
    }

    // ════════════════════════════════════════
    // OPERATOR MANAGEMENT
    // ════════════════════════════════════════

    /**
     * @notice Register the operator address for a node.
     *         Only the admin can set this (during node onboarding).
     */
    function registerOperator(bytes32 _nodeId, address _operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_operator != address(0), "Zero address");
        nodeOperator[_nodeId] = _operator;
        emit OperatorRegistered(_nodeId, _operator);
    }

    // ════════════════════════════════════════
    // REWARD DISTRIBUTION
    // ════════════════════════════════════════

    /**
     * @notice Credit rewards to a node's operator.
     *         Called by the AttestationBridge (or distributor) after minting
     *         the miner share to this contract.
     *
     * @param _nodeId The node whose operator receives the reward.
     * @param _amount Amount of $SOV to credit.
     */
    function creditReward(bytes32 _nodeId, uint256 _amount) external onlyRole(DISTRIBUTOR_ROLE) {
        address operator = nodeOperator[_nodeId];
        require(operator != address(0), "No operator registered");
        require(_amount > 0, "Zero amount");

        unclaimedRewards[operator] += _amount;
        totalEarned[operator] += _amount;
        totalDistributed += _amount;

        emit RewardCredited(_nodeId, operator, _amount);
    }

    /**
     * @notice Batch credit rewards for multiple nodes.
     */
    function batchCreditReward(
        bytes32[] calldata _nodeIds,
        uint256[] calldata _amounts
    ) external onlyRole(DISTRIBUTOR_ROLE) {
        require(_nodeIds.length <= 100, "Batch too large");
        require(_nodeIds.length == _amounts.length, "Length mismatch");
        for (uint256 i = 0; i < _nodeIds.length; i++) {
            address operator = nodeOperator[_nodeIds[i]];
            if (operator != address(0) && _amounts[i] > 0) {
                unclaimedRewards[operator] += _amounts[i];
                totalEarned[operator] += _amounts[i];
                totalDistributed += _amounts[i];
                emit RewardCredited(_nodeIds[i], operator, _amounts[i]);
            }
        }
    }

    // ════════════════════════════════════════
    // CLAIM
    // ════════════════════════════════════════

    /**
     * @notice Claim all accumulated $SOV rewards.
     *         Transfers $SOV from this contract's balance to the caller.
     */
    function claim() external nonReentrant {
        uint256 amount = unclaimedRewards[msg.sender];
        if (amount == 0) revert REWARDS__NothingToClaim();

        // Effects before interactions
        unclaimedRewards[msg.sender] = 0;
        totalClaimed += amount;

        // Transfer $SOV
        bool success = sovToken.transfer(msg.sender, amount);
        require(success, "Transfer failed");

        emit RewardClaimed(msg.sender, amount);
    }

    // ════════════════════════════════════════
    // VIEW
    // ════════════════════════════════════════

    function pendingRewards(address _operator) external view returns (uint256) {
        return unclaimedRewards[_operator];
    }

    function operatorStats(address _operator) external view returns (
        uint256 earned,
        uint256 claimed,
        uint256 pending
    ) {
        earned = totalEarned[_operator];
        pending = unclaimedRewards[_operator];
        claimed = earned - pending;
    }
}
