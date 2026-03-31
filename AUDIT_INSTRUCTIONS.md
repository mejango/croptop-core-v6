# croptop-core-v6 -- Audit Instructions

Audit preparation document for experienced Solidity auditors. This repo contains the Croptop content publishing system: three contracts that allow permissioned posting of NFT content as 721 tiers to Juicebox V6 projects, with fee accounting, an allowlist system, and a data hook proxy for cross-chain cash-out interception.

Compiler: `solc 0.8.28`. Framework: Foundry.

---

## 1. Architecture Overview

Croptop is a thin orchestration layer on top of Juicebox V6 core and the 721 tiers hook system. It adds content-posting semantics (price floors, supply bounds, poster allowlists, split caps) and a 5% fee on every mint.

### Contract Table

| Contract | File | Lines | Role |
|----------|------|-------|------|
| **CTPublisher** | `src/CTPublisher.sol` | ~590 | Core publishing engine. Validates posts against bit-packed allowances, creates 721 tiers, mints first copies, routes fees. Inherits `JBPermissioned`, `ERC2771Context`. |
| **CTDeployer** | `src/CTDeployer.sol` | ~433 | Factory that deploys a JB project + 721 hook + posting criteria in one transaction. Acts as `IJBRulesetDataHook` proxy: forwards pay/cash-out calls to the underlying hook while granting fee-free cash outs to suckers. Inherits `JBPermissioned`, `ERC2771Context`, `IERC721Receiver`. |
| **CTProjectOwner** | `src/CTProjectOwner.sol` | ~82 | Receives project ownership NFT via `safeTransferFrom` and permanently grants `CTPublisher` the `ADJUST_721_TIERS` permission. Implements `IERC721Receiver`. |

### Struct Table

| Struct | File | Key Fields |
|--------|------|------------|
| `CTAllowedPost` | `src/structs/CTAllowedPost.sol` | `hook` (address), `category` (uint24), `minimumPrice` (uint104), `minimumTotalSupply` (uint32), `maximumTotalSupply` (uint32), `maximumSplitPercent` (uint32), `allowedAddresses` (address[]) |
| `CTDeployerAllowedPost` | `src/structs/CTDeployerAllowedPost.sol` | Same as `CTAllowedPost` minus `hook` (inferred during deployment) |
| `CTPost` | `src/structs/CTPost.sol` | `encodedIPFSUri` (bytes32), `totalSupply` (uint32), `price` (uint104), `category` (uint24), `splitPercent` (uint32), `splits` (JBSplit[]) |
| `CTProjectConfig` | `src/structs/CTProjectConfig.sol` | `terminalConfigurations` (JBTerminalConfig[]), `projectUri` (string), `allowedPosts` (CTDeployerAllowedPost[]), `contractUri` (string), `name` (string), `symbol` (string), `salt` (bytes32) |
| `CTSuckerDeploymentConfig` | `src/structs/CTSuckerDeploymentConfig.sol` | `deployerConfigurations` (JBSuckerDeployerConfig[]), `salt` (bytes32) |

### Dependency Map

```
CTPublisher
  ├── JBPermissioned (access control)
  ├── ERC2771Context (meta-transactions)
  ├── IJBDirectory (terminal lookup)
  ├── IJBTerminal (payments)
  ├── IJB721TiersHook (tier adjustment, mint)
  ├── IJB721TiersHookStore (tier reads)
  ├── JBMetadataResolver (metadata encoding)
  └── JBOwnable (hook owner reads)

CTDeployer
  ├── JBPermissioned (access control)
  ├── ERC2771Context (meta-transactions)
  ├── IJBRulesetDataHook (pay/cashout interception)
  ├── IERC721Receiver (project NFT receipt)
  ├── IJBProjects (project NFT operations)
  ├── IJB721TiersHookDeployer (hook deployment)
  ├── IJBController (project launch)
  ├── IJBSuckerRegistry (sucker verification, deployment)
  ├── JBOwnable (hook ownership transfer)
  └── ICTPublisher (posting criteria delegation)

CTProjectOwner
  ├── IERC721Receiver (project NFT receipt)
  ├── IJBPermissions (permission grants)
  └── IJBProjects (sender validation)
```

---

## Value Extraction Paths

Quick reference for where the money is:

| Path | Entry Point | Value at Risk | What to Verify |
|------|------------|---------------|----------------|
| Fee evasion | `CTPublisher.mintFrom()` | 5% fee on every mint | `totalPrice` computed from on-chain tier prices for existing tiers, not user-supplied `post.price` |
| Fee-free cashout | `CTDeployer.beforeCashOutRecordedWith()` | Full treasury value | Only legitimate suckers (via registry) get 0% tax |
| Unauthorized minting | `CTDeployer.hasMintPermissionFor()` | Arbitrary token minting | Only registered suckers get mint permission |
| Tier spam | `CTPublisher._setupPosts()` | Gas griefing, hook degradation | Allowlist + price/supply floors gate tier creation |
| Fee routing failure | `CTPublisher.mintFrom()` pre-computed fee | Fee project loses 5% | Pre-computed fee (`msg.value - payValue`) sent via try-catch to fee terminal, with fallback to `feeBeneficiary` then `msg.sender` |

---

## 2. Content Posting Flow

The core flow is `CTPublisher.mintFrom()`. This is the primary entry point for all content publishing.

### Step-by-step execution (CTPublisher.sol lines 310-430)

```
Poster calls mintFrom(hook, posts[], nftBeneficiary, feeBeneficiary, additionalPayMetadata, feeMetadata)
  with msg.value = sum(post prices) + 5% fee

1. Read projectId from hook.PROJECT_ID()                              [line 329]
2. _setupPosts(hook, posts) returns:                                  [line 333-334]
   (tiersToAdd[], tierIdsToMint[], totalPrice)

   For each post in the batch:
     a. Revert if encodedIPFSUri == bytes32("")                       [line 473-474]
     b. O(i) duplicate check against all prior posts in batch         [line 478-482]
     c. Look up tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]       [line 487]
        - If tier exists and NOT removed: reuse tier ID,              [line 496]
          accumulate store.tierOf().price (on-chain price)            [line 501]
        - If tier exists but removed: delete stale mapping,           [line 494]
          fall through to new tier creation
        - If no tier exists: validate against allowance:              [line 510-549]
          * Category must be configured (minimumTotalSupply > 0)
          * price >= minimumPrice
          * totalSupply >= minimumTotalSupply
          * totalSupply <= maximumTotalSupply
          * splitPercent <= maximumSplitPercent
          * caller in allowedAddresses (if non-empty)
          Then build JB721TierConfig and accumulate post.price        [line 553-579]
     d. Store tierIdForEncodedIPFSUriOf mapping for new tiers         [line 576]

   Assembly-resize tiersToAdd if some posts reused existing tiers     [line 584-588]

3. If projectId != FEE_PROJECT_ID:                                    [line 336]
     payValue = msg.value - (totalPrice / FEE_DIVISOR)                [line 341/348]
   Else: payValue = msg.value (no fee for fee project)

4. Revert if totalPrice > payValue                                    [line 352-354]

5. hook.adjustTiers(tiersToAdd, [])                                   [line 358]

6. Build mint metadata:                                               [line 366-370]
   - JBMetadataResolver.addToMetadata with tier IDs
   - Assembly: write FEE_PROJECT_ID into first 32 bytes (referral)

7. Emit Mint event                                                    [line 380-389]

8. Look up project's primary ETH terminal via DIRECTORY               [line 393-394]
   terminal.pay{value: payValue}(...)                                 [line 398-406]

9. payValue = msg.value - payValue (pre-computed fee)                  [line 411]
   If payValue != 0:                                                   [line 414]
   Look up fee project's primary ETH terminal                        [line 416-417]
   try feeTerminal.pay{value: payValue}(...) {}                      [line 421-429]
   catch { feeBeneficiary.call{value}; fallback msg.sender.call }    [line 430-437]
```

### Fee Calculation

- `FEE_DIVISOR = 20` (5% fee)
- Fee = `totalPrice / 20` (integer division, truncates)
- Maximum rounding loss: 19 wei per transaction
- Fee is deducted from `msg.value` before the project payment
- Pre-computed fee (`msg.value - payValue`) goes to fee terminal via try-catch, with fallback to `feeBeneficiary` then `msg.sender`
- Fee is skipped entirely when `projectId == FEE_PROJECT_ID`

---

## 3. Tier Creation Mechanics

### New Tier Path

When a post's `encodedIPFSUri` has no existing mapping (or the mapped tier was removed), a new tier is created:

1. Posting criteria are read from bit-packed `_packedAllowanceFor[hook][category]` (CTPublisher.sol lines 177-190)
2. Each field is validated against the post's parameters
3. A `JB721TierConfig` is constructed with the post's values (lines 553-570)
4. The tier ID is computed as `startingTierId + numberOfTiersBeingAdded++` (line 573)
5. The mapping `tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]` is set (line 576)
6. All new tiers are committed to the hook via `hook.adjustTiers()` after the loop (line 358)

### Existing Tier Path

When a post's `encodedIPFSUri` already has a mapping to a live (non-removed) tier:

1. The tier ID is reused (line 496)
2. The fee is calculated from `store.tierOf().price` -- the on-chain price, not `post.price` (line 501)
3. No new `JB721TierConfig` is added to `tiersToAdd`
4. The poster still gets a mint of the existing tier

### Stale Tier Cleanup

If a tier was removed externally via `adjustTiers()`, the publisher detects this via `hook.STORE().isTierRemoved()` (line 493) and deletes the stale mapping (line 494), allowing the URI to be posted as a new tier.

---

## 4. Bit-Packed Allowance Storage

Posting criteria are packed into a single `uint256` per hook/category:

```
Bits   0-103  (104 bits): minimumPrice      (uint104)
Bits 104-135  ( 32 bits): minimumTotalSupply (uint32)
Bits 136-167  ( 32 bits): maximumTotalSupply (uint32)
Bits 168-199  ( 32 bits): maximumSplitPercent(uint32)
Bits 200-255  ( 56 bits): unused
```

Packing logic: CTPublisher.sol lines 274-282
Unpacking logic: CTPublisher.sol lines 177-190

The address allowlist is stored separately in `_allowedAddresses[hook][category]` (a dynamic array).

---

## 5. Allowlist System

### Configuration

`configurePostingCriteriaFor()` (line 243) accepts an array of `CTAllowedPost` structs. For each:

1. Emits `ConfigurePostingCriteria` event (line 252)
2. Checks `ADJUST_721_TIERS` permission from `JBOwnable(hook).owner()` (lines 256-260)
3. Validates `minimumTotalSupply > 0` (line 263)
4. Validates `minimumTotalSupply <= maximumTotalSupply` (line 268)
5. Packs numeric fields into `_packedAllowanceFor` (lines 274-284)
6. Replaces the entire `_allowedAddresses` array (delete + push loop, lines 289-296)

### Enforcement

In `_setupPosts()` at line 547:

```solidity
if (addresses.length != 0 && !_isAllowed({addrs: _msgSender(), addresses: addresses})) {
    revert CTPublisher_NotInAllowList(_msgSender(), addresses);
}
```

`_isAllowed()` (lines 210-220) is a linear scan: O(n) where n = allowlist size.

### Key Behavior

- Empty `allowedAddresses` means anyone can post (permissionless)
- Reconfiguring a category fully replaces the previous criteria and allowlist
- Categories with `minimumTotalSupply == 0` are treated as unconfigured (posting reverts)
- There is no mechanism to fully disable a configured category (NM-006, documented as won't-fix)

---

## 6. Data Hook Proxy (CTDeployer)

### Architecture

CTDeployer registers itself as the `dataHook` for every project it deploys (CTDeployer.sol line 289). It implements `IJBRulesetDataHook` and proxies calls:

- **`beforePayRecordedWith(context)`** (line 160): Forwards directly to `dataHookOf[context.projectId]` (the JB721TiersHook).
- **`beforeCashOutRecordedWith(context)`** (line 132): Checks `SUCKER_REGISTRY.isSuckerOf()` first. If the holder is a sucker, returns `cashOutTaxRate = 0` (fee-free). Otherwise forwards to the data hook.
- **`hasMintPermissionFor(projectId, ruleset, addr)`** (line 176): Returns `true` if `addr` is a registered sucker.

### Failure Scenarios

**Critical: Data hook forwarding has no try-catch.** If `dataHookOf[projectId]` reverts for any reason:

- All `pay()` calls to the project will revert (line 168)
- All `cashOut()` calls (for non-sucker holders) will revert (line 150)
- Since `dataHookOf` is write-once (set at line 306, no setter), the project is permanently bricked

**Scenarios that could trigger this:**

1. The 721 hook has a bug in `beforePayRecordedWith()` or `beforeCashOutRecordedWith()`
2. The hook's dependencies (store, prices, rulesets) revert due to bad state
3. An upgrade to a dependency contract breaks ABI compatibility

**Mitigations:**

- The hook is deployed via Create2 with deterministic bytecode (no proxy, no upgrade)
- The hook's logic is well-tested in the `nana-721-hook-v6` repo
- Sucker cash-outs bypass the hook entirely (they return before the forwarding call)

---

## 7. Sucker Impersonation Risks

### Trust Chain

```
CTDeployer.beforeCashOutRecordedWith()
  └── SUCKER_REGISTRY.isSuckerOf(projectId, context.holder)
        └── Registry tracks suckers deployed by allowed deployers
              └── allowSuckerDeployer() restricted to registry owner (multisig)
```

### Attack Surface

If an attacker can make `SUCKER_REGISTRY.isSuckerOf()` return `true` for their address:

1. They call `cashOut()` on any Croptop project
2. CTDeployer intercepts the cash-out, sees the attacker as a "sucker"
3. Returns `cashOutTaxRate = 0` instead of forwarding to the hook
4. The attacker receives full treasury value without paying the project's cash-out tax

### Risk Factors

- `MAP_SUCKER_TOKEN` permission is granted as wildcard (`projectId: 0`) at CTDeployer construction (line 105)
- The sucker registry is a shared singleton controlled by the protocol multisig
- Once a sucker deployer is allowed, it can deploy suckers for any project
- Compromising the multisig or a sucker deployer would affect all Croptop projects

### What to Verify

- That `isSuckerOf()` cannot be manipulated without multisig action
- That the wildcard `MAP_SUCKER_TOKEN` permission cannot be abused to register arbitrary addresses
- That the `hasMintPermissionFor()` function (which also trusts the sucker registry) cannot be exploited to mint tokens without payment

---

## 8. Allowlist Gas Scaling

### Current Implementation

`_isAllowed()` at CTPublisher.sol lines 210-220:

```solidity
function _isAllowed(address addrs, address[] memory addresses) internal pure returns (bool) {
    uint256 numberOfAddresses = addresses.length;
    for (uint256 i; i < numberOfAddresses; i++) {
        if (addrs == addresses[i]) return true;
    }
    return false;
}
```

### Gas Analysis

- Each comparison: ~3 gas (MLOAD + EQ)
- Per-address overhead: ~100 gas (loop counter, bounds check, memory access)
- 100 addresses: ~10,000 gas additional
- 1,000 addresses: ~100,000 gas additional
- 10,000 addresses: ~1,000,000 gas additional
- Block gas limit (~30M mainnet): effective cap of ~300,000 addresses before tx becomes infeasible

### Storage Scaling

The `_allowedAddresses` array is also written during `configurePostingCriteriaFor()` via a push loop (lines 293-295). For large allowlists, the configuration transaction gas cost could also become prohibitive.

### Recommendation for Auditors

Check that no realistic usage pattern could cause a revert due to gas limits. The recommended practical cap is 100 addresses per category. A Merkle proof pattern would scale to millions of addresses but was not implemented (complexity vs. expected usage tradeoff).

---

## 9. Priority Audit Areas

### P0 -- Critical (fund loss or permanent DoS)

1. **Fee accounting correctness in `_setupPosts()`** (CTPublisher.sol lines 442-589). Verify:
   - `totalPrice` is always computed from on-chain tier prices for existing tiers (not user-supplied `post.price`)
   - `totalPrice` is always computed from `post.price` for new tiers
   - No path exists where `totalPrice` can be manipulated to be less than the actual value of tiers being minted
   - The duplicate URI check (lines 478-482) covers all batch orderings

2. **Fee deduction and routing** (CTPublisher.sol lines 336-428). Verify:
   - `payValue = msg.value - (totalPrice / FEE_DIVISOR)` cannot underflow
   - The check `totalPrice > payValue` correctly prevents underpayment
   - The pre-computed fee (`msg.value - payValue`) equals exactly the intended fee amount, independent of `address(this).balance`
   - The fee terminal payment is wrapped in try-catch with fallback to `feeBeneficiary` then `msg.sender` — verify the fallback chain cannot lose ETH

3. **Data hook proxy forwarding** (CTDeployer.sol lines 132-169). Verify:
   - `dataHookOf[projectId]` is always set before any pay/cashout can occur for that project
   - No path exists where `dataHookOf[projectId]` is `address(0)` and a forwarding call is made
   - The sucker check correctly short-circuits before the forwarding call

### P1 -- High (access control bypass, permission escalation)

4. **Sucker fee-free cash-out** (CTDeployer.sol lines 143-146). Verify:
   - Only legitimate suckers can trigger the zero-tax path
   - The `hasMintPermissionFor()` function cannot be abused for unauthorized minting

5. **Permission enforcement in `configurePostingCriteriaFor()`** (CTPublisher.sol lines 256-260). Verify:
   - The permission check uses `JBOwnable(hook).owner()` and `IJB721TiersHook(hook).PROJECT_ID()` correctly
   - No one besides the hook owner (or permissioned delegate) can modify posting criteria

6. **CTProjectOwner permission grant** (CTProjectOwner.sol lines 47-80). Verify:
   - The permission granted is scoped to the correct project ID
   - The `uint64(tokenId)` cast does not truncate for realistic project IDs
   - Any address can transfer a project NFT to CTProjectOwner (no `from == address(0)` check), effectively burning ownership permanently

### P2 -- Medium (economic manipulation, griefing)

7. **Tier spam / unbounded tier creation** (R-1 in RISKS.md). When allowlist is empty, anyone meeting price/supply floors can create unlimited tiers. Assess impact on hook gas costs.

8. **Bit-packing correctness** in `_packedAllowanceFor` storage (CTPublisher.sol lines 274-282 write, lines 177-190 read). Verify no field overlap or silent truncation.

9. **Assembly metadata injection** (CTPublisher.sol lines 375-377). Verify the `mstore` correctly places `FEE_PROJECT_ID` in the referral position without corrupting the JBMetadataResolver lookup table.

10. **Project deployment front-running** (CTDeployer.sol lines 261, 294-303). Verify the `assert(projectId == ...)` check correctly prevents ID mismatch without permanent fund loss.

### P3 -- Low (informational, code quality)

11. **`uint64` project ID cast** in CTProjectOwner (line 77) and CTDeployer (line 344). Both now use `uint64`. Confirm no truncation risk for realistic project IDs.

12. **Force-sent ETH stranding** (CTPublisher.sol lines 409-438). Fee is now pre-computed from `msg.value`, not `address(this).balance`. Force-sent ETH remains stranded. Confirm this is acceptable and the try-catch fallback chain cannot lose ETH from `msg.value`.

13. **Allowlist overwrite behavior** (CTPublisher.sol lines 289-296). Verify that `delete` followed by `push` loop correctly replaces the array with no residual state.

---

## 10. Invariants

These properties should hold across all operations. They are suitable targets for fuzz testing and formal verification.

### Fee Invariants

1. **Fee correctness:** For any `mintFrom()` where `projectId != FEE_PROJECT_ID`, the fee project receives at least `totalPrice / FEE_DIVISOR - 19 wei` and at most `totalPrice / FEE_DIVISOR` ETH.

2. **No fee for fee project:** When `projectId == FEE_PROJECT_ID`, the full `msg.value` is sent to the project terminal (zero deducted for fees).

3. **ETH conservation:** For every `mintFrom()` call, `msg.value == payValue + feeAmount + dust`, where `dust <= 19 wei`. The fee amount is pre-computed as `msg.value - payValue` and routed via try-catch to the fee terminal, then `feeBeneficiary`, then `msg.sender`. No ETH from `msg.value` is lost. Force-sent ETH (via `selfdestruct`) is not routed and remains stranded in the contract.

### Posting Invariants

4. **Allowance enforcement:** A `mintFrom()` call succeeds for a new tier only if every post satisfies: `price >= minimumPrice`, `totalSupply >= minimumTotalSupply`, `totalSupply <= maximumTotalSupply`, `splitPercent <= maximumSplitPercent`, and (if allowlist non-empty) `_msgSender()` is in `allowedAddresses`.

5. **Duplicate rejection:** Within a single `mintFrom()` batch, no two posts can have the same `encodedIPFSUri`.

6. **Existing tier price integrity:** For existing tiers, `totalPrice` accumulates `store.tierOf().price` (the on-chain price), never `post.price`.

7. **Tier uniqueness:** After `_setupPosts()` completes, every `encodedIPFSUri` in the batch maps to a unique tier ID via `tierIdForEncodedIPFSUriOf`.

### Ownership Invariants

8. **Transient deployer ownership:** CTDeployer owns a project NFT only during `deployProjectFor()` execution. By function return, ownership has been transferred to the specified `owner`.

9. **Data hook immutability:** `dataHookOf[projectId]` is set exactly once (during `deployProjectFor`) and never modified afterward. There is no setter function.

10. **Permission scoping:** CTProjectOwner grants `ADJUST_721_TIERS` permission scoped to the specific `tokenId` (project ID) received, not globally.

---

## 11. Testing Setup

### Running Tests

```bash
cd croptop-core-v6
forge install
forge test
```

For fork tests (requires RPC URL):
```bash
ETHEREUM_RPC_URL=<your-rpc> forge test --match-contract ForkTest --fork-url $ETHEREUM_RPC_URL
```

### Test File Overview

| Test File | Focus | Tests |
|-----------|-------|-------|
| `test/CTPublisher.t.sol` | Allowance round-trip, bit packing fuzz, permission checks, split validation | 26 tests including fuzz |
| `test/CTDeployer.t.sol` | Deploy flow, data hook proxy, sucker permissions, onERC721Received, supportsInterface | 21 tests |
| `test/CTProjectOwner.t.sol` | Permission grants on NFT receipt, rejection of non-project NFTs, rejection of transfers | 7 tests |
| `test/ClaimCollectionOwnership.t.sol` | NM-002 scenario: ownership transfer, permission breakage, recovery path | 6 tests |
| `test/TestAuditGaps.sol` | Data hook proxy forwarding failure, sucker impersonation, allowlist gas scaling, force-sent ETH | 19 tests |
| `test/CroptopAttacks.t.sol` | Adversarial input validation, allowlist bypass, split percent enforcement | 12 tests |
| `test/Fork.t.sol` | Full deployment integration with real JB infrastructure | 2 fork tests |
| `test/fork/PublishFork.t.sol` | End-to-end mint flow, fee distribution, duplicate post reuse on mainnet fork | 4 fork tests |
| `test/Test_MetadataGeneration.t.sol` | Metadata assembly correctness | 1 test |
| `test/regression/DuplicateUriFeeEvasion.t.sol` | NM-001 fix: duplicate URI detection | 5 tests including fuzz |
| `test/regression/FeeEvasion.t.sol` | H-19 fix: existing tier price used for fees | 2 tests |
| `test/regression/StaleTierIdMapping.t.sol` | L-52 fix: stale mapping cleanup | 2 tests |

### Coverage Gaps (no existing tests)

- Force-sent ETH handling via selfdestruct (fee is now pre-computed from `msg.value`, not `address(this).balance`, so force-sent ETH remains stranded)
- `deployProjectFor` front-running race condition
- Multiple hooks sharing the same CTPublisher instance
- Cross-category posting in a single batch (different categories, different allowlists)
- `configurePostingCriteriaFor()` called with a very large allowlist (storage gas)
- Edge case: `totalPrice == 0` when all posts reuse existing free (price=0) tiers

### Testing Approach Used

Tests use Foundry's `vm.mockCall()` to isolate CTPublisher from its dependencies (hook, store, permissions, directory, terminal). The fork test (`Fork.t.sol`) deploys all JB infrastructure fresh within a mainnet fork for integration testing. Regression tests target specific audit findings with dedicated attack reproductions.

---

## 12. Previous Audit Findings

Six Nemesis findings plus two regression-test findings. See `.audit/findings/nemesis-verified.md` for full Nemesis details and `RISKS.md` for context.

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| NM-001 | MEDIUM | FALSE POSITIVE | `dataHookOf` write-once = permanent project bricking -- project owner can queue new ruleset to escape (`useDataHookForPay = false`) |
| NM-002 | MEDIUM | OPEN | `claimCollectionOwnershipOf` breaks all `CTPublisher.mintFrom` calls -- hook ownership transfer does not update CTPublisher permissions |
| NM-003 | LOW | OPEN | Permission grants to initial owner stale after project NFT transfer -- old owner retains 4 permissions |
| NM-004 | LOW | OPEN | Stale `tierIdForEncodedIPFSUriOf` in `tiersFor()` view -- removed tiers still returned to off-chain consumers |
| NM-005 | LOW | FIXED | Fee underflow gives generic panic (`0x11`) instead of custom `CTPublisher_InsufficientEthSent` error -- the `if (payValue < fee)` check now guards the subtraction |
| NM-006 | LOW | OPEN | Cannot fully disable posting for a configured category |
| H-19 | HIGH | FIXED | Fee evasion on existing tier mints via `post.price = 0` *(regression test naming, not from Nemesis audit)* |
| L-52 | LOW | FIXED | Stale tier ID mapping after external tier removal *(regression test naming, not from Nemesis audit)* |

---

## Compiler and Version Info

- **Solidity**: 0.8.28
- **EVM target**: Cancun
- **Optimizer**: 200 runs
- **Dependencies**: OpenZeppelin 5.x, nana-core-v6, nana-721-hook-v6, nana-suckers-v6
- **Build**: `forge build` (Foundry)

---

## How to Report Findings

For each finding:

1. **Title** -- one line, starts with severity (CRITICAL/HIGH/MEDIUM/LOW)
2. **Affected contract(s)** -- exact file path and line numbers
3. **Description** -- what is wrong, in plain language
4. **Trigger sequence** -- step-by-step
5. **Impact** -- what an attacker gains, what the project/fee project loses
6. **Proof** -- code trace or Foundry test
7. **Fix** -- minimal code change

**Severity guide:**
- **CRITICAL**: Fee evasion at scale, unauthorized treasury drain, permanent project DoS.
- **HIGH**: Conditional fee bypass, sucker impersonation, broken posting criteria.
- **MEDIUM**: Tier spam, gas griefing, rounding errors in fee calculation.
- **LOW**: Informational, cosmetic, testnet-only.
