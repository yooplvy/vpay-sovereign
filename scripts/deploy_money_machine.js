const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Architect:", deployer.address);

  // 1. Deploy Mock USDC
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log("USDC:", usdc.address);

  // 2. Connect to SovereignNode
  const NODE_ADDR = "0xdC28716DdDdF51fd106d3149Cd3c7499EF7A1120";
  
  // 3. Deploy VPAYVault (Treasury = YOU)
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(NODE_ADDR, usdc.address, deployer.address);
  await vault.deployed();
  console.log("VAULT:", vault.address);

  // 4. Fund the Vault
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  await (await usdc.transfer(vault.address, amount)).wait();
  console.log("Vault Funded: 10,000 USDC");
  
  console.log("\n=== ADDRESSES ===");
  console.log(`NEW_USDC=${usdc.address}`);
  console.log(`NEW_VAULT=${vault.address}`);
}

main().catch(console.error);
