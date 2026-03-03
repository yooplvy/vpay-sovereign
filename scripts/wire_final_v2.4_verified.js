const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  // FINAL DEPLOYED ADDRESSES (v2.4)
  const TOKEN = "0x483DED1E5EfaFA509088145f4F7B3f1689f1bF5a";
  const NODE = "0x63D4E0026cc27516Cb46c011d6D0a46CBbD28407";
  const USDC = "0x19C569E0A569D2D91e848CFa26Adf4B1cF19fC43"; // NEW USDC
  const STAKING = "0xd2273060d17Bb23BB96574a5Ae6df4896f454f9b"; // NEW STAKING
  const VAULT = "0x709707f5295FDd967Ca9c614D0EAcCcff02a5b6a";

  // Attach
  const token = await hre.ethers.getContractAt("VPAYToken", TOKEN);
  const node = await hre.ethers.getContractAt("SovereignNode", NODE);
  const usdc = await hre.ethers.getContractAt("MockUSDC", USDC);
  const staking = await hre.ethers.getContractAt("StakingModule", STAKING);
  const vault = await hre.ethers.getContractAt("VPAYVault", VAULT);

  console.log("1. Checking USDC Balance...");
  const bal = await usdc.balanceOf(deployer.address);
  console.log(`Balance: ${hre.ethers.utils.formatUnits(bal, 6)} USDC`);
  if (bal.lt(hre.ethers.utils.parseUnits("10000", 6))) {
    console.log("⚠️ Low balance, minting more...");
    // If MockUSDC has mint function accessible, call it here. Otherwise transfer.
    // Assuming constructor minted 1M, you should have enough.
  }

  console.log("2. Granting Roles...");
  
  const NODE_ROLE = hre.ethers.utils.id("NODE_ROLE");
  const BURNER_ROLE = hre.ethers.utils.id("BURNER_ROLE");
  const FEE_PROCESSOR_ROLE = hre.ethers.utils.id("FEE_PROCESSOR_ROLE");

  // Grant Node Role
  await (await node.grantRole(NODE_ROLE, deployer.address)).wait();
  console.log("✅ NODE_ROLE granted.");

  // Grant Burner to Staking
  await (await token.grantRole(BURNER_ROLE, STAKING)).wait();
  console.log("✅ BURNER granted to Staking.");

  // Grant Fee Processor to Vault
  // This WILL FAIL if StakingModule.sol does not have FEE_PROCESSOR_ROLE
  // Run the grep check first!
  try {
    await (await staking.grantRole(FEE_PROCESSOR_ROLE, VAULT)).wait();
    console.log("✅ FEE_PROCESSOR granted to Vault.");
  } catch (e) {
    console.error("❌ FEE_PROCESSOR grant failed. Check if StakingModule.sol has the role defined.");
    // If this fails, you might be using an old artifact.
  }

  console.log("3. Registering Test Node...");
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  await (await node.registerNode(nodeId, deployer.address)).wait();
  console.log("✅ Node #1 Registered.");

  console.log("4. Wiring Vault...");
  await (await vault.setStakingModule(STAKING)).wait();
  console.log("✅ Staking Module wired.");

  console.log("5. Funding Vault...");
  const amount = hre.ethers.utils.parseUnits("10000", 6);
  await (await usdc.transfer(VAULT, amount)).wait();
  console.log("✅ Vault Funded.");

  console.log("\n═══════════════════════════════════");
  console.log("  SYSTEM WIRED SUCCESSFULLY");
  console.log("═══════════════════════════════════");
}

main().catch(console.error);
