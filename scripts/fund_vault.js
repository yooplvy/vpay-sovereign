const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log(`🏦 BANKER: ${deployer.address}`);

  // 1. Addresses
  const USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"; // Mock USDC on Sepolia
  const VAULT_ADDRESS = "0xEbf7f0966b2D045207c7a1F840f0f9E523A6309c";
  
  // 2. Connect to Contracts
  // We use a generic ERC20 ABI for the USDC token
  const ERC20_ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function transfer(address to, uint256 amount) external returns (bool)"
  ];
  
  const usdc = new hre.ethers.Contract(USDC_ADDRESS, ERC20_ABI, deployer);
  const vault = await hre.ethers.getContractAt("VPAYVault", VAULT_ADDRESS);

  // 3. Check Balance
  console.log("Checking USDC Balance...");
  let bal = await usdc.balanceOf(deployer.address);
  console.log(`Current Balance: ${hre.ethers.utils.formatUnits(bal, 6)} USDC`);

  // 4. Mint USDC (If it's a faucet/mock token that allows minting)
  // NOTE: Standard Mock USDC usually has a 'mint' function or you use a faucet.
  // If this address is a real token you can't mint, we skip to transfer if you have balance.
  // Let's assume we have tokens from a faucet or previous steps.
  
  if (bal.isZero()) {
     console.log("⚠️ NO USDC. Please get Mock USDC from a faucet or use the 'mint' function if available.");
     console.log("Attempting to mint 1000 USDC...");
     try {
        // Try to mint (common in mock contracts)
        const mintTx = await usdc.mint(deployer.address, hre.ethers.utils.parseUnits("1000", 6));
        await mintTx.wait();
        bal = await usdc.balanceOf(deployer.address);
        console.log(`✅ Minted! New Balance: ${hre.ethers.utils.formatUnits(bal, 6)} USDC`);
     } catch (e) {
        console.log("❌ Mint failed. You need to get USDC from a faucet.");
        return;
     }
  }

  // 5. Approve Vault to spend USDC
  console.log("Approving Vault...");
  const amountToDeposit = hre.ethers.utils.parseUnits("100", 6); // Deposit 100 USDC
  const approveTx = await usdc.approve(VAULT_ADDRESS, amountToDeposit);
  await approveTx.wait();
  console.log("✅ Approved.");

  // 6. Deposit (We need a 'deposit' function on the vault, or we just send it)
  // VPAYVault usually has a 'deposit' function or we add liquidity via a strategy.
  // For this demo, let's just transfer 100 USDC to the Vault to simulate liquidity.
  console.log("Depositing Liquidity...");
  const transferTx = await usdc.transfer(VAULT_ADDRESS, amountToDeposit);
  await transferTx.wait();
  
  console.log("═══════════════════════════════════");
  console.log("  💰 VAULT FUNDED");
  console.log(`  Amount: 100 USDC`);
  console.log("═══════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
