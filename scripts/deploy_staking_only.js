const hre = require("hardhat");

async function main() {
  const USDC = "0x19C569E0A569D2D91e848CFa26Adf4B1cF19fC43"; // Correct USDC
  const VPAY = "0x483DED1E5EfaFA509088145f4F7B3f1689f1bF5a";

  console.log("Deploying Staking Module V2.4 (Secured)...");
  const Staking = await hre.ethers.getContractFactory("StakingModule");
  const staking = await Staking.deploy(USDC, VPAY);
  await staking.deployed();
  console.log(`✅ STAKING V2.4: ${staking.address}`);
}

main().catch(console.error);
