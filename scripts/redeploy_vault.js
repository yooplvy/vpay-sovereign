const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NODE_ADDRESS = "0x0E4fe542660D581984F6b02037FF0048C1fF287b";
  const USDC_ADDRESS = "0x01F8ba946F5E3643DD9C3fF9b65eAf2BC8f0eaaB";
  const ORACLE_ADDRESS = "0x74D79fEefBcE0c74483ca6b4a024DD426FeF7Fd0";

  console.log("Redeploying Vault...");
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(NODE_ADDRESS, USDC_ADDRESS, deployer.address, ORACLE_ADDRESS);
  await vault.deployed();
  console.log(`✅ NEW VAULT: ${vault.address}`);
  
  // Fund it
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.attach(USDC_ADDRESS);
  await usdc.transfer(vault.address, hre.ethers.utils.parseUnits("10000", 6));
  console.log("✅ Vault Funded.");
}

main().catch(console.error);
