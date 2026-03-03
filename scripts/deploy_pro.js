const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🚀 PRO DEPLOYER: ${deployer.address}`);

  // 1. Deploy Mock USDC
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log(`✅ USDC: ${usdc.address}`);

  // 2. Deploy Mock Oracle
  const Oracle = await hre.ethers.getContractFactory("MockOracle");
  const oracle = await Oracle.deploy(8, 2000 * 1e8); // 8 decimals, $2000 initial
  await oracle.deployed();
  console.log(`✅ ORACLE: ${oracle.address}`);

  // 3. Deploy SovereignNode
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log(`✅ NODE: ${node.address}`);

  // 4. Deploy VPAYVault (Pro)
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(node.address, usdc.address, deployer.address, oracle.address);
  await vault.deployed();
  console.log(`✅ VAULT: ${vault.address}`);

  // 5. Setup Roles
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  await node.grantRole(NODE_ROLE, deployer.address);
  console.log("✅ NODE_ROLE granted.");

  // 6. Register Node #1 (Correct 32-byte Hex)
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await node.registerNode(nodeId, deployer.address);
  console.log("✅ Node #1 Registered.");
  
  // 7. Fund Vault
  const fundAmount = hre.ethers.utils.parseUnits("10000", 6);
  await usdc.transfer(vault.address, fundAmount);
  console.log("✅ Vault Funded.");

  console.log("\n═══════════════════════════════════");
  console.log("  PRO DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════");
  console.log(`USDC=${usdc.address}`);
  console.log(`ORACLE=${oracle.address}`);
  console.log(`NODE=${node.address}`);
  console.log(`VAULT=${vault.address}`);
}

main().catch(console.error);
