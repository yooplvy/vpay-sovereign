// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../KommitBridge.sol";
import "../interfaces/ISovereignToken.sol";

/**
 * @title DeployKommit
 * @author ANO-YOOFI-AGYEI
 * @notice Deployment script for KommitBridge — VPAY Genesis IP #2 (v1.1).
 *
 *         ────────────────────────────────────────────────────────────────
 *         v1.1 Changelog (Audit Fix 2026-04-22 · Round 3 redeploy)
 *         ────────────────────────────────────────────────────────────────
 *         The KommitBridge v1.1 constructor only grants DEFAULT_ADMIN_ROLE
 *         (KOM-002 fix — v1.0 auto-granted REASONER/ORACLE to deployer).
 *         This script MUST therefore explicitly grant REASONER_ROLE and
 *         ORACLE_ROLE to operational wallets — otherwise the contract is
 *         stranded with no one able to attest after admin migration to Safe.
 *
 *         Required env vars are now hard-checked: the script reverts before
 *         broadcast if REASONER_WALLET or ORACLE_WALLET is unset. This is
 *         intentional — it forces deliberate role provisioning and aligns
 *         the deploy ergonomics with the KOM-002 audit fix.
 *
 *         New optional env var MODEL_HASH_PRIMARY pre-registers a canonical
 *         model hash in the same broadcast (before admin migration), so the
 *         deploy + first-model-seed is one atomic operation. If unset, the
 *         registry is empty post-deploy and Safe must register models later.
 *
 *         ────────────────────────────────────────────────────────────────
 *         Dependencies (must already be deployed on Polygon Mainnet)
 *         ────────────────────────────────────────────────────────────────
 *         • SovereignToken ($SOV) — 0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0
 *         • CircuitBreaker        — 0xeaef8dc4872a73815aea74a31ff7c83fdaa347d4
 *         • MinerRewards (v2)     — 0xfcb7d33f7d00040767faaca707f57c4e0bd5db19
 *
 *         ────────────────────────────────────────────────────────────────
 *         Env vars
 *         ────────────────────────────────────────────────────────────────
 *         REQUIRED:
 *           PRIVATE_KEY           — deployer EOA private key
 *           REASONER_WALLET       — Hermes/Pantheon relayer wallet
 *           ORACLE_WALLET         — replay oracle service wallet
 *
 *         OPTIONAL:
 *           MIGRATE_ADMIN         — bool, default true (atomic admin handoff to Safe)
 *           MODEL_HASH_PRIMARY    — bytes32, if set, register in same broadcast
 *           MODEL_NAME_PRIMARY    — string, companion to MODEL_HASH_PRIMARY
 *                                   (defaults to "hermes-v2-zeus-orchestrator")
 *
 *         ────────────────────────────────────────────────────────────────
 *         Run
 *         ────────────────────────────────────────────────────────────────
 *         export PRIVATE_KEY=...
 *         export REASONER_WALLET=0x...      # Hermes relayer
 *         export ORACLE_WALLET=0x...        # replay oracle
 *         export MODEL_HASH_PRIMARY=0x...   # optional: pre-register Zeus model
 *
 *         forge script contracts/deploy/DeployKommit.s.sol \
 *           --rpc-url $POLYGON_RPC \
 *           --broadcast \
 *           --verify \
 *           --etherscan-api-key $POLYGONSCAN_API_KEY \
 *           -vvvv
 *
 *         NETWORK: Polygon Mainnet (chainId: 137)
 */
contract DeployKommit is Script {
    // ════════════════════════════════════════════════════════════════
    // CANONICAL ADDRESSES — Polygon Mainnet (verified 2026-04-20)
    // ════════════════════════════════════════════════════════════════

    address constant SOV_TOKEN        = 0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0;
    address constant CIRCUIT_BREAKER  = 0xeaeF8DC4872a73815aEA74a31FF7C83fdAA347d4;
    address constant MINER_REWARDS    = 0xFCb7d33F7D00040767FaAcA707F57c4E0Bd5db19;
    address constant DEPLOYER         = 0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0;
    address constant SAFE_MULTISIG    = 0xFc93b70fAa2045e19CEae43d1b645b2137c68A67;

    // ════════════════════════════════════════════════════════════════
    // CONFIG (resolved from env at run time)
    // ════════════════════════════════════════════════════════════════

    address public reasonerWallet;
    address public oracleWallet;
    bool    public migrateAdmin;
    bytes32 public modelHashPrimary;
    string  public modelNamePrimary;

    KommitBridge public kommit;

    function run() external {
        // ════════════════════════════════════════
        // STEP 0: Resolve + validate env vars
        // ════════════════════════════════════════
        // KOM-002 alignment: REQUIRE explicit operational wallets. No silent
        // fallback to deployer — the whole point of v1.1 is to make role
        // provisioning a deliberate, visible action.
        reasonerWallet = vm.envAddress("REASONER_WALLET");
        oracleWallet   = vm.envAddress("ORACLE_WALLET");
        require(reasonerWallet != address(0), "REASONER_WALLET must be set (KOM-002)");
        require(oracleWallet   != address(0), "ORACLE_WALLET must be set (KOM-002)");
        // KOM-OPS-1 (internal red-team 2026-04-22): the same address holding both
        // REASONER_ROLE and ORACLE_ROLE could attest a reasoning and then verdict
        // its own attestation honest via oracleSlash, defeating the fraud-proof
        // premise. Enforce role separation at deploy time.
        require(reasonerWallet != oracleWallet, "REASONER and ORACLE must be distinct (KOM-OPS-1)");

        migrateAdmin       = vm.envOr("MIGRATE_ADMIN", true);
        modelHashPrimary   = vm.envOr("MODEL_HASH_PRIMARY", bytes32(0));
        modelNamePrimary   = vm.envOr("MODEL_NAME_PRIMARY", string("hermes-v2-zeus-orchestrator"));

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // ════════════════════════════════════════
        // STEP 1: Deploy KommitBridge v1.1
        // ════════════════════════════════════════
        kommit = new KommitBridge(
            SOV_TOKEN,
            CIRCUIT_BREAKER,
            MINER_REWARDS
        );
        console.log("1. KommitBridge v1.1 deployed:", address(kommit));

        // ════════════════════════════════════════
        // STEP 2: Grant operational roles
        // ════════════════════════════════════════
        // v1.1 (KOM-002): constructor does NOT auto-grant these. We must
        // grant them explicitly in this same broadcast — otherwise admin
        // migration would strand the contract with no reasoner or oracle.
        kommit.grantRole(kommit.REASONER_ROLE(), reasonerWallet);
        console.log("2. REASONER_ROLE granted to:", reasonerWallet);

        kommit.grantRole(kommit.ORACLE_ROLE(), oracleWallet);
        console.log("3. ORACLE_ROLE granted to:  ", oracleWallet);

        // ════════════════════════════════════════
        // STEP 3 (optional): Pre-register canonical model hash
        // ════════════════════════════════════════
        // Must happen BEFORE admin migration — registerModel requires
        // DEFAULT_ADMIN_ROLE, which the deployer is about to renounce.
        if (modelHashPrimary != bytes32(0)) {
            kommit.registerModel(modelHashPrimary, modelNamePrimary);
            console.log("4. Model registered:");
            console.log("   hash:", vm.toString(modelHashPrimary));
            console.log("   name:", modelNamePrimary);
        } else {
            console.log("4. MODEL_HASH_PRIMARY not set - skipping model seed.");
            console.log("   Safe must call registerModel() post-deploy to seed registry.");
        }

        // ════════════════════════════════════════
        // STEP 4: Migrate admin to Safe (atomic, prevents stranded admin)
        // ════════════════════════════════════════
        if (migrateAdmin) {
            kommit.grantRole(kommit.DEFAULT_ADMIN_ROLE(), SAFE_MULTISIG);
            console.log("5. DEFAULT_ADMIN_ROLE granted to Safe:", SAFE_MULTISIG);
            kommit.renounceRole(kommit.DEFAULT_ADMIN_ROLE(), DEPLOYER);
            console.log("   DEPLOYER renounced DEFAULT_ADMIN_ROLE");
        } else {
            console.log("5. MIGRATE_ADMIN=false - DEPLOYER retains DEFAULT_ADMIN_ROLE.");
            console.log("   You MUST migrate to Safe via a separate broadcast before mainnet use.");
        }

        vm.stopBroadcast();

        // ════════════════════════════════════════
        // POST-BROADCAST SANITY (off-chain reads, no gas)
        // ════════════════════════════════════════
        // These calls run after vm.stopBroadcast so they don't burn a tx,
        // but they DO assert the deploy reached the expected state. If any
        // of these fail, the deploy is broken and you should investigate
        // before trusting the address.
        require(kommit.hasRole(kommit.REASONER_ROLE(), reasonerWallet), "Reasoner role missing");
        require(kommit.hasRole(kommit.ORACLE_ROLE(),   oracleWallet),   "Oracle role missing");
        if (migrateAdmin) {
            require(kommit.hasRole(kommit.DEFAULT_ADMIN_ROLE(), SAFE_MULTISIG), "Safe admin missing");
            require(!kommit.hasRole(kommit.DEFAULT_ADMIN_ROLE(), DEPLOYER), "Deployer still admin");
        }
        if (modelHashPrimary != bytes32(0)) {
            require(kommit.registeredModel(modelHashPrimary), "Model not registered");
        }

        // ════════════════════════════════════════
        // SUMMARY
        // ════════════════════════════════════════
        console.log("\n========================================");
        console.log("   VPAY GENESIS - KOMMIT v1.1 DEPLOYED");
        console.log("========================================");
        console.log("Network:           Polygon Mainnet (137)");
        console.log("KommitBridge:     ", address(kommit));
        console.log("Protocol ID:      ", kommit.PROTOCOL_ID());
        console.log("SovereignToken:   ", SOV_TOKEN);
        console.log("CircuitBreaker:   ", CIRCUIT_BREAKER);
        console.log("MinerRewards:     ", MINER_REWARDS);
        console.log("Admin:            ", migrateAdmin ? SAFE_MULTISIG : DEPLOYER);
        console.log("Reasoner:         ", reasonerWallet);
        console.log("Oracle:           ", oracleWallet);
        console.log("Reasoner Bond:     10 SOV (default)");
        console.log("Challenger Bond:   20 SOV (default)");
        console.log("Challenge Window:  1 hour (default)");
        console.log("Reveal Window:     1 hour (default)");
        console.log("Oracle Window:     1 hour (default, v1.1 KOM-001)");
        console.log("Bounty:            50% of slashed bond");
        console.log("Models seeded:    ", modelHashPrimary != bytes32(0) ? "yes (1)" : "no");
        console.log("========================================\n");
        console.log("NEXT STEPS:");
        console.log("1. Verify on Polygonscan (forge --verify should auto-handle)");
        console.log("2. Update contracts/deploy/deployed-addresses.json");
        console.log("3. Update CLAUDE.md with new KommitBridge v1.1 address");
        console.log("4. If MODEL_HASH_PRIMARY was unset: Safe registerModel() for canonical hashes");
        console.log("5. Wire Hermes hermes_v2/kommit_client.py to new address");
        console.log("6. Patch vpay-hmi-cockpit.html Kommit panel address");
    }
}
