// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../CircuitBreaker.sol";
import "../SovereignNode.sol";
import "../MinerRewards.sol";
import "../AttestationBridge.sol";
import "../VPAYVault.sol";
import "../GuardianBond.sol";
import "../interfaces/ISovereignToken.sol";

/**
 * @title DeployVPAYGenesis
 * @author ANO-YOOFI-AGYEI
 * @notice Deployment script for the full VPAY Genesis v2 contract stack.
 *
 *         DEPLOYMENT ORDER (dependency chain):
 *         ────────────────────────────────────
 *         1. CircuitBreaker          — no dependencies
 *         2. SovereignNode           — depends on CircuitBreaker
 *         3. MinerRewards            — depends on $SOV token
 *         4. AttestationBridge       — depends on SovereignNode, $SOV, CircuitBreaker, MinerRewards
 *         5. VPAYVault               — depends on stablecoin, SovereignNode, $SOV, CircuitBreaker
 *         6. GuardianBond            — depends on $SOV, ArbitrationChamber (future)
 *
 *         POST-DEPLOYMENT ROLE GRANTS:
 *         ────────────────────────────
 *         • Grant MINTER_ROLE on $SOV → AttestationBridge
 *         • Grant DISTRIBUTOR_ROLE on MinerRewards → AttestationBridge
 *         • Grant GUARDIAN_ROLE on CircuitBreaker → multisig / guardian wallet
 *         • Grant RELAYER_ROLE on AttestationBridge → relayer service wallet
 *         • Grant ORACLE_ROLE on VPAYVault → oracle service wallet
 *
 *         NETWORK: Polygon Mainnet (chainId: 137)
 *
 *         RUN:
 *         ────
 *         forge script contracts/deploy/DeployVPAYGenesis.s.sol \
 *           --rpc-url $POLYGON_RPC \
 *           --broadcast \
 *           --verify \
 *           --etherscan-api-key $POLYGONSCAN_API_KEY \
 *           -vvvv
 */
contract DeployVPAYGenesis is Script {
    // ════════════════════════════════════════════════════════════════
    // ALREADY DEPLOYED — Polygon Mainnet
    // ════════════════════════════════════════════════════════════════

    /// @notice SovereignToken ($SOV) — deployed and verified.
    address constant SOV_TOKEN = 0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0;

    /// @notice Deployer wallet.
    address constant DEPLOYER = 0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0;

    // ════════════════════════════════════════════════════════════════
    // CONFIGURATION — Set before deployment
    // ════════════════════════════════════════════════════════════════

    /// @notice Stablecoin for VPAYVault lending (USDC on Polygon).
    address constant STABLECOIN = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // USDC (native) on Polygon

    /// @notice Relayer service wallet (runs the attestation → mint pipeline).
    address public relayerWallet;

    /// @notice Oracle service wallet (feeds gold price + attestation data to VPAYVault).
    address public oracleWallet;

    /// @notice Guardian multisig (emergency pause authority).
    address public guardianMultisig;

    /// @notice ArbitrationChamber (for GuardianBond — deploy later or use placeholder).
    address public arbitrationChamber;

    // ════════════════════════════════════════════════════════════════
    // DEPLOYED ADDRESSES (populated during run)
    // ════════════════════════════════════════════════════════════════

    CircuitBreaker public circuitBreaker;
    SovereignNode public sovereignNode;
    MinerRewards public minerRewards;
    AttestationBridge public attestationBridge;
    VPAYVault public vpayVault;
    GuardianBond public guardianBond;

    function run() external {
        // ── Load config from environment ──
        relayerWallet = vm.envOr("RELAYER_WALLET", DEPLOYER);
        oracleWallet = vm.envOr("ORACLE_WALLET", DEPLOYER);
        guardianMultisig = vm.envOr("GUARDIAN_MULTISIG", DEPLOYER);
        arbitrationChamber = vm.envOr("ARBITRATION_CHAMBER", DEPLOYER);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // ════════════════════════════════════════
        // STEP 1: CircuitBreaker (no dependencies)
        // ════════════════════════════════════════
        circuitBreaker = new CircuitBreaker();
        console.log("1. CircuitBreaker deployed:", address(circuitBreaker));

        // Grant GUARDIAN_ROLE to multisig
        if (guardianMultisig != DEPLOYER) {
            circuitBreaker.grantRole(circuitBreaker.GUARDIAN_ROLE(), guardianMultisig);
            console.log("   GUARDIAN_ROLE granted to:", guardianMultisig);
        }

        // ════════════════════════════════════════
        // STEP 2: SovereignNode (depends on CircuitBreaker)
        // ════════════════════════════════════════
        sovereignNode = new SovereignNode(address(circuitBreaker));
        console.log("2. SovereignNode deployed:", address(sovereignNode));

        // ════════════════════════════════════════
        // STEP 3: MinerRewards (depends on $SOV)
        // ════════════════════════════════════════
        minerRewards = new MinerRewards(SOV_TOKEN);
        console.log("3. MinerRewards deployed:", address(minerRewards));

        // ════════════════════════════════════════
        // STEP 4: AttestationBridge (depends on 1, 2, 3, $SOV)
        // ════════════════════════════════════════
        attestationBridge = new AttestationBridge(
            address(sovereignNode),
            SOV_TOKEN,
            address(circuitBreaker),
            address(minerRewards)
        );
        console.log("4. AttestationBridge deployed:", address(attestationBridge));

        // Grant RELAYER_ROLE to relayer wallet
        if (relayerWallet != DEPLOYER) {
            attestationBridge.grantRole(attestationBridge.RELAYER_ROLE(), relayerWallet);
            console.log("   RELAYER_ROLE granted to:", relayerWallet);
        }

        // Grant DISTRIBUTOR_ROLE on MinerRewards to AttestationBridge
        minerRewards.grantRole(minerRewards.DISTRIBUTOR_ROLE(), address(attestationBridge));
        console.log("   DISTRIBUTOR_ROLE on MinerRewards granted to AttestationBridge");

        // ════════════════════════════════════════
        // STEP 5: VPAYVault (depends on stablecoin, 1, 2, $SOV)
        // ════════════════════════════════════════
        vpayVault = new VPAYVault(
            STABLECOIN,
            address(sovereignNode),
            SOV_TOKEN,
            address(circuitBreaker)
        );
        console.log("5. VPAYVault deployed:", address(vpayVault));

        // Grant ORACLE_ROLE to oracle wallet
        if (oracleWallet != DEPLOYER) {
            vpayVault.grantRole(vpayVault.ORACLE_ROLE(), oracleWallet);
            console.log("   ORACLE_ROLE granted to:", oracleWallet);
        }

        // ════════════════════════════════════════
        // STEP 6: GuardianBond (depends on $SOV, ArbitrationChamber)
        // ════════════════════════════════════════
        guardianBond = new GuardianBond(SOV_TOKEN, arbitrationChamber);
        console.log("6. GuardianBond deployed:", address(guardianBond));

        // ════════════════════════════════════════
        // STEP 7: Cross-contract role grants on $SOV
        // ════════════════════════════════════════
        // NOTE: The deployer must hold DEFAULT_ADMIN_ROLE on SovereignToken.
        //       These calls grant MINTER_ROLE and BURNER_ROLE to the bridge
        //       and vault contracts so they can mint/burn $SOV.
        //
        //       If the deployer wallet deployed $SOV, it already has admin.
        //       If not, these must be executed via the $SOV admin multisig.

        ISovereignToken sov = ISovereignToken(SOV_TOKEN);

        // AttestationBridge needs MINTER_ROLE to mint $SOV on attestation
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        sov.grantRole(MINTER_ROLE, address(attestationBridge));
        console.log("7. MINTER_ROLE on $SOV granted to AttestationBridge");

        // VPAYVault needs BURNER_ROLE to burn $SOV interest payments
        // (burnFrom is called during repay)
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");
        // Note: burnFrom may need approval pattern depending on $SOV implementation
        // If $SOV uses OZ AccessControl for burn, grant BURNER_ROLE to VPAYVault
        // If $SOV uses standard ERC20 burn (from allowance), this isn't needed
        // Uncomment if your $SOV requires BURNER_ROLE:
        // sov.grantRole(BURNER_ROLE, address(vpayVault));
        // console.log("   BURNER_ROLE on $SOV granted to VPAYVault");

        vm.stopBroadcast();

        // ════════════════════════════════════════
        // DEPLOYMENT SUMMARY
        // ════════════════════════════════════════
        console.log("\n========================================");
        console.log("   VPAY GENESIS v2 - DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("Network:            Polygon Mainnet");
        console.log("SovereignToken:    ", SOV_TOKEN);
        console.log("CircuitBreaker:    ", address(circuitBreaker));
        console.log("SovereignNode:     ", address(sovereignNode));
        console.log("MinerRewards:      ", address(minerRewards));
        console.log("AttestationBridge: ", address(attestationBridge));
        console.log("VPAYVault:         ", address(vpayVault));
        console.log("GuardianBond:      ", address(guardianBond));
        console.log("========================================\n");
    }
}
