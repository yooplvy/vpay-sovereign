const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  // FINAL ADDRESSES
  const TOKEN = "0x483DED1E5EfaFA509088145f4F7B3f1689f1bF5a";
  const NODE = "0x63D4E0026cc27516Cb46c011d6D0a46CBbD28407";
  const USDC = "0x19C569E0A569D2D91e848CFa26Adf4B1cF19fC43";
  const STAKING = "0x5C508FCF7E4f136d37f8bD438468B24B6aa0497C"; // SECURE STAKING
  const VAULT = "0x709707f5295FDd967Ca9c614D0EAcCcff02a5b6a";

  // Attach
  const token = await hre.ethers.getContractAt("VPAYToken", TOKEN);
  const staking = await hre.ethers.getContractAt("StakingModule", STAKING);
  const usdc = await hre.ethers.getContractAt("MockUSDC", USDC);
  const vault = await hre.ethers.getContractAt("VPAYVault", VAULT);

  console.log("1. Granting Roles...");
  
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  const FEE_PROCESSOR_ROLE = hre.ethers.utils.id("FEE_PROCESSOR_ROLE");

  // Grant Burner to Staking
  await (await token.grantRole(BURNER_ROLE, STAKING)).wait();
  console.log("✅ BURNER granted to Staking.");

  // Grant Fee Processor to Vault
  await (await staking.grantRole(FEE_PROCESSOR_ROLE, VAULT)).wait();
  console.log("✅ FEE_PROCESSOR granted to Vault.");

  console.log("2. Wiring Vault...");
  await (await vault.setStakingModule(STAKING)).wait();
  console.log("✅ Staking Module wired.");

  console.log("3. Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  await (await usdc.transfer(VAULT, amount)).wait();
  console.log("✅ Vault Funded with 10,000 USDC.");

  console.log("\n═══════════════════════════════════");
  console.log("  SYSTEM WIRED SUCCESSFULLY");
  console.log("  PRODUCTION v2.4 STACK COMPLETE");
  console.log("═══════════════════════════════════");
}

main().catch(console.error);
