const hre = require("hardhat");

async function main() {
  console.log("Deploying VPAY Token Only...");
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.deploy();
  await token.deployed();
  console.log(`✅ VPAY TOKEN: ${token.address}`);
}

main().catch(console.error);
