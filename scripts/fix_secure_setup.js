const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NODE_ADDRESS = "0x75844d444E0AD89af0eD21a750A034ba7545bC67";
  const USDC_ADDRESS = "0x5b002726dF654ac1BA43Ba9e519fc454B07370d3";
  const VAULT_ADDRESS = "0x590b216cA5ea609Df31C602ccac22Ac63Fca6F4b";

  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDRESS);

  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.attach(USDC_ADDRESS);

  // 1. Register Node #1
  console.log("Registering Node #1...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  const tx1 = await node.registerNode(nodeId, deployer.address, { gasPrice: hre.ethers.utils.parseUnits("15", "gwei") });
  await tx1.wait();
  console.log("✅ Node Registered.");

  // 2. Fund Vault
  console.log("Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  const tx2 = await usdc.transfer(VAULT_ADDRESS, amount, { gasPrice: hre.ethers.utils.parseUnits("15", "gwei") });
  await tx2.wait();
  console.log("✅ Vault Funded.");
}

main().catch(console.error);
