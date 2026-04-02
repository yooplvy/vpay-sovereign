// grant-roles.js
// Grant NODE_ROLE to Hermes and GATEWAY_ROLE to Gateway
const { ethers } = require("ethers");
require("dotenv").config();

const provider = new ethers.providers.JsonRpcProvider("https://1rpc.io/matic");
const wallet   = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

const HERMES  = "0x79B95fbCe4A83E995DcBABA3B2C2984c21D2e3af";
const GATEWAY = "0xB69808E9b18B7E33Fd00c00F0166515C5Fc600E6";

const SOV_NODE_ABI = [
  "function grantRole(bytes32 role, address account) external",
  "function NODE_ROLE() view returns (bytes32)"
];
const ON_RAMP_ABI = [
  "function grantRole(bytes32 role, address account) external",
  "function GATEWAY_ROLE() view returns (bytes32)"
];

const GAS_PRICE = ethers.utils.parseUnits("400", "gwei");

async function main() {
  const nonce = await wallet.getTransactionCount("latest");
  const bal   = await wallet.getBalance();
  console.log(`Deployer: ${wallet.address}`);
  console.log(`Balance:  ${ethers.utils.formatEther(bal)} POL`);
  console.log(`Nonce:    ${nonce}\n`);

  const sovNode  = new ethers.Contract("0x721A41B6da222697b4cc3be02715CAD2e598D834", SOV_NODE_ABI, wallet);
  const onRamp   = new ethers.Contract("0x34Dd2c07e7a6a051A08691e9d1abA23d81033779", ON_RAMP_ABI, wallet);

  const NODE_ROLE    = await sovNode.NODE_ROLE();
  const GATEWAY_ROLE = await onRamp.GATEWAY_ROLE();

  // Grant NODE_ROLE to Hermes
  console.log(`Granting NODE_ROLE to Hermes (${HERMES})...`);
  const tx1 = await sovNode.grantRole(NODE_ROLE, HERMES, {
    gasPrice: GAS_PRICE, gasLimit: 150000, nonce
  });
  console.log(`  tx: ${tx1.hash}`);
  const r1 = await tx1.wait(2);
  console.log(`  Confirmed block ${r1.blockNumber} ✓\n`);

  // Grant GATEWAY_ROLE to Gateway
  console.log(`Granting GATEWAY_ROLE to Gateway (${GATEWAY})...`);
  const tx2 = await onRamp.grantRole(GATEWAY_ROLE, GATEWAY, {
    gasPrice: GAS_PRICE, gasLimit: 150000, nonce: nonce + 1
  });
  console.log(`  tx: ${tx2.hash}`);
  const r2 = await tx2.wait(2);
  console.log(`  Confirmed block ${r2.blockNumber} ✓\n`);

  console.log("DONE");
  console.log(`  NODE_ROLE    → ${HERMES}`);
  console.log(`  GATEWAY_ROLE → ${GATEWAY}`);
}

main().catch(e => { console.error("ERROR:", e.message); process.exit(1); });
