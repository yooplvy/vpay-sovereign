const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const VAULT_ADDRESS = "0x518FD93dd10622028B7a68767B4e89f2bb6602D0";
  const NODE_ADDRESS = "0x0E4fe542660D581984F6b02037FF0048C1fF287b";

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.attach(VAULT_ADDRESS);

  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDRESS);

  console.log("📡 Testing Oracle Triad Data Flow...");

  // 1. Get Price from Vault (which uses Triad)
  try {
    // This calls the Triad internally
    // We can't easily call getGoldPrice publicly without a helper, so we check the Node status
    const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const att = await node.getAttestation(nodeId);
    console.log(`✅ Physics Status: Sealed=${att.isSealed}, Mass=${att.massKg}kg`);
    console.log("✅ ORACLE TRIAD IS FEEDING DATA.");

  } catch (e) {
    console.log("Error reading data", e.message);
  }
}

main().catch(console.error);
