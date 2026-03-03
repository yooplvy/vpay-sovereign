const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const USDC_ADDRESS = "0x01F8ba946F5E3643DD9C3fF9b65eAf2BC8f0eaaB";
  const TOKEN_ADDRESS = "0x480e1a1933435d8f299e4a0b45DCC5AE62A9d6F8";

  console.log("Deploying Time-Lock Staking...");
  const Staking = await hre.ethers.getContractFactory("StakingModule");
  const staking = await Staking.deploy(USDC_ADDRESS, TOKEN_ADDRESS);
  await staking.deployed();
  console.log(`✅ NEW STAKING: ${staking.address}`);

  // Grant Burner Role to Staking Module
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.attach(TOKEN_ADDRESS);
  
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  await token.grantRole(BURNER_ROLE, staking.address);
  console.log("✅ Burner Role Granted.");
}

main().catch(console.error);
