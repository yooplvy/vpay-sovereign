const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🚀 Deploying Triad System with ${deployer.address}`);

  // 1. Deploy Mock Oracles
  const MockChainlink = await hre.ethers.getContractFactory("MockChainlink");
  const mockCl = await MockChainlink.deploy(2000 * 1e8); // $2000
  await mockCl.deployed();
  console.log(`✅ Mock Chainlink: ${mockCl.address}`);

  const MockBand = await hre.ethers.getContractFactory("MockBand");
  const mockBand = await MockBand.deploy(2000 * 1e8); // $2000
  await mockBand.deployed();
  console.log(`✅ Mock Band: ${mockBand.address}`);

  // 2. Deploy OracleTriad
  const OracleTriad = await hre.ethers.getContractFactory("OracleTriad");
  // Params: Chainlink, Uniswap (use address(0) for now), Band
  const triad = await OracleTriad.deploy(
    mockCl.address,
    "0x0000000000000000000000000000000000000000", 
    mockBand.address
  );
  await triad.deployed();
  console.log(`✅ ORACLE TRIAD: ${triad.address}`);

  console.log("\n═══════════════════════════════════");
  console.log("  TRIAD SYSTEM DEPLOYED");
  console.log("═══════════════════════════════════");
  console.log(`Triad Address: ${triad.address}`);
}

main().catch(console.error);
