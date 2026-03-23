const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.utils.formatEther(balance));

  // ── 1. CircuitBreaker ─────────────────────────────────────────
  console.log("\nDeploying CircuitBreaker...");
  const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
  const cb = await CircuitBreaker.deploy(deployer.address);
  await cb.deployed();
  console.log("CircuitBreaker:", cb.address);

  // ── 2. PaymentSOV ─────────────────────────────────────────────
  const LZ_ENDPOINT = process.env.LZ_ENDPOINT_ADDRESS;
  if (!LZ_ENDPOINT) throw new Error("Set LZ_ENDPOINT_ADDRESS in .env");

  console.log("\nDeploying PaymentSOV...");
  const PaymentSOV = await ethers.getContractFactory("PaymentSOV");
  const token = await PaymentSOV.deploy(
    "Sovereign Payment Token",
    "pSOV",
    LZ_ENDPOINT,
    deployer.address
  );
  await token.deployed();
  console.log("PaymentSOV:", token.address);

  // ── 3. ReserveOracle ──────────────────────────────────────────
  console.log("\nDeploying ReserveOracle...");
  const ReserveOracle = await ethers.getContractFactory("ReserveOracle");
  const oracle = await ReserveOracle.deploy(deployer.address);
  await oracle.deployed();
  console.log("ReserveOracle:", oracle.address);

  // ── 4. OnRampEscrow ───────────────────────────────────────────
  console.log("\nDeploying OnRampEscrow...");
  const OnRampEscrow = await ethers.getContractFactory("OnRampEscrow");
  const onRamp = await OnRampEscrow.deploy(
    token.address,
    cb.address,
    deployer.address
  );
  await onRamp.deployed();
  console.log("OnRampEscrow:", onRamp.address);

  // ── 5. OffRampEscrow ──────────────────────────────────────────
  console.log("\nDeploying OffRampEscrow...");
  const OffRampEscrow = await ethers.getContractFactory("OffRampEscrow");
  const offRamp = await OffRampEscrow.deploy(
    token.address,
    deployer.address
  );
  await offRamp.deployed();
  console.log("OffRampEscrow:", offRamp.address);

  // ── 6. Wire roles ─────────────────────────────────────────────
  console.log("\nWiring roles...");
  await token.grantRole(await token.MINTER_ROLE(), onRamp.address);
  await token.grantRole(await token.BURNER_ROLE(), offRamp.address);
  await cb.grantRole(await cb.ORACLE_ROLE(), oracle.address);
  console.log("Roles wired.");

  console.log("\n── DEPLOYMENT COMPLETE ──");
  console.log("CircuitBreaker: ", cb.address);
  console.log("PaymentSOV:     ", token.address);
  console.log("ReserveOracle:  ", oracle.address);
  console.log("OnRampEscrow:   ", onRamp.address);
  console.log("OffRampEscrow:  ", offRamp.address);
  console.log("\nNext: Grant GATEWAY_ROLE on OnRampEscrow + OffRampEscrow to Gateway wallet.");
  console.log("Next: Grant UPDATER_ROLE on ReserveOracle to Gateway wallet.");
  console.log("Next: Transfer DEFAULT_ADMIN_ROLE to Gnosis Safe multisig.");
}

main().catch((err) => { console.error(err); process.exit(1); });
