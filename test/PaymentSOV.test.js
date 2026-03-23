const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("PaymentSOV", function () {
  before(async () => {
    const { chainId } = await ethers.provider.getNetwork();
    if (Number(chainId) !== 31337) throw new Error("Tests must run on Hardhat network.");
  });

  async function deployFixture() {
    const [owner, minter, burner, user, other] = await ethers.getSigners();

    // Deploy mock LayerZero endpoint (required by OFT constructor)
    const MockLZEndpoint = await ethers.getContractFactory("MockLZEndpoint");
    const lzEndpoint = await MockLZEndpoint.deploy(31337); // local chainId
    await lzEndpoint.deployed();

    const PaymentSOV = await ethers.getContractFactory("PaymentSOV");
    const token = await PaymentSOV.deploy(
      "Sovereign Payment Token",
      "pSOV",
      lzEndpoint.address,
      owner.address // OFT delegate + Ownable owner + DEFAULT_ADMIN_ROLE
    );
    await token.deployed();

    const MINTER_ROLE = await token.MINTER_ROLE();
    const BURNER_ROLE = await token.BURNER_ROLE();

    await token.grantRole(MINTER_ROLE, minter.address);
    await token.grantRole(BURNER_ROLE, burner.address);

    return { token, owner, minter, burner, user, other, MINTER_ROLE, BURNER_ROLE };
  }

  describe("Roles", () => {
    it("owner has DEFAULT_ADMIN_ROLE", async () => {
      const { token, owner } = await loadFixture(deployFixture);
      const ADMIN = await token.DEFAULT_ADMIN_ROLE();
      expect(await token.hasRole(ADMIN, owner.address)).to.be.true;
    });

    it("minter can mint", async () => {
      const { token, minter, user } = await loadFixture(deployFixture);
      await expect(token.connect(minter).mint(user.address, ethers.utils.parseEther("100")))
        .to.emit(token, "Transfer")
        .withArgs(ethers.constants.AddressZero, user.address, ethers.utils.parseEther("100"));
      expect(await token.balanceOf(user.address)).to.equal(ethers.utils.parseEther("100"));
    });

    it("non-minter cannot mint", async () => {
      const { token, user, other } = await loadFixture(deployFixture);
      await expect(token.connect(other).mint(user.address, ethers.utils.parseEther("100")))
        .to.be.revertedWithCustomError(token, "AccessControlUnauthorizedAccount");
    });

    it("burner can burn from address", async () => {
      const { token, minter, burner, user } = await loadFixture(deployFixture);
      await token.connect(minter).mint(user.address, ethers.utils.parseEther("100"));
      await expect(token.connect(burner).burn(user.address, ethers.utils.parseEther("40")))
        .to.emit(token, "Transfer")
        .withArgs(user.address, ethers.constants.AddressZero, ethers.utils.parseEther("40"));
      expect(await token.balanceOf(user.address)).to.equal(ethers.utils.parseEther("60"));
    });

    it("non-burner cannot burn", async () => {
      const { token, minter, user, other } = await loadFixture(deployFixture);
      await token.connect(minter).mint(user.address, ethers.utils.parseEther("100"));
      await expect(token.connect(other).burn(user.address, ethers.utils.parseEther("40")))
        .to.be.revertedWithCustomError(token, "AccessControlUnauthorizedAccount");
    });

    it("minter role does NOT grant burn access", async () => {
      const { token, minter, user } = await loadFixture(deployFixture);
      await token.connect(minter).mint(user.address, ethers.utils.parseEther("100"));
      await expect(token.connect(minter).burn(user.address, ethers.utils.parseEther("40")))
        .to.be.revertedWithCustomError(token, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Burn reverts on insufficient balance", () => {
    it("reverts if burning more than balance", async () => {
      const { token, minter, burner, user } = await loadFixture(deployFixture);
      await token.connect(minter).mint(user.address, ethers.utils.parseEther("10"));
      await expect(token.connect(burner).burn(user.address, ethers.utils.parseEther("100")))
        .to.be.revertedWithCustomError(token, "ERC20InsufficientBalance");
    });
  });
});
