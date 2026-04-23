# `contracts/docs/` — VPAY Sovereign Governance & Operational Trail

This directory carries snapshots of the most diligence-critical governance and operational documents for the VPAY Sovereign smart contract stack. They live here so anyone reading the `vpay-sovereign` GitHub repo can audit the contracts AND understand the operational discipline around them, without depending on the workspace folder on Ano's Mac.

**Phase 3 GitHub migration** (Round 2 audit follow-up, 2026-04-23): governance docs now travel with the contracts.

---

## What's in here

| File | Purpose | Sync state |
|------|---------|------------|
| [`VPAY-Round2-Opsec-Audit-2026-04-22.md`](./VPAY-Round2-Opsec-Audit-2026-04-22.md) | Round 2 key custody + opsec audit. Per-finding sections with closure status as of the snapshot date. **Anchor diligence document.** | Snapshot — workspace canonical is the live version |
| [`INCIDENT-RESPONSE.md`](./INCIDENT-RESPONSE.md) | Top-5 incident response runbook (Mac theft / Safe signer compromise / Kommit key leak / Binance key leak / Hermes external access). | Snapshot |
| [`SOVVesting-Day366-Release-Runbook.md`](./SOVVesting-Day366-Release-Runbook.md) | Operational runbook for the 2027-04-22 founder-allocation cliff release. | Snapshot |

---

## Canonical source of truth

These files are **snapshots** as of 2026-04-23. The live, append-only canonical versions live in the workspace at:

```
/Users/apple/Desktop/OPEN CLAW WORKS/VPAY-Round2-Opsec-Audit-2026-04-22.md
/Users/apple/Desktop/OPEN CLAW WORKS/INCIDENT-RESPONSE.md
/Users/apple/Desktop/OPEN CLAW WORKS/SOVVesting-Day366-Release-Runbook.md
```

**If the workspace and this repo diverge:** workspace wins. Sync this repo when material changes land (new audit closures, new runbook scenarios, schedule milestones, etc.).

**Suggested re-sync command** (from workspace root, on Ano's Mac):

```bash
cp "/Users/apple/Desktop/OPEN CLAW WORKS/VPAY-Round2-Opsec-Audit-2026-04-22.md" \
   "/Users/apple/Desktop/OPEN CLAW WORKS/INCIDENT-RESPONSE.md" \
   "/Users/apple/Desktop/OPEN CLAW WORKS/SOVVesting-Day366-Release-Runbook.md" \
   "/Users/apple/Desktop/OPEN CLAW WORKS/contracts/docs/"
cd "/Users/apple/Desktop/OPEN CLAW WORKS/contracts"
git add docs/
git commit -m "docs: re-sync governance trail $(date +%Y-%m-%d)"
git push origin foundry-round2
```

---

## What's intentionally NOT in here

- **`CLAUDE.md`** — too Hermes-specific for the contracts repo. Carries trading-engine + dashboard + tooling context unrelated to the on-chain stack. Lives in the workspace canonical only.
- **`SOVVesting-Deploy-Runbook.md`** — deployment is complete; the historical runbook isn't load-bearing for diligence reading the deployed-and-verified contract.
- **Memory files** (`memory/*.md` in the workspace) — those are Claude's session memory, not project documentation. Workspace-only.
- **Live dashboards / HTML files** — operational, not governance.

---

## How to use these docs

**For investors / auditors:** start with [`VPAY-Round2-Opsec-Audit-2026-04-22.md`](./VPAY-Round2-Opsec-Audit-2026-04-22.md). The closure status table near the top tells you which findings are CLOSED, which are in_progress with artifact ready, and which are blocked by external coordination.

**For incident-response engagement:** [`INCIDENT-RESPONSE.md`](./INCIDENT-RESPONSE.md) is the playbook the founder uses when something goes wrong. Each scenario gives detection signals, immediate actions, escalation paths, and prevention notes.

**For SOVVesting beneficiary / Safe signer:** [`SOVVesting-Day366-Release-Runbook.md`](./SOVVesting-Day366-Release-Runbook.md) explains exactly when the cliff opens, who calls `release()`, and what to verify after each release.

---

## Phase 3 closure note

Before 2026-04-23, the contracts repo carried only Solidity + tests + deploy scripts + broadcast receipts. Anyone reading the GitHub repo would see the on-chain artifacts but not the audit trail or operational discipline around them — they'd have to take Ano's word on diligence claims, since the audit was on his Mac.

After Phase 3 (this commit), the diligence trail travels with the code. Third parties can `git clone --branch foundry-round2 https://github.com/yooplvy/vpay-sovereign` and read the audit + runbooks alongside the contracts. The chain of evidence is no longer single-machine-of-truth.
