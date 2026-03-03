const hre = require("hardhat");

async function main() {
  console.log("Deploying Mock Band...");
  const MockBand = await hre.ethers.getContractFactory("MockBand");
  // Set initial price to $2000
  const mockBand = await MockBand.deploy(2000 * 1e8);
  await mockBand.deployed();
  console.log(`✅ MOCK BAND: ${mockBand.address}`);
}

main().catch(console.error);
