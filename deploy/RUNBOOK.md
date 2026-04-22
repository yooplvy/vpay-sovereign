# VPAY Genesis v2 — Mainnet Deployment Runbook

**Last updated:** 2026-04-20
**Network:** Polygon Mainnet (chainId 137)
**Deployer:** `0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0`
**Safe:** `0xFc93b70fAa2045e19CEae43d1b645b2137c68A67`

---

## Phase 0 — Pre-Flight Checklist

Execute on the Mac terminal in `/Users/apple/Desktop/OPEN CLAW WORKS/contracts`.

### 1. Confirm Foundry is installed

```bash
forge --version
```

Expect `forge 0.2.0` or similar. If missing: `curl -L https://foundry.paradigm.xyz | bash && foundryup`.

### 2. Set environment variables

Create (or edit) `~/.vpay-deploy-env` with these lines:

```bash
# RPC — use a reliable endpoint. Public Polygon RPCs throttle aggressively from Ghana.
# Recommended: sign up at alchemy.com (free, 60 seconds) and paste your URL here.
# Fallback (may throttle): https://polygon-rpc.com
export POLYGON_RPC="https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY_HERE"

# Deployer private key (NEVER commit this file)
export PRIVATE_KEY="0x..."

# Polygonscan API key — for auto-verification of deployed contracts
# Sign up at polygonscan.com/apis (free, 30 seconds)
export POLYGONSCAN_API_KEY="..."

# Guardian multisig = Safe. This is the emergency pause authority.
export GUARDIAN_MULTISIG="0xFc93b70fAa2045e19CEae43d1b645b2137c68A67"

# Service wallets — leave unset to default to deployer. Migrate to real
# service accounts later when those services are built.
# export RELAYER_WALLET="0x..."
# export ORACLE_WALLET="0x..."
# export ARBITRATION_CHAMBER="0x..."
```

Then load it into your shell:

```bash
source ~/.vpay-deploy-env
```

Verify:

```bash
echo "RPC: $POLYGON_RPC" ; echo "GUARDIAN: $GUARDIAN_MULTISIG"
# Do NOT echo $PRIVATE_KEY
```

### 3. Check deployer MATIC balance

```bash
cast balance $(cast wallet address $PRIVATE_KEY) --rpc-url $POLYGON_RPC --ether
```

Need at least **0.5 MATIC**. Rough cost breakdown at 30 gwei:
- 6 contract deployments: ~0.15 MATIC
- 5 role grants during deploy: ~0.03 MATIC
- 14 role calls during admin migration: ~0.08 MATIC
- Buffer: ~0.24 MATIC

If balance is low, fund the deployer from exchange or bridge.

### 4. Confirm Polygon RPC works

```bash
cast block-number --rpc-url $POLYGON_RPC
```

Should return a current block number (~85.8M as of 2026-04-20).

---

## Phase 1 — Dry-Run (no broadcast)

Simulates the full deployment without sending any transactions. Use this to catch errors before spending gas.

```bash
cd "/Users/apple/Desktop/OPEN CLAW WORKS/contracts"
forge script deploy/DeployVPAYGenesis.s.sol \
  --rpc-url $POLYGON_RPC \
  -vvvv
```

**Check for in the output:**
- All 6 contracts "deployed" (simulated) with predicted addresses
- No reverts
- "POST-DEPLOYMENT" role grants all succeed
- Gas estimate at the bottom (~6-8M gas total)

If anything reverts, STOP and investigate before Phase 2.

---

## Phase 2 — Broadcast Deployment

This actually spends gas and creates the 6 contracts on Polygon Mainnet.

```bash
forge script deploy/DeployVPAYGenesis.s.sol \
  --rpc-url $POLYGON_RPC \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  -vvvv
```

**After completion, capture the deployed addresses** from the final summary:

```
========================================
   VPAY GENESIS v2 - DEPLOYMENT COMPLETE
========================================
Network:            Polygon Mainnet
SovereignToken:     0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0
CircuitBreaker:     0x...    ← new
SovereignNode:      0x...    ← new
MinerRewards:       0x...    ← new
AttestationBridge:  0x...    ← new
VPAYVault:          0x...    ← new
GuardianBond:       0x...    ← new
========================================
```

**Paste all 6 new addresses into `~/.vpay-deploy-env`:**

```bash
export CIRCUIT_BREAKER="0x..."
export SOVEREIGN_NODE="0x..."
export MINER_REWARDS="0x..."
export ATTESTATION_BRIDGE="0x..."
export VPAY_VAULT="0x..."
export GUARDIAN_BOND="0x..."
```

Then `source ~/.vpay-deploy-env` again.

Also save the addresses in `contracts/deploy/deployed-addresses.json` (git-trackable record):

```json
{
  "network": "polygon-mainnet",
  "chainId": 137,
  "deployedAt": "2026-04-20",
  "contracts": {
    "SovereignToken":    "0x5833ABF0Ecfe61e85682F3720BA4d636084e0eC0",
    "CircuitBreaker":    "0x...",
    "SovereignNode":     "0x...",
    "MinerRewards":      "0x...",
    "AttestationBridge": "0x...",
    "VPAYVault":         "0x...",
    "GuardianBond":      "0x..."
  }
}
```

---

## Phase 3 — Admin Migration to Safe

**⚠ IRREVERSIBLE.** Once Phase 3 completes, only Safe can administer the contracts. Lola's signature becomes required for any future role changes or admin actions (until Safe signer #2 is added to reach 2-of-3 with Ano holding 2 keys).

Dry-run first:

```bash
forge script deploy/MigrateAdminToSafe.s.sol \
  --rpc-url $POLYGON_RPC \
  -vvvv
```

Verify all 14 operations (7 grants + 7 renounces) simulate without revert. Then broadcast:

```bash
forge script deploy/MigrateAdminToSafe.s.sol \
  --rpc-url $POLYGON_RPC \
  --broadcast \
  -vvvv
```

The script ends with a built-in post-flight that prints `OK <contract>` for each successfully migrated contract.

---

## Phase 4 — On-Chain Verification

Independent verification from outside the deploy tooling:

```bash
cd "/Users/apple/Desktop/OPEN CLAW WORKS/scripts"
# Update audit_roles_batch.py CONTRACTS dict with the new addresses first, then:
python3 audit_roles_batch.py
```

**Expected output:** For every row: `deployer=✗  safe=✓` on DEFAULT_ADMIN_ROLE. Service roles (MINTER, RELAYER, ORACLE, DISTRIBUTOR, GUARDIAN) held by appropriate wallets per DeployVPAYGenesis.s.sol.

---

## Phase 5 — Documentation Truth-Up

- Update `CLAUDE.md` — "Deployed Contracts" table with real mainnet addresses
- Update `VPAY-Genesis-Project-Brief.md`
- Update `deployed-addresses.json`
- Regenerate master deck slide on contract addresses if it shows them
- Post "v2 stack deployed" bulletin if any investor comms reference expected infra

---

## Rollback / Recovery

**Between Phase 2 and Phase 3:** If Phase 2 broadcast succeeds but Phase 3 breaks something, deployer still holds admin — can grant roles manually or re-run migration.

**After Phase 3:** Deployer no longer has admin. Any fix must come via Safe (requires Lola co-sign under current 2-of-2 arrangement). This is by design.

**If Safe itself becomes unreachable** (Ano + Lola can't both sign): admin is lost. That's the tradeoff of renouncing. Mitigate by executing Phase 3 only when Safe is known-operational (test with a small Safe tx beforehand).

---

## Post-Migration Service-Role Grants (Later, From Safe)

Once real service accounts exist, these calls happen from the Safe (Ano + Lola co-sign):

- `AttestationBridge.grantRole(RELAYER_ROLE, relayerServiceWallet)` + `revokeRole(RELAYER_ROLE, deployer)`
- `VPAYVault.grantRole(ORACLE_ROLE, oracleServiceWallet)` + `revokeRole(ORACLE_ROLE, deployer)`
- `SovereignNode.revokeRole(GOVERNANCE_ROLE, deployer)` — once governance structure is live

These are Safe Transaction Builder operations, not forge scripts.
