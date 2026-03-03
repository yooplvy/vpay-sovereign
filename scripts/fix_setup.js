const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NODE_ADDRESS = "0x1df4eF74eE74a264a58123923BAFfDedFeBd1304";
  const USDC_ADDRESS = "0x5c5aAfd602964333FC05286C0c85Aad5D3bf907F";
  const VAULT_ADDRESS = "0x8F1091d0cA4c8cd4e2E67856F674E929A0017b98";

  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDRESS);

  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.attach(USDC_ADDRESS);

  // 1. Register Node #1
  console.log("Registering Node #1...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  const tx1 = await node.registerNode(nodeId, deployer.address, { gasPrice: hre.ethers.utils.parseUnits("10", "gwei") });
  await tx1.wait();
  console.log("✅ Node Registered.");

  // 2. Fund Vault
  console.log("Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  const tx2 = await usdc.transfer(VAULT_ADDRESS, amount, { gasPrice: hre.ethers.utils.parseUnits("10", "gwei") });
  await tx2.wait();
  console.log("✅ Vault Funded.");
}

main().catch(console.error);
