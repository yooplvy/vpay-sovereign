const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Clearing Queue...");
  
  // Send 0 ETH to yourself with massive gas
  const tx = await deployer.sendTransaction({
    to: deployer.address,
    value: 0,
    gasPrice: hre.ethers.utils.parseUnits("30", "gwei"), // Very High Gas
    gasLimit: 21000
  });
  
  console.log("Clearing TX Sent. Waiting...");
  await tx.wait();
  console.log("✅ QUEUE CLEARED.");
}

main().catch(console.error);
