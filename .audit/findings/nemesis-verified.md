# N E M E S I S — Verified Findings

## Scope
- Language: Solidity 0.8.26
- Modules analyzed: CTPublisher, CTDeployer, CTProjectOwner, Deploy.s.sol, ConfigureFeeProject.s.sol, CroptopDeploymentLib
- Functions analyzed: 19 (all entry points across src/ and script/)
- Coupled state pairs mapped: 4
- Mutation paths traced: 8
- Nemesis loop iterations: 4 (Pass 1 Feynman + Pass 2 State + Pass 3 Feynman targeted + Pass 4 State targeted → converged)

## Nemesis Map (Phase 1 Cross-Reference)

| Function | Writes _packed | Writes _allowed | Writes tierIdFor | Writes dataHookOf | Sync Status |
|----------|---------------|----------------|-----------------|-------------------|-------------|
| configurePostingCriteriaFor() | YES | YES | — | — | SYNCED |
| _setupPosts() | — | — | YES | — | SYNCED (atomic) |
| deployProjectFor() | — | — | — | YES | SYNCED |
| External: hook.adjustTiers(remove) | — | — | NO (stale) | — | GAP (LOW) |

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Original Sev | Verdict | Final Sev |
|----|--------|-------------|-------------|-------------|---------|-----------|
| NM-001 | Feynman→State cross-feed | post.price ↔ actual tier price | mintFrom() (existing tier) | HIGH | TRUE POSITIVE | HIGH |
| NM-002 | Feynman (Category 3) | useDataHookForCashOut ↔ beforeCashOutRecordedWith() | deployProjectFor() | MEDIUM | TRUE POSITIVE | MEDIUM |
| NM-003 | State Inconsistency (GAP-1) | tierIdForEncodedIPFSUriOf ↔ hook.STORE() | External adjustTiers(remove) | LOW | TRUE POSITIVE | LOW |
| NM-004 | Feynman (Category 4) | address(this).balance ↔ expected fee | mintFrom() | LOW | TRUE POSITIVE | LOW |
| NM-005 | State Inconsistency | dataHookOf ↔ project config | — (no update path) | LOW | TRUE POSITIVE | LOW |

---

## Verified Findings (TRUE POSITIVES)

---

### Finding NM-001: Fee Evasion for Existing Tier Mints

**Severity:** HIGH
**Source:** Cross-feed (Feynman Category 4 assumption exposed → State accounting analysis confirmed)
**Verification:** Deep Code Trace (Method A) — all paths traced, no mitigating code found.

**Coupled Pair:** `post.price` (user input in `CTPost`) ↔ actual tier price (stored in `hook.STORE()`)
**Invariant:** The fee calculation must use the actual price of the NFT being minted, not a user-controlled value.

**Feynman Question that exposed it:**
> Q4.3: "What does `totalPrice += post.price` (L530) assume about the relationship between `post.price` and the actual tier price? Is this assumption enforced?"

**State Mapper gap that confirmed it:**
> The validation block at L457-500 (price check, supply check, split check, address check) is gated by `if (tierIdsToMint[i] == 0)` — it only runs for NEW tiers. For existing tiers, `post.price` is used in fee calculation with zero validation.

**The code:**

`src/CTPublisher.sol:450-530` — The critical path in `_setupPosts()`:
```solidity
// L450-454: Existing tier check
uint256 tierId = tierIdForEncodedIPFSUriOf[address(hook)][post.encodedIPFSUri];
if (tierId != 0) tierIdsToMint[i] = tierId;

// L457: Gate — ALL validation is INSIDE this block (new tiers only)
if (tierIdsToMint[i] == 0) {
    // L475: price validation — ONLY for new tiers
    if (post.price < minimumPrice) {
        revert CTPublisher_PriceTooSmall(post.price, minimumPrice);
    }
    // ... other validations ...
}

// L530: OUTSIDE the gate — runs for ALL posts (new AND existing)
totalPrice += post.price;  // post.price is user-controlled for existing tiers
```

`src/CTPublisher.sol:321-326` — Fee calculation:
```solidity
if (projectId != FEE_PROJECT_ID) {
    payValue -= totalPrice / FEE_DIVISOR;  // fee based on unvalidated totalPrice
}
```

**Why this is wrong:**

For existing tiers, the `if (tierIdsToMint[i] == 0)` gate on line 457 causes the entire validation block to be skipped. This means `post.price` is never checked against `minimumPrice` or the actual tier price. However, `totalPrice += post.price` on line 530 runs unconditionally, using this unvalidated value to compute the protocol fee.

A user minting from an existing tier can set `post.price = 0` (or any arbitrarily low value). The fee calculation `totalPrice / FEE_DIVISOR` then produces a near-zero fee. The hook's payment processing still enforces the actual tier price (the user must send enough ETH), but the 5% protocol fee is evaded.

**Verification evidence:**

Code trace confirms no mitigating code exists:
1. `_setupPosts()` is the only function that computes `totalPrice`
2. `totalPrice` is only used for fee calculation and the `totalPrice > payValue` check
3. No other validation of `post.price` for existing tiers exists anywhere in the codebase
4. The hook enforces its own tier price during payment, but this is independent of the Croptop fee

**Trigger Sequence:**
1. Alice calls `mintFrom()` with a new post: `{encodedIPFSUri: X, price: 1 ETH, totalSupply: 100, ...}` and `msg.value = 1.05 ETH`
   - New tier created with price 1 ETH. Fee: 0.05 ETH paid to fee project. ✓
2. Bob calls `mintFrom()` with existing post: `{encodedIPFSUri: X, price: 0, ...}` and `msg.value = 1.0 ETH`
   - `tierIdForEncodedIPFSUriOf[hook][X]` returns existing tier ID → skips validation
   - `totalPrice = 0`, fee = 0, `payValue = 1.0 ETH`
   - All 1.0 ETH goes to project terminal. Fee project receives 0.
   - Hook processes payment, mints NFT (actual price 1 ETH, payment 1 ETH). ✓ Mint succeeds.
3. Fee project lost: 0.05 ETH (5% of 1 ETH). Repeatable for every existing-tier mint.

**Impact:**
- The fee project (CPN — Croptop Publishing Network) loses 5% revenue on every existing-tier mint where the user sets `post.price` below the actual tier price.
- First mints (new tiers) correctly enforce minimum price and pay fees. All subsequent mints (from existing tiers) can evade fees entirely.
- In popular projects where the same tier is minted many times, the cumulative fee loss is significant.
- Any user can exploit this with a direct contract call — no special access or setup required.

**Suggested fix:**

For existing tiers, read the actual tier price from the hook and use it for fee calculation:

```solidity
// After finding existing tier (L450-454), ALSO validate/use the actual price:
if (tierId != 0) {
    tierIdsToMint[i] = tierId;
    // Use the actual tier price for fee calculation, not post.price
    JB721Tier memory tier = hook.STORE().tierOf({hook: address(hook), id: tierId, includeResolvedUri: false});
    totalPrice += tier.price;  // Use actual price, skip to end of loop
    continue;
}
```

Alternatively, validate that `post.price` matches the actual tier price for existing tiers.

---

### Finding NM-002: `useDataHookForCashOut` Not Set — Sucker Tax-Free Cash Out Mechanism Non-Functional

**Severity:** MEDIUM
**Source:** Feynman Pass 1 (Category 3 — consistency between `useDataHookForPay = true` and missing `useDataHookForCashOut`)
**Verification:** Deep Code Trace (Method A) — confirmed no setting of `useDataHookForCashOut` anywhere in the deployment path.

**Feynman Question that exposed it:**
> Q3.1: "If `useDataHookForPay` is explicitly set to `true` (L277), why is `useDataHookForCashOut` not also set to `true`? `beforeCashOutRecordedWith()` is fully implemented with sucker bypass logic — when is it called?"

**The code:**

`src/CTDeployer.sol:275-278` — Ruleset metadata configuration:
```solidity
rulesetConfigurations[0].metadata.cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE;
rulesetConfigurations[0].metadata.dataHook = address(this);
rulesetConfigurations[0].metadata.useDataHookForPay = true;
// NOTE: useDataHookForCashOut is NOT set — defaults to false
```

`src/CTDeployer.sol:153-172` — The implemented (but never-called) function:
```solidity
/// @notice Allow cash outs from suckers without a tax.
function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
    external view override returns (...)
{
    // If the cash out is from a sucker, return the full cash out amount without taxes or fees.
    if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
        return (0, context.cashOutCount, context.totalSupply, hookSpecifications);
    }
    return dataHookOf[context.projectId].beforeCashOutRecordedWith(context);
}
```

**Why this is wrong:**

`CTDeployer` implements `IJBRulesetDataHook`, which includes both `beforePayRecordedWith()` and `beforeCashOutRecordedWith()`. The deployment configures `useDataHookForPay = true` so that payment processing goes through CTDeployer (which delegates to the 721 hook). However, `useDataHookForCashOut` is never set to `true`, so the terminal processes cash outs using the raw ruleset parameters without consulting the data hook.

This means:
- `cashOutTaxRate = MAX_CASH_OUT_TAX_RATE` is applied to ALL cash outs, including from suckers
- The sucker bypass in `beforeCashOutRecordedWith()` (returning `cashOutTaxRate = 0`) is never executed
- The NatSpec explicitly states the function's purpose: "Allow cash outs from suckers without a tax"

**Verification evidence:**

1. Searched entire codebase for `useDataHookForCashOut` — zero occurrences.
2. `JBRulesetMetadata` struct initializes booleans to `false` in Solidity.
3. `beforeCashOutRecordedWith()` is fully implemented with sucker check logic and NatSpec documentation.
4. The function is part of the `IJBRulesetDataHook` interface that CTDeployer explicitly implements.

**Trigger Sequence:**
1. Project deployed via `CTDeployer.deployProjectFor()` with `cashOutTaxRate = MAX` and `useDataHookForCashOut = false` (default)
2. Sucker contract attempts to cash out project tokens for cross-chain bridging
3. Terminal applies MAX cash out tax rate (sucker pays full tax)
4. `beforeCashOutRecordedWith()` is never called → sucker gets no tax exemption
5. Cross-chain bridging via sucker is economically penalized

**Impact:**
- Suckers cannot perform tax-free cash outs for projects deployed via CTDeployer
- Cross-chain token bridging through the sucker mechanism is penalized with maximum tax
- This effectively disables the intended frictionless cross-chain experience for CTDeployer-deployed projects
- Note: Impact depends on whether suckers actually use the terminal cash out mechanism for bridging. If suckers use a different mechanism (direct burn), this finding is lower severity.

**Suggested fix:**

Add the missing configuration in `deployProjectFor()`:

```solidity
rulesetConfigurations[0].metadata.cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE;
rulesetConfigurations[0].metadata.dataHook = address(this);
rulesetConfigurations[0].metadata.useDataHookForPay = true;
rulesetConfigurations[0].metadata.useDataHookForCashOut = true;  // ADD THIS LINE
```

---

### Finding NM-003: `tierIdForEncodedIPFSUriOf` Stale After External Tier Removal

**Severity:** LOW
**Source:** State Inconsistency Pass 2 (GAP-1)
**Verification:** Code Trace (Method A)

**Coupled Pair:** `tierIdForEncodedIPFSUriOf[hook][uri]` ↔ actual tier existence in `hook.STORE()`
**Invariant:** If `tierIdForEncodedIPFSUriOf` maps to a non-zero tier ID, that tier should exist in the hook's store.

**Breaking Operation:** External call to `hook.adjustTiers({tierIdsToRemove: [tierId]})` by the hook owner or authorized operator.

`src/CTPublisher.sol:65` — The mapping:
```solidity
mapping(address hook => mapping(bytes32 encodedIPFSUri => uint256)) public override tierIdForEncodedIPFSUriOf;
```

**Why this exists:**
`CTPublisher` writes to `tierIdForEncodedIPFSUriOf` when a new tier is created via `_setupPosts()` (L526). However, if the tier is later removed directly through the hook's `adjustTiers()` (not through CTPublisher), the mapping is not cleared. `CTPublisher` has no callback or mechanism to detect external tier removal.

**Consequence:**
A subsequent `mintFrom()` for the same `encodedIPFSUri` will find the stale tier ID, attempt to mint from a non-existent tier, and the transaction will revert at the hook level. No value is lost (ETH is returned on revert), but the mint fails unexpectedly. Additionally, the URI cannot be re-posted as a new tier because `tierIdForEncodedIPFSUriOf` returns a non-zero value, permanently blocking re-creation of that URI's tier on that hook.

**Impact:** Low — causes unexpected reverts and prevents re-posting of removed URIs, but no value loss. The scenario requires the hook owner to deliberately remove a tier created through Croptop.

---

### Finding NM-004: Pre-Existing ETH Balance Swept to Fee Project

**Severity:** LOW (Informational)
**Source:** Feynman Pass 1 (Category 4)
**Verification:** Code Trace (Method A)

`src/CTPublisher.sol:388-403`:
```solidity
if (address(this).balance != 0) {
    IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf({projectId: FEE_PROJECT_ID, token: JBConstants.NATIVE_TOKEN});
    feeTerminal.pay{value: address(this).balance}({...});
}
```

**Why this matters:**
`address(this).balance` may include ETH from sources other than the current `mintFrom()` call — for example, ETH force-sent via `selfdestruct` or coinbase rewards. This pre-existing ETH would be swept to the fee project on the next `mintFrom()` call.

**Impact:** Negligible. The CTPublisher contract is not designed to hold ETH, so any pre-existing balance is unintentional. Sweeping it to the fee project is arguably the best default behavior. No user funds at risk.

---

### Finding NM-005: `dataHookOf` Immutable After Deployment — No Update Mechanism

**Severity:** LOW (Design Limitation)
**Source:** State Inconsistency analysis
**Verification:** Code Trace (Method A)

`src/CTDeployer.sol:73`:
```solidity
mapping(uint256 projectId => IJBRulesetDataHook) public dataHookOf;
```

Set once at `src/CTDeployer.sol:292`:
```solidity
dataHookOf[projectId] = IJBRulesetDataHook(hook);
```

**Why this matters:**
`dataHookOf` is set during `deployProjectFor()` and has no update function. If a project owner needs to change the underlying data hook (e.g., to upgrade the 721 hook), they cannot update `dataHookOf` through CTDeployer. The workaround is to change the ruleset's `dataHook` to point directly to the new hook instead of CTDeployer, but this also removes the sucker bypass logic in `beforeCashOutRecordedWith()`.

**Impact:** Low — this is a design limitation with a known workaround. Projects that need to upgrade their hook must also change their ruleset configuration.

---

## Feedback Loop Discoveries

**NM-001 emerged from cross-feed:**
- Feynman Pass 1 identified the assumption that `post.price` matches actual tier price (Category 4)
- State Pass 2 confirmed no validation exists for existing tiers by analyzing the mutation matrix
- Feynman Pass 3 re-interrogated the fee calculation path and confirmed the accounting invariant is broken
- Neither auditor alone would have classified this as HIGH without the other's perspective:
  - Feynman alone would flag "unvalidated input" but might not trace the fee impact
  - State alone would not flag this because no coupled STATE variables are desynchronized — the bug is in the fee LOGIC

## False Positives Eliminated

1. **Hook re-entrancy via adjustTiers()** — Initial suspect from Feynman Q7.3. Code trace confirmed that `tierIdForEncodedIPFSUriOf` is set before the external call (CEI pattern), preventing duplicate tier creation on re-entry. FALSE POSITIVE.

2. **Malicious hook returning FEE_PROJECT_ID** — Initial suspect from Feynman Q4.1. Code trace confirmed that if a hook returns FEE_PROJECT_ID, the payment goes to the fee project anyway (more, not less). No exploit. FALSE POSITIVE.

3. **startingTierId race condition** — Initial suspect from Feynman Q7.5. Confirmed that all operations are within a single transaction, and `adjustTiers` assigns sequential IDs matching the prediction. FALSE POSITIVE.

4. **uint56 truncation in CTProjectOwner** — Initial suspect from Feynman Q5.1. Juicebox project IDs are sequential and will never reach 2^56 (~72 quadrillion). FALSE POSITIVE.

5. **Packed allowance bit overlap** — Initial suspect from State analysis. Bit layout verified: uint104 (0-103) + uint32 (104-135) + uint32 (136-167) + uint32 (168-199) = 200 bits, no overlap. FALSE POSITIVE.

## Summary
- Total functions analyzed: 19
- Coupled state pairs mapped: 4
- Nemesis loop iterations: 4 (converged after Pass 4)
- Raw findings (pre-verification): 1 HIGH | 1 MEDIUM | 3 LOW
- After verification: 5 TRUE POSITIVE | 5 FALSE POSITIVE | 0 DOWNGRADED
- **Final: 1 HIGH | 1 MEDIUM | 3 LOW**
- Feedback loop discoveries: 1 (NM-001 — found via Feynman→State cross-feed)
