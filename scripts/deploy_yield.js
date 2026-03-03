const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🚀 Yield Deployer: ${deployer.address}`);

  // 1. Deploy Mocks
  const USDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();
  console.log(`✅ USDC: ${usdc.address}`);

  const Oracle = await hre.ethers.getContractFactory("MockOracle");
  const oracle = await Oracle.deploy(8, 2000 * 1e8);
  await oracle.deployed();
  console.log(`✅ Oracle: ${oracle.address}`);

  // 2. Deploy Token
  const Token = await hre.ethers.getContractFactory("VPAYToken");
  const token = await Token.deploy();
  await token.deployed();
  console.log(`✅ VPAY Token: ${token.address}`);

  // 3. Deploy Staking Module
  const Staking = await hre.ethers.getContractFactory("StakingModule");
  const staking = await Staking.deploy(usdc.address, token.address);
  await staking.deployed();
  console.log(`✅ Staking Module: ${staking.address}`);

  // 4. Deploy Core
  const Node = await hre.ethers.getContractFactory("SovereignNode");
  const node = await Node.deploy();
  await node.deployed();
  console.log(`✅ Node: ${node.address}`);

  const Vault = await hre.ethers.getContractFactory("VPAYVault");
  const vault = await Vault.deploy(node.address, usdc.address, deployer.address, oracle.address);
  await vault.deployed();
  console.log(`✅ Vault: ${vault.address}`);

  // 5. Wiring
  console.log("Wiring Contracts...");
  
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  const MINTER_ROLE = hre.ethers.utils.id("MINTER_ROLE");
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");

  await node.grantRole(NODE_ROLE, deployer.address);
  await token.grantRole(MINTER_ROLE, staking.address);
  await token.grantRole(BURNER_ROLE, staking.address);
  await vault.setStakingModule(staking.address);

  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await node.registerNode(nodeId, deployer.address);

  await usdc.transfer(vault.address, hre.ethers.utils.parseUnits("10000", 6));

  console.log("\n═══════════════════════════════════");
  console.log("  YIELD STACK DEPLOYED");
  console.log("═══════════════════════════════════");
  console.log(`USDC:    ${usdc.address}`);
  console.log(`TOKEN:   ${token.address}`);
  console.log(`STAKE:   ${staking.address}`);
  console.log(`NODE:    ${node.address}`);
  console.log(`VAULT:   ${vault.address}`);
}

main().catch(console.error);
