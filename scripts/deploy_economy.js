const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`💎 ECONOMY BUILDER: ${deployer.address}`);

  // 1. Deploy VPAY Token
  console.log("Deploying VPAY Token...");
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.deploy();
  await token.deployed();
  console.log(`✅ VPAY TOKEN: ${token.address}`);

  // 2. Deploy Miner Rewards
  console.log("Deploying Rewards Engine...");
  const Rewards = await hre.ethers.getContractFactory("MinerRewards");
  const rewards = await Rewards.deploy(token.address);
  await rewards.deployed();
  console.log(`✅ REWARDS: ${rewards.address}`);

  // 3. Grant Minter Role to Rewards Contract
  console.log("Granting Minter Role...");
  await token.grantRole(await token.MINTER_ROLE(), rewards.address);
  console.log("✅ Rewards can now mint VPAY!");

  console.log("\n═══════════════════════════════════");
  console.log("  💰 YIELD LAYER ONLINE");
  console.log("═══════════════════════════════════");
  console.log(`TOKEN_ADDRESS=${token.address}`);
  console.log(`REWARDS_ADDRESS=${rewards.address}`);
}

main().catch(console.error);
