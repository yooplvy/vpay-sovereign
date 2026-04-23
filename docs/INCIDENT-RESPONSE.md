# VPAY Genesis · Incident Response Runbook

**Version:** 1.0 · 2026-04-23
**Owner:** Ano Yoofi Agyei
**Closes:** Round 2 Opsec Audit · INFO-1
**Audit reference:** [VPAY-Round2-Opsec-Audit-2026-04-22.md § INFO-1](./VPAY-Round2-Opsec-Audit-2026-04-22.md)

> **Snapshot in `vpay-sovereign` contracts repo for diligence portability (Phase 3, 2026-04-23).** Canonical source: workspace `OPEN CLAW WORKS/INCIDENT-RESPONSE.md`.

This is the playbook for the five scenarios most likely to compromise VPAY Genesis. Each scenario gives you: how you'd notice, what to do in the first ten minutes, who to wake up, and how to restore safe state.

---

## Before you do anything else (60-second guidance)

If you suspect compromise, **do NOT** power off the Mac or unplug the network. Two reasons:

1. **Powering off destroys volatile evidence** that helps you reason about what happened.
2. **Network isolation breaks your ability to trigger the most important defense** — pausing CircuitBreaker via Safe.

**Instead, in this order:**

1. **Open this document.** Identify which scenario you're in.
2. **Open a fresh incident log** in Apple Notes or a paper notebook. Record everything with timestamps.
3. **Execute the immediate action** from the relevant scenario below.
4. **Escalate** per the contact list while you keep working.

If you cannot identify the scenario, default to **Scenario 1 (Mac theft / compromise)**.

---

## Severity scale

| Tier | Meaning | Response window |
|------|---------|-----------------|
| **CRITICAL** | Founder allocation, Safe authority, or full token-supply at risk | < 10 minutes |
| **HIGH** | Specific subsystem compromised; bounded blast radius | < 1 hour |
| **MEDIUM** | Operational hygiene; remediate same day | < 24 hours |

---

## Contact list

| Role | Person | Notes |
|------|--------|-------|
| Founder / CEO | Ano Yoofi Agyei | Holds Safe slot #1 (and #2 in process); all keys on his Mac |
| CCO | Ibilola "Lola" Macaulay | Holds Safe slot #3; can co-sign emergency Safe txs |
| External legal | TBD — engage Q1 2027 latest | For tax counsel + regulatory escalation |
| Polygon RPC providers | dRPC, PublicNode, Ankr | Fallback chain: drpc.org → publicnode.com |
| Etherscan / Polygonscan support | https://etherscan.io/contactus | Source verification issues |
| Anthropic API status | https://status.anthropic.com | If Hermes intelligence stops responding |
| Binance support | https://www.binance.com/en/support | API key disable: account → API management → Delete |

---

## Tooling reference

| Tool | URL | Purpose |
|------|-----|---------|
| Safe (mainnet) | https://app.safe.global | Sign + execute Safe txs |
| Polygonscan SOV token | https://polygonscan.com/token/0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0 | Watch for unauthorized transfers |
| Polygonscan deployer EOA | https://polygonscan.com/address/0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0 | Watch for unauthorized txs |
| Polygonscan Vesting | https://polygonscan.com/address/0x452987FE45BbbF38A8cf12854F99983b549369F1 | Verify vesting balance untouched |
| KommitBridge v1.1 | https://polygonscan.com/address/0x7EA30Ea8A14041380E04d4678B9A7E2173AcD528 | Watch for unauthorized commits / oracle calls |
| Binance API mgmt | https://www.binance.com/en/my/settings/api-management | Disable / rotate Binance keys |
| Audit-roles script | `scripts/audit_roles_batch.py` | Quick on-chain role state read |

---

## Scenario 1 — Mac theft or device compromise (CRITICAL · apex)

Ano's Mac currently holds: deployer EOA (8 service roles), Safe slot #1, Safe slot #2 (post-#124), `~/.vpay-kommit/` keys, browser sessions. iCloud / Time Machine snapshots may persist secrets even after wipe.

### Trigger / detection

- Laptop physically stolen, lost in transit, or out of your control
- Unfamiliar logins to Apple ID, GitHub, etc.
- Any of the more specific scenarios below firing

### Immediate action (first 10 minutes)

1. **From a different device,** open [app.safe.global](https://app.safe.global) → check the Safe queue. Reject any unfamiliar txs.
2. **Check Polygonscan** for the Safe and the deployer EOA for any txs you didn't initiate in the last 24h.
3. **Disable Binance API keys immediately** — Binance UI → API management → Delete the live key.
4. **Apple ID → Find My iPhone/Mac** — mark the device as lost; if stolen, request remote wipe.
5. **GitHub → Settings → Sessions** — revoke all active sessions. Same for Box, Notion, Linear.
6. **Call Lola** — she is now your only Safe co-signer until you regain a clean device.

### Recovery procedure

1. **Acquire a clean device.**
2. **Generate fresh wallets** for deployer-equivalent + new `~/.vpay-kommit/` keypairs.
3. **From the Safe** (now operating with Lola + your new fresh wallet for one role), queue a 2-of-3 batch to:
   - Replace compromised Safe owners via `swapOwner`
   - Rotate REASONER_ROLE on KommitBridge
   - Rotate ORACLE_ROLE on KommitBridge
4. **Polygonscan post-rotation audit:** run `python3 scripts/audit_roles_batch.py`.
5. **Re-issue Binance API keys** with new permissions.
6. **Restore Hermes config** from a clean source — re-enter secrets via `seed_keychain.sh`.

### Prevention (in motion)

- CRIT-1 (revoke 8 service roles from deployer)
- HIGH-1 SOVVesting (closed) — already prevents 19M SOV move
- CRIT-3 / #104 (hardware wallet for Safe slots)
- MED-2 (HSM keys for REASONER + ORACLE)
- MED-3 (`.env` → Keychain) ✅ closed

---

## Scenario 2 — Safe signer key compromise (CRITICAL)

A signer's private key (Ano #1, Ano #2, or Lola) is leaked. Attacker has 1 of 2 (currently) or 1 of 3 (post-#124) signatures needed.

### Trigger / detection

- Queued Safe transaction you didn't initiate
- Polygonscan shows Safe-originated tx you don't recognize
- A signer reports their seed phrase or private key was exposed

### Immediate action

1. **Open Safe** → Transactions → Queue. Reject unfamiliar txs.
2. **Notify other signers immediately** — they must NOT sign anything they didn't initiate.
3. **If compromise confirmed, queue `swapOwner` batch** from un-compromised signers. Atomically swaps compromised owner for fresh address.
4. **Do NOT execute any other Safe action** until the swap lands.

### Recovery procedure

1. Sign + execute the `swapOwner` tx.
2. Verify on-chain via `cast call SAFE "getOwners()(address[])"` — compromised address gone.
3. Compromised signer rotates MetaMask completely.
4. Run `audit_roles_batch.py` to confirm no v2-stack drift.

---

## Scenario 3 — Kommit operational key leak (HIGH)

`~/.vpay-kommit/reasoner.key` or `oracle.key` is leaked.

### Blast radius (per role)

- **REASONER key:** attacker posts fraudulent commits costing 10 SOV bond per attestation. Ambiguous authorship for legitimate attestations between leak and rotation.
- **ORACLE key:** attacker can `oracleSlash()` arbitrarily during oracle window — direct integrity hit on Proof-of-Reasoning.

### Immediate action

1. Pause CircuitBreaker if KommitBridge subscribes (verify first).
2. **From Safe,** queue `revokeRole(<role>, <leaked wallet>)` on KommitBridge.
3. **Generate fresh wallet:** `bash contracts/scripts/gen_kommit_wallets.sh`
4. Fund new wallet (~1 POL gas + 50 SOV bond pool from Safe).
5. **From Safe,** queue `grantRole(<role>, <new wallet>)`.
6. Update `hermes_v2/kommit_client.py` to point at new keypair location.
7. Restart Gold Hermes.

### Recovery

1. Run `audit_roles_batch.py` — confirm role on new wallet only.
2. Document fraudulent commits made between leak and rotation; flag block range as ambiguous to integrators.

---

## Scenario 4 — Binance live trading API key leak (HIGH)

`BINANCE_API_KEY` + `BINANCE_SECRET` exposed via Keychain extraction, .env leak, or shell history.

### Blast radius

Currently $275 LIVE_CAPITAL with `LIVE_TRADING=true`. Withdrawal should be disabled on the API key (verify pre-incident, not post-). Worst case: attacker moves $275 across pairs (no withdrawal) until you rotate.

### Immediate action

1. **Binance UI → API Management → Delete the leaked key.** One-click revocation.
2. **Stop both Hermes processes:**
   ```bash
   lsof -ti:5000 | xargs kill -9
   lsof -ti:5001 | xargs kill -9
   ```
3. **Generate new Binance API key.** Same restrictions: trading enabled, **withdrawal disabled**, IP allowlist if possible.
4. **Update Keychain:** re-run `bash hermes-vpay/seed_keychain.sh` with the new key.
5. **Restart Hermes.**

### Prevention (in place)

- MED-3 ✅ closed — secrets in Keychain, not .env
- LOW-1 ✅ closed — `.zshrc` cleaned
- Quarterly key rotation recommended

---

## Scenario 5 — Hermes server external access (MEDIUM)

Despite loopback bind, Hermes API at port 5000/5001 reachable externally. Possible paths: VPN port-forwarding, tailscale misconfig, ngrok left open, malware tunneling.

### Trigger / detection

- Hermes server logs show requests from non-localhost IPs
- `lsof -i :5000` shows non-loopback peer
- Unsolicited POST to `/v1/admin/tick` or `/v2/zeus/tick`
- Fan spinning at unusual times

### Immediate action

1. **Stop both Hermes processes** (commands above).
2. **Check open ports:** `lsof -iTCP -sTCP:LISTEN -n -P`
3. **macOS firewall:** System Settings → Network → Firewall → enable + block all incoming.
4. **Revoke tunneling tools:** kill ngrok, tailscale, VPN port-forwards.
5. **Audit Hermes decision log** for the request window.

### Recovery

1. Restart Hermes with strict loopback bind (default per R2-003).
2. Purge any injected bad state.
3. Rotate Bearer tokens at `~/.vpay-hermes/token` and `~/.dark-hermes/token`.

---

## Decision trees

### "I just lost my Mac"
→ **Scenario 1**. Maximum-paranoia default.

### "I see a transaction on Polygon I didn't authorize"
- FROM = deployer EOA → **Scenario 1**
- FROM = Safe → **Scenario 2**
- FROM = REASONER or ORACLE on KommitBridge → **Scenario 3**

### "I see Binance trading I didn't authorize"
→ **Scenario 4**

### "Hermes is doing things I didn't ask"
- Trades match legitimate signals → probably normal Pantheon, not an incident
- Requests from non-loopback IPs → **Scenario 5**

### "I think someone is in my Mac right now"
Don't power off. Pull network cable / disable WiFi. Photograph (separate device) for forensics. Then proceed as Scenario 1.

---

## Post-incident hygiene

1. **Document the timeline** in this runbook's "Incident log" section.
2. **Run `scripts/audit_roles_batch.py`** and save output.
3. **Review CLAUDE.md** + audit doc — update if claims invalidated.
4. **Brief Lola** on the timeline.
5. **Update this runbook** if a gap was exposed.
6. **Annual review:** re-read every 6 months minimum.

---

## What this runbook deliberately does NOT cover

- **Tax / legal incidents** — engage external counsel.
- **Public PR response** — defer all public statements until technical incident closes.
- **Minor operational issues** — RPC outages, Hermes process crashes (see `deploy/RUNBOOK.md`).
- **Smart contract bugs** — pause via Safe + CircuitBreaker first, then assess.

---

## Incident log

_(Append after every incident. Most recent at top.)_

- _(none yet — runbook authored 2026-04-23)_

---

## Living-document hooks

- [ ] Add Lola's actual phone number + email to contact list
- [ ] After CRIT-1 ships: update Scenario 1 prevention notes
- [ ] After #104 ships: update Scenario 2 prevention notes
- [ ] After MED-2 ships: update Scenario 3 prevention notes
- [ ] At 6-month review (Q4 2026): re-validate all URLs
