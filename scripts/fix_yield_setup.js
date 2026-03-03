const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const TOKEN_ADDRESS = "0x480e1a1933435d8f299e4a0b45DCC5AE62A9d6F8";
  const STAKING_ADDRESS = "0xA0aC2670EDFe5012272Ba4f1982B070bECb9799E";
  const NODE_ADDRESS = "0x0E4fe542660D581984F6b02037FF0048C1fF287b";
  const VAULT_ADDRESS = "0x7e210488DE45b3506188Ca91de72db34Fa079b2f";
  const USDC_ADDRESS = "0x01F8ba946F5E3643DD9C3fF9b65eAf2BC8f0eaaB";

  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.attach(TOKEN_ADDRESS);

  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.attach(NODE_ADDRESS);

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.attach(VAULT_ADDRESS);

  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.attach(USDC_ADDRESS);

  const highGas = { gasPrice: hre.ethers.utils.parseUnits("15", "gwei") };

  // 1. Grant Roles
  console.log("Granting Roles...");
  const MINTER_ROLE = hre.ethers.utils.id("MINTER_ROLE");
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");

  await (await token.grantRole(MINTER_ROLE, STAKING_ADDRESS, highGas)).wait();
  console.log("✅ MINTER granted to Staking.");

  await (await token.grantRole(BURNER_ROLE, STAKING_ADDRESS, highGas)).wait();
  console.log("✅ BURNER granted to Staking.");

  await (await node.grantRole(NODE_ROLE, deployer.address, highGas)).wait();
  console.log("✅ NODE_ROLE granted.");

  // 2. Wire Vault
  console.log("Wiring Vault...");
  await (await vault.setStakingModule(STAKING_ADDRESS, highGas)).wait();
  console.log("✅ Staking Module connected.");

  // 3. Register Node #1
  console.log("Registering Node...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await (await node.registerNode(nodeId, deployer.address, highGas)).wait();
  console.log("✅ Node Registered.");

  // 4. Fund Vault
  console.log("Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  await (await usdc.transfer(VAULT_ADDRESS, amount, highGas)).wait();
  console.log("✅ Vault Funded.");
}

main().catch(console.error);
