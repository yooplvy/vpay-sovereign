const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// Helper: sign a v6.0 physics gate attestation
async function signAttestation6(node, nodeId, massKg, massDeviation_mg, r2Score, resilienceScore, isSealed, nonce, signer) {
  const { chainId } = await ethers.provider.getNetwork();
  const domain = {
    name: "SovereignNode",
    version: "6.0",
    chainId: Number(chainId),
    verifyingContract: node.address,
  };
  const types = {
    Attestation: [
      { name: "nodeId",           type: "bytes32" },
      { name: "massKg",           type: "uint128" },
      { name: "massDeviation_mg", type: "int64"   },
      { name: "r2Score",          type: "uint32"  },
      { name: "resilienceScore",  type: "uint32"  },
      { name: "isSealed",         type: "bool"    },
      { name: "nonce",            type: "uint256" },
    ],
  };
  const value = { nodeId, massKg, massDeviation_mg, r2Score, resilienceScore, isSealed, nonce };
  if (typeof signer.signTypedData === "function") return signer.signTypedData(domain, types, value);
  return signer._signTypedData(domain, types, value);
}

// Submit a passing attestation (nonce must be unique per-test; use a counter or pass in)
async function submitPassingAttestation(node, nodeId, nonce, signer) {
  const sig = await signAttestation6(node, nodeId, 1000, 0, 9800, 9000, true, nonce, signer);
  await node.submitAttestation(nodeId, 1000, 0, 9800, 9000, true, nonce, sig);
}

describe("PaymentFlow — Integration", function () {
  async function deployAllFixture() {
    const [owner, gateway, user] = await ethers.getSigners();

    // LZ endpoint mock (uint32 eid)
    const lzEndpoint = await (
      await ethers.getContractFactory("MockLZEndpoint")
    ).deploy(31337);
    await lzEndpoint.deployed();

    // Token
    const token = await (
      await ethers.getContractFactory("PaymentSOV")
    ).deploy(
      "Sovereign Payment Token",
      "pSOV",
      lzEndpoint.address,
      owner.address
    );
    await token.deployed();

    // Circuit breaker
    const cb = await (
      await ethers.getContractFactory("CircuitBreaker")
    ).deploy(owner.address);
    await cb.deployed();
    await cb.grantRole(await cb.ORACLE_ROLE(), owner.address);
    await cb.updateRatio(8500, 0); // healthy — NORMAL band

    // SovereignNode — physics gate
    const node = await (await ethers.getContractFactory("SovereignNode")).deploy();
    await node.deployed();
    const NODE_ROLE = await node.NODE_ROLE();
    const GOVERNANCE_ROLE = await node.GOVERNANCE_ROLE();
    await node.grantRole(NODE_ROLE, owner.address);
    await node.grantRole(GOVERNANCE_ROLE, owner.address);
    const nodeId = ethers.utils.formatBytes32String("GS-ACC-01");
    await node.registerNode(nodeId, owner.address);

    // On-ramp escrow (now requires sovereignNode address)
    const onRamp = await (
      await ethers.getContractFactory("OnRampEscrow")
    ).deploy(token.address, cb.address, node.address, owner.address);
    await onRamp.deployed();

    // Off-ramp escrow
    const offRamp = await (
      await ethers.getContractFactory("OffRampEscrow")
    ).deploy(token.address, owner.address);
    await offRamp.deployed();

    // Wire roles
    await token.grantRole(await token.MINTER_ROLE(), onRamp.address);
    await token.grantRole(await token.BURNER_ROLE(), offRamp.address);
    await onRamp.grantRole(await onRamp.GATEWAY_ROLE(), gateway.address);
    await offRamp.grantRole(await offRamp.GATEWAY_ROLE(), gateway.address);

    return { token, cb, onRamp, offRamp, node, owner, gateway, user, nodeId };
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Test 1 — Full on-ramp: MoMo payment → SOV minted to user
  // ─────────────────────────────────────────────────────────────────────────────
  it("Test 1 — full on-ramp: gateway creates rate lock → confirms → user receives SOV", async function () {
    const { token, onRamp, node, owner, gateway, user, nodeId } = await loadFixture(deployAllFixture);

    const txId = ethers.utils.id("onramp_001");
    const sovAmount = ethers.utils.parseEther("0.00347");

    await onRamp.connect(gateway).createRateLock(txId, user.address, sovAmount);
    await submitPassingAttestation(node, nodeId, 1, owner);
    await onRamp.connect(gateway).confirmAndMint(txId, nodeId);

    expect(await token.balanceOf(user.address)).to.equal(sovAmount);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Test 2 — Full off-ramp: on-ramp first → deposit to escrow → gateway releases → SOV burned
  // ─────────────────────────────────────────────────────────────────────────────
  it("Test 2 — full off-ramp: user on-ramps → deposits to escrow → gateway releases → SOV burned", async function () {
    const { token, onRamp, offRamp, node, owner, gateway, user, nodeId } = await loadFixture(deployAllFixture);

    const sovAmount = ethers.utils.parseEther("0.00347");

    // Step 1: give user SOV via on-ramp
    const onRampTxId = ethers.utils.id("onramp_002");
    await onRamp.connect(gateway).createRateLock(onRampTxId, user.address, sovAmount);
    await submitPassingAttestation(node, nodeId, 1, owner);
    await onRamp.connect(gateway).confirmAndMint(onRampTxId, nodeId);

    // Step 2: user deposits SOV to off-ramp escrow
    const offRampTxId = ethers.utils.id("offramp_002");
    await token.connect(user).approve(offRamp.address, sovAmount);
    await offRamp.connect(user).deposit(offRampTxId, sovAmount);

    // Intermediate assertions: user balance = 0, escrow holds sovAmount
    expect(await token.balanceOf(user.address)).to.equal(0);
    expect(await token.balanceOf(offRamp.address)).to.equal(sovAmount);

    // Step 3: record total supply before release
    const totalBefore = await token.totalSupply();

    // Step 4: gateway releases (burns) — GHS confirmed delivered
    await offRamp.connect(gateway).release(offRampTxId);

    // Assertions: supply decreased by sovAmount, escrow now empty
    expect(await token.totalSupply()).to.equal(totalBefore.sub(sovAmount));
    expect(await token.balanceOf(offRamp.address)).to.equal(0);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Test 3 — Off-ramp refund: Flutterwave disbursement fails → SOV returned
  // ─────────────────────────────────────────────────────────────────────────────
  it("Test 3 — off-ramp refund: user deposits → gateway refunds → SOV returned to user", async function () {
    const { token, onRamp, offRamp, node, owner, gateway, user, nodeId } = await loadFixture(deployAllFixture);

    const sovAmount = ethers.utils.parseEther("0.00347");

    // Give user SOV via on-ramp
    const onRampTxId = ethers.utils.id("onramp_003");
    await onRamp.connect(gateway).createRateLock(onRampTxId, user.address, sovAmount);
    await submitPassingAttestation(node, nodeId, 1, owner);
    await onRamp.connect(gateway).confirmAndMint(onRampTxId, nodeId);

    // User deposits to off-ramp
    const offRampTxId = ethers.utils.id("offramp_003");
    await token.connect(user).approve(offRamp.address, sovAmount);
    await offRamp.connect(user).deposit(offRampTxId, sovAmount);

    // Gateway refunds (disbursement failed)
    await offRamp.connect(gateway).refund(offRampTxId);

    // SOV must be returned in full
    expect(await token.balanceOf(user.address)).to.equal(sovAmount);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Test 4 — Circuit breaker blocks confirmAndMint when state is PAUSED
  // ─────────────────────────────────────────────────────────────────────────────
  it("Test 4 — circuit breaker blocks on-ramp when PAUSED (ratio 5000 bps)", async function () {
    const { cb, onRamp, gateway, user, nodeId } = await loadFixture(deployAllFixture);

    const txId = ethers.utils.id("onramp_paused");
    const sovAmount = ethers.utils.parseEther("0.00347");

    // Gateway creates rate lock while circuit breaker is still NORMAL
    await onRamp.connect(gateway).createRateLock(txId, user.address, sovAmount);

    // Owner drops reserve ratio to 5000 bps → state transitions to PAUSED
    await cb.updateRatio(5000, 0);

    // confirmAndMint must revert with MintingPaused (fires before physics gate check)
    await expect(
      onRamp.connect(gateway).confirmAndMint(txId, nodeId)
    ).to.be.revertedWithCustomError(onRamp, "MintingPaused");
  });
});
