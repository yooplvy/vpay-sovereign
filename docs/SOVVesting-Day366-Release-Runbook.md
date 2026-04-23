# SOVVesting · Day-366 Release Operationalization Runbook

**Closes:** Round 2 Opsec Audit · HIGH-1 outstanding follow-up #2 (operationalize who calls `release(SOV)` at the cliff and on what cadence afterwards).
**Authored:** 2026-04-23 · 12 months ahead of cliff date.
**Owner:** Ano Yoofi Agyei (primary caller / Safe co-signer).
**Audit reference:** [VPAY-Round2-Opsec-Audit-2026-04-22.md § HIGH-1](./VPAY-Round2-Opsec-Audit-2026-04-22.md)

> **Snapshot in `vpay-sovereign` contracts repo for diligence portability (Phase 3, 2026-04-23).** Canonical source: workspace `OPEN CLAW WORKS/SOVVesting-Day366-Release-Runbook.md`.

---

## TL;DR

On **22 Apr 2027 at 22:26:56 UTC**, the founder allocation cliff unlocks. Calling `release(SOV)` on `0x452987FE45BbbF38A8cf12854F99983b549369F1` at any moment after that timestamp transfers the currently-vested-but-unreleased SOV to the Safe `0xFc93b70fAa2045e19CEae43d1b645b2137c68A67`. The function is **permissionless** — anyone can pay the gas, but the SOV always lands at the Safe.

**Default plan:**

1. **Day 366 (22 Apr 2027 22:26:56 UTC)** — first release: ~4,749,988 SOV (the 25% cliff tranche) lands on the Safe.
2. **Monthly thereafter, on the 22nd of each month** — recurring release of ~395,837 SOV/month, until end-of-vest on 22 Apr 2030.
3. **Each release** is followed by a one-line cap-table append documenting the tx hash, block, and resulting Safe SOV balance.

If nobody calls `release()`, nothing breaks — vested SOV simply accumulates inside the contract. The first call that does happen sweeps everything that has vested up to that moment.

---

## The contract (review)

| Field | Value |
|-------|-------|
| Address | `0x452987FE45BbbF38A8cf12854F99983b549369F1` |
| Polygonscan (verified source) | [polygonscan.com/address/0x452987FE45BbbF38A8cf12854F99983b549369F1#code](https://polygonscan.com/address/0x452987FE45BbbF38A8cf12854F99983b549369F1#code) |
| Beneficiary + Owner | Safe `0xFc93b70fAa2045e19CEae43d1b645b2137c68A67` |
| Total allocation | 18,999,950 SOV |
| Operational carve-out | 50 SOV on REASONER `0x13C6...8e92` (rotating Kommit bond, not part of vesting) |
| Base contract | OpenZeppelin `VestingWalletCliff` |
| Revocable? | **No**. There is no admin, pause, or upgrade path. Only `transferOwnership` exists. |
| Schedule type | 12-month cliff + 4-year linear (technically 1460 days = 4×365, ends one day shy of 2030-04-22 — see footnote) |

---

## The schedule (precise)

| Marker | Unix timestamp | UTC | Days from start | Vested |
|--------|----------------|-----|-----------------|--------|
| `start` (deploy) | `1776896816` | 2026-04-22 22:26:56 | 0 | 0 SOV |
| `cliff` | `1808432816` | 2027-04-22 22:26:56 | 365 | 4,749,987.5 SOV (25%) atomic at this instant |
| 50% mark | `1839968816` | 2028-04-22 04:26:56 (approx) | 730 | 9,499,975 SOV |
| 75% mark | `1871504816` | 2029-04-22 (approx) | 1095 | 14,249,962.5 SOV |
| `end` | `1903040816` | 2030-04-21 22:26:56 | 1460 | 18,999,950 SOV (full) |

**Footnote on the end date.** `durationSeconds = 126144000 = 1460 days = 4 × 365`. Because the 4-year span includes the leap year 2028, the actual end lands on **2030-04-21**, one day shy of the 4th calendar anniversary. This is a property of the deploy-time constant, not an error.

**Rate after cliff (linear vest from 25% to 100% over 1095 days):**

| Cadence | Amount |
|---------|--------|
| per second | ≈ 0.150594 SOV |
| per day | ≈ 13,013.66 SOV |
| per 7 days (week) | ≈ 91,096 SOV |
| per 30 days (month, conservative) | ≈ 390,410 SOV |
| per 30.4375 days (calendar-month avg) | ≈ 395,837 SOV |
| per 91 days (quarter) | ≈ 1,184,243 SOV |
| per 365 days (year) | ≈ 4,749,988 SOV |

---

## How `release()` works (mechanics)

```solidity
// Call signature (inherited from OZ VestingWallet):
function release(address token) external

// Effective behavior, given owner = beneficiary = Safe:
// 1. Reads sovReleasable() = vested - already_released
// 2. Accounts for the new release internally
// 3. Transfers `sovReleasable` SOV to owner() (= Safe)
// 4. Emits ERC20Released(token, amount)
```

**Permissionless:** any address can call it. Only effect on the caller is paying gas (~50k gas on Polygon = ~$0.005).

**Idempotent:** calling twice in the same block transfers nothing the second time.

**Griefing-impossible:** since the destination is hard-coded to `owner()`, a third party calling `release()` just pays gas to push SOV to the Safe.

---

## The first call (at or shortly after 2027-04-22 22:26:56 UTC)

### Path A — Call from a personal EOA (simplest, recommended)

```bash
SOV=0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0
VEST=0x452987FE45BbbF38A8cf12854F99983b549369F1
RPC=https://polygon.drpc.org

# 1. Confirm the cliff is open
cast call $VEST "sovReleasable()(uint256)" --rpc-url $RPC
# Expected output post-cliff: ~4749987500000000000000000

# 2. Send the tx
cast send $VEST "release(address)" $SOV \
  --private-key $YOUR_KEY \
  --rpc-url $RPC

# 3. Capture the tx hash, paste into cap-table log
```

### Path B — Call via Safe Transaction Builder

1. Open [app.safe.global](https://app.safe.global) → Apps → Transaction Builder.
2. Add: To `0x452987FE45BbbF38A8cf12854F99983b549369F1`, ABI for `release(address)`, arg `0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0`.
3. Create batch → Sign with both signers → Execute.

---

## Post-release verification (after every call)

```bash
cast call $VEST "sovBalance()(uint256)" --rpc-url $RPC      # drops by released amount
cast call $VEST "sovReleasable()(uint256)" --rpc-url $RPC   # should be 0
cast call $VEST "sovReleased()(uint256)" --rpc-url $RPC     # cumulative
cast call $SOV "balanceOf(address)(uint256)" $SAFE --rpc-url $RPC  # Safe balance increases
```

---

## Recurring monthly cadence (post-cliff)

**Recommended:** call on the 22nd of each month from May 2027 onwards.

| Date | Approx tranche | Cumulative |
|------|----------------|------------|
| 2027-04-22 (cliff) | 4,749,988 SOV | 4,749,988 SOV |
| 2027-05-22 | ~395,837 SOV | ~5,145,825 SOV |
| 2027-06-22 | ~395,837 SOV | ~5,541,662 SOV |
| ... | ... | ... |
| 2030-04-21 (end) | sweeps remainder | 18,999,950 SOV |

**Skipping a month is harmless.** The next call sweeps everything accumulated since.

---

## Edge cases

- **Cliff hits exactly:** Polygon block times are ~2 seconds; the cliff opens within ~2 seconds of the target time. Calling too early = tx succeeds, transfers 0 SOV, costs gas (~$0.005).
- **Two callers race:** First tx mined wins; second becomes a no-op. Both pay gas; only one moves SOV.
- **Polygon re-org:** Polygon finality is ~2 mins. No double-release possible.
- **End-of-vest:** Final release sends everything remaining; subsequent calls are no-ops.

---

## Cap-table tracking

After each successful release, append to `SOVVesting-Release-Log.md` (create on first call):

```
| Date | Block | Tx | Released | Cumulative | Caller |
|------|-------|----|----------|------------|--------|
| 2027-04-22 22:27:18 UTC | 95,xxx,xxx | 0x... | 4,749,987.500000 SOV | 4,749,987.500000 SOV | 0x4849...(Ano) |
```

---

## Tax / accounting flag (out of scope, but heads up)

SOV releasing to the Safe is likely a **constructive receipt** event for the founder under most jurisdictions. Consult tax counsel **before** the cliff (Q1 2027). Failing to plan for this is the single most expensive mistake possible here.

---

## What NOT to do

- ❌ Do **not** transfer additional SOV into the contract beyond the original 18,999,950.
- ❌ Do **not** call `transferOwnership` casually. It's the only privileged action and has no undo.
- ❌ Do **not** call `release()` from a wallet that doesn't have at least 1 POL.

---

## Related artifacts

- **Contract source:** [`../SOVVesting.sol`](../SOVVesting.sol)
- **Deploy receipt:** [`../broadcast/DeploySOVVesting.s.sol/137/run-latest.json`](../broadcast/DeploySOVVesting.s.sol/137/run-latest.json)
- **Round 2 Opsec Audit:** [`./VPAY-Round2-Opsec-Audit-2026-04-22.md`](./VPAY-Round2-Opsec-Audit-2026-04-22.md)

---

## Living-document hooks

- [ ] Closer to the cliff (Q1 2027): re-validate calendar reminders + verification commands still resolve.
- [ ] After first release: append the live tx hash + cap-table line item.
- [ ] After end-of-vest (2030-04-21): mark runbook ARCHIVED.
