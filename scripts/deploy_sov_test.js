const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  console.log("Deploying VPAY Sovereign ($SOV)...");
  const Token = await hre.ethers.getContractFactory("SovereignToken");
  const token = await Token.deploy();
  await token.deployed();
  
  console.log("\n═══════════════════════════════════");
  console.log("  ✅ BRAND UPGRADE COMPLETE");
  console.log("═══════════════════════════════════");
  console.log("Name   :", await token.name());
  console.log("Symbol :", await token.symbol());
  console.log("Supply :", hre.ethers.utils.formatUnits(await token.totalSupply(), 18));
  console.log("Address:", token.address);
}

main().catch(console.error);
