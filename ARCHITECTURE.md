# croptop-core-v6 — Architecture

## Purpose

NFT publishing platform built on Juicebox V6. Allows permissioned posting of NFT content to Juicebox projects. CTDeployer creates projects pre-configured for content publishing, and CTPublisher manages the posting workflow with configurable rules (price floors, supply limits, category restrictions).

## Contract Map

```
src/
├── CTDeployer.sol       — Deploys Croptop projects with 721 hooks and publishing rules
├── CTPublisher.sol      — Manages permissioned NFT posting to projects
├── CTProjectOwner.sol   — Proxy owner for Croptop-deployed projects
├── interfaces/
│   ├── ICTDeployer.sol
│   ├── ICTProjectOwner.sol
│   └── ICTPublisher.sol
└── structs/
    ├── CTAllowedPost.sol         — Rules for what can be posted
    ├── CTDeployerAllowedPost.sol — Deployer-level post rules (no hook field)
    ├── CTPost.sol                — A post submission
    ├── CTProjectConfig.sol       — Project configuration
    └── CTSuckerDeploymentConfig.sol — Cross-chain config
```

## Key Data Flows

### Project Deployment

```
Creator → CTDeployer.deployProjectFor(owner, projectConfig, suckerConfig, controller)
  1. Deploy 721 hook via IJB721TiersHookDeployer (empty tiers, ETH currency)
  2. Launch JB project with:
     → weight = 1,000,000 * 10^18
     → cashOutTaxRate = MAX (100%)
     → dataHook = CTDeployer itself (see "Data Hook Behavior" below)
     → useDataHookForPay = true, useDataHookForCashOut = true
  3. Store dataHookOf[projectId] = the 721 hook (for pay forwarding)
  4. Configure allowed post rules on CTPublisher
  5. Deploy suckers for cross-chain support (if configured)
  6. Transfer project NFT to the specified owner
  7. Grant owner permissions: ADJUST_721_TIERS, SET_721_METADATA, MINT_721, SET_721_DISCOUNT_PERCENT
```

### Content Publishing (mintFrom)

```
Publisher → CTPublisher.mintFrom(hook, posts[], nftBeneficiary, feeBeneficiary, ...)
  → _setupPosts: for each post:
    1. Reject empty encodedIPFSUri
    2. Reject duplicate encodedIPFSUri within the batch
    3. If tier already exists for this encodedIPFSUri:
       → Use existing tier ID, add tier's price to totalPrice
       → (Prevents fee evasion by using actual on-chain price, not user-supplied)
    4. If tier is new:
       → Load allowance for (hook, category) — see "Allowed Post Rules" below
       → Validate: category enabled, price >= minimum, supply in range,
         splitPercent <= maximum, caller in allowlist (if restricted)
       → Create JB721TierConfig with the post's price, supply, category,
         splitPercent, and splits array
       → Record tierIdForEncodedIPFSUriOf mapping
       → Add post.price to totalPrice
  → Calculate fee: totalPrice / FEE_DIVISOR (5% fee, FEE_DIVISOR = 20)
     Fee is skipped when projectId == FEE_PROJECT_ID
  → adjustTiers on the 721 hook to add new tiers
  → Pay the project terminal: payValue = msg.value - fee
     Metadata encodes tier IDs to mint, so the 721 hook mints one NFT per post
  → Pay fee to FEE_PROJECT_ID terminal with remaining balance
```

### Allowed Post Rules

Each category on each 721 hook has an allowance stored as bit-packed values in `_packedAllowanceFor[hook][category]`. The project owner configures these via `configurePostingCriteriaFor`.

| Field | Type | Bits | Purpose |
|-------|------|------|---------|
| `minimumPrice` | `uint104` | 0-103 | Floor price per NFT. Posts below this revert. |
| `minimumTotalSupply` | `uint32` | 104-135 | Minimum editions. Must be >= 1; a zero value means the category is disabled. |
| `maximumTotalSupply` | `uint32` | 136-167 | Maximum editions. Must be >= minimumTotalSupply. |
| `maximumSplitPercent` | `uint32` | 168-199 | Cap on the publisher's split (out of `SPLITS_TOTAL_PERCENT = 1,000,000,000`). 0 means no splits allowed. |
| `allowedAddresses` | `address[]` | separate storage | If non-empty, only these addresses may post in this category. Empty means anyone can post. |

Validation order in `_setupPosts`: category enabled (minimumTotalSupply != 0) -> price check -> supply range check -> split percent cap -> allowlist check.

Categories cannot be fully removed after creation. This is by design -- once a category exists, removing posting would break expectations for existing posters. Projects can set restrictive allowance configurations to effectively disable new posts.

## Data Hook Behavior

CTDeployer registers itself as the ruleset's `dataHook` so it can intercept both payments and cash-outs. It acts as a transparent proxy that adds sucker-awareness:

**`beforePayRecordedWith`**: Pure passthrough. Forwards the call directly to `dataHookOf[projectId]` (the project's 721 hook). The 721 hook returns the weight and pay hook specifications that handle NFT minting. CTDeployer does not modify pay behavior.

**`beforeCashOutRecordedWith`**: Checks if the `holder` is a sucker for the project (via `SUCKER_REGISTRY.isSuckerOf`). If yes, returns `cashOutTaxRate = 0` with no hook specifications -- suckers cash out without any tax. If no, forwards to `dataHookOf[projectId]` for standard cash-out behavior.

**`hasMintPermissionFor`**: Returns `true` only for addresses that are suckers for the project. This allows suckers to mint tokens on-demand during cross-chain bridging.

```
Payment path:        CTDeployer.beforePayRecordedWith → 721 hook (passthrough)
Cash-out (sucker):   CTDeployer.beforeCashOutRecordedWith → return 0% tax
Cash-out (normal):   CTDeployer.beforeCashOutRecordedWith → 721 hook (forward)
Mint permission:     Only suckers get on-demand mint permission
```

## Ownership Model

### Why a Proxy Owner?

When CTDeployer creates a project, it initially owns the project NFT (because `launchProjectFor` mints to `msg.sender`). CTDeployer needs to be the initial owner so it can:
1. Configure posting criteria on CTPublisher (requires `ADJUST_721_TIERS` permission from the hook's owner, which is CTDeployer).
2. Deploy suckers (requires project ownership).
3. Grant the final owner NFT management permissions.

After setup, CTDeployer transfers the project NFT to the specified `owner`. The 721 hook's ownership stays with CTDeployer, which has granted `ADJUST_721_TIERS` permission to CTPublisher with `projectId = 0` (wildcard). This means CTPublisher can add tiers to any Croptop-deployed project without further permission grants.

### CTProjectOwner: The Immutable-Rules Pattern

`CTProjectOwner` is a separate contract that serves as a "lockbox" for projects that want immutable posting rules. When the project owner transfers their project NFT to a CTProjectOwner instance:

1. `onERC721Received` fires and grants CTPublisher the `ADJUST_721_TIERS` permission for that project.
2. CTProjectOwner exposes no function to reconfigure posting criteria, queue new rulesets, or transfer the project further.
3. The posting rules become permanently frozen -- content can still be published under the existing rules, but the rules themselves cannot change.

This enables a trust model: creators can prove to publishers that the rules (price floors, supply caps, split percentages) will never change, providing a credible commitment that the economic terms are permanent.

### Claiming Collection Ownership

`CTDeployer.claimCollectionOwnershipOf(hook)` allows the project NFT holder to take direct ownership of the 721 hook by calling `JBOwnable.transferOwnershipToProject(projectId)`. After this, the hook's owner resolves to whoever holds the project NFT. The caller must then independently grant CTPublisher the `ADJUST_721_TIERS` permission, or subsequent posts will revert.

## Publisher Fee and Split Mechanics

### Fee Structure

CTPublisher charges a 5% fee (`FEE_DIVISOR = 20`) on the total price of all posts in a `mintFrom` call. The fee is skipped when the target project is the fee project itself (`FEE_PROJECT_ID`).

```
msg.value breakdown:
  totalPrice     → paid to the project's terminal (mints NFTs + project tokens)
  totalPrice/20  → paid to FEE_PROJECT_ID's terminal (Croptop platform fee)
  remainder      → reverts if insufficient, excess stays as overpayment
```

### Publisher Split Mechanism

When a publisher creates a new post, they can set a `splitPercent` and a `splits` array on their `CTPost`. These are stored directly on the 721 tier via `JB721TierConfig.splitPercent` and `JB721TierConfig.splits`.

The split mechanics work at the 721 hook level: whenever someone mints (buys) an NFT from that tier, the 721 hook routes `splitPercent` of the tier's price to the addresses in the `splits` array. The publisher typically sets themselves as a split recipient so they earn a share of every future mint from the tier they created.

The project owner controls the maximum split a publisher can claim via `maximumSplitPercent` in the allowed post rules. If `maximumSplitPercent` is 0, publishers cannot set any splits. This gives project owners control over how much revenue publishers can capture versus how much flows to the project treasury.

## Design Decisions

**Permissioned publishing over open posting.** Posts are validated against per-category allowance rules rather than allowing anyone to post anything. This prevents spam, ensures minimum economic commitment (price floors), and lets project owners curate their collection's quality by restricting who can post and at what terms.

**Publisher gets a split, not a direct payment.** Rather than paying publishers upfront, Croptop uses the 721 hook's split mechanism. The publisher earns a percentage of every future mint from their tier. This aligns incentives: publishers profit when their content is popular enough that others want to mint copies, not just from the act of posting.

**CTDeployer as data hook proxy.** Instead of requiring projects to use a custom data hook, CTDeployer inserts itself as a transparent proxy. This lets it add sucker-awareness (tax-free cross-chain cash-outs) without requiring the underlying 721 hook to know about suckers. The 721 hook handles NFT minting logic; CTDeployer handles cross-chain policy.

**Immutable rules via CTProjectOwner.** Rather than building immutability into CTPublisher (which would add complexity for all projects), immutability is opt-in: transfer the project to CTProjectOwner and the rules freeze. Projects that want governance flexibility simply keep the project NFT in a wallet or multisig.

**Category-based organization.** Posts are organized by `category` (uint24), with each category having independent allowance rules. This lets a single project support multiple content types (e.g., category 1 for images at 0.01 ETH, category 2 for music at 0.1 ETH) with different price floors, supply limits, and access controls.

**Duplicate prevention via encodedIPFSUri mapping.** `tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]` ensures each piece of content can only create one tier. If a tier already exists, the mint uses the existing tier (at its on-chain price, not the caller-supplied price). This prevents duplicate tiers and fee evasion.

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | CTDeployer proxies pay/cash-out hooks, adds sucker-awareness |
| 721 hook | `IJB721TiersHook` | NFT tier management, split routing on mints |
| Publisher | `ICTPublisher` | Content posting workflow and allowance configuration |

## Dependencies

- `@bananapus/core-v6` -- Core protocol (terminals, rulesets, permissions, directory)
- `@bananapus/721-hook-v6` -- NFT tier system (tiers, minting, splits)
- `@bananapus/ownable-v6` -- JB-aware ownership (ownership-to-project transfer)
- `@bananapus/permission-ids-v6` -- Permission constants
- `@bananapus/suckers-v6` -- Cross-chain support (sucker registry)
- `@openzeppelin/contracts` -- ERC2771 (meta-transactions), ERC721Receiver
