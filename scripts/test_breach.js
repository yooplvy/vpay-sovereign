const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NODE_ADDRESS = "0x7ad90B0Bc4680D111B49B671704dbC1C35BbC382";
  const NODE_ABI = ["function submitAttestation(bytes32, uint128, bool, bytes) external"];
  
  const node = new hre.ethers.Contract(NODE_ADDRESS, NODE_ABI, deployer);
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  
  console.log("⚠️ BREAKING SEAL (Simulating Wear)...");
  
  // Submit isSealed = false
  const tx = await node.submitAttestation(nodeId, 45000, false, "0x");
  await tx.wait();
  
  console.log("✅ SEAL BROKEN. GRACE PERIOD STARTED.");
}

main().catch(console.error);
