const hre = require("hardhat");
async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Clearing...");
  const tx = await deployer.sendTransaction({
    to: deployer.address,
    value: 0,
    gasPrice: hre.ethers.utils.parseUnits("50", "gwei"),
    gasLimit: 21000
  });
  await tx.wait();
  console.log("✅ CLEARED.");
}
main().catch(console.error);
