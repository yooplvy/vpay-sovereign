const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`⛏️ MINER: ${deployer.address}`);

  const NODE_ADDR = "0xdC28716DdDdF51fd106d3149Cd3c7499EF7A1120";
  
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDR);

  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  
  // Calculate Role Hashes
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  const GOVERNANCE_ROLE = hre.ethers.utils.id("GOVERNANCE_ROLE");

  // STEP A: Grant Governance Role (if not already)
  console.log("Checking Governance Role...");
  const hasGov = await node.hasRole(GOVERNANCE_ROLE, deployer.address);
  if (!hasGov) {
    console.log("Granting Governance Role...");
    const tx0 = await node.grantRole(GOVERNANCE_ROLE, deployer.address);
    await tx0.wait();
    console.log("✅ Governance Role Granted.");
  }

  // STEP B: Register Node (Requires Governance Role)
  console.log("Registering Node...");
  try {
    const tx1 = await node.registerNode(nodeId, deployer.address);
    await tx1.wait();
    console.log("✅ Node Registered.");
  } catch (e) {
    console.log("Node already registered (continuing...)");
  }

  // STEP C: Grant Node Role (to submit physics)
  console.log("Granting Node Role...");
  const hasNode = await node.hasRole(NODE_ROLE, deployer.address);
  if (!hasNode) {
    const tx1b = await node.grantRole(NODE_ROLE, deployer.address);
    await tx1b.wait();
    console.log("✅ Node Role Granted.");
  }

  // STEP D: Submit Physics (Simulate Sealed Box)
  console.log("Simulating Physics (Sealing Box)...");
  const tx2 = await node.submitAttestation(nodeId, 45000, true, "0x");
  await tx2.wait();
  console.log("✅ Physics Submitted: SEALED.");
  
  console.log("═══════════════════════════════════");
  console.log("  MINING STATUS: ACTIVE");
  console.log(`  Node ID: ${nodeId}`);
  console.log("  Seal: TRUE (Simulated)");
  console.log("═══════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
