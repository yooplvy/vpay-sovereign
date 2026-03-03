const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🔓 BREAKING SEAL for Node #1...`);

  const NODE_ADDR = "0xdC28716DdDdF51fd106d3149Cd3c7499EF7A1120";
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDR);

  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";

  // SUBMIT FALSE: The seal is broken!
  const tx = await node.submitAttestation(nodeId, 45000, false, "0x");
  await tx.wait();

  console.log("═══════════════════════════════════");
  console.log("  ⚠️ SEAL BREACH DETECTED");
  console.log("  Status: OPEN (isSealed = false)");
  console.log("═══════════════════════════════════");
  console.log("In a full version, a Liquidator Bot would now seize your collateral.");
}

main().catch(console.error);
