const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

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

    const OnRampEscrow = await ethers.getContractFactory("OnRampEscrow");
    const escrow = await OnRampEscrow.deploy(
      token.address,
      cb.address,
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
    return { token, cb, escrow, owner, gateway, user, other, TTL };
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
    it("mints SOV to user after gateway confirms", async () => {
      const { escrow, token, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      const amt = ethers.utils.parseEther("0.00347");
      await escrow.connect(gateway).createRateLock(txId, user.address, amt);
      await expect(escrow.connect(gateway).confirmAndMint(txId))
        .to.emit(token, "Transfer")
        .withArgs(ethers.constants.AddressZero, user.address, amt);
    });

    it("reverts mint after TTL expires", async () => {
      const { escrow, gateway, user, TTL } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await time.increase(TTL + 1);
      await expect(escrow.connect(gateway).confirmAndMint(txId))
        .to.be.revertedWithCustomError(escrow, "RateLockExpired");
    });

    it("reverts mint if circuit breaker is PAUSED", async () => {
      const { escrow, cb, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("1"));
      await cb.updateRatio(5000, 0); // → PAUSED
      await expect(escrow.connect(gateway).confirmAndMint(txId))
        .to.be.revertedWithCustomError(escrow, "MintingPaused");
    });

    it("cannot confirm same txId twice (idempotency)", async () => {
      const { escrow, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx1");
      await escrow.connect(gateway).createRateLock(txId, user.address, ethers.utils.parseEther("0.001"));
      await escrow.connect(gateway).confirmAndMint(txId);
      await expect(escrow.connect(gateway).confirmAndMint(txId))
        .to.be.revertedWithCustomError(escrow, "TxAlreadyProcessed");
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
