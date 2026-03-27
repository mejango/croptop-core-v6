# croptop-core-v6 Changelog (v5 → v6)

This document describes all changes between `croptop-core` (v5) and `croptop-core-v6` (v6).

## Summary

- **Data hook proxy activated**: `CTDeployer` now sets itself as the data hook (`metadata.dataHook = address(this)`) instead of pointing directly to the 721 hook — enables sucker cashouts at 0% tax rate for cross-chain operations.
- **Split support for posts**: `CTPost` gained `splitPercent` and `splits` fields, allowing poster-defined payment routing per NFT tier (bounded by `maximumSplitPercent`).
- **Fee evasion fixes**: Existing tier mints now use on-chain price (not user-supplied), and duplicate posts within a batch are rejected.
- **Stale tier recovery**: Externally-removed tiers are detected and re-created instead of silently failing.
- **`projectId` cast widened**: `uint56` → `uint64` to match v6 `JBPermissionsData`.

---

## 1. Breaking Changes

### Solidity Version
- Compiler version bumped from `0.8.23` to `0.8.28` across all implementation contracts (`CTDeployer`, `CTProjectOwner`, `CTPublisher`).

### Dependency Namespace Migration
All imports updated from v5 to v6 namespaces:
- `@bananapus/core-v5` → `@bananapus/core-v6`
- `@bananapus/721-hook-v5` → `@bananapus/721-hook-v6`
- `@bananapus/ownable-v5` → `@bananapus/ownable-v6`
- `@bananapus/permission-ids-v5` → `@bananapus/permission-ids-v6`
- `@bananapus/suckers-v5` → `@bananapus/suckers-v6`

### `ICTPublisher.allowanceFor` Return Signature Changed
- **v5:** Returns 4 values — `(uint256 minimumPrice, uint256 minimumTotalSupply, uint256 maximumTotalSupply, address[] memory allowedAddresses)`
- **v6:** Returns 5 values — `(uint256 minimumPrice, uint256 minimumTotalSupply, uint256 maximumTotalSupply, uint256 maximumSplitPercent, address[] memory allowedAddresses)`
- The new `maximumSplitPercent` return value is inserted before `allowedAddresses`. Any consumer destructuring this return value will break.

### `ICTPublisher.mintFrom` Parameter Data Location Changed
- **v5:** `CTPost[] memory posts`
- **v6:** `CTPost[] calldata posts`

### `CTPost` Struct Has New Fields
- **v5:** `{ bytes32 encodedIPFSUri, uint32 totalSupply, uint104 price, uint24 category }`
- **v6:** `{ bytes32 encodedIPFSUri, uint32 totalSupply, uint104 price, uint24 category, uint32 splitPercent, JBSplit[] splits }`
- Adds `splitPercent` (uint32) and `splits` (JBSplit[] from `@bananapus/core-v6`). This changes the ABI encoding of `CTPost` and all functions that accept it.

### `CTAllowedPost` Struct Has New Field
- **v5:** `{ address hook, uint24 category, uint104 minimumPrice, uint32 minimumTotalSupply, uint32 maximumTotalSupply, address[] allowedAddresses }`
- **v6:** `{ address hook, uint24 category, uint104 minimumPrice, uint32 minimumTotalSupply, uint32 maximumTotalSupply, uint32 maximumSplitPercent, address[] allowedAddresses }`
- Adds `maximumSplitPercent` (uint32) before `allowedAddresses`. This changes the ABI encoding of `CTAllowedPost` and all functions that accept it.

### `CTDeployerAllowedPost` Struct Has New Field
- **v5:** `{ uint24 category, uint104 minimumPrice, uint32 minimumTotalSupply, uint32 maximumTotalSupply, address[] allowedAddresses }`
- **v6:** `{ uint24 category, uint104 minimumPrice, uint32 minimumTotalSupply, uint32 maximumTotalSupply, uint32 maximumSplitPercent, address[] allowedAddresses }`
- Adds `maximumSplitPercent` (uint32) before `allowedAddresses`, mirroring `CTAllowedPost`.

### `CTProjectOwner.onERC721Received` — `projectId` Cast Width Changed
- **v5:** `projectId: uint56(tokenId)`
- **v6:** `projectId: uint64(tokenId)`
- This aligns with the v6 `JBPermissionsData` struct which uses `uint64` for `projectId` (was `uint56` in v5).

### `CTDeployer.deployProjectFor` — Data Hook and Cash Out Behavior Changed
- **v5:** Sets `metadata.dataHook = address(hook)` (the 721 hook itself is the data hook). Does NOT set `cashOutTaxRate` or `useDataHookForCashOut`.
- **v6:** Sets `metadata.dataHook = address(this)` (the CTDeployer itself is the data hook). Sets `metadata.cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE` and `metadata.useDataHookForCashOut = true`.
- The CTDeployer now acts as a data hook proxy, forwarding pay/cashout calls to the stored `dataHookOf[projectId]`, while intercepting sucker cash outs to grant 0% tax rate. This is a fundamental architectural change.

> **Why this change**: In v5, the CTDeployer already had the proxy methods (`beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`) and the `dataHookOf` mapping, but `deployProjectFor` pointed `metadata.dataHook` directly at the 721 hook, bypassing the proxy entirely. v6 activates the proxy so the deployer can intercept sucker cashouts (verified via `SUCKER_REGISTRY.isSuckerOf`) and return a 0% tax rate for cross-chain operations. Without this, cross-chain token bridging via suckers would incur the full `MAX_CASH_OUT_TAX_RATE`, making omnichain projects economically unviable.

### `JB721InitTiersConfig` — `prices` Field Removed
- **v5:** `JB721InitTiersConfig({ tiers, currency, decimals, prices: controller.PRICES() })`
- **v6:** `JB721InitTiersConfig({ tiers, currency, decimals })` — the `prices` field no longer exists in the v6 721 hook config struct.

### `JB721TiersHookFlags` — New `issueTokensForSplits` Flag
- **v5:** `JB721TiersHookFlags({ noNewTiersWithReserves, noNewTiersWithVotes, noNewTiersWithOwnerMinting, preventOverspending })`
- **v6:** Adds `issueTokensForSplits: false` as a fifth flag.

### `ICTDeployer.deployProjectFor` — Parameter Renamed
- **v5:** `projectConfigurations` parameter name
- **v6:** `projectConfig` parameter name

---

## 2. New Features

### Split Percent Support for Posts
Posts can now include a `splitPercent` and an array of `splits` (JBSplit[]) that route a percentage of the tier's price to specified recipients when the NFT is minted. This is enforced against a per-category `maximumSplitPercent` configured by the project owner.

- `CTPost.splitPercent` — percent of tier price to route to splits (out of `JBConstants.SPLITS_TOTAL_PERCENT`).
- `CTPost.splits` — the split recipients for the tier.
- `CTAllowedPost.maximumSplitPercent` — the maximum split percent a poster can set (0 = splits not allowed).
- `CTDeployerAllowedPost.maximumSplitPercent` — same as above, for deployer-configured posts.
- `JB721TierConfig` in v6 now accepts `splitPercent` and `splits` fields, which are populated from the post.

### Duplicate Post Detection
- v6 adds an explicit duplicate check within `_setupPosts`: if two posts in the same batch share the same `encodedIPFSUri`, the transaction reverts with `CTPublisher_DuplicatePost`. This prevents fee evasion by submitting duplicate URIs in a single `mintFrom` call.

### Stale Tier Cleanup
- v6 adds logic to detect when a tier referenced by `tierIdForEncodedIPFSUriOf` has been removed externally (via `adjustTiers`). If `hook.STORE().isTierRemoved()` returns true, the stale mapping is deleted and a new tier is created for that URI.

### Fee Evasion Prevention for Existing Tiers
- **v5:** When minting from an existing tier, `totalPrice` was accumulated using `post.price` (user-supplied).
- **v6:** When minting from an existing tier, `totalPrice` is accumulated using the actual tier price fetched from `store.tierOf()`. This prevents a caller from passing `price=0` for an existing tier to evade fees.

### CTDeployer Data Hook Proxy Activated
- The CTDeployer implemented the data hook proxy pattern in v5 as well -- it had `beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`, and the `dataHookOf` mapping -- but `deployProjectFor` set `metadata.dataHook = address(hook)` (the 721 hook directly), so the proxy methods were never called. In v6, `deployProjectFor` sets `metadata.dataHook = address(this)`, `cashOutTaxRate = MAX_CASH_OUT_TAX_RATE`, and `useDataHookForCashOut = true`, activating the proxy. This routes all pay and cash out data hook calls through CTDeployer, which forwards them to the stored `dataHookOf[projectId]` while intercepting sucker cash outs (verified via `SUCKER_REGISTRY.isSuckerOf`) to return a 0% tax rate for cross-chain operations.

---

## 3. Event Changes

Indexer note:
- event names are stable, but embedded struct payloads changed ABI shape;
- if your graph decodes `ConfigurePostingCriteria` or `Mint`, update the event-decoding schema for the new `maximumSplitPercent`, `splitPercent`, and `splits` fields.

No event signatures were changed. Both versions emit the same two events:
- `ConfigurePostingCriteria(address indexed hook, CTAllowedPost allowedPost, address caller)` — note that the `CTAllowedPost` struct gained a `maximumSplitPercent` field, which changes the ABI encoding of this event's data.
- `Mint(uint256 indexed projectId, IJB721TiersHook indexed hook, address indexed nftBeneficiary, address feeBeneficiary, CTPost[] posts, uint256 postValue, uint256 txValue, address caller)` — note that the `CTPost` struct gained `splitPercent` and `splits` fields, which changes the ABI encoding of this event's data.

---

## 4. Error Changes

### New Errors

| Error | Contract | Description |
|-------|----------|-------------|
| `CTPublisher_DuplicatePost(bytes32 encodedIPFSUri)` | `CTPublisher` | Reverts when two posts in the same `mintFrom` batch share the same encoded IPFS URI. |
| `CTPublisher_SplitPercentExceedsMaximum(uint256 splitPercent, uint256 maximumSplitPercent)` | `CTPublisher` | Reverts when a post's split percent exceeds the category's configured maximum. |

### Unchanged Errors
- `CTDeployer_NotOwnerOfProject(uint256 projectId, address hook, address caller)` — unchanged.
- `CTPublisher_EmptyEncodedIPFSUri()` — unchanged.
- `CTPublisher_InsufficientEthSent(uint256 expected, uint256 sent)` — signature unchanged; v6 adds an explicit fee validation check before the subtraction (`if (payValue < fee) revert`) so this error now fires with a descriptive message instead of a panic on underflow.
- `CTPublisher_MaxTotalSupplyLessThanMin(uint256 min, uint256 max)` — unchanged.
- `CTPublisher_NotInAllowList(address addr, address[] allowedAddresses)` — unchanged.
- `CTPublisher_PriceTooSmall(uint256 price, uint256 minimumPrice)` — unchanged.
- `CTPublisher_TotalSupplyTooBig(uint256 totalSupply, uint256 maximumTotalSupply)` — unchanged.
- `CTPublisher_TotalSupplyTooSmall(uint256 totalSupply, uint256 minimumTotalSupply)` — unchanged.
- `CTPublisher_UnauthorizedToPostInCategory()` — unchanged.
- `CTPublisher_ZeroTotalSupply()` — unchanged.

---

## 5. Struct Changes

### `CTPost`
| Field | v5 | v6 |
|-------|----|----|
| `encodedIPFSUri` | `bytes32` | `bytes32` |
| `totalSupply` | `uint32` | `uint32` |
| `price` | `uint104` | `uint104` |
| `category` | `uint24` | `uint24` |
| `splitPercent` | -- | `uint32` (new) |
| `splits` | -- | `JBSplit[]` (new) |

New import: `JBSplit` from `@bananapus/core-v6/src/structs/JBSplit.sol`.

### `CTAllowedPost`
| Field | v5 | v6 |
|-------|----|----|
| `hook` | `address` | `address` |
| `category` | `uint24` | `uint24` |
| `minimumPrice` | `uint104` | `uint104` |
| `minimumTotalSupply` | `uint32` | `uint32` |
| `maximumTotalSupply` | `uint32` | `uint32` |
| `maximumSplitPercent` | -- | `uint32` (new) |
| `allowedAddresses` | `address[]` | `address[]` |

### `CTDeployerAllowedPost`
| Field | v5 | v6 |
|-------|----|----|
| `category` | `uint24` | `uint24` |
| `minimumPrice` | `uint104` | `uint104` |
| `minimumTotalSupply` | `uint32` | `uint32` |
| `maximumTotalSupply` | `uint32` | `uint32` |
| `maximumSplitPercent` | -- | `uint32` (new) |
| `allowedAddresses` | `address[]` | `address[]` |

### `CTProjectConfig`
No field changes. Import path updated from `@bananapus/core-v5` to `@bananapus/core-v6` for `JBTerminalConfig`.

### `CTSuckerDeploymentConfig`
No field changes. Import path updated from `@bananapus/suckers-v5` to `@bananapus/suckers-v6` for `JBSuckerDeployerConfig`.

---

## 6. Implementation Changes (Non-Interface)

### `CTPublisher._setupPosts`

#### Store Reference Caching
- **v5:** Calls `hook.STORE().maxTierIdOf(...)` inline, accessing the store through the hook each time.
- **v6:** Caches `IJB721TiersHookStore store = hook.STORE()` once and reuses it. Also imports `IJB721TiersHookStore` explicitly.

#### Duplicate Post Detection
- **v6 only:** Adds an O(n^2) check at the start of each post iteration that scans all previous posts for matching `encodedIPFSUri`. Reverts with `CTPublisher_DuplicatePost` on match.

#### Stale Tier Recovery
- **v5:** If `tierIdForEncodedIPFSUriOf` returns a nonzero tier ID, it is used unconditionally.
- **v6:** Checks `hook.STORE().isTierRemoved(address(hook), tierId)`. If removed, deletes the stale mapping and falls through to create a new tier.

#### Fee-Accurate Price for Existing Tiers
- **v5:** `totalPrice += post.price` for all posts (new and existing).
- **v6:** For existing tiers, `totalPrice += store.tierOf(...).price` (uses actual on-chain price). For new tiers, `totalPrice += post.price`.

#### Split Validation
- **v6 only:** Checks `post.splitPercent > maximumSplitPercent` and reverts with `CTPublisher_SplitPercentExceedsMaximum` if exceeded.

#### `JB721TierConfig` Construction
- **v5:** 14 fields in `JB721TierConfig`.
- **v6:** 16 fields — adds `splitPercent: post.splitPercent` and `splits: post.splits`.

### `CTPublisher.allowanceFor` — Packed Storage Layout Extended
- **v5:** Packs 3 fields into `_packedAllowanceFor`: bits 0-103 (minimumPrice), 104-135 (minimumTotalSupply), 136-167 (maximumTotalSupply). Total: 168 bits.
- **v6:** Packs 4 fields: bits 0-103, 104-135, 136-167 as before, plus bits 168-199 (maximumSplitPercent, 32 bits). Total: 200 bits.

### `CTPublisher.configurePostingCriteriaFor` — Packs `maximumSplitPercent`
- **v6 only:** Adds `packed |= uint256(allowedPost.maximumSplitPercent) << 168;` when storing allowance data.

### `CTDeployer._configurePostingCriteriaFor` — Passes `maximumSplitPercent`
- **v5:** `CTAllowedPost` construction has 6 fields.
- **v6:** `CTAllowedPost` construction has 7 fields — adds `maximumSplitPercent: post.maximumSplitPercent`.

### `CTDeployer.deployProjectFor` — Ruleset Configuration Changes
- **v5:** Sets `metadata.dataHook = address(hook)` and `metadata.useDataHookForPay = true`.
- **v6:** Sets `metadata.cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE`, `metadata.dataHook = address(this)`, `metadata.useDataHookForPay = true`, and `metadata.useDataHookForCashOut = true`. Imports `JBConstants` for this.

### `CTDeployer.deployProjectFor` — Named Arguments in Function Calls
- **v6:** Uses named arguments consistently (e.g., `PROJECTS.transferFrom({from: ..., to: ..., tokenId: ...})` instead of positional arguments).

### `CTDeployer` — Function Ordering
- **v5:** `beforePayRecordedWith` appears before `beforeCashOutRecordedWith` in source.
- **v6:** `beforeCashOutRecordedWith` appears before `beforePayRecordedWith`. Similarly, `claimCollectionOwnershipOf` appears before `deployProjectFor` in v6 (reversed from v5).

### `CTDeployer.beforeCashOutRecordedWith` — Named Arguments
- **v5:** `SUCKER_REGISTRY.isSuckerOf(context.projectId, context.holder)`
- **v6:** `SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})`

### `CTDeployer.hasMintPermissionFor` — Named Arguments
- **v5:** `SUCKER_REGISTRY.isSuckerOf(projectId, addr)`
- **v6:** `SUCKER_REGISTRY.isSuckerOf({projectId: projectId, addr: addr})`

### `CTPublisher.tiersFor` — Named Arguments
- **v5:** `IJB721TiersHook(hook).STORE().tierOf(hook, tierId, false)`
- **v6:** `IJB721TiersHook(hook).STORE().tierOf({hook: hook, id: tierId, includeResolvedUri: false})`

### `CTPublisher.mintFrom` — Named Arguments
- **v6:** Uses named arguments for `DIRECTORY.primaryTerminalOf(...)`, `hook.adjustTiers(...)`, `JBMetadataResolver.getId(...)`, and `_isAllowed(...)`.

### NatDoc / Comments
- **v6:** Adds extensive NatDoc comments to all interface functions, events, and struct fields. Adds `forge-lint` disable comments for mixed-case variables. Adds explanatory comments for design decisions (e.g., fee rounding behavior, force-sent ETH handling, category irrevocability, linear scan scaling).

---

## 7. Migration Table

| v5 Identifier | v6 Identifier | Change |
|---------------|---------------|--------|
| `CTPost.{4 fields}` | `CTPost.{6 fields}` | Added `splitPercent`, `splits` |
| `CTAllowedPost.{6 fields}` | `CTAllowedPost.{7 fields}` | Added `maximumSplitPercent` |
| `CTDeployerAllowedPost.{5 fields}` | `CTDeployerAllowedPost.{6 fields}` | Added `maximumSplitPercent` |
| `ICTPublisher.allowanceFor` (4 returns) | `ICTPublisher.allowanceFor` (5 returns) | Added `maximumSplitPercent` return |
| `ICTPublisher.mintFrom(... CTPost[] memory ...)` | `ICTPublisher.mintFrom(... CTPost[] calldata ...)` | `memory` → `calldata` |
| `CTProjectOwner`: `uint56(tokenId)` | `CTProjectOwner`: `uint64(tokenId)` | Cast width for projectId |
| `CTDeployer`: `dataHook = address(hook)` | `CTDeployer`: `dataHook = address(this)` | CTDeployer is now the data hook |
| `CTDeployer`: no cashout config | `CTDeployer`: `cashOutTaxRate = MAX`, `useDataHookForCashOut = true` | Enables sucker 0% tax cashout |
| `JB721InitTiersConfig`: has `prices` | `JB721InitTiersConfig`: no `prices` | Field removed in v6 721 hook |
| `JB721TiersHookFlags`: 4 flags | `JB721TiersHookFlags`: 5 flags | Added `issueTokensForSplits` |
| -- | `CTPublisher_DuplicatePost` | New error |
| -- | `CTPublisher_SplitPercentExceedsMaximum` | New error |
| Solidity `0.8.23` | Solidity `0.8.28` | Compiler bump |
| `@bananapus/*-v5` | `@bananapus/*-v6` | All dependency namespaces |

> **Cross-repo impact**: The `CTPost.splitPercent` and `splits` fields feed directly into `nana-721-hook-v6`'s tier splits system. `nana-suckers-v6` suckers are detected via `SUCKER_REGISTRY.isSuckerOf` for the 0% tax cashout path. `nana-permission-ids-v6` `uint64` projectId width change drove the `CTProjectOwner` cast update.
