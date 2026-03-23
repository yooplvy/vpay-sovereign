const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("ReserveOracle", function () {
  before(async () => {
    const { chainId } = await ethers.provider.getNetwork();
    if (Number(chainId) !== 31337) throw new Error("Tests must run on Hardhat network.");
  });

  async function deployFixture() {
    const [owner, updater, other] = await ethers.getSigners();
    const ReserveOracle = await ethers.getContractFactory("ReserveOracle");
    const oracle = await ReserveOracle.deploy(owner.address);
    await oracle.deployed();
    const UPDATER_ROLE = await oracle.UPDATER_ROLE();
    await oracle.grantRole(UPDATER_ROLE, updater.address);
    return { oracle, owner, updater, other, UPDATER_ROLE };
  }

  describe("Initial state", () => {
    it("starts with zero ratios", async () => {
      const { oracle } = await loadFixture(deployFixture);
      const [verified, pending, total] = await oracle.reserveRatio();
      expect(verified).to.equal(0);
      expect(pending).to.equal(0);
      expect(total).to.equal(0);
    });
  });

  describe("Update verified ratio", () => {
    it("updater can set verified gold ratio", async () => {
      const { oracle, updater } = await loadFixture(deployFixture);
      await oracle.connect(updater).updateVerified(7720); // 77.20%
      const [verified, , total] = await oracle.reserveRatio();
      expect(verified).to.equal(7720);
      expect(total).to.equal(7720);
    });

    it("non-updater cannot update", async () => {
      const { oracle, other } = await loadFixture(deployFixture);
      await expect(oracle.connect(other).updateVerified(7720))
        .to.be.revertedWithCustomError(oracle, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Pending procurement state (F1)", () => {
    it("updater can set pending procurement ratio", async () => {
      const { oracle, updater } = await loadFixture(deployFixture);
      await oracle.connect(updater).updateVerified(7720);
      await oracle.connect(updater).updatePending(810); // 8.1% in procurement
      const [verified, pending, total] = await oracle.reserveRatio();
      expect(verified).to.equal(7720);
      expect(pending).to.equal(810);
      expect(total).to.equal(8530);
    });

    it("completing procurement moves pending to verified", async () => {
      const { oracle, updater } = await loadFixture(deployFixture);
      await oracle.connect(updater).updateVerified(7720);
      await oracle.connect(updater).updatePending(810);
      // GSU attests the gold — procurement complete
      await oracle.connect(updater).completeProcurement(810);
      const [verified, pending, total] = await oracle.reserveRatio();
      expect(verified).to.equal(8530); // 7720 + 810
      expect(pending).to.equal(0);
      expect(total).to.equal(8530);
    });
  });

  describe("USDC reserve (market price, not par)", () => {
    it("updater sets USDC balance and market price", async () => {
      const { oracle, updater } = await loadFixture(deployFixture);
      const balance = ethers.utils.parseUnits("100000", 6); // 100K USDC (6 decimals)
      const marketPrice = ethers.utils.parseUnits("0.9998", 6); // slight depeg
      await oracle.connect(updater).updateUSDC(balance, marketPrice);
      const [bal, price] = await oracle.usdcReserve();
      expect(bal).to.equal(balance);
      expect(price).to.equal(marketPrice);
    });
  });

  describe("Events", () => {
    it("emits RatioUpdated on verified update", async () => {
      const { oracle, updater } = await loadFixture(deployFixture);
      await expect(oracle.connect(updater).updateVerified(8000))
        .to.emit(oracle, "RatioUpdated");
    });
  });
});
