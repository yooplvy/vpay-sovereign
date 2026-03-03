const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🚀 DEPLOYER: ${deployer.address}`);
  console.log("⚙️  Mode: GAS OPTIMIZED");

  // 1. Deploy Mock USDC
  console.log("Deploying Mock USDC...");
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log(`✅ USDC: ${usdc.address}`);

  // 2. Deploy Optimized SovereignNode
  console.log("Deploying SovereignNode (Optimized)...");
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log(`✅ NODE: ${node.address}`);

  // 3. Deploy Optimized VPAYVault
  console.log("Deploying VPAYVault (Optimized)...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(node.address, usdc.address, deployer.address);
  await vault.deployed();
  console.log(`✅ VAULT: ${vault.address}`);

  // 4. Fund the Vault
  console.log("Funding Vault...");
  const fundAmount = hre.ethers.utils.parseUnits("10000", 6);
  await (await usdc.transfer(vault.address, fundAmount)).wait();
  console.log(`✅ Vault Balance: 10,000 USDC`);

  console.log("\n═══════════════════════════════════");
  console.log("  💎 OPTIMIZED DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════");
  console.log(`NEW_USDC=${usdc.address}`);
  console.log(`NEW_NODE=${node.address}`);
  console.log(`NEW_VAULT=${vault.address}`);
}

main().catch(console.error);
