# croptop-core-v6 -- Risks

Deep implementation-level risk analysis. References are to source files under `src/` and test files under `test/`.

## Trust Assumptions

### 1. CTDeployer as Data Hook (CRITICAL trust surface)

CTDeployer acts as `IJBRulesetDataHook` for every project it deploys (`CTDeployer.sol` line 290: `rulesetConfigurations[0].metadata.dataHook = address(this)`). This means:

- All pay and cashout calls for every CTDeployer-launched project are routed through CTDeployer's `beforePayRecordedWith()` (line 162) and `beforeCashOutRecordedWith()` (line 134).
- CTDeployer forwards these to `dataHookOf[projectId]` (line 152, 170), which is the JB721TiersHook.
- If CTDeployer has a bug, all Croptop projects are affected simultaneously.
- `dataHookOf` is write-once (no setter function), so a bug cannot be patched per-project.

### 2. Sucker Registry (MEDIUM trust surface)

`CTDeployer.beforeCashOutRecordedWith()` at line 146 trusts `SUCKER_REGISTRY.isSuckerOf()` to determine whether a cashout should be tax-free. If the sucker registry is compromised or returns `true` for an attacker's address, that address can cash out with zero tax from any Croptop project.

### 3. JBPermissions (HIGH trust surface)

Both CTDeployer and CTPublisher inherit `JBPermissioned` and rely on `_requirePermissionFrom()` for access control. The JBPermissions contract is a shared singleton. If compromised, all permission-gated functions across all projects lose access control.

### 4. JB721TiersHookStore (MEDIUM trust surface)

CTPublisher reads tier data from the hook's store at `_setupPosts()` line 477 (`store.tierOf(address(hook), tierId, false).price`) and line 469 (`hook.STORE().isTierRemoved()`). If the store returns incorrect data, fee calculations and tier reuse logic break.

### 5. Publisher-Set Splits (MEDIUM trust surface)

Publishers set their own `splitPercent` and `splits` array in `CTPost` (line 544, `CTPublisher.sol`). While `splitPercent` is bounded by `maximumSplitPercent` (line 518-519), the actual `splits` array contents are not validated against the percent. The JB721TiersHook and JBSplits contracts downstream are responsible for enforcing that splits sum correctly.

### 6. ERC2771 Trusted Forwarder (LOW trust surface)

Both CTDeployer and CTPublisher use `ERC2771Context` with a trusted forwarder set at construction. If the trusted forwarder is compromised, any `_msgSender()` check can be spoofed, bypassing all permission checks. Mitigated by setting `trustedForwarder = address(0)` in deployments that don't need meta-transactions.

## Audited Findings (Nemesis Audit)

### Fixed: NM-001 -- Duplicate URI Fee Evasion (MEDIUM, FIXED)

**Location:** `CTPublisher._setupPosts()` lines 454-469
**Test:** `test/regression/M6_DuplicateUriFeeEvasion.t.sol`

**Root cause:** Two posts with the same `encodedIPFSUri` in a single `mintFrom()` batch caused a desync between `tierIdForEncodedIPFSUriOf` (written at line 552 during iteration) and the hook store (updated only after `adjustTiers()` is called at line 338). The second post found a non-zero tier ID, but `store.tierOf()` returned `price=0` because the tier hadn't been committed yet.

**Attack scenario:**
1. Attacker calls `mintFrom()` with two identical `encodedIPFSUri` posts, each priced at 1 ETH.
2. First post: `totalPrice += 1 ether`. Mapping written.
3. Second post: Finds mapping, reads `store.tierOf().price = 0`. `totalPrice` stays at 1 ETH.
4. Fee calculated on 1 ETH instead of 2 ETH. Attacker evades 50% of fees.

**Fix applied:** Explicit duplicate detection loop at lines 454-458. Reverts with `CTPublisher_DuplicatePost(encodedIPFSUri)` if any two posts in the batch share an `encodedIPFSUri`.

**Test coverage:** 5 tests covering adjacent duplicates, non-adjacent duplicates, distinct URIs, single posts, and fuzz over arbitrary URI pairs.

### Fixed: H-19 -- Fee Evasion on Existing Tier Mints (HIGH, FIXED)

**Location:** `CTPublisher._setupPosts()` line 477
**Test:** `test/regression/H19_FeeEvasion.t.sol`

**Root cause:** When a post reused an existing tier (same `encodedIPFSUri`), the fee was calculated from `post.price` (attacker-controlled) instead of the actual tier price stored on-chain. An attacker could set `post.price = 0` for existing tiers to evade the 5% fee entirely.

**Fix applied:** For existing tiers, `totalPrice` accumulates `store.tierOf(address(hook), tierId, false).price` (line 477) -- the on-chain price -- not `post.price`.

**Test coverage:** 2 tests: one proving the attacker can't send 0 ETH for existing tiers, one proving the exact fee boundary (1.05 ETH required for a 1 ETH tier).

### Fixed: L-52 -- Stale Tier ID Mapping After External Removal (LOW, FIXED)

**Location:** `CTPublisher._setupPosts()` lines 466-470
**Test:** `test/regression/L52_StaleTierIdMapping.t.sol`

**Root cause:** If a tier was removed externally via `adjustTiers()`, the `tierIdForEncodedIPFSUriOf` mapping still pointed to the removed tier ID. Subsequent posts with the same URI would try to mint from a removed tier.

**Fix applied:** Before reusing a tier, `isTierRemoved()` is checked (line 469). If true, the stale mapping is deleted (line 470), and the post falls through to create a new tier.

**Test coverage:** 2 tests: mapping cleared on removal, mapping preserved when tier still exists.

### Open: NM-005 -- uint56 vs uint64 Project ID Cast (LOW, NOT FIXED)

**Location:** `CTProjectOwner.sol` line 72 vs `CTDeployer.sol` line 337

CTProjectOwner casts `tokenId` to `uint56`, while CTDeployer casts `projectId` to `uint64` in `JBPermissionsData`. No practical impact since project IDs are sequential and won't exceed 2^56, but the inconsistency should be harmonized.

### Open: NM-006 -- Cannot Fully Disable Posting for a Category (LOW, NOT FIXED)

**Location:** `CTPublisher.configurePostingCriteriaFor()` line 250-252

`minimumTotalSupply` must be > 0, so once a category is enabled, there is no clean way to disable it. Workaround: set `minimumPrice` to `type(uint104).max` and `minimumTotalSupply = maximumTotalSupply = 1`.

## Active Risk Analysis

### R-1: Tier Spam via Permissionless Posting

**Severity:** MEDIUM
**Location:** `CTPublisher.mintFrom()` line 297, `_setupPosts()` line 419
**Tested:** Partially (CroptopAttacks.t.sol tests input validation, not volume)

**Description:** When `allowedAddresses` is empty (line 523 condition not met), anyone can call `mintFrom()` and create new tiers as long as they meet price/supply criteria. Each `mintFrom()` call can include multiple posts, each creating a new tier. There is no per-address rate limit or maximum tier count.

**Impact:** An attacker can create thousands of tiers on a project's hook, increasing gas costs for all tier-related operations (enumeration, minting, removal). The JB721TiersHookStore uses a linked list for tiers, making enumeration O(n).

**Mitigation:** Project owners should use allowlists for categories. The `minimumPrice` floor provides an economic barrier. Each new tier costs the poster the tier price + 5% fee.

### R-2: Fee Rounding Loss (Dust)

**Severity:** INFORMATIONAL
**Location:** `CTPublisher.mintFrom()` line 328
**Tested:** No dedicated test

**Description:** Fee calculation `totalPrice / FEE_DIVISOR` uses integer division, which truncates. For `totalPrice = 39 wei`, the fee is `1 wei` instead of `1.95 wei`. This consistently rounds in the payer's favor (fee project receives slightly less).

**Quantification:** Maximum dust loss per transaction is `FEE_DIVISOR - 1 = 19 wei`. For practical ETH amounts (>= 0.001 ETH), this is < 0.000002% underpayment.

### R-3: Allowlist Linear Scan Gas Scaling

**Severity:** LOW
**Location:** `CTPublisher._isAllowed()` lines 200-210
**Tested:** No gas benchmarks in test suite

**Description:** Allowlist checking is O(n) linear scan. For an allowlist of 1000 addresses, each `mintFrom()` call pays ~3000 gas per address checked (1000 * 3 gas/comparison) = ~3M additional gas. The EVM block gas limit (~30M on mainnet) imposes an effective cap of ~10,000 addresses before a `mintFrom()` transaction becomes infeasible.

**Mitigation:** Document the recommendation of < 100 addresses per allowlist (comment at line 197). A Merkle proof pattern would scale better but adds complexity.

### R-4: Force-Sent ETH Routed to Fee Project

**Severity:** LOW (NM-004 from audit)
**Location:** `CTPublisher.mintFrom()` lines 389-404
**Tested:** No dedicated test

**Description:** If ETH is force-sent to CTPublisher via `selfdestruct` from another contract, it gets included in `address(this).balance` (line 397) and is sent to the fee project terminal on the next `mintFrom()` call. CTPublisher has no `receive()` or `fallback()`, so normal sends revert. Only `selfdestruct` (deprecated in future Ethereum hard forks) can force-send ETH.

**Impact:** The fee project receives a windfall. No funds are lost to attackers. The mint caller is not charged extra (fee is subtracted from `msg.value` before the main payment, and the residual balance goes to fees).

### R-5: Data Hook Proxy Forwarding Failure

**Severity:** MEDIUM
**Location:** `CTDeployer.beforeCashOutRecordedWith()` line 152, `beforePayRecordedWith()` line 170
**Tested:** No unit test for forwarding failure

**Description:** CTDeployer forwards data hook calls to `dataHookOf[projectId]`, which is set to the JB721TiersHook. If the hook reverts (e.g., due to a bug or an upgrade in dependent contracts), all pay and cashout operations for the project will revert. There is no try-catch wrapping these forwards.

**Impact:** A broken or upgraded hook can DoS all payments and cashouts for a project. Since `dataHookOf` has no setter, the project is permanently bricked in this scenario.

**Mitigation:** The hook is a deterministic deployment (Create2) with no upgrade mechanism, reducing the likelihood of unexpected behavior changes.

### R-6: CTProjectOwner Accepts Transfers (Not Just Mints)

**Severity:** LOW
**Location:** `CTProjectOwner.onERC721Received()` line 47-77
**Tested:** No negative test for transfer vs mint

**Description:** Unlike `CTDeployer.onERC721Received()` (which checks `from != address(0)` at line 201), `CTProjectOwner.onERC721Received()` only checks that `msg.sender == address(PROJECTS)` (line 62). It does NOT check `from == address(0)`. This means any holder can `safeTransferFrom` their project NFT to `CTProjectOwner`, effectively burning their project ownership. While this is the intended use case (burn-lock), there is no confirmation dialog or cooling period.

**Impact:** A project owner who accidentally transfers their project to CTProjectOwner loses ownership permanently with no recovery mechanism.

### R-7: Sucker Fee-Free Cashout Trust Chain

**Severity:** MEDIUM
**Location:** `CTDeployer.beforeCashOutRecordedWith()` line 146
**Tested:** No adversarial test for sucker impersonation

**Description:** The fee-free cashout path relies entirely on `SUCKER_REGISTRY.isSuckerOf({projectId, addr: context.holder})`. The trust chain is:

1. `SUCKER_REGISTRY` must correctly track deployed suckers.
2. `allowSuckerDeployer()` on the registry must only be callable by the registry owner.
3. Deployed suckers must not be compromisable.

If any link breaks, an attacker could register a malicious address as a "sucker" and cash out any Croptop project's treasury at 0% tax rate.

**Mitigation:** The sucker registry is operated by the protocol multisig. The `MAP_SUCKER_TOKEN` permission granted at CTDeployer construction (line 107) is wildcard (`projectId: 0`), which is necessary for cross-chain functionality but broadens the blast radius.

### R-8: No Input Validation on `splits` Array Contents

**Severity:** LOW
**Location:** `CTPublisher._setupPosts()` line 544-545
**Tested:** Split percent bounds are tested (`CTPublisher.t.sol`, `CroptopAttacks.t.sol`), but split array contents are not

**Description:** While `splitPercent` is validated against `maximumSplitPercent` (line 518-519), the actual `splits` array (line 545) is passed through to the JB721TierConfig without validation. CTPublisher does not verify:
- That split beneficiaries are non-zero addresses.
- That split percentages sum to `SPLITS_TOTAL_PERCENT`.
- That split hooks are valid contracts.

**Mitigation:** The JB721TiersHook and JBSplits contracts downstream validate split configurations. CTPublisher relies on these downstream checks.

### R-9: Project Deployment Front-Running

**Severity:** LOW
**Location:** `CTDeployer.deployProjectFor()` line 260
**Tested:** Fork test in `Fork.t.sol` but no front-running test

**Description:** `deployProjectFor()` calculates the expected project ID as `PROJECTS.count() + 1` (line 260) and asserts it matches the actual ID returned by `launchProjectFor()` (line 296). If another project is created between the `count()` read and the `launchProjectFor()` call (front-running), the assertion fails and the entire transaction reverts.

**Impact:** No fund loss. The deployment simply fails and must be retried. An attacker would pay gas to front-run with no economic benefit.

### R-10: Metadata Assembly Correctness

**Severity:** INFORMATIONAL
**Location:** `CTPublisher.mintFrom()` lines 355-357
**Tested:** `test/Test_MetadataGeneration.t.sol`

**Description:** `FEE_PROJECT_ID` is written into the first 32 bytes of `mintMetadata` via inline assembly `mstore`. This overwrites whatever was previously in that position (the metadata length prefix is at offset 0, the first data word is at offset 32). The test file confirms this produces valid metadata that can be parsed by `JBMetadataResolver.getDataFor()`.

**Verified as correct:** False positive FF-002 from the Nemesis audit confirmed this is intentional per the JBMetadataResolver referral ID format.

## Test Coverage Summary

| Risk Area | Test File | Coverage |
|-----------|-----------|----------|
| Posting criteria round-trip | `CTPublisher.t.sol` | 11 tests including fuzz |
| Permission enforcement | `CTPublisher.t.sol`, `CroptopAttacks.t.sol` | 3 tests |
| Input validation (price, supply, URI) | `CroptopAttacks.t.sol` | 6 tests |
| Split percent enforcement | `CTPublisher.t.sol`, `CroptopAttacks.t.sol` | 10 tests including fuzz |
| Fee evasion (existing tiers) | `H19_FeeEvasion.t.sol` | 2 regression tests |
| Fee evasion (duplicate URIs) | `M6_DuplicateUriFeeEvasion.t.sol` | 5 tests including fuzz |
| Stale tier mapping | `L52_StaleTierIdMapping.t.sol` | 2 regression tests |
| Metadata generation | `Test_MetadataGeneration.t.sol` | 1 test |
| Full deployment integration | `Fork.t.sol` | 2 fork tests |
| Data hook proxy forwarding | -- | **Not tested** |
| Force-sent ETH handling | -- | **Not tested** |
| Allowlist gas scaling | -- | **Not tested** |
| Sucker fee-free cashout abuse | -- | **Not tested** |
| CTProjectOwner transfer vs mint | -- | **Not tested** |
| Front-running `deployProjectFor` | -- | **Not tested** |

## Invariants

These invariants should hold for all Croptop operations:

1. **Fee invariant:** For any `mintFrom()` where `projectId != FEE_PROJECT_ID`, the fee project receives exactly `totalPrice / FEE_DIVISOR` (minus rounding dust of at most 19 wei).

2. **Posting criteria invariant:** A `mintFrom()` call succeeds only if every post satisfies: `price >= minimumPrice`, `totalSupply >= minimumTotalSupply`, `totalSupply <= maximumTotalSupply`, `splitPercent <= maximumSplitPercent`, and (if allowlist non-empty) `msg.sender in allowedAddresses`.

3. **Tier uniqueness invariant (post-fix):** Within a single `mintFrom()` batch, no two posts can have the same `encodedIPFSUri`.

4. **Fee calculation invariant (post-fix):** For existing tiers, the fee is based on `store.tierOf().price` (on-chain price), not `post.price` (user-supplied).

5. **Ownership invariant:** CTDeployer owns the project NFT only transiently during `deployProjectFor()`. By the end of the function, ownership is always transferred to the specified `owner`.

6. **Data hook immutability invariant:** `dataHookOf[projectId]` is set exactly once (during `deployProjectFor`) and never modified afterward.
