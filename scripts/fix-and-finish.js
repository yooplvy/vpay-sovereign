// fix-and-finish.js
// MINTER_ROLE grant already done at nonce 12/13
// Nonce 13: Deploy OffRampEscrow
// Nonce 14: Deploy StakingModule
const { ethers } = require("ethers");
require("dotenv").config();
const fs = require("fs"), path = require("path");

const OffRampEscrow_ART = require("../artifacts/contracts/OffRampEscrow.sol/OffRampEscrow.json");
const StakingModule_ART = require("../artifacts/contracts/StakingModule.sol/StakingModule.json");

// Use 1rpc.io — more reliable for tx broadcast
const provider = new ethers.providers.JsonRpcProvider("https://1rpc.io/matic");
const wallet   = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

const ADDR = {
  paymentSOV: "0x3451222D576AF7Ee994915C8D2B7b09a738FBF49",
  onRamp:     "0x34Dd2c07e7a6a051A08691e9d1abA23d81033779",
  usdc:       "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
  // Already deployed
  token:      "0x5833ABF0Ecfe61e85682F3720BA4d636084E0EC0",
  node:       "0x721A41B6da222697b4cc3be02715CAD2e598D834",
  oracle:     "0xE130956e443ABBecefc3BE4E33DD811C70749752",
  cb:         "0xA6500cA2dcF8E9F67a71F7aA9795cA2d51FE9ba9",
  vault:      "0x1B6d93dB06521F22cAF31DfF251f277A619586B3",
  chainlink:  "0x0C466540B2ee1a31b441671eac0ca886e051E410",
  lzEndpoint: "0x1a44076050125825900e736c501f859c50fE728c",
};

// Fixed high gas price: 400 gwei
const GAS_PRICE = ethers.utils.parseUnits("400", "gwei");

async function main() {
  const nonce = await wallet.getTransactionCount("latest");
  const bal   = await wallet.getBalance();
  console.log(`Deployer: ${wallet.address}`);
  console.log(`Balance:  ${ethers.utils.formatEther(bal)} POL`);
  console.log(`Nonce:    ${nonce} (need 14)`);
  console.log(`Gas:      400 gwei (fixed)\n`);

  if (nonce !== 14) {
    throw new Error(`Expected nonce 14, got ${nonce}. Check on-chain state.`);
  }

  console.log("MINTER_ROLE already granted to OnRampEscrow ✓ (nonces 12+13 used for role calls)\n");

  // ── nonce 14: Deploy OffRampEscrow ────────────────────────────────────────────
  console.log("Step 1: Deploy OffRampEscrow (nonce 14)...");
  const offRampFactory = new ethers.ContractFactory(
    OffRampEscrow_ART.abi, OffRampEscrow_ART.bytecode, wallet
  );
  const offRamp = await offRampFactory.deploy(ADDR.paymentSOV, wallet.address, {
    gasPrice: GAS_PRICE, gasLimit: 1500000, nonce: 14
  });
  console.log(`  tx: ${offRamp.deployTransaction.hash}`);
  await offRamp.deployed();
  console.log(`  OffRampEscrow: ${offRamp.address} ✓\n`);

  // ── nonce 15: Deploy StakingModule ────────────────────────────────────────────
  console.log("Step 2: Deploy StakingModule (nonce 15)...");
  const stakingFactory = new ethers.ContractFactory(
    StakingModule_ART.abi, StakingModule_ART.bytecode, wallet
  );
  const staking = await stakingFactory.deploy(ADDR.usdc, ADDR.paymentSOV, {
    gasPrice: GAS_PRICE, gasLimit: 2000000, nonce: 15
  });
  console.log(`  tx: ${staking.deployTransaction.hash}`);
  await staking.deployed();
  console.log(`  StakingModule: ${staking.address} ✓\n`);

  // ── Save final deployment manifest ───────────────────────────────────────────
  const manifest = {
    network:           "polygon_mainnet",
    chainId:           137,
    deployer:          wallet.address,
    timestamp:         new Date().toISOString(),
    SovereignToken:    ADDR.token,
    SovereignNode:     ADDR.node,
    OracleTriad:       ADDR.oracle,
    CircuitBreaker:    ADDR.cb,
    PaymentSOV:        ADDR.paymentSOV,
    OnRampEscrow:      ADDR.onRamp,
    OffRampEscrow:     offRamp.address,
    VPAYVault:         ADDR.vault,
    StakingModule:     staking.address,
    ChainlinkXAUUSD:   ADDR.chainlink,
    USDC:              ADDR.usdc,
    LayerZeroEndpoint: ADDR.lzEndpoint,
  };

  const outFile = path.join(__dirname, "..", "deployments", "polygon_mainnet.json");
  fs.writeFileSync(outFile, JSON.stringify(manifest, null, 2));
  console.log("Saved deployments/polygon_mainnet.json\n");

  console.log("═══════════════════════════════════════════════════");
  console.log("COMPLETE");
  console.log("═══════════════════════════════════════════════════");
  for (const [k, v] of Object.entries(manifest)) {
    if (typeof v === "string" && v.startsWith("0x")) {
      console.log(`  ${k.padEnd(22)}: ${v}`);
    }
  }
}

main().catch(e => { console.error("ERROR:", e.message); process.exit(1); });
