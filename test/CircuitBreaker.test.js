const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CircuitBreaker", function () {
  before(async () => {
    const { chainId } = await ethers.provider.getNetwork();
    if (Number(chainId) !== 31337) throw new Error("Tests must run on Hardhat network.");
  });

  async function deployFixture() {
    const [owner, oracle, other] = await ethers.getSigners();
    const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
    const cb = await CircuitBreaker.deploy(owner.address);
    await cb.deployed();
    const ORACLE_ROLE = await cb.ORACLE_ROLE();
    await cb.grantRole(ORACLE_ROLE, oracle.address);
    return { cb, owner, oracle, other, ORACLE_ROLE };
  }

  describe("Initial state", () => {
    it("starts in NORMAL state with 0 ratio", async () => {
      const { cb } = await loadFixture(deployFixture);
      expect(await cb.state()).to.equal(0); // NORMAL = 0
      expect(await cb.currentRatio()).to.equal(0);
    });

    it("canMint returns true initially", async () => {
      const { cb } = await loadFixture(deployFixture);
      expect(await cb.canMint()).to.be.true;
    });
  });

  describe("State transitions", () => {
    it("NORMAL at >= 8000 bps (80%)", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await cb.connect(oracle).updateRatio(8500, 0);
      expect(await cb.state()).to.equal(0); // NORMAL
      expect(await cb.canMint()).to.be.true;
    });

    it("ALERT at 60-80% (6000-7999 bps)", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await cb.connect(oracle).updateRatio(7000, 0);
      expect(await cb.state()).to.equal(1); // ALERT
      expect(await cb.canMint()).to.be.true; // mint still allowed
    });

    it("PAUSED at 40-60% (4000-5999 bps)", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await cb.connect(oracle).updateRatio(5000, 0);
      expect(await cb.state()).to.equal(2); // PAUSED
      expect(await cb.canMint()).to.be.false;
    });

    it("REVERTED below hard floor (< 4000 bps = 40%)", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await cb.connect(oracle).updateRatio(3000, 0);
      expect(await cb.state()).to.equal(4); // REVERTED
      expect(await cb.canMint()).to.be.false;
    });

    it("emits StateChanged event on transition", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await expect(cb.connect(oracle).updateRatio(5000, 0))
        .to.emit(cb, "StateChanged");
    });

    it("emits CircuitBroken when REVERTED", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await expect(cb.connect(oracle).updateRatio(3500, 0))
        .to.emit(cb, "CircuitBroken");
    });

    it("RESUMING: enters RESUMING when ratio rises above 7000 from PAUSED", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      // Drive into PAUSED
      await cb.connect(oracle).updateRatio(5000, 0);
      expect(await cb.state()).to.equal(2); // PAUSED = 2
      // Ratio rises above 7000 — should enter RESUMING
      await cb.connect(oracle).updateRatio(7500, 0);
      expect(await cb.state()).to.equal(3); // RESUMING = 3
    });

    it("RESUMING → NORMAL after 24h above 7000 bps", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await cb.connect(oracle).updateRatio(5000, 0); // PAUSED
      await cb.connect(oracle).updateRatio(7500, 0); // RESUMING
      await time.increase(24 * 60 * 60 + 1);         // advance 24h
      // Next updateRatio should transition to NORMAL
      await cb.connect(oracle).updateRatio(7500, 0);
      expect(await cb.state()).to.equal(0); // NORMAL = 0
    });

    it("canMint returns true in RESUMING state", async () => {
      const { cb, oracle } = await loadFixture(deployFixture);
      await cb.connect(oracle).updateRatio(5000, 0); // PAUSED
      await cb.connect(oracle).updateRatio(7500, 0); // RESUMING
      expect(await cb.canMint()).to.equal(true);
    });
  });

  describe("Hard floor governance protection", () => {
    it("HARD_FLOOR constant is 4000 bps (40%)", async () => {
      const { cb } = await loadFixture(deployFixture);
      expect(await cb.HARD_FLOOR()).to.equal(4000);
    });

    it("non-oracle cannot update ratio", async () => {
      const { cb, other } = await loadFixture(deployFixture);
      await expect(cb.connect(other).updateRatio(8000, 0))
        .to.be.revertedWithCustomError(cb, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Band thresholds governance (48h timelock)", () => {
    it("proposes threshold update", async () => {
      const { cb, owner } = await loadFixture(deployFixture);
      await expect(cb.connect(owner).proposeThresholdUpdate(7500, 6000))
        .to.emit(cb, "ThresholdUpdateProposed");
    });

    it("cannot execute threshold update before 48h", async () => {
      const { cb, owner } = await loadFixture(deployFixture);
      await cb.connect(owner).proposeThresholdUpdate(7500, 6000);
      await expect(cb.connect(owner).executeThresholdUpdate())
        .to.be.revertedWithCustomError(cb, "TimelockNotExpired");
    });

    it("can execute threshold update after 48h", async () => {
      const { cb, owner } = await loadFixture(deployFixture);
      await cb.connect(owner).proposeThresholdUpdate(7500, 6000);
      await time.increase(48 * 60 * 60 + 1); // 48h + 1s
      await expect(cb.connect(owner).executeThresholdUpdate())
        .to.emit(cb, "ThresholdUpdated");
    });
  });
});
