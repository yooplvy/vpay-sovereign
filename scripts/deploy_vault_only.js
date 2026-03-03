const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NODE = "0x63D4E0026cc27516Cb46c011d6D0a46CBbD28407";
  const USDC = "0x4C62289eAF3c7D35c520417Df9524CD2c26E8658";
  const ORACLE = "0xaDf1CB61E1fB6f8C6BB2416c575377de119CEE53";

  console.log("Deploying VPAY Vault...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(NODE, USDC, deployer.address, ORACLE);
  await vault.deployed();
  console.log(`✅ VPAY VAULT: ${vault.address}`);
}

main().catch(console.error);
