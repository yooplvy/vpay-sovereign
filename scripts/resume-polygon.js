// resume-polygon.js — Resumes Polygon mainnet deploy from OracleTriad onwards.
// SovereignToken and SovereignNode are already deployed (nonce 0 and 1).
// Run: npx hardhat run scripts/resume-polygon.js --network polygon_mainnet

const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Already deployed on Polygon mainnet (2026-04-02) — verified on-chain
const ALREADY_DEPLOYED = {
  token:    "0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0", // SovereignToken  (nonce 0) ✓
  node:     "0x721A41B6da222697b4cc3be02715CAD2e598D834", // SovereignNode   (nonce 1) ✓
  oracle:   "0xE130956e443ABBecefc3BE4E33DD811C70749752",  // OracleTriad     (nonce 2) ✓
  cb:       "0xA6500cA2dcF8E9F67a71F7aA9795cA2d51FE9ba9",  // CircuitBreaker  (nonce 3) ✓
  // Live oracles — no mocks on mainnet
  chainlink: "0x0C466540B2ee1a31b441671eac0ca886e051E410", // Chainlink XAU/USD (live feed)
  band:      ethers.constants.AddressZero,                 // Band N/A on Polygon — Chainlink-only
  usdc:      "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", // Native USDC
};

// LayerZero V2 Endpoint on Polygon mainnet
const LZ_ENDPOINT = "0x1a44076050125825900e736c501f859c50fE728c";

async function main() {
  const [deployer] = await ethers.getSigners();
  const bal = await deployer.getBalance();
  const nonce = await deployer.getTransactionCount();
  console.log(`\nResuming deploy on ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.utils.formatEther(bal)} POL`);
  console.log(`Nonce:    ${nonce} (expected: 2)\n`);

  // nonce 4 was used to cancel a stuck tx (self-transfer). Deploying starts at nonce 5.
  if (nonce < 5) throw new Error(`Unexpected nonce ${nonce} — expected 5 (nonce 4 was used to cancel stuck tx). Check on-chain state.`);

  const D = ALREADY_DEPLOYED; // shorthand

  // ── Deploy remaining contracts ──────────────────────────────────────────────
  console.log("Already deployed (verified on-chain):");
  console.log(`  SovereignToken: ${D.token}`);
  console.log(`  SovereignNode:  ${D.node}`);
  console.log(`  OracleTriad:    ${D.oracle}`);
  console.log(`  CircuitBreaker: ${D.cb}`);
  console.log(`  Chainlink:      ${D.chainlink}`);
  console.log(`  USDC:           ${D.usdc}\n`);

  console.log("Deploying remaining contracts (nonce 4 onwards)...");

  const PaymentSOV = await ethers.getContractFactory("PaymentSOV");
  const paymentSOV = await PaymentSOV.deploy("VPAY Sovereign", "SOV", LZ_ENDPOINT, deployer.address);
  await paymentSOV.deployed();
  console.log(`  PaymentSOV:     ${paymentSOV.address}`);

  console.log("\nDeploying escrows and vault...");

  const OnRampEscrow = await ethers.getContractFactory("OnRampEscrow");
  const onRamp = await OnRampEscrow.deploy(paymentSOV.address, D.cb, D.node, deployer.address);
  await onRamp.deployed();
  console.log(`  OnRampEscrow:   ${onRamp.address}`);

  const OffRampEscrow = await ethers.getContractFactory("OffRampEscrow");
  const offRamp = await OffRampEscrow.deploy(paymentSOV.address, deployer.address);
  await offRamp.deployed();
  console.log(`  OffRampEscrow:  ${offRamp.address}`);

  const VPAYVault = await ethers.getContractFactory("VPAYVault");
  const vault = await VPAYVault.deploy(D.node, D.usdc, deployer.address, D.oracle);
  await vault.deployed();
  console.log(`  VPAYVault:      ${vault.address}`);

  const StakingModule = await ethers.getContractFactory("StakingModule");
  const staking = await StakingModule.deploy(D.usdc, paymentSOV.address);
  await staking.deployed();
  console.log(`  StakingModule:  ${staking.address}`);

  // ── Wire roles ──────────────────────────────────────────────────────────────
  console.log("\nWiring roles...");

  const nodeContract    = await ethers.getContractAt("SovereignNode", D.node);
  const MINTER_ROLE     = await paymentSOV.MINTER_ROLE();
  const GOVERNANCE_ROLE = await nodeContract.GOVERNANCE_ROLE();

  await paymentSOV.grantRole(MINTER_ROLE, onRamp.address);
  console.log("  MINTER_ROLE     → OnRampEscrow ✓");

  await nodeContract.grantRole(GOVERNANCE_ROLE, vault.address);
  console.log("  GOVERNANCE_ROLE → VPAYVault ✓");

  // ── Save all addresses ──────────────────────────────────────────────────────
  const addresses = {
    network:       network.name,
    chainId:       137,
    deployer:      deployer.address,
    timestamp:     new Date().toISOString(),
    SovereignToken:  D.token,
    SovereignNode:   D.node,
    OracleTriad:     D.oracle,
    CircuitBreaker:  D.cb,
    PaymentSOV:      paymentSOV.address,
    OnRampEscrow:    onRamp.address,
    OffRampEscrow:   offRamp.address,
    VPAYVault:       vault.address,
    StakingModule:   staking.address,
    // External
    ChainlinkXAUUSD: D.chainlink,
    USDC:            D.usdc,
  };

  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir);
  const outFile = path.join(outDir, "polygon_mainnet.json");
  fs.writeFileSync(outFile, JSON.stringify(addresses, null, 2));
  console.log(`\nAddresses saved to deployments/polygon_mainnet.json`);

  // ── Summary ─────────────────────────────────────────────────────────────────
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
