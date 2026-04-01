const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

// Helper: sign an attestation with all 5 physics gate fields (v6.0 TYPEHASH)
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

// All-passing sensor values — adjust one at a time to test each condition
const PASS = { massKg: 1000, massDeviation_mg: 200, r2Score: 9800, resilienceScore: 9000, isSealed: true };

async function deployFixture() {
  const [owner, nodeOwner] = await ethers.getSigners();
  const node = await (await ethers.getContractFactory("SovereignNode")).deploy();
  await node.deployed();
  const NODE_ROLE = await node.NODE_ROLE();
  const GOVERNANCE_ROLE = await node.GOVERNANCE_ROLE();
  await node.grantRole(NODE_ROLE, owner.address);
  await node.grantRole(GOVERNANCE_ROLE, owner.address);
  const nodeId = ethers.utils.formatBytes32String("GS-ACC-01");
  await node.registerNode(nodeId, owner.address);
  return { node, owner, nodeOwner, nodeId };
}

async function submitPass(node, nodeId, overrides, nonce, signer) {
  const s = { ...PASS, ...overrides };
  const sig = await signAttestation6(node, nodeId, s.massKg, s.massDeviation_mg, s.r2Score, s.resilienceScore, s.isSealed, nonce, signer);
  await node.submitAttestation(nodeId, s.massKg, s.massDeviation_mg, s.r2Score, s.resilienceScore, s.isSealed, nonce, sig);
}

describe("SovereignNode — Physics Gate (v6.0)", function () {

  before(async () => {
    const { chainId } = await ethers.provider.getNetwork();
    if (Number(chainId) !== 31337) throw new Error("Tests must run on Hardhat network.");
  });

  describe("attested() — all 5 conditions PASS", () => {
    it("returns true when all 5 conditions pass", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, {}, 1, owner);
      expect(await node.attested(nodeId)).to.be.true;
    });

    it("returns false for a node that has never been attested", async () => {
      const { node } = await loadFixture(deployFixture);
      const unknown = ethers.utils.formatBytes32String("NEVER_ATTESTED");
      expect(await node.attested(unknown)).to.be.false;
    });
  });

  describe("Condition 1 — Tamper seal", () => {
    it("attested() returns false when isSealed = false", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { isSealed: false }, 1, owner);
      expect(await node.attested(nodeId)).to.be.false;
    });
  });

  describe("Condition 2 — Mass deviation ≤ ±500mg", () => {
    it("attested() returns false when massDeviation_mg = +501 (over threshold)", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { massDeviation_mg: 501 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.false;
    });

    it("attested() returns false when massDeviation_mg = -501 (under threshold)", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { massDeviation_mg: -501 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.false;
    });

    it("attested() returns true at exactly ±500mg boundary", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { massDeviation_mg: 500 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.true;
      await submitPass(node, nodeId, { massDeviation_mg: -500 }, 2, owner);
      expect(await node.attested(nodeId)).to.be.true;
    });
  });

  describe("Condition 3 — R² ≥ 0.97 (9700 × 10000)", () => {
    it("attested() returns false when r2Score = 9699 (below threshold)", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { r2Score: 9699 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.false;
    });

    it("attested() returns true at exactly 9700 (boundary)", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { r2Score: 9700 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.true;
    });
  });

  describe("Condition 4 — ResilienceScore ≥ 0.88 (8800 × 10000)", () => {
    it("attested() returns false when resilienceScore = 8799 (below threshold)", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { resilienceScore: 8799 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.false;
    });

    it("attested() returns true at exactly 8800 (boundary)", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, { resilienceScore: 8800 }, 1, owner);
      expect(await node.attested(nodeId)).to.be.true;
    });
  });

  describe("Condition 5 — Staleness < 120s", () => {
    it("attested() returns false when attestation is exactly 120s old", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, {}, 1, owner);
      await time.increase(120);
      expect(await node.attested(nodeId)).to.be.false;
    });

    it("attested() returns false when attestation is 121s old", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, {}, 1, owner);
      await time.increase(121);
      expect(await node.attested(nodeId)).to.be.false;
    });

    it("attested() returns true when attestation is 119s old", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      await submitPass(node, nodeId, {}, 1, owner);
      await time.increase(119);
      expect(await node.attested(nodeId)).to.be.true;
    });
  });

  describe("AND-gate invariant", () => {
    it("any single failing condition closes the gate", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      const failCases = [
        { isSealed: false },
        { massDeviation_mg: 501 },
        { r2Score: 9699 },
        { resilienceScore: 8799 },
      ];
      for (let i = 0; i < failCases.length; i++) {
        await submitPass(node, nodeId, failCases[i], i + 1, owner);
        expect(await node.attested(nodeId), `Case ${i}: expected false`).to.be.false;
      }
    });
  });

  describe("EIP-712 replay protection", () => {
    it("reverts on nonce replay", async () => {
      const { node, owner, nodeId } = await loadFixture(deployFixture);
      const sig = await signAttestation6(node, nodeId, PASS.massKg, PASS.massDeviation_mg, PASS.r2Score, PASS.resilienceScore, PASS.isSealed, 1, owner);
      await node.submitAttestation(nodeId, PASS.massKg, PASS.massDeviation_mg, PASS.r2Score, PASS.resilienceScore, PASS.isSealed, 1, sig);
      await expect(
        node.submitAttestation(nodeId, PASS.massKg, PASS.massDeviation_mg, PASS.r2Score, PASS.resilienceScore, PASS.isSealed, 1, sig)
      ).to.be.revertedWith("Nonce too old");
    });
  });
});
