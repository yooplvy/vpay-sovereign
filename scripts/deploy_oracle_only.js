const hre = require("hardhat");

async function main() {
  const CHAINLINK = "0xF8638038f4FFaD45dE9Ce0E8e7bd6dC7D17F23b9";
  const BAND = "0x229BF65fb67C5807D36a1581157D3e900Eb3d1eF";

  console.log("Deploying Oracle Triad...");
  const Oracle = await hre.ethers.getContractFactory("OracleTriad");
  // Args: Chainlink, Uniswap (0x0), Band
  const oracle = await Oracle.deploy(CHAINLINK, "0x0000000000000000000000000000000000000000", BAND);
  await oracle.deployed();
  console.log(`✅ ORACLE TRIAD: ${oracle.address}`);
}

main().catch(console.error);
