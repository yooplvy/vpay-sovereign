const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const USDC_ADDRESS = "0x4C62289eAF3c7D35c520417Df9524CD2c26E8658";
  
  const usdc = await hre.ethers.getContractAt("MockUSDC", USDC_ADDRESS);
  const bal = await usdc.balanceOf(deployer.address);
  
  console.log(`USDC Balance: ${hre.ethers.utils.formatUnits(bal, 6)} USDC`);
}

main().catch(console.error);
