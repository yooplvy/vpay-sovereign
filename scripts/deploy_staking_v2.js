const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const USDC_ADDRESS = "0x01F8ba946F5E3643DD9C3fF9b65eAf2BC8f0eaaB";
  const TOKEN_ADDRESS = "0x480e1a1933435d8f299e4a0b45DCC5AE62A9d6F8";
  const VAULT_ADDRESS = "0x518FD93dd10622028B7a68767B4e89f2bb6602D0";

  console.log("Deploying Staking V2 (Flash Loan Protected)...");
  const Staking = await hre.ethers.getContractFactory("StakingModule");
  const staking = await Staking.deploy(USDC_ADDRESS, TOKEN_ADDRESS);
  await staking.deployed();
  console.log(`✅ STAKING V2: ${staking.address}`);

  // Grant Burner Role
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.attach(TOKEN_ADDRESS);
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  await token.grantRole(BURNER_ROLE, staking.address);
  console.log("✅ BURNER_ROLE granted.");

  // Wire to Vault
  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.attach(VAULT_ADDRESS);
  await vault.setStakingModule(staking.address);
  console.log("✅ WIRED to Vault.");
}

main().catch(console.error);
