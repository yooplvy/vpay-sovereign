const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

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

// Submit a passing attestation to the node
async function submitPassingAttestation(node, nodeId, nonce, signer) {
  const sig = await signAttestation6(
    node, nodeId,
    1000,  // massKg
    0,     // massDeviation_mg (within ±500)
    9800,  // r2Score (≥ 9700)
    9000,  // resilienceScore (≥ 8800)
    true,  // isSealed
    nonce,
    signer
  );
  await node.submitAttestation(nodeId, 1000, 0, 9800, 9000, true, nonce, sig);
}

describe("OnRampEscrow", function () {
  before(async () => {
    const { chainId } = await ethers.provider.getNetwork();
    if (Number(chainId) !== 31337) throw new Error("Tests must run on Hardhat network.");
  });

  async function deployFixture() {
    const [owner, gateway, user, other] = await ethers.getSigners();

    const MockLZEndpoint = await ethers.getContractFactory("MockLZEndpoint");
    const lzEndpoint = await MockLZEndpoint.deploy(31337);
    await lzEndpoint.deployed();

    const PaymentSOV = await ethers.getContractFactory("PaymentSOV");
    const token = await PaymentSOV.deploy(
      "Sovereign Payment Token", "pSOV",
      lzEndpoint.address, owner.address
    );
    await token.deployed();

    const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
    const cb = await CircuitBreaker.deploy(owner.address);
    await cb.deployed();

    // Deploy SovereignNode and register a test node
    const node = await (await ethers.getContractFactory("SovereignNode")).deploy();
    await node.deployed();
    const NODE_ROLE = await node.NODE_ROLE();
    const GOVERNANCE_ROLE = await node.GOVERNANCE_ROLE();
    await node.grantRole(NODE_ROLE, owner.address);
    await node.grantRole(GOVERNANCE_ROLE, owner.address);
    const nodeId = ethers.utils.formatBytes32String("GS-ACC-01");
    await node.registerNode(nodeId, owner.address);

    const OnRampEscrow = await ethers.getContractFactory("OnRampEscrow");
    const escrow = await OnRampEscrow.deploy(
      token.address,
      cb.address,
      node.address,
      owner.address
    );
    await escrow.deployed();

    // Grant MINTER_ROLE to escrow
    await token.grantRole(await token.MINTER_ROLE(), escrow.address);
    // Grant GATEWAY_ROLE to gateway signer
    await escrow.grantRole(await escrow.GATEWAY_ROLE(), gateway.address);
    // Grant ORACLE_ROLE on circuit breaker to owner for test setup
    await cb.grantRole(await cb.ORACLE_ROLE(), owner.address);
    // Set healthy ratio so minting is allowed
    await cb.updateRatio(8500, 0);

    const TTL = 120; // 120 seconds
    return { token, cb, escrow, node, owner, gateway, user, other, TTL, nodeId };
  }

  describe("Rate lock creation", () => {
    it("gateway creates a rate lock", async () => {
      const { escrow, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      const sovAmount = ethers.utils.parseEther("0.00347");
      await expect(
        escrow.connect(gateway).createRateLock(txId, user.address, sovAmount)
      ).to.emit(escrow, "RateLockCreated").withArgs(txId, user.address, sovAmount);
    });

    it("cannot create duplicate txId", async () => {
      const { escrow, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await expect(
        escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"))
      ).to.be.revertedWithCustomError(escrow, "TxAlreadyExists");
    });

    it("non-gateway cannot create rate lock", async () => {
      const { escrow, other, user } = await loadFixture(deployFixture);
      await expect(
        escrow.connect(other).createRateLock(ethers.utils.id("tx1"), user.address, ethers.utils.parseEther("1"))
      ).to.be.revertedWithCustomError(escrow, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Mint on confirmation", () => {
    it("mints SOV to user after gateway confirms (with valid attestation)", async () => {
      const { escrow, token, node, owner, gateway, user, nodeId } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      const amt = ethers.utils.parseEther("0.00347");
      await escrow.connect(gateway).createRateLock(txId, user.address, amt);
      // Submit a passing physics gate attestation before minting
      await submitPassingAttestation(node, nodeId, 1, owner);
      await expect(escrow.connect(gateway).confirmAndMint(txId, nodeId))
        .to.emit(token, "Transfer")
        .withArgs(ethers.constants.AddressZero, user.address, amt);
    });

    it("reverts mint after TTL expires", async () => {
      const { escrow, gateway, user, nodeId, TTL } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await time.increase(TTL + 1);
      // No attestation needed — RateLockExpired fires before the physics gate check
      await expect(escrow.connect(gateway).confirmAndMint(txId, nodeId))
        .to.be.revertedWithCustomError(escrow, "RateLockExpired");
    });

    it("reverts mint if circuit breaker is PAUSED", async () => {
      const { escrow, cb, gateway, user, nodeId } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await cb.updateRatio(5000, 0); // → PAUSED
      // No attestation needed — MintingPaused fires before the physics gate check
      await expect(escrow.connect(gateway).confirmAndMint(txId, nodeId))
        .to.be.revertedWithCustomError(escrow, "MintingPaused");
    });

    it("cannot confirm same txId twice (idempotency)", async () => {
      const { escrow, node, owner, gateway, user, nodeId } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("0.001"));
      // First mint — needs a passing attestation
      await submitPassingAttestation(node, nodeId, 1, owner);
      await escrow.connect(gateway).confirmAndMint(txId, nodeId);
      // Second attempt — already MINTED
      await expect(escrow.connect(gateway).confirmAndMint(txId, nodeId))
        .to.be.revertedWithCustomError(escrow, "TxAlreadyProcessed");
    });

    it("REVERTS confirmAndMint when physics gate not attested", async () => {
      const { escrow, gateway, user, nodeId } = await loadFixture(deployFixture);
      const txId = ethers.utils.formatBytes32String("TX-GATE-TEST");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseUnits("100", 18));
      // Deliberately skip attestation — physics gate must block mint
      await expect(
        escrow.connect(gateway).confirmAndMint(txId, nodeId)
      ).to.be.revertedWith("OnRampEscrow: physics gate not attested");
    });
  });

  describe("Refund (expired / failed payment)", () => {
    it("gateway can cancel expired rate lock", async () => {
      const { escrow, gateway, user, TTL } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await time.increase(TTL + 1);
      await expect(escrow.connect(gateway).cancelRateLock(txId))
        .to.emit(escrow, "RateLockCancelled").withArgs(txId);
    });

    it("cannot cancel active (non-expired) rate lock", async () => {
      const { escrow, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await expect(escrow.connect(gateway).cancelRateLock(txId))
        .to.be.revertedWithCustomError(escrow, "RateLockStillActive");
    });
  });
});
