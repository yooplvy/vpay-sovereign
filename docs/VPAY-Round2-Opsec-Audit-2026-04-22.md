# VPAY Round 2 — Key Custody + Opsec Audit

**Date:** 2026-04-22
**Scope:** Key custody, operational security, incident response posture
**Auditor:** Claude (Opus 4.6) under Ano Yoofi Agyei direction
**Predecessor audits:** Sprint 0 Fixes #12-#15, AAA-Plus Institutional Audit (2026-04-19), Best 2-of-3 Attack/Defence (#103), Kommit v1.1 internal red-team (2026-04-22)

**Severity scale:** CRIT (immediate action) · HIGH (this week) · MED (this sprint) · LOW (backlog) · INFO (note)

> **This is a snapshot inside the `vpay-sovereign` contracts repo for diligence portability (Phase 3, 2026-04-23).** Canonical source lives in the workspace at `OPEN CLAW WORKS/VPAY-Round2-Opsec-Audit-2026-04-22.md`. If the two diverge, the workspace version wins; this snapshot may lag pending the next sync.

---

## Executive summary

Round 2 surfaces **one CRIT and one HIGH that supersede the previously-tracked CRIT (#104 hardware-wallet migration).** The contract-layer admin migration completed in name but not in substance: only `DEFAULT_ADMIN_ROLE` was migrated. Eight service roles across six v2 contracts remain on the deployer EOA — the same MetaMask hot wallet that holds 2 of 3 future Safe slots and 19M unlocked SOV.

The Safe itself is currently **2-of-2** (Ano #1 + Lola), not 2-of-3. The 2-of-3 migration is mid-flight (task #124, blocked on Lola signing 4 queue entries). Once it lands, the well-understood single-machine collapse risk (#104) goes live.

**Recommendation order:**
1. **CRIT-1 first** — write `RevokeDeployerServiceRoles.s.sol` and route through Safe to revoke MINTER + BURNER + GUARDIAN + GOVERNANCE + ORACLE + RELAYER + DISTRIBUTOR + ARBITRATOR from deployer. Until this lands, the Safe migration is theatre.
2. ~~**HIGH-1 next** — move 19M SOV genesis from deployer EOA to a vesting/timelock contract or to the Safe.~~ **RESOLVED 2026-04-22** via `SOVVesting` at `0x452987FE45BbbF38A8cf12854F99983b549369F1` (18,999,950 SOV locked, beneficiary = Safe, 12mo cliff / 4yr linear / irrevocable). See HIGH-1 section for tx hashes and on-chain verification.
3. **CRIT-2 / #104** — hardware wallet migration after #124 completes the 2-of-3.
4. MED items in parallel.

---

## Closure status (2026-04-23 snapshot)

| Finding | Status |
|---------|--------|
| HIGH-1 · Founder allocation custody | ✅ FULLY CLOSED |
| INFO-2 · Diligence trail (GitHub) | ✅ CLOSED |
| MED-1 · KommitBridge role audit | ✅ CLOSED |
| MED-3 · `.env` secrets in Keychain | ✅ CLOSED |
| MED-4 · CircuitBreaker globalPaused | ✅ CLOSED |
| INFO-1 · Incident response runbook | ✅ CLOSED |
| LOW-1 · `.zshrc` Binance landmine | ✅ CLOSED |
| Dark Hermes Keychain mirror | ✅ CLOSED |
| CRIT-1 · 8 service roles on deployer | 🟡 Safe TX ready, awaits co-sign |
| CRIT-2 · Safe 2-of-2 → 2-of-3 | ⏳ blocked on Lola (#124) |
| CRIT-3 · Hardware wallet migration | ⏳ blocked by CRIT-2 |
| MED-2 · HSM keys for Kommit | 🔵 hardware decision, future |

**For the up-to-date version with full per-finding sections, see the workspace canonical at `OPEN CLAW WORKS/VPAY-Round2-Opsec-Audit-2026-04-22.md`.** The full per-finding text is preserved in this snapshot below for offline diligence access.

---

## CRIT-1 · Deployer EOA still holds 8 service roles after "admin migration"

**Finding.** `MigrateAdminToSafe.s.sol` only migrated `DEFAULT_ADMIN_ROLE` (14 txs: 7 grants + 7 renounces). All other roles still sit on the deployer EOA `0xc899...EAc0`.

**Evidence.** On-chain audit at `scripts/audit_roles_output.json` (2026-04-20T19:17, run 2 minutes after MigrateAdminToSafe broadcast):

| Contract | Service role still on deployer | Blast radius |
|---|---|---|
| SovereignToken | `MINTER_ROLE` | Mint up to **81M additional SOV** (cap = 100M, current = 19M) |
| SovereignToken | `BURNER_ROLE` | Burn anyone's SOV |
| CircuitBreaker | `GUARDIAN_ROLE` | Pause/unpause any contract globally or per-node |
| SovereignNode | `GOVERNANCE_ROLE` | Register/deregister GSU nodes; bypass attestation |
| MinerRewards | `DISTRIBUTOR_ROLE` | Drain reward pool |
| AttestationBridge | `RELAYER_ROLE` | Trigger `confirmAndMint()` without GSU attestation |
| VPAYVault | `ORACLE_ROLE` | Set arbitrary gold prices → liquidate or grief loans |
| GuardianBond | `ARBITRATOR_ROLE` | Arbitrary slash/release on Guardian bonds |

**Why CRIT.** A single MetaMask compromise on Ano's Mac collapses every economic and operational guarantee the contract layer was supposed to provide. The Safe migration is a Potemkin village from a service-role perspective.

**Fix (authored 2026-04-23, awaits Safe execution):** `safe/RevokeDeployerServiceRoles.tx-builder.json` — 11-call atomic batch (3 grants → Safe for GOVERNANCE/ORACLE/ARBITRATOR + 8 revokes from deployer for all 8 service roles). Full runbook at `safe/RevokeDeployerServiceRoles.RUNBOOK.md`.

---

## CRIT-2 · Safe is 2-of-2, not 2-of-3 (memory + CLAUDE.md drift)

**Finding.** Current Safe state per `hermes-vpay/scripts/safe_queue_check.py`:

```
THRESHOLD = 2  # current 2-of-2 threshold; migration target is 2-of-3
owners = [Ano #1 (0x4849), Lola (0xB670)]   # Ano #2 NOT yet on-chain
```

**Why CRIT.** Until 2-of-3 lands, every Safe transaction (including the CRIT-1 fix) requires Lola's signature with no redundancy. If Ano loses access to #1, Lola can't act alone (and vice versa). The 2-of-2 has higher liveness risk than either 1-of-1 or 2-of-3.

**Fix.** Two parts:
1. Get Lola's 4 sigs to clear the queue (already in motion as task #124).
2. Either correct CLAUDE.md / memory to say "2-of-2 transitioning to 2-of-3" OR finish the migration before any external diligence read.

---

## HIGH-1 · 19M SOV genesis allocation sits on deployer hot wallet — **CLOSED 2026-04-22**

**Status:** **RESOLVED 2026-04-22 via SOVVesting at `0x452987FE45BbbF38A8cf12854F99983b549369F1`** (Polygon Mainnet).

**Resolution sequence (all on-chain on 2026-04-22):**
- Step A — Deployed `SOVVesting` (OZ `VestingWalletCliff`) at block 85888392, tx [`0x0a3e6d8a...bd360`](https://polygonscan.com/tx/0x0a3e6d8a4e565872f487a33c8ed50afe9e2418300798f4333f1c4c8e7d6bd360). Owner = Safe `0xFc93...8A67`. Beneficiary = Safe.
- Step B — Transferred 18,999,950 SOV (deployer's full SOV balance) into the vesting contract at block 85888636, tx [`0x32fb71f2...9f5c`](https://polygonscan.com/tx/0x32fb71f28123e27d5dc69db2fdf3303843d5a2451fb7d6c9be908998a2bb9f5c).
- Step C — On-chain verification confirmed: `sovBalance() = 18,999,950 SOV`, deployer SOV balance = 0, `cliff() = 1808432816` (2027-04-22), `end() = 1903040816` (2030-04-22), `owner() = Safe`.

**All HIGH-1 follow-ups closed:**
- Polygonscan source verification: ✅ DONE 2026-04-23 — `Pass - Verified` via `forge verify-contract` against Etherscan v2 unified endpoint. [Source on Polygonscan](https://polygonscan.com/address/0x452987FE45BbbF38A8cf12854F99983b549369F1#code).
- Day-366 release operationalization runbook: ✅ DONE 2026-04-23 — see [`SOVVesting-Day366-Release-Runbook.md`](./SOVVesting-Day366-Release-Runbook.md) in this docs folder.

---

## CRIT-3 · #104 single-machine 2-of-3 collapse (deferred / known)

Already filed as CRITICAL pending. Actionable **after** the 2-of-3 migration completes (currently 2-of-2). Hardware wallet migration for slot #1 + slot #2 to (ideally) two separate Ledger / Trezor devices on two separate machines. Without this, the 2-of-3 thesis collapses to single-machine compromise = 2-signature quorum = full admin.

Blocked-by: CRIT-2 / task #124 completion.

---

## MED-1 · KommitBridge v1.1 role state — **CLOSED 2026-04-23**

**Status:** **RESOLVED 2026-04-23.** Extended `audit_roles_batch.py` to include KommitBridge `0x7EA30Ea8A14041380E04d4678B9A7E2173AcD528` and its 3 roles (DEFAULT_ADMIN, REASONER, ORACLE). On-chain verification confirms: deployer holds nothing on KommitBridge ✅; Safe holds DEFAULT_ADMIN ✅; REASONER `0x13C682Ad10797415eDe7B85C2b9a2Ad539B18e92` holds REASONER_ROLE ✅; ORACLE `0xA326089D225616970EAA115f4d7cAf38DC564268` holds ORACLE_ROLE ✅. KOM-OPS-1 distinct-address requirement satisfied on-chain.

---

## MED-2 · Kommit operational keys live on Mac, no documented backup or rotation

**Finding.** `~/.vpay-kommit/{reasoner,oracle}.key` at mode 0600. No HSM, no rotation runbook.

**Blast radius if Mac is stolen / disk imaged:**
- REASONER key leak → attacker can post fraudulent `commitReasoning()` calls under VPAY-GENESIS-KOMMIT-v1.1 signed by the legitimate REASONER address. Costs them 10 SOV bond per attestation.
- ORACLE key leak → attacker can call `oracleSlash()` arbitrarily during the oracle window, slashing legitimate reasoners or dismissing legitimate challenges.

**Fix (open):**
1. Move keys to YubiKey HSM or Ledger (Foundry has Ledger integration via `--ledger`).
2. Document rotation runbook (Safe-revoke + Safe-grant pattern).
3. Encrypted backup of current keys to a separate physical location.

**Effort.** Half-day for HSM migration + runbook.

---

## MED-3 · Binance + Hermes secrets to Keychain — **CLOSED 2026-04-23**

**Status:** **RESOLVED 2026-04-23.** Both Hermes engines (Gold port 5000, Dark port 5001) now load secrets from macOS Keychain via dedicated `secrets_loader.py` modules. `.env` retains only non-sensitive operational config (LIVE_TRADING flag, capital cap, etc.). Plaintext secrets eliminated from disk in either codebase. Verified by startup log lines `[secrets_loader] BINANCE_API_KEY=keychain ...` for both engines.

---

## MED-4 · CircuitBreaker `globalPaused()` reverts on read — **CLOSED 2026-04-23**

**Status:** **RESOLVED 2026-04-23.** Was an audit-script ABI selector bug (closed by task #28), not a contract bug. Fresh `audit_roles_batch.py` run reads `globalPaused = False` cleanly.

---

## LOW-1 · `.zshrc` Binance key landmine — **CLOSED 2026-04-23**

**Status:** **CLOSED 2026-04-23.** Operator deleted `~/.zshrc` lines 17–18 (`export BINANCE_API_KEY=...` and `export BINANCE_SECRET=...`) entirely. `grep -n -i 'BINANCE' ~/.zshrc` returns nothing; new interactive shells start with both vars empty. Combined with MED-3 closure, plaintext Binance secrets no longer exist on disk in any rc file or `.env`.

**Residual note for diligence completeness.** Time Machine snapshots taken before 2026-04-23 still contain copies of `~/.zshrc` with the old key values. Mitigation: rotate the Binance API key + re-seed Keychain quarterly.

---

## INFO-1 · Incident-response runbook — **CLOSED 2026-04-23**

**Status:** **CLOSED 2026-04-23.** Authored at [`INCIDENT-RESPONSE.md`](./INCIDENT-RESPONSE.md) in this docs folder. Covers the top 5 scenarios: Mac theft / device compromise (apex), Safe signer key compromise, Kommit operational key leak, Binance live trading API key leak, Hermes server external access. Each scenario gives trigger/detection signals, immediate-action checklist (first 10 min), escalation contacts, recovery procedure, and prevention notes.

---

## INFO-2 · Round 2 contracts public-repo-backed — **CLOSED 2026-04-23**

**Status:** **CLOSED 2026-04-23.** Round 2 contract surface published to `foundry-round2` branch on `https://github.com/yooplvy/vpay-sovereign`. 42 changed files, 12,807 line additions, 0 deletions, 52 git objects, 135.79 KiB push payload, 1 commit.

**Canonical diligence URL:** [https://github.com/yooplvy/vpay-sovereign/tree/foundry-round2](https://github.com/yooplvy/vpay-sovereign/tree/foundry-round2)

---

## What we DIDN'T find (assurance baseline)

- Smart-contract attack surface: nothing new beyond what KOM v1.1 red-team and AAA-Plus already covered.
- Hermes server (port 5000) auth: previous fixes #105/#107 hold — bound to loopback, mutations gated.
- Dark Hermes (port 5001): also loopback, Spot mode limits blast radius.
- Polygonscan source verification: confirmed for all 9 contracts (v2 stack + KommitBridge + SOVVesting).
- DEFAULT_ADMIN_ROLE: correctly migrated to Safe across all 7 v2 contracts.

---

## Recommended action order (post-2026-04-23)

| # | Action | Severity | Status |
|---|---|---|---|
| 1 | Execute `RevokeDeployerServiceRoles` Safe TX batch | CRIT-1 | 🟡 batch authored, awaits Safe co-sign |
| 2 | Lola signs queue → Safe becomes 2-of-3 | CRIT-2 | ⏳ blocked on Lola availability |
| 3 | Hardware wallet migration for slots #1 + #2 | CRIT-3 / #104 | ⏳ blocked by CRIT-2 |
| 4 | HSM migration for REASONER + ORACLE | MED-2 | 🔵 hardware decision pending |

All other items closed as of 2026-04-23.

---

## Cross-references to prior audits and pending tasks

- Existing CRITICAL pending: **#104** (hardware wallet migration) — relabeled here as CRIT-3.
- Existing in-progress: **#124** (clear Safe queue + execute 2-of-3 migration) — directly blocks CRIT-2 and CRIT-3.
- Existing pending: **#117** (MED-3 v1.2 slashed-bond distribution) — separate Kommit issue, unaffected.
- Existing pending: **#61** (seed model registry from Safe) — depends on Safe being functional 2-of-3.

---

## Where to find the live, append-only change log

The full point-in-time change log (per-day entries documenting closures, artifact authoring, smoke-test outputs, redeploys) lives in the **workspace canonical** at:

```
/Users/apple/Desktop/OPEN CLAW WORKS/VPAY-Round2-Opsec-Audit-2026-04-22.md  (Change log section)
```

This snapshot in the contracts repo is updated periodically. For the most recent state, refer to the workspace.
