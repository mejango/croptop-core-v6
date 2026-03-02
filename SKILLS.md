# croptop-core-v5

## Purpose

Permissioned NFT publishing system that lets anyone post content as 721 tiers to a Juicebox project, subject to owner-defined criteria for price, supply, and poster identity.

## Contracts

| Contract | Role |
|----------|------|
| `CTPublisher` | Validates posts against allowances, creates 721 tiers, mints first copies, and routes fees. |
| `CTDeployer` | Factory that deploys a Juicebox project + 721 hook + posting criteria in one transaction. Also acts as a data hook proxy. |
| `CTProjectOwner` | Receives project ownership and grants the publisher tier-adjustment permissions permanently. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `mintFrom` | `CTPublisher` | Publishes posts as new 721 tiers, mints first copies to `nftBeneficiary`, deducts a 5% fee (1/`FEE_DIVISOR`) routed to `FEE_PROJECT_ID`, and pays the remainder into the project terminal. |
| `configurePostingCriteriaFor` | `CTPublisher` | Sets per-category posting rules (min price, min/max supply, address allowlist) for a given hook. Requires `ADJUST_721_TIERS` permission from the hook owner. |
| `allowanceFor` | `CTPublisher` | Reads the packed allowance for a hook+category: minimum price (104 bits), min supply (32 bits), max supply (32 bits), plus the address allowlist. |
| `tiersFor` | `CTPublisher` | Resolves an array of encoded IPFS URIs to their corresponding `JB721Tier` structs via the stored `tierIdForEncodedIPFSUriOf` mapping. |
| `deployProjectFor` | `CTDeployer` | Deploys a new Juicebox project with a 721 tiers hook, configures posting criteria, optionally deploys suckers, and transfers project ownership to the specified owner. |
| `claimCollectionOwnershipOf` | `CTDeployer` | Transfers hook ownership to the project (via `JBOwnable.transferOwnershipToProject`). Only callable by the project owner. |
| `deploySuckersFor` | `CTDeployer` | Deploys new cross-chain suckers for an existing project. Requires `DEPLOY_SUCKERS` permission. |
| `beforePayRecordedWith` | `CTDeployer` | Data hook proxy: forwards pay context to the stored `dataHookOf[projectId]`. |
| `beforeCashOutRecordedWith` | `CTDeployer` | Data hook proxy: returns zero tax rate for sucker addresses (fee-free cross-chain cash outs), otherwise forwards to the stored data hook. |
| `onERC721Received` | `CTProjectOwner` | On receiving the project NFT, grants `CTPublisher` the `ADJUST_721_TIERS` permission for that project. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v5` | `IJBDirectory`, `IJBPermissions`, `IJBTerminal`, `IJBProjects`, `IJBController` | Project lookup, permission enforcement, payment routing, project creation. |
| `@bananapus/721-hook-v5` | `IJB721TiersHook`, `IJB721TiersHookDeployer`, `JB721TierConfig`, `JB721Tier` | Tier creation/adjustment, hook deployment, tier data resolution. |
| `@bananapus/ownable-v5` | `JBOwnable` | Ownership checks and transfers for hooks. |
| `@bananapus/suckers-v5` | `IJBSuckerRegistry`, `JBSuckerDeployerConfig` | Cross-chain sucker deployment and fee-free cash-out detection. |
| `@bananapus/permission-ids-v5` | `JBPermissionIds` | Permission ID constants (`ADJUST_721_TIERS`, `DEPLOY_SUCKERS`, `MAP_SUCKER_TOKEN`, etc.). |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, safe project NFT receipt. |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `CTAllowedPost` | `hook`, `category`, `minimumPrice` (uint104), `minimumTotalSupply` (uint32), `maximumTotalSupply` (uint32), `allowedAddresses` | `CTPublisher.configurePostingCriteriaFor` |
| `CTPost` | `encodedIPFSUri` (bytes32), `totalSupply` (uint32), `price` (uint104), `category` (uint24) | `CTPublisher.mintFrom` |
| `CTProjectConfig` | `terminalConfigurations`, `projectUri`, `allowedPosts`, `contractUri`, `name`, `symbol`, `salt` | `CTDeployer.deployProjectFor` |
| `CTDeployerAllowedPost` | `category`, `minimumPrice`, `minimumTotalSupply`, `maximumTotalSupply`, `allowedAddresses` | `CTProjectConfig.allowedPosts` |
| `CTSuckerDeploymentConfig` | `deployerConfigurations`, `salt` | `CTDeployer.deployProjectFor`, `CTDeployer.deploySuckersFor` |

## Gotchas

- The `FEE_DIVISOR` is 20 (5% fee), not a percentage. Fee = `totalPrice / 20`. The fee is skipped when `projectId == FEE_PROJECT_ID`.
- Allowances are bit-packed into a single `uint256`: price in bits 0-103, min supply in 104-135, max supply in 136-167. Reading with wrong bit widths will silently return wrong values.
- `CTDeployer` owns the project NFT temporarily during deployment (to configure permissions and hooks) then transfers it to the specified `owner`. If the transfer reverts, the entire deployment fails.
- `CTDeployer.beforeCashOutRecordedWith` checks `SUCKER_REGISTRY.isSuckerOf` to grant fee-free cash outs. If the sucker registry is compromised, any address could cash out without tax.
- `CTProjectOwner.onERC721Received` only accepts tokens from `PROJECTS` and only from `address(0)` (mints). In `CTDeployer`, it accepts mints only. Sending a project NFT via transfer to `CTProjectOwner` works, but to `CTDeployer` it does not (reverts if `from != address(0)`).
- `_setupPosts` resizes `tiersToAdd` via inline assembly if some posts reuse existing tiers. The `tierIdsToMint` array is NOT resized and may contain zeros for pre-existing tiers that were already minted in prior calls.
- The `mintFrom` function sends `address(this).balance` as the fee payment after the main payment. If no ETH remains (e.g., exact payment), the fee transfer is skipped entirely.

## Example Integration

```solidity
import {ICTPublisher} from "@croptop/core-v5/src/interfaces/ICTPublisher.sol";
import {CTPost} from "@croptop/core-v5/src/structs/CTPost.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHook.sol";

// Mint a post from a Croptop-enabled project
CTPost[] memory posts = new CTPost[](1);
posts[0] = CTPost({
    encodedIPFSUri: 0x1234..., // encoded IPFS CID
    totalSupply: 100,
    price: 0.01 ether,
    category: 1
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
```
