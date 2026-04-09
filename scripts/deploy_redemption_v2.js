// deploy_redemption_v2.js
// Deploys the rewritten GoldRedemption contract and updates polygon_mainnet.json.
// BURNER_ROLE is already granted (via wire_roles.js) — this script skips that step.

const hre     = require("hardhat");
const fs      = require("fs");
const path    = require("path");

const DEPLOYMENTS_FILE = path.join(__dirname, "../deployments/polygon_mainnet.json");

// Mainnet addresses (from deployments/polygon_mainnet.json)
const VPAY_TOKEN      = "0x37f68e66d142C31a2c01Eb36e8b5227bfC04B4Dc";
const USDC            = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";
const CHAINLINK_XAU   = "0x0C466540B2ee1a31b441671eac0ca886e051E410"; // Chainlink XAU/USD Polygon

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const bal = await hre.ethers.provider.getBalance(deployer.address);

  console.log("=== Deploy GoldRedemption v2 ===");
  console.log(`Deployer : ${deployer.address}`);
  console.log(`Balance  : ${hre.ethers.formatEther(bal)} POL\n`);

  const Factory = await hre.ethers.getContractFactory("GoldRedemption");
  console.log("Deploying...");

  const contract = await Factory.deploy(VPAY_TOKEN, USDC, CHAINLINK_XAU, {
    maxFeePerGas:         hre.ethers.parseUnits("300", "gwei"),
    maxPriorityFeePerGas: hre.ethers.parseUnits("30",  "gwei"),
    gasLimit: 1_500_000,
  });

  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`[OK] GoldRedemption deployed: ${address}`);

  // Update deployments/polygon_mainnet.json
  const deployments = JSON.parse(fs.readFileSync(DEPLOYMENTS_FILE, "utf8"));
  const oldAddress  = deployments.GoldRedemption;
  deployments.GoldRedemption = address;
  deployments.timestamp      = new Date().toISOString();
  fs.writeFileSync(DEPLOYMENTS_FILE, JSON.stringify(deployments, null, 2));
  console.log(`[OK] deployments/polygon_mainnet.json updated`);
  console.log(`     old: ${oldAddress}`);
  console.log(`     new: ${address}\n`);

  console.log("Next steps:");
  console.log(`  1. Grant BURNER_ROLE on VPAYToken to new address:`);
  console.log(`     node scripts/wire_roles.js  (update ADDRS.GoldRedemption in script first)`);
  console.log(`  2. Set gold backing (e.g. 100 = 0.01g per VPAY):`);
  console.log(`     await goldRedemption.setGoldBacking(100)`);
  console.log(`  3. Fund the reserve pool with USDC:`);
  console.log(`     await goldRedemption.fundReserves(amount)`);
  console.log(`  4. Verify on Polygonscan:`);
  console.log(`     npx hardhat verify --network polygon_mainnet ${address} ${VPAY_TOKEN} ${USDC} ${CHAINLINK_XAU}`);
}

main().catch(e => { console.error("ERROR:", e.message); process.exit(1); });
