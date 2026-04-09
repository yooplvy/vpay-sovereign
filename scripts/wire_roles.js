// wire_roles.js
// Grants all missing protocol roles after deployment.
//
// Roles granted:
//   UPDATER_ROLE  → ReserveOracle    (target: KEEPER_ADDRESS or deployer)
//   ORACLE_ROLE   → CircuitBreaker   (target: KEEPER_ADDRESS or deployer)
//   FEE_PROCESSOR_ROLE → StakingModule (target: VPAYVault)
//   BURNER_ROLE   → VPAYToken        (target: StakingModule)
//   BURNER_ROLE   → VPAYToken        (target: GoldRedemption)
//
// Usage:
//   KEEPER_ADDRESS=0x... node scripts/wire_roles.js
//   (omit KEEPER_ADDRESS to use the deployer EOA as keeper)

const { ethers } = require("ethers");
require("dotenv").config();

const RPC_URL = process.env.POLYGON_RPC_URL || "https://polygon-bor-rpc.publicnode.com";
const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet   = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

// ── Addresses from deployments/polygon_mainnet.json ────────────────────────
const ADDRS = {
  VPAYToken:       "0x37f68e66d142C31a2c01Eb36e8b5227bfC04B4Dc",
  ReserveOracle:   "0x6E352C668dB20D1e76d833e22455F5BBda18b6D9",
  CircuitBreaker:  "0xA6500cA2dcF8E9F67a71F7aA9795cA2d51FE9ba9",
  StakingModule:   "0x549215Ac647E763E77a8e8dB923C75176c19DF0b",
  VPAYVault:       "0x1B6d93dB06521F22cAF31DfF251f277A619586B3",
  GoldRedemption:  "0x72CaF0Ae3765A57eEC0aeb2A44Cd2Be57f810B83",
};

const KEEPER = process.env.KEEPER_ADDRESS || wallet.address;

const ACCESS_ABI = [
  "function grantRole(bytes32 role, address account) external",
  "function hasRole(bytes32 role, address account) external view returns (bool)",
];

// Polygon EIP-1559 gas — let provider estimate base fee, set a generous tip
const GAS_OVERRIDES = {
  maxFeePerGas:         ethers.parseUnits("300", "gwei"),
  maxPriorityFeePerGas: ethers.parseUnits("30",  "gwei"),
  gasLimit: 150000,
};

const ROLES = {
  UPDATER_ROLE:       ethers.keccak256(ethers.toUtf8Bytes("UPDATER_ROLE")),
  ORACLE_ROLE:        ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE")),
  FEE_PROCESSOR_ROLE: ethers.keccak256(ethers.toUtf8Bytes("FEE_PROCESSOR_ROLE")),
  BURNER_ROLE:        ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE")),
};

async function grantIfMissing(label, contract, role, grantee) {
  const already = await contract.hasRole(role, grantee);
  if (already) {
    console.log(`  [SKIP] ${label} — already granted`);
    return;
  }
  const tx = await contract.grantRole(role, grantee, GAS_OVERRIDES);
  console.log(`  [TX]   ${label} → ${tx.hash}`);
  const r = await tx.wait(2);
  console.log(`  [OK]   Confirmed block ${r.blockNumber}`);
}

async function main() {
  const bal = await provider.getBalance(wallet.address);

  console.log("=== VPAY Role Wiring ===");
  console.log(`Deployer : ${wallet.address}`);
  console.log(`Keeper   : ${KEEPER}`);
  console.log(`Balance  : ${ethers.formatEther(bal)} POL\n`);

  const reserveOracle  = new ethers.Contract(ADDRS.ReserveOracle,  ACCESS_ABI, wallet);
  const circuitBreaker = new ethers.Contract(ADDRS.CircuitBreaker, ACCESS_ABI, wallet);
  const stakingModule  = new ethers.Contract(ADDRS.StakingModule,  ACCESS_ABI, wallet);
  const vpayToken      = new ethers.Contract(ADDRS.VPAYToken,      ACCESS_ABI, wallet);

  console.log("1. ReserveOracle — UPDATER_ROLE");
  await grantIfMissing(`UPDATER_ROLE → ${KEEPER}`, reserveOracle, ROLES.UPDATER_ROLE, KEEPER);

  console.log("\n2. CircuitBreaker — ORACLE_ROLE");
  await grantIfMissing(`ORACLE_ROLE → ${KEEPER}`, circuitBreaker, ROLES.ORACLE_ROLE, KEEPER);

  console.log("\n3. StakingModule — FEE_PROCESSOR_ROLE");
  await grantIfMissing(`FEE_PROCESSOR_ROLE → VPAYVault`, stakingModule, ROLES.FEE_PROCESSOR_ROLE, ADDRS.VPAYVault);

  console.log("\n4. VPAYToken — BURNER_ROLE → StakingModule");
  await grantIfMissing(`BURNER_ROLE → StakingModule`, vpayToken, ROLES.BURNER_ROLE, ADDRS.StakingModule);

  console.log("\n5. VPAYToken — BURNER_ROLE → GoldRedemption");
  await grantIfMissing(`BURNER_ROLE → GoldRedemption`, vpayToken, ROLES.BURNER_ROLE, ADDRS.GoldRedemption);

  console.log("\n=== DONE ===");
  console.log(`  ReserveOracle.UPDATER_ROLE      → ${KEEPER}`);
  console.log(`  CircuitBreaker.ORACLE_ROLE       → ${KEEPER}`);
  console.log(`  StakingModule.FEE_PROCESSOR_ROLE → VPAYVault`);
  console.log(`  VPAYToken.BURNER_ROLE            → StakingModule`);
  console.log(`  VPAYToken.BURNER_ROLE            → GoldRedemption`);
  console.log("\nNext: redeploy GoldRedemption, then call setGoldBacking() + fundReserves().");
}

main().catch(e => { console.error("ERROR:", e.message); process.exit(1); });
