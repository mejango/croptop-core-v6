# RISKS.md -- croptop-core-v6

## 1. Trust Assumptions

- **Trusted forwarder.** ERC-2771 `_msgSender()` is trusted in both CTPublisher and CTDeployer for permission checks, allowlist validation, and payment routing. A compromised forwarder can post as any allowed address, deploy projects as any owner, and redirect payments.
- **CTDeployer as permanent data hook proxy.** `CTDeployer` sets itself as the data hook for projects it deploys. `dataHookOf[projectId]` is set once during `deployProjectFor` and has no setter to update it. If the underlying data hook needs to change, there is no mechanism to do so without redeploying.
- **Sucker registry.** `CTDeployer.beforeCashOutRecordedWith` trusts `SUCKER_REGISTRY.isSuckerOf()` for 0% tax cashouts, same risk as the omnichain deployer.
- **CTProjectOwner as burn target.** Projects transferred to `CTProjectOwner` grant `ADJUST_721_TIERS` to `PUBLISHER`. The project NFT cannot be recovered -- this is intentional but irreversible.
- **JBDirectory / Terminal resolution.** `CTPublisher.mintFrom` resolves terminals via `DIRECTORY.primaryTerminalOf()`. A compromised directory could redirect payment and fee flows.
- **721 hook store.** `_setupPosts` calls `hook.STORE().tierOf()` and `hook.STORE().isTierRemoved()`. The store is trusted to return accurate tier data. A malicious hook returning a fake store can report manipulated prices, supply limits, and removal status, causing `_setupPosts` to miscalculate `totalPrice` or skip duplicate detection.

## 2. Economic / Manipulation Risks

- **Fee evasion via duplicate posts across hooks.** `tierIdForEncodedIPFSUriOf` is keyed per hook. The same `encodedIPFSUri` can be posted to different hooks without duplicate detection, potentially creating fee-arbitrage opportunities.
- **Fee calculation rounding.** Fee is `totalPrice / FEE_DIVISOR` (FEE_DIVISOR=20, so 5% fee). Integer division truncates, losing up to 19 wei per post. Negligible individually but could compound across many micro-priced posts. Explicit validation: reverts `CTPublisher_InsufficientEthSent` if `msg.value < fee` (before subtraction) or if `msg.value - fee < totalPrice` (after subtraction).
- **Pre-computed fee routing.** `CTPublisher.mintFrom` computes the fee as `msg.value - payValue` before the external payment call, so the fee amount is determined from `msg.value` alone. Force-sent ETH (via selfdestruct) does not affect fee calculation.
- **Try-catch fee payment.** The fee terminal payment is wrapped in try-catch. If the fee terminal reverts, the fee is sent to `feeBeneficiary` via low-level call. If that also fails, the fee is sent to `msg.sender`. This means a broken fee terminal does not block mints, but the fee project may lose fee revenue during the outage.
- **Split percent manipulation.** Posters can set `splitPercent` up to `maximumSplitPercent`. Splits route funds away from the project treasury to poster-specified addresses. If `maximumSplitPercent` is set high, posters can redirect most of the tier revenue.

## 3. Access Control

- **Allowlist is O(n) linear scan.** `_isAllowed` iterates the entire allowlist array. Acceptable for small lists but gas-expensive for large allowlists. No Merkle proof alternative.
- **Categories cannot be disabled.** Once `configurePostingCriteriaFor` is called for a category, it can only be restricted by setting very high `minimumPrice` or `minimumTotalSupply`, but never fully removed.
- **CTDeployer grants broad permissions.** Constructor grants `MAP_SUCKER_TOKEN` (wildcard, projectId=0) to sucker registry and `ADJUST_721_TIERS` (wildcard, projectId=0) to publisher. These permissions apply to ALL projects deployed by this CTDeployer instance.
- **CTDeployer.deployProjectFor permission gap.** No explicit permission check -- anyone can call `deployProjectFor` and create a project. A griefer could deploy many projects with arbitrary owners.
- **CTDeployer.claimCollectionOwnershipOf.** Only checks `PROJECTS.ownerOf(projectId) == _msgSender()`. No Juicebox permission check. If the project NFT is transferred, the new owner can claim collection ownership. After claiming, the project owner must grant CTPublisher the `ADJUST_721_TIERS` permission for the project so that `mintFrom()` continues to work — without this, all subsequent posts revert.

## 4. DoS Vectors

- **Large batch posts.** `_setupPosts` iterates all posts with O(n^2) duplicate detection (inner loop `j < i`). A batch of 100+ posts has quadratic gas growth.
- **External hook calls in loops.** `_setupPosts` calls `hook.STORE().tierOf()` and `hook.STORE().isTierRemoved()` inside the post loop. A reverting or gas-expensive store blocks the entire mint.
- **Terminal resolution failure.** If `DIRECTORY.primaryTerminalOf()` returns `address(0)` for the project or fee project, the `pay()` call will revert with a low-level error.
- **adjustTiers revert.** `hook.adjustTiers()` can revert if tiers violate category ordering constraints or other hook-level rules. This blocks the entire `mintFrom` call.

## 5. Reentrancy Surface

- **`mintFrom` external call chain.** `mintFrom` makes three categories of external calls: (1) `hook.adjustTiers()` to create new tiers, (2) `terminal.pay{value}()` to pay the project, (3) `feeTerminal.pay{value}()` to pay the fee project (wrapped in try-catch, with fallback to `feeBeneficiary.call` then `msg.sender.call`). The first `terminal.pay` can trigger pay hooks on the target project, which could call back into `CTPublisher`. However, `mintFrom` has no mutable state between the tier adjustment and the payment — `totalPrice` and `payValue` are computed from local variables before the external calls. A re-entrant `mintFrom` call would process independently.
- **Fee payment ordering.** The fee is sent AFTER the main payment (line ordering in `mintFrom`). If the main payment's pay hook re-enters and calls `mintFrom` again, the fee for the first call has not yet been sent. This is safe because the fee is pre-computed from `msg.value` before the external call (`msg.value - payValue`), and each call independently computes its own fee from its own `msg.value`. Force-sent ETH (via selfdestruct) does not affect fee calculation since the fee is derived from `msg.value`, not `address(this).balance`. The fee terminal payment is wrapped in try-catch, so a reverting fee terminal does not block the mint — the fee falls back to `feeBeneficiary` then `msg.sender`.
- **No `ReentrancyGuard`.** The publisher relies on independent local state per call. This is safe for the current implementation but fragile if mutable contract storage is added in future versions.

## 6. Integration Risks

- **CTDeployer forwards pay/cashout calls to `dataHookOf` with null check.** `beforePayRecordedWith` and `beforeCashOutRecordedWith` check for a null `dataHookOf` and return defaults (context weight, empty specs) instead of reverting. If a non-null data hook reverts, payments/cashouts for the project are still blocked.
- **No mechanism for hook migration.** `dataHookOf` is written once in `deployProjectFor` and never updated. If the data hook becomes compromised, there is no governance path to replace it without deploying a new project.
- **Tier ID prediction.** `_setupPosts` predicts new tier IDs as `maxTierIdOf(hook) + 1 + i`. If another transaction adds tiers between `maxTierIdOf` read and `adjustTiers` execution, tier IDs shift and the wrong tiers are minted. This is a race condition in concurrent posting.
- **CTProjectOwner accepts any project NFT.** `onERC721Received` grants `ADJUST_721_TIERS` to `PUBLISHER` for whatever tokenId is received. If a non-Croptop project is accidentally transferred to `CTProjectOwner`, the publisher gains tier adjustment permission for it.
- **Fee payment destination.** Fees are routed to `FEE_PROJECT_ID` via its primary terminal. If the fee project changes its terminal or token acceptance, fee payments will fail. However, the fee terminal payment is wrapped in try-catch: on failure, the fee is sent to `feeBeneficiary` via low-level call, then to `msg.sender` if that also fails. Minting is never blocked by a broken fee terminal, but the fee project loses revenue during the outage.

## 7. Accepted Behaviors

### 7.1 O(n^2) duplicate detection in `_setupPosts` (bounded by practical limits)

`_setupPosts` uses an inner loop (`j < i`) to detect duplicate `encodedIPFSUri` values within a single batch. This is O(n^2) in the number of posts. For typical batch sizes (1-20 posts), gas cost is negligible (~2k gas per comparison). At 100 posts, the quadratic cost adds ~10M gas. The practical limit is ~150 posts per batch before approaching block gas limits. No mitigation is needed because: (1) the quadratic detection prevents duplicate NFT tiers which would corrupt tier ID tracking, (2) real-world posting batches are small (marketplace UX limits), and (3) the gas cost is borne by the poster, not the protocol.

### 7.2 Tier ID prediction assumes no concurrent transactions

`_setupPosts` predicts new tier IDs as `maxTierIdOf(hook) + 1 + i`. A concurrent `adjustTiers` call between the `maxTierIdOf` read and the `adjustTiers` execution shifts all predicted IDs, causing the wrong tiers to be minted. This is a known race condition. Mitigation is at the application layer: frontends should use nonce-based transaction ordering or warn users about concurrent posting. The hook-level `adjustTiers` is atomic (all-or-nothing), so a failed prediction reverts the entire batch cleanly.

## 8. Invariants to Verify

- `tierIdForEncodedIPFSUriOf[hook][encodedIPFSUri]` is set exactly once per (hook, encodedIPFSUri) pair and points to a valid, non-removed tier.
- `totalPrice` accumulated in `_setupPosts` equals the sum of prices for all posts (new tier price for new posts, existing tier price for existing posts).
- Fee amount: `msg.value - payValue == totalPrice / FEE_DIVISOR` (within 19 wei rounding).
- For every configured category, `minimumTotalSupply <= maximumTotalSupply` and `minimumTotalSupply > 0`.
- Packed allowance encoding/decoding round-trips correctly for all valid input ranges.
- After `CTDeployer.deployProjectFor`, the project NFT is owned by `owner`, and `dataHookOf[projectId]` is the deployed 721 hook.
- `CTProjectOwner` only grants `ADJUST_721_TIERS` permission, never broader permissions.
