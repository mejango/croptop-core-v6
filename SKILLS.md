# croptop-core

## Purpose

Permissioned NFT publishing system that lets anyone post content as 721 tiers to a Juicebox project, subject to owner-defined criteria for price, supply, split percentages, and poster identity. Routes a 5% fee on each mint to a designated fee project.

## Contracts

| Contract | Role |
|----------|------|
| `CTPublisher` | Core publishing engine. Validates posts against bit-packed allowances, creates 721 tiers on hooks, mints first copies to posters, and routes fees. Inherits `JBPermissioned`, `ERC2771Context`. |
| `CTDeployer` | Factory that deploys a Juicebox project + 721 hook + posting criteria in one transaction. Also acts as `IJBRulesetDataHook` proxy that forwards pay/cash-out calls to the underlying hook while granting fee-free cash outs to suckers. |
| `CTProjectOwner` | Receives project ownership NFT and grants `CTPublisher` the `ADJUST_721_TIERS` permission permanently. Locks ownership while keeping posting enabled. |

## Key Functions

### Publishing

| Function | What it does |
|----------|-------------|
| `CTPublisher.mintFrom(hook, posts, nftBeneficiary, feeBeneficiary, additionalPayMetadata, feeMetadata)` | Publishes posts as new 721 tiers, mints first copies to `nftBeneficiary`, deducts a 5% fee (`totalPrice / FEE_DIVISOR`) routed to `FEE_PROJECT_ID`, and pays the remainder into the project's primary terminal. Reuses existing tiers if the IPFS URI was already minted. |
| `CTPublisher.configurePostingCriteriaFor(allowedPosts)` | Sets per-category posting rules (min price, min/max supply, max split percent, address allowlist) for a given hook. Requires `ADJUST_721_TIERS` permission from the hook owner. |

### Views

| Function | What it does |
|----------|-------------|
| `CTPublisher.allowanceFor(hook, category)` | Returns the posting criteria for a hook/category: minimum price (uint104), min supply (uint32), max supply (uint32), max split percent (uint32), plus the address allowlist. Reads from bit-packed storage. |
| `CTPublisher.tiersFor(hook, encodedIPFSUris)` | Resolves an array of encoded IPFS URIs to their corresponding `JB721Tier` structs via the stored `tierIdForEncodedIPFSUriOf` mapping. |

### Project Deployment

| Function | What it does |
|----------|-------------|
| `CTDeployer.deployProjectFor(owner, projectConfig, suckerDeploymentConfiguration, controller)` | Deploys a new Juicebox project with a 721 tiers hook, configures posting criteria, optionally deploys suckers, and transfers project ownership to the specified owner. Uses `CTDeployer` as data hook proxy. Returns `(projectId, hook)`. |
| `CTDeployer.claimCollectionOwnershipOf(hook)` | Transfers hook ownership to the project via `JBOwnable.transferOwnershipToProject`. Only callable by the project owner. |
| `CTDeployer.deploySuckersFor(projectId, suckerDeploymentConfiguration)` | Deploys new cross-chain suckers for an existing project. Requires `DEPLOY_SUCKERS` permission. |

### Data Hook Proxy

| Function | What it does |
|----------|-------------|
| `CTDeployer.beforePayRecordedWith(context)` | Forwards pay context to the stored `dataHookOf[projectId]` (typically the 721 tiers hook). |
| `CTDeployer.beforeCashOutRecordedWith(context)` | Returns zero tax rate for sucker addresses (fee-free cross-chain cash outs). Otherwise forwards to the stored data hook. |
| `CTDeployer.hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` if `addr` is a sucker for the project. |

### Burn-Lock Ownership

| Function | What it does |
|----------|-------------|
| `CTProjectOwner.onERC721Received(operator, from, tokenId, data)` | On receiving the project NFT, grants `CTPublisher` the `ADJUST_721_TIERS` permission for that project. Only accepts mints from `PROJECTS` (rejects direct transfers). |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBDirectory`, `IJBPermissions`, `IJBTerminal`, `IJBProjects`, `IJBController`, `JBConstants`, `JBMetadataResolver` | Project lookup, permission enforcement, payment routing, project creation, metadata encoding |
| `@bananapus/721-hook-v6` | `IJB721TiersHook`, `IJB721TiersHookDeployer`, `JB721TierConfig`, `JB721Tier` | Tier creation/adjustment, hook deployment, tier data resolution |
| `@bananapus/ownable-v6` | `JBOwnable` | Ownership checks and transfers for hooks |
| `@bananapus/suckers-v6` | `IJBSuckerRegistry`, `JBSuckerDeployerConfig` | Cross-chain sucker deployment and fee-free cash-out detection |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | Permission ID constants (`ADJUST_721_TIERS`, `DEPLOY_SUCKERS`, `MAP_SUCKER_TOKEN`, etc.) |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, safe project NFT receipt |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `CTAllowedPost` | `hook`, `category` (uint24), `minimumPrice` (uint104), `minimumTotalSupply` (uint32), `maximumTotalSupply` (uint32), `maximumSplitPercent` (uint32), `allowedAddresses[]` | `configurePostingCriteriaFor` |
| `CTPost` | `encodedIPFSUri` (bytes32), `totalSupply` (uint32), `price` (uint104), `category` (uint24), `splitPercent` (uint32), `splits[]` (JBSplit[]) | `mintFrom` |
| `CTProjectConfig` | `terminalConfigurations`, `projectUri`, `allowedPosts` (CTDeployerAllowedPost[]), `contractUri`, `name`, `symbol`, `salt` | `deployProjectFor` |
| `CTDeployerAllowedPost` | Same as `CTAllowedPost` minus `hook` (inferred during deployment) | `CTProjectConfig.allowedPosts` |
| `CTSuckerDeploymentConfig` | `deployerConfigurations` (JBSuckerDeployerConfig[]), `salt` | `deployProjectFor`, `deploySuckersFor` |

## Events

| Event | When |
|-------|------|
| `ConfigurePostingCriteria(hook, allowedPost, caller)` | Posting criteria set or updated for a hook/category |
| `Mint(projectId, hook, nftBeneficiary, feeBeneficiary, posts, postValue, txValue, caller)` | Posts published and first copies minted |

## Errors

| Error | When |
|-------|------|
| `CTPublisher_EmptyEncodedIPFSUri` | Post has `encodedIPFSUri == bytes32(0)` |
| `CTPublisher_InsufficientEthSent` | `totalPrice + fee > msg.value` |
| `CTPublisher_MaxTotalSupplyLessThanMin` | `minimumTotalSupply > maximumTotalSupply` in config |
| `CTPublisher_NotInAllowList` | Caller not in allowlist (when allowlist is non-empty) |
| `CTPublisher_PriceTooSmall` | Post price below `minimumPrice` |
| `CTPublisher_SplitPercentExceedsMaximum` | Post `splitPercent > maximumSplitPercent` |
| `CTPublisher_TotalSupplyTooSmall` | Post `totalSupply < minimumTotalSupply` |
| `CTPublisher_TotalSupplyTooBig` | Post `totalSupply > maximumTotalSupply` (when max > 0) |
| `CTPublisher_UnauthorizedToPostInCategory` | Category unconfigured (`minSupply == 0`) |
| `CTPublisher_ZeroTotalSupply` | `configurePostingCriteriaFor` with `minimumTotalSupply == 0` |
| `CTDeployer_NotOwnerOfProject` | `claimCollectionOwnershipOf` called by non-owner |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `FEE_DIVISOR` | 20 | 5% fee: `totalPrice / 20` |
| `FEE_PROJECT_ID` | immutable | Fees routed to this project. Fee skipped when `projectId == FEE_PROJECT_ID` |

## Storage

| Mapping | Type | Purpose |
|---------|------|---------|
| `tierIdForEncodedIPFSUriOf` | `hook => encodedIPFSUri => uint256` | Maps IPFS URI to existing tier ID (prevents duplicates) |
| `_packedAllowanceFor` | `hook => category => uint256` | Bit-packed allowance: price (0-103), minSupply (104-135), maxSupply (136-167), maxSplitPercent (168-199) |
| `_allowedAddresses` | `hook => category => address[]` | Per-category address allowlist |
| `dataHookOf` | `projectId => IJBRulesetDataHook` | Stores original data hook (CTDeployer proxy pattern) |

## Gotchas

1. **Bit-packed allowances.** Allowances are packed into a single `uint256`: price in bits 0-103, min supply in 104-135, max supply in 136-167, max split percent in 168-199. Reading with wrong bit widths silently returns wrong values.
2. **Fee is 1/20, not a percentage.** `FEE_DIVISOR = 20` means fee = `totalPrice / 20` = 5%. Integer division truncates (rounding down favors payer).
3. **Fee skipped for fee project.** When `projectId == FEE_PROJECT_ID`, no fee is deducted. This prevents self-referential fee loops.
4. **Fee payment uses contract balance.** After the main payment, `mintFrom` sends `address(this).balance` as the fee. If the main payment uses exact funds (no remainder), the fee transfer is skipped entirely.
5. **Tier reuse by IPFS URI.** If an encoded IPFS URI was already minted on the hook, the existing tier ID is reused instead of creating a new tier. The poster still gets a mint of the existing tier.
6. **Array resizing via assembly.** `_setupPosts` resizes `tiersToAdd` via inline assembly when some posts reuse existing tiers. The `tierIdsToMint` array is NOT resized and may contain zeros for pre-existing tiers.
7. **CTProjectOwner only accepts mints.** `onERC721Received` reverts if `from != address(0)` -- it only accepts tokens minted by `PROJECTS`, not transferred directly. But external project NFT transfers (where `from` is the previous owner) DO work since the hook is on `CTProjectOwner`, not `CTDeployer`.
8. **CTDeployer rejects direct transfers.** `CTDeployer.onERC721Received` reverts if `from != address(0)`. It only accepts mints from `PROJECTS`.
9. **Temporary ownership during deployment.** `CTDeployer` owns the project NFT temporarily during `deployProjectFor` (to configure permissions and hooks), then transfers it to the specified `owner`. If the transfer reverts, the entire deployment fails.
10. **Data hook proxy pattern.** `CTDeployer` wraps itself as the data hook, forwarding to `dataHookOf[projectId]`. This is needed to intercept cash-out calls and grant fee-free cash outs to suckers.
11. **Sucker registry trust.** `CTDeployer.beforeCashOutRecordedWith` trusts `SUCKER_REGISTRY.isSuckerOf` to determine fee exemption. If the registry is compromised, any address could cash out without tax.
12. **Allowlist uses linear scan.** `_isAllowed()` iterates the full allowlist array. Acceptable for <100 addresses; gas cost scales linearly with list size.
13. **Referral ID in metadata.** `FEE_PROJECT_ID` is stored in the first 32 bytes of mint metadata (via assembly `mstore`), allowing the fee terminal to track referrals.
14. **Deterministic deployment.** Hook salt is `keccak256(abi.encode(projectConfig.salt, msg.sender))` and sucker salt is `keccak256(abi.encode(suckerConfig.salt, msg.sender))`. Different callers with the same salt get different addresses.
15. **Default project weight.** `CTDeployer` deploys projects with `weight = 1_000_000 * 10^18`, ETH currency, and `maxCashOutTaxRate`. These defaults are hardcoded.
16. **ERC2771 meta-transaction support.** Both `CTPublisher` and `CTDeployer` support meta-transactions via `ERC2771Context` with a configurable trusted forwarder, allowing relayers to submit transactions on behalf of users.

## Example Integration

```solidity
import {ICTPublisher} from "@croptop/core-v6/src/interfaces/ICTPublisher.sol";
import {CTPost} from "@croptop/core-v6/src/structs/CTPost.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";

// --- Post content to a Croptop-enabled project ---

CTPost[] memory posts = new CTPost[](1);
posts[0] = CTPost({
    encodedIPFSUri: 0x1234..., // encoded IPFS CID
    totalSupply: 100,
    price: 0.01 ether,
    category: 1,
    splitPercent: 0,
    splits: new JBSplit[](0)
});

// Price + 5% fee
uint256 totalCost = 0.01 ether + (0.01 ether / 20);

publisher.mintFrom{value: totalCost}(
    IJB721TiersHook(hookAddress),
    posts,
    msg.sender, // NFT beneficiary
    msg.sender, // fee beneficiary
    "",         // additional pay metadata
    ""          // fee metadata
);

// --- Deploy a new Croptop project ---

(uint256 projectId, IJB721TiersHook hook) = deployer.deployProjectFor({
    owner: msg.sender,
    projectConfig: CTProjectConfig({
        terminalConfigurations: terminals,
        projectUri: "ipfs://...",
        allowedPosts: allowedPosts,
        contractUri: "ipfs://...",
        name: "My Collection",
        symbol: "MYC",
        salt: bytes32("my-project")
    }),
    suckerDeploymentConfiguration: CTSuckerDeploymentConfig({
        deployerConfigurations: new JBSuckerDeployerConfig[](0),
        salt: bytes32(0)
    }),
    controller: IJBController(controllerAddress)
});

// --- Lock ownership via CTProjectOwner ---
// Transfer the project NFT to CTProjectOwner to burn-lock ownership
// while keeping Croptop posting enabled.
IERC721(projects).safeTransferFrom(msg.sender, address(projectOwner), projectId);
```
