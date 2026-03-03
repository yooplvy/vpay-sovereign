const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const TOKEN = "0x0Cbd040a1281131d37663Ea67BaC98BB3f48A982";
  const NODE = "0x1bDF1eaF5ed440614C887D6cF97b2e5de50e0C99";
  const USDC = "0x4FcF30696167B4B5D95cc09655331d9331ab5f90";
  const STAKING = "0xd787EE26D7cfD2497f719848C1FC84cE1EEAeC11";
  const VAULT = "0xe9f1640142C5623ba53A897A6616843d36d54474";

  // Attach contracts
  const token = await hre.ethers.getContractAt("VPAYToken", TOKEN);
  const node = await hre.ethers.getContractAt("SovereignNode", NODE);
  const usdc = await hre.ethers.getContractAt("MockUSDC", USDC);
  const vault = await hre.ethers.getContractAt("VPAYVault", VAULT);

  console.log("1. Granting Roles...");
  
  // Roles
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  const MINTER_ROLE = hre.ethers.utils.id("MINTER_ROLE");
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");

  // Grant Node Role to deployer
  await (await node.grantRole(NODE_ROLE, deployer.address)).wait();
  console.log("✅ NODE_ROLE granted.");

  // Grant Minter & Burner to Staking
  await (await token.grantRole(MINTER_ROLE, STAKING)).wait();
  await (await token.grantRole(BURNER_ROLE, STAKING)).wait();
  console.log("✅ MINTER & BURNER granted to Staking.");

  console.log("2. Registering Test Node...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await (await node.registerNode(nodeId, deployer.address)).wait();
  console.log("✅ Node #1 Registered.");

  console.log("3. Wiring Vault...");
  await (await vault.setStakingModule(STAKING)).wait();
  console.log("✅ Staking Module wired.");

  console.log("4. Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  await (await usdc.transfer(VAULT, amount)).wait();
  console.log("✅ Vault Funded with 10,000 USDC.");

  console.log("\n═══════════════════════════════════");
  console.log("  SYSTEM WIRED SUCCESSFULLY");
  console.log("═══════════════════════════════════");
}

main().catch(console.error);
