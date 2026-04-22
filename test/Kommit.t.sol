// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../KommitBridge.sol";
import "../interfaces/IKommitBridge.sol";
import "../interfaces/ISovereignToken.sol";
import "../interfaces/ICircuitBreaker.sol";

/*//////////////////////////////////////////////////////////////
                        TEST DOUBLES
//////////////////////////////////////////////////////////////*/

/// @notice Minimal $SOV mock — same shape as MockSovereignToken in
///         VPAYGenesis.integration.t.sol so behavior matches across the suite.
contract MockSov is ISovereignToken {
    string public constant name = "Sovereign Token";
    string public constant symbol = "SOV";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    mapping(bytes32 => mapping(address => bool)) private _roles;

    constructor() {
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
        _roles[MINTER_ROLE][msg.sender] = true;
        _roles[BURNER_ROLE][msg.sender] = true;
    }

    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function allowance(address o, address s) external view returns (uint256) { return _allowances[o][s]; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "Insufficient");
        require(_allowances[from][msg.sender] >= amount, "Not approved");
        _balances[from] -= amount;
        _allowances[from][msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        require(_roles[MINTER_ROLE][msg.sender], "Not minter");
        require(_totalSupply + amount <= MAX_SUPPLY, "Cap exceeded");
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function burn(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "Insufficient");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        require(_balances[from] >= amount, "Insufficient");
        require(_allowances[from][msg.sender] >= amount, "Not approved");
        _balances[from] -= amount;
        _allowances[from][msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "Not admin");
        _roles[role][account] = true;
    }

    /// @dev Test helper — bypass MINTER_ROLE checks to seed accounts.
    function mintDirect(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
    }
}

/// @notice Tiny CircuitBreaker double — the real one needs role setup we don't
///         care about here; we only need to flip globalPaused.
contract MockCB is ICircuitBreaker {
    bool public paused;
    function globalPaused() external view returns (bool) { return paused; }
    function nodePaused(bytes32) external pure returns (bool) { return false; }
    function setPaused(bool p) external { paused = p; }
}

/*//////////////////////////////////////////////////////////////
                        BASE FIXTURE
//////////////////////////////////////////////////////////////*/

abstract contract KommitFixture is Test {
    // Actors
    address admin     = address(this);
    address reasoner  = address(0xBEEF01);
    address reasoner2 = address(0xBEEF02);
    address challenger = address(0xC1A1);
    address challenger2 = address(0xC1A2);
    address oracle     = address(0x07AC1E);
    address minerPool  = address(0x70011);
    address randomUser = address(0xBADBAD);

    // Contracts
    MockSov  sov;
    MockCB   cb;
    KommitBridge bridge;

    // Test data
    bytes32 constant MODEL_HASH  = keccak256("hermes-v2-zeus-orchestrator");
    bytes32 constant MODEL_HASH2 = keccak256("pantheon-plutus-flow");
    bytes32 constant CONTEXT     = keccak256("prompt+state+tools");
    bytes32 constant OUTPUT      = keccak256("the-zeus-said-trade");
    bytes32 constant SEED        = bytes32(uint256(0x1234567890));
    bytes32 constant SALT        = bytes32(uint256(0xDEADBEEFCAFE));

    function setUp() public virtual {
        sov = new MockSov();
        cb  = new MockCB();
        bridge = new KommitBridge(address(sov), address(cb), minerPool);

        // v1.1 (KOM-002): Constructor only grants DEFAULT_ADMIN_ROLE.
        // Admin must explicitly grant REASONER_ROLE and ORACLE_ROLE — we test
        // that role grants work and seed the test fixture in one step.
        bridge.grantRole(bridge.REASONER_ROLE(), reasoner);
        bridge.grantRole(bridge.REASONER_ROLE(), reasoner2);
        bridge.grantRole(bridge.ORACLE_ROLE(), oracle);

        // Register canonical model
        bridge.registerModel(MODEL_HASH, "hermes-v2-zeus-orchestrator");

        // Fund reasoners + challengers with $SOV
        sov.mintDirect(reasoner,    1_000e18);
        sov.mintDirect(reasoner2,   1_000e18);
        sov.mintDirect(challenger,  1_000e18);
        sov.mintDirect(challenger2, 1_000e18);

        // Pre-approve max allowance to the bridge
        vm.prank(reasoner);    sov.approve(address(bridge), type(uint256).max);
        vm.prank(reasoner2);   sov.approve(address(bridge), type(uint256).max);
        vm.prank(challenger);  sov.approve(address(bridge), type(uint256).max);
        vm.prank(challenger2); sov.approve(address(bridge), type(uint256).max);

        vm.label(reasoner,    "Reasoner");
        vm.label(reasoner2,   "Reasoner2");
        vm.label(challenger,  "Challenger");
        vm.label(challenger2, "Challenger2");
        vm.label(oracle,      "Oracle");
        vm.label(minerPool,   "MinerPool");
    }

    // Helpers
    function _commit(bytes32 seed, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(seed, salt));
    }

    function _attest() internal returns (uint256 id) {
        vm.prank(reasoner);
        id = bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function _attestAs(address who, bytes32 model, bytes32 ctx, bytes32 seed, bytes32 salt, bytes32 out)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = bridge.attestReasoning(model, ctx, _commit(seed, salt), out);
    }

    /// @dev Convenience: attest → challenge → reveal (puts attestation in Revealed
    ///      state, ready for oracle verdict or claimByDefault).
    function _attestChallengeReveal() internal returns (uint256 id) {
        id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("wrong-replay"));
        bridge.revealSeed(id, SEED, SALT);
    }
}

/*//////////////////////////////////////////////////////////////
                    HAPPY PATH — UNIT TESTS
//////////////////////////////////////////////////////////////*/

contract KommitBridge_HappyPath_Test is KommitFixture {
    function test_DeploymentConstants() public view {
        assertEq(bridge.ARCHITECT(),   "ANO-YOOFI-AGYEI");
        assertEq(bridge.PROTOCOL_ID(), "VPAY-GENESIS-KOMMIT-v1.1");
        assertEq(bridge.IP_CODENAME(), "KOMMIT");
        assertEq(address(bridge.sovToken()),   address(sov));
        assertEq(address(bridge.circuitBreaker()), address(cb));
        assertEq(bridge.minerRewardsPool(),    minerPool);
        assertEq(bridge.reasonerBondAmount(),   10e18);
        assertEq(bridge.challengerBondAmount(), 20e18);
        assertEq(bridge.challengeBountyBps(),   5000);
        assertEq(bridge.challengeWindow(),      1 hours);
        assertEq(bridge.revealWindow(),         1 hours);
        assertEq(bridge.oracleWindow(),         1 hours); // v1.1
    }

    /// @notice v1.1 (KOM-002): Constructor only grants DEFAULT_ADMIN_ROLE — not
    ///         REASONER_ROLE or ORACLE_ROLE. Validates the deploy-time footgun fix.
    function test_Constructor_OnlyGrantsAdminRole() public {
        // Fresh deploy with no fixture role grants
        KommitBridge fresh = new KommitBridge(address(sov), address(cb), minerPool);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(fresh.hasRole(fresh.REASONER_ROLE(),    address(this)));
        assertFalse(fresh.hasRole(fresh.ORACLE_ROLE(),      address(this)));
    }

    function test_RegisterModel_HappyPath() public {
        assertFalse(bridge.registeredModel(MODEL_HASH2));
        bridge.registerModel(MODEL_HASH2, "pantheon-plutus");
        assertTrue(bridge.registeredModel(MODEL_HASH2));
        assertEq(bridge.modelName(MODEL_HASH2), "pantheon-plutus");
    }

    function test_AttestReasoning_LocksReasonerBond() public {
        uint256 reasonerBefore = sov.balanceOf(reasoner);
        uint256 bridgeBefore   = sov.balanceOf(address(bridge));

        uint256 id = _attest();

        assertEq(id, 1);
        assertEq(bridge.totalAttestations(), 1);
        assertEq(sov.balanceOf(reasoner),       reasonerBefore - 10e18);
        assertEq(sov.balanceOf(address(bridge)), bridgeBefore   + 10e18);

        (uint64 ts, , , , bytes32 outputHash, address r, address c, uint256 rBond, uint256 cBond, uint64 deadline, IKommitBridge.AttestationStatus status)
            = bridge.attestations(id);
        assertEq(ts,        block.timestamp);
        assertEq(outputHash, OUTPUT);
        assertEq(r,          reasoner);
        assertEq(c,          address(0));
        assertEq(rBond,      10e18);
        assertEq(cBond,      0);
        assertEq(deadline,   block.timestamp + 1 hours);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Pending));
    }

    function test_AttestReasoning_MonotonicId() public {
        uint256 a = _attest();
        uint256 b = _attestAs(reasoner2, MODEL_HASH, CONTEXT, SEED, SALT, OUTPUT);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(bridge.totalAttestations(), 2);
    }

    function test_Challenge_LocksChallengerBondAndExtendsDeadline() public {
        uint256 id = _attest();
        uint256 cBefore = sov.balanceOf(challenger);
        uint256 bBefore = sov.balanceOf(address(bridge));

        uint256 t0 = block.timestamp;
        bytes32 replayHash = keccak256("a-different-output");
        vm.prank(challenger);
        bridge.challenge(id, replayHash);

        assertEq(sov.balanceOf(challenger),       cBefore - 20e18);
        assertEq(sov.balanceOf(address(bridge)),  bBefore + 20e18);
        assertEq(bridge.totalChallenged(),        1);

        (, , , , , , address c, , uint256 cBond, uint64 deadline, IKommitBridge.AttestationStatus status)
            = bridge.attestations(id);
        assertEq(c,    challenger);
        assertEq(cBond, 20e18);
        assertEq(deadline, t0 + 1 hours); // deadline reset to now + revealWindow
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Challenged));
    }

    /// @notice v1.1: revealSeed transitions Challenged → Revealed and rolls the
    ///         deadline forward to now + oracleWindow. Does NOT settle.
    function test_RevealSeed_TransitionsToRevealed() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("wrong-replay"));

        // No bond movement on reveal — only state + deadline change.
        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);
        uint256 bridgeBefore     = sov.balanceOf(address(bridge));

        uint256 t0 = block.timestamp;
        bridge.revealSeed(id, SEED, SALT); // anyone can call

        // No tokens move
        assertEq(sov.balanceOf(reasoner),        reasonerBefore);
        assertEq(sov.balanceOf(challenger),      challengerBefore);
        assertEq(sov.balanceOf(minerPool),       poolBefore);
        assertEq(sov.balanceOf(address(bridge)), bridgeBefore);

        // State machine moved + deadline rolled to oracle window
        (, , , , , , , , , uint64 deadline, IKommitBridge.AttestationStatus status)
            = bridge.attestations(id);
        assertEq(deadline, t0 + 1 hours);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Revealed));
    }

    /// @notice v1.1 KOM-001 fix: claimByDefault settles ONLY after the oracle
    ///         was given a fair window to verdict. Default-to-reasoner.
    function test_ClaimByDefault_DismissesAfterOracleWindow() public {
        uint256 id = _attestChallengeReveal();

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        // Warp past oracle window
        vm.warp(block.timestamp + 1 hours + 1);
        bridge.claimByDefault(id); // anyone can call

        // Reasoner refunded; challenger forfeit goes to miner pool
        assertEq(sov.balanceOf(reasoner),   reasonerBefore   + 10e18);
        assertEq(sov.balanceOf(challenger), challengerBefore + 0);
        assertEq(sov.balanceOf(minerPool),  poolBefore       + 20e18);

        (, , , , , , , , , , IKommitBridge.AttestationStatus status) = bridge.attestations(id);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Dismissed));
    }

    /// @notice v1.1: claimByChallenger slashes a non-cooperative reasoner who
    ///         refused to reveal the seed within the reveal window.
    function test_ClaimByChallenger_SlashesNonCooperator() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("any-replay"));

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        // Reasoner stays silent past reveal window
        vm.warp(block.timestamp + 1 hours + 1);
        bridge.claimByChallenger(id); // anyone can call

        // Reasoner slashed (no refund); challenger gets bond back + bounty (50% of 10 = 5)
        // Pool gets remainder (10 - 5 = 5)
        assertEq(sov.balanceOf(reasoner),   reasonerBefore);
        assertEq(sov.balanceOf(challenger), challengerBefore + 20e18 + 5e18);
        assertEq(sov.balanceOf(minerPool),  poolBefore       + 5e18);

        (, , , , , , , , , , IKommitBridge.AttestationStatus status) = bridge.attestations(id);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Slashed));
        assertEq(bridge.totalSlashed(), 1);
    }

    /// @notice v1.1: oracleSlash on a Revealed attestation with the matching
    ///         output hash dismisses the challenge in the reasoner's favor.
    function test_OracleSlash_DismissesWhenChallengerWrong() public {
        uint256 id = _attestChallengeReveal();

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        // Oracle replays and finds reasoner was telling the truth
        vm.prank(oracle);
        bridge.oracleSlash(id, OUTPUT);

        assertEq(sov.balanceOf(reasoner),   reasonerBefore   + 10e18);
        assertEq(sov.balanceOf(challenger), challengerBefore + 0);
        assertEq(sov.balanceOf(minerPool),  poolBefore       + 20e18);

        (, , , , , , , , , , IKommitBridge.AttestationStatus status) = bridge.attestations(id);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Dismissed));
    }

    /// @notice v1.1: oracleSlash on a Revealed attestation with a different
    ///         output hash slashes the reasoner (the hash mismatch is the proof).
    function test_OracleSlash_SlashesReasonerWhenWrong() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("the-true-output-i-replayed"));
        bridge.revealSeed(id, SEED, SALT);

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        bytes32 truth = keccak256("the-true-output-i-replayed");
        vm.prank(oracle);
        bridge.oracleSlash(id, truth);

        // Bounty: 50% of reasoner's 10 SOV bond = 5 SOV to challenger
        // Challenger also gets their 20 SOV bond back
        // Pool: remaining 5 SOV
        // Reasoner: receives nothing (slashed)
        assertEq(sov.balanceOf(reasoner),   reasonerBefore);
        assertEq(sov.balanceOf(challenger), challengerBefore + 20e18 + 5e18);
        assertEq(sov.balanceOf(minerPool),  poolBefore       + 5e18);

        (, , , , , , , , , , IKommitBridge.AttestationStatus status) = bridge.attestations(id);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Slashed));
        assertEq(bridge.totalSlashed(), 1);
    }

    function test_Finalize_RefundsReasonerAfterWindow() public {
        uint256 id = _attest();
        uint256 reasonerBefore = sov.balanceOf(reasoner);

        vm.warp(block.timestamp + 1 hours + 1);
        bridge.finalize(id);

        assertEq(sov.balanceOf(reasoner), reasonerBefore + 10e18);

        (, , , , , , , , , , IKommitBridge.AttestationStatus status) = bridge.attestations(id);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Finalized));
    }

    function test_ComputeSeedCommit_MatchesInternal() public view {
        bytes32 expected = keccak256(abi.encodePacked(SEED, SALT));
        assertEq(bridge.computeSeedCommit(SEED, SALT), expected);
    }
}

/*//////////////////////////////////////////////////////////////
                    REVERT PATHS — UNIT TESTS
//////////////////////////////////////////////////////////////*/

contract KommitBridge_Reverts_Test is KommitFixture {
    function test_RegisterModel_Revert_NotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        bridge.registerModel(MODEL_HASH2, "x");
    }

    function test_RegisterModel_Revert_AlreadyRegistered() public {
        vm.expectRevert(KOMMIT__ModelAlreadyRegistered.selector);
        bridge.registerModel(MODEL_HASH, "duplicate");
    }

    function test_AttestReasoning_Revert_NotReasoner() public {
        vm.prank(randomUser);
        vm.expectRevert();
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_AttestReasoning_Revert_Paused() public {
        cb.setPaused(true);
        vm.prank(reasoner);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_AttestReasoning_Revert_ModelNotRegistered() public {
        vm.prank(reasoner);
        vm.expectRevert(KOMMIT__ModelNotRegistered.selector);
        bridge.attestReasoning(MODEL_HASH2, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_AttestReasoning_Revert_BondNotApproved() public {
        // Strip approval on reasoner2
        vm.prank(reasoner2);
        sov.approve(address(bridge), 0);

        vm.prank(reasoner2);
        vm.expectRevert(); // SafeERC20 reverts via low-level call check
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_Challenge_Revert_AttestationNotFound() public {
        vm.prank(challenger);
        vm.expectRevert(KOMMIT__AttestationNotFound.selector);
        bridge.challenge(999, keccak256("x"));
    }

    function test_Challenge_Revert_NotPending_AlreadyFinalized() public {
        uint256 id = _attest();
        vm.warp(block.timestamp + 1 hours + 1);
        bridge.finalize(id);

        vm.prank(challenger);
        vm.expectRevert(KOMMIT__NotPending.selector);
        bridge.challenge(id, keccak256("x"));
    }

    function test_Challenge_Revert_WindowClosed() public {
        uint256 id = _attest();
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(challenger);
        vm.expectRevert(KOMMIT__ChallengeWindowClosed.selector);
        bridge.challenge(id, keccak256("x"));
    }

    function test_Challenge_Revert_Paused() public {
        uint256 id = _attest();
        cb.setPaused(true);

        vm.prank(challenger);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.challenge(id, keccak256("x"));
    }

    function test_Challenge_Revert_BondNotApproved() public {
        uint256 id = _attest();
        vm.prank(challenger2);
        sov.approve(address(bridge), 0);

        vm.prank(challenger2);
        vm.expectRevert();
        bridge.challenge(id, keccak256("x"));
    }

    // ────────────────────────────────────────
    // v1.1 — revealSeed reverts
    // ────────────────────────────────────────

    function test_RevealSeed_Revert_AttestationNotFound() public {
        vm.expectRevert(KOMMIT__AttestationNotFound.selector);
        bridge.revealSeed(999, SEED, SALT);
    }

    function test_RevealSeed_Revert_NotChallenged_StillPending() public {
        uint256 id = _attest();
        vm.expectRevert(KOMMIT__NotChallenged.selector);
        bridge.revealSeed(id, SEED, SALT);
    }

    function test_RevealSeed_Revert_NotChallenged_AlreadyRevealed() public {
        uint256 id = _attestChallengeReveal();
        vm.expectRevert(KOMMIT__NotChallenged.selector);
        bridge.revealSeed(id, SEED, SALT); // already Revealed
    }

    function test_RevealSeed_Revert_SeedMismatch() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));

        vm.expectRevert(KOMMIT__SeedMismatch.selector);
        bridge.revealSeed(id, bytes32("wrong-seed"), SALT);
    }

    function test_RevealSeed_Revert_RevealWindowClosed() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));

        vm.warp(block.timestamp + 1 hours + 1); // past reveal window
        vm.expectRevert(KOMMIT__RevealWindowClosed.selector);
        bridge.revealSeed(id, SEED, SALT);
    }

    function test_RevealSeed_Revert_Paused() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));

        cb.setPaused(true);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.revealSeed(id, SEED, SALT);
    }

    // ────────────────────────────────────────
    // v1.1 — claimByDefault reverts
    // ────────────────────────────────────────

    function test_ClaimByDefault_Revert_AttestationNotFound() public {
        vm.expectRevert(KOMMIT__AttestationNotFound.selector);
        bridge.claimByDefault(999);
    }

    function test_ClaimByDefault_Revert_NotRevealed_StillPending() public {
        uint256 id = _attest();
        vm.expectRevert(KOMMIT__NotRevealed.selector);
        bridge.claimByDefault(id);
    }

    function test_ClaimByDefault_Revert_NotRevealed_StillChallenged() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.expectRevert(KOMMIT__NotRevealed.selector);
        bridge.claimByDefault(id);
    }

    function test_ClaimByDefault_Revert_OracleWindowOpen() public {
        uint256 id = _attestChallengeReveal();
        // oracle window still open
        vm.expectRevert(KOMMIT__OracleWindowOpen.selector);
        bridge.claimByDefault(id);
    }

    // ────────────────────────────────────────
    // v1.1 — claimByChallenger reverts
    // ────────────────────────────────────────

    function test_ClaimByChallenger_Revert_AttestationNotFound() public {
        vm.expectRevert(KOMMIT__AttestationNotFound.selector);
        bridge.claimByChallenger(999);
    }

    function test_ClaimByChallenger_Revert_NotChallenged() public {
        uint256 id = _attest();
        vm.expectRevert(KOMMIT__NotChallenged.selector);
        bridge.claimByChallenger(id);
    }

    function test_ClaimByChallenger_Revert_RevealWindowOpen() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.expectRevert(KOMMIT__RevealWindowOpen.selector);
        bridge.claimByChallenger(id);
    }

    function test_ClaimByChallenger_Revert_AlreadyRevealed() public {
        uint256 id = _attestChallengeReveal();
        // Revealed already — claimByChallenger only valid in Challenged status
        vm.expectRevert(KOMMIT__NotChallenged.selector);
        bridge.claimByChallenger(id);
    }

    // ────────────────────────────────────────
    // v1.1 — oracleSlash reverts (now requires Revealed, not Challenged)
    // ────────────────────────────────────────

    function test_OracleSlash_Revert_NotOracle() public {
        uint256 id = _attestChallengeReveal();

        vm.prank(randomUser);
        vm.expectRevert();
        bridge.oracleSlash(id, OUTPUT);
    }

    function test_OracleSlash_Revert_NotRevealed_Pending() public {
        uint256 id = _attest();
        vm.prank(oracle);
        vm.expectRevert(KOMMIT__NotRevealed.selector);
        bridge.oracleSlash(id, OUTPUT);
    }

    function test_OracleSlash_Revert_NotRevealed_StillChallenged() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.prank(oracle);
        vm.expectRevert(KOMMIT__NotRevealed.selector);
        bridge.oracleSlash(id, OUTPUT);
    }

    function test_OracleSlash_Revert_AlreadySettled() public {
        uint256 id = _attestChallengeReveal();
        vm.prank(oracle);
        bridge.oracleSlash(id, OUTPUT); // Dismissed

        // Second slash attempt — no longer Revealed
        vm.prank(oracle);
        vm.expectRevert(KOMMIT__NotRevealed.selector);
        bridge.oracleSlash(id, OUTPUT);
    }

    // ────────────────────────────────────────
    // Finalize reverts
    // ────────────────────────────────────────

    function test_Finalize_Revert_AttestationNotFound() public {
        vm.expectRevert(KOMMIT__AttestationNotFound.selector);
        bridge.finalize(999);
    }

    function test_Finalize_Revert_AlreadyFinalized() public {
        uint256 id = _attest();
        vm.warp(block.timestamp + 1 hours + 1);
        bridge.finalize(id);

        vm.expectRevert(KOMMIT__AlreadyFinalized.selector);
        bridge.finalize(id);
    }

    function test_Finalize_Revert_WindowStillOpen() public {
        uint256 id = _attest();
        vm.expectRevert(KOMMIT__ChallengeWindowClosed.selector);
        bridge.finalize(id);
    }

    function test_Finalize_Revert_AfterChallenge() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(KOMMIT__AlreadyFinalized.selector);
        bridge.finalize(id);
    }
}

/*//////////////////////////////////////////////////////////////
                    ADMIN — PARAMETER CHANGES
//////////////////////////////////////////////////////////////*/

contract KommitBridge_Admin_Test is KommitFixture {
    function test_SetBonds_OnlyAdmin() public {
        // v1.1 KOM-003: challenger must be >= reasoner
        bridge.setBonds(50e18, 100e18);
        assertEq(bridge.reasonerBondAmount(),   50e18);
        assertEq(bridge.challengerBondAmount(), 100e18);
    }

    function test_SetBonds_AllowsEqualBonds() public {
        // v1.1 KOM-003: challenger >= reasoner allows equality
        bridge.setBonds(15e18, 15e18);
        assertEq(bridge.reasonerBondAmount(),   15e18);
        assertEq(bridge.challengerBondAmount(), 15e18);
    }

    function test_SetBonds_Revert_NotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        bridge.setBonds(50e18, 100e18);
    }

    function test_SetBonds_Revert_ReasonerZero() public {
        // v1.1 KOM-003: zero bonds banned
        vm.expectRevert(KOMMIT__BondMustBeNonZero.selector);
        bridge.setBonds(0, 10e18);
    }

    function test_SetBonds_Revert_ChallengerZero() public {
        vm.expectRevert(KOMMIT__BondMustBeNonZero.selector);
        bridge.setBonds(10e18, 0);
    }

    function test_SetBonds_Revert_ChallengerBelowReasoner() public {
        // v1.1 KOM-003: challenger < reasoner banned (preserves anti-griefing)
        vm.expectRevert(KOMMIT__ChallengerBondTooLow.selector);
        bridge.setBonds(20e18, 10e18);
    }

    function test_SetChallengeBountyBps_OnlyAdmin() public {
        bridge.setChallengeBountyBps(7500);
        assertEq(bridge.challengeBountyBps(), 7500);
    }

    function test_SetChallengeBountyBps_Revert_OutOfBounds() public {
        vm.expectRevert(bytes("Invalid bps"));
        bridge.setChallengeBountyBps(10001);
    }

    function test_SetChallengeBountyBps_AcceptsZero() public {
        bridge.setChallengeBountyBps(0);
        assertEq(bridge.challengeBountyBps(), 0);
    }

    function test_SetChallengeBountyBps_AcceptsMax() public {
        bridge.setChallengeBountyBps(10000);
        assertEq(bridge.challengeBountyBps(), 10000);
    }

    function test_SetWindows_HappyPath() public {
        bridge.setWindows(2 hours, 30 minutes);
        assertEq(bridge.challengeWindow(), 2 hours);
        assertEq(bridge.revealWindow(),    30 minutes);
    }

    function test_SetWindows_Revert_BelowMin() public {
        vm.expectRevert(bytes("60s-7d"));
        bridge.setWindows(59, 1 hours);
    }

    function test_SetWindows_Revert_AboveMax() public {
        vm.expectRevert(bytes("60s-7d"));
        bridge.setWindows(7 days + 1, 1 hours);
    }

    function test_SetWindows_Revert_RevealBelowMin() public {
        vm.expectRevert(bytes("60s-7d"));
        bridge.setWindows(1 hours, 30);
    }

    // v1.1 — setOracleWindow (KOM-005)
    function test_SetOracleWindow_HappyPath() public {
        bridge.setOracleWindow(45 minutes);
        assertEq(bridge.oracleWindow(), 45 minutes);
    }

    function test_SetOracleWindow_Revert_NotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        bridge.setOracleWindow(45 minutes);
    }

    function test_SetOracleWindow_Revert_BelowMin() public {
        vm.expectRevert(bytes("60s-7d"));
        bridge.setOracleWindow(59);
    }

    function test_SetOracleWindow_Revert_AboveMax() public {
        vm.expectRevert(bytes("60s-7d"));
        bridge.setOracleWindow(7 days + 1);
    }

    function test_SetOracleWindow_AppliesToNextReveal() public {
        bridge.setOracleWindow(2 hours);

        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));

        uint256 t0 = block.timestamp;
        bridge.revealSeed(id, SEED, SALT);

        (, , , , , , , , , uint64 deadline, ) = bridge.attestations(id);
        assertEq(deadline, t0 + 2 hours);
    }

    function test_SetCircuitBreaker_OnlyAdmin() public {
        MockCB newCB = new MockCB();
        bridge.setCircuitBreaker(address(newCB));
        assertEq(address(bridge.circuitBreaker()), address(newCB));
    }

    function test_SetMinerRewardsPool_OnlyAdmin() public {
        address newPool = address(0xFEED);
        bridge.setMinerRewardsPool(newPool);
        assertEq(bridge.minerRewardsPool(), newPool);
    }

    function test_RoleAdmin_RevokeStopsAttestation() public {
        bridge.revokeRole(bridge.REASONER_ROLE(), reasoner);
        vm.prank(reasoner);
        vm.expectRevert();
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_RoleGrant_OracleCanSlashAfterGrant() public {
        // v1.1 KOM-002: ORACLE_ROLE not auto-granted; verify post-grant flow works
        address newOracle = address(0x0BADCAFE);
        bridge.grantRole(bridge.ORACLE_ROLE(), newOracle);

        uint256 id = _attestChallengeReveal();
        vm.prank(newOracle);
        bridge.oracleSlash(id, OUTPUT); // dismiss-style slash succeeds
    }
}

/*//////////////////////////////////////////////////////////////
                    BOND ECONOMICS — ASYMMETRY
//////////////////////////////////////////////////////////////*/

contract KommitBridge_BondEconomics_Test is KommitFixture {
    function test_AsymmetricBonds_PreventGriefing() public view {
        // Challenger bond > reasoner bond by design (anti-griefing)
        assertGt(bridge.challengerBondAmount(), bridge.reasonerBondAmount());
    }

    function test_SlashConservation_AllSOVAccountedFor() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("truth"));
        bridge.revealSeed(id, SEED, SALT);

        uint256 totalLockedBefore = sov.balanceOf(address(bridge));
        // 10 (reasoner) + 20 (challenger) = 30 SOV in flight
        assertEq(totalLockedBefore, 30e18);

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        vm.prank(oracle);
        bridge.oracleSlash(id, keccak256("truth"));

        // Sum of payouts must equal what was locked
        uint256 reasonerOut   = sov.balanceOf(reasoner)   - reasonerBefore;   // 0
        uint256 challengerOut = sov.balanceOf(challenger) - challengerBefore; // 25
        uint256 poolOut       = sov.balanceOf(minerPool)  - poolBefore;       // 5

        assertEq(reasonerOut + challengerOut + poolOut, 30e18);
        assertEq(sov.balanceOf(address(bridge)), 0); // bridge fully drained
    }

    function test_DismissalConservation_AllSOVAccountedFor() public {
        uint256 id = _attestChallengeReveal();

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        vm.prank(oracle);
        bridge.oracleSlash(id, OUTPUT);

        uint256 reasonerOut   = sov.balanceOf(reasoner)   - reasonerBefore;
        uint256 challengerOut = sov.balanceOf(challenger) - challengerBefore;
        uint256 poolOut       = sov.balanceOf(minerPool)  - poolBefore;

        // Reasoner gets bond back (10), challenger forfeits (0), pool gets challenger's 20
        assertEq(reasonerOut,   10e18);
        assertEq(challengerOut, 0);
        assertEq(poolOut,       20e18);
        assertEq(reasonerOut + challengerOut + poolOut, 30e18);
        assertEq(sov.balanceOf(address(bridge)), 0);
    }

    /// @notice v1.1: claimByDefault path — same accounting as oracle-driven dismiss.
    function test_DefaultDismissalConservation_AllSOVAccountedFor() public {
        uint256 id = _attestChallengeReveal();

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        vm.warp(block.timestamp + 1 hours + 1);
        bridge.claimByDefault(id);

        assertEq(sov.balanceOf(reasoner)   - reasonerBefore,   10e18);
        assertEq(sov.balanceOf(challenger) - challengerBefore, 0);
        assertEq(sov.balanceOf(minerPool)  - poolBefore,       20e18);
        assertEq(sov.balanceOf(address(bridge)), 0);
    }

    /// @notice v1.1: claimByChallenger path — slash-reasoner accounting under non-cooperation.
    function test_NonCooperationSlashConservation_AllSOVAccountedFor() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("anything"));

        uint256 reasonerBefore   = sov.balanceOf(reasoner);
        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        vm.warp(block.timestamp + 1 hours + 1);
        bridge.claimByChallenger(id);

        // Reasoner: slashed (0), Challenger: bond (20) + bounty (5), Pool: 5
        uint256 reasonerOut   = sov.balanceOf(reasoner)   - reasonerBefore;
        uint256 challengerOut = sov.balanceOf(challenger) - challengerBefore;
        uint256 poolOut       = sov.balanceOf(minerPool)  - poolBefore;

        assertEq(reasonerOut,   0);
        assertEq(challengerOut, 25e18);
        assertEq(poolOut,       5e18);
        assertEq(reasonerOut + challengerOut + poolOut, 30e18);
        assertEq(sov.balanceOf(address(bridge)), 0);
    }

    function test_FinalizeConservation_OnlyReasonerBondReturned() public {
        uint256 id = _attest();
        uint256 reasonerBefore = sov.balanceOf(reasoner);
        uint256 poolBefore     = sov.balanceOf(minerPool);

        vm.warp(block.timestamp + 1 hours + 1);
        bridge.finalize(id);

        assertEq(sov.balanceOf(reasoner)  - reasonerBefore, 10e18);
        assertEq(sov.balanceOf(minerPool) - poolBefore,     0);
        assertEq(sov.balanceOf(address(bridge)), 0);
    }
}

/*//////////////////////////////////////////////////////////////
                    FUZZING
//////////////////////////////////////////////////////////////*/

contract KommitBridge_Fuzz_Test is KommitFixture {
    function testFuzz_AttestReasoning_AcceptsAnyHashes(
        bytes32 ctx,
        bytes32 seedCommit,
        bytes32 outputHash
    ) public {
        vm.prank(reasoner);
        uint256 id = bridge.attestReasoning(MODEL_HASH, ctx, seedCommit, outputHash);
        (, , bytes32 storedCtx, bytes32 storedCommit, bytes32 storedOut, , , , , , ) = bridge.attestations(id);
        assertEq(storedCtx,    ctx);
        assertEq(storedCommit, seedCommit);
        assertEq(storedOut,    outputHash);
    }

    /// @notice v1.1: revealSeed succeeds with any (seed, salt) whose commit matches.
    ///         Then oracle dismissal with matching outputHash drives Dismissed state.
    function testFuzz_SeedCommit_BindsExactly(bytes32 seed, bytes32 salt) public {
        bytes32 commit = bridge.computeSeedCommit(seed, salt);
        vm.prank(reasoner);
        uint256 id = bridge.attestReasoning(MODEL_HASH, CONTEXT, commit, OUTPUT);

        vm.prank(challenger);
        bridge.challenge(id, keccak256("anything"));

        // Correct seed/salt revealsSeed
        bridge.revealSeed(id, seed, salt);

        // Oracle endorses the original output → dismiss
        vm.prank(oracle);
        bridge.oracleSlash(id, OUTPUT);

        (, , , , , , , , , , IKommitBridge.AttestationStatus status) = bridge.attestations(id);
        assertEq(uint8(status), uint8(IKommitBridge.AttestationStatus.Dismissed));
    }

    /// @notice v1.1: revealSeed rejects any (seed, salt) pair whose commit
    ///         does not match the committed value.
    function testFuzz_SeedCommit_RejectsAnyOtherSaltOrSeed(
        bytes32 seed,
        bytes32 salt,
        bytes32 wrongSeed,
        bytes32 wrongSalt
    ) public {
        vm.assume(wrongSeed != seed || wrongSalt != salt);
        bytes32 commit = bridge.computeSeedCommit(seed, salt);

        vm.prank(reasoner);
        uint256 id = bridge.attestReasoning(MODEL_HASH, CONTEXT, commit, OUTPUT);
        vm.prank(challenger);
        bridge.challenge(id, keccak256("anything"));

        vm.expectRevert(KOMMIT__SeedMismatch.selector);
        bridge.revealSeed(id, wrongSeed, wrongSalt);
    }

    /// @notice v1.1 KOM-003: setBonds only accepts non-zero with challenger >= reasoner.
    function testFuzz_SetBonds_BoundedAmounts(uint128 r, uint128 cExtra) public {
        uint256 reasonerB = uint256(r) + 1;            // ensure non-zero
        uint256 challengerB = reasonerB + uint256(cExtra); // ensure >= reasonerB
        bridge.setBonds(reasonerB, challengerB);
        assertEq(bridge.reasonerBondAmount(),   reasonerB);
        assertEq(bridge.challengerBondAmount(), challengerB);
    }

    /// @notice Conservation across the full slash flow with a fuzzed bounty rate.
    function testFuzz_SetBountyBps_BoundedConservation(uint16 bps) public {
        bps = uint16(bound(bps, 0, 10000));
        bridge.setBonds(100e18, 100e18); // equal — bigger bonds make accounting visible
        bridge.setChallengeBountyBps(bps);

        // Refund every reasoner+challenger so we start clean for new bond size
        sov.mintDirect(reasoner,   1_000e18);
        sov.mintDirect(challenger, 1_000e18);

        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        bridge.revealSeed(id, SEED, SALT);

        uint256 challengerBefore = sov.balanceOf(challenger);
        uint256 poolBefore       = sov.balanceOf(minerPool);

        vm.prank(oracle);
        bridge.oracleSlash(id, keccak256("x"));

        // Bounty + poolShare must equal reasoner bond
        uint256 bond = 100e18;
        uint256 expectedBounty = (bond * uint256(bps)) / 10000;
        uint256 expectedPool   = bond - expectedBounty;

        assertEq(sov.balanceOf(challenger) - challengerBefore, 100e18 + expectedBounty);
        assertEq(sov.balanceOf(minerPool)  - poolBefore,       expectedPool);
        assertEq(sov.balanceOf(address(bridge)), 0);
    }

    function testFuzz_ChallengeWindow_TimingBoundary(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, 1 hours - 1));
        uint256 id = _attest();

        vm.warp(block.timestamp + elapsed);
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x")); // must succeed for any elapsed < window
    }

    function testFuzz_ChallengeWindow_ExpiredBoundary(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 1, 30 days));
        uint256 id = _attest();
        vm.warp(block.timestamp + 1 hours + elapsed);

        vm.prank(challenger);
        vm.expectRevert(KOMMIT__ChallengeWindowClosed.selector);
        bridge.challenge(id, keccak256("x"));
    }

    /// @notice v1.1: claimByDefault must revert until the oracle window elapses.
    function testFuzz_ClaimByDefault_OracleWindowGuard(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, 1 hours)); // <= deadline → must revert
        uint256 id = _attestChallengeReveal();
        vm.warp(block.timestamp + elapsed);

        vm.expectRevert(KOMMIT__OracleWindowOpen.selector);
        bridge.claimByDefault(id);
    }

    /// @notice v1.1: claimByChallenger must revert until the reveal window elapses.
    function testFuzz_ClaimByChallenger_RevealWindowGuard(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, 1 hours)); // <= deadline → must revert
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.warp(block.timestamp + elapsed);

        vm.expectRevert(KOMMIT__RevealWindowOpen.selector);
        bridge.claimByChallenger(id);
    }
}

/*//////////////////////////////////////////////////////////////
                    CIRCUIT BREAKER INTEGRATION
//////////////////////////////////////////////////////////////*/

contract KommitBridge_CircuitBreaker_Test is KommitFixture {
    function test_PauseBlocksAttestation() public {
        cb.setPaused(true);
        vm.prank(reasoner);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_PauseBlocksChallenge() public {
        uint256 id = _attest();
        cb.setPaused(true);
        vm.prank(challenger);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.challenge(id, keccak256("x"));
    }

    /// @notice v1.1: revealSeed checks the pause — a paused system should not
    ///         accept new state transitions even on the resolution path.
    function test_PauseBlocksRevealSeed() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));

        cb.setPaused(true);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.revealSeed(id, SEED, SALT);
    }

    /// @notice v1.1: claimByDefault deliberately does NOT check pause — once
    ///         the oracle window has elapsed, settlement should be unstoppable
    ///         (otherwise admin can grief honest reasoners by pausing forever).
    function test_PauseDoesNotBlockClaimByDefault() public {
        uint256 id = _attestChallengeReveal();
        vm.warp(block.timestamp + 1 hours + 1);
        cb.setPaused(true);
        bridge.claimByDefault(id); // must succeed
    }

    /// @notice v1.1: claimByChallenger deliberately does NOT check pause —
    ///         honest challengers must be able to slash a non-cooperative
    ///         reasoner even mid-pause.
    function test_PauseDoesNotBlockClaimByChallenger() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.warp(block.timestamp + 1 hours + 1);

        cb.setPaused(true);
        bridge.claimByChallenger(id); // must succeed
    }

    function test_PauseDoesNotBlockFinalize() public {
        uint256 id = _attest();
        vm.warp(block.timestamp + 1 hours + 1);
        cb.setPaused(true);
        bridge.finalize(id); // must succeed
    }

    function test_PauseDoesNotBlockOracleSlash() public {
        uint256 id = _attestChallengeReveal();

        cb.setPaused(true);
        vm.prank(oracle);
        bridge.oracleSlash(id, OUTPUT); // oracle can still verdict mid-pause
    }

    function test_UnpauseRestoresAttestation() public {
        cb.setPaused(true);
        vm.prank(reasoner);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);

        cb.setPaused(false);
        vm.prank(reasoner);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }

    function test_SwapCircuitBreaker_NewBreakerControlsState() public {
        MockCB newCB = new MockCB();
        bridge.setCircuitBreaker(address(newCB));

        // Old CB pause has no effect now
        cb.setPaused(true);
        vm.prank(reasoner);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT); // succeeds

        // New CB does
        newCB.setPaused(true);
        vm.prank(reasoner);
        vm.expectRevert(KOMMIT__Paused.selector);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, _commit(SEED, SALT), OUTPUT);
    }
}

/*//////////////////////////////////////////////////////////////
                    EVENT EMISSION
//////////////////////////////////////////////////////////////*/

contract KommitBridge_Events_Test is KommitFixture {
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
    event ChallengerReplayPosted(uint256 indexed id, bytes32 replayedOutputHash);
    event SeedRevealed(uint256 indexed id, bytes32 seed, bytes32 salt, uint64 oracleDeadline);
    event ReasoningSlashed(uint256 indexed id, bytes32 expectedOutputHash, bytes32 claimedOutputHash, uint256 slashedAmount);
    event ChallengeDismissed(uint256 indexed id, uint256 forfeitedBond);
    event ReasoningFinalized(uint256 indexed id);

    function test_Emit_ModelRegistered() public {
        vm.expectEmit(true, false, false, true);
        emit ModelRegistered(MODEL_HASH2, "p", address(this));
        bridge.registerModel(MODEL_HASH2, "p");
    }

    function test_Emit_ReasoningAttested() public {
        bytes32 commit = _commit(SEED, SALT);
        vm.expectEmit(true, true, true, true);
        emit ReasoningAttested(
            1, reasoner, MODEL_HASH, CONTEXT, OUTPUT, uint64(block.timestamp + 1 hours)
        );
        vm.prank(reasoner);
        bridge.attestReasoning(MODEL_HASH, CONTEXT, commit, OUTPUT);
    }

    function test_Emit_ReasoningChallenged_AndReplayPosted() public {
        uint256 id = _attest();

        vm.expectEmit(true, true, false, true);
        emit ReasoningChallenged(id, challenger, 20e18);

        vm.expectEmit(true, false, false, true);
        emit ChallengerReplayPosted(id, keccak256("guess"));

        vm.prank(challenger);
        bridge.challenge(id, keccak256("guess"));
    }

    /// @notice v1.1 KOM-006: SeedRevealed carries (seed, salt, oracleDeadline)
    ///         so off-chain replay services have everything they need.
    function test_Emit_SeedRevealed() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));

        uint256 t0 = block.timestamp;
        vm.expectEmit(true, false, false, true);
        emit SeedRevealed(id, SEED, SALT, uint64(t0 + 1 hours));
        bridge.revealSeed(id, SEED, SALT);
    }

    function test_Emit_ReasoningSlashed_OracleDriven() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("truth"));
        bridge.revealSeed(id, SEED, SALT);

        vm.expectEmit(true, false, false, true);
        emit ReasoningSlashed(id, keccak256("truth"), OUTPUT, 10e18);
        vm.prank(oracle);
        bridge.oracleSlash(id, keccak256("truth"));
    }

    /// @notice v1.1: claimByChallenger emits ReasoningSlashed with expectedHash
    ///         set to bytes32(0) (no oracle hash on non-cooperation slash).
    function test_Emit_ReasoningSlashed_NonCooperation() public {
        uint256 id = _attest();
        vm.prank(challenger);
        bridge.challenge(id, keccak256("x"));
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectEmit(true, false, false, true);
        emit ReasoningSlashed(id, bytes32(0), OUTPUT, 10e18);
        bridge.claimByChallenger(id);
    }

    function test_Emit_ChallengeDismissed_OracleDriven() public {
        uint256 id = _attestChallengeReveal();

        vm.expectEmit(true, false, false, true);
        emit ChallengeDismissed(id, 20e18);
        vm.prank(oracle);
        bridge.oracleSlash(id, OUTPUT);
    }

    /// @notice v1.1: claimByDefault also emits ChallengeDismissed.
    function test_Emit_ChallengeDismissed_Default() public {
        uint256 id = _attestChallengeReveal();
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectEmit(true, false, false, true);
        emit ChallengeDismissed(id, 20e18);
        bridge.claimByDefault(id);
    }

    function test_Emit_ReasoningFinalized() public {
        uint256 id = _attest();
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectEmit(true, false, false, true);
        emit ReasoningFinalized(id);
        bridge.finalize(id);
    }
}

/*//////////////////////////////////////////////////////////////
                    INVARIANT TESTING
//////////////////////////////////////////////////////////////*/

/// @notice Stateful handler the invariant runner pokes randomly.
///         Tracks net SOV that *should* be locked inside the bridge.
///         v1.1: handler exposes the new state machine entry points
///         (revealLast, claimByDefaultLast, claimByChallengerLast).
contract KommitHandler is Test {
    KommitBridge public bridge;
    MockSov public sov;
    bytes32 public MODEL_HASH;
    bytes32 public SALT_BASE;
    address public reasoner;
    address public challenger;
    address public oracle;

    uint256 public attestationCount;
    uint256 public lastId;

    constructor(
        KommitBridge _bridge,
        MockSov _sov,
        bytes32 _modelHash,
        address _reasoner,
        address _challenger,
        address _oracle
    ) {
        bridge = _bridge;
        sov = _sov;
        MODEL_HASH = _modelHash;
        SALT_BASE = keccak256("salt-base");
        reasoner = _reasoner;
        challenger = _challenger;
        oracle = _oracle;
    }

    function attest(uint256 entropy) external {
        bytes32 ctx  = keccak256(abi.encode(entropy, "ctx"));
        bytes32 seed = keccak256(abi.encode(entropy, "seed"));
        bytes32 commit = keccak256(abi.encodePacked(seed, SALT_BASE));
        bytes32 out  = keccak256(abi.encode(entropy, "out"));
        vm.prank(reasoner);
        try bridge.attestReasoning(MODEL_HASH, ctx, commit, out) returns (uint256 id) {
            attestationCount++;
            lastId = id;
        } catch { /* skip — out of bond, etc. */ }
    }

    function challengeLast(bytes32 replay) external {
        if (lastId == 0) return;
        vm.prank(challenger);
        try bridge.challenge(lastId, replay) {} catch {}
    }

    function revealLast() external {
        if (lastId == 0) return;
        bytes32 seed = keccak256(abi.encode(lastId, "seed"));
        try bridge.revealSeed(lastId, seed, SALT_BASE) {} catch {}
    }

    function claimByDefaultLast() external {
        if (lastId == 0) return;
        try bridge.claimByDefault(lastId) {} catch {}
    }

    function claimByChallengerLast() external {
        if (lastId == 0) return;
        try bridge.claimByChallenger(lastId) {} catch {}
    }

    function oracleSlashLast(bytes32 expectedOutput) external {
        if (lastId == 0) return;
        vm.prank(oracle);
        try bridge.oracleSlash(lastId, expectedOutput) {} catch {}
    }

    function finalizeLast() external {
        if (lastId == 0) return;
        try bridge.finalize(lastId) {} catch {}
    }

    function warp(uint32 t) external {
        // Allow warps long enough to clear challenge + reveal + oracle windows.
        vm.warp(block.timestamp + bound(uint256(t), 0, 4 hours));
    }
}

contract KommitBridge_Invariant_Test is KommitFixture {
    KommitHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new KommitHandler(bridge, sov, MODEL_HASH, reasoner, challenger, oracle);

        // Fund handler-controlled reasoner/challenger generously — a long fuzz
        // run will burn through bonds otherwise.
        sov.mintDirect(reasoner,   1_000_000e18);
        sov.mintDirect(challenger, 1_000_000e18);
        vm.prank(reasoner);   sov.approve(address(bridge), type(uint256).max);
        vm.prank(challenger); sov.approve(address(bridge), type(uint256).max);

        targetContract(address(handler));
    }

    /// @dev Bridge's $SOV balance is always non-negative and bounded by the
    ///      number of attestations ever made × max conceivable bond per side.
    function invariant_BridgeBalanceBounded() public view {
        uint256 cap = handler.attestationCount() * (bridge.reasonerBondAmount() + bridge.challengerBondAmount());
        assertLe(sov.balanceOf(address(bridge)), cap);
    }

    /// @dev nextId only ever grows.
    function invariant_NextIdMonotonic() public view {
        assertGe(bridge.totalAttestations(), handler.lastId());
    }

    /// @dev totalSlashed and totalChallenged never exceed total attestations.
    function invariant_CountersBounded() public view {
        assertLe(bridge.totalChallenged(), bridge.totalAttestations());
        assertLe(bridge.totalSlashed(),    bridge.totalChallenged());
    }

    /// @dev v1.1: bond economics must always be asymmetric or equal — challenger
    ///      bond must never sit below reasoner bond (KOM-003 invariant).
    function invariant_BondAsymmetryPreserved() public view {
        assertGe(bridge.challengerBondAmount(), bridge.reasonerBondAmount());
        assertGt(bridge.reasonerBondAmount(),   0);
        assertGt(bridge.challengerBondAmount(), 0);
    }
}
