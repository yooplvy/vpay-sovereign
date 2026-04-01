// deploy-polygon.js — Full VPAY contract suite deployment for Polygon Amoy / Mainnet
// Run: npx hardhat run scripts/deploy-polygon.js --network polygon_amoy
//
// Deploy order:
//   1. MockUSDC (testnet only — mainnet: use real USDC 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174)
//   2. MockChainlink + MockBand (testnet only — mainnet: use real Chainlink/Band oracles)
//   3. SovereignToken ($SOV)
//   4. SovereignNode (physics gate v6.0)
//   5. OracleTriad
//   6. CircuitBreaker
//   7. PaymentSOV (OFT — requires LayerZero endpoint)
//   8. OnRampEscrow
//   9. OffRampEscrow
//  10. VPAYVault
//  11. StakingModule
//  12. Wire roles: MINTER_ROLE, GOVERNANCE_ROLE
//  13. Print deployed addresses + next steps

const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const IS_TESTNET = network.name === "polygon_amoy";
const IS_LOCAL   = network.name === "hardhat" || network.name === "localhost";

// LayerZero V2 Endpoint addresses (live networks)
const LZ_ENDPOINTS = {
  polygon_amoy:    "0x6EDCE65403992e310A62460808c4b910D972f10f",
  polygon_mainnet: "0x1a44076050125825900e736c501f859c50fE728c",
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const bal = await deployer.getBalance();
  console.log(`\nDeploying on ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance: ${ethers.utils.formatEther(bal)} POL\n`);

  if (network.name !== "hardhat" && bal.lt(ethers.utils.parseEther("0.1"))) {
    throw new Error("Insufficient balance. Need at least 0.1 POL for deployment gas.");
  }

  const deployed = {};

  // ── 0. Local hardhat: deploy mock LZ endpoint stub ─────────────────────────
  let lzEndpoint;
  if (IS_LOCAL) {
    // Deploy a minimal LZ endpoint stub that satisfies OFT constructor setDelegate() call
    const MockLZEndpoint = await ethers.getContractFactory("MockLZEndpoint");
    const mockEndpoint = await MockLZEndpoint.deploy(31337); // hardhat chainId as eid
    await mockEndpoint.deployed();
    lzEndpoint = mockEndpoint.address;
    console.log(`  MockLZEndpoint: ${lzEndpoint}`);
  } else {
    lzEndpoint = LZ_ENDPOINTS[network.name];
    if (!lzEndpoint) throw new Error(`No LZ endpoint configured for network: ${network.name}`);
  }

  // ── 1. Test infrastructure (testnet only) ──────────────────────────────────
  if (IS_TESTNET || IS_LOCAL) {
    console.log("Deploying MockUSDC...");
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    deployed.usdc = await MockUSDC.deploy();
    await deployed.usdc.deployed();
    console.log(`  MockUSDC:      ${deployed.usdc.address}`);

    console.log("Deploying MockChainlink + MockBand...");
    const MockChainlink = await ethers.getContractFactory("MockChainlink");
    deployed.chainlink = await MockChainlink.deploy();
    await deployed.chainlink.deployed();
    await deployed.chainlink.setPrice(ethers.utils.parseUnits("4491", 8)); // $4,491/oz XAU (8 dec)

    const MockBand = await ethers.getContractFactory("MockBand");
    deployed.band = await MockBand.deploy();
    await deployed.band.deployed();
    await deployed.band.setPrice(ethers.utils.parseUnits("144395", 18)); // $144,395/kg (18 dec)
    console.log(`  MockChainlink: ${deployed.chainlink.address}`);
    console.log(`  MockBand:      ${deployed.band.address}`);
  } else {
    // Mainnet: set real addresses before deploying
    throw new Error(
      "Mainnet deploy: replace this error with real USDC/Chainlink/Band addresses in the script."
    );
  }

  // ── 2. Core protocol contracts ──────────────────────────────────────────────
  console.log("\nDeploying core protocol...");

  const SovereignToken = await ethers.getContractFactory("SovereignToken");
  deployed.token = await SovereignToken.deploy();
  await deployed.token.deployed();
  console.log(`  SovereignToken: ${deployed.token.address}`);

  const SovereignNode = await ethers.getContractFactory("SovereignNode");
  deployed.node = await SovereignNode.deploy();
  await deployed.node.deployed();
  console.log(`  SovereignNode:  ${deployed.node.address}`);

  const OracleTriad = await ethers.getContractFactory("OracleTriad");
  deployed.oracle = await OracleTriad.deploy(deployed.chainlink.address, deployed.band.address);
  await deployed.oracle.deployed();
  console.log(`  OracleTriad:    ${deployed.oracle.address}`);

  const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
  deployed.cb = await CircuitBreaker.deploy(deployer.address);
  await deployed.cb.deployed();
  console.log(`  CircuitBreaker: ${deployed.cb.address}`);

  const PaymentSOV = await ethers.getContractFactory("PaymentSOV");
  deployed.paymentSOV = await PaymentSOV.deploy("VPAY Sovereign", "SOV", lzEndpoint, deployer.address);
  await deployed.paymentSOV.deployed();
  console.log(`  PaymentSOV:     ${deployed.paymentSOV.address}`);

  // ── 3. Escrows + Vault ──────────────────────────────────────────────────────
  console.log("\nDeploying escrows and vault...");

  const OnRampEscrow = await ethers.getContractFactory("OnRampEscrow");
  deployed.onRamp = await OnRampEscrow.deploy(
    deployed.paymentSOV.address,
    deployed.cb.address,
    deployed.node.address,
    deployer.address
  );
  await deployed.onRamp.deployed();
  console.log(`  OnRampEscrow:   ${deployed.onRamp.address}`);

  const OffRampEscrow = await ethers.getContractFactory("OffRampEscrow");
  deployed.offRamp = await OffRampEscrow.deploy(deployed.paymentSOV.address, deployer.address);
  await deployed.offRamp.deployed();
  console.log(`  OffRampEscrow:  ${deployed.offRamp.address}`);

  const VPAYVault = await ethers.getContractFactory("VPAYVault");
  deployed.vault = await VPAYVault.deploy(
    deployed.node.address,
    deployed.usdc.address,
    deployer.address,        // treasury
    deployed.oracle.address
  );
  await deployed.vault.deployed();
  console.log(`  VPAYVault:      ${deployed.vault.address}`);

  const StakingModule = await ethers.getContractFactory("StakingModule");
  deployed.staking = await StakingModule.deploy(deployed.usdc.address, deployed.paymentSOV.address);
  await deployed.staking.deployed();
  console.log(`  StakingModule:  ${deployed.staking.address}`);

  // ── 4. Wire roles ───────────────────────────────────────────────────────────
  console.log("\nWiring roles...");

  const MINTER_ROLE     = await deployed.paymentSOV.MINTER_ROLE();
  const GOVERNANCE_ROLE = await deployed.node.GOVERNANCE_ROLE();

  await deployed.paymentSOV.grantRole(MINTER_ROLE, deployed.onRamp.address);
  console.log("  MINTER_ROLE     → OnRampEscrow ✓");

  await deployed.node.grantRole(GOVERNANCE_ROLE, deployed.vault.address);
  console.log("  GOVERNANCE_ROLE → VPAYVault ✓");

  console.log("  (NODE_ROLE must be granted to your Hermes backend address post-deploy)");
  console.log("  (GATEWAY_ROLE must be granted to your gateway backend address post-deploy)");

  // ── 5. Save addresses ───────────────────────────────────────────────────────
  const addresses = {};
  for (const [name, contract] of Object.entries(deployed)) {
    addresses[name] = contract.address;
  }
  addresses.network  = network.name;
  addresses.chainId  = (await ethers.provider.getNetwork()).chainId;
  addresses.deployer = deployer.address;
  addresses.timestamp = new Date().toISOString();

  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir);
  const outFile = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outFile, JSON.stringify(addresses, null, 2));
  console.log(`\nAddresses saved to deployments/${network.name}.json`);

  // ── 6. Summary ──────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════");
  console.log(`DEPLOYMENT COMPLETE — ${network.name}`);
  console.log("═══════════════════════════════════════════════════");
  for (const [name, addr] of Object.entries(addresses)) {
    if (typeof addr === "string" && addr.startsWith("0x")) {
      console.log(`${name.padEnd(16)}: ${addr}`);
    }
  }
  console.log("\nNEXT STEPS:");
  console.log("1. Transfer DEFAULT_ADMIN_ROLE to Gnosis Safe on VPAYVault + CircuitBreaker");
  console.log("2. Grant NODE_ROLE to your Hermes backend address on SovereignNode");
  console.log("3. Grant GATEWAY_ROLE to your gateway backend address on OnRampEscrow");
  console.log("4. Update src/contracts/addresses.ts with the addresses above");
  console.log(`5. Verify contracts on Polygonscan:`);
  console.log(`   npx hardhat verify --network ${network.name} <address> [constructor args]`);
}

main().catch((e) => { console.error(e); process.exit(1); });
