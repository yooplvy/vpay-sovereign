const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  const NODE_ADDR = "0x144bba4e85886fDb544003233a1D0a788C4814D4";
  const VAULT_ADDR = "0x34Dd2c07e7a6a051A08691e9d1abA23d81033779";
  
  const nodeId = "0x0000000000000000000000000000000000000000000000000000000000000001";
  const massKg = 1000; 
  const isSealed = true;
  const nonce = 1;

  // --- EIP-712 Domain ---
  const domain = {
    name: "SovereignNode",
    version: "2.4",
    chainId: 421614, // Arbitrum Sepolia
    verifyingContract: NODE_ADDR
  };

  // --- EIP-712 Types ---
  const types = {
    Attestation: [
      { name: "nodeId", type: "bytes32" },
      { name: "massKg", type: "uint128" },
      { name: "isSealed", type: "bool" },
      { name: "nonce", type: "uint256" }
    ]
  };

  // --- EIP-712 Value ---
  const value = {
    nodeId: nodeId,
    massKg: massKg,
    isSealed: isSealed,
    nonce: nonce
  };

  // --- Sign Typed Data ---
  console.log("Signing EIP-712 Typed Data...");
  const signature = await deployer._signTypedData(domain, types, value);
  console.log("Signature:", signature);

  // 3. Submit Attestation to Node
  const node = await hre.ethers.getContractAt("SovereignNode", NODE_ADDR);
  console.log("Submitting Attestation...");
  const txAttest = await node.submitAttestation(nodeId, massKg, isSealed, nonce, signature);
  await txAttest.wait();
  console.log("✅ ATTESTATION SUBMITTED. Node is now Sealed with 1000kg Gold.");

  // 4. Borrow $100 USDC
  const vault = await hre.ethers.getContractAt("VPAYVault", VAULT_ADDR);
  const borrowAmount = hre.ethers.utils.parseUnits("100", 6);
  
  console.log("Executing Genesis Borrow ($100 USDC)...");
  const txBorrow = await vault.lockAndBorrow(nodeId, borrowAmount, 30); 
  await txBorrow.wait();
  
  console.log("\n═══════════════════════════════════");
  console.log("  🚀 GENESIS BORROW SUCCESSFUL!");
  console.log("═══════════════════════════════════");
  console.log("Collateral: 1000kg Gold");
  console.log("Loan: 100 USDC");
  console.log("Revenue Generated: 0.5 USDC (Protocol Fee)");
}

main().catch(console.error);
