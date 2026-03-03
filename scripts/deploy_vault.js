const hre = require("hardhat");

async function main() {
  // 1. Deploy Sovereign Node
  console.log("Deploying SovereignNode...");
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log("✅ SovereignNode deployed to:", node.address);

  // 2. Define Mock Stablecoin (Sepolia USDC)
  const USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

  // 3. Deploy VPAYVault
  console.log("Deploying VPAYVault...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(node.address, USDC_ADDRESS);
  await vault.deployed();
  console.log("✅ VPAYVault deployed to:", vault.address);

  // 4. Deploy MinerRewards
  console.log("Deploying MinerRewards...");
  const Rewards = await hre.ethers.getContractFactory("MinerRewards");
  const rewards = await Rewards.deploy(vault.address, vault.address);
  await rewards.deployed();
  console.log("✅ MinerRewards deployed to:", rewards.address);

  console.log("═══════════════════════════════════");
  console.log("  FINANCIAL LAYER DEPLOYED");
  console.log("  Architect: ANO-YOOFI-AGYEI");
  console.log("═══════════════════════════════════");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
