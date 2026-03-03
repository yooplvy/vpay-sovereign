const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NEW_VAULT = "0x518FD93dd10622028B7a68767B4e89f2bb6602D0";
  const STAKING_ADDRESS = "0xA0aC2670EDFe5012272Ba4f1982B070bECb9799E";
  const NODE_ADDRESS = "0x0E4fe542660D581984F6b02037FF0048C1fF287b";
  const TOKEN_ADDRESS = "0x480e1a1933435d8f299e4a0b45DCC5AE62A9d6F8";

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.attach(NEW_VAULT);

  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDRESS);

  const highGas = { gasPrice: hre.ethers.utils.parseUnits("15", "gwei") };

  // 1. Connect Staking Module to Vault
  console.log("Connecting Staking Module...");
  await (await vault.setStakingModule(STAKING_ADDRESS, highGas)).wait();
  console.log("✅ Staking Connected.");

  // 2. Register Node #1
  console.log("Registering Node #1...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  
  // Check if already registered to save gas
  const owner = await node.nodeOwners(nodeId);
  if (owner === "0x0000000000000000000000000000000000000000") {
      await (await node.registerNode(nodeId, deployer.address, highGas)).wait();
      console.log("✅ Node Registered.");
  } else {
      console.log("✅ Node already registered.");
  }
  
  // 3. Grant Node Role (if not already)
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  console.log("Granting Node Role...");
  await (await node.grantRole(NODE_ROLE, deployer.address, highGas)).wait();
  console.log("✅ Node Role Granted.");

  console.log("\n═══════════════════════════════════");
  console.log("  SYSTEM WIRED SUCCESSFULLY");
  console.log("═══════════════════════════════════");
}

main().catch(console.error);
