// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../SOVVesting.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/*//////////////////////////////////////////////////////////////
                        TEST DOUBLES
//////////////////////////////////////////////////////////////*/

/// @notice Minimal ERC-20 — only the surface SOVVesting actually touches
///         (balanceOf, transfer, transferFrom). Seeded via mintDirect helper.
///         Mirrors the shape of MockSov in Kommit.t.sol so behavior is
///         consistent across the v2 test suite.
contract MockSOV is IERC20 {
    string public constant name = "Sovereign Token";
    string public constant symbol = "SOV";
    uint8 public constant decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function totalSupply() external view returns (uint256) {return _totalSupply;}
    function balanceOf(address a) external view returns (uint256) {return _balances[a];}
    function allowance(address o, address s) external view returns (uint256) {return _allowances[o][s];}

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "Insufficient");
        require(_allowances[from][msg.sender] >= amount, "Not approved");
        _balances[from] -= amount;
        _allowances[from][msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @dev Test helper — seed any account without role checks.
    function mintDirect(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                        BASE FIXTURE
//////////////////////////////////////////////////////////////*/

abstract contract SOVVestingFixture is Test {
    // Canonical schedule constants (mirror production deploy)
    uint256 constant ALLOCATION       = 19_000_000 * 1e18;
    uint64  constant CLIFF_SECONDS    = 365 days;        // 12 months
    uint64  constant DURATION_SECONDS = 1460 days;       // 4 years (cliff + linear tail)

    // Actors
    address beneficiary = address(0xB12C0); // stand-in for VPAY Safe
    address randomGuy   = address(0xBADD1);
    address newOwner    = address(0xFEED);

    // Contracts under test
    MockSOV     sov;
    SOVVesting  vesting;

    // Schedule timestamps (set in setUp)
    uint64 startTs;
    uint64 cliffTs;
    uint64 endTs;

    function setUp() public virtual {
        // Move time off the genesis-block edge so we have headroom for warps.
        vm.warp(1_700_000_000); // 2023-11-14 — chosen for clean math, not significance.
        startTs = uint64(block.timestamp);
        cliffTs = startTs + CLIFF_SECONDS;
        endTs   = startTs + DURATION_SECONDS;

        sov = new MockSOV();
        vesting = new SOVVesting({
            _beneficiary: beneficiary,
            _sovToken: address(sov),
            _totalAllocation: ALLOCATION,
            _startTimestamp: startTs,
            _durationSeconds: DURATION_SECONDS,
            _cliffSeconds: CLIFF_SECONDS
        });
    }

    /// @dev Seed the vesting contract with the full 19M allocation.
    function _depositFullAllocation() internal {
        sov.mintDirect(address(vesting), ALLOCATION);
    }
}

/*//////////////////////////////////////////////////////////////
                  CONSTRUCTION & INVARIANTS
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Construction is SOVVestingFixture {
    function test_ConstructorSetsImmutables() public view {
        assertEq(vesting.sovToken(), address(sov),     "sovToken");
        assertEq(vesting.totalAllocation(), ALLOCATION, "totalAllocation");
    }

    function test_ConstructorSetsScheduleTimestamps() public view {
        assertEq(vesting.start(),    startTs, "start");
        assertEq(vesting.duration(), DURATION_SECONDS, "duration");
        assertEq(vesting.end(),      endTs, "end");
        assertEq(vesting.cliff(),    cliffTs, "cliff");
    }

    function test_ConstructorSetsBeneficiaryAsOwner() public view {
        // VestingWallet inherits Ownable; beneficiary becomes owner.
        assertEq(vesting.owner(), beneficiary, "owner == beneficiary");
    }

    function test_RevertsOnZeroBeneficiary() public {
        vm.expectRevert(); // OZ Ownable rejects zero owner before our require fires
        new SOVVesting(address(0), address(sov), ALLOCATION, startTs, DURATION_SECONDS, CLIFF_SECONDS);
    }

    function test_RevertsOnZeroSovToken() public {
        vm.expectRevert(bytes("SOVVesting: sovToken is zero"));
        new SOVVesting(beneficiary, address(0), ALLOCATION, startTs, DURATION_SECONDS, CLIFF_SECONDS);
    }

    function test_RevertsOnZeroAllocation() public {
        vm.expectRevert(bytes("SOVVesting: allocation is zero"));
        new SOVVesting(beneficiary, address(sov), 0, startTs, DURATION_SECONDS, CLIFF_SECONDS);
    }

    function test_RevertsOnZeroDuration() public {
        vm.expectRevert(bytes("SOVVesting: duration is zero"));
        new SOVVesting(beneficiary, address(sov), ALLOCATION, startTs, 0, 0);
    }

    function test_RevertsOnCliffExceedsDuration() public {
        // VestingWalletCliff's constructor enforces cliff <= duration and runs
        // BEFORE the SOVVesting body (C3 linearization). So the actual revert
        // is the typed error InvalidCliffDuration(cliffSeconds, durationSeconds),
        // not a string from our body. We assert the exact selector + args.
        vm.expectRevert(
            abi.encodeWithSelector(
                VestingWalletCliff.InvalidCliffDuration.selector,
                uint64(200),  // cliffSeconds
                uint64(100)   // durationSeconds
            )
        );
        new SOVVesting(beneficiary, address(sov), ALLOCATION, startTs, 100, 200);
    }

    function test_AcceptsCliffEqualToDuration() public {
        // Edge case: cliff == duration is allowed (becomes a hard timelock).
        SOVVesting v = new SOVVesting(beneficiary, address(sov), 1e18, startTs, 100, 100);
        assertEq(v.cliff(), startTs + 100, "cliff == duration ok");
    }
}

/*//////////////////////////////////////////////////////////////
                  PRE-DEPOSIT BEHAVIOR
//////////////////////////////////////////////////////////////*/

contract SOVVesting_PreDeposit is SOVVestingFixture {
    function test_AllViewsReturnZeroBeforeDeposit() public view {
        assertEq(vesting.sovBalance(),    0, "sovBalance");
        assertEq(vesting.sovVested(),     0, "sovVested");
        assertEq(vesting.sovReleasable(), 0, "sovReleasable");
        assertEq(vesting.sovReleased(),   0, "sovReleased");
    }

    function test_ReleaseBeforeDepositIsNoOp() public {
        // No SOV in the contract → nothing to release. Should succeed silently.
        vesting.release(address(sov));
        assertEq(sov.balanceOf(beneficiary), 0, "no SOV to beneficiary");
    }
}

/*//////////////////////////////////////////////////////////////
                  CLIFF LOCKUP
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Cliff is SOVVestingFixture {
    function setUp() public override {
        super.setUp();
        _depositFullAllocation();
    }

    function test_NothingVestedRightAfterDeposit() public view {
        assertEq(vesting.sovBalance(),    ALLOCATION, "balance == allocation");
        assertEq(vesting.sovVested(),     0,           "vested == 0");
        assertEq(vesting.sovReleasable(), 0,           "releasable == 0");
    }

    function test_NothingVestedAtMonthSix() public {
        vm.warp(startTs + 180 days);
        assertEq(vesting.sovVested(),     0, "vested == 0 mid-cliff");
        assertEq(vesting.sovReleasable(), 0, "releasable == 0 mid-cliff");
    }

    function test_NothingVestedOneSecondBeforeCliff() public {
        vm.warp(cliffTs - 1);
        assertEq(vesting.sovVested(),     0, "vested == 0 at cliff - 1s");
        assertEq(vesting.sovReleasable(), 0, "releasable == 0 at cliff - 1s");
    }

    function test_ReleaseDuringCliffIsNoOp() public {
        vm.warp(startTs + 100 days);
        vesting.release(address(sov));
        assertEq(sov.balanceOf(beneficiary),    0,          "beneficiary unchanged");
        assertEq(sov.balanceOf(address(vesting)), ALLOCATION, "vault unchanged");
    }

    function test_TwentyFivePercentUnlocksAtCliff() public {
        vm.warp(cliffTs);
        // At t = start + 365 days, schedule = ALLOCATION * 365 / 1460 = 25%.
        uint256 expected = ALLOCATION / 4;
        assertEq(vesting.sovVested(),     expected, "vested == 25% at cliff");
        assertEq(vesting.sovReleasable(), expected, "releasable == 25% at cliff");
    }
}

/*//////////////////////////////////////////////////////////////
                  LINEAR VEST POST-CLIFF
//////////////////////////////////////////////////////////////*/

contract SOVVesting_LinearVest is SOVVestingFixture {
    function setUp() public override {
        super.setUp();
        _depositFullAllocation();
    }

    function test_HalfwayUnlocksAtTwoYears() public {
        // 730 / 1460 = exactly 50%
        vm.warp(startTs + 730 days);
        assertEq(vesting.sovVested(), ALLOCATION / 2, "vested == 50% at 24 months");
    }

    function test_ThreeQuartersAtThreeYears() public {
        // 1095 / 1460 = exactly 75%
        vm.warp(startTs + 1095 days);
        assertEq(vesting.sovVested(), (ALLOCATION * 3) / 4, "vested == 75% at 36 months");
    }

    function test_FullyVestedAtEnd() public {
        vm.warp(endTs);
        assertEq(vesting.sovVested(), ALLOCATION, "vested == 100% at end");
        assertEq(vesting.sovReleasable(), ALLOCATION, "releasable == 100% at end");
    }

    function test_NoOverVestPastEnd() public {
        vm.warp(endTs + 365 days * 10); // 10 years past end
        assertEq(vesting.sovVested(), ALLOCATION, "vested capped at 100% post-end");
    }

    function test_LinearGrowthIsMonotonic() public {
        // Sample 12 quarterly checkpoints from cliff onwards.
        uint256 prev = 0;
        for (uint64 q = 4; q <= 16; q++) {
            vm.warp(startTs + q * 91 days);
            uint256 v = vesting.sovVested();
            assertGe(v, prev, "vested non-decreasing");
            prev = v;
        }
    }
}

/*//////////////////////////////////////////////////////////////
                  RELEASE MECHANICS
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Release is SOVVestingFixture {
    function setUp() public override {
        super.setUp();
        _depositFullAllocation();
    }

    function test_ReleaseAtCliffSends25PercentToBeneficiary() public {
        vm.warp(cliffTs);
        vesting.release(address(sov));
        assertEq(sov.balanceOf(beneficiary), ALLOCATION / 4, "25% to beneficiary");
        assertEq(vesting.sovReleased(),       ALLOCATION / 4, "released ledger");
        assertEq(vesting.sovReleasable(),     0,               "nothing more to release at this exact ts");
    }

    function test_SecondReleaseAtFiftyPercentSendsAdditional25() public {
        vm.warp(cliffTs);
        vesting.release(address(sov));
        uint256 firstChunk = sov.balanceOf(beneficiary);

        vm.warp(startTs + 730 days); // 50% mark
        vesting.release(address(sov));
        uint256 totalToBeneficiary = sov.balanceOf(beneficiary);

        // Total should be 50%; second chunk should equal 25%.
        assertEq(totalToBeneficiary,                ALLOCATION / 2, "cumulative 50% to beneficiary");
        assertEq(totalToBeneficiary - firstChunk,   ALLOCATION / 4, "second chunk == 25%");
    }

    function test_FullReleaseAtEnd() public {
        vm.warp(endTs);
        vesting.release(address(sov));
        assertEq(sov.balanceOf(beneficiary),       ALLOCATION, "100% to beneficiary");
        assertEq(sov.balanceOf(address(vesting)),  0,           "vault drained");
        assertEq(vesting.sovReleased(),            ALLOCATION, "released ledger == allocation");
    }

    function test_ReleaseIsPermissionless_AnyoneCanCall() public {
        vm.warp(cliffTs);
        // randomGuy calls release — but funds still go to the beneficiary (owner).
        vm.prank(randomGuy);
        vesting.release(address(sov));
        assertEq(sov.balanceOf(beneficiary), ALLOCATION / 4, "permissionless release sent to owner");
        assertEq(sov.balanceOf(randomGuy),   0,               "random caller got nothing");
    }

    function test_DoubleReleaseAtSameTimestampIsIdempotent() public {
        vm.warp(cliffTs);
        vesting.release(address(sov));
        uint256 first = sov.balanceOf(beneficiary);
        vesting.release(address(sov)); // call again at same ts
        uint256 second = sov.balanceOf(beneficiary);
        assertEq(first, second, "second release at same ts is no-op");
    }
}

/*//////////////////////////////////////////////////////////////
                  ADDITIONAL DEPOSITS (top-up semantics)
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Topups is SOVVestingFixture {
    /// @notice Per OZ docs: tokens deposited at any time follow the same
    ///         schedule as if they had been there since `start`. So a
    ///         late deposit during the linear phase becomes partly
    ///         immediately releasable. We assert that behavior so
    ///         operators understand it before any "oops, wrong amount"
    ///         top-up scenario hits production.
    function test_LateDepositIsImmediatelyPartlyReleasable() public {
        // Skip past cliff to halfway through the schedule (50%).
        vm.warp(startTs + 730 days);

        // First deposit + release the original chunk.
        sov.mintDirect(address(vesting), ALLOCATION);
        vesting.release(address(sov));
        uint256 afterFirst = sov.balanceOf(beneficiary);
        assertEq(afterFirst, ALLOCATION / 2, "50% of first deposit released");

        // Now top up by 4M at the same timestamp.
        sov.mintDirect(address(vesting), 4_000_000e18);
        // 50% of the 4M top-up should be immediately releasable.
        assertApproxEqAbs(vesting.sovReleasable(), 2_000_000e18, 1, "50% of top-up immediately releasable");
    }
}

/*//////////////////////////////////////////////////////////////
                  OWNERSHIP TRANSFER (Safe re-targeting)
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Ownership is SOVVestingFixture {
    function setUp() public override {
        super.setUp();
        _depositFullAllocation();
    }

    function test_OnlyOwnerCanTransferOwnership() public {
        vm.expectRevert(); // OZ OwnableUnauthorizedAccount
        vm.prank(randomGuy);
        vesting.transferOwnership(newOwner);
    }

    function test_BeneficiaryCanTransferOwnershipToNewAddress() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(newOwner);
        assertEq(vesting.owner(), newOwner, "owner updated");
    }

    function test_FutureReleasesGoToNewOwnerAfterTransfer() public {
        // Beneficiary takes their cliff release.
        vm.warp(cliffTs);
        vesting.release(address(sov));
        assertEq(sov.balanceOf(beneficiary), ALLOCATION / 4, "cliff release to original owner");

        // Beneficiary (Safe) decides to re-target to a new dedicated wallet.
        vm.prank(beneficiary);
        vesting.transferOwnership(newOwner);

        // Skip to halfway. The next 25% should go to newOwner, not original beneficiary.
        vm.warp(startTs + 730 days);
        vesting.release(address(sov));

        assertEq(sov.balanceOf(beneficiary), ALLOCATION / 4, "original beneficiary unchanged");
        assertEq(sov.balanceOf(newOwner),    ALLOCATION / 4, "next chunk to new owner");
    }
}

/*//////////////////////////////////////////////////////////////
                  EVENT EMISSION
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Events is SOVVestingFixture {
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

    event ERC20Released(address indexed token, uint256 amount);

    function test_ConstructionEmitsCreatedEvent() public {
        // Re-deploy inside the test so we can capture the event.
        vm.expectEmit(true, true, false, true);
        emit SOVVestingCreated(
            beneficiary,
            address(sov),
            ALLOCATION,
            startTs,
            cliffTs,
            endTs,
            CLIFF_SECONDS,
            DURATION_SECONDS
        );
        new SOVVesting(beneficiary, address(sov), ALLOCATION, startTs, DURATION_SECONDS, CLIFF_SECONDS);
    }

    function test_ReleaseEmitsERC20ReleasedEvent() public {
        _depositFullAllocation();
        vm.warp(cliffTs);
        vm.expectEmit(true, false, false, true);
        emit ERC20Released(address(sov), ALLOCATION / 4);
        vesting.release(address(sov));
    }
}

/*//////////////////////////////////////////////////////////////
                  FUZZ + INVARIANTS
//////////////////////////////////////////////////////////////*/

contract SOVVesting_Fuzz is SOVVestingFixture {
    function setUp() public override {
        super.setUp();
        _depositFullAllocation();
    }

    /// @notice For any timestamp, vested(t) is monotonically non-decreasing
    ///         and always <= total allocation. Released <= vested at all times.
    function testFuzz_VestedNeverExceedsAllocation(uint64 offset) public {
        offset = uint64(bound(offset, 0, 365 days * 20)); // 20 years
        vm.warp(startTs + offset);
        uint256 vested = vesting.sovVested();
        assertLe(vested, ALLOCATION, "vested <= allocation");
    }

    function testFuzz_ReleasableNeverNegativeOrAboveVested(uint64 offset) public {
        offset = uint64(bound(offset, 0, 365 days * 20));
        vm.warp(startTs + offset);
        uint256 vested = vesting.sovVested();
        uint256 releasable = vesting.sovReleasable();
        assertLe(releasable, vested, "releasable <= vested");
    }

    /// @notice Multiple releases over an arbitrary timeline never exceed
    ///         the schedule. The cumulative payout to the beneficiary at
    ///         any time t equals `vested(t)`, never more.
    ///
    /// @dev    The schedule is monotonic in real time, so this test only
    ///         models forward time progression — we sort the fuzzed offsets
    ///         ascending before warping. Backward time travel between
    ///         releases is a non-physical state (block timestamps in the
    ///         EVM only ever increase) and would underflow the OZ vesting
    ///         math (vestedAmount(earlier) - released < 0). That underflow
    ///         is correct contract behavior, not a bug to test against.
    function testFuzz_CumulativeReleaseEqualsVestedAtT(uint64[5] calldata offsets) public {
        // Bound + materialize into memory so we can sort.
        uint64[5] memory bounded;
        for (uint256 i = 0; i < 5; i++) {
            bounded[i] = uint64(bound(offsets[i], 0, 365 days * 5));
        }
        _sortAscending(bounded);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(startTs + bounded[i]);
            vesting.release(address(sov));
        }
        // Final-check: balance held by beneficiary == vested(now)
        uint256 vested = vesting.sovVested();
        assertEq(sov.balanceOf(beneficiary), vested, "cumulative release == vested(now)");
    }

    /// @dev Insertion sort over a fixed-5 array — fine for tiny N, no
    ///      external deps, no library import.
    function _sortAscending(uint64[5] memory a) internal pure {
        for (uint256 i = 1; i < 5; i++) {
            uint64 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
    }
}
