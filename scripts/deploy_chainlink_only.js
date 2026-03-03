const hre = require("hardhat");

async function main() {
  console.log("Deploying Mock Chainlink...");
  const MockChainlink = await hre.ethers.getContractFactory("MockChainlink");
  // Set initial price to $2000 (in 8 decimals)
  const mockCl = await MockChainlink.deploy(2000 * 1e8);
  await mockCl.deployed();
  console.log(`✅ MOCK CHAINLINK: ${mockCl.address}`);
}

main().catch(console.error);
