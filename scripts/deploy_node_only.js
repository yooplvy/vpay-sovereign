const hre = require("hardhat");

async function main() {
  console.log("Deploying Sovereign Node (v2.4)...");
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log(`✅ SOVEREIGN NODE: ${node.address}`);
}

main().catch(console.error);
