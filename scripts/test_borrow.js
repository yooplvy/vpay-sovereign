const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const VAULT_ADDRESS = "0xb3d2e1bD2BC0E7bf6b772dE3caf2812eE417e84E";
  const VAULT_ABI = [
    "function lockAndBorrow(bytes32 nodeId, uint256 amount, uint256 durationDays) external",
    "function loans(bytes32) view returns (uint256, uint256, uint256, uint256, bool, bytes32)"
  ];

  const vault = new hre.ethers.Contract(VAULT_ADDRESS, VAULT_ABI, deployer);
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  
  console.log("Requesting Loan of 100 USDC...");
  
  // Borrow 100 USDC for 30 days
  const amount = hre.ethers.utils.parseUnits("100", 6);
  const tx = await vault.lockAndBorrow(nodeId, amount, 30);
  await tx.wait();
  
  console.log("✅ LOAN ACTIVE!");
  console.log("Check your MetaMask for 99.5 USDC (0.5 fee paid).");
}

main().catch(console.error);
