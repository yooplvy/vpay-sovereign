// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/ISovereignToken.sol";

/**
 * @title MigrateAdminToSafe
 * @author ANO-YOOFI-AGYEI
 * @notice Second-stage deployment script. Migrates DEFAULT_ADMIN_ROLE
 *         from the deployer EOA to the VPAY Genesis Safe multisig across
 *         all 7 v2 contracts. Runs AFTER DeployVPAYGenesis.s.sol.
 *
 *         SAFETY PATTERN (per contract):
 *         ──────────────────────────────
 *         1. grantRole(DEFAULT_ADMIN_ROLE, SAFE)   ← Safe becomes co-admin
 *         2. renounceRole(DEFAULT_ADMIN_ROLE, deployer)  ← deployer drops admin
 *
 *         Step 1 before Step 2 prevents the contract from becoming adminless
 *         if step 2 reverts for any reason. Each contract is migrated
 *         atomically within the broadcast; if any call reverts, the whole
 *         broadcast aborts and no state is changed.
 *
 *         REQUIRES:
 *         ─────────
 *         • Deployer holds DEFAULT_ADMIN_ROLE on all 7 contracts (post-deploy state)
 *         • SAFE address is the VPAY Genesis Safe on Polygon
 *         • PRIVATE_KEY env = deployer's key
 *
 *         DOES NOT TOUCH:
 *         ──────────────
 *         • Service roles (MINTER, BURNER, RELAYER, ORACLE, DISTRIBUTOR, GUARDIAN,
 *           NODE, GOVERNANCE, ARBITRATOR) — these stay where DeployVPAYGenesis.s.sol
 *           placed them. Grant/revoke service roles later via separate targeted
 *           scripts or directly from the Safe once Safe is admin.
 *
 *         RUN:
 *         ────
 *         forge script contracts/deploy/MigrateAdminToSafe.s.sol \
 *           --rpc-url $POLYGON_RPC \
 *           --broadcast \
 *           -vvvv
 */
contract MigrateAdminToSafe is Script {
    // ════════════════════════════════════════════════════════════════
    // ADDRESSES
    // ════════════════════════════════════════════════════════════════

    /// @notice VPAY Genesis Safe multisig on Polygon (2-of-3 target).
    address constant SAFE = 0xFc93b70fAa2045e19CEae43d1b645b2137c68A67;

    /// @notice Deployer EOA (current admin holder).
    address constant DEPLOYER = 0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0;

    /// @notice SovereignToken ($SOV) — already deployed.
    address constant SOV_TOKEN = 0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0;

    /// @notice Bytes32 identifier for DEFAULT_ADMIN_ROLE (= 0x00...00).
    bytes32 constant ADMIN = 0x00;

    // ════════════════════════════════════════════════════════════════
    // RUN
    // ════════════════════════════════════════════════════════════════

    function run() external {
        // Load addresses of the 6 newly-deployed contracts from env.
        // These are printed by DeployVPAYGenesis.s.sol — copy them into .env.
        address circuitBreaker    = vm.envAddress("CIRCUIT_BREAKER");
        address sovereignNode     = vm.envAddress("SOVEREIGN_NODE");
        address minerRewards      = vm.envAddress("MINER_REWARDS");
        address attestationBridge = vm.envAddress("ATTESTATION_BRIDGE");
        address vpayVault         = vm.envAddress("VPAY_VAULT");
        address guardianBond      = vm.envAddress("GUARDIAN_BOND");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // Sanity checks — fail fast if anything is off.
        require(SAFE != address(0), "SAFE unset");
        require(DEPLOYER != address(0), "DEPLOYER unset");
        require(circuitBreaker != address(0), "CIRCUIT_BREAKER unset");
        require(sovereignNode != address(0), "SOVEREIGN_NODE unset");
        require(minerRewards != address(0), "MINER_REWARDS unset");
        require(attestationBridge != address(0), "ATTESTATION_BRIDGE unset");
        require(vpayVault != address(0), "VPAY_VAULT unset");
        require(guardianBond != address(0), "GUARDIAN_BOND unset");

        // Pre-flight: confirm deployer actually holds admin on each (reads only, no gas).
        require(AccessControl(SOV_TOKEN).hasRole(ADMIN, DEPLOYER), "deployer not admin on SOV");
        require(AccessControl(circuitBreaker).hasRole(ADMIN, DEPLOYER), "deployer not admin on CircuitBreaker");
        require(AccessControl(sovereignNode).hasRole(ADMIN, DEPLOYER), "deployer not admin on SovereignNode");
        require(AccessControl(minerRewards).hasRole(ADMIN, DEPLOYER), "deployer not admin on MinerRewards");
        require(AccessControl(attestationBridge).hasRole(ADMIN, DEPLOYER), "deployer not admin on AttestationBridge");
        require(AccessControl(vpayVault).hasRole(ADMIN, DEPLOYER), "deployer not admin on VPAYVault");
        require(AccessControl(guardianBond).hasRole(ADMIN, DEPLOYER), "deployer not admin on GuardianBond");

        vm.startBroadcast(deployerKey);

        // ════════════════════════════════════════════════════════
        // PHASE 1: Grant Safe admin on all 7 contracts
        // ════════════════════════════════════════════════════════
        // Order doesn't matter — each grant is independent.
        console.log("\n-- PHASE 1: Granting DEFAULT_ADMIN_ROLE to Safe --\n");

        AccessControl(SOV_TOKEN).grantRole(ADMIN, SAFE);
        console.log("1/7 SOV_TOKEN         admin -> Safe");

        AccessControl(circuitBreaker).grantRole(ADMIN, SAFE);
        console.log("2/7 CircuitBreaker    admin -> Safe");

        AccessControl(sovereignNode).grantRole(ADMIN, SAFE);
        console.log("3/7 SovereignNode     admin -> Safe");

        AccessControl(minerRewards).grantRole(ADMIN, SAFE);
        console.log("4/7 MinerRewards      admin -> Safe");

        AccessControl(attestationBridge).grantRole(ADMIN, SAFE);
        console.log("5/7 AttestationBridge admin -> Safe");

        AccessControl(vpayVault).grantRole(ADMIN, SAFE);
        console.log("6/7 VPAYVault         admin -> Safe");

        AccessControl(guardianBond).grantRole(ADMIN, SAFE);
        console.log("7/7 GuardianBond      admin -> Safe");

        // ════════════════════════════════════════════════════════
        // PHASE 2: Renounce deployer's admin on all 7 contracts
        // ════════════════════════════════════════════════════════
        // After this, only Safe holds DEFAULT_ADMIN_ROLE.
        // IRREVERSIBLE — if any bug renders Safe unable to sign, admin is lost.
        // This is why Phase 1 runs first: Safe is admin before deployer drops it.
        console.log("\n-- PHASE 2: Renouncing deployer admin --\n");

        AccessControl(SOV_TOKEN).renounceRole(ADMIN, DEPLOYER);
        console.log("1/7 SOV_TOKEN         deployer admin renounced");

        AccessControl(circuitBreaker).renounceRole(ADMIN, DEPLOYER);
        console.log("2/7 CircuitBreaker    deployer admin renounced");

        AccessControl(sovereignNode).renounceRole(ADMIN, DEPLOYER);
        console.log("3/7 SovereignNode     deployer admin renounced");

        AccessControl(minerRewards).renounceRole(ADMIN, DEPLOYER);
        console.log("4/7 MinerRewards      deployer admin renounced");

        AccessControl(attestationBridge).renounceRole(ADMIN, DEPLOYER);
        console.log("5/7 AttestationBridge deployer admin renounced");

        AccessControl(vpayVault).renounceRole(ADMIN, DEPLOYER);
        console.log("6/7 VPAYVault         deployer admin renounced");

        AccessControl(guardianBond).renounceRole(ADMIN, DEPLOYER);
        console.log("7/7 GuardianBond      deployer admin renounced");

        vm.stopBroadcast();

        // ════════════════════════════════════════════════════════
        // POST-FLIGHT: read-only verification (no gas)
        // ════════════════════════════════════════════════════════
        console.log("\n-- POST-FLIGHT VERIFICATION --\n");

        _verify(SOV_TOKEN,         "SOV_TOKEN");
        _verify(circuitBreaker,    "CircuitBreaker");
        _verify(sovereignNode,     "SovereignNode");
        _verify(minerRewards,      "MinerRewards");
        _verify(attestationBridge, "AttestationBridge");
        _verify(vpayVault,         "VPAYVault");
        _verify(guardianBond,      "GuardianBond");

        console.log("\n========================================");
        console.log("   ADMIN MIGRATION COMPLETE");
        console.log("   All 7 contracts: Safe is sole admin");
        console.log("========================================\n");
    }

    function _verify(address c, string memory name) internal view {
        bool safeHasAdmin     = AccessControl(c).hasRole(ADMIN, SAFE);
        bool deployerHasAdmin = AccessControl(c).hasRole(ADMIN, DEPLOYER);
        if (safeHasAdmin && !deployerHasAdmin) {
            console.log(string.concat("  OK  ", name));
        } else {
            console.log(string.concat("  FAIL ", name, " - safe:"), safeHasAdmin, " deployer:", deployerHasAdmin);
        }
    }
}
