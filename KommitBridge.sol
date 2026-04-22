// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ISovereignToken.sol";
import "./interfaces/ICircuitBreaker.sol";
import "./interfaces/IKommitBridge.sol";

error KOMMIT__Paused();
error KOMMIT__ModelNotRegistered();
error KOMMIT__ModelAlreadyRegistered();
error KOMMIT__AttestationNotFound();
error KOMMIT__NotPending();
error KOMMIT__ChallengeWindowClosed();
error KOMMIT__NotChallenged();
error KOMMIT__NotRevealed();              // v1.1
error KOMMIT__RevealWindowClosed();       // v1.1
error KOMMIT__RevealWindowOpen();         // v1.1
error KOMMIT__OracleWindowOpen();         // v1.1
error KOMMIT__SeedMismatch();
error KOMMIT__InsufficientBond();
error KOMMIT__BondTransferFailed();
error KOMMIT__AlreadyFinalized();
error KOMMIT__BondMustBeNonZero();        // v1.1 — KOM-003
error KOMMIT__ChallengerBondTooLow();     // v1.1 — KOM-003

/**
 * @title KommitBridge — Proof of Reasoning (v1.1)
 * @author ANO-YOOFI-AGYEI
 * @notice The second groundbreaking IP in the VPAY Genesis stack.
 *
 *         AttestationBridge proves MATTER: a physical bar of gold exists, this
 *         mass, this purity, sealed, attested by hardware. On-chain minting
 *         follows from physical reality. "No verification, no token."
 *
 *         KommitBridge proves MIND: a specific reasoning output was produced
 *         by a specific model under a specific context and seed. On-chain
 *         attestation follows from verifiable deterministic computation, with
 *         asymmetric fraud proofs (cheap to verify, expensive to forge).
 *         "No commit, no credence."
 *
 *         ────────────────────────────────────────────────────────────────
 *         v1.1 Changelog (Audit Fix 2026-04-22 · Round 3 redeploy)
 *         ────────────────────────────────────────────────────────────────
 *         KOM-001 [CRITICAL] — Split resolveChallenge into revealSeed +
 *           claimByDefault + claimByChallenger. v1.0 always dismissed after a
 *           valid seed reveal, bypassing the oracle entirely. v1.1 introduces
 *           a Revealed status and an oracleWindow that the oracle MUST be
 *           given to slash before default-to-reasoner can fire.
 *
 *         KOM-002 [HIGH] — Constructor no longer auto-grants REASONER_ROLE
 *           and ORACLE_ROLE to the deployer. Admin must explicitly grant.
 *           This eliminates the "deploy and walk away with reasoning power"
 *           footgun and forces ops to think about role provisioning.
 *
 *         KOM-003 [MEDIUM] — setBonds now enforces challengerBond >= reasonerBond
 *           (preserves asymmetric griefing protection) and both > 0.
 *
 *         KOM-004 [MEDIUM] — All token transfers use OZ SafeERC20.
 *
 *         KOM-005 [LOW] — Dedicated setOracleWindow admin function with the
 *           same 60s–7d bound as setWindows.
 *
 *         KOM-006 [LOW] — SeedRevealed event carries (seed, salt, oracleDeadline)
 *           so off-chain replay services can pick up the work to do.
 *
 *         KOM-007 [INFO] — PROTOCOL_ID bumped to "VPAY-GENESIS-KOMMIT-v1.1".
 *
 *         ────────────────────────────────────────────────────────────────
 *         Mechanism (v1.1)
 *         ────────────────────────────────────────────────────────────────
 *         1. Register a model's canonical weights hash (one-time, admin-only).
 *
 *         2. REASONER attests (modelHash, contextHash, seedCommit, outputHash)
 *            before or as the reasoning is returned to the caller.
 *            - seedCommit = keccak256(seed || salt)   (binding, hiding)
 *            - reasoner locks `reasonerBond` $SOV.
 *            - challenge window opens (default 1 hour).
 *
 *         3. Any CHALLENGER may, within the window, post a replayedOutputHash
 *            they claim is correct.
 *            - locks `challengerBond` $SOV.
 *            - status → Challenged. Reveal window opens.
 *
 *         4. Reasoner (or anyone with the seed/salt) reveals via revealSeed().
 *            - if seedCommit doesn't match keccak256(seed||salt) → revert.
 *            - status → Revealed. Oracle window opens.
 *            - SeedRevealed event emitted with (seed, salt) for the oracle.
 *
 *         5a. ORACLE replays (modelHash, contextHash, seed) off-chain and posts
 *             expectedOutputHash via oracleSlash() within oracleWindow:
 *             - if expectedOutputHash == original outputHash → reasoner was
 *               honest, dismiss; challenger bond → MinerRewards pool.
 *             - if expectedOutputHash != original outputHash → reasoner was
 *               lying, slash; bounty → challenger; remainder → MinerRewards.
 *
 *         5b. If oracleWindow elapses without an oracle verdict → anyone can
 *             call claimByDefault() → reasoner wins by default; challenger bond
 *             → MinerRewards pool. (Default-to-reasoner only after oracle was
 *             given a fair window.)
 *
 *         6. If reasoner refuses to reveal seed within revealWindow → anyone
 *            can call claimByChallenger() → reasoner slashed for non-cooperation;
 *            bounty → challenger; remainder → MinerRewards pool.
 *
 *         7. If challenge window elapses with no challenge → finalize() returns
 *            the reasoner's bond.
 *
 *         ────────────────────────────────────────────────────────────────
 *         Why this works (LLM determinism)
 *         ────────────────────────────────────────────────────────────────
 *         Given fixed (model_weights, context, seed), transformer inference is
 *         deterministic up to floating-point non-associativity at the kernel
 *         level. The outputHash commits to the token stream. Replay on any
 *         inference substrate with equivalent numerical semantics reproduces
 *         the same outputHash. Fraud is detectable; honesty is cheap.
 *
 *         ────────────────────────────────────────────────────────────────
 *         Circuit Breaker Integration
 *         ────────────────────────────────────────────────────────────────
 *         Paused globally via the existing VPAY CircuitBreaker. Guardians
 *         (Safe multisig) can freeze reasoning attestations independently of
 *         physical attestations.
 */
contract KommitBridge is IKommitBridge, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant ARCHITECT = "ANO-YOOFI-AGYEI";
    string public constant PROTOCOL_ID = "VPAY-GENESIS-KOMMIT-v1.1";   // v1.1 — KOM-007
    string public constant IP_CODENAME = "KOMMIT";

    bytes32 public constant REASONER_ROLE   = keccak256("REASONER_ROLE");
    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");
    bytes32 public constant ORACLE_ROLE     = keccak256("ORACLE_ROLE");

    // ════════════════════════════════════════
    // EXTERNAL CONTRACTS
    // ════════════════════════════════════════

    ISovereignToken public immutable sovToken;
    ICircuitBreaker public circuitBreaker;
    address public minerRewardsPool;

    // ════════════════════════════════════════
    // CONFIG
    // ════════════════════════════════════════

    /// @notice Bond a reasoner must lock when attesting (default 10 $SOV).
    uint256 public reasonerBondAmount = 10 * 1e18;

    /// @notice Bond a challenger must lock when challenging (default 20 $SOV — asymmetric).
    uint256 public challengerBondAmount = 20 * 1e18;

    /// @notice Bounty to a successful challenger (paid from slashed reasoner bond, in bps of bond).
    uint256 public challengeBountyBps = 5000; // 50% of slashed bond

    /// @notice Challenge window in seconds after attestation (default 1 hour).
    uint256 public challengeWindow = 1 hours;

    /// @notice Grace window for seed reveal after a challenge (default 1 hour).
    uint256 public revealWindow = 1 hours;

    /// @notice v1.1 — Window the oracle has to post a verdict after seed reveal (default 1 hour).
    ///         If oracle stays silent past this window, anyone can call claimByDefault to
    ///         dismiss the challenge in the reasoner's favor.
    uint256 public oracleWindow = 1 hours;

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    mapping(bytes32 => bool)    private _registeredModel;
    mapping(bytes32 => string)  private _modelName;
    mapping(uint256 => Attestation) private _attestations;

    uint256 public nextId;
    uint256 private _totalChallenged;
    uint256 private _totalSlashed;

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    /**
     * @notice v1.1 — Constructor only grants DEFAULT_ADMIN_ROLE to deployer.
     *         REASONER_ROLE and ORACLE_ROLE must be explicitly granted by admin
     *         (typically the Safe multisig after admin migration). KOM-002 fix.
     */
    constructor(
        address _sovToken,
        address _circuitBreaker,
        address _minerRewardsPool
    ) {
        sovToken = ISovereignToken(_sovToken);
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
        minerRewardsPool = _minerRewardsPool;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // v1.1 (KOM-002): NO automatic REASONER_ROLE / ORACLE_ROLE grant. Admin must
        // explicitly grant after deploy + admin migration to Safe.
    }

    // ════════════════════════════════════════
    // MODEL REGISTRY
    // ════════════════════════════════════════

    function registerModel(bytes32 modelWeightsHash, string calldata name)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_registeredModel[modelWeightsHash]) revert KOMMIT__ModelAlreadyRegistered();
        _registeredModel[modelWeightsHash] = true;
        _modelName[modelWeightsHash] = name;
        emit ModelRegistered(modelWeightsHash, name, msg.sender);
    }

    // ════════════════════════════════════════
    // CORE — ATTEST
    // ════════════════════════════════════════

    function attestReasoning(
        bytes32 modelWeightsHash,
        bytes32 contextHash,
        bytes32 seedCommit,
        bytes32 outputHash
    ) external override onlyRole(REASONER_ROLE) nonReentrant returns (uint256 id) {
        if (circuitBreaker.globalPaused()) revert KOMMIT__Paused();
        if (!_registeredModel[modelWeightsHash]) revert KOMMIT__ModelNotRegistered();

        // Lock reasoner's bond (v1.1 — SafeERC20)
        uint256 bond = reasonerBondAmount;
        if (bond > 0) {
            IERC20(address(sovToken)).safeTransferFrom(msg.sender, address(this), bond);
        }

        id = ++nextId;
        uint64 deadline = uint64(block.timestamp + challengeWindow);

        _attestations[id] = Attestation({
            ts:                 uint64(block.timestamp),
            modelWeightsHash:   modelWeightsHash,
            contextHash:        contextHash,
            seedCommit:         seedCommit,
            outputHash:         outputHash,
            reasoner:           msg.sender,
            challenger:         address(0),
            reasonerBond:       bond,
            challengerBond:     0,
            challengeDeadline:  deadline,
            status:             AttestationStatus.Pending
        });

        emit ReasoningAttested(id, msg.sender, modelWeightsHash, contextHash, outputHash, deadline);
    }

    // ════════════════════════════════════════
    // CORE — CHALLENGE
    // ════════════════════════════════════════

    function challenge(uint256 id, bytes32 replayedOutputHash)
        external
        override
        nonReentrant
    {
        if (circuitBreaker.globalPaused()) revert KOMMIT__Paused();

        Attestation storage a = _attestations[id];
        if (a.reasoner == address(0)) revert KOMMIT__AttestationNotFound();
        if (a.status != AttestationStatus.Pending) revert KOMMIT__NotPending();
        if (block.timestamp > a.challengeDeadline) revert KOMMIT__ChallengeWindowClosed();

        // Lock challenger's bond (v1.1 — SafeERC20)
        uint256 bond = challengerBondAmount;
        if (bond > 0) {
            IERC20(address(sovToken)).safeTransferFrom(msg.sender, address(this), bond);
        }

        a.challenger = msg.sender;
        a.challengerBond = bond;
        a.status = AttestationStatus.Challenged;
        // Roll deadline forward to the reveal window.
        a.challengeDeadline = uint64(block.timestamp + revealWindow);

        emit ReasoningChallenged(id, msg.sender, bond);
        emit ChallengerReplayPosted(id, replayedOutputHash);

        _totalChallenged++;
    }

    /// @dev Emitted alongside ReasoningChallenged — carries challenger's replayed hash.
    event ChallengerReplayPosted(uint256 indexed id, bytes32 replayedOutputHash);

    // ════════════════════════════════════════
    // CORE — REVEAL (v1.1, replaces v1.0 resolveChallenge)
    // ════════════════════════════════════════

    /**
     * @notice v1.1 — Reveal seed/salt. Verifies commit, opens the oracle window.
     *         CRITICAL FIX (KOM-001): v1.0's `resolveChallenge` always dismissed
     *         after seed reveal, bypassing the oracle. v1.1 splits this: revealSeed
     *         only transitions to Revealed state — the actual outcome (slash vs
     *         dismiss) is decided by oracleSlash (during the window) or
     *         claimByDefault (after the window).
     */
    function revealSeed(uint256 id, bytes32 seed, bytes32 salt)
        external
        override
        nonReentrant
    {
        if (circuitBreaker.globalPaused()) revert KOMMIT__Paused();

        Attestation storage a = _attestations[id];
        if (a.reasoner == address(0)) revert KOMMIT__AttestationNotFound();
        if (a.status != AttestationStatus.Challenged) revert KOMMIT__NotChallenged();
        if (block.timestamp > a.challengeDeadline) revert KOMMIT__RevealWindowClosed();

        // Verify the seed reveal matches the commit
        bytes32 computed = keccak256(abi.encodePacked(seed, salt));
        if (computed != a.seedCommit) revert KOMMIT__SeedMismatch();

        a.status = AttestationStatus.Revealed;
        // Roll deadline forward to the oracle window. The oracle now has
        // `oracleWindow` seconds to post a verdict via oracleSlash.
        uint64 oracleDeadline = uint64(block.timestamp + oracleWindow);
        a.challengeDeadline = oracleDeadline;

        emit SeedRevealed(id, seed, salt, oracleDeadline);
    }

    // ════════════════════════════════════════
    // CORE — RESOLVE (v1.1)
    // ════════════════════════════════════════

    /**
     * @notice v1.1 — Anyone may call after oracleWindow elapses on a Revealed
     *         attestation. Default-to-reasoner: dismisses challenge, returns
     *         reasoner's bond, forfeits challenger's bond to miner rewards pool.
     *         Only callable AFTER the oracle was given a fair window — this is
     *         the KOM-001 fix: the oracle gets to slash first.
     */
    function claimByDefault(uint256 id) external override nonReentrant {
        Attestation storage a = _attestations[id];
        if (a.reasoner == address(0)) revert KOMMIT__AttestationNotFound();
        if (a.status != AttestationStatus.Revealed) revert KOMMIT__NotRevealed();
        if (block.timestamp <= a.challengeDeadline) revert KOMMIT__OracleWindowOpen();

        _dismissChallenge(id);
    }

    /**
     * @notice v1.1 — Anyone may call after revealWindow elapses on a Challenged
     *         attestation where the reasoner failed to reveal. Slashes reasoner
     *         for non-cooperation: challenger gets bounty + bond return, remainder
     *         to miner rewards pool. Symmetric to claimByDefault but punishing
     *         the reasoner instead of the challenger.
     */
    function claimByChallenger(uint256 id) external override nonReentrant {
        Attestation storage a = _attestations[id];
        if (a.reasoner == address(0)) revert KOMMIT__AttestationNotFound();
        if (a.status != AttestationStatus.Challenged) revert KOMMIT__NotChallenged();
        if (block.timestamp <= a.challengeDeadline) revert KOMMIT__RevealWindowOpen();

        _slashReasoner(id, bytes32(0));
    }

    /**
     * @notice Oracle-driven verdict. Called by the registered replay oracle after
     *         independently executing (modelWeightsHash, contextHash, seed) and
     *         determining whether the attested outputHash is correct.
     *
     *         v1.1: now requires status == Revealed (not Challenged) — the oracle
     *         can only verdict AFTER the seed has been revealed (since it needs
     *         the seed to replay).
     *
     * @param id                  Attestation under challenge.
     * @param expectedOutputHash  Hash the oracle computed via independent replay.
     */
    function oracleSlash(uint256 id, bytes32 expectedOutputHash)
        external
        onlyRole(ORACLE_ROLE)
        nonReentrant
    {
        Attestation storage a = _attestations[id];
        if (a.reasoner == address(0)) revert KOMMIT__AttestationNotFound();
        // v1.1 — must be Revealed (not Challenged); oracle needs the seed
        if (a.status != AttestationStatus.Revealed) revert KOMMIT__NotRevealed();

        // If oracle-computed hash matches original attestation → reasoner was honest
        if (expectedOutputHash == a.outputHash) {
            _dismissChallenge(id);
            return;
        }

        // Otherwise → reasoner was lying, slash.
        _slashReasoner(id, expectedOutputHash);
    }

    // ════════════════════════════════════════
    // INTERNAL — SETTLEMENT
    // ════════════════════════════════════════

    function _slashReasoner(uint256 id, bytes32 expectedOutputHash) internal {
        Attestation storage a = _attestations[id];
        uint256 bounty = (a.reasonerBond * challengeBountyBps) / 10000;
        uint256 poolShare = a.reasonerBond - bounty;

        a.status = AttestationStatus.Slashed;
        _totalSlashed++;

        // Refund + reward challenger (v1.1 — SafeERC20)
        if (a.challengerBond > 0) {
            IERC20(address(sovToken)).safeTransfer(a.challenger, a.challengerBond);
        }
        if (bounty > 0) {
            IERC20(address(sovToken)).safeTransfer(a.challenger, bounty);
        }
        // Remainder to miner rewards pool (public good)
        if (poolShare > 0 && minerRewardsPool != address(0)) {
            IERC20(address(sovToken)).safeTransfer(minerRewardsPool, poolShare);
        }

        emit ReasoningSlashed(id, expectedOutputHash, a.outputHash, a.reasonerBond);
    }

    function _dismissChallenge(uint256 id) internal {
        Attestation storage a = _attestations[id];
        a.status = AttestationStatus.Dismissed;

        // Refund reasoner's bond (v1.1 — SafeERC20)
        if (a.reasonerBond > 0) {
            IERC20(address(sovToken)).safeTransfer(a.reasoner, a.reasonerBond);
        }
        // Forfeit challenger's bond to miner rewards pool (discourages spam)
        if (a.challengerBond > 0 && minerRewardsPool != address(0)) {
            IERC20(address(sovToken)).safeTransfer(minerRewardsPool, a.challengerBond);
        }

        emit ChallengeDismissed(id, a.challengerBond);
    }

    // ════════════════════════════════════════
    // CORE — FINALIZE (no challenge ever filed)
    // ════════════════════════════════════════

    function finalize(uint256 id) external override nonReentrant {
        Attestation storage a = _attestations[id];
        if (a.reasoner == address(0)) revert KOMMIT__AttestationNotFound();
        if (a.status != AttestationStatus.Pending) revert KOMMIT__AlreadyFinalized();
        if (block.timestamp <= a.challengeDeadline) revert KOMMIT__ChallengeWindowClosed();

        a.status = AttestationStatus.Finalized;

        // Refund reasoner's bond (v1.1 — SafeERC20)
        if (a.reasonerBond > 0) {
            IERC20(address(sovToken)).safeTransfer(a.reasoner, a.reasonerBond);
        }

        emit ReasoningFinalized(id);
    }

    // ════════════════════════════════════════
    // ADMIN
    // ════════════════════════════════════════

    /**
     * @notice v1.1 — KOM-003 fix. Both bonds must be > 0, and challenger bond
     *         must be >= reasoner bond to preserve the asymmetric griefing
     *         protection (challenging is more expensive than attesting, so
     *         spam is unprofitable; the bounty makes legitimate challenges
     *         worthwhile).
     */
    function setBonds(uint256 _reasonerBond, uint256 _challengerBond)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_reasonerBond == 0 || _challengerBond == 0) revert KOMMIT__BondMustBeNonZero();
        if (_challengerBond < _reasonerBond) revert KOMMIT__ChallengerBondTooLow();
        reasonerBondAmount = _reasonerBond;
        challengerBondAmount = _challengerBond;
    }

    function setChallengeBountyBps(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bps <= 10000, "Invalid bps");
        challengeBountyBps = _bps;
    }

    function setWindows(uint256 _challengeWindow, uint256 _revealWindow)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_challengeWindow >= 60 && _challengeWindow <= 7 days, "60s-7d");
        require(_revealWindow    >= 60 && _revealWindow    <= 7 days, "60s-7d");
        challengeWindow = _challengeWindow;
        revealWindow    = _revealWindow;
    }

    /**
     * @notice v1.1 — KOM-005 fix. Dedicated setter for oracleWindow.
     *         Same 60s–7d bound as setWindows.
     */
    function setOracleWindow(uint256 _oracleWindow)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_oracleWindow >= 60 && _oracleWindow <= 7 days, "60s-7d");
        oracleWindow = _oracleWindow;
    }

    function setCircuitBreaker(address _breaker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        circuitBreaker = ICircuitBreaker(_breaker);
    }

    function setMinerRewardsPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minerRewardsPool = _pool;
    }

    // ════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════

    function attestations(uint256 id) external view override returns (
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
    ) {
        Attestation storage a = _attestations[id];
        return (
            a.ts,
            a.modelWeightsHash,
            a.contextHash,
            a.seedCommit,
            a.outputHash,
            a.reasoner,
            a.challenger,
            a.reasonerBond,
            a.challengerBond,
            a.challengeDeadline,
            a.status
        );
    }

    function registeredModel(bytes32 modelWeightsHash) external view override returns (bool) {
        return _registeredModel[modelWeightsHash];
    }

    function modelName(bytes32 modelWeightsHash) external view override returns (string memory) {
        return _modelName[modelWeightsHash];
    }

    function totalAttestations() external view override returns (uint256) {
        return nextId;
    }

    function totalChallenged() external view override returns (uint256) {
        return _totalChallenged;
    }

    function totalSlashed() external view override returns (uint256) {
        return _totalSlashed;
    }

    /**
     * @notice Convenience: derive the canonical seedCommit from a (seed, salt) pair.
     *         Clients should compute this off-chain; provided here for parity.
     */
    function computeSeedCommit(bytes32 seed, bytes32 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(seed, salt));
    }
}
