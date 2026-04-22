// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../SOVVesting.sol";

/**
 * @title  DeploySOVVesting
 * @author ANO-YOOFI-AGYEI
 * @notice Deploys SOVVesting on Polygon Mainnet to lock the 19,000,000 SOV
 *         founder genesis allocation. Beneficiary defaults to the VPAY
 *         Genesis Safe (the canonical 2-of-3 multisig).
 *
 *         ────────────────────────────────────────────────────────────────
 *         WHY THIS SCRIPT EXISTS
 *         ────────────────────────────────────────────────────────────────
 *         The 19M SOV founder allocation currently sits on the deployer EOA
 *         hot wallet. Round 2 Opsec Audit (2026-04-22) flagged this as
 *         HIGH-1: compromise of one Mac → instant 19M transfer. This deploy
 *         is the first half of the fix; the SOV transfer is the second.
 *
 *         ────────────────────────────────────────────────────────────────
 *         TWO-STEP REMEDIATION
 *         ────────────────────────────────────────────────────────────────
 *         Step A (this script):  Deploy SOVVesting, beneficiary = Safe.
 *         Step B (manual):       Deployer EOA transfers 19M SOV to vesting
 *                                contract address. Once that tx confirms,
 *                                the 19M is no longer on a hot key —
 *                                only the schedule can move it.
 *
 *         Step B is intentionally NOT automated by this script — it is a
 *         high-stakes irreversible transfer that deserves a deliberate
 *         hand-typed `cast send`. See SOVVesting-Deploy-Runbook.md.
 *
 *         ────────────────────────────────────────────────────────────────
 *         ENV VARS
 *         ────────────────────────────────────────────────────────────────
 *         REQUIRED:
 *           PRIVATE_KEY            — deployer EOA key (the same key that
 *                                    holds DEFAULT_ADMIN_ROLE for $SOV)
 *
 *         OPTIONAL:
 *           BENEFICIARY            — override target wallet
 *                                    (default: VPAY Genesis Safe)
 *           ALLOCATION_WEI         — override headline allocation in wei
 *                                    (default: 19_000_000 * 1e18)
 *           CLIFF_SECONDS          — override cliff length
 *                                    (default: 365 days)
 *           DURATION_SECONDS       — override total vest duration
 *                                    (default: 1460 days = 4 years)
 *           START_OFFSET           — seconds from now to start vesting
 *                                    (default: 0 = start immediately)
 *           DEV_MODE               — bool, default false. If false, the
 *                                    script REFUSES to broadcast unless
 *                                    BENEFICIARY equals the canonical Safe.
 *                                    Set DEV_MODE=true for testnet runs.
 *
 *         ────────────────────────────────────────────────────────────────
 *         RUN
 *         ────────────────────────────────────────────────────────────────
 *           export PRIVATE_KEY=0x...
 *
 *           forge script contracts/deploy/DeploySOVVesting.s.sol \
 *             --rpc-url $POLYGON_RPC \
 *             --broadcast \
 *             --verify \
 *             --etherscan-api-key $POLYGONSCAN_API_KEY \
 *             -vvvv
 *
 *           # Network: Polygon Mainnet (chainId: 137)
 */
contract DeploySOVVesting is Script {
    // ════════════════════════════════════════════════════════════════
    // CANONICAL ADDRESSES — Polygon Mainnet
    // ════════════════════════════════════════════════════════════════

    /// @notice $SOV ERC-20 — already deployed.
    address constant SOV_TOKEN = 0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0;

    /// @notice VPAY Genesis Safe multisig (sole admin across v2 stack).
    address constant SAFE_MULTISIG = 0xFc93b70fAa2045e19CEae43d1b645b2137c68A67;

    /// @notice Deployer EOA — current holder of the 19M SOV genesis allocation.
    address constant DEPLOYER = 0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0;

    // ════════════════════════════════════════════════════════════════
    // DEFAULTS — match Round 2 audit recommendation
    // ════════════════════════════════════════════════════════════════

    uint256 constant DEFAULT_ALLOCATION       = 19_000_000 * 1e18; // 19M SOV
    uint64  constant DEFAULT_CLIFF_SECONDS    = 365 days;          // 12 months
    uint64  constant DEFAULT_DURATION_SECONDS = 1460 days;         // 4 years

    // ════════════════════════════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════════════════════════════

    SOVVesting public vesting;
    address public beneficiary;
    uint256 public allocation;
    uint64 public cliffSeconds;
    uint64 public durationSeconds;
    uint64 public startTimestamp;
    bool public devMode;

    function run() external {
        // ════════════════════════════════════════
        // STEP 0: Resolve env vars + safety checks
        // ════════════════════════════════════════
        beneficiary     = vm.envOr("BENEFICIARY", SAFE_MULTISIG);
        allocation      = vm.envOr("ALLOCATION_WEI", DEFAULT_ALLOCATION);
        cliffSeconds    = uint64(vm.envOr("CLIFF_SECONDS", uint256(DEFAULT_CLIFF_SECONDS)));
        durationSeconds = uint64(vm.envOr("DURATION_SECONDS", uint256(DEFAULT_DURATION_SECONDS)));
        uint64 startOffset = uint64(vm.envOr("START_OFFSET", uint256(0)));
        startTimestamp  = uint64(block.timestamp) + startOffset;
        devMode         = vm.envOr("DEV_MODE", false);

        // SAFETY: in production mode, refuse to deploy to anything other than
        // the canonical Safe. This prevents typos like "I meant Safe but
        // pasted the deployer EOA" that would re-create the very problem we
        // are trying to solve.
        if (!devMode) {
            require(
                beneficiary == SAFE_MULTISIG,
                "Beneficiary != canonical Safe. Set DEV_MODE=true to override (testnet only)."
            );
        }

        require(beneficiary != address(0), "beneficiary unset");
        require(allocation > 0,            "allocation unset");
        require(durationSeconds > 0,       "duration unset");
        require(cliffSeconds <= durationSeconds, "cliff > duration");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // ════════════════════════════════════════
        // STEP 1: Print pre-flight summary
        // ════════════════════════════════════════
        console.log("\n========================================");
        console.log("  SOVVesting DEPLOY - PRE-FLIGHT");
        console.log("========================================");
        console.log("Network:           Polygon Mainnet (137)");
        console.log("DevMode:          ", devMode ? "TRUE (testnet)" : "FALSE (mainnet safety)");
        console.log("SOV token:        ", SOV_TOKEN);
        console.log("Beneficiary:      ", beneficiary);
        console.log("Allocation (wei): ", allocation);
        console.log("Cliff (s):        ", cliffSeconds);
        console.log("Duration (s):     ", durationSeconds);
        console.log("Start (ts):       ", startTimestamp);
        console.log("Deployer:         ", DEPLOYER);
        console.log("========================================\n");

        // ════════════════════════════════════════
        // STEP 2: Deploy
        // ════════════════════════════════════════
        vm.startBroadcast(deployerKey);

        vesting = new SOVVesting({
            _beneficiary: beneficiary,
            _sovToken: SOV_TOKEN,
            _totalAllocation: allocation,
            _startTimestamp: startTimestamp,
            _durationSeconds: durationSeconds,
            _cliffSeconds: cliffSeconds
        });

        console.log("1. SOVVesting deployed at:", address(vesting));

        vm.stopBroadcast();

        // ════════════════════════════════════════
        // STEP 3: Post-deploy sanity (no gas)
        // ════════════════════════════════════════
        require(vesting.sovToken()        == SOV_TOKEN,    "sovToken mismatch");
        require(vesting.totalAllocation() == allocation,    "allocation mismatch");
        require(vesting.start()           == startTimestamp,"start mismatch");
        require(vesting.duration()        == durationSeconds,"duration mismatch");
        require(vesting.cliff()           == startTimestamp + cliffSeconds, "cliff mismatch");
        require(vesting.owner()           == beneficiary,   "owner mismatch");

        // ════════════════════════════════════════
        // STEP 4: Print runbook for STEP B (SOV transfer)
        // ════════════════════════════════════════
        console.log("\n========================================");
        console.log("  POST-DEPLOY - VERIFIED");
        console.log("========================================");
        console.log("SOVVesting:       ", address(vesting));
        console.log("Owner == Safe:    ", vesting.owner() == SAFE_MULTISIG ? "YES" : "NO (DEV)");
        console.log("Cliff timestamp:  ", vesting.cliff());
        console.log("End timestamp:    ", vesting.end());
        console.log("========================================\n");

        console.log("NEXT STEPS:");
        console.log("");
        console.log("1. Verify on Polygonscan (forge --verify auto-handles, else manual).");
        console.log("");
        console.log("2. Transfer 19M SOV from deployer to vesting contract:");
        console.log("");
        console.log("   cast send", SOV_TOKEN);
        console.log("     'transfer(address,uint256)'");
        console.log("    ", address(vesting));
        console.log("     19000000000000000000000000  # 19M * 1e18");
        console.log("     --private-key $PRIVATE_KEY");
        console.log("     --rpc-url $POLYGON_RPC");
        console.log("");
        console.log("3. Verify deposit landed:");
        console.log("");
        console.log("   cast call", address(vesting), "'sovBalance()(uint256)' --rpc-url $POLYGON_RPC");
        console.log("   # expected: 19000000000000000000000000");
        console.log("");
        console.log("4. Update CLAUDE.md + deployed-addresses.json with the SOVVesting address.");
        console.log("");
        console.log("5. Update Round 2 audit doc to flip HIGH-1 from OPEN to RESOLVED.");
    }
}
