# croptop-core-v6 -- User Journeys

Complete user path documentation for auditors. Each journey describes the entry point, who can call, parameters, state changes, events, external calls, and edge cases.

---

## Journey 1: Deploy a Croptop Project

**Actor:** Project creator
**Entry point:** `CTDeployer.deployProjectFor(address owner, CTProjectConfig calldata projectConfig, CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration, IJBController controller) external returns (uint256 projectId, IJB721TiersHook hook)`
**Who can call:** Anyone. No access control on this function.
**Source:** `src/CTDeployer.sol` lines 244-348

### Parameters

- `owner` (`address`): Final owner of the project NFT after deployment.
- `projectConfig` (`CTProjectConfig`): Name, symbol, URIs, terminal configs, allowed posts, salt.
- `suckerDeploymentConfiguration` (`CTSuckerDeploymentConfig`): Cross-chain sucker deployer configs + salt (set salt to `bytes32(0)` to skip).
- `controller` (`IJBController`): The JB controller that will manage the project.

### Execution Flow

1. **Controller validation** (line 254): Reverts if `controller.PROJECTS() != PROJECTS`.

2. **Ruleset configuration** (lines 256-291):
   - Weight: `1_000_000 * 10^18`
   - Base currency: ETH
   - Cash-out tax rate: `MAX_CASH_OUT_TAX_RATE` (100%)
   - Data hook: `address(this)` (CTDeployer)
   - `useDataHookForPay = true`, `useDataHookForCashOut = true`

3. **Project ID prediction** (line 261): `projectId = PROJECTS.count() + 1`

4. **Hook deployment** (lines 265-286):
   ```
   DEPLOYER.deployHookFor(projectId, config, salt)
   ```
   - Salt: `keccak256(abi.encode(projectConfig.salt, _msgSender()))`
   - Deployed with empty tiers, ETH currency, 18 decimals
   - No reserves, no votes, no owner minting, no overspend prevention

5. **Project launch** (lines 294-303):
   ```
   controller.launchProjectFor(owner: address(this), ...)
   ```
   - CTDeployer receives the project NFT temporarily
   - `assert(projectId == returned ID)` -- reverts on mismatch (front-running protection)

6. **Data hook registration** (line 306):
   ```
   dataHookOf[projectId] = IJBRulesetDataHook(hook)
   ```
   This is write-once. No setter exists.

7. **Posting criteria** (lines 309-311): If `projectConfig.allowedPosts.length > 0`, calls internal `_configurePostingCriteriaFor()` which formats `CTDeployerAllowedPost` into `CTAllowedPost` (adding the hook address) and delegates to `PUBLISHER.configurePostingCriteriaFor()`.

8. **Sucker deployment** (lines 317-324): If `suckerDeploymentConfiguration.salt != bytes32(0)`:
   ```
   SUCKER_REGISTRY.deploySuckersFor(projectId, salt, configurations)
   ```

9. **Ownership transfer** (line 327):
   ```
   PROJECTS.transferFrom(address(this), owner, projectId)
   ```

10. **Permission grants** (lines 329-347): Grants `owner` four permissions from CTDeployer's account:
    - `ADJUST_721_TIERS`
    - `SET_721_METADATA`
    - `MINT_721`
    - `SET_721_DISCOUNT_PERCENT`

### State Changes

1. `CTDeployer.dataHookOf[projectId]` -- set to the deployed hook address (permanent, write-once).
2. `JBProjects` (ERC-721) -- new token minted, transferred from CTDeployer to `owner`.
3. `JBPermissions` -- 2 permission entries set in constructor (sucker registry `MAP_SUCKER_TOKEN` + publisher `ADJUST_721_TIERS`), 4 permission entries set for `owner` (`ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT`).
4. `CTPublisher._packedAllowanceFor[hook][category]` -- set for each allowed post category (if any).
5. `CTPublisher._allowedAddresses[hook][category]` -- set for each allowed post category with allowlists (if any).

### Events

- `ConfigurePostingCriteria(hook, allowedPost, caller)` -- emitted by CTPublisher for each allowed post entry (only if `projectConfig.allowedPosts` is non-empty). See Journey 3 for the full event signature.
- No events are emitted directly by CTDeployer itself. External calls to `controller.launchProjectFor()`, `DEPLOYER.deployHookFor()`, `PROJECTS.transferFrom()`, and `PERMISSIONS.setPermissionsFor()` emit their own events from those contracts.

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
**Entry point:** `CTPublisher.mintFrom(IJB721TiersHook hook, CTPost[] calldata posts, address nftBeneficiary, address feeBeneficiary, bytes calldata additionalPayMetadata, bytes calldata feeMetadata) external payable`
**Who can call:** Anyone, subject to per-category allowlist restrictions. If a category has a non-empty `allowedAddresses` list, only those addresses may post in that category. Checked via `_isAllowed(_msgSender(), addresses)`.
**Source:** `src/CTPublisher.sol` lines 310-430
**Value:** Must send `msg.value >= sum(tier prices) + 5% fee`

### Parameters

- `hook` (`IJB721TiersHook`): The 721 hook to post to.
- `posts` (`CTPost[]`): Array of posts (URI, supply, price, category, splits).
- `nftBeneficiary` (`address`): Receives the minted NFTs.
- `feeBeneficiary` (`address`): Receives fee project tokens.
- `additionalPayMetadata` (`bytes`): Extra metadata appended to the payment.
- `feeMetadata` (`bytes`): Metadata sent with the fee payment.

### Execution Flow

**Phase 1: Validation and setup** (`_setupPosts`, lines 442-589)

For each post in the batch:

1. **URI check:** `encodedIPFSUri != bytes32("")` or revert `CTPublisher_EmptyEncodedIPFSUri`
2. **Duplicate check:** O(i) scan against all prior posts. Revert `CTPublisher_DuplicatePost` on match.
3. **Existing tier lookup:** Check `tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]`
   - **Tier exists and live:** Reuse tier ID. Accumulate `store.tierOf().price`.
   - **Tier exists but removed:** Delete mapping. Fall through to new tier.
   - **No tier:** Validate against category allowance, create `JB721TierConfig`.

**Phase 2: Fee calculation** (lines 336-354)

```
fee = totalPrice / FEE_DIVISOR   (integer division)
require(payValue >= fee)         (reverts CTPublisher_InsufficientEthSent if not)
payValue = msg.value - fee       (if projectId != FEE_PROJECT_ID)
require(totalPrice <= payValue)  (reverts CTPublisher_InsufficientEthSent if not)
```

**Phase 3: Tier creation** (line 358)

```
hook.adjustTiers(tiersToAdd, [])
```

**Phase 4: Metadata construction** (lines 361-377)

Build JBMetadataResolver-compatible metadata with tier IDs and referral ID.

**Phase 5: Project payment** (lines 398-406)

```
projectTerminal.pay{value: payValue}(projectId, NATIVE_TOKEN, payValue, nftBeneficiary, 0, "Minted from Croptop", mintMetadata)
```

**Phase 6: Fee payment** (lines 413-429)

```
if (address(this).balance != 0) {
    feeTerminal.pay{value: address(this).balance}(FEE_PROJECT_ID, ...)
}
```

### State Changes

1. `CTPublisher.tierIdForEncodedIPFSUriOf[hook][uri]` -- set for each new tier created.
2. `CTPublisher.tierIdForEncodedIPFSUriOf[hook][uri]` -- deleted if stale mapping detected (removed tier).
3. `JB721TiersHookStore` (external) -- new tiers added via `adjustTiers`.
4. Project terminal (external) -- balance increased by `payValue`.
5. Fee project terminal (external) -- balance increased by fee amount.

### Events

- `Mint(projectId, hook, nftBeneficiary, feeBeneficiary, posts, postValue, txValue, caller)` -- emitted at line 380 after setup is complete, before the project payment. Full signature:
  ```solidity
  event Mint(
      uint256 indexed projectId,
      IJB721TiersHook indexed hook,
      address indexed nftBeneficiary,
      address feeBeneficiary,
      CTPost[] posts,
      uint256 postValue,
      uint256 txValue,
      address caller
  );
  ```

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
**Entry point:** `CTPublisher.configurePostingCriteriaFor(CTAllowedPost[] memory allowedPosts) external`
**Who can call:** The hook's owner (as returned by `JBOwnable(hook).owner()`) or any address that has been granted the `ADJUST_721_TIERS` permission for the hook's `PROJECT_ID()` from that owner. Checked per-entry via `_requirePermissionFrom(account: JBOwnable(hook).owner(), projectId: hook.PROJECT_ID(), permissionId: JBPermissionIds.ADJUST_721_TIERS)`.
**Source:** `src/CTPublisher.sol` lines 243-298

### Parameters

- `allowedPosts` (`CTAllowedPost[]`): Array of per-category posting rules.

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

1. **Emit event** (line 252): `ConfigurePostingCriteria(hook, allowedPost, caller)`

2. **Permission check** (lines 256-260):
   ```
   _requirePermissionFrom(
       account: JBOwnable(hook).owner(),
       projectId: IJB721TiersHook(hook).PROJECT_ID(),
       permissionId: JBPermissionIds.ADJUST_721_TIERS
   )
   ```

3. **Validation:**
   - `minimumTotalSupply > 0` or revert `CTPublisher_ZeroTotalSupply` (line 263)
   - `minimumTotalSupply <= maximumTotalSupply` or revert `CTPublisher_MaxTotalSupplyLessThanMin` (line 268)

4. **Pack and store** (lines 274-284):
   ```
   packed = minimumPrice | (minimumTotalSupply << 104) | (maximumTotalSupply << 136) | (maximumSplitPercent << 168)
   _packedAllowanceFor[hook][category] = packed
   ```

5. **Allowlist storage** (lines 287-296):
   ```
   delete _allowedAddresses[hook][category]
   for each address in allowedAddresses:
       _allowedAddresses[hook][category].push(address)
   ```

### State Changes

1. `CTPublisher._packedAllowanceFor[hook][category]` -- overwritten with new packed values.
2. `CTPublisher._allowedAddresses[hook][category]` -- deleted and repopulated.

### Events

- `ConfigurePostingCriteria(address indexed hook, CTAllowedPost allowedPost, address caller)` -- emitted once per entry in the `allowedPosts` array (line 252), **before** the permission check. Full signature:
  ```solidity
  event ConfigurePostingCriteria(address indexed hook, CTAllowedPost allowedPost, address caller);
  ```
  Note: the event is emitted before `_requirePermissionFrom`, so an unauthorized call will emit the event then revert, rolling back the event emission.

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
**Entry point:** Triggered within `CTPublisher.mintFrom()` at lines 413-429
**Who can call:** N/A -- this is an internal sub-flow of Journey 2, not independently callable.
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

### Events

- No events are emitted by the fee sub-flow itself. The `Mint` event (see Journey 2) is emitted before the fee payment. The fee terminal's `pay()` call emits its own events from the terminal contract.

### Edge Cases

- **Fee project has no primary terminal:** `DIRECTORY.primaryTerminalOf()` returns `address(0)`. The `pay()` call to address(0) reverts. The entire `mintFrom()` transaction reverts (including the project payment).
- **Fee terminal reverts:** Same as above -- entire `mintFrom()` reverts. No state changes persist.
- **`address(this).balance == 0` after project payment:** This happens when `fee == 0` (e.g., `totalPrice < FEE_DIVISOR` or `projectId == FEE_PROJECT_ID`). The fee payment is skipped entirely.
- **Force-sent ETH (via `selfdestruct`):** If ETH was force-sent to CTPublisher before the `mintFrom()` call, it is included in `address(this).balance` and routed to the fee project. CTPublisher has no `receive()` or `fallback()`, so normal sends revert. Only `selfdestruct` (deprecated post-Dencun) can force-send ETH.

---

## Journey 5: Deploy a Croptop Project via CTDeployer with Posting Criteria

**Actor:** Project creator
**Entry point:** `CTDeployer.deployProjectFor(address owner, CTProjectConfig calldata projectConfig, CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration, IJBController controller) external returns (uint256 projectId, IJB721TiersHook hook)` with non-empty `projectConfig.allowedPosts`
**Who can call:** Anyone. No access control on this function. Same as Journey 1.
**Source:** `src/CTDeployer.sol` lines 244-348, internal `_configurePostingCriteriaFor()` at lines 382-411

This is an extension of Journey 1 that details the posting criteria configuration during deployment.

### Posting Criteria Flow

1. CTDeployer receives `CTDeployerAllowedPost[]` (which omits the `hook` field, since the hook hasn't been deployed yet).
2. After the hook is deployed, `_configurePostingCriteriaFor()` converts each `CTDeployerAllowedPost` to a `CTAllowedPost` by injecting `hook: address(hook)` (lines 398-406).
3. Calls `PUBLISHER.configurePostingCriteriaFor(formattedAllowedPosts)` (line 410).
4. The publisher validates each entry (supply bounds, permissions) and stores the packed allowances and allowlists.

### Permission Flow

The `PUBLISHER.configurePostingCriteriaFor()` call checks `ADJUST_721_TIERS` permission from `JBOwnable(hook).owner()`. At this point in the deployment:

- The hook was deployed by `DEPLOYER.deployHookFor()` on behalf of CTDeployer
- Hook ownership is set to CTDeployer (the deployer is the effective owner after deployment)
- The permission check passes because CTDeployer is both the caller and the hook owner (or has wildcard permission)

After the deployment completes and ownership is transferred to `owner`, only the new owner (or their delegate) can reconfigure posting criteria.

### State Changes

1. `CTPublisher._packedAllowanceFor[hook][category]` -- set for each allowed post category.
2. `CTPublisher._allowedAddresses[hook][category]` -- set for each allowed post category with allowlists.

### Events

- `ConfigurePostingCriteria(address indexed hook, CTAllowedPost allowedPost, address caller)` -- emitted by CTPublisher once per `allowedPosts` entry. The `caller` is CTDeployer's address (since CTDeployer calls the publisher). The `hook` is the newly deployed hook address.

### Edge Cases

- **Empty `allowedPosts`:** The `_configurePostingCriteriaFor()` call is skipped (line 309 condition). The project has no posting categories configured. Content cannot be posted until the owner configures criteria manually.
- **Invalid criteria in deployment:** If any `CTDeployerAllowedPost` has `minimumTotalSupply == 0` or `minimumTotalSupply > maximumTotalSupply`, the publisher reverts, and the entire deployment fails.

---

## Journey 6: Lock Project Ownership (Burn-Lock)

**Actor:** Project owner
**Entry point:** `IERC721(PROJECTS).safeTransferFrom(address from, address to, uint256 tokenId)` where `to = address(ctProjectOwner)`
**Who can call:** The current owner of the project NFT, or an approved operator. The `safeTransferFrom` is an ERC-721 function with standard ownership/approval checks. CTProjectOwner itself has no caller restrictions in `onERC721Received` beyond requiring `msg.sender == address(PROJECTS)`.
**Source:** `src/CTProjectOwner.sol` lines 50-83

### Parameters

- `from` (`address`): Current holder of the project NFT (not checked by CTProjectOwner, unlike CTDeployer).
- `to` (`address`): Must be `address(ctProjectOwner)`.
- `tokenId` (`uint256`): The project ID to lock.

### Execution Flow

1. The project owner calls `safeTransferFrom` on the JBProjects ERC-721 contract, transferring their project NFT to the CTProjectOwner contract.
2. The ERC-721 contract calls `CTProjectOwner.onERC721Received()`.
3. **Validation** (line 65): `msg.sender == address(PROJECTS)` -- only accepts tokens from the JBProjects contract. Reverts with empty revert on failure.
4. **Permission grant** (lines 68-80):
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

1. `JBProjects` (ERC-721) -- token transferred from owner to CTProjectOwner.
2. `JBPermissions` -- CTPublisher granted `ADJUST_721_TIERS` for this project from CTProjectOwner's account.

### Events

- No events are emitted directly by CTProjectOwner. The ERC-721 `Transfer(from, to, tokenId)` event is emitted by JBProjects. The `JBPermissions.setPermissionsFor()` call emits its own event from the permissions contract.

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
**Entry point:** `CTDeployer.claimCollectionOwnershipOf(IJB721TiersHook hook) external`
**Who can call:** Only the current owner of the project NFT (`PROJECTS.ownerOf(hook.PROJECT_ID())`). Checked via `PROJECTS.ownerOf(projectId) != _msgSender()` -- reverts with `CTDeployer_NotOwnerOfProject(projectId, address(hook), _msgSender())` on failure.
**Source:** `src/CTDeployer.sol` lines 224-235

### Parameters

- `hook` (`IJB721TiersHook`): The 721 hook to claim ownership of.

### Execution Flow

1. **Read project ID** (line 226): `projectId = hook.PROJECT_ID()`
2. **Owner check** (lines 229-231): `PROJECTS.ownerOf(projectId) == _msgSender()` or revert `CTDeployer_NotOwnerOfProject(projectId, address(hook), _msgSender())`
3. **Transfer ownership** (line 234):
   ```
   JBOwnable(address(hook)).transferOwnershipToProject(projectId)
   ```

### State Changes

1. Hook's `JBOwnable` storage -- owner changed from CTDeployer to the project (ownership tied to project NFT holder via `PROJECTS.ownerOf(projectId)`).

### Events

- No events are emitted directly by CTDeployer. The `JBOwnable.transferOwnershipToProject()` call emits its own ownership transfer event from the hook contract.

### Consequences

After claiming, the hook's ownership follows the project NFT. Whoever owns the project NFT can call owner-only functions on the hook (tier adjustments, metadata changes, etc.) directly, without going through CTDeployer.

**Important:** After claiming, the project owner must grant CTPublisher the `ADJUST_721_TIERS` permission for the project so that `mintFrom()` continues to work. Without this permission grant, all subsequent posts will revert.

### Edge Cases

- **Already claimed:** If hook ownership has already been transferred, `transferOwnershipToProject` may revert (depending on JBOwnable implementation). CTDeployer is no longer the owner.
- **Project transferred after deployment:** If the project was sold or transferred, the new owner can claim the hook. The original deployer cannot.
- **Hook not deployed by CTDeployer:** If the `hook` was deployed independently, `JBOwnable(hook).transferOwnershipToProject()` will revert because CTDeployer is not the owner.

---

## Journey 8: Deploy Suckers for Existing Project

**Actor:** Project owner (or permissioned delegate)
**Entry point:** `CTDeployer.deploySuckersFor(uint256 projectId, CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration) external returns (address[] memory suckers)`
**Who can call:** The project owner (`PROJECTS.ownerOf(projectId)`) or any address that has been granted the `DEPLOY_SUCKERS` permission for that project. Checked via `_requirePermissionFrom(account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS)`.
**Source:** `src/CTDeployer.sol` lines 354-373

### Parameters

- `projectId` (`uint256`): The project to deploy suckers for.
- `suckerDeploymentConfiguration` (`CTSuckerDeploymentConfig`): Deployer configs + salt.

### Execution Flow

1. **Permission check** (lines 362-364):
   ```
   _requirePermissionFrom(
       account: PROJECTS.ownerOf(projectId),
       projectId: projectId,
       permissionId: JBPermissionIds.DEPLOY_SUCKERS
   )
   ```

2. **Sucker deployment** (lines 368-372):
   ```
   suckers = SUCKER_REGISTRY.deploySuckersFor(
       projectId,
       keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
       suckerDeploymentConfiguration.deployerConfigurations
   )
   ```

### State Changes

1. Sucker Registry -- new suckers registered for the project.
2. Deployed sucker contracts -- new contracts deployed via Create2.

### Events

- No events are emitted directly by CTDeployer. The `SUCKER_REGISTRY.deploySuckersFor()` call emits its own events from the registry contract.

### Edge Cases

- **Permission not granted:** Reverts. The project owner must explicitly grant `DEPLOY_SUCKERS` to the caller, or the caller must be the project owner.
- **Salt collision:** If the computed salt matches a previously deployed sucker, the Create2 deployment reverts.
- **Empty `deployerConfigurations`:** The sucker registry call succeeds with zero suckers deployed.

---

## Journey 9: Data Hook Interception (Pay)

**Actor:** Anyone paying a Croptop-deployed project
**Entry point:** `CTDeployer.beforePayRecordedWith(JBBeforePayRecordedContext calldata context) external view returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)`
**Who can call:** Intended to be called by JBMultiTerminal during the `pay()` flow. No explicit access control -- any address can call this function, but it is only meaningful when called by the terminal as part of a payment.
**Source:** `src/CTDeployer.sol` lines 160-169

### Parameters

- `context` (`JBBeforePayRecordedContext`): Standard Juicebox payment context containing `projectId`, payer details, amount, and metadata.

### Execution Flow

1. JBMultiTerminal calls `CTDeployer.beforePayRecordedWith(context)` because CTDeployer is registered as the project's data hook.
2. CTDeployer forwards the call directly to `dataHookOf[context.projectId]` (line 168), which is the JB721TiersHook.
3. The hook returns `(weight, hookSpecifications)` which determine token issuance and pay hook routing.

### State Changes

- None. This is a `view` function.

### Events

- None. This is a `view` function.

### Edge Cases

- **`dataHookOf[projectId]` is `address(0)`:** If a project was somehow created without setting the data hook (not possible via normal deployment flow), the forwarding call reverts on the zero address.
- **Hook reverts:** The entire `pay()` call reverts. The payer's ETH is returned. This can cause permanent DoS for a project if the hook is in a broken state.

---

## Journey 10: Data Hook Interception (Cash Out)

**Actor:** Token holder cashing out from a Croptop-deployed project
**Entry point:** `CTDeployer.beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context) external view returns (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply, JBCashOutHookSpecification[] memory hookSpecifications)`
**Who can call:** Intended to be called by JBMultiTerminal during the `cashOut()` flow. No explicit access control -- any address can call this function, but it is only meaningful when called by the terminal as part of a cash-out.
**Source:** `src/CTDeployer.sol` lines 132-151

### Parameters

- `context` (`JBBeforeCashOutRecordedContext`): Standard Juicebox cash-out context containing `projectId`, `holder`, `cashOutCount`, `totalSupply`, and metadata.

### Execution Flow

1. JBMultiTerminal calls `CTDeployer.beforeCashOutRecordedWith(context)`.

2. **Sucker check** (line 144):
   ```
   if (SUCKER_REGISTRY.isSuckerOf(projectId, context.holder))
       return (0, context.cashOutCount, context.totalSupply, [])
   ```
   If the holder is a registered sucker: return zero tax rate (fee-free cash out). Skip the hook entirely.

3. **Normal path** (line 150): Forward to `dataHookOf[context.projectId].beforeCashOutRecordedWith(context)`.

### State Changes

- None. This is a `view` function.

### Events

- None. This is a `view` function.

### Edge Cases

- **Sucker impersonation:** If an attacker can register as a sucker (via compromised registry), they get zero-tax cash outs from any Croptop project.
- **Sucker registry reverts:** If `isSuckerOf()` reverts, the entire cash-out reverts. This could DoS cash-outs.
- **Hook reverts (non-sucker path):** Same as Journey 9 -- permanent DoS for non-sucker cash-outs.
- **Sucker cashing out:** The sucker receives full treasury value without paying the project's configured cash-out tax. This is intentional (cross-chain bridging needs lossless value transfer).

---

## Journey 11: Read Posting Allowance

**Actor:** Anyone (view function)
**Entry point:** `CTPublisher.allowanceFor(address hook, uint256 category) public view returns (uint256 minimumPrice, uint256 minimumTotalSupply, uint256 maximumTotalSupply, uint256 maximumSplitPercent, address[] memory allowedAddresses)`
**Who can call:** Anyone. This is a public view function with no access control.
**Source:** `src/CTPublisher.sol` lines 161-193

### Parameters

- `hook` (`address`): The hook contract.
- `category` (`uint256`): The posting category.

### Returns

| Return | Type | Description |
|--------|------|-------------|
| `minimumPrice` | `uint256` | Extracted from bits 0-103 of packed storage |
| `minimumTotalSupply` | `uint256` | Extracted from bits 104-135 |
| `maximumTotalSupply` | `uint256` | Extracted from bits 136-167 |
| `maximumSplitPercent` | `uint256` | Extracted from bits 168-199 |
| `allowedAddresses` | `address[]` | Full copy of the allowlist array |

### State Changes

- None. This is a `view` function.

### Events

- None. This is a `view` function.

### Edge Cases

- **Unconfigured category:** Returns all zeros and empty array. A `minimumTotalSupply` of 0 means posting is not allowed.
- **Gas cost for large allowlists:** The function copies the entire `_allowedAddresses` array to memory. For a 10,000-address list, this is approximately 200,000 gas for the memory copy.

---

## Journey 12: Look Up Tiers by IPFS URI

**Actor:** Anyone (view function)
**Entry point:** `CTPublisher.tiersFor(address hook, bytes32[] memory encodedIPFSUris) external view returns (JB721Tier[] memory tiers)`
**Who can call:** Anyone. This is an external view function with no access control.
**Source:** `src/CTPublisher.sol` lines 118-145

### Parameters

- `hook` (`address`): The hook contract.
- `encodedIPFSUris` (`bytes32[]`): Array of encoded IPFS URIs to look up.

### Returns

`JB721Tier[]` -- one tier per URI. Empty tier (all zeros) if the URI has no associated tier.

### Execution Flow

For each URI:
1. Look up `tierIdForEncodedIPFSUriOf[hook][uri]`
2. If non-zero, call `hook.STORE().tierOf(hook, tierId, false)` (line 142)
3. If zero, return an empty `JB721Tier`

### State Changes

- None. This is a `view` function.

### Events

- None. This is a `view` function.

### Edge Cases

- **Stale mapping:** If a tier was removed but the mapping was not yet cleared (only cleared on re-post), `tierOf()` may return a tier with `remainingSupply = 0` or the store may revert.
- **Large array:** Each URI requires an external call to the store. Gas scales linearly with array length.
