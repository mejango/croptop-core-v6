# croptop-core-v6 -- User Journeys

Complete user path documentation for auditors. Each journey describes the entry point, parameters, state changes, external calls, and edge cases.

---

## Journey 1: Deploy a Croptop Project

**Actor:** Project creator
**Entry point:** `CTDeployer.deployProjectFor(owner, projectConfig, suckerDeploymentConfiguration, controller)`
**Source:** `src/CTDeployer.sol` lines 241-342

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `owner` | `address` | Final owner of the project NFT after deployment |
| `projectConfig` | `CTProjectConfig` | Name, symbol, URIs, terminal configs, allowed posts, salt |
| `suckerDeploymentConfiguration` | `CTSuckerDeploymentConfig` | Cross-chain sucker deployer configs + salt (set salt to `bytes32(0)` to skip) |
| `controller` | `IJBController` | The JB controller that will manage the project |

### Execution Flow

1. **Controller validation** (line 251): Reverts if `controller.PROJECTS() != PROJECTS`.

2. **Ruleset configuration** (lines 253-288):
   - Weight: `1_000_000 * 10^18`
   - Base currency: ETH
   - Cash-out tax rate: `MAX_CASH_OUT_TAX_RATE` (100%)
   - Data hook: `address(this)` (CTDeployer)
   - `useDataHookForPay = true`, `useDataHookForCashOut = true`

3. **Project ID prediction** (line 258): `projectId = PROJECTS.count() + 1`

4. **Hook deployment** (lines 262-283):
   ```
   DEPLOYER.deployHookFor(projectId, config, salt)
   ```
   - Salt: `keccak256(abi.encode(projectConfig.salt, _msgSender()))`
   - Deployed with empty tiers, ETH currency, 18 decimals
   - No reserves, no votes, no owner minting, no overspend prevention

5. **Project launch** (lines 291-300):
   ```
   controller.launchProjectFor(owner: address(this), ...)
   ```
   - CTDeployer receives the project NFT temporarily
   - `assert(projectId == returned ID)` -- reverts on mismatch (front-running protection)

6. **Data hook registration** (line 303):
   ```
   dataHookOf[projectId] = IJBRulesetDataHook(hook)
   ```
   This is write-once. No setter exists.

7. **Posting criteria** (lines 306-308): If `projectConfig.allowedPosts.length > 0`, calls internal `_configurePostingCriteriaFor()` which formats `CTDeployerAllowedPost` into `CTAllowedPost` (adding the hook address) and delegates to `PUBLISHER.configurePostingCriteriaFor()`.

8. **Sucker deployment** (lines 314-321): If `suckerDeploymentConfiguration.salt != bytes32(0)`:
   ```
   SUCKER_REGISTRY.deploySuckersFor(projectId, salt, configurations)
   ```

9. **Ownership transfer** (line 324):
   ```
   PROJECTS.transferFrom(address(this), owner, projectId)
   ```

10. **Permission grants** (lines 327-341): Grants `owner` four permissions from CTDeployer's account:
    - `ADJUST_721_TIERS`
    - `SET_721_METADATA`
    - `MINT_721`
    - `SET_721_DISCOUNT_PERCENT`

### State Changes

| Storage | Change |
|---------|--------|
| `CTDeployer.dataHookOf[projectId]` | Set to the deployed hook address (permanent) |
| `JBProjects` (ERC-721) | New token minted, transferred from CTDeployer to `owner` |
| `JBPermissions` | 5 permission entries set (1 for sucker registry, 1 for publisher, 4 for owner) |
| `CTPublisher._packedAllowanceFor` | Set for each allowed post category (if any) |
| `CTPublisher._allowedAddresses` | Set for each allowed post category with allowlists (if any) |

### Edge Cases

- **Front-running:** If another project is created between `PROJECTS.count()` and `launchProjectFor()`, the `assert` fails and the transaction reverts. No funds are lost.
- **`owner = address(0)`:** The project NFT transfer to `address(0)` would revert (ERC-721 constraint). The deployment fails.
- **`owner` is a contract without `onERC721Received`:** The `transferFrom` (not `safeTransferFrom`) succeeds even if the owner cannot handle ERC-721s. The project NFT could become stuck.
- **Sucker deployment failure:** If `deploySuckersFor` reverts, the entire deployment reverts. The sucker deployer uses a try-catch cascade internally, but registry-level reverts propagate.
- **Empty `terminalConfigurations`:** The project launches with no terminals. Payments and cash-outs are not possible until terminals are added separately.
- **Salt collision:** If `keccak256(abi.encode(salt, _msgSender()))` collides with a previously deployed hook, `DEPLOYER.deployHookFor()` reverts (Create2 collision).

---

## Journey 2: Post Content (Mint NFTs)

**Actor:** Content poster (any address, or allowlisted address)
**Entry point:** `CTPublisher.mintFrom(hook, posts, nftBeneficiary, feeBeneficiary, additionalPayMetadata, feeMetadata)`
**Source:** `src/CTPublisher.sol` lines 307-420
**Value:** Must send `msg.value >= sum(tier prices) + 5% fee`

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `hook` | `IJB721TiersHook` | The 721 hook to post to |
| `posts` | `CTPost[]` | Array of posts (URI, supply, price, category, splits) |
| `nftBeneficiary` | `address` | Receives the minted NFTs |
| `feeBeneficiary` | `address` | Receives fee project tokens |
| `additionalPayMetadata` | `bytes` | Extra metadata appended to the payment |
| `feeMetadata` | `bytes` | Metadata sent with the fee payment |

### Execution Flow

**Phase 1: Validation and setup** (`_setupPosts`, lines 432-579)

For each post in the batch:

1. **URI check:** `encodedIPFSUri != bytes32("")` or revert `CTPublisher_EmptyEncodedIPFSUri`
2. **Duplicate check:** O(i) scan against all prior posts. Revert `CTPublisher_DuplicatePost` on match.
3. **Existing tier lookup:** Check `tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]`
   - **Tier exists and live:** Reuse tier ID. Accumulate `store.tierOf().price`.
   - **Tier exists but removed:** Delete mapping. Fall through to new tier.
   - **No tier:** Validate against category allowance, create `JB721TierConfig`.

**Phase 2: Fee calculation** (lines 333-344)

```
fee = totalPrice / FEE_DIVISOR   (integer division)
payValue = msg.value - fee       (if projectId != FEE_PROJECT_ID)
require(totalPrice <= payValue)
```

**Phase 3: Tier creation** (line 348)

```
hook.adjustTiers(tiersToAdd, [])
```

**Phase 4: Metadata construction** (lines 356-367)

Build JBMetadataResolver-compatible metadata with tier IDs and referral ID.

**Phase 5: Project payment** (lines 388-396)

```
projectTerminal.pay{value: payValue}(projectId, NATIVE_TOKEN, payValue, nftBeneficiary, 0, "Minted from Croptop", mintMetadata)
```

**Phase 6: Fee payment** (lines 403-418)

```
if (address(this).balance != 0) {
    feeTerminal.pay{value: address(this).balance}(FEE_PROJECT_ID, ...)
}
```

### State Changes

| Storage | Change |
|---------|--------|
| `CTPublisher.tierIdForEncodedIPFSUriOf[hook][uri]` | Set for each new tier created |
| `CTPublisher.tierIdForEncodedIPFSUriOf[hook][uri]` | Deleted if stale mapping detected (removed tier) |
| `JB721TiersHookStore` (external) | New tiers added via `adjustTiers` |
| Project terminal (external) | Balance increased by `payValue` |
| Fee project terminal (external) | Balance increased by fee amount |

### Edge Cases

- **Empty posts array:** `_setupPosts` returns with `totalPrice = 0`, `tiersToAdd` and `tierIdsToMint` both empty. `adjustTiers` is called with an empty array (no-op). The project terminal receives `msg.value` (no fee deducted since `totalPrice / 20 = 0`). The fee terminal receives nothing.
- **All posts reuse existing tiers:** No new tiers are created. `tiersToAdd` is resized to length 0 via assembly. `adjustTiers` is a no-op. Fees are calculated from on-chain tier prices.
- **Mixed new and existing tiers:** `tiersToAdd` is resized via assembly to contain only new tiers. `tierIdsToMint` contains a mix of new and existing IDs.
- **`msg.value` exceeds required amount:** Excess ETH is sent to the fee project (via `address(this).balance`). The poster overpays the fee project.
- **`msg.value` is exactly right:** `address(this).balance` after the project payment equals the fee. Fee project receives the correct amount.
- **`projectId == FEE_PROJECT_ID`:** No fee is deducted. Full `msg.value` goes to the project terminal. `address(this).balance` is 0 after the project payment (no fee payment occurs).
- **Tier price is 0:** Posting criteria allow `minimumPrice = 0`. A post with `price = 0` creates a free tier. Fee on a free tier is 0. The poster sends 0 ETH (or only ETH for other posts in the batch).
- **`nftBeneficiary = address(0)`:** The terminal payment may succeed (depending on terminal implementation), but the NFTs would be minted to `address(0)`, effectively burning them.
- **`hook.adjustTiers()` reverts:** The entire transaction reverts. No state changes are committed. The poster's ETH is returned.
- **Terminal payment reverts:** The entire transaction reverts. The `adjustTiers` state change is also rolled back.
- **Fee terminal payment reverts:** This occurs after the project payment has already succeeded. If the fee terminal reverts, the entire transaction reverts, undoing the project payment too.
- **Batch with posts in different categories:** Each post is validated against its own category's allowance independently. A batch can contain posts in multiple categories.
- **Re-posting a removed tier's URI:** The stale mapping is cleared and a new tier is created. The new tier may have different price/supply/splits than the original.

---

## Journey 3: Configure Posting Criteria (Allowlist Setup)

**Actor:** Hook owner (or permissioned delegate)
**Entry point:** `CTPublisher.configurePostingCriteriaFor(allowedPosts)`
**Source:** `src/CTPublisher.sol` lines 240-295

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `allowedPosts` | `CTAllowedPost[]` | Array of per-category posting rules |

Each `CTAllowedPost` contains:

| Field | Type | Constraints |
|-------|------|-------------|
| `hook` | `address` | Must be a JBOwnable + IJB721TiersHook |
| `category` | `uint24` | 0 to 16,777,215 |
| `minimumPrice` | `uint104` | Must fit in 104 bits |
| `minimumTotalSupply` | `uint32` | Must be > 0 |
| `maximumTotalSupply` | `uint32` | Must be >= `minimumTotalSupply` |
| `maximumSplitPercent` | `uint32` | 0 = splits disabled, up to `SPLITS_TOTAL_PERCENT` (1,000,000,000) |
| `allowedAddresses` | `address[]` | Empty = permissionless, non-empty = restricted |

### Execution Flow

For each `CTAllowedPost` in the array:

1. **Emit event** (line 249): `ConfigurePostingCriteria(hook, allowedPost, caller)`

2. **Permission check** (lines 253-257):
   ```
   _requirePermissionFrom(
       account: JBOwnable(hook).owner(),
       projectId: IJB721TiersHook(hook).PROJECT_ID(),
       permissionId: JBPermissionIds.ADJUST_721_TIERS
   )
   ```

3. **Validation:**
   - `minimumTotalSupply > 0` or revert `CTPublisher_ZeroTotalSupply` (line 260)
   - `minimumTotalSupply <= maximumTotalSupply` or revert `CTPublisher_MaxTotalSupplyLessThanMin` (line 265)

4. **Pack and store** (lines 271-281):
   ```
   packed = minimumPrice | (minimumTotalSupply << 104) | (maximumTotalSupply << 136) | (maximumSplitPercent << 168)
   _packedAllowanceFor[hook][category] = packed
   ```

5. **Allowlist storage** (lines 284-293):
   ```
   delete _allowedAddresses[hook][category]
   for each address in allowedAddresses:
       _allowedAddresses[hook][category].push(address)
   ```

### State Changes

| Storage | Change |
|---------|--------|
| `_packedAllowanceFor[hook][category]` | Overwritten with new packed values |
| `_allowedAddresses[hook][category]` | Deleted and repopulated |

### Edge Cases

- **Overwriting existing criteria:** The entire packed value and allowlist are replaced. There is no merge or append behavior.
- **Multiple categories in one call:** Each `CTAllowedPost` can target a different hook/category pair. A single call can configure multiple categories across multiple hooks (provided the caller has permission for each).
- **Same category twice in one call:** The second entry overwrites the first. No duplicate check on the input array.
- **`maximumSplitPercent = 0`:** Splits are disabled. Any post with `splitPercent > 0` will revert with `CTPublisher_SplitPercentExceedsMaximum`.
- **`maximumTotalSupply = type(uint32).max`:** Effectively unlimited supply (4,294,967,295).
- **Large allowlist:** Stored via a push loop. A 1,000-address allowlist costs approximately 20M gas for the SSTORE operations. A 10,000-address list is infeasible in a single transaction.
- **Empty allowlist after previously non-empty:** `delete _allowedAddresses[hook][category]` clears the array. Posting becomes permissionless for that category.
- **Cannot disable category:** There is no way to set `minimumTotalSupply = 0` (it reverts). To effectively disable a category, set `minimumPrice = type(uint104).max` and `minimumTotalSupply = maximumTotalSupply = 1`. This makes posting economically infeasible.
- **Permission check uses `hook.owner()`:** If hook ownership has been transferred (e.g., to the project via `claimCollectionOwnershipOf`), the new owner (or their delegate) must call this function.
- **ERC2771 context:** `_msgSender()` is used for the permission check. If a trusted forwarder relays the call, the original sender (appended to calldata) is checked against permissions.

---

## Journey 4: Collect Posting Fees

**Actor:** Passive (fee project). Fees are collected automatically during `mintFrom()`.
**Entry point:** Triggered within `CTPublisher.mintFrom()` at lines 403-418
**Beneficiary:** The project with ID `FEE_PROJECT_ID` (immutable, set at construction)

### Fee Calculation

```
totalPrice = sum of all post prices in the batch
    (on-chain tier price for existing tiers, post.price for new tiers)

fee = totalPrice / FEE_DIVISOR       (FEE_DIVISOR = 20, so fee = 5%)
payValue = msg.value - fee            (deducted before project payment)
```

### Fee Routing

After the project payment completes:

```solidity
if (address(this).balance != 0) {
    IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf(FEE_PROJECT_ID, NATIVE_TOKEN);
    feeTerminal.pay{value: address(this).balance}({
        projectId: FEE_PROJECT_ID,
        amount: address(this).balance,
        token: NATIVE_TOKEN,
        beneficiary: feeBeneficiary,
        minReturnedTokens: 0,
        memo: "",
        metadata: feeMetadata
    });
}
```

### Fee Project Token Distribution

The `feeBeneficiary` parameter in `mintFrom()` determines who receives the fee project's tokens minted from the fee payment. The `feeMetadata` parameter allows the caller to pass arbitrary metadata to the fee payment (e.g., for data hooks on the fee project).

### Fee Accounting Details

| Scenario | Fee Behavior |
|----------|-------------|
| Normal mint (1 post, 1 ETH price) | `fee = 1 ether / 20 = 0.05 ether`. Poster sends >= 1.05 ETH. |
| Batch mint (3 posts, 1 ETH each) | `fee = 3 ether / 20 = 0.15 ether`. Poster sends >= 3.15 ETH. |
| Existing tier reuse (1 ETH on-chain price) | Fee uses on-chain price, not `post.price`. `fee = 1 ether / 20`. |
| Free tier (price = 0) | `fee = 0 / 20 = 0`. No fee payment occurs. |
| `projectId == FEE_PROJECT_ID` | Fee deduction skipped entirely. Full `msg.value` goes to project. |
| `msg.value` exceeds requirement | Excess goes to fee project. Poster overpays. |
| Dust from integer division | Up to 19 wei lost per tx. Fee project receives slightly less. |

### Edge Cases

- **Fee project has no primary terminal:** `DIRECTORY.primaryTerminalOf()` returns `address(0)`. The `pay()` call to address(0) reverts. The entire `mintFrom()` transaction reverts (including the project payment).
- **Fee terminal reverts:** Same as above -- entire `mintFrom()` reverts. No state changes persist.
- **`address(this).balance == 0` after project payment:** This happens when `fee == 0` (e.g., `totalPrice < FEE_DIVISOR` or `projectId == FEE_PROJECT_ID`). The fee payment is skipped entirely.
- **Force-sent ETH (via `selfdestruct`):** If ETH was force-sent to CTPublisher before the `mintFrom()` call, it is included in `address(this).balance` and routed to the fee project. CTPublisher has no `receive()` or `fallback()`, so normal sends revert. Only `selfdestruct` (deprecated post-Dencun) can force-send ETH.

---

## Journey 5: Deploy a Croptop Project via CTDeployer with Posting Criteria

**Actor:** Project creator
**Entry point:** `CTDeployer.deployProjectFor()` with non-empty `projectConfig.allowedPosts`
**Source:** `src/CTDeployer.sol` lines 241-342, internal `_configurePostingCriteriaFor()` at lines 376-405

This is an extension of Journey 1 that details the posting criteria configuration during deployment.

### Posting Criteria Flow

1. CTDeployer receives `CTDeployerAllowedPost[]` (which omits the `hook` field, since the hook hasn't been deployed yet).
2. After the hook is deployed, `_configurePostingCriteriaFor()` converts each `CTDeployerAllowedPost` to a `CTAllowedPost` by injecting `hook: address(hook)` (lines 392-400).
3. Calls `PUBLISHER.configurePostingCriteriaFor(formattedAllowedPosts)` (line 404).
4. The publisher validates each entry (supply bounds, permissions) and stores the packed allowances and allowlists.

### Permission Flow

The `PUBLISHER.configurePostingCriteriaFor()` call checks `ADJUST_721_TIERS` permission from `JBOwnable(hook).owner()`. At this point in the deployment:

- The hook was deployed by `DEPLOYER.deployHookFor()` on behalf of CTDeployer
- Hook ownership is set to CTDeployer (the deployer is the effective owner after deployment)
- The permission check passes because CTDeployer is both the caller and the hook owner (or has wildcard permission)

After the deployment completes and ownership is transferred to `owner`, only the new owner (or their delegate) can reconfigure posting criteria.

### Edge Cases

- **Empty `allowedPosts`:** The `_configurePostingCriteriaFor()` call is skipped (line 306 condition). The project has no posting categories configured. Content cannot be posted until the owner configures criteria manually.
- **Invalid criteria in deployment:** If any `CTDeployerAllowedPost` has `minimumTotalSupply == 0` or `minimumTotalSupply > maximumTotalSupply`, the publisher reverts, and the entire deployment fails.

---

## Journey 6: Lock Project Ownership (Burn-Lock)

**Actor:** Project owner
**Entry point:** `IERC721(PROJECTS).safeTransferFrom(owner, address(ctProjectOwner), projectId)`
**Source:** `src/CTProjectOwner.sol` lines 47-80

### Execution Flow

1. The project owner calls `safeTransferFrom` on the JBProjects ERC-721 contract, transferring their project NFT to the CTProjectOwner contract.
2. The ERC-721 contract calls `CTProjectOwner.onERC721Received()`.
3. **Validation** (line 62): `msg.sender == address(PROJECTS)` -- only accepts tokens from the JBProjects contract.
4. **Permission grant** (lines 65-77):
   ```
   PERMISSIONS.setPermissionsFor(
       account: address(this),
       permissionsData: JBPermissionsData({
           operator: address(PUBLISHER),
           projectId: uint64(tokenId),
           permissionIds: [ADJUST_721_TIERS]
       })
   )
   ```
5. Returns `IERC721Receiver.onERC721Received.selector`.

### State Changes

| Storage | Change |
|---------|--------|
| `JBProjects` (ERC-721) | Token transferred from owner to CTProjectOwner |
| `JBPermissions` | CTPublisher granted `ADJUST_721_TIERS` for this project from CTProjectOwner |

### Consequences

- The project NFT is now held by CTProjectOwner. Since CTProjectOwner has no transfer function, ownership is effectively burned.
- CTPublisher can still adjust tiers (post content) because it has `ADJUST_721_TIERS` permission.
- The project owner can no longer change rulesets, add terminals, or perform any owner-only operations.
- This is irreversible. There is no recovery mechanism.

### Edge Cases

- **`from != address(0)`:** Unlike CTDeployer, CTProjectOwner does NOT check `from != address(0)`. It accepts both mints and transfers. Any project holder can transfer their project to CTProjectOwner.
- **`tokenId` truncation:** The `uint64(tokenId)` cast truncates if `tokenId > type(uint64).max`. For realistic sequential project IDs, this is not a concern.
- **Transfer vs. `safeTransferFrom`:** Only `safeTransferFrom` triggers `onERC721Received`. A raw `transferFrom` would transfer the NFT without granting the publisher permission, leaving the project locked without posting capability.
- **Double transfer:** If two different project NFTs are transferred to CTProjectOwner, each gets its own scoped permission. The contract can hold multiple projects simultaneously.
- **Accidental transfer:** There is no confirmation, cooling period, or undo. A user who accidentally sends their project NFT to CTProjectOwner loses ownership permanently.

---

## Journey 7: Claim Hook Collection Ownership

**Actor:** Project owner
**Entry point:** `CTDeployer.claimCollectionOwnershipOf(hook)`
**Source:** `src/CTDeployer.sol` lines 221-232

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `hook` | `IJB721TiersHook` | The 721 hook to claim ownership of |

### Execution Flow

1. **Read project ID** (line 223): `projectId = hook.PROJECT_ID()`
2. **Owner check** (lines 226-228): `PROJECTS.ownerOf(projectId) == _msgSender()` or revert `CTDeployer_NotOwnerOfProject`
3. **Transfer ownership** (line 231):
   ```
   JBOwnable(address(hook)).transferOwnershipToProject(projectId)
   ```

### State Changes

| Storage | Change |
|---------|--------|
| Hook's JBOwnable storage | Owner changed from CTDeployer to the project (ownership tied to project NFT) |

### Consequences

After claiming, the hook's ownership follows the project NFT. Whoever owns the project NFT can call owner-only functions on the hook (tier adjustments, metadata changes, etc.) directly, without going through CTDeployer.

### Edge Cases

- **Already claimed:** If hook ownership has already been transferred, `transferOwnershipToProject` may revert (depending on JBOwnable implementation). CTDeployer is no longer the owner.
- **Project transferred after deployment:** If the project was sold or transferred, the new owner can claim the hook. The original deployer cannot.
- **Hook not deployed by CTDeployer:** If the `hook` was deployed independently, `JBOwnable(hook).transferOwnershipToProject()` will revert because CTDeployer is not the owner.

---

## Journey 8: Deploy Suckers for Existing Project

**Actor:** Project owner (or permissioned delegate)
**Entry point:** `CTDeployer.deploySuckersFor(projectId, suckerDeploymentConfiguration)`
**Source:** `src/CTDeployer.sol` lines 348-367

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | `uint256` | The project to deploy suckers for |
| `suckerDeploymentConfiguration` | `CTSuckerDeploymentConfig` | Deployer configs + salt |

### Execution Flow

1. **Permission check** (lines 356-358):
   ```
   _requirePermissionFrom(
       account: PROJECTS.ownerOf(projectId),
       projectId: projectId,
       permissionId: JBPermissionIds.DEPLOY_SUCKERS
   )
   ```

2. **Sucker deployment** (lines 362-366):
   ```
   suckers = SUCKER_REGISTRY.deploySuckersFor(
       projectId,
       keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
       suckerDeploymentConfiguration.deployerConfigurations
   )
   ```

### State Changes

| Storage | Change |
|---------|--------|
| Sucker Registry | New suckers registered for the project |
| Deployed sucker contracts | New contracts deployed via Create2 |

### Edge Cases

- **Permission not granted:** Reverts. The project owner must explicitly grant `DEPLOY_SUCKERS` to the caller, or the caller must be the project owner.
- **Salt collision:** If the computed salt matches a previously deployed sucker, the Create2 deployment reverts.
- **Empty `deployerConfigurations`:** The sucker registry call succeeds with zero suckers deployed.

---

## Journey 9: Data Hook Interception (Pay)

**Actor:** Anyone paying a Croptop-deployed project
**Entry point:** Called by JBMultiTerminal during `pay()` flow
**Source:** `CTDeployer.beforePayRecordedWith(context)` at lines 160-169

### Execution Flow

1. JBMultiTerminal calls `CTDeployer.beforePayRecordedWith(context)` because CTDeployer is registered as the project's data hook.
2. CTDeployer forwards the call directly to `dataHookOf[context.projectId]` (line 168), which is the JB721TiersHook.
3. The hook returns `(weight, hookSpecifications)` which determine token issuance and pay hook routing.

### Edge Cases

- **`dataHookOf[projectId]` is `address(0)`:** If a project was somehow created without setting the data hook (not possible via normal deployment flow), the forwarding call reverts on the zero address.
- **Hook reverts:** The entire `pay()` call reverts. The payer's ETH is returned. This can cause permanent DoS for a project if the hook is in a broken state.

---

## Journey 10: Data Hook Interception (Cash Out)

**Actor:** Token holder cashing out from a Croptop-deployed project
**Entry point:** Called by JBMultiTerminal during `cashOut()` flow
**Source:** `CTDeployer.beforeCashOutRecordedWith(context)` at lines 132-151

### Execution Flow

1. JBMultiTerminal calls `CTDeployer.beforeCashOutRecordedWith(context)`.

2. **Sucker check** (line 144):
   ```
   if (SUCKER_REGISTRY.isSuckerOf(projectId, context.holder))
       return (0, context.cashOutCount, context.totalSupply, [])
   ```
   If the holder is a registered sucker: return zero tax rate (fee-free cash out). Skip the hook entirely.

3. **Normal path** (line 150): Forward to `dataHookOf[context.projectId].beforeCashOutRecordedWith(context)`.

### Edge Cases

- **Sucker impersonation:** If an attacker can register as a sucker (via compromised registry), they get zero-tax cash outs from any Croptop project.
- **Sucker registry reverts:** If `isSuckerOf()` reverts, the entire cash-out reverts. This could DoS cash-outs.
- **Hook reverts (non-sucker path):** Same as Journey 9 -- permanent DoS for non-sucker cash-outs.
- **Sucker cashing out:** The sucker receives full treasury value without paying the project's configured cash-out tax. This is intentional (cross-chain bridging needs lossless value transfer).

---

## Journey 11: Read Posting Allowance

**Actor:** Anyone (view function)
**Entry point:** `CTPublisher.allowanceFor(hook, category)`
**Source:** `src/CTPublisher.sol` lines 158-190

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `hook` | `address` | The hook contract |
| `category` | `uint256` | The posting category |

### Returns

| Return | Type | Description |
|--------|------|-------------|
| `minimumPrice` | `uint256` | Extracted from bits 0-103 of packed storage |
| `minimumTotalSupply` | `uint256` | Extracted from bits 104-135 |
| `maximumTotalSupply` | `uint256` | Extracted from bits 136-167 |
| `maximumSplitPercent` | `uint256` | Extracted from bits 168-199 |
| `allowedAddresses` | `address[]` | Full copy of the allowlist array |

### Edge Cases

- **Unconfigured category:** Returns all zeros and empty array. A `minimumTotalSupply` of 0 means posting is not allowed.
- **Gas cost for large allowlists:** The function copies the entire `_allowedAddresses` array to memory. For a 10,000-address list, this is approximately 200,000 gas for the memory copy.

---

## Journey 12: Look Up Tiers by IPFS URI

**Actor:** Anyone (view function)
**Entry point:** `CTPublisher.tiersFor(hook, encodedIPFSUris)`
**Source:** `src/CTPublisher.sol` lines 115-142

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `hook` | `address` | The hook contract |
| `encodedIPFSUris` | `bytes32[]` | Array of encoded IPFS URIs to look up |

### Returns

`JB721Tier[]` -- one tier per URI. Empty tier (all zeros) if the URI has no associated tier.

### Execution Flow

For each URI:
1. Look up `tierIdForEncodedIPFSUriOf[hook][uri]`
2. If non-zero, call `hook.STORE().tierOf(hook, tierId, false)` (line 139)
3. If zero, return an empty `JB721Tier`

### Edge Cases

- **Stale mapping:** If a tier was removed but the mapping was not yet cleared (only cleared on re-post), `tierOf()` may return a tier with `remainingSupply = 0` or the store may revert.
- **Large array:** Each URI requires an external call to the store. Gas scales linearly with array length.
