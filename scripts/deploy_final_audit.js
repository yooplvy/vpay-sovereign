const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🚀 DEPLOYER: ${deployer.address}`);

  // 1. Deploy Mock USDC
  console.log("Deploying Mock USDC...");
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log(`✅ USDC: ${usdc.address}`);

  // 2. Deploy SovereignNode (Fixed)
  console.log("Deploying SovereignNode...");
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log(`✅ NODE: ${node.address}`);

  // 3. Deploy VPAYVault (Fixed)
  console.log("Deploying VPAYVault...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(node.address, usdc.address, deployer.address);
  await vault.deployed();
  console.log(`✅ VAULT: ${vault.address}`);

  // 4. Setup Permissions
  console.log("Configuring Roles...");
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  await node.grantRole(NODE_ROLE, deployer.address);
  console.log("✅ NODE_ROLE granted to deployer.");

  // 5. Register Node #1
  console.log("Registering Node #1...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await node.registerNode(nodeId, deployer.address);
  console.log("✅ Node #1 Registered.");

  // 6. Fund Vault
  console.log("Funding Vault...");
  const fundAmount = hre.ethers.utils.parseUnits("10000", 6);
  await usdc.transfer(vault.address, fundAmount);
  console.log("✅ Vault Funded with 10,000 USDC.");

  console.log("\n═══════════════════════════════════");
  console.log("  AUDIT-COMPLIANT DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════");
  console.log(`NEW_USDC=${usdc.address}`);
  console.log(`NEW_NODE=${node.address}`);
  console.log(`NEW_VAULT=${vault.address}`);
}

main().catch(console.error);
