const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const TOKEN_ADDRESS = "0x480e1a1933435d8f299e4a0b45DCC5AE62A9d6F8";
  const USDC_ADDRESS = "0x01F8ba946F5E3643DD9C3fF9b65eAf2BC8f0eaaB";
  const ORACLE_ADDRESS = "0x74D79fEefBcE0c74483ca6b4a024DD426FeF7Fd0";

  console.log("Deploying Redemption Mechanism...");
  const Redemption = await hre.ethers.getContractFactory("GoldRedemption");
  const redemption = await Redemption.deploy(TOKEN_ADDRESS, USDC_ADDRESS, ORACLE_ADDRESS);
  await redemption.deployed();
  console.log(`✅ REDEMPTION: ${redemption.address}`);

  // Grant BURNER_ROLE to Redemption Contract
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.attach(TOKEN_ADDRESS);
  
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  await token.grantRole(BURNER_ROLE, redemption.address);
  console.log("✅ BURNER_ROLE granted to Redemption.");

  // Fund the Redemption Pool (Optional: Add 1000 USDC)
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.attach(USDC_ADDRESS);
  
  const fundAmount = hre.ethers.utils.parseUnits("1000", 6);
  await usdc.transfer(redemption.address, fundAmount);
  console.log("✅ Redemption Pool Funded with 1000 USDC.");
}

main().catch(console.error);
