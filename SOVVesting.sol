// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  SOVVesting — Founder Genesis Allocation Vesting
 * @author ANO-YOOFI-AGYEI
 * @notice Locks the 19,000,000 SOV founder genesis allocation under a standard
 *         "4-year vest with 12-month cliff" schedule. Beneficiary is set at
 *         construction (intended: VPAY Genesis Safe multisig).
 *
 *         ──────────────────────────────────────────────────────────────────
 *         WHY THIS EXISTS (Round 2 Opsec Audit · finding HIGH-1, 2026-04-22)
 *         ──────────────────────────────────────────────────────────────────
 *         At deploy of the v2 stack on 2026-04-20, the deployer EOA
 *         (0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0) was minted the full
 *         19,000,000 SOV founder allocation directly to its hot key. The
 *         allocation has no on-chain vesting schedule, no timelock, no
 *         multisig escrow — i.e. compromise of one Mac → instant transfer
 *         of 19M SOV.
 *
 *         This contract converts that allocation into a transparent on-chain
 *         schedule. After deployment, the deployer transfers 19M SOV in.
 *         From that moment forward only the schedule can release tokens, and
 *         only to the beneficiary.
 *
 *         ──────────────────────────────────────────────────────────────────
 *         SCHEDULE (OpenZeppelin VestingWalletCliff semantics)
 *         ──────────────────────────────────────────────────────────────────
 *         • start                       = startTimestamp (constructor arg)
 *         • cliff                       = start + cliffSeconds
 *         • end                         = start + durationSeconds
 *         • vested(t) for t  <  cliff   = 0                                (cliff lockup)
 *         • vested(t) for t >= cliff    = totalAllocation * (t - start) / durationSeconds
 *         • vested(t) for t >= end      = totalAllocation                  (fully vested)
 *
 *         For the canonical 12-month cliff / 48-month total schedule:
 *           - 0% unlocked through month 11
 *           - 25% (12/48 months) unlocks atomically at the cliff
 *           - linear to 100% over the remaining 36 months
 *
 *         ──────────────────────────────────────────────────────────────────
 *         IRREVOCABILITY
 *         ──────────────────────────────────────────────────────────────────
 *         There is NO admin, NO pause, NO upgrade path, NO clawback. The
 *         only privileged action on this contract is `transferOwnership`,
 *         which the VestingWallet base inherits from Ownable. The owner is
 *         set to the beneficiary at construction. If the beneficiary is the
 *         VPAY Genesis Safe (intended deployment), this means the Safe can
 *         re-target future releases to a different address only by a Safe
 *         multisig signing a transferOwnership tx. This is a feature of
 *         OZ VestingWallet, not a bug; it is documented openly.
 *
 *         ──────────────────────────────────────────────────────────────────
 *         OPERATIONAL SEQUENCE
 *         ──────────────────────────────────────────────────────────────────
 *         1. Deploy this contract via DeploySOVVesting.s.sol (deployer EOA).
 *         2. Deployer EOA transfers 19,000,000 SOV to address(this).
 *         3. After cliff, the beneficiary (or anyone — release is permissionless)
 *            calls release(SOV_TOKEN) to push vested SOV to the beneficiary.
 *            Since release() is permissionless but only ever sends to owner(),
 *            griefing is impossible — at worst a third party pays gas to
 *            release SOV to the Safe.
 */
contract SOVVesting is VestingWalletCliff {
    // ════════════════════════════════════════════════════════════════
    //                          IMMUTABLE STATE
    // ════════════════════════════════════════════════════════════════

    /// @notice The ERC-20 token this schedule vests (set at construction).
    address public immutable sovToken;

    /// @notice Headline allocation for diligence/UI (not enforced on-chain;
    ///         actual vested amount tracks the contract's live SOV balance).
    uint256 public immutable totalAllocation;

    // ════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ════════════════════════════════════════════════════════════════

    /// @notice Emitted exactly once at construction. Indexed beneficiary +
    ///         token make filtering across multiple vesting wallets trivial.
    event SOVVestingCreated(
        address indexed beneficiary,
        address indexed sovToken,
        uint256 totalAllocation,
        uint64 startTimestamp,
        uint64 cliffTimestamp,
        uint64 endTimestamp,
        uint64 cliffSeconds,
        uint64 durationSeconds
    );

    // ════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════

    /**
     * @param _beneficiary      Address that receives released SOV (and is set as owner).
     * @param _sovToken         ERC-20 token address (canonical $SOV on Polygon).
     * @param _totalAllocation  Headline number of tokens this schedule is sized for.
     *                          Stored for transparency; the live schedule tracks
     *                          actual contract balance, not this number.
     * @param _startTimestamp   When the vesting clock starts (unix seconds).
     *                          For a deploy-now schedule, pass uint64(block.timestamp).
     * @param _durationSeconds  Total vest length (cliff + linear tail). 4 years = 1460 days.
     * @param _cliffSeconds     Cliff length within the duration. 12 months = 365 days.
     *
     *  Reverts if beneficiary or token is zero, or allocation/duration is zero.
     *  The cliff <= duration invariant is enforced by VestingWalletCliff's own
     *  constructor (revert: `InvalidCliffDuration(cliff, duration)`), which runs
     *  before this body per Solidity's C3 base-constructor ordering — so we do
     *  not duplicate that check here.
     */
    constructor(
        address _beneficiary,
        address _sovToken,
        uint256 _totalAllocation,
        uint64 _startTimestamp,
        uint64 _durationSeconds,
        uint64 _cliffSeconds
    )
        VestingWallet(_beneficiary, _startTimestamp, _durationSeconds)
        VestingWalletCliff(_cliffSeconds)
    {
        require(_beneficiary != address(0), "SOVVesting: beneficiary is zero");
        require(_sovToken != address(0), "SOVVesting: sovToken is zero");
        require(_totalAllocation > 0, "SOVVesting: allocation is zero");
        require(_durationSeconds > 0, "SOVVesting: duration is zero");

        sovToken = _sovToken;
        totalAllocation = _totalAllocation;

        emit SOVVestingCreated(
            _beneficiary,
            _sovToken,
            _totalAllocation,
            _startTimestamp,
            _startTimestamp + _cliffSeconds,
            _startTimestamp + _durationSeconds,
            _cliffSeconds,
            _durationSeconds
        );
    }

    // ════════════════════════════════════════════════════════════════
    //                          CONVENIENCE VIEWS
    // ════════════════════════════════════════════════════════════════
    // These wrap the inherited (token-arg) views with the canonical SOV
    // address so dashboards / UI / Polygonscan integrators don't need to
    // pass the token address each time.

    /// @notice SOV currently held by this contract (vesting + vested-not-released).
    function sovBalance() external view returns (uint256) {
        return IERC20(sovToken).balanceOf(address(this));
    }

    /// @notice SOV that has vested but has not yet been released to the beneficiary.
    function sovReleasable() external view returns (uint256) {
        return releasable(sovToken);
    }

    /// @notice Total SOV vested as of `block.timestamp` (released + still releasable).
    function sovVested() external view returns (uint256) {
        return vestedAmount(sovToken, uint64(block.timestamp));
    }

    /// @notice SOV that has already been released to the beneficiary.
    function sovReleased() external view returns (uint256) {
        return released(sovToken);
    }
}
