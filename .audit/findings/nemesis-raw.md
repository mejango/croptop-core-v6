# N E M E S I S — Raw Findings (Pre-Verification)

## Phase 0: Attacker Recon

**Language:** Solidity 0.8.26
**Framework:** Juicebox V6 / Bananapus / Croptop

### Attack Goals (Q0.1)
1. **Drain ETH** — manipulate fee calculation in `mintFrom()` to avoid fees or redirect funds
2. **Unauthorized posting** — bypass allowance restrictions to post NFTs to projects without permission
3. **Fee theft/redirection** — manipulate fee routing to steal or redirect protocol fees
4. **Griefing** — post unwanted content or corrupt tier state for other projects

### Novel Code (Q0.2)
- `CTPublisher._setupPosts()` — custom tier setup + validation with packed allowances
- `CTPublisher.mintFrom()` — custom fee calculation and dual-terminal payment routing
- `CTPublisher.configurePostingCriteriaFor()` — custom bit-packed allowance storage
- `CTDeployer.deployProjectFor()` — multi-step project deployment with hook, controller, suckers, permissions
- `CTDeployer.beforeCashOutRecordedWith()` — data hook forwarding with sucker bypass

### Value Stores (Q0.3)
- `CTPublisher.mintFrom()` receives ETH transiently (msg.value → project terminal + fee terminal)
- `address(this).balance` used for fee payment — residual after project payment
- No permanent ETH storage

### Complex Paths (Q0.4)
- `mintFrom()` → `_setupPosts()` → `hook.adjustTiers()` → `projectTerminal.pay()` → `feeTerminal.pay()` (3+ external calls)
- `deployProjectFor()` → 7+ external calls across deployer, controller, publisher, suckers, permissions

### Coupled Value (Q0.5)
- `tierIdForEncodedIPFSUriOf` must match actual tier existence in hook.STORE()
- `_packedAllowanceFor` and `_allowedAddresses` must be set atomically for same (hook, category)
- `dataHookOf[projectId]` must match the project's actual data hook configuration
- `msg.value` = `payValue` + `fee` (transient accounting invariant)

### Priority Order
1. `CTPublisher.mintFrom()` + `_setupPosts()` — value handling, fee calculation, external calls
2. `CTDeployer.deployProjectFor()` — complex multi-step deployment
3. `CTDeployer.beforeCashOutRecordedWith()` — sucker bypass logic
4. `CTPublisher.configurePostingCriteriaFor()` — permission model, packed storage

---

## Phase 1: Dual Mapping

### 1A: Function-State Matrix

**CTPublisher:**
| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| tiersFor() | tierIdForEncodedIPFSUriOf | — | — | hook.STORE().tierOf() |
| allowanceFor() | _packedAllowanceFor, _allowedAddresses | — | — | — |
| configurePostingCriteriaFor() | — | _packedAllowanceFor, _allowedAddresses | _requirePermissionFrom(owner, ADJUST_721_TIERS) | JBOwnable(hook).owner(), hook.PROJECT_ID() |
| mintFrom() | msg.value, FEE_PROJECT_ID | — (via _setupPosts) | — (external payable) | hook.PROJECT_ID(), _setupPosts(), hook.adjustTiers(), hook.METADATA_ID_TARGET(), DIRECTORY.primaryTerminalOf() x2, terminal.pay() x2 |
| _setupPosts() | tierIdForEncodedIPFSUriOf, _packedAllowanceFor, _allowedAddresses | tierIdForEncodedIPFSUriOf | — (internal) | hook.STORE().maxTierIdOf() |

**CTDeployer:**
| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| beforePayRecordedWith() | dataHookOf | — | — | dataHookOf[].beforePayRecordedWith() |
| beforeCashOutRecordedWith() | dataHookOf | — | — | SUCKER_REGISTRY.isSuckerOf(), dataHookOf[].beforeCashOutRecordedWith() |
| hasMintPermissionFor() | — | — | — | SUCKER_REGISTRY.isSuckerOf() |
| onERC721Received() | PROJECTS | — | msg.sender==PROJECTS, from==address(0) | — |
| deployProjectFor() | PROJECTS | dataHookOf | — | controller.PROJECTS(), PROJECTS.count(), DEPLOYER.deployHookFor(), controller.launchProjectFor(), PUBLISHER.configurePostingCriteriaFor(), SUCKER_REGISTRY.deploySuckersFor(), PROJECTS.transferFrom(), PERMISSIONS.setPermissionsFor() |
| claimCollectionOwnershipOf() | PROJECTS | — | PROJECTS.ownerOf()==_msgSender() | hook.PROJECT_ID(), JBOwnable(hook).transferOwnershipToProject() |
| deploySuckersFor() | PROJECTS | — | _requirePermissionFrom(owner, DEPLOY_SUCKERS) | SUCKER_REGISTRY.deploySuckersFor() |

**CTProjectOwner:**
| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| onERC721Received() | PROJECTS | — | msg.sender==PROJECTS | PERMISSIONS.setPermissionsFor() |

### 1B: Coupled State Dependency Map

| Pair | State A | State B | Invariant | Mutation Points |
|------|---------|---------|-----------|-----------------|
| 1 | _packedAllowanceFor[hook][cat] | _allowedAddresses[hook][cat] | Both set/cleared atomically | configurePostingCriteriaFor() |
| 2 | tierIdForEncodedIPFSUriOf[hook][uri] | Actual tier in hook.STORE() | If tierIdForEncodedIPFSUriOf != 0, tier must exist | _setupPosts() + hook.adjustTiers() |
| 3 | dataHookOf[projectId] | Project ruleset's data hook setting | Must point to correct hook | deployProjectFor() |
| 4 | msg.value (transient) | payValue + fee (transient) | msg.value = payValue + totalPrice/FEE_DIVISOR | mintFrom() |

### 1C: Cross-Reference

| Function | Writes A | Writes B | A<>B Pair | Sync Status |
|----------|----------|----------|-----------|-------------|
| configurePostingCriteriaFor() | _packedAllowanceFor | _allowedAddresses | Pair 1 | SYNCED |
| _setupPosts() | tierIdForEncodedIPFSUriOf | — (adjustTiers in caller) | Pair 2 | SYNCED (atomic tx) |
| deployProjectFor() | dataHookOf | — (set once) | Pair 3 | SYNCED (one-time) |

---

## Phase 2: Feynman Interrogation (Pass 1)

### CTPublisher.mintFrom() — Line-by-line

**L308: `uint256 payValue = msg.value;`**
- Q1.1: Initializes payValue to total ETH received. Will be reduced by fee.
- VERDICT: SOUND

**L314: `uint256 projectId = hook.PROJECT_ID();`**
- Q4.1: hook is user-provided. Could be a malicious contract returning any projectId.
- Q4.2: If attacker passes hook that returns FEE_PROJECT_ID, fee is skipped (L321). But payment goes to fee project anyway. Net effect: fee project receives MORE (no fee deduction), not less.
- VERDICT: SOUND — self-serving attack against malicious hook owner only

**L318-319: `_setupPosts(hook, posts)` returns tiersToAdd, tierIdsToMint, totalPrice**
- Q7.5: For EXISTING tiers, post.price is user-controlled and unvalidated. totalPrice can be understated.
- VERDICT: **SUSPECT** — fee evasion vector

**L321-326: Fee calculation**
```solidity
if (projectId != FEE_PROJECT_ID) {
    payValue -= totalPrice / FEE_DIVISOR;
}
```
- Q1.1: Fee = totalPrice/20 = 5%. Deducted from payValue.
- Q4.3: **ASSUMES totalPrice accurately reflects the actual cost of all mints.** For existing tiers, totalPrice uses post.price (user input), NOT the actual tier price stored in the hook.
- Q5.1: totalPrice=0 → fee=0, payValue unchanged. Valid but means zero-priced mints pay no fee.
- VERDICT: **VULNERABLE** — totalPrice can be artificially low for existing tiers

**L330-332: `if (totalPrice > payValue) revert`**
- Q1.1: Ensures msg.value covers at least totalPrice + fee.
- Q4.3: Same assumption — if totalPrice is artificially low, this check is weakened.
- VERDICT: SOUND (check itself is correct, but input totalPrice may be wrong)

**L336: `hook.adjustTiers({tiersToAdd, tierIdsToRemove: []})`**
- Q7.3: External call to potentially malicious hook. State (tierIdForEncodedIPFSUriOf) already updated.
- Q2.1: If moved before _setupPosts → reentrancy could create duplicate tiers (current ordering is safe).
- VERDICT: SOUND (CEI pattern: state before external call)

**L353-355: Assembly metadata write**
```solidity
assembly { mstore(add(mintMetadata, 32), feeProjectId) }
```
- Q1.1: Writes FEE_PROJECT_ID as referral into metadata's first 32 bytes.
- Q4.2: JBMetadataResolver.addToMetadata() always produces >= 32 bytes of data.
- VERDICT: SOUND

**L376-384: `projectTerminal.pay{value: payValue}(...)`**
- Q6.1: Return value ignored (slither annotation). Terminal pay returns tokens minted — not needed here.
- Q7.3: At this point, all state is updated. External call is after state changes. ✓
- VERDICT: SOUND

**L395-403: `feeTerminal.pay{value: address(this).balance}(...)`**
- Q4.3: `address(this).balance` could include pre-existing ETH (from selfdestruct/coinbase).
- Q1.1: Uses `address(this).balance` twice (value + amount) — both evaluated before the call, same value. ✓
- VERDICT: SOUND (pre-existing ETH sweep is LOW impact)

### CTPublisher._setupPosts() — Key Lines

**L432: `uint256 startingTierId = hook.STORE().maxTierIdOf(address(hook)) + 1;`**
- Q4.2: External call. Assumes sequential tier ID assignment. Valid for standard JB721TiersHook.
- Q7.5: Within same tx, no race condition.
- VERDICT: SOUND

**L450-454: Existing tier check**
```solidity
uint256 tierId = tierIdForEncodedIPFSUriOf[address(hook)][post.encodedIPFSUri];
if (tierId != 0) tierIdsToMint[i] = tierId;
```
- Q1.1: Reuses existing tier instead of creating a new one. Efficient.
- Q4.3: **ASSUMES the tier still exists in the hook.** If the tier was removed externally (via adjustTiers), tierId points to a non-existent tier.
- VERDICT: SUSPECT — stale reference (LOW impact, causes revert)

**L457-527: New tier creation block (skipped for existing tiers)**
- Q3.1: Price validation (L475), supply validation (L481-488), split validation (L492), address validation (L497) — all present for NEW tiers.
- Q3.2: **NONE of these validations apply to existing tiers.** The `if (tierIdsToMint[i] == 0)` gate on L457 skips all validation for existing tiers.
- VERDICT: **VULNERABLE** — validation bypass for existing tiers, including post.price

**L530: `totalPrice += post.price;`**
- Q1.1: Accumulates total price for fee calculation.
- Q4.3: For existing tiers, post.price is user-controlled. User can set 0 to minimize fee.
- VERDICT: **VULNERABLE** — fee evasion

### CTDeployer.deployProjectFor() — Key Lines

**L242-243: Ruleset configuration**
```solidity
rulesetConfigurations[0].weight = 1_000_000 * (10 ** 18);
rulesetConfigurations[0].metadata.baseCurrency = JBCurrencyIds.ETH;
```
- VERDICT: SOUND

**L275-278: Metadata settings**
```solidity
rulesetConfigurations[0].metadata.cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE;
rulesetConfigurations[0].metadata.dataHook = address(this);
rulesetConfigurations[0].metadata.useDataHookForPay = true;
```
- Q3.1: `useDataHookForPay = true` is set. `useDataHookForCashOut` is NOT set (defaults to false).
- Q3.3: CTDeployer implements `beforeCashOutRecordedWith()` with sucker bypass logic, but it's never called because `useDataHookForCashOut = false`.
- VERDICT: **SUSPECT** — dead code, sucker cash out bypass non-functional

**L280-289: assert for projectId match**
- Q2.4: If assert fails, entire tx reverts including hook deployment. No orphaned state.
- VERDICT: SOUND

**L310: `PROJECTS.transferFrom(address(this), owner, projectId);`**
- Q2.1: Ownership transfer happens BEFORE permission granting (L319-324).
- Q4.1: If `owner` is a contract that implements onERC721Received and re-enters, the permissions haven't been set yet. But the owner can set their own permissions later. No exploit.
- VERDICT: SOUND

### CTDeployer.beforeCashOutRecordedWith() — Full Analysis

**L165-167: Sucker check**
```solidity
if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
    return (0, context.cashOutCount, context.totalSupply, hookSpecifications);
}
```
- Q1.1: Suckers get 0 tax rate for cross-chain bridging.
- Q3.1: `useDataHookForCashOut` is not set → this function is never called.
- VERDICT: **VULNERABLE** — feature is non-functional due to missing config

**L171: `return dataHookOf[context.projectId].beforeCashOutRecordedWith(context);`**
- Q4.3: If dataHookOf is address(0) for a project, this call reverts (call to zero address). Only projects deployed via deployProjectFor() have dataHookOf set.
- VERDICT: SOUND (reverts safely for misconfigured projects)

### CTProjectOwner.onERC721Received() — Key Analysis

**L72: `projectId: uint56(tokenId)`**
- Q5.1: tokenId is uint256. Cast to uint56 truncates if tokenId > 2^56. Extremely unlikely for Juicebox project IDs but technically possible.
- Q3.3: CTDeployer uses `uint64(projectId)` in the same struct. Inconsistent casting.
- VERDICT: SOUND (practically, project IDs will never exceed uint56)

---

## Phase 3: State Inconsistency (Pass 2)

### Mutation Matrix

| State Variable | Mutating Function | Updates Coupled State? |
|----------------|-------------------|-----------------------|
| _packedAllowanceFor[h][c] | configurePostingCriteriaFor() | ✓ also sets _allowedAddresses |
| _allowedAddresses[h][c] | configurePostingCriteriaFor() | ✓ also sets _packedAllowanceFor |
| tierIdForEncodedIPFSUriOf[h][u] | _setupPosts() (internal, from mintFrom) | ✓ tier created atomically in same tx |
| tierIdForEncodedIPFSUriOf[h][u] | EXTERNAL: hook.adjustTiers(tierIdsToRemove) | ✗ GAP — tier removed but tierIdForEncodedIPFSUriOf not cleared |
| dataHookOf[projectId] | deployProjectFor() | ✓ set once, immutable |

### GAP Analysis

**GAP-1: tierIdForEncodedIPFSUriOf stale after external tier removal**
- Trigger: Project owner calls hook.adjustTiers() directly to remove a tier
- State A: tierIdForEncodedIPFSUriOf[hook][uri] still points to removed tier ID
- State B: Tier no longer exists in hook.STORE()
- Consequence: Attempting to mint from this URI via mintFrom() reverts at the hook level
- Severity: LOW — causes reverts but no value loss. Self-inflicted by the project owner.

### Parallel Path Comparison

| Operation | configurePostingCriteriaFor (via CTPublisher) | _configurePostingCriteriaFor (via CTDeployer) |
|-----------|----------------------------------------------|----------------------------------------------|
| _packedAllowanceFor | ✓ updated | ✓ updated (delegates to publisher) |
| _allowedAddresses | ✓ updated | ✓ updated (delegates to publisher) |
| Permission check | ✓ _requirePermissionFrom | ✓ implicit (CTDeployer is hook owner) |
| Sync status | ✓ SYNCED | ✓ SYNCED |

No parallel path mismatch found for coupled state updates.

### Masking Code Check

No masking patterns (ternary clamps, min caps, try-catch swallowing) found in the codebase. Arithmetic is straightforward with Solidity 0.8.26 built-in overflow checks.

---

## Phase 4: Nemesis Feedback Loop

### Pass 3 (Feynman re-interrogation of State findings)

**Re: GAP-1 (tierIdForEncodedIPFSUriOf stale)**
- Q: "WHY doesn't CTPublisher clear tierIdForEncodedIPFSUriOf when a tier is removed?"
- A: CTPublisher doesn't control tier removal. The hook owner can remove tiers directly via hook.adjustTiers(). CTPublisher has no callback or hook to detect tier removal.
- Q: "What downstream function reads the stale value and breaks?"
- A: mintFrom() → _setupPosts() reads tierIdForEncodedIPFSUriOf. If stale, it attempts to mint from a non-existent tier, which reverts in the hook's payment processing. The revert is safe — no value loss.
- VERDICT: Confirmed LOW. No escalation.

**Re: NM-001 (fee evasion)**
- Q: "WHY doesn't _setupPosts validate post.price for existing tiers?"
- A: The code assumes that for existing tiers, the price is already set correctly in the hook. But the fee calculation uses post.price (from the current call), not the actual tier price.
- Q: "Can the fee be zero even for legitimate existing tier mints?"
- A: Yes. User sets post.price = 0 for an existing tier. Fee = 0. The hook still enforces the actual tier price during payment. Only the protocol fee is evaded.
- VERDICT: Confirmed HIGH. No downgrade.

### Pass 4 (State re-analysis of Feynman findings)

**Re: NM-001 — checking for additional coupled state implications:**
- The fee evasion doesn't create state inconsistency per se — all state variables are updated correctly. The issue is in the ACCOUNTING LOGIC (fee computed on wrong input), not in coupled state.
- No additional state gaps found from this finding.

**Re: NM-002 (useDataHookForCashOut missing):**
- This is a CONFIGURATION gap, not a runtime state inconsistency.
- The coupled pair (useDataHookForCashOut flag ↔ beforeCashOutRecordedWith implementation) is mismatched at deployment time, not during mutations.
- No additional runtime state gaps found.

### Convergence Check
Pass 4 produced no new findings, coupled pairs, suspects, or root causes. **CONVERGED.**

---

## Phase 5: Multi-Transaction Journey Tracing

### Sequence 1: Fee Evasion (NM-001)
1. Alice calls mintFrom(hook, [{encodedIPFSUri: X, price: 1 ETH, totalSupply: 100, ...}], ...) with msg.value = 1.05 ETH
   - Tier created with price 1 ETH
   - Fee: 0.05 ETH paid to fee project ✓
   - payValue: 1.0 ETH to project terminal ✓
2. Bob calls mintFrom(hook, [{encodedIPFSUri: X, price: 0, ...}], ...) with msg.value = 1.0 ETH
   - Existing tier found (tierId != 0)
   - totalPrice = 0
   - Fee: 0 (should be 0.05 ETH) ✗
   - payValue: 1.0 ETH to project terminal
   - Hook mints NFT (actual price 1 ETH, payment 1 ETH covers it)
3. Repeat N times by different users → fee project loses 0.05 ETH per mint

### Sequence 2: Stale tierIdForEncodedIPFSUriOf (NM-003, LOW)
1. Alice creates tier via mintFrom (tierIdForEncodedIPFSUriOf[hook][X] = 5)
2. Project owner removes tier 5 via hook.adjustTiers({tierIdsToRemove: [5]})
3. Bob tries to mint from URI X via mintFrom
4. _setupPosts sees tierId = 5 (stale), sets tierIdsToMint = [5]
5. projectTerminal.pay() sends payment with metadata to mint tier 5
6. Hook rejects mint (tier 5 doesn't exist) → tx reverts
7. Bob's ETH is safe (tx reverted), but mint fails unexpectedly

### Sequence 3: Sucker Cash Out (NM-002)
1. CTDeployer deploys project with cashOutTaxRate = MAX and useDataHookForCashOut = false
2. Sucker contract tries to cash out tokens for the project
3. Terminal processes cash out using ruleset's cashOutTaxRate = MAX (100% tax)
4. beforeCashOutRecordedWith() is NOT called (useDataHookForCashOut = false)
5. Sucker pays maximum tax → cross-chain bridging is economically infeasible

---

## Raw Finding List

### NM-001: Fee Evasion for Existing Tier Mints
- Severity: HIGH
- Source: Feynman Pass 1 (Category 4 — assumption that post.price matches actual tier price)

### NM-002: useDataHookForCashOut Not Set — Sucker Cash Out Bypass Non-Functional
- Severity: MEDIUM
- Source: Feynman Pass 1 (Category 3 — consistency: useDataHookForPay set but useDataHookForCashOut not)

### NM-003: tierIdForEncodedIPFSUriOf Stale After External Tier Removal
- Severity: LOW
- Source: State Inconsistency Pass 2 (GAP-1 — external mutation without coupled update)

### NM-004: Residual ETH Sweep to Fee Project
- Severity: LOW (Informational)
- Source: Feynman Pass 1 (Category 4 — assumption about address(this).balance)

### NM-005: dataHookOf Immutable After Deployment
- Severity: LOW (Informational / Design Limitation)
- Source: State Inconsistency Pass 2 (no update function)
