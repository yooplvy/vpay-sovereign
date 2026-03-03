const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🚀 DEPLOYING SECURE v2.2 STACK with ${deployer.address}`);

  // 1. Mocks
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log(`✅ USDC: ${usdc.address}`);

  const MockChainlink = await hre.ethers.getContractFactory("MockChainlink");
  const mockCl = await MockChainlink.deploy(2000 * 1e8);
  await mockCl.deployed();
  console.log(`✅ Chainlink: ${mockCl.address}`);

  const MockBand = await hre.ethers.getContractFactory("MockBand");
  const mockBand = await MockBand.deploy(2000 * 1e8);
  await mockBand.deployed();
  console.log(`✅ Band: ${mockBand.address}`);

  // 2. Core
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.deploy();
  await token.deployed();
  console.log(`✅ VPAY Token: ${token.address}`);

  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log(`✅ Node: ${node.address}`);

  const Oracle = await hre.ethers.getContractFactory("OracleTriad");
  const oracle = await Oracle.deploy(mockCl.address, "0x0000000000000000000000000000000000000000", mockBand.address);
  await oracle.deployed();
  console.log(`✅ Oracle: ${oracle.address}`);

  const Staking = await hre.ethers.getContractFactory("StakingModule");
  const staking = await Staking.deploy(usdc.address, token.address);
  await staking.deployed();
  console.log(`✅ Staking: ${staking.address}`);

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(node.address, usdc.address, deployer.address, oracle.address);
  await vault.deployed();
  console.log(`✅ Vault: ${vault.address}`);

  // 3. Wiring
  console.log("Wiring Roles...");
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  const FEE_PROCESSOR_ROLE = hre.ethers.utils.id("FEE_PROCESSOR_ROLE");

  await node.grantRole(NODE_ROLE, deployer.address);
  
  // Staking Permissions
  await token.grantRole(BURNER_ROLE, staking.address);
  
  // CRITICAL FIX: Grant Vault permission to call processFees
  await staking.grantRole(FEE_PROCESSOR_ROLE, vault.address);
  
  // Wire Vault
  await vault.setStakingModule(staking.address);

  // Register Node #1
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await node.registerNode(nodeId, deployer.address);

  // Fund Vault
  const fundAmount = hre.ethers.utils.parseUnits("10000", 6);
  await usdc.transfer(vault.address, fundAmount);

  console.log("\n═══════════════════════════════════");
  console.log("  SECURE v2.2 STACK DEPLOYED");
  console.log("═══════════════════════════════════");
  console.log(`Token:   ${token.address}`);
  console.log(`Node:    ${node.address}`);
  console.log(`Oracle:  ${oracle.address}`);
  console.log(`Staking: ${staking.address}`);
  console.log(`Vault:   ${vault.address}`);
}

main().catch(console.error);
