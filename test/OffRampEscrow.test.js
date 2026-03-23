const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OffRampEscrow", function () {
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
    const token = await PaymentSOV.deploy("Sovereign Payment Token", "pSOV",
      lzEndpoint.address, owner.address);
    await token.deployed();

    const OffRampEscrow = await ethers.getContractFactory("OffRampEscrow");
    const escrow = await OffRampEscrow.deploy(token.address, owner.address);
    await escrow.deployed();

    // Grant BURNER_ROLE to escrow (it calls token.burn on release)
    await token.grantRole(await token.BURNER_ROLE(), escrow.address);
    // Grant MINTER_ROLE to owner for test setup (mint tokens to user)
    await token.grantRole(await token.MINTER_ROLE(), owner.address);
    // Grant GATEWAY_ROLE on escrow
    await escrow.grantRole(await escrow.GATEWAY_ROLE(), gateway.address);

    // Mint 100 pSOV to user
    await token.mint(user.address, ethers.utils.parseEther("100"));

    return { token, escrow, owner, gateway, user, other };
  }

  describe("Deposit", () => {
    it("user deposits SOV into escrow", async () => {
      const { escrow, token, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_1");
      const amt = ethers.utils.parseEther("10");
      // User must approve escrow first
      await token.connect(user).approve(escrow.address, amt);
      await expect(escrow.connect(user).deposit(txId, amt))
        .to.emit(escrow, "SOVEscrowed")
        .withArgs(txId, user.address, amt);
      expect(await token.balanceOf(escrow.address)).to.equal(amt);
    });

    it("cannot deposit duplicate txId", async () => {
      const { escrow, token, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_1");
      const amt = ethers.utils.parseEther("10");
      await token.connect(user).approve(escrow.address, amt.mul(2));
      await escrow.connect(user).deposit(txId, amt);
      await expect(escrow.connect(user).deposit(txId, amt))
        .to.be.revertedWithCustomError(escrow, "TxAlreadyExists");
    });
  });

  describe("Release (burns SOV)", () => {
    it("gateway releases escrow — SOV burned, not returned", async () => {
      const { escrow, token, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_2");
      const amt = ethers.utils.parseEther("10");
      await token.connect(user).approve(escrow.address, amt);
      await escrow.connect(user).deposit(txId, amt);

      const balanceBefore = await token.balanceOf(user.address);
      await expect(escrow.connect(gateway).release(txId))
        .to.emit(token, "Transfer")
        .withArgs(escrow.address, ethers.constants.AddressZero, amt); // burn event

      // User balance unchanged (SOV was already in escrow, now burned)
      expect(await token.balanceOf(user.address)).to.equal(balanceBefore);
      expect(await token.balanceOf(escrow.address)).to.equal(0);
    });

    it("non-gateway cannot release", async () => {
      const { escrow, token, user, other } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_3");
      const amt = ethers.utils.parseEther("10");
      await token.connect(user).approve(escrow.address, amt);
      await escrow.connect(user).deposit(txId, amt);
      await expect(escrow.connect(other).release(txId))
        .to.be.revertedWithCustomError(escrow, "AccessControlUnauthorizedAccount");
    });

    it("cannot release twice (idempotency)", async () => {
      const { escrow, token, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_4");
      const amt = ethers.utils.parseEther("10");
      await token.connect(user).approve(escrow.address, amt);
      await escrow.connect(user).deposit(txId, amt);
      await escrow.connect(gateway).release(txId);
      await expect(escrow.connect(gateway).release(txId))
        .to.be.revertedWithCustomError(escrow, "TxAlreadyProcessed");
    });
  });

  describe("Refund (disbursement failed)", () => {
    it("gateway refunds escrow — SOV returned to depositor", async () => {
      const { escrow, token, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_5");
      const amt = ethers.utils.parseEther("10");
      await token.connect(user).approve(escrow.address, amt);
      await escrow.connect(user).deposit(txId, amt);

      const balanceBefore = await token.balanceOf(user.address);
      await expect(escrow.connect(gateway).refund(txId))
        .to.emit(escrow, "SOVRefunded")
        .withArgs(txId, user.address, amt);

      expect(await token.balanceOf(user.address)).to.equal(balanceBefore.add(amt));
    });

    it("cannot refund after release", async () => {
      const { escrow, token, gateway, user } = await loadFixture(deployFixture);
      const txId = ethers.utils.id("tx_off_6");
      const amt = ethers.utils.parseEther("10");
      await token.connect(user).approve(escrow.address, amt);
      await escrow.connect(user).deposit(txId, amt);
      await escrow.connect(gateway).release(txId);
      await expect(escrow.connect(gateway).refund(txId))
        .to.be.revertedWithCustomError(escrow, "TxAlreadyProcessed");
    });
  });
});
