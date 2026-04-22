# Hermes-Agent Red-Team Prompt — Kommit v1.1

**Purpose:** Independent adversarial review of the v1.1 KommitBridge stack before Polygon Mainnet broadcast.

**How to run:** Paste the prompt below into your Hermes-Agent CLI session. Then attach (or have it read) the four files listed under **Files to review**. The agent should produce a findings report you paste back here as `Kommit-v1.1-Hermes-Agent-Findings.md`.

---

## Files to review

```
contracts/KommitBridge.sol                 # v1.1 production contract (~580 lines)
contracts/interfaces/IKommitBridge.sol     # v1.1 integrator interface
contracts/test/Kommit.t.sol                # v1.1 Foundry suite — 106 tests, 4 invariants
contracts/deploy/DeployKommit.s.sol        # v1.1 Polygon Mainnet deploy script
```

Optional context:
```
ip/provisional-patent-claims-v3.md         # Patent claims K1-K12 (the protocol intent)
Kommit-Integration-Spec.md                 # Downstream integrator guide
```

---

## Prompt

```
You are doing an adversarial pre-deploy review of a Solidity smart contract:
KommitBridge v1.1, the "Proof of Reasoning" contract for the VPAY Genesis stack.
Target chain: Polygon Mainnet. Compiler: Solc 0.8.28. Framework: Foundry.

CONTEXT (one-paragraph):
KommitBridge attests that an LLM produced a specific output under a specific
(modelWeightsHash, contextHash, seedCommit) tuple. A REASONER pre-commits to the
output with a 10-SOV bond. Anyone may challenge with a 20-SOV bond and a counter-
hash. The reasoner reveals (seed, salt) — anyone in the open challenge window can
verify the commit. Then the off-chain ORACLE replays the inference and either
slashes the reasoner (if the replay produces a different hash) or dismisses the
challenge (if it matches). If the oracle stays silent past `oracleWindow`, anyone
can call `claimByDefault` to dismiss in the reasoner's favor. If the reasoner
never reveals, anyone can call `claimByChallenger` to slash for non-cooperation.
Slashing pays 50% bounty to the challenger, remainder to MinerRewards pool.

WHAT v1.1 FIXED (from prior audit round):
  KOM-001 [CRIT] split resolveChallenge into revealSeed + oracleSlash +
    claimByDefault + claimByChallenger (v1.0 always dismissed on valid seed
    reveal, bypassing the oracle entirely).
  KOM-002 [HIGH] constructor only grants DEFAULT_ADMIN_ROLE (not REASONER/ORACLE).
  KOM-003 [MED]  setBonds enforces challengerBond >= reasonerBond > 0.
  KOM-004 [MED]  SafeERC20 throughout.
  KOM-005 [LOW]  dedicated setOracleWindow admin function.
  KOM-006 [LOW]  SeedRevealed event carries (seed, salt, oracleDeadline).
  KOM-007 [INFO] PROTOCOL_ID bumped to "VPAY-GENESIS-KOMMIT-v1.1".

WHAT I WANT FROM YOU:

1. State-machine analysis. Walk every transition. Find any path that:
   - lets a reasoner escape with their bond after lying
   - lets a challenger be unfairly slashed
   - leaves an attestation stranded (no terminal state reachable)
   - lets the same address occupy two roles to its own benefit

2. Token accounting. Confirm that for every settlement branch, tokens-in = tokens-out
   (no value created or lost). Pay special attention to the slash branch where
   bond is split into bounty + pool share via integer math.

3. Reentrancy and call ordering. SafeERC20 + nonReentrant are in place but verify
   no state mutation happens after an external call.

4. Admin / ops footguns. List every admin setter and what damage it could do
   if mis-set. The admin will be a 2-of-3 Gnosis Safe on Polygon
   (0xFc93b70fAa2045e19CEae43d1b645b2137c68A67).

5. MEV / front-run vectors. Special attention to the `revealSeed` step
   (seed hits the public mempool) and the permissionless `claimByDefault` /
   `claimByChallenger` race conditions.

6. Deploy-script review. The script grants REASONER_ROLE + ORACLE_ROLE in the
   same broadcast as deploy + admin migration to Safe. Look for: missing checks,
   missing role grants, broken ordering, anything that could strand the contract.

7. Test coverage assessment. The Foundry suite has 106 tests + 4 invariants.
   Tell me what important edge case is NOT covered.

OUTPUT FORMAT (markdown):

  # Kommit v1.1 — Hermes-Agent Findings

  ## Summary
  | Severity | Count |
  | Critical | N |
  | High     | N |
  | Medium   | N |
  | Low      | N |
  | Info     | N |

  ## Findings
  ### [SEVERITY] short title
  - File / line:
  - Issue:
  - Exploit scenario (if applicable):
  - Recommendation:

  ## Items checked and cleared
  - bullet list

  ## Test coverage gaps
  - bullet list

  ## Verdict
  GO / NO-GO for Polygon Mainnet broadcast, with one-paragraph justification.

Be brutal. Assume the contract will hold meaningful value within 90 days of
deployment. Assume the deployer is incentivized to ship; you are the only
adversarial check before mainnet.
```

---

## After Hermes-Agent runs

Save its output as `contracts/Kommit-v1.1-Hermes-Agent-Findings.md`.
I'll then reconcile it against the internal pass (`Kommit-v1.1-RedTeam-Internal.md`) into a single delta report and we decide what (if anything) blocks broadcast.
