# Kommit v1.1 — Internal Red-Team Pass

**Reviewer:** Claude (Cowork agent, internal pre-review)
**Date:** 2026-04-22
**Scope:** `contracts/KommitBridge.sol` (v1.1), `contracts/test/Kommit.t.sol`, `contracts/deploy/DeployKommit.s.sol`, `contracts/interfaces/IKommitBridge.sol`
**Build status:** Clean (`forge build` returns no `Error:` lines)
**Test status:** 106/106 passing, 4 invariants × 128,000 calls each, 0 reverts (last run: pre-em-dash-fix, but contracts unchanged since)

This is an adversarial pre-review intended to surface findings before the external Hermes-Agent pass. Severity follows the convention: Critical (deploy-blocker), High (deploy-blocker pending fix), Medium (operational hardening, not exploit), Low (footgun, fix opportunistically), Info (documentation/clarification).

---

## Summary

| Severity | Count | Net assessment                                                              |
|----------|-------|------------------------------------------------------------------------------|
| Critical | 0     | No deploy-blockers in the contract.                                          |
| High     | 0     | KOM-001..007 fixes all check out against the new state machine.              |
| Medium   | 3     | All operator/economic-intent concerns; none are contract exploits.           |
| Low      | 1     | Admin footgun in `setMinerRewardsPool(0)`.                                   |
| Info     | 1     | One documentation item.                                                      |

**Update 2026-04-22 (post-INFO-1 follow-through):** INFO-1 promoted to MED-3 after reading MinerRewards.sol source. Plain ERC-20 transfers land safely in MinerRewards (no hooks revert), but the "remainder to miner pool" intent in `_dismissChallenge` / `_slashReasoner` does not actually distribute to any operator — funds accumulate in the pool's contract balance with no claim path until Safe calls `creditReward()` manually. Not blocking broadcast; documented for v1.2.

**Bottom line:** v1.1 is materially sounder than v1.0. The KOM-001 split (revealSeed → oracleSlash | claimByDefault | claimByChallenger) closes the v1.0 hole where a valid seed reveal auto-dismissed without giving the oracle a chance to slash. State machine, bond accounting, and reentrancy posture are all clean. The two Medium items are operational guards I'd add at the deploy-script and runbook level, not contract patches.

---

## Findings

### MED-1 — Deploy script does not enforce `REASONER_WALLET != ORACLE_WALLET`

**File:** `contracts/deploy/DeployKommit.s.sol`

**Issue:** The deploy script reads both wallets from env vars and grants `REASONER_ROLE` and `ORACLE_ROLE` independently, but never asserts the two addresses are distinct. If the same address ends up in both, that operator can attest a reasoning, then verdict its own attestation honest via `oracleSlash` — defeating the entire fraud-proof premise of Kommit.

**Why this is operator-runbook rather than contract:** OZ AccessControl is a generic role primitive. Adding overlap-prevention into `grantRole` would require overriding it (touchy) or wrapping it in a domain-specific setter pair. Cheaper and clearer to enforce at deploy time.

**Recommendation:** Add a single `require` to `DeployKommit.s.sol` between the env reads and the broadcast:

```solidity
require(reasonerWallet != oracleWallet, "REASONER and ORACLE must be distinct (KOM-OPS-1)");
```

Place it right after the existing two `!= address(0)` requires. No contract change needed. I will apply this in the next pass if you confirm.

---

### MED-2 — Model registry has no `deregisterModel`

**File:** `contracts/KommitBridge.sol` (lines 209-218)

**Issue:** Once a model weights hash is registered, it cannot be removed. If a registered model is later found to be compromised (weights leaked, fine-tuned to game outputs, etc.), the only mitigation is to never call `attestReasoning` against it — but on-chain, anyone with `REASONER_ROLE` can keep attesting against it indefinitely. This is more "stale data" than "exploit," but it does mean the on-chain registry can drift from operator intent over time.

**Tradeoff:** Immutability of the registry is a feature for some use cases (you don't want an admin to silently de-register a model that's already been used to attest valuable reasoning). The argument for immutability is that historical attestations stay verifiable forever. The argument against is that a known-bad model can keep poisoning the stream.

**Options:**
1. Leave as-is, document immutability as intentional.
2. Add `deregisterModel(bytes32)` that flips `_registeredModel` to false but leaves `_modelName` intact for historical lookup. Future `attestReasoning` against it would revert; existing in-flight attestations are unaffected (status checks are independent).
3. Add a `modelStatus` enum (Active / Deprecated / Revoked) for richer signaling.

**My recommendation:** Option 2. Minimal surface area, preserves history, fixes the operational gap. Can be added in v1.2 — not v1.1-blocking.

---

### LOW-1 — `setMinerRewardsPool(address(0))` is a silent value-loss footgun

**File:** `contracts/KommitBridge.sol` (lines 516-518, 421, 437)

**Issue:** `setMinerRewardsPool` accepts `address(0)`. The settlement helpers (`_dismissChallenge`, `_slashReasoner`) guard against transferring to zero (`if (poolShare > 0 && minerRewardsPool != address(0))`), so token loss is averted — but the funds that *should* have gone to the pool stay stuck in the KommitBridge contract with no recovery path. Admin can re-set the pool to a real address, but funds already routed past the guard are stranded.

Wait — re-reading the code, the guard is *before* the transfer, so funds aren't actually transferred to zero. They simply don't move. That means they remain in the KommitBridge contract balance. The next `_dismissChallenge` or `_slashReasoner` won't pick them up because each call only handles its own bond. There is no `sweep` function.

**Recommendation:** One of:
1. `require(_pool != address(0), "Pool cannot be zero")` in `setMinerRewardsPool`.
2. Add a permissioned `sweepStranded(IERC20)` admin function that can recover stuck token balances minus the sum of locked bonds.

**Severity rationale:** Low because (a) it requires admin to actively misconfigure, (b) Safe multisig is the admin so it would take 2-of-3 to misconfigure, (c) funds aren't lost to a third party, only stuck. But a single `require` would close it cleanly.

---

### MED-3 — `MinerRewards` accepts the transfer but the SOV isn't distributable to operators

**File:** `contracts/KommitBridge.sol` (lines 421, 437) → `contracts/MinerRewards.sol`

**Resolution of the original INFO-1 question:** Yes, MinerRewards accepts plain ERC-20 inflows. No `receive()`, no `fallback()`, no `_beforeTokenTransfer` hook, no ERC777/ERC1363 receiver interface. SafeERC20 from KommitBridge will land cleanly in MinerRewards' SOV balance. The original concern (settlement reverts on transfer) is fully cleared.

**But — the economic intent gap:** MinerRewards' design is mint-then-credit:

```solidity
// AttestationBridge (matter attestation) pattern:
sovToken.mint(address(minerRewards), share);             // tokens land in pool
minerRewards.creditReward(nodeId, share);                // assigned to operator
// Later: operator calls claim() to withdraw.
```

KommitBridge (mind attestation) only does the first half. The `safeTransfer` puts SOV into MinerRewards' balance, but no operator's `unclaimedRewards[op]` is ever incremented because:
1. KommitBridge doesn't have `DISTRIBUTOR_ROLE` on MinerRewards, and
2. Even if it did, slashed bonds and forfeited challenger bonds have no natural `nodeId` to credit to.

**Net effect:** SOV sent by KommitBridge to MinerRewards is held by the pool contract but is unclaimable by any node operator under the current MinerRewards interface. The Safe (which holds DISTRIBUTOR_ROLE) can later call `creditReward(someNodeId, amount)` to assign these stranded balances to specific operators — but until that happens, the "remainder to miner pool" promise is vacuous.

**Severity: MED, not deploy-blocking.** Reasoning:
- Funds are not lost. They sit in MinerRewards' SOV balance, recoverable by Safe action.
- The slashing mechanism still works correctly — challenger gets bond + bounty, reasoner is slashed. The malfunctioning piece is only the *third* outflow (the "to public good" share).
- The fraud-proof economics depend on bounty → challenger (works) and bond → slashed (works). The pool share is meant as a tertiary "discourage spam" sink — degraded, not broken.

**Options for v1.2 (pick one):**
1. Add a generic `addToRewardPool()` function on MinerRewards that distributes pro-rata to all registered operators on next claim. Cleanest economic story.
2. Route KommitBridge's pool share to a dedicated `KOMMIT_REWARDS_TREASURY` address (could be the Safe). Honest about who controls it.
3. Add a synthetic `KOMMIT_POOL` nodeId that any operator can register as a co-claimant of, then KommitBridge gets `DISTRIBUTOR_ROLE` and credits to that nodeId.
4. Burn the remainder (cleanest but most aggressive — `safeTransfer` to a known burn sink that accepts inflows).

**My recommendation:** Option 2 for v1.2. Routing to Safe is honest about the control structure and avoids a MinerRewards interface change. Document the destination clearly in the integration spec.

**Pre-broadcast action:** Update `Kommit-Integration-Spec.md` and the cockpit Kommit panel to reflect the actual flow: "remainder retained in MinerRewards pool balance (Safe-administered)." Don't claim it auto-flows to operators.

---

### INFO-2 — Document `challengeDeadline` polymorphism

**File:** `contracts/KommitBridge.sol`

**Observation (not bug):** The `challengeDeadline` field on `Attestation` is reused across three semantic phases:

| Status     | What `challengeDeadline` means                       |
|------------|------------------------------------------------------|
| Pending    | When the challenge window closes                      |
| Challenged | When the reveal window closes (rolled forward at challenge) |
| Revealed   | When the oracle window closes (rolled forward at revealSeed) |

This is a smart storage optimization, but it's fully implicit — the field name says "challenge" and the comment on line 327 only documents the third roll-forward. A diligence reader looking at `attestations(id)` output will see `challengeDeadline=...` and need to check `status` to know what they're looking at.

**Recommendation:** Add a one-line note in the NatSpec for the `Attestation` struct (or the `attestations` view) explaining the polymorphism. Pure docs, no code change. Will help auditors and integrators.

---

## Items I checked and cleared

These were on my adversarial checklist; all came back clean:

- **State machine cycles:** No way to re-enter a settled state. Slashed/Dismissed/Finalized are terminal — nothing transitions back to Pending.
- **Reentrancy:** All external state-changing functions carry `nonReentrant`. SafeERC20 used uniformly. SOV is our own ERC-20 with no reentrancy hooks.
- **Bond accounting:** Token in == token out across every settlement path. Confirmed by hand-trace of all 5 settlement branches and corroborated by the invariant suite (4 invariants × 128k calls passed).
- **Mid-flight admin parameter changes:** `setBonds` only affects new attestations. Existing `a.reasonerBond` / `a.challengerBond` are snapshotted at lock time. No retroactive impact.
- **MEV / front-run on `claimByDefault` / `claimByChallenger`:** Both are permissionless after their windows. No competing transaction to front-run.
- **MEV on `revealSeed`:** Once the seed hits the mempool, it's public — but by then the attestation is in `Revealed` state and only the oracle can act. No exploitable race.
- **Salt entropy:** `bytes32` salt = 256 bits = no rainbow-table risk on `seedCommit`.
- **Reasoner self-challenge:** Possible (no role check on `challenge`), but only achieves stat inflation (`_totalChallenged++`) at a net cost of `challengerBond - reasonerBond` per cycle. Not exploitable.
- **`finalize` permissionless:** Anyone can call after challenge window. Reasoner has the strongest economic incentive to call it. No griefing vector.
- **Integer overflow:** Solidity 0.8.20 default checked arithmetic. `uint64(block.timestamp + window)` is safe through the year ~584 billion.
- **Constructor role grant (KOM-002):** Confirmed only `DEFAULT_ADMIN_ROLE` is granted to `msg.sender`. REASONER_ROLE and ORACLE_ROLE not auto-granted.
- **`setBonds` invariant (KOM-003):** Confirmed `challengerBond >= reasonerBond > 0` enforced.
- **SafeERC20 (KOM-004):** Confirmed `using SafeERC20 for IERC20;` and all 6 transfer call sites use safe wrappers.
- **`setOracleWindow` (KOM-005):** Confirmed dedicated setter with same 60s–7d bound as `setWindows`.
- **`SeedRevealed` payload (KOM-006):** Confirmed event carries `(id, seed, salt, oracleDeadline)`.
- **`PROTOCOL_ID` (KOM-007):** Confirmed `"VPAY-GENESIS-KOMMIT-v1.1"`.
- **CircuitBreaker integration:** All three external state-changing entries (`attestReasoning`, `challenge`, `revealSeed`) check `globalPaused()`. Settlement helpers do not — intentional, so a paused state doesn't strand in-flight bonds.

---

## Recommended actions before broadcast

| # | Action                                                                                | Where                          | Severity / type | Blocking?     |
|---|---------------------------------------------------------------------------------------|--------------------------------|------------------|---------------|
| 1 | Add `require(reasonerWallet != oracleWallet)` to deploy script                         | `DeployKommit.s.sol`           | MED-1 (ops)      | Yes — DONE     |
| 2 | (Optional) Add `require(_pool != address(0))` in `setMinerRewardsPool`                | `KommitBridge.sol`             | LOW-1            | No (admin-only, Safe-controlled) |
| 3 | Verify MinerRewards v2 accepts plain ERC-20 transfers                                  | Local source review            | INFO-1 → MED-3   | DONE — promoted to MED-3 |
| 4 | (v1.2) Add `deregisterModel` admin function                                            | `KommitBridge.sol`             | MED-2            | No (defer to v1.2) |
| 5 | (v1.1 docs) NatSpec note on `challengeDeadline` polymorphism                          | `KommitBridge.sol`             | INFO-2           | No (docs)     |
| 6 | (Pre-broadcast docs) Honest framing of "remainder to pool" in integration spec + cockpit | `Kommit-Integration-Spec.md`, `vpay-hmi-cockpit.html` | MED-3 followup | Yes (non-code, pre-broadcast or immediately post) |
| 7 | (v1.2) Real distribution mechanism for slashed-bond remainder                          | `KommitBridge.sol` + `MinerRewards.sol` | MED-3       | No (v1.2) |

**Blocking-for-broadcast set:** Item 1 (DONE). Item 6 is documentation hygiene that can ship pre- or immediately post-broadcast. No contract patches required for v1.1.

---

## Cross-validation

The Hermes-Agent external pass should be run with the prompt in `Kommit-v1.1-Hermes-Agent-Prompt.md`. Anything Hermes-Agent surfaces that I missed gets folded into a delta report; anything we agree on gets queued for v1.2 unless flagged blocking.
