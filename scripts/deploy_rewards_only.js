const hre = require("hardhat");

async function main() {
  // Your existing Vault Address
  const VAULT_ADDRESS = "0xEbf7f0966b2D045207c7a1F840f0f9E523A6309c";

  console.log("Deploying MinerRewards...");
  const Rewards = await hre.ethers.getContractFactory("MinerRewards");
  
  // Deploy: (vpayTokenAddress, vaultAddress)
  // We use the Vault address as the Token address for this test
  const rewards = await Rewards.deploy(VAULT_ADDRESS, VAULT_ADDRESS);
  await rewards.deployed();
  
  console.log("═══════════════════════════════════");
  console.log("  MINER REWARDS DEPLOYED");
  console.log(`  Address:   ${rewards.address}`);
  console.log("═══════════════════════════════════");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
