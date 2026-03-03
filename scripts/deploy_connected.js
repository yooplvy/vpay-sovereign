const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  // Existing Addresses
  const NODE_ADDR = "0xcD4Ac982ae88488e3928Ffc9999295016A513e63";
  const USDC_ADDR = "0x92816a0F67FEE598E120f9C06Ec908958A132dfb";
  const REWARDS_ADDR = "0xf627004981ea40dfB1f45642eC30cAd479F25203";

  console.log("Deploying Connected Vault...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(NODE_ADDR, USDC_ADDR, deployer.address, REWARDS_ADDR);
  await vault.deployed();
  console.log(`✅ CONNECTED VAULT: ${vault.address}`);

  // Grant Vault permission to call Rewards
  console.log("Connecting Rewards...");
  const Rewards = await hre.ethers.getContractFactory("MinerRewards");
  const rewards = await Rewards.attach(REWARDS_ADDR);
  
  // Grant ADMIN role to Vault so it can call updateReward
  // Note: MinerRewards needs a function to grant role or we do it here if deployer is admin
  // The deployer is admin, so we can grant role.
  const ADMIN_ROLE = await rewards.DEFAULT_ADMIN_ROLE(); // Actually we need to grant VAULT the right to call updateReward.
  // updateReward is `onlyRole(DEFAULT_ADMIN_ROLE)`.
  // So we grant Vault the ADMIN_ROLE (or a specific role if we update the code).
  // For simplicity in this test, let's grant ADMIN role to Vault.
  await rewards.grantRole(ADMIN_ROLE, vault.address);
  console.log("✅ Vault connected to Rewards.");

  // Fund this new Vault
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.attach(USDC_ADDR);
  
  console.log("Funding New Vault...");
  const amt = hre.ethers.utils.parseUnits("10000", 6);
  await usdc.transfer(vault.address, amt);
  console.log("✅ Funded with 10,000 USDC.");

  console.log("\n═══════════════════════════════════");
  console.log("  🔗 YIELD CONNECTED");
  console.log("═══════════════════════════════════");
  console.log(`FINAL_VAULT=${vault.address}`);
}

main().catch(console.error);
