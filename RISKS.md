# RISKS.md -- croptop-core-v6

## 1. Trust Assumptions

- **Trusted forwarder.** ERC-2771 `_msgSender()` is trusted in both CTPublisher and CTDeployer for permission checks, allowlist validation, and payment routing. A compromised forwarder can post as any allowed address, deploy projects as any owner, and redirect payments.
- **CTDeployer as permanent data hook proxy.** `CTDeployer` sets itself as the data hook for projects it deploys. `dataHookOf[projectId]` is set once during `deployProjectFor` and has no setter to update it. If the underlying data hook needs to change, there is no mechanism to do so without redeploying.
- **Sucker registry.** `CTDeployer.beforeCashOutRecordedWith` trusts `SUCKER_REGISTRY.isSuckerOf()` for 0% tax cashouts, same risk as the omnichain deployer.
- **CTProjectOwner as burn target.** Projects transferred to `CTProjectOwner` grant `ADJUST_721_TIERS` to `PUBLISHER`. The project NFT cannot be recovered -- this is intentional but irreversible.
- **JBDirectory / Terminal resolution.** `CTPublisher.mintFrom` resolves terminals via `DIRECTORY.primaryTerminalOf()`. A compromised directory could redirect payment and fee flows.

## 2. Economic / Manipulation Risks

- **Fee evasion via duplicate posts across hooks.** `tierIdForEncodedIPFSUriOf` is keyed per hook. The same `encodedIPFSUri` can be posted to different hooks without duplicate detection, potentially creating fee-arbitrage opportunities.
- **Fee calculation rounding.** `payValue -= totalPrice / FEE_DIVISOR` (FEE_DIVISOR=20, so 5% fee). Integer division truncates, losing up to 19 wei per post. Negligible individually but could compound across many micro-priced posts.
- **Balance-based fee routing.** `CTPublisher.mintFrom` sends fees based on `address(this).balance` after the main payment. Force-sent ETH (via selfdestruct) is routed to the fee project.
- **Split percent manipulation.** Posters can set `splitPercent` up to `maximumSplitPercent`. Splits route funds away from the project treasury to poster-specified addresses. If `maximumSplitPercent` is set high, posters can redirect most of the tier revenue.

## 3. Access Control

- **Allowlist is O(n) linear scan.** `_isAllowed` iterates the entire allowlist array. Acceptable for small lists but gas-expensive for large allowlists. No Merkle proof alternative.
- **Categories cannot be disabled.** Once `configurePostingCriteriaFor` is called for a category, it can only be restricted by setting very high `minimumPrice` or `minimumTotalSupply`, but never fully removed.
- **CTDeployer grants broad permissions.** Constructor grants `MAP_SUCKER_TOKEN` (wildcard, projectId=0) to sucker registry and `ADJUST_721_TIERS` (wildcard, projectId=0) to publisher. These permissions apply to ALL projects deployed by this CTDeployer instance.
- **CTDeployer.deployProjectFor permission gap.** No explicit permission check -- anyone can call `deployProjectFor` and create a project. A griefer could deploy many projects with arbitrary owners.
- **CTDeployer.claimCollectionOwnershipOf.** Only checks `PROJECTS.ownerOf(projectId) == _msgSender()`. No Juicebox permission check. If the project NFT is transferred, the new owner can claim collection ownership.

## 4. DoS Vectors

- **Large batch posts.** `_setupPosts` iterates all posts with O(n^2) duplicate detection (inner loop `j < i`). A batch of 100+ posts has quadratic gas growth.
- **External hook calls in loops.** `_setupPosts` calls `hook.STORE().tierOf()` and `hook.STORE().isTierRemoved()` inside the post loop. A reverting or gas-expensive store blocks the entire mint.
- **Terminal resolution failure.** If `DIRECTORY.primaryTerminalOf()` returns `address(0)` for the project or fee project, the `pay()` call will revert with a low-level error.
- **adjustTiers revert.** `hook.adjustTiers()` can revert if tiers violate category ordering constraints or other hook-level rules. This blocks the entire `mintFrom` call.

## 5. Integration Risks

- **CTDeployer forwards all pay/cashout calls to `dataHookOf`.** `beforePayRecordedWith` and `beforeCashOutRecordedWith` delegate to the stored data hook without try-catch. If the data hook reverts, all payments/cashouts for the project are blocked.
- **No mechanism for hook migration.** `dataHookOf` is written once in `deployProjectFor` and never updated. If the data hook becomes compromised, there is no governance path to replace it without deploying a new project.
- **Tier ID prediction.** `_setupPosts` predicts new tier IDs as `maxTierIdOf(hook) + 1 + i`. If another transaction adds tiers between `maxTierIdOf` read and `adjustTiers` execution, tier IDs shift and the wrong tiers are minted. This is a race condition in concurrent posting.
- **CTProjectOwner accepts any project NFT.** `onERC721Received` grants `ADJUST_721_TIERS` to `PUBLISHER` for whatever tokenId is received. If a non-Croptop project is accidentally transferred to `CTProjectOwner`, the publisher gains tier adjustment permission for it.
- **Fee payment destination.** Fees are routed to `FEE_PROJECT_ID` via its primary terminal. If the fee project changes its terminal or token acceptance, fee payments could fail and block all minting.

## 6. Invariants to Verify

- `tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]` is set exactly once per (hook, encodedIPFSUri) pair and points to a valid, non-removed tier.
- `totalPrice` accumulated in `_setupPosts` equals the sum of prices for all posts (new tier price for new posts, existing tier price for existing posts).
- Fee amount: `msg.value - payValue == totalPrice / FEE_DIVISOR` (within 19 wei rounding).
- For every configured category, `minimumTotalSupply <= maximumTotalSupply` and `minimumTotalSupply > 0`.
- Packed allowance encoding/decoding round-trips correctly for all valid input ranges.
- After `CTDeployer.deployProjectFor`, the project NFT is owned by `owner`, and `dataHookOf[projectId]` is the deployed 721 hook.
- `CTProjectOwner` only grants `ADJUST_721_TIERS` permission, never broader permissions.
