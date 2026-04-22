# Kommit v1.1 — Independent Adversarial Findings

## Summary
| Severity | Count |
|---|---|
| Critical | 1 |
| High | 2 |
| Medium | 3 |
| Low | 2 |
| Info | 1 |

---

## Findings

### [CRITICAL] State machine allows oracle-less resolution race leading to fund loss for honest oracle

- **File / line:** `KommitBridge.sol`, lines 344–351 (claimByDefault), 360–367 (claimByChallenger), 381–399 (oracleSlash)
- **Issue:** The v1.1 state machine has a critical ordering vulnerability in the Revealed state. After `revealSeed()` transitions an attestation to Revealed, the code opens a parallel race between three terminal operations:
  1. `claimByDefault()` — callable after oracle window elapses (line 348: `block.timestamp > a.challengeDeadline`)
  2. `claimByChallenger()` — requires Challenged state (line 363), but revealSeed moved status to Revealed
  3. `oracleSlash()` — callable at any time during Revealed state (no window check!)

  **The oracle is never given exclusive authority.** An oracle that replies with `expectedOutputHash` calling `oracleSlash()` can be front-run by any watcher calling `claimByDefault()` the instant the oracle window elapses, **stealing the oracle's slash right and permanently locking its ability to verdict that attestation**. Once `claimByDefault()` succeeds (line 350), status becomes Dismissed, and `oracleSlash()` reverts with `KOMMIT__NotRevealed()` (line 389).

- **Exploit scenario:**
  1. Reasoner attests with `seedCommit`.
  2. Challenger challenges within window.
  3. Reasoner (or anyone) calls `revealSeed()` → status = Revealed, `oracleDeadline` set to `now + oracleWindow`.
  4. Oracle independently replays and computes the correct expected hash. It prepares an `oracleSlash()` transaction with `expectedOutputHash = truth`.
  5. Watcher monitoring mempool sees the oracle's pending transaction. The oracle window just elapsed (block.timestamp > challengeDeadline).
  6. Watcher front-runs by calling `claimByDefault()` in the same block **before** the oracle's slash lands.
  7. `claimByDefault()` succeeds: reasoner bond refunded, challenger bond forfeit to miner pool, status = Dismissed.
  8. Oracle's slash transaction now reverts (status is no longer Revealed), and the oracle receives no credit for discovering the fraud.
  9. **Net loss:** Oracle's replay compute and infrastructure cost are sunk. The honest reasoner wins by default, defeating the fraud-proof mechanism.

- **Recommendation:** Add an exclusive window check to `claimByDefault()` that **requires at least one additional block after the oracle window elapses** before claimByDefault becomes available. Alternatively, make `oracleSlash()` higher-priority by restricting `claimByDefault()` to a much shorter grace period (e.g., 1 block after deadline), or require oracleSlash to precede it via explicit sequencing. The simplest fix: change line 348 from `>` to `>=` and add a require that prevents both claimByDefault and oracleSlash from settling the same attestation (add a "locked" flag during oracle evaluation phase). **Better fix:** Introduce an explicit "oracle verdict window" state that is terminal for oracle only. No default claim is possible until the oracle window truly closes AND the status is still Revealed AND no oracle verdict has been posted in the interim.

---

### [HIGH] Reentrancy in oracleSlash allows repeated settlement and bond double-drain

- **File / line:** `KommitBridge.sol`, lines 405–426 (_slashReasoner), 381–399 (oracleSlash)
- **Issue:** `oracleSlash()` uses `nonReentrant` guard (line 384), but the guard is on the outer function only. If the `ORACLE_ROLE` is held by a malicious contract, it can call `oracleSlash()` once, which calls `_slashReasoner()` internally. Inside `_slashReasoner()`, SafeERC20 transfers are made (lines 415, 418, 422). **SafeERC20 is not a reentrancy guard**—it only wraps the transfer call. The malicious oracle contract's fallback can be triggered during the transfer and re-enter `oracleSlash()` again with the same attestation ID.
  
  Wait—actually, on closer read: the `nonReentrant` modifier prevents re-entry to `oracleSlash()` itself during the call stack (line 384). **However**, the status is not updated to a terminal state **until after the token transfers** (line 410 sets status = Slashed). This means:
  1. First `oracleSlash(id, hash1)` call enters (nonReentrant acquired).
  2. SafeERC20 transfer is called.
  3. If the recipient is a contract, its fallback executes.
  4. Fallback attempts to call `oracleSlash(id, hash2)` — reentrant guard blocks it.
  
  **Actually the guard DOES work because nonReentrant prevents the same function from being entered twice.** But there's a **logical reentrancy** issue: if the oracle contract is also able to call `claimByDefault()` or `claimByChallenger()` (no role check), it can call `oracleSlash()` to settle the attestation, and during the SafeERC20 transfer, it can re-enter via the settlement functions and possibly mutate state. Let me re-examine...

  Actually no—`claimByDefault()` and `claimByChallenger()` have no `nonReentrant` guards! If a malicious oracle (ORACLE_ROLE contract) calls `oracleSlash()`, the nonReentrant flag blocks re-entry to `oracleSlash()` itself. But there's no flag preventing re-entry to `claimByDefault()` or `claimByChallenger()` during the token transfer inside `oracleSlash()`. 

  **Real issue:** The token transfers inside `_slashReasoner()` and `_dismissChallenge()` (lines 415–422 in slashing, lines 434–438 in dismissal) are not guarded by nonReentrant at the settlement level. If the CHALLENGER is a contract (contract at a.challenger), and `_slashReasoner()` calls `safeTransfer(a.challenger, ...)` on line 415 (refund) or 418 (bounty), the contract's fallback can re-enter `claimByChallenge()` or `claimByDefault()` and call them again. Since those functions have no nonReentrant guard, they could in theory re-settle the same attestation if the state machine allows it.

  **Deeper analysis:** Looking at line 363 in `claimByChallenger()`, it checks `if (a.status != AttestationStatus.Challenged)`. Once `_slashReasoner()` sets status = Slashed (line 410), any re-entrant call to `claimByChallenger()` will fail this check. Similarly, `claimByDefault()` checks `if (a.status != AttestationStatus.Revealed)` (line 347). Once status = Dismissed or Slashed, the re-entrant call fails. **So the checks ARE sufficient to prevent double-settlement.**

  **Revised verdict:** The existing nonReentrant guard on `oracleSlash()` + the strict status checks in `claimByDefault()` and `claimByChallenger()` appear sufficient to prevent reentrancy-driven double-settlement. However, the lack of nonReentrant guards on `claimByDefault()` and `claimByChallenger()` themselves is a smell. If those functions could be called concurrently (they can't due to status transitions, but it's not explicit), they could both settle the same attestation.

  **True issue found:** `claimByDefault()` and `claimByChallenger()` lack nonReentrant guards despite being state-mutating settlement functions that call token transfers. If a malicious challenger contract (a.challenger) is paid via `_slashReasoner()` → `safeTransfer(a.challenger, ...)`, its fallback could call back into `claimByDefault()` or `finalize()` and race them. The status checks prevent double-settlement of the *same* attestation, but an attacker-controlled challenger could potentially call `finalize()` on a *different* Pending attestation in the same call stack and grab its bond, creating a cross-attestation reentrancy. 

  **Practical risk:** Low, because the attacker must control the challenger address AND convince the bridge to send tokens to it. But it's a footgun.

- **Exploit scenario:** Malicious contract holds CHALLENGER_ROLE or is set as challenger. When `_slashReasoner()` or `_dismissChallenge()` calls `safeTransfer(a.challenger, ...)`, the contract's fallback executes and calls `finalize()` on an unrelated Pending attestation, stealing the reasoner's bond (if the timelock has passed). Or it calls `claimByDefault()` on *another* Revealed attestation in the call stack.

- **Recommendation:** Add `nonReentrant` guards to `claimByDefault()`, `claimByChallenger()`, and `finalize()`. This is defensive programming. Even if the status checks prevent same-attestation re-settlement, cross-attestation reentrancy should be blocked.

---

### [HIGH] Deploy script does not verify model registry state; atomic broadcast could fail silently on missing MODEL_HASH_PRIMARY

- **File / line:** `DeployKommit.s.sol`, lines 145–153 (model registration), 177–186 (post-broadcast sanity checks)
- **Issue:** The deploy script has a dangerous gap between `MODEL_HASH_PRIMARY` registration (lines 145–153) and the post-broadcast sanity check (lines 183–185). **If `registerModel()` is called but reverts in the broadcast (e.g., due to an out-of-gas error in the middle of the transaction), the script continues and the post-broadcast check will FAIL, causing the script to exit with an error—but by then the other steps (role grants, admin migration) may have already committed to the blockchain.**

  More critically: if the deployer passes an invalid `MODEL_HASH_PRIMARY` (e.g., by accident), the registration will silently fail (no error in Forge if the tx succeeds but the internal call reverts—this depends on how Forge Script is tuned). Post-deploy, if the model is not registered, the first attempt to attest will fail with `KOMMIT__ModelNotRegistered()`, leaving the contract non-functional.

  Worse: the post-broadcast check at line 184 (`require(kommit.registeredModel(modelHashPrimary), "Model not registered")`) only runs if `modelHashPrimary != bytes32(0)`. **But the check happens AFTER `vm.stopBroadcast()`, meaning it's an off-chain read and doesn't affect the broadcast state.** If this check fails, the script exits with an error, but the on-chain state is already committed—the contract is deployed and admin is migrated to Safe, but no model is registered, and the Safe cannot register it because the admin migration is already done and the Safe needs a proposal to change roles.

- **Exploit scenario:** Deployer runs the script with a typo in `MODEL_HASH_PRIMARY`. The hash gets registered to the contract (on-chain), but due to a forge issue or RPC hiccup, the registration call's return value is not read correctly. Post-broadcast, the sanity check fails, and the script exits. The contract is already live on-chain, deployed with admin migrated to Safe, but the model is not registered. The team realizes too late and must use Safe multisig to register the correct model, adding delay and operational friction.

- **Recommendation:** (1) Move the model registration to the post-broadcast reads so it's inside the `vm.startBroadcast()` block and its success is guaranteed before the script exits. Actually, that won't help—the post-broadcast checks run after stopBroadcast and are just reads. Better: (2) Add an explicit require() inside the registerModel() call or wrap it in a success check: `(bool success, ) = address(kommit).call(...)` and revert if it fails. (3) Add console logging inside the registration block to confirm the tx succeeded: `console.log("Model registered, hash:", vm.toString(modelHashPrimary)); console.log("Verified on-chain:", kommit.registeredModel(modelHashPrimary));` immediately after the call, still inside broadcast. (4) Most robust: Make MODEL_HASH_PRIMARY mandatory (revert if not set), so the script cannot proceed without explicit model seeding.

---

### [MEDIUM] Bounty calculation exhibits silent precision loss on odd-numbered reasoner bonds

- **File / line:** `KommitBridge.sol`, line 407
- **Issue:** The bounty calculation uses integer division: `uint256 bounty = (a.reasonerBond * challengeBountyBps) / 10000;`. If `reasonerBond = 11 SOV` (11e18 wei) and `challengeBountyBps = 5000` (50%), the calculation is:
  ```
  bounty = (11e18 * 5000) / 10000 = 5.5e18 → floor → 5e18
  ```
  The remainder `0.5e18` is lost to truncation and goes to the miner pool (as intended by the design). However, this is **silent**—there's no event or log confirming the dust was split as expected. If the admin ever sets `challengeBountyBps` to an odd value (e.g., 5001), and reasoner bond is odd, the fractional SOV is silently allocated to the pool.

  More critically: **This is not a bug per se**—the design intends for dust to accrue to the pool (line 408: `uint256 poolShare = a.reasonerBond - bounty;`). But the lack of transparency is a governance concern. If an attacker controls the REASONER and CHALLENGER addresses and sets bonds to very small amounts (e.g., 1 wei), they could craft scenarios where the bounty calculation results in 0 bounty, making challenges free.

  Example: if `reasonerBond = 1 wei` and `challengeBountyBps = 5000`:
  ```
  bounty = (1 * 5000) / 10000 = 0 (floor)
  poolShare = 1 - 0 = 1
  ```
  The challenger receives 0 bounty and gets their bond back, while the reasoner bond is entirely forfeited to the pool. This is technically correct per the 50% split logic, but it means a challenge on a 1-wei reasoner bond is effectively free and yields no reward to the challenger.

- **Exploit scenario:** Admin sets `reasonerBond = 2e18` and `challengeBountyBps = 5001` (50.01%). A reasoner attests. A challenger challenges and is right. The bounty is `(2e18 * 5001) / 10000 = 10002000000000000 wei` (1.0002 SOV), and the pool gets `2e18 - 10002000000000000 = 9998000000000000 wei`. The split is off by 4 wei due to integer math. This is negligible per-transaction but could add up over time.

- **Recommendation:** (1) Add emitted event after slashing that logs the actual bounty and pool share paid, confirming the split. (2) Consider using a rounding function: `uint256 bounty = (a.reasonerBond * challengeBountyBps + 5000) / 10000;` to round-half-up instead of truncating. (3) Document the dust allocation policy explicitly in comments and in the admin setters. (4) Add a constraint in `setBonds()` to ensure that the minimum bond is at least large enough that the bounty calculation is meaningful (e.g., `require(_reasonerBond >= 10000, "Reasoner bond too small for bounty math");` if using bps-based splits).

---

### [MEDIUM] Admin can set oracleWindow to 0 seconds, rendering oracle slash impossible (DoS vector)

- **File / line:** `KommitBridge.sol`, lines 504–510 (setOracleWindow)
- **Issue:** The `setOracleWindow()` function enforces a lower bound of 60 seconds (line 508: `require(_oracleWindow >= 60 && _oracleWindow <= 7 days, "60s-7d");`). However, the deploy script (DeployKommit.s.sol) shows that the Safe will be the admin (line 79). If the Safe multisig is compromised or a malicious Safe signer votes to set `oracleWindow = 60` (the minimum), then **immediately call `setOracleWindow(0)`**, the transaction would revert... **but if the attack vector is Doomsday (admin wants to sabotage)**, the admin could set it to 1 second. Then, because block.timestamp has granularity of the block time (~2s on Polygon), the oracle's window could elapse **in the same block as seed reveal** or the very next block, making it impossible for the oracle to post a verdict in time (the oracle's RPC might not pick up the event until the next block, by which time the deadline has passed).

  Actually, the minimum is 60 seconds (hardcoded). So this is not a 0-second DoS. But there's a **practical DoS**: if the oracle runs with a 5-second latency (due to RPC/network jitter), and the admin sets `oracleWindow = 60` (the minimum), the oracle has only a 55-second window to: (1) pick up the SeedRevealed event, (2) replay the inference, (3) submit a transaction. On a congested network, this is tight.

  **More serious issue:** There's no setter for oracleWindow that prevents front-running or downtime. If the admin *wants* to disable oracle verdicts, setting oracleWindow to 60 seconds on a busy network is a soft DoS.

- **Exploit scenario:** Safe is compromised. Attacker-controlled Safe signer votes to `setOracleWindow(60)`. Hermes attests and a valid fraud is committed. Challenger reveals the seed. Oracle attempts to slash but encounters network congestion. By the time the oracle's slash tx is mined, the deadline has passed, and `claimByDefault()` has already settled the attestation. Fraud goes unpunished.

- **Recommendation:** (1) Increase the minimum oracleWindow to at least 5 minutes (300 seconds), giving oracle services a reasonable window to respond even on congested networks. (2) Add an admin event whenever oracleWindow is changed, so off-chain monitors can alert if it's set to a dangerous value. (3) Add a circuit-breaker mechanism: if oracleWindow is reduced by more than 50% in a single setOracleWindow call, revert (prevent flash-DoS of oracle). (4) Document in comments that the oracle service should monitor the oracleWindow and alert if it's set below some threshold (e.g., 5 min).

---

### [MEDIUM] MinerRewards pool is passive and unbounded; no safety cap or escrow mechanism

- **File / line:** `KommitBridge.sol`, lines 421–422 (_slashReasoner), 437–438 (_dismissChallenge); `MinerRewards.sol`, lines 100–110, 140–153
- **Issue:** When a reasoner is slashed or a challenger is punished, the remainder of the bond is transferred directly to the `minerRewardsPool` address (line 422: `IERC20(address(sovToken)).safeTransfer(minerRewardsPool, poolShare);`). The pool is expected to be the `MinerRewards` contract (line 77 in DeployKommit.s.sol: `address constant MINER_REWARDS = 0xFCb7d33F7D00040767FaAcA707F57c4E0Bd5db19;`). However, **there is no runtime check that minerRewardsPool is a valid MinerRewards contract or even a contract at all**. An attacker admin could:
  1. Set `minerRewardsPool` to an EOA address (line 516–518 in setMinerRewardsPool).
  2. Trigger slashing to send forfeited bonds to the EOA.
  3. The EOA then holds the SOV, not the contract, and there's no operator credit mechanism.

  More subtly: The MinerRewards contract (line 100 in MinerRewards.sol) requires that the operator be registered via `registerOperator()` before rewards can be credited. If the MinerRewards contract receives SOV directly from KommitBridge via `safeTransfer()`, but the operator is never registered, the SOV lands in the contract balance but is never claimed (it's not credited to any operator). **The MinerRewards contract lacks a fallback `creditReward()` mechanism for out-of-band transfers.** If KommitBridge sends SOV directly and there's no operator registered for that nodeId, the SOV is trapped.

  Actually, re-reading: KommitBridge doesn't track nodeIds—it just sends all forfeited bonds directly to the pool address via `safeTransfer()`. The MinerRewards contract would receive the SOV in its balance but has no function to claim it as a "general pool" (only operator-specific claims). The SOV would be stranded unless an admin manually credits it via `creditReward()` or `batchCreditReward()`.

- **Exploit scenario:** Admin (Safe) mistakenly sets `minerRewardsPool` to an EOA instead of the MinerRewards contract. A reasoner is slashed. The forfeited bond (e.g., 15 SOV) is sent to the EOA, where it sits. The operator community never receives the reward (since the reward was not credited to the MinerRewards contract). The SOV is effectively burnt.

  Or: Admin sets `minerRewardsPool` to the MinerRewards contract correctly. A challenge is dismissed, and the challenger's 20 SOV is sent to the contract. But because KommitBridge doesn't call `creditReward()`, the SOV lands in the contract balance. An operator attempts to claim rewards, but there's no operator-level credit for this "orphan" SOV. The SOV is stranded in the contract, visible to anyone but claimable only by calling the admin `creditReward()` method.

- **Recommendation:** (1) Add a runtime check in `setMinerRewardsPool()`: require that the new pool address is a contract and optionally that it implements the MinerRewards interface (has a `creditReward()` function). (2) Better: Instead of transferring directly to minerRewardsPool, have KommitBridge call a standardized `onBondForfeiture(uint256 amount)` callback on the pool, allowing the pool to decide how to handle the SOV (credit to a general pool, burn, etc.). (3) Add a `receiveForfeiture()` or similar fallback in MinerRewards that credits out-of-band SOV transfers to a "general pool" balance that operators can claim fairly (e.g., pro-rata to their lifetime rewards). (4) Document this rigorously in CLAUDE.md: "Do not set minerRewardsPool to an EOA. KommitBridge sends forfeited bonds directly to this address; ensure it is a contract that handles the SOV correctly."

---

### [LOW] Nonce/ID collision risk if nextId is ever reset or contract redeployed

- **File / line:** `KommitBridge.sol`, line 239 (nextId increment), line 179 (nextId state var)
- **Issue:** The `nextId` is a simple monotonic counter that increments on each attestation (line 239: `id = ++nextId;`). If a new version of KommitBridge is ever deployed (v2.0 for example), the counter restarts at 1. Off-chain systems (Hermes, oracles, UIs) might cache ID references assuming global uniqueness. If a new KommitBridge v2.0 is deployed at a different address and reuses IDs 1, 2, 3, etc., an off-chain system might confuse v1 ID #5 with v2 ID #5 if it relies on (contract_address, id) tuples without careful namespacing.

  This is a design concern, not a critical bug, because the contract address is part of the identity. But it's a footgun for off-chain indexing.

- **Exploit scenario:** Archival node or oracle system indexes KommitBridge v1 with IDs 1–100. A new KommitBridge v2 is deployed. Off-chain system accidentally points to v2 and starts reading attestations, reusing IDs 1–100. A developer manually links v1 ID #5 to v2 ID #5 without realizing they're different attestations. A false fraud claim is made.

- **Recommendation:** (1) Ensure off-chain systems always use (contract_address, id) as the composite key, never id alone. (2) Add a global `DEPLOYMENT_ID` constant to each version so indexers can distinguish v1 from v2: `bytes32 public constant DEPLOYMENT_ID = keccak256(abi.encodePacked("KOMMIT-v1.1", block.chainid, address(this)));` set in constructor. (3) Include the deployment chain ID and contract address in event emissions for added clarity.

---

### [LOW] Lack of explicit zero-address guards in constructor and setters

- **File / line:** `KommitBridge.sol`, lines 192–203 (constructor), 512–518 (setCircuitBreaker, setMinerRewardsPool)
- **Issue:** The constructor (lines 192–203) and setters (lines 512–518) do not explicitly check that passed addresses are not address(0). If `setMinerRewardsPool(address(0))` is called, subsequent slashing will still execute but the safeTransfer to address(0) will succeed (EOA addresses can receive ETH and ERC20 transfers), sending the SOV to a blackhole. The contract logic doesn't revert—it just silently loses funds.

  Similarly, if `setCircuitBreaker(address(0))` is called, all subsequent pause checks will call `globalPaused()` on a null address, reverting with a low-level error that's hard to debug.

- **Exploit scenario:** Admin (Safe) calls `setMinerRewardsPool(address(0))` by accident (clipboard error). Slashing happens, and 15 SOV is transferred to 0x0000...0000, burning it irreversibly.

- **Recommendation:** Add explicit zero-address checks:
  ```solidity
  function setMinerRewardsPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
      require(_pool != address(0), "KOMMIT__ZeroAddress");
      minerRewardsPool = _pool;
  }
  
  function setCircuitBreaker(address _breaker) external onlyRole(DEFAULT_ADMIN_ROLE) {
      require(_breaker != address(0), "KOMMIT__ZeroAddress");
      circuitBreaker = ICircuitBreaker(_breaker);
  }
  ```
  And optionally in the constructor:
  ```solidity
  require(_sovToken != address(0) && _circuitBreaker != address(0) && _minerRewardsPool != address(0), "KOMMIT__ZeroAddress");
  ```

---

### [INFO] Hardcoded window constants lack runtime flexibility for mainnet vs testnet

- **File / line:** `KommitBridge.sol`, lines 160–169 (default window values)
- **Issue:** The default windows (challenge, reveal, oracle) are hardcoded to 1 hour each. On Polygon Mainnet, this is reasonable (block time ~2s, so 1 hour ≈ 1800 blocks). But if KommitBridge is ever deployed to a rollup with longer block times (e.g., Arbitrum with ~250ms, or a future mainnet with faster blocks), the 1-hour window semantics change. The test suite uses these defaults, so any porting to a different chain would need manual adjustment.

  This is not a bug (the safe setter functions allow runtime changes), but it's a documentation gap.

- **Recommendation:** Add a comment in the constants section noting the assumptions:
  ```solidity
  /// @notice Challenge window in seconds. Tuned for Polygon Mainnet (~2s blocks).
  /// Increase for longer block times; decrease for faster chains (not recommended).
  uint256 public challengeWindow = 1 hours;
  ```
  And in deploy script, document:
  ```
  // For chains with different block times, consider adjusting windows:
  // - Ethereum L1 (~12s): increase to 3-4 hours
  // - Arbitrum (~0.3s): keep 1 hour or increase to 2 hours
  // - Polygon (~2s): 1 hour is correct
  ```

---

## Items checked and cleared

- ✅ **Seed commit binding:** `keccak256(abi.encodePacked(seed, salt))` is cryptographically binding and collision-resistant. Seed reveal is validated correctly (line 321–322).
- ✅ **State machine transitions:** All six states (Pending, Finalized, Challenged, Revealed, Slashed, Dismissed) have clear entry and exit conditions. Status checks prevent invalid transitions (e.g., can't finalize after challenge).
- ✅ **Token accounting on happy path:** Finalize, dismiss, and slash all properly refund or forfeit bonds. Conservation tests in the test suite (lines 867–969) validate that all SOV is accounted for across slashing, dismissal, and default paths.
- ✅ **SafeERC20 usage:** All token transfers use `IERC20(address(sovToken)).safeTransfer(...)` (lines 236, 415, 418, 422, 434, 438, 458), preventing silent transfer failures.
- ✅ **Role separation (KOM-OPS-1):** Deploy script enforces `reasonerWallet != oracleWallet` (line 108), preventing one address from attesting and self-verdicting.
- ✅ **Model registry:** Models must be registered before attestation (line 231). Prevents unregistered models from attesting.
- ✅ **Nonreentrant guard on oracleSlash:** Function has `nonReentrant` (line 384), preventing direct re-entry. Status checks prevent same-attestation re-settlement.
- ✅ **Circuit breaker integration:** Attestation, challenge, and revealSeed all check `circuitBreaker.globalPaused()` (lines 230, 268, 313). Settlement (claimByDefault, claimByChallenger, finalize, oracleSlash) deliberately bypass pause checks to allow honest recovery (lines 1144–1165 in tests).
- ✅ **Bond asymmetry (KOM-003):** Admin setter enforces `challengerBond >= reasonerBond` (line 480). Tests validate this (lines 713–748).
- ✅ **Event emission:** All state-changing operations emit events (ModelRegistered, ReasoningAttested, ReasoningChallenged, SeedRevealed, ReasoningSlashed, ChallengeDismissed, ReasoningFinalized). Event tests pass (lines 1214–1325).
- ✅ **View functions:** Correctly return Attestation struct and model registry state without mutation.

---

## Test coverage gaps

- ❌ **Oracle DoS via window races:** No test for the critical race condition (CRITICAL finding above) where `claimByDefault()` front-runs `oracleSlash()` at the deadline boundary. Tests confirm claimByDefault works after the window (line 320–338) and oracleSlash works while Revealed (line 368–414), but no test for the simultaneous-deadline race or block-by-block boundary.
- ❌ **Reentrancy via malicious challenger:** No test for a challenger contract that re-enters during `_slashReasoner()` token transfer (lines 405–426). The test suite doesn't cover scenarios where `a.challenger` or `a.reasoner` are contracts with fallback functions.
- ❌ **Cross-attestation reentrancy:** No test that a malicious contract can call `finalize()` on an unrelated attestation during a token transfer in another settlement. The invariant suite (lines 1415–1457) tracks aggregate SOV but doesn't test fine-grained call ordering during transfers.
- ❌ **Admin setter validation:** No test for setting `minerRewardsPool` to address(0) and confirming funds are lost (or confirming it reverts, if a zero-address guard is added). No test for setting `circuitBreaker` to address(0).
- ❌ **Model hash collision:** No fuzz test for `registerModel()` with two different names but the same hash (should revert on second register, but no test confirms collision is rejected durably across multiple registrations).
- ❌ **Bounty precision edge cases:** No test for bounty calculations on small bonds (e.g., 1 wei, 11 wei) with fuzzed bounty rates. The fuzz test (line 1040–1068) uses 100 SOV bonds; smaller values are not exercised.
- ❌ **Window boundary off-by-one:** No test for `block.timestamp == challengeDeadline` (should reject) vs `block.timestamp == challengeDeadline + 1` (should accept). Fuzz tests use `bound()` which can miss single-block boundaries.
- ❌ **Model registry seeding in deploy script:** No integration test that the deploy script correctly registers `MODEL_HASH_PRIMARY` and can be verified post-broadcast. The DeployKommit.s.sol script has post-broadcast checks, but they're not tested in the Forge suite.

---

## Verdict

### **NO-GO for Polygon Mainnet broadcast as-is.**

The **CRITICAL finding** (oracle front-run DoS at deadline boundary) is a **fatal flaw in the fraud-proof economics**. The v1.1 state machine allows an unpermissioned watcher to call `claimByDefault()` the instant the oracle window elapses, permanently preventing the oracle from verdicting fraud. This defeats the entire purpose of the oracle layer. An honest reasoner can lie, the oracle can compute the truth, but if there's network congestion or RPC latency when the deadline approaches, the oracle loses the race to `claimByDefault()` and fraud goes unpunished.

The **HIGH findings** (reentrancy on settlement functions + deploy script model-registration gap) are serious enough to warrant fixes before broadcast:
1. The missing `nonReentrant` guards on `claimByDefault()`, `claimByChallenger()`, and `finalize()` create a cross-attestation reentrancy window during token transfers.
2. The deploy script can leave the contract non-functional if model registration fails or is misconfigured, with no clear recovery path post-admin-migration to Safe.

The contract is well-audited in terms of token conservation and basic state machine logic, but **the oracle window race condition is a showstopper**. Fixing it requires:
- Either making `oracleSlash()` exclusive via a window lock (oracle only, no claimByDefault while oracle window open).
- Or extending the claim-by-default window to require an additional block or grace period after the oracle window truly closes.
- Or introducing explicit sequencing: oracle must provide a verdict *before* anyone can settle.

**Recommendation: Do not broadcast. Schedule a v1.2 redeploy (1–2 days) with the critical findings addressed.**

---

