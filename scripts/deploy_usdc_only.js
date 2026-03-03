const hre = require("hardhat");

async function main() {
  console.log("Deploying Mock USDC...");
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log(`✅ MOCK USDC: ${usdc.address}`);
}

main().catch(console.error);
