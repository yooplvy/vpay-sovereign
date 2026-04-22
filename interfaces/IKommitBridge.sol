// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

/**
 * @title IKommitBridge
 * @author ANO-YOOFI-AGYEI
 * @notice Integrator interface for KommitBridge — Proof of Reasoning.
 *
 *         KommitBridge is the second groundbreaking IP in the VPAY Genesis
 *         stack. Where AttestationBridge attests MATTER (gold exists, this
 *         weight, this purity), KommitBridge attests MIND (this model, this
 *         context, this seed, this output — verifiable on-chain, challengeable
 *         by anyone).
 *
 *         Matter attested (Sika Dwa)  +  Mind attested (Kommit)  =  Sovereignty claimed.
 *
 *         The Commit is the universal primitive: a cryptographic promise made
 *         before the work is done, verifiable after.
 *
 *         ────────────────────────────────────────────────────────────────
 *         v1.1 — Audit Fix 2026-04-22 (Round 3 redeploy)
 *         ────────────────────────────────────────────────────────────────
 *         v1.0 had a CRITICAL bug (KOM-001) where `resolveChallenge` always
 *         dismissed the challenge after a valid seed reveal — bypassing the
 *         oracle entirely and inverting the fraud-proof economics. v1.1
 *         splits resolution into a phase-gated state machine:
 *
 *           Pending ──challenge──▶ Challenged ──revealSeed──▶ Revealed
 *                                       │                        │
 *                                       │ (no reveal             │ (oracleSlash slash)   ▶ Slashed
 *                                       │  in window)            │ (oracleSlash confirm) ▶ Dismissed
 *                                       ▼                        │ (oracle window over)
 *                                  Slashed (claimByChallenger)   ▼ ▶ Dismissed (claimByDefault)
 *
 *         Pending ──challengeWindow elapsed──▶ Finalized (no challenge ever filed)
 */
interface IKommitBridge {
    // ════════════════════════════════════════
    // ENUMS
    // ════════════════════════════════════════

    enum AttestationStatus {
        Pending,      // within challenge window
        Finalized,    // challenge window elapsed, no challenge ever filed
        Challenged,   // challenge active, awaiting seed reveal
        Revealed,     // seed revealed, awaiting oracle verdict (or default-to-reasoner timeout)
        Slashed,      // reasoner slashed (oracle verdict OR non-cooperation)
        Dismissed     // challenger bond forfeit (oracle confirmed reasoner OR reasoner won by default)
    }

    // ════════════════════════════════════════
    // STRUCTS
    // ════════════════════════════════════════

    struct Attestation {
        uint64  ts;                 // block.timestamp at attestation
        bytes32 modelWeightsHash;   // canonical hash of model weights (registered)
        bytes32 contextHash;        // keccak256 of full prompt + system state
        bytes32 seedCommit;         // commitment to seed (revealed only on challenge)
        bytes32 outputHash;         // keccak256 of the reasoning output
        address reasoner;           // address that made the attestation
        address challenger;         // zero until challenged
        uint256 reasonerBond;       // $SOV locked by reasoner
        uint256 challengerBond;     // $SOV locked by challenger (zero until challenged)
        uint64  challengeDeadline;  // rolling deadline:
                                    //   Pending    → challenge window end
                                    //   Challenged → reveal window end
                                    //   Revealed   → oracle window end
        AttestationStatus status;   // lifecycle state
    }

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event ModelRegistered(bytes32 indexed modelWeightsHash, string name, address registrar);
    event ReasoningAttested(
        uint256 indexed id,
        address indexed reasoner,
        bytes32 indexed modelWeightsHash,
        bytes32 contextHash,
        bytes32 outputHash,
        uint64 challengeDeadline
    );
    event ReasoningChallenged(uint256 indexed id, address indexed challenger, uint256 challengerBond);
    /// @notice v1.1 — emitted when reasoner reveals seed within reveal window. Carries the
    ///         (seed, salt) for off-chain replay services to recompute the expected output.
    event SeedRevealed(uint256 indexed id, bytes32 seed, bytes32 salt, uint64 oracleDeadline);
    event ReasoningSlashed(uint256 indexed id, bytes32 expectedOutputHash, bytes32 claimedOutputHash, uint256 slashedAmount);
    event ChallengeDismissed(uint256 indexed id, uint256 forfeitedBond);
    event ReasoningFinalized(uint256 indexed id);

    // ════════════════════════════════════════
    // CORE
    // ════════════════════════════════════════

    /**
     * @notice Register a model's canonical weights hash. Required before attesting.
     * @param modelWeightsHash keccak256 of canonical model weight serialization.
     * @param name Human-readable model name (e.g., "hermes-v2-zeus", "pantheon-plutus").
     */
    function registerModel(bytes32 modelWeightsHash, string calldata name) external;

    /**
     * @notice Attest that a reasoning output was produced by a specific (model, context, seed).
     *         Caller must hold REASONER_ROLE and pre-lock `reasonerBond` $SOV via approve.
     */
    function attestReasoning(
        bytes32 modelWeightsHash,
        bytes32 contextHash,
        bytes32 seedCommit,
        bytes32 outputHash
    ) external returns (uint256 id);

    /**
     * @notice Challenge an attestation within the challenge window.
     *         Challenger must pre-lock `challengerBond` $SOV via approve.
     *         Challenger submits the replayed output hash they computed independently.
     */
    function challenge(uint256 id, bytes32 replayedOutputHash) external;

    /**
     * @notice v1.1 — Reveal the seed/salt for a challenged attestation.
     *         Anyone may call (the seed/salt are sufficient credential — only the reasoner
     *         legitimately holds them). Verifies seedCommit == keccak256(seed || salt).
     *         Transitions Challenged → Revealed and opens the oracle window. The oracle
     *         can then independently replay (modelWeightsHash, contextHash, seed) and
     *         post a verdict via oracleSlash. If oracle stays silent past oracleWindow,
     *         anyone can call claimByDefault to dismiss the challenge.
     *
     *         REPLACES the v1.0 `resolveChallenge` function which had a CRITICAL bug
     *         (always dismissed regardless of oracle verdict — see KOM-001).
     */
    function revealSeed(uint256 id, bytes32 seed, bytes32 salt) external;

    /**
     * @notice v1.1 — Anyone may call after oracleWindow elapses on a Revealed attestation.
     *         Dismisses the challenge in the reasoner's favor (default-to-reasoner when
     *         the oracle is silent — but only AFTER the oracle was given a fair window).
     *         Returns reasoner's bond, forfeits challenger's bond to miner rewards pool.
     */
    function claimByDefault(uint256 id) external;

    /**
     * @notice v1.1 — Anyone may call after revealWindow elapses on a Challenged attestation
     *         where the reasoner failed to reveal the seed. Slashes the reasoner for
     *         non-cooperation, awards bounty + bond return to challenger.
     */
    function claimByChallenger(uint256 id) external;

    /**
     * @notice Finalize a pending attestation after the challenge deadline with no challenge.
     *         Returns the reasoner's bond. Anyone can call.
     */
    function finalize(uint256 id) external;

    // ════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════

    function attestations(uint256 id) external view returns (
        uint64 ts,
        bytes32 modelWeightsHash,
        bytes32 contextHash,
        bytes32 seedCommit,
        bytes32 outputHash,
        address reasoner,
        address challenger,
        uint256 reasonerBond,
        uint256 challengerBond,
        uint64 challengeDeadline,
        AttestationStatus status
    );

    function registeredModel(bytes32 modelWeightsHash) external view returns (bool);
    function modelName(bytes32 modelWeightsHash) external view returns (string memory);
    function totalAttestations() external view returns (uint256);
    function totalChallenged() external view returns (uint256);
    function totalSlashed() external view returns (uint256);
}
