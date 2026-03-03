const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const VAULT_ADDRESS = "0x518FD93dd10622028B7a68767B4e89f2bb6602D0";
  const TRIAD_ADDRESS = "0xA2642ED2Ccba7F49DA7a732bD2606809bAC8543b";

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.attach(VAULT_ADDRESS);

  console.log("Wiring OracleTriad into Vault...");
  const tx = await vault.setOracle(TRIAD_ADDRESS);
  await tx.wait();
  
  console.log("✅ WIRED. Vault now uses the Safe Oracle Triad.");
}

main().catch(console.error);
