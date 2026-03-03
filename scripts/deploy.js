const hre = require("hardhat");

async function main() {
  const GenesisCertificate = await hre.ethers.getContractFactory("GenesisCertificate");
  
  const codeHash = "QmVPAY_GENESIS_ANO-YOOFI-AGYEI_001";
  
  console.log("Deploying Genesis Certificate...");
  const cert = await GenesisCertificate.deploy(codeHash);

  // WAIT FOR DEPLOYMENT (ETHERS V5 SYNTAX)
  await cert.deployed();

  console.log("═══════════════════════════════════");
  console.log("  GENESIS CERTIFICATE DEPLOYED");
  console.log(`  Architect: ANO-YOOFI-AGYEI`);
  // GET ADDRESS (ETHERS V5 SYNTAX)
  console.log(`  Address:   ${cert.address}`);
  console.log(`  Token ID:  1`);
  console.log("═══════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
