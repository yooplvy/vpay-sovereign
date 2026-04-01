const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

async function signAttestation(node, nodeId, massKg, isSealed, nonce, signer) {
  const domain = {
    name: "SovereignNode",
    version: "5.0",
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    verifyingContract: node.address,
  };
  const types = {
    Attestation: [
      { name: "nodeId", type: "bytes32" },
      { name: "massKg", type: "uint128" },
      { name: "isSealed", type: "bool" },
      { name: "nonce", type: "uint256" },
    ],
  };
  const value = { nodeId, massKg, isSealed, nonce };
  if (typeof signer.signTypedData === "function") return signer.signTypedData(domain, types, value);
  return signer._signTypedData(domain, types, value);
}

async function signRaw(domain, types, value, signer) {
  if (typeof signer.signTypedData === "function") return signer.signTypedData(domain, types, value);
  return signer._signTypedData(domain, types, value);
}

describe("VPAY Sovereign Stack — Security Audit v7", function () {

  before(async () => {
    const { chainId } = await ethers.provider.getNetwork();
    if (Number(chainId) !== 31337) throw new Error("Tests must run on Hardhat network.");
  });

  async function deployProtocolFixture() {
    // FIX: separate treasury signer so fee assertions are accurate
    const [owner, user, liquidator, treasury] = await ethers.getSigners();

    const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
    await usdc.deployed();

    const chainlink = await (await ethers.getContractFactory("MockChainlink")).deploy();
    await chainlink.deployed();
    const band = await (await ethers.getContractFactory("MockBand")).deploy();
    await band.deployed();

    // Chainlink returns 8-decimal $/oz; OracleTriad converts to 18-decimal $/kg.
    // At $4491/oz → ~$144,389/kg, within OracleTriad bounds [$100K–$200K/kg].
    // Band Protocol returns 18-decimal $/kg natively.
    await chainlink.setPrice(ethers.utils.parseUnits("4491", 8));
    await band.setPrice(ethers.utils.parseUnits("144395", 18));

    const token = await (await ethers.getContractFactory("SovereignToken")).deploy();
    await token.deployed();
    const node = await (await ethers.getContractFactory("SovereignNode")).deploy();
    await node.deployed();

    const oracle = await (await ethers.getContractFactory("OracleTriad")).deploy(chainlink.address, band.address);
    await oracle.deployed();

    // FIX: Use separate treasury address, not owner
    const vault = await (await ethers.getContractFactory("VPAYVault")).deploy(node.address, usdc.address, treasury.address, oracle.address);
    await vault.deployed();

    const NODE_ROLE = await node.NODE_ROLE();
    const GOVERNANCE_ROLE = await node.GOVERNANCE_ROLE();
    const MINTER_ROLE = await token.MINTER_ROLE();

    await node.grantRole(NODE_ROLE, owner.address);
    // FIX: Grant vault GOVERNANCE_ROLE so liquidateExpired can call node.transferNode
    await node.grantRole(GOVERNANCE_ROLE, vault.address);

    const nodeId = ethers.utils.formatBytes32String("NODE_1");
    await node.registerNode(nodeId, owner.address);

    await usdc.transfer(vault.address, ethers.utils.parseUnits("100000", 6));

    return { token, vault, node, usdc, oracle, chainlink, band, owner, user, liquidator, treasury, nodeId, MINTER_ROLE };
  }

  describe("Attestation Security", function () {
    it("Should REVERT on nonce replay", async () => {
      const { node, owner, nodeId } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      await expect(node.submitAttestation(nodeId, 1000, true, 1, sig)).to.be.revertedWith("Nonce too old");
    });

    it("Should REVERT on cross-chain replay", async () => {
      const { node, owner, nodeId } = await loadFixture(deployProtocolFixture);
      const wrongDomain = { name: "SovereignNode", version: "2.4", chainId: 1, verifyingContract: node.address };
      const types = { Attestation: [{ name: "nodeId", type: "bytes32" }, { name: "massKg", type: "uint128" }, { name: "isSealed", type: "bool" }, { name: "nonce", type: "uint256" }] };
      const value = { nodeId, massKg: 1000, isSealed: true, nonce: 1 };
      const sig = await signRaw(wrongDomain, types, value, owner);
      await expect(node.submitAttestation(nodeId, 1000, true, 1, sig)).to.be.reverted;
    });
  });

  describe("Borrowing Logic", function () {
    it("Should REVERT if caller does not own node", async () => {
      const { vault, user, nodeId } = await loadFixture(deployProtocolFixture);
      await expect(vault.connect(user).lockAndBorrow(nodeId, ethers.utils.parseUnits("100", 6), 30)).to.be.revertedWithCustomError(vault, "VAULT__NotOwner");
    });

    it("Should REVERT if attestation is expired", async () => {
      const { vault, node, owner, nodeId } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      await time.increase(3601);
      await expect(vault.lockAndBorrow(nodeId, ethers.utils.parseUnits("100", 6), 30)).to.be.revertedWithCustomError(vault, "VAULT__StaleAttestation");
    });

    it("Should REVERT on double borrow", async () => {
      const { vault, node, owner, nodeId } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      await vault.lockAndBorrow(nodeId, ethers.utils.parseUnits("100", 6), 30);

      const sig2 = await signAttestation(node, nodeId, 1000, true, 2, owner);
      await node.submitAttestation(nodeId, 1000, true, 2, sig2);
      await expect(vault.lockAndBorrow(nodeId, ethers.utils.parseUnits("100", 6), 30)).to.be.revertedWithCustomError(vault, "VAULT__LoanActive");
    });

    it("Should SUCCEED on valid borrow and disburse amount minus origination fee", async () => {
      const { vault, node, owner, nodeId, usdc } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);

      const amount = ethers.utils.parseUnits("100", 6);
      const fee = amount.mul(50).div(10000); // 50 bps origination fee
      const payout = amount.sub(fee);

      // FIX: owner receives payout (amount - fee), not the full requested amount
      await expect(vault.lockAndBorrow(nodeId, amount, 30)).to.changeTokenBalance(usdc, owner, payout);
      expect((await vault.loans(nodeId)).isActive).to.be.true;
    });
  });

  describe("Repayment Logic", function () {
    it("Should REVERT if caller is not borrower", async () => {
      const { vault, node, owner, user, nodeId } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      await vault.lockAndBorrow(nodeId, ethers.utils.parseUnits("100", 6), 30);
      await expect(vault.connect(user).repayLoan(nodeId)).to.be.revertedWithCustomError(vault, "VAULT__NotOwner");
    });

    it("Should clear loan on repayment", async () => {
      const { vault, node, owner, nodeId, usdc } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      const amount = ethers.utils.parseUnits("100", 6);
      await vault.lockAndBorrow(nodeId, amount, 30);
      await usdc.approve(vault.address, ethers.constants.MaxUint256);
      await expect(vault.repayLoan(nodeId)).to.emit(vault, "LoanRepaid").withArgs(nodeId);
      expect((await vault.loans(nodeId)).isActive).to.be.false;
    });

    it("Should return correct repaymentDue (full loan amount, not payout)", async () => {
      const { vault, node, owner, nodeId } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      const amount = ethers.utils.parseUnits("100", 6);
      await vault.lockAndBorrow(nodeId, amount, 30);
      // Borrower owes the full requested amount; fee was deducted from disbursement
      expect(await vault.repaymentDue(nodeId)).to.equal(amount);
    });
  });

  describe("Liquidation Logic", function () {
    it("Should REVERT if loan is not yet expired", async () => {
      const { vault, node, owner, liquidator, nodeId } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      await vault.lockAndBorrow(nodeId, ethers.utils.parseUnits("100", 6), 30);
      await expect(vault.connect(liquidator).liquidateExpired(nodeId)).to.be.revertedWithCustomError(vault, "VAULT__LoanNotExpired");
    });

    it("Should SUCCEED on expired loan: clear loan and transfer node to liquidator", async () => {
      const { vault, node, owner, liquidator, nodeId, usdc } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);

      const amount = ethers.utils.parseUnits("100", 6);
      await vault.lockAndBorrow(nodeId, amount, 30);

      await time.increase(30 * 24 * 3600 + 1); // advance past 30-day expiry

      // Liquidator needs 108% of loan amount (LIQUIDATION_PENALTY = 8%)
      const payoff = amount.mul(108).div(100);
      await usdc.transfer(liquidator.address, payoff);
      await usdc.connect(liquidator).approve(vault.address, payoff);

      await expect(vault.connect(liquidator).liquidateExpired(nodeId))
        .to.emit(vault, "LiquidationExecuted")
        .withArgs(nodeId, liquidator.address, anyValue, anyValue);

      expect((await vault.loans(nodeId)).isActive).to.be.false;
      // FIX: node ownership must transfer to liquidator, preventing re-borrow by original owner
      expect(await node.nodeOwners(nodeId)).to.equal(liquidator.address);
    });

    it("Should REVERT if liquidator provides insufficient payoff (< 105%)", async () => {
      const { vault, node, owner, liquidator, nodeId, usdc } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);

      const amount = ethers.utils.parseUnits("100", 6);
      await vault.lockAndBorrow(nodeId, amount, 30);

      await time.increase(30 * 24 * 3600 + 1);

      // Approve only 100%, not the required 105%
      await usdc.transfer(liquidator.address, amount);
      await usdc.connect(liquidator).approve(vault.address, amount);

      await expect(vault.connect(liquidator).liquidateExpired(nodeId)).to.be.reverted;
    });
  });

  describe("Token Economics", function () {
    it("Should REVERT minting beyond MAX_SUPPLY", async () => {
      const { token, owner, MINTER_ROLE } = await loadFixture(deployProtocolFixture);
      await token.grantRole(MINTER_ROLE, owner.address);
      const max = await token.MAX_SUPPLY();
      const curr = await token.totalSupply();
      await expect(token.mint(owner.address, max.sub(curr).add(1))).to.be.revertedWith("Max supply reached");
    });
  });

});
