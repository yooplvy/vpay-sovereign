// resume-polygon-2.js — Resumes Polygon mainnet deploy from VPAYVault (nonce 8) onwards.
// Nonces 0-7 are confirmed on-chain. Starting from VPAYVault.
// Run: npx hardhat run scripts/resume-polygon-2.js --network polygon_mainnet

const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const DEPLOYED = {
  token:       "0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0", // SovereignToken  (nonce 0) ✓
  node:        "0x721A41B6da222697b4cc3be02715CAD2e598D834", // SovereignNode   (nonce 1) ✓
  oracle:      "0xE130956e443ABBecefc3BE4E33DD811C70749752", // OracleTriad     (nonce 2) ✓
  cb:          "0xA6500cA2dcF8E9F67a71F7aA9795cA2d51FE9ba9", // CircuitBreaker  (nonce 3) ✓
  // nonce 4: cancelled (self-transfer)
  paymentSOV:  "0x3451222D576AF7Ee994915C8D2B7b09a738FBF49", // PaymentSOV      (nonce 5) ✓
  onRamp:      "0xc9c802FC5860e271FBE06Ebd2274A7ac72D0b0AA", // OnRampEscrow    (nonce 6) ✓
  offRamp:     "0x34Dd2c07e7a6a051A08691e9d1abA23d81033779", // OffRampEscrow   (nonce 7) ✓
  // External
  chainlink:   "0x0C466540B2ee1a31b441671eac0ca886e051E410", // Chainlink XAU/USD
  usdc:        "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", // Native USDC
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const bal = await deployer.getBalance();
  const nonce = await deployer.getTransactionCount();
  console.log(`\nResuming deploy on ${network.name} (from nonce ${nonce})`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.utils.formatEther(bal)} POL`);
  console.log(`Nonce:    ${nonce} (expected: 8)\n`);

  if (nonce < 8) throw new Error(`Unexpected nonce ${nonce} — expected >= 8. Check on-chain state.`);
  if (nonce > 8) throw new Error(`Nonce ${nonce} > 8. VPAYVault may already be deployed — check on-chain.`);

  const D = DEPLOYED;

  console.log("Already deployed (nonces 0-7):");
  console.log(`  SovereignToken:  ${D.token}`);
  console.log(`  SovereignNode:   ${D.node}`);
  console.log(`  OracleTriad:     ${D.oracle}`);
  console.log(`  CircuitBreaker:  ${D.cb}`);
  console.log(`  PaymentSOV:      ${D.paymentSOV}`);
  console.log(`  OnRampEscrow:    ${D.onRamp}`);
  console.log(`  OffRampEscrow:   ${D.offRamp}\n`);

  // ── nonce 8: VPAYVault ────────────────────────────────────────────────────────
  console.log("Deploying VPAYVault (nonce 8)...");
  const VPAYVault = await ethers.getContractFactory("VPAYVault");
  const vault = await VPAYVault.deploy(D.node, D.usdc, deployer.address, D.oracle);
  await vault.deployed();
  console.log(`  VPAYVault:       ${vault.address}`);

  // ── nonce 9: StakingModule ────────────────────────────────────────────────────
  console.log("Deploying StakingModule (nonce 9)...");
  const StakingModule = await ethers.getContractFactory("StakingModule");
  const staking = await StakingModule.deploy(D.usdc, D.paymentSOV);
  await staking.deployed();
  console.log(`  StakingModule:   ${staking.address}`);

  // ── nonces 10-11: Wire roles ──────────────────────────────────────────────────
  console.log("\nWiring roles...");

  const paymentSOV  = await ethers.getContractAt("PaymentSOV", D.paymentSOV);
  const nodeContract = await ethers.getContractAt("SovereignNode", D.node);

  const MINTER_ROLE     = await paymentSOV.MINTER_ROLE();
  const GOVERNANCE_ROLE = await nodeContract.GOVERNANCE_ROLE();

  await paymentSOV.grantRole(MINTER_ROLE, D.onRamp);
  console.log("  MINTER_ROLE     → OnRampEscrow ✓");

  await nodeContract.grantRole(GOVERNANCE_ROLE, vault.address);
  console.log("  GOVERNANCE_ROLE → VPAYVault ✓");

  // ── Save all addresses ────────────────────────────────────────────────────────
  const addresses = {
    network:         network.name,
    chainId:         137,
    deployer:        deployer.address,
    timestamp:       new Date().toISOString(),
    SovereignToken:  D.token,
    SovereignNode:   D.node,
    OracleTriad:     D.oracle,
    CircuitBreaker:  D.cb,
    PaymentSOV:      D.paymentSOV,
    OnRampEscrow:    D.onRamp,
    OffRampEscrow:   D.offRamp,
    VPAYVault:       vault.address,
    StakingModule:   staking.address,
    ChainlinkXAUUSD: D.chainlink,
    USDC:            D.usdc,
  };

  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir);
  const outFile = path.join(outDir, "polygon_mainnet.json");
  fs.writeFileSync(outFile, JSON.stringify(addresses, null, 2));
  console.log(`\nAddresses saved to deployments/polygon_mainnet.json`);

  // ── Summary ───────────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════");
  console.log("DEPLOYMENT COMPLETE — polygon_mainnet");
  console.log("═══════════════════════════════════════════════════");
  for (const [k, v] of Object.entries(addresses)) {
    if (typeof v === "string" && v.startsWith("0x")) {
      console.log(`${k.padEnd(18)}: ${v}`);
    }
  }
  console.log("\nNEXT STEPS:");
  console.log("1. Transfer DEFAULT_ADMIN_ROLE to Gnosis Safe on VPAYVault + CircuitBreaker");
  console.log("2. Grant NODE_ROLE to Hermes backend address on SovereignNode");
  console.log("3. Grant GATEWAY_ROLE to gateway backend address on OnRampEscrow");
  console.log("4. Update src/contracts/addresses.ts with the addresses above");
  console.log("5. Verify on Polygonscan:");
  console.log("   npx hardhat verify --network polygon_mainnet <address> [args]");
}

main().catch((e) => { console.error(e); process.exit(1); });
