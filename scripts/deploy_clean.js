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

  // 2. Deploy VPAYVault (Connected to our USDC)
  console.log("Deploying VPAYVault...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy("0x0000000000000000000000000000000000000001", usdc.address); // Node addr dummy
  await vault.deployed();
  console.log(`✅ VAULT: ${vault.address}`);

  // 3. Fund the Vault (Deposit 1000 USDC)
  console.log("Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("1000", 6);
  const tx = await usdc.transfer(vault.address, amount);
  await tx.wait();
  
  const bal = await usdc.balanceOf(vault.address);
  console.log(`✅ Vault Balance: ${hre.ethers.utils.formatUnits(bal, 6)} USDC`);

  console.log("═══════════════════════════════════");
  console.log("  UPDATE YOUR .ENV FILE:");
  console.log(`  NEW_USDC_ADDRESS=${usdc.address}`);
  console.log(`  NEW_VAULT_ADDRESS=${vault.address}`);
  console.log("═══════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
