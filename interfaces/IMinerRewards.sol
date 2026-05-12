// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

/**
 * @title IMinerRewards
 * @author ANO-YOOFI-AGYEI
 * @notice Minimal interface used by KommitBridge v1.2 to credit slashed-bond
 *         remainder into the MinerRewards operator-credit ledger.
 *
 *         v1.2 (MED-3 fix): KommitBridge v1.1 correctly transfers the SOV
 *         remainder to the MinerRewards contract balance, but never calls
 *         creditReward() — so no operator's unclaimedRewards mapping is ever
 *         incremented and the funds are Safe-administered dead-weight.
 *
 *         v1.2 closes the gap by granting KommitBridge DISTRIBUTOR_ROLE on
 *         MinerRewards and calling creditReward() for each node in the active
 *         slash period immediately after the transfer lands.
 */
interface IMinerRewards {
    /**
     * @notice Credit rewards to the operator of a registered node.
     *         Caller must hold DISTRIBUTOR_ROLE on the MinerRewards contract.
     *         Reverts if the nodeId has no registered operator.
     *
     * @param nodeId The node whose operator receives the credit.
     * @param amount Amount of $SOV to credit (must be > 0).
     */
    function creditReward(bytes32 nodeId, uint256 amount) external;
}
