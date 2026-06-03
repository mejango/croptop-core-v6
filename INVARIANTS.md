# Invariants of `croptop-core-v6`

Scope: the three production contracts in `src/` — `CTPublisher`, `CTDeployer`, `CTProjectOwner` — plus their three interfaces in `src/interfaces/` and the five structs in `src/structs/`. Croptop is a permissionless social-posting layer on top of a Juicebox revnet:

- **`CTPublisher`** is the universal entrypoint: any caller (subject to per-category allowlist) can call `mintFrom` to create one or more new 721 tiers on a project and mint the first copy in a single transaction. The caller supplies a terminal `token` and `amount`; native-token payments use `msg.value`, and ERC-20 payments are pulled from `_msgSender()` by direct approval or Permit2. Tier creation is gated by per-category `minimumPrice`, `minimumTotalSupply`, `maximumTotalSupply`, `maximumSplitPercent` set by the project owner (or an `ADJUST_721_TIERS` operator). A 5% (`1/FEE_DIVISOR=20`) fee routes to the configured fee project or refunds if that fee path is unavailable. Duplicate IPFS URIs within a batch revert, the second mint of an already-published URI reuses the existing tier rather than creating a duplicate, and a project payment that does not deliver the requested NFTs reverts.
- **`CTDeployer`** launches Croptop-ready Juicebox projects: it reserves the project NFT, deploys a `JB721TiersHook`, queues a ruleset that uses `CTDeployer` itself as the data hook (giving suckers 0% cash-out tax and mint permission), optionally deploys suckers, configures allowed posts on `CTPublisher`, and finally `safeTransferFrom`s the project NFT to the intended owner. The hook stays owned by the deployer until the project owner calls `claimCollectionOwnershipOf`.
- **`CTProjectOwner`** is a permission-routing helper: any project NFT `safeTransferFrom`'d into it grants `CTPublisher` the `ADJUST_721_TIERS` permission for that project and the NFT becomes permanently stuck — there is no transfer-out path.

This file is the per-repo scoped invariants doc. The protocol-wide guarantees for the V6 deploy live in [`../INVARIANTS.md`](../INVARIANTS.md). The `RISKS.md` in this repo enumerates the runtime/admin/deployment/integration risk-set this invariants doc operationally implements; `ARCHITECTURE.md` is the higher-altitude system overview.

---

# Section A — Guarantees to Users (Posters / Minters)

"Users" here are anyone who calls `CTPublisher.mintFrom` to publish a new post and mint the first NFT, or who mints subsequent copies of an existing tier through the project's terminal. There is no separate "holder" surface in this repo — the 721 hook (in `nana-721-hook-v6`) governs holder-side cash-out / transfer mechanics.

## A.1 Permissionless posting (subject to allowlist)

- **A.1.1 Any address can `mintFrom` when the category has no allowlist.** `CTPublisher.mintFrom` calls `_setupPosts`, which evaluates the category's `_allowedAddresses` array. If the array is empty, the address check is skipped — anyone can post (`src/CTPublisher.sol`). When the array is non-empty, `_isAllowed` linearly scans for `_msgSender()` and reverts `CTPublisher_NotInAllowList` if not found (`src/CTPublisher.sol`).
- **A.1.2 Posts must satisfy ALL four per-category bounds, evaluated together.** For each NEW tier (`tierIdsToMint[i] == 0`), `_setupPosts` reads the packed allowance via `allowanceFor` and enforces:
  - `post.price >= minimumPrice` else `CTPublisher_PriceTooSmall` (`src/CTPublisher.sol`).
  - `post.totalSupply >= minimumTotalSupply` else `CTPublisher_TotalSupplyTooSmall` (`src/CTPublisher.sol`).
  - `post.totalSupply <= maximumTotalSupply` (when `maximumTotalSupply != 0`; zero means unlimited) else `CTPublisher_TotalSupplyTooBig` (`src/CTPublisher.sol`).
  - `post.splitPercent <= maximumSplitPercent` else `CTPublisher_SplitPercentExceedsMaximum` (`src/CTPublisher.sol`).
  All four are enforced independently — none can override another.
- **A.1.3 Posting to an unconfigured / disabled category reverts.** `_setupPosts` checks `minimumTotalSupply == 0` and reverts `CTPublisher_UnauthorizedToPostInCategory` (`src/CTPublisher.sol`). Since `configurePostingCriteriaFor` itself rejects `minimumTotalSupply == 0` (`src/CTPublisher.sol`, B.1.3), a category is "active" exactly when its operator has explicitly configured it.
- **A.1.4 Empty `posts` array reverts.** `mintFrom` reverts `CTPublisher_NoPosts` if `posts.length == 0` (`src/CTPublisher.sol`). A caller cannot use Croptop as a fee-free pay-router to the project terminal.

## A.2 Duplicate-IPFS protection

- **A.2.1 Within-batch duplicate IPFS URIs revert.** `_setupPosts` runs an O(n²) inner loop comparing each post's `encodedIpfsUri` against all earlier indices in the same batch; a match reverts `CTPublisher_DuplicatePost` (`src/CTPublisher.sol`). Posters cannot batch the same URI twice to pay for one tier-creation but mint two NFTs at the new tier's price (the fee path uses `totalPrice`, not `numberOfNewTiers`).
- **A.2.2 Empty IPFS URI reverts.** Any post with `encodedIpfsUri == bytes32(0)` reverts `CTPublisher_EmptyEncodedIpfsUri` (`src/CTPublisher.sol`). Prevents the canonical "missing URI" tier from being claimed by anyone.
- **A.2.3 Cross-batch duplicate reuses the existing tier at its existing price.** When a previously-published URI is included again, `_setupPosts` looks up `tierIdForEncodedIpfsUriOf[hook][uri]`. If the cached tier still exists and its URI still matches, the function uses the CACHED tier's stored `price` (NOT the caller-supplied `post.price`) when accumulating `totalPrice` and routes the mint to the existing tier (`src/CTPublisher.sol`). A caller cannot pass `post.price = 0` for an existing tier to mint at zero cost.
- **A.2.4 Stale cache is auto-invalidated.** If the cached tier was removed via `adjustTiers` (`store.isTierRemoved == true`) OR its URI changed via `setMetadata` (`cachedTier.encodedIpfsUri != post.encodedIpfsUri`), `_setupPosts` deletes the mapping and falls through to create a new tier (`src/CTPublisher.sol`). Stale mappings cannot strand a URI or charge stale prices.

## A.3 Fee accounting and routing

- **A.3.1 5% fee on `totalPrice`, payable in the selected terminal token.** `mintFrom` takes `token` and `amount`. Croptop reads the project terminal's accounting context for `token`, converts the hook tier total into that payment-token unit, and uses `hook.PRICES()` when the payment currency differs from `hook.pricingContext()` (`src/CTPublisher.sol`). ETH and the native-token currency alias are equivalent for native-token pricing. When `projectId != FEE_PROJECT_ID`, it deducts `fee = totalPrice / FEE_DIVISOR` (with `FEE_DIVISOR = 20`, i.e. 5%) from `amount`. The remainder (`payValue`) is paid to the project's primary terminal for `token`; the fee is paid to the fee project's primary terminal for `token` when that terminal exists (`src/CTPublisher.sol`).
- **A.3.2 Insufficient `amount` reverts.** Two separate checks: (a) `payValue < fee` (the fee deduction would underflow) reverts `CTPublisher_InsufficientEthSent` for native token or `CTPublisher_InsufficientPayment` for ERC-20 (`src/CTPublisher.sol`); (b) the converted tier price exceeds the remaining `payValue` after fee deduction, reverting the same token-appropriate error (`src/CTPublisher.sol`).
- **A.3.3 Excess `amount` is paid through.** If `amount > totalPrice + fee`, the surplus flows into `payValue` and is paid into the project's terminal — it is NOT refunded. This is consistent with the project-payment semantics of the underlying terminal (overpayment increases the beneficiary's mint count or surplus, depending on the project's curve), and is the caller's responsibility.
- **A.3.4 Fee project posts skip the fee.** When `projectId == FEE_PROJECT_ID`, the fee deduction and fee-terminal call are skipped entirely (`src/CTPublisher.sol`). The fee project does not pay a fee to itself.
- **A.3.5 Failed or missing fee payment refunds the caller.** If the fee project has no primary terminal for the selected token, or if the fee terminal reverts, the fee amount is refunded to `_msgSender()` in the selected token. If a native-token refund fails, the whole tx reverts `CTPublisher_FeePaymentFailed` (`src/CTPublisher.sol`). Fees never strand inside `CTPublisher`.
- **A.3.6 `feeBeneficiary == address(0)` rejected upfront.** Reverts `CTPublisher_InvalidFeeBeneficiary` (`src/CTPublisher.sol`). Prevents callers from burning the fee project's tokens by minting to the zero address.
- **A.3.7 Post-call fee math uses pre-computed `payValue`, not contract balances.** After `projectTerminal.pay`, the code recomputes `payValue = amount - payValue` to recover the fee amount, deliberately avoiding `address(this).balance` or ERC-20 balances so reentrancy / force-sent funds cannot inflate the fee paid to the fee project (`src/CTPublisher.sol`).
- **A.3.8 Project payment must mint the requested NFTs.** `mintFrom` snapshots the beneficiary's hook-store balance before `projectTerminal.pay` and requires the balance to increase by `posts.length` afterward. If the active terminal path accepts payment but does not invoke the intended 721 mint, the whole transaction reverts (`src/CTPublisher.sol`).
- **A.3.9 Permit2 authorizes ERC-20 pulls without direct publisher approval.** If `additionalPayMetadata` includes a `permit2` entry targeted to `CTPublisher`, the publisher validates `amount <= permit2Allowance.amount`, submits the allowance for `_msgSender()`, and then pulls ERC-20 payment tokens through either a direct publisher allowance or Permit2. Native-token payments ignore Permit2 data. A failed Permit2 allowance attempt is emitted and the subsequent pull must still succeed or revert (`src/CTPublisher.sol`).

## A.4 Anti-tier-shadow (caller metadata cannot select tiers)

- **A.4.1 Caller-supplied `additionalPayMetadata` cannot include a `pay`-purpose ID.** Before composing the mint metadata, `mintFrom` looks up the JBMetadataResolver `pay` ID against `hook.METADATA_ID_TARGET()` and reverts `CTPublisher_DuplicatePayMetadata` if any `getDataFor(payId, additionalPayMetadata).exists` (`src/CTPublisher.sol`). A caller cannot smuggle a forged `tierIdsToMint` array through their metadata to mint arbitrary (cheaper or already-deployed) tiers.
- **A.4.2 Croptop ALWAYS prepends its own canonical `(true, tierIdsToMint)` `pay` entry.** After the existence check, `mintFrom` calls `JBMetadataResolver.addToMetadata` to append its own pay entry derived from `_setupPosts`' output. The 721 hook only sees the Croptop-authored tier list.

## A.5 Post-tier-creation ordering

- **A.5.1 New tiers are sorted by ASCENDING CATEGORY for `adjustTiers`, but mint metadata stays in caller-`posts` order.** `_setupPosts` carries `newTierPostIndexes[]` alongside `tiersToAdd[]`, stably insertion-sorts both in lockstep by category, then translates each new tier's `startingTierId + i` back into `tierIdsToMint[postIndex]` (`src/CTPublisher.sol`). A caller submitting posts in mint order, in any category order, gets:
  - tiers added on-chain in the category-sorted order the hook requires (`InvalidCategorySortOrder` from the 721 store is impossible),
  - mints emitted in the caller's submitted order via the metadata.
- **A.5.2 Subsequent mints of the same URI cost the original price.** Because `tierIdForEncodedIpfsUriOf` is keyed on the URI, the second `mintFrom` call with the same URI reuses the existing tier ID and adds the existing tier's price to `totalPrice` (A.2.3). The original poster cannot raise the price on re-posts (the tier's stored price is what `tierOf` returns).

---

# Section B — Guarantees to Operators (Project Owners / 721-Tier Admins)

"Operator" here is the project NFT owner OR any address granted `ADJUST_721_TIERS` on that project's hook owner.

## B.1 Configuring posting criteria

- **B.1.1 `configurePostingCriteriaFor` is gated by the hook owner's permission table.** For each entry, `CTPublisher` calls `_requirePermissionFrom({account: JBOwnable(hook).owner(), projectId: hook.projectId(), permissionId: JBPermissionIds.ADJUST_721_TIERS})` (`src/CTPublisher.sol`). Until the project owner claims hook ownership (see B.4), `JBOwnable(hook).owner()` resolves to `CTDeployer`; afterwards it resolves dynamically through `PROJECTS.ownerOf(projectId)`. Either way, only the legitimate authority for the hook can edit criteria.
- **B.1.2 Each call REPLACES the criteria for the specified `(hook, category)`.** The packed allowance is overwritten in one `SSTORE`, and the allowlist array is either bulk-assigned (non-empty supplied) or `delete`d (empty supplied) (`src/CTPublisher.sol`). Stale allowlist entries cannot survive across edits.
- **B.1.3 `minimumTotalSupply == 0` rejected.** Reverts `CTPublisher_ZeroTotalSupply` (`src/CTPublisher.sol`). Operators cannot configure a category that would simultaneously appear "active" (allowing posts) and "inactive" (failing A.1.3). The internal-state invariant `_packedAllowanceFor[hook][category] != 0  iff  category is active` is preserved.
- **B.1.4 `minimumTotalSupply > maximumTotalSupply` rejected (when max != 0).** Reverts `CTPublisher_MaxTotalSupplyLessThanMin` (`src/CTPublisher.sol`). `maximumTotalSupply == 0` is treated as unlimited and skips the check, matching the runtime semantics in A.1.2.
- **B.1.5 Categories cannot be fully disabled, only restricted.** There is no `removeCategory` or "delete" flow. Once a category is configured, the operator can tighten allowedAddresses, raise `minimumPrice`, lower `maximumTotalSupply`, or zero out `maximumSplitPercent` to effectively block new posts — but the cache mapping `tierIdForEncodedIpfsUriOf` and previously-published tiers remain. This is documented in the source as intentional: "removing posting would break expectations for existing posters" (`src/CTPublisher.sol`).

## B.2 Configuration is a property of the HOOK, not the project

- **B.2.1 The `_packedAllowanceFor` and `_allowedAddresses` maps are keyed on `address hook`, not on `projectId`.** A project that migrates to a new 721 hook (or has no hook at all) does not inherit the prior hook's posting criteria. Conversely, two projects sharing one 721 hook would share criteria — though in practice each Croptop-deployed project gets its own hook.

## B.3 Powers the operator does NOT have via Croptop

- **B.3.1 No mint authority beyond the publisher.** Croptop does not grant the operator new mint paths. The operator's mint authority over the hook comes from `CTDeployer`'s launch-time grant of `MINT_721` (see D.2), not from `CTPublisher`.
- **B.3.2 No fee redirection.** `FEE_PROJECT_ID` is `immutable` on `CTPublisher` (`src/CTPublisher.sol`). The operator cannot redirect the 5% fee to themselves.
- **B.3.3 No claim on already-published tiers.** Once a tier is created, the operator cannot revoke its IPFS URI mapping or force-burn it through Croptop. The hook's own `adjustTiers` / `setMetadata` paths govern tier mutation — Croptop only WRITES the mapping, the 721 hook owns the tier.

## B.4 Hook-ownership claim (post-deploy convenience)

- **B.4.1 `claimCollectionOwnershipOf` is callable only by the current `PROJECTS.ownerOf(projectId)`.** Reverts `CTDeployer_NotOwnerOfProject` otherwise (`src/CTDeployer.sol`). A third party cannot snatch hook ownership.
- **B.4.2 Atomic: revokes deployer-scoped permissions for the caller, then transfers hook ownership to the project.** `_transferOwnershipToProject` resolves `JBOwnable(hook).owner()` to `PROJECTS.ownerOf(projectId)` dynamically thereafter (`src/CTDeployer.sol`). The owner becomes the de facto hook authority.
- **B.4.3 Caller MUST grant `CTPublisher` `ADJUST_721_TIERS` after claiming, or future posts will revert.** Documented inline in source (`src/CTDeployer.sol`). This is a launch-time UX trade-off acknowledged in the contract docstring, not a structural defect — the deployer cannot atomically grant on the project owner's behalf because at the moment of the claim, the project owner is the new authority and the deployer no longer is.

---

# Section C — Per-Contract Operation Inventory

## C.1 `CTPublisher` — `src/CTPublisher.sol`

### Constructor (one-shot, immutable wiring)

- **`constructor(IJBDirectory directory, IJBPermissions permissions, uint256 feeProjectId, address trustedForwarder)`** (`src/CTPublisher.sol`) — sets `DIRECTORY`, `FEE_PROJECT_ID`, ERC-2771 trusted forwarder, and `JBPermissioned`'s `PERMISSIONS`. All four are immutable.

### Operator-gated configuration

- **`configurePostingCriteriaFor(CTAllowedPost[] memory allowedPosts) external`** (`src/CTPublisher.sol`) — gated per-entry by `_requirePermissionFrom(JBOwnable(hook).owner(), hook.projectId(), ADJUST_721_TIERS)`. Iterates the array; for each entry validates `minimumTotalSupply != 0` and `minimumTotalSupply <= maximumTotalSupply` (when max != 0), then packs `(minimumPrice | minimumTotalSupply | maximumTotalSupply | maximumSplitPercent)` into one slot and writes the allowlist array. Emits `ConfigurePostingCriteria` per entry. Reverts: `CTPublisher_ZeroTotalSupply`, `CTPublisher_MaxTotalSupplyLessThanMin`, plus `_requirePermissionFrom`'s unauthorized revert.
  - **Invariants:** B.1.1, B.1.2, B.1.3, B.1.4, B.1.5, B.2.1.

### Permissionless mint entrypoint

- **`mintFrom(IJB721TiersHook hook, CTPost[] calldata posts, address token, uint256 amount, address nftBeneficiary, address feeBeneficiary, bytes calldata additionalPayMetadata) external payable`** (`src/CTPublisher.sol`) — anyone. Validates native-token `amount == msg.value` or pulls ERC-20 `amount` from `_msgSender()` by direct allowance or publisher-targeted Permit2 metadata; validates `posts.length != 0`, `feeBeneficiary != address(0)`, and the selected payment token's terminal accounting context; converts hook tier pricing into payment-token units; calls `_setupPosts` to validate per-category allowances, build sorted tier configs, and accumulate `totalPrice`; computes fee (skipping when `projectId == FEE_PROJECT_ID`); validates `amount` covers converted price+fee; calls `hook.adjustTiers(tiersToAdd, [])` to add new tiers; rejects `additionalPayMetadata` containing a `pay`-purpose ID; composes Croptop's canonical pay metadata; emits `Mint`; pays the project's primary terminal for `token`; verifies the beneficiary received the requested NFTs; recomputes the fee from `amount - payValue`; if fee != 0, pays the fee project's primary terminal for `token` when available, otherwise clearing and refunding on failure or missing terminal.
  - Reverts: `CTPublisher_NoPosts`, `CTPublisher_InvalidFeeBeneficiary`, `CTPublisher_InvalidPaymentTokenContext`, `CTPublisher_PriceFeedUnavailable`, `CTPublisher_PermitAllowanceNotEnough`, `CTPublisher_NativeTokenAmountMismatch`, `CTPublisher_MsgValueNotAllowed`, `CTPublisher_InsufficientEthSent` / `CTPublisher_InsufficientPayment`, `CTPublisher_TemporaryAllowanceNotConsumed`, `CTPublisher_DuplicatePayMetadata`, `CTPublisher_MintNotDelivered`, `CTPublisher_FeePaymentFailed`, plus all `_setupPosts` reverts below.
  - **Invariants:** A.1.1–A.1.4, A.2.1–A.2.4, A.3.1–A.3.9, A.4.1–A.4.2, A.5.1–A.5.2.

### Views

- **`tiersFor(address hook, bytes32[] encodedIpfsUris) external view → JB721Tier[]`** (`src/CTPublisher.sol`) — looks up `tierIdForEncodedIpfsUriOf[hook][uri]` per URI and queries the hook's store. Returns the default empty tier when not yet published OR when the cached ID is stale; callers must check `tier.initialSupply` to disambiguate (documented in source).
- **`allowanceFor(address hook, uint256 category) public view → (uint256, uint256, uint256, uint256, address[])`** (`src/CTPublisher.sol`) — unpacks the four bit-fields and returns the allowlist.
- **`tierIdForEncodedIpfsUriOf(address, bytes32) public view → uint256`** — auto-getter; URI→tierId map.
- **Immutable getters:** `DIRECTORY`, `FEE_PROJECT_ID`, `PERMIT2`, `FEE_DIVISOR` (constant), plus inherited `PERMISSIONS()`.

### Internal helpers

- **`_acceptFundsFor`, `_transferFrom`** (`src/CTPublisher.sol`) — validate native-token value, pull ERC-20s by direct allowance or Permit2, and return the actual amount received.
- **`_clearAllowanceFor`, `_prepareAllowanceFor`, `_requireTemporaryAllowanceConsumed`** (`src/CTPublisher.sol`) — manage exact-use temporary ERC-20 allowances for downstream terminal calls.
- **`_isAllowed(address addr, address[] addresses) internal pure → bool`** (`src/CTPublisher.sol`) — O(n) linear scan.
- **`_paymentAmountFromPricing`, `_paymentContextOf`, `_scaleAmount`** (`src/CTPublisher.sol`) — validate selected terminal-token accounting context and convert hook tier pricing into terminal-token units, rounding up when decimal precision is reduced.
- **`_refundFee`** (`src/CTPublisher.sol`) — refunds a failed fee payment in the selected token; native-token refund failure reverts.
- **`_revertInsufficientPayment`** (`src/CTPublisher.sol`) — preserves the native-compatible insufficient-ETH error for native payments and uses token-generic insufficient-payment errors otherwise.
- **`_setupPosts(IJB721TiersHook hook, CTPost[] posts) → (JB721TierConfig[], uint256[], uint256)`** (`src/CTPublisher.sol`) — for each post: rejects empty URI (A.2.2), rejects within-batch duplicate URI (A.2.1), checks the URI cache and reuses cached tier price (A.2.3) or invalidates stale cache (A.2.4); for new tiers, reads `allowanceFor` and enforces A.1.2 / A.1.3; assembles a `JB721TierConfig` with fixed flags (`allowOwnerMint=false`, `useVotingUnits=true`, others false); tracks the `(tierToAdd, originalPostIndex)` pair for stable in-place insertion-sort by ascending category; finally re-maps `startingTierId + i` back to `tierIdsToMint[postIndex]` and to `tierIdForEncodedIpfsUriOf`. Resizes `tiersToAdd` via assembly when fewer new tiers were added than `posts.length`.
- **`_contextSuffixLength` / `_msgData` / `_msgSender`** — standard ERC-2771 trampolines (`src/CTPublisher.sol`).

## C.2 `CTDeployer` — `src/CTDeployer.sol`

### Constructor (one-shot, immutable wiring + permission self-grant)

- **`constructor(IJBPermissions permissions, IJBProjects projects, IJB721TiersHookDeployer deployer, ICTPublisher publisher, IJBSuckerRegistry suckerRegistry, address trustedForwarder)`** (`src/CTDeployer.sol`) — sets immutables. Grants `CTPublisher` a wildcard (`projectId: 0`) `ADJUST_721_TIERS` permission on `CTDeployer`'s own permission table so that while the deployer temporarily owns a new hook, the publisher can call `adjustTiers` via the JBPermissioned `_requirePermissionFrom(JBOwnable(hook).owner() == CTDeployer, ...)` path.

### Permissionless launch

- **`deployProjectFor(address owner, CTProjectConfig calldata projectConfig, CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration, IJBController controller) external payable → (uint256 projectId, IJB721TiersHook hook)`** (`src/CTDeployer.sol`) — anyone. Validates `controller.PROJECTS() == PROJECTS`; reserves the project NFT to `CTDeployer` via `PROJECTS.createFor{value: msg.value}(address(this))`; deploys a fresh `JB721TiersHook` with name/symbol/contractUri from `projectConfig`, empty tier list, ETH currency at 18 decimals, salt = `keccak256(salt, _msgSender())`, and zero token URI resolver; configures a single ruleset with `weight = 1e24`, ETH base currency, `cashOutTaxRate = MAX_CASH_OUT_TAX_RATE`, and `dataHook = address(this)` with `useDataHookForPay = useDataHookForCashOut = true`; calls `controller.launchRulesetsFor`; records `dataHookOf[projectId] = hook`; calls `_configurePostingCriteriaFor(hook, allowedPosts)`; if `suckerDeploymentConfiguration.salt != 0`, mirrors the sucker-registry's explicit-peer permission check against `owner` (not `address(this)`) and try/catch calls `SUCKER_REGISTRY.deploySuckersFor` (emits `CTDeployer_SuckerDeploymentFailed` on catch — launch still succeeds); `safeTransferFrom`s the project NFT to `owner`; grants `owner` (on `CTDeployer`'s table) `ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT` so they can directly admin the hook while the deployer still owns it.
  - Reverts: bare `revert()` on wrong-controller mismatch; propagated reverts from `PROJECTS.createFor`, `DEPLOYER.deployHookFor`, `controller.launchRulesetsFor`, `safeTransferFrom`. Sucker failures are caught.
  - **Invariants:** D.1, D.2, D.3 below.

### Operator-gated post-launch ops

- **`deploySuckersFor(uint256 projectId, CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration) external → address[]`** (`src/CTDeployer.sol`) — gated by `_requirePermissionFrom(PROJECTS.ownerOf(projectId), projectId, DEPLOY_SUCKERS)`; explicit-peer entries additionally require `SET_SUCKER_PEER` via `_requireExplicitSuckerPeerPermissionFrom`. Calls `SUCKER_REGISTRY.deploySuckersFor` with salt = `keccak256(salt, _msgSender())`.
- **`claimCollectionOwnershipOf(IJB721TiersHook hook) external`** (`src/CTDeployer.sol`) — only `PROJECTS.ownerOf(hook.projectId())`. Revokes the deployer-scoped permissions previously granted to the caller (empty `permissionIds` array), then calls `JBOwnable(hook).transferOwnershipToProject(projectId)`. After this point `JBOwnable(hook).owner()` resolves to `PROJECTS.ownerOf(projectId)` dynamically.
  - **Invariants:** B.4.1, B.4.2, B.4.3.

### Data-hook callbacks (terminal-only by use)

- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context) external view → (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply, uint256 surplusValue, JBCashOutHookSpecification[])`** (`src/CTDeployer.sol`) — if `SUCKER_REGISTRY.isSuckerOf(projectId, holder)`, returns `(0, context.cashOutCount, context.totalSupply, context.surplus.value, [])` — sucker holders pay no cash-out tax. Otherwise delegates to `dataHookOf[projectId]` if non-zero; else passes through the original context values.
  - **Invariants:** D.4 (suckers get 0% tax), D.5 (delegation).
- **`beforePayRecordedWith(JBBeforePayRecordedContext calldata context) external view → (uint256 weight, JBPayHookSpecification[])`** (`src/CTDeployer.sol`) — delegates to `dataHookOf[projectId]` if non-zero; else returns `(context.weight, [])`. The data hook for Croptop-deployed projects is the 721 hook, so tier-mint logic runs.
- **`hasMintPermissionFor(uint256 projectId, JBRuleset, address addr) external view → bool`** (`src/CTDeployer.sol`) — returns true iff `SUCKER_REGISTRY.isSuckerOf(projectId, addr)`. No other address (including the operator) gets mint permission through this hook.
  - **Invariants:** D.6.

### ERC-721 receiver

- **`onERC721Received(address, address from, uint256, bytes) external view → bytes4`** (`src/CTDeployer.sol`) — accepts only mints from `PROJECTS` (`msg.sender == PROJECTS` AND `from == address(0)`). Rejects any other transfer. This is the SOLE way for a project NFT to land here; the launch flow then transfers it onward to the project owner.

### Views

- **`supportsInterface(bytes4 interfaceId) public view → bool`** (`src/CTDeployer.sol`) — `ICTDeployer`, `IJBRulesetDataHook`, `IERC721Receiver`.
- **Immutable getters:** `DEPLOYER`, `PROJECTS`, `PUBLISHER`, `SUCKER_REGISTRY`; plus `dataHookOf(uint256)` storage getter.

### Internal helpers

- **`_configurePostingCriteriaFor(address hook, CTDeployerAllowedPost[] allowedPosts)`** (`src/CTDeployer.sol`) — repacks each `CTDeployerAllowedPost` (no `hook` field) into `CTAllowedPost` (with the `hook` field filled), then calls `PUBLISHER.configurePostingCriteriaFor`. Because the call is from `CTDeployer` which OWNS the hook at this point, `JBOwnable(hook).owner() == CTDeployer` and `CTPublisher`'s `_requirePermissionFrom` check resolves against `CTDeployer`'s own permission table (where the constructor self-granted `ADJUST_721_TIERS` wildcard for the publisher).
- **`_requireExplicitSuckerPeerPermissionFrom(address account, uint256 projectId, CTSuckerDeploymentConfig)` view** (`src/CTDeployer.sol`) — iterates `deployerConfigurations`; if ANY `peer != 0`, calls `_requirePermissionFrom(account, projectId, SET_SUCKER_PEER)` and returns. Mirrors the sucker registry's own direct-caller check against the ORIGINAL project authority (not against `CTDeployer` itself).

## C.3 `CTProjectOwner` — `src/CTProjectOwner.sol`

### Constructor (one-shot, immutable wiring)

- **`constructor(IJBPermissions permissions, IJBProjects projects, ICTPublisher publisher)`** (`src/CTProjectOwner.sol`) — sets immutables. NO permission self-grant, no ownership transfer, no other state.

### ERC-721 receiver (the only mutating entrypoint)

- **`onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external → bytes4`** (`src/CTProjectOwner.sol`) — only accepts transfers from `PROJECTS` (bare `revert()` otherwise). Calls `PERMISSIONS.setPermissionsFor` to grant `CTPublisher` `ADJUST_721_TIERS` for `projectId = tokenId` on `CTProjectOwner`'s own permission table. Returns the ERC-721 receiver magic value.
  - **Invariants:** E.1 (one-way / no transfer-out), E.2 (publisher gets posting permission).

### Views

- **Immutable getters:** `PERMISSIONS`, `PROJECTS`, `PUBLISHER`. NO operation other than `onERC721Received` mutates state. `CTProjectOwner` has NO `transferOwnership`, `safeTransferFrom`, `approve`, or `setApprovalForAll` — the project NFT is permanently lodged here once received.

---

# Section D — Cross-Cutting Invariants

- **D.1 Tier-per-post creation.** Each new post produces exactly one new `JB721TierConfig` (price = poster's price, supply = poster's supply, splits = poster's splits, all `flags` fixed to non-privileged values, `allowOwnerMint=false`). The hook receives them sorted by ascending category, satisfying the 721 store's `InvalidCategorySortOrder` constraint without exposing that ordering quirk to the caller. (`src/CTPublisher.sol`.)
- **D.2 Launch-time hook-permission grant to the project owner.** `CTDeployer.deployProjectFor` grants the `owner` parameter four direct-on-hook permissions (`ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT`) on the deployer's own permission table for the duration of the deployer-owned-hook window (`src/CTDeployer.sol`). The documented trade-off: until `claimCollectionOwnershipOf` is called, the project owner can bypass `CTPublisher` to directly modify the collection. Once claimed, the deployer-scoped grants are revoked (`src/CTDeployer.sol`).
- **D.3 `dataHookOf[projectId]` is one-shot and stores the 721 hook itself.** Set inside `deployProjectFor` to the freshly-deployed 721 hook (`src/CTDeployer.sol`); no setter exists for callers to replace it. The runtime ruleset's `dataHook` slot is `CTDeployer` itself, so terminal payments / cash-outs first hit `CTDeployer.before*RecordedWith`, which then delegates to `dataHookOf[projectId]` (the 721 hook).
- **D.4 Suckers get 0% cash-out tax.** `CTDeployer.beforeCashOutRecordedWith` short-circuits to `cashOutTaxRate = 0` when `SUCKER_REGISTRY.isSuckerOf(projectId, holder)` — bridge accounting stays loss-less (`src/CTDeployer.sol`). Local supply/surplus are passed through unmodified — the sucker branch deliberately does NOT aggregate remote totals here (the sucker prepares against LOCAL backing only; see `../INVARIANTS.md` Section D2 for the cross-chain arbitrage model).
- **D.5 Non-sucker cash-out delegates to the 721 hook.** When the holder is not a sucker AND `dataHookOf[projectId]` is set, the call forwards to the 721 hook's own `beforeCashOutRecordedWith` (`src/CTDeployer.sol`). Croptop adds no tax of its own to user cash-outs.
- **D.6 `hasMintPermissionFor` returns true ONLY for registered suckers.** `CTDeployer.hasMintPermissionFor` does not delegate, does not grant to operators, does not grant to the publisher (`src/CTDeployer.sol`). Mint-on-demand authority through the ruleset's data hook is reserved for bridge-claim flows.
- **D.7 Fee project credit on every fee-paying mint when the fee terminal is available.** `CTPublisher.mintFrom` calls the fee project's primary terminal for the selected `token` with `beneficiary: feeBeneficiary` when that terminal exists and accepts the payment — the fee beneficiary receives the fee project's tokens at the fee project's current weight, NOT the originating revnet's tokens (`src/CTPublisher.sol`). If that path is unavailable, the fee is refunded to the caller.
- **D.8 No silent payment loss.** Four independent guards: (a) insufficient-funds checks revert pre-pay (A.3.2); (b) ERC-20 terminal allowances must be fully consumed; (c) `payValue` is recomputed from `amount - payValue` after the project call (so reentrancy / force-sent funds can't redirect the fee — A.3.7); (d) failed or missing fee payment refunds the caller, and native refund failure reverts the whole tx (A.3.5). The only "loss" path is the dust from `totalPrice / FEE_DIVISOR` integer truncation, which is in the caller's favor (`src/CTPublisher.sol`).
- **D.9 ERC-2771 trusted-forwarder support.** `CTPublisher` and `CTDeployer` both inherit `ERC2771Context` with a constructor-supplied forwarder; all `_msgSender()` usages flow through the standard OZ trampoline (`src/CTPublisher.sol`, `src/CTDeployer.sol`). Meta-tx senders are authenticated as the original signer. Critically, this affects every permission check (`_requirePermissionFrom`) and every allowlist check (`_isAllowed`).
- **D.10 Sucker explicit-peer permission is checked against the ORIGINAL project owner, not against `CTDeployer`.** Both the launch-time path (during `deployProjectFor`, against the intended `owner` arg before the NFT transfer) and the post-launch path (`deploySuckersFor`, against `PROJECTS.ownerOf(projectId)`) call `_requireExplicitSuckerPeerPermissionFrom` against the legitimate authority. Without this mirror-check, `DEPLOY_SUCKERS` alone could be smuggled into setting non-default peers via the deployer wrapper (`src/CTDeployer.sol`).

---

# Section E — Centralization Caveats

These are powers held by privileged addresses outside any individual minter/poster's control. They are NOT third-party attack vectors but should be understood by integrators.

- **E.1 `CTProjectOwner` has NO transfer-out path.** Once a project NFT lands here via `onERC721Received`, it is permanently stuck — there is no `transferOwnership`, `safeTransferFrom`, `approve`, or escape hatch (`src/CTProjectOwner.sol`). Project ownership is effectively burned, replaced by an auto-grant of `ADJUST_721_TIERS` to `CTPublisher`. This is intentional: it lets a project run "headless" with Croptop as the sole tier-management surface, while the project NFT can never be transferred to a malicious new owner who would reroute splits, swap terminals, or queue new rulesets. **Operators who transfer to `CTProjectOwner` SHOULD configure all posting criteria BEFORE the transfer**, because afterwards only the publisher has tier authority and no entity has owner-tier project authority (no `LAUNCH_RULESETS`, no `SET_PROJECT_URI`, no `SET_TERMINALS`, no `MIGRATE_CONTROLLER`).
- **E.2 `CTDeployer` is its own one-shot setter authority.** The constructor self-grants `ADJUST_721_TIERS` (wildcard project ID) to `CTPublisher` on the deployer's own permission table (`src/CTDeployer.sol`). There is NO setter to revoke or rewire this. Any project that uses `CTDeployer` to launch will have its hook posting governed by this exact publisher address for the entire deployer-owned-hook window. The publisher address is captured at constructor time as immutable `PUBLISHER`.
- **E.3 `CTDeployer` deployer-scoped grants persist until claimed.** A project's `owner` retains the four direct-hook permissions (D.2) on `CTDeployer`'s permission table until they call `claimCollectionOwnershipOf`. If they never call it, those grants are stable. If they DO call it, only their OWN row is cleared — any prior owner of the project NFT who held the same grants is NOT automatically revoked. In practice, the project NFT is transferred to the intended owner at the end of `deployProjectFor`, so the only entity who ever held these grants on the deployer's table is the original launch-time `owner`. **A subsequent transfer of the project NFT to a third party does not propagate those grants** (the third party gets the dynamic `JBOwnable(hook).owner() == PROJECTS.ownerOf(projectId)` path post-claim, but if claim has not yet happened, the third party needs to either ask the original owner to call claim or accept that the hook is still owned by `CTDeployer`).
- **E.4 `CTPublisher.FEE_PROJECT_ID` is immutable.** Set at constructor time, never mutable (`src/CTPublisher.sol`). If the configured fee project is misconfigured for the selected payment token at the time of a mint, A.3.5 refunds the caller — the protocol fee for that mint is effectively waived. There is no upgrade or migration path.
- **E.5 The 721 hook deployer is trusted.** `CTDeployer.DEPLOYER` is `IJB721TiersHookDeployer` and is immutable. A compromised hook deployer could ship a malicious hook implementation, which would then be wired as `dataHookOf[projectId]` and called on every payment/cashout. This is the same trust posture as `JBOmnichainDeployer` and `REVDeployer` in the broader V6 system — see `../INVARIANTS.md` Section E.
- **E.6 The sucker registry is trusted.** `CTDeployer.SUCKER_REGISTRY` is `IJBSuckerRegistry` and is immutable. `isSuckerOf` checks during `beforeCashOutRecordedWith` and `hasMintPermissionFor` determine whether a caller gets 0% tax and unconditional mint authority. A compromised registry could fraudulently classify an attacker as a sucker. Same trust posture as the rest of V6.

---

# Section F — Key Code References

| Invariant | File |
|---|---|
| A.1.1 (allowlist-empty implies open posting) | `src/CTPublisher.sol` |
| A.1.2 (four per-category bounds) | `src/CTPublisher.sol` |
| A.1.3 (unconfigured category reverts) | `src/CTPublisher.sol` |
| A.1.4 (empty posts reverts) | `src/CTPublisher.sol` |
| A.2.1 (within-batch duplicate URI) | `src/CTPublisher.sol` |
| A.2.2 (empty URI rejected) | `src/CTPublisher.sol` |
| A.2.3 (cross-batch reuses cached tier, cached price) | `src/CTPublisher.sol` |
| A.2.4 (stale cache invalidation) | `src/CTPublisher.sol` |
| A.3.1 (5% fee on converted totalPrice) | `src/CTPublisher.sol` |
| A.3.2 (insufficient amount) | `src/CTPublisher.sol` |
| A.3.4 (fee-project self-skip) | `src/CTPublisher.sol` |
| A.3.5 (failed or missing fee refund) | `src/CTPublisher.sol` |
| A.3.6 (feeBeneficiary != 0) | `src/CTPublisher.sol` |
| A.3.7 (post-call fee math via amount - payValue) | `src/CTPublisher.sol` |
| A.3.8 (project payment must mint NFTs) | `src/CTPublisher.sol` |
| A.3.9 (Permit2 ERC-20 pull) | `src/CTPublisher.sol` |
| A.4.1 (caller can't include pay-purpose metadata) | `src/CTPublisher.sol` |
| A.4.2 (Croptop's canonical pay metadata) | `src/CTPublisher.sol` |
| A.5.1 (category sort + post-index lockstep) | `src/CTPublisher.sol` |
| B.1.1 (configurePostingCriteriaFor permission gate) | `src/CTPublisher.sol` |
| B.1.2 (per-call replacement) | `src/CTPublisher.sol` |
| B.1.3 (minimumTotalSupply != 0) | `src/CTPublisher.sol` |
| B.1.4 (min ≤ max when max != 0) | `src/CTPublisher.sol` |
| B.1.5 (no full-disable, only restriction) | `src/CTPublisher.sol` |
| B.4.1 (claim is owner-only) | `src/CTDeployer.sol` |
| B.4.2 (claim atomic: revoke + transferOwnershipToProject) | `src/CTDeployer.sol` |
| D.1 (tier-per-post fixed flags) | `src/CTPublisher.sol` |
| D.2 (launch grants four hook permissions to owner) | `src/CTDeployer.sol` |
| D.3 (dataHookOf set inside deployProjectFor) | `src/CTDeployer.sol` |
| D.4 (suckers get 0% cash-out tax) | `src/CTDeployer.sol` |
| D.5 (non-sucker delegates to dataHookOf) | `src/CTDeployer.sol` |
| D.6 (hasMintPermissionFor sucker-only) | `src/CTDeployer.sol` |
| D.7 (fee project credit) | `src/CTPublisher.sol` |
| D.9 (ERC-2771 sender resolution) | `src/CTPublisher.sol`, `src/CTDeployer.sol` |
| D.10 (explicit-peer check vs original owner) | `src/CTDeployer.sol` |
| E.1 (`CTProjectOwner` no transfer-out, only `onERC721Received`) | `src/CTProjectOwner.sol` |
| E.2 (`CTDeployer` constructor self-grant to `CTPublisher`) | `src/CTDeployer.sol` |
| E.3 (deployer-scoped grants persist until claim) | `src/CTDeployer.sol` |
| E.4 (FEE_PROJECT_ID immutable) | `src/CTPublisher.sol` |
