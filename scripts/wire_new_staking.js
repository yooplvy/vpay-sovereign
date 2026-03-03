const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0x518FD93dd10622028B7a68767B4e89f2bb6602D0";
  const STAKING_ADDRESS = "0xF1bfDcA2503A604936bED61860821ed8559CbF21";

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.attach(VAULT_ADDRESS);

  console.log("Wiring Vault to New Staking Module...");
  const tx = await vault.setStakingModule(STAKING_ADDRESS);
  await tx.wait();
  
  console.log("✅ WIRED. Vault fees now go to Time-Lock Staking.");
}

main().catch(console.error);
