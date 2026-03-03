const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🔑 ADMIN: ${deployer.address}`);

  const NODE_ADDR = "0xcD4Ac982ae88488e3928Ffc9999295016A513e63";
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDR);

  // 1. Grant Node Role
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  console.log("Granting NODE_ROLE...");
  const tx = await node.grantRole(NODE_ROLE, deployer.address);
  await tx.wait();
  console.log("✅ PERMISSION GRANTED.");

  // 2. Register Node #1
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  try {
    const tx2 = await node.registerNode(nodeId, deployer.address);
    await tx2.wait();
    console.log("✅ NODE #1 REGISTERED.");
  } catch (e) {
    console.log("Node already registered.");
  }
}

main().catch(console.error);
