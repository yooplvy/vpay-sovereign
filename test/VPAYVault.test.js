const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

async function signAttestation(node, nodeId, massKg, isSealed, nonce, signer) {
  const domain = {
    name: "SovereignNode",
    version: "2.4",
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
    const [owner, user, liquidator] = await ethers.getSigners();

    const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
    await usdc.deployed();

    const chainlink = await (await ethers.getContractFactory("MockChainlink")).deploy();
    await chainlink.deployed();
    const band = await (await ethers.getContractFactory("MockBand")).deploy();
    await band.deployed();

    // PRICES: Scaled for Vault Math (Same as Production)
    await chainlink.setPrice(ethers.utils.parseUnits("2000", 24));
    await band.setPrice(ethers.utils.parseUnits("2000", 24)); 

    const token = await (await ethers.getContractFactory("SovereignToken")).deploy();
    await token.deployed();
    const node = await (await ethers.getContractFactory("SovereignNode")).deploy();
    await node.deployed();
    
    // FIX: Deploy OracleTriad matching Production (chainlink, band, band)
    // This ensures ALL slots return a valid price.
    const oracle = await (await ethers.getContractFactory("OracleTriad")).deploy(chainlink.address, band.address, band.address);
    await oracle.deployed();

    const vault = await (await ethers.getContractFactory("VPAYVault")).deploy(node.address, usdc.address, owner.address, oracle.address);
    await vault.deployed();

    const NODE_ROLE = await node.NODE_ROLE();
    const MINTER_ROLE = await token.MINTER_ROLE();
    await node.grantRole(NODE_ROLE, owner.address);

    const nodeId = ethers.utils.formatBytes32String("NODE_1");
    await node.registerNode(nodeId, owner.address);

    await usdc.transfer(vault.address, ethers.utils.parseUnits("100000", 6));

    return { token, vault, node, usdc, oracle, chainlink, band, owner, user, liquidator, nodeId, MINTER_ROLE };
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

    it("Should SUCCEED on valid borrow", async () => {
      const { vault, node, owner, nodeId, usdc } = await loadFixture(deployProtocolFixture);
      const sig = await signAttestation(node, nodeId, 1000, true, 1, owner);
      await node.submitAttestation(nodeId, 1000, true, 1, sig);
      const amount = ethers.utils.parseUnits("100", 6);
      await expect(vault.lockAndBorrow(nodeId, amount, 30)).to.changeTokenBalance(usdc, owner, amount);
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
