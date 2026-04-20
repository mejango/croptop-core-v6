# Croptop Core Risk Register

This file focuses on the publishing, fee-routing, and hook-composition risks that matter once third parties can create NFT tiers on someone else's Juicebox project.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections for contract-level reasoning about posting criteria, fee routing, and deployer composition.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the boundary between intentional tradeoffs and defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Hook/store and terminal trust | `mintFrom` depends on hook storage and directory terminal resolution; a bad integration can misprice posts or redirect value. | Audit integration assumptions, verify hook/store pairings, and monitor terminal configuration. |
| P1 | Tier ID race during concurrent posting | `_setupPosts` predicts future tier IDs before `adjustTiers`; concurrent writes can shift those IDs and break the batch. | Application-layer ordering, atomic reverts on mismatch, and operator awareness. |
| P1 | Fee-path degradation without mint failure | The fee terminal is fail-open via try/catch, so publishing continues even if the fee project temporarily stops receiving revenue. | Terminal health monitoring, fallback-beneficiary handling, and explicit fee-routing checks. |

## 1. Trust Assumptions

- **Trusted forwarder.** ERC-2771 `_msgSender()` is trusted in both publisher and deployer for permission checks, allowlists, and payment routing.
- **CTDeployer as permanent data-hook proxy.** `CTDeployer` sets itself as the data hook for projects it deploys. `dataHookOf[projectId]` is set once and has no setter.
- **Sucker registry.** `CTDeployer.beforeCashOutRecordedWith` trusts `SUCKER_REGISTRY.isSuckerOf()` for 0% tax cash outs.
- **Sucker deployment is fail-open at launch time.** Launch can continue on chains where the configured sucker deployer cascade cannot complete.
- **CTProjectOwner as burn target.** Projects transferred to `CTProjectOwner` cannot be recovered.
- **JBDirectory / terminal resolution.** `CTPublisher.mintFrom` trusts `DIRECTORY.primaryTerminalOf()`.
- **721 hook store.** `_setupPosts` trusts the hook store for tier state, removal checks, and prices.

## 2. Economic And Manipulation Risks

- **Fee evasion via duplicate posts across hooks.** Duplicate-content checks are keyed per hook, so the same URI can be reused across different hooks.
- **Fee calculation rounding.** Fee is `totalPrice / 20`, so integer division truncates small amounts.
- **Fee is computed from `msg.value`.** Force-sent ETH does not affect the fee calculation.
- **Fee terminal fallback refunds the caller.** If the fee project cannot accept the fee, Croptop refunds `_msgSender()`. Relayers or contracts that cannot receive ETH will make the mint revert.
- **Split percent manipulation.** Posters can direct large shares of tier revenue away from the project if `maximumSplitPercent` is configured high.

## 3. Access Control

- **Allowlist is O(n).** `_isAllowed` linearly scans the full allowlist.
- **Categories cannot be disabled cleanly.** Once configured, a category can only be made impractical through stricter bounds.
- **CTDeployer grants broad permissions.** Wildcard permissions to the sucker registry and publisher apply to all projects deployed by that deployer instance.
- **`deployProjectFor` is permissionless for new projects.** Anyone can create a project with arbitrary owners.
- **`claimCollectionOwnershipOf` only checks current NFT ownership.** After claiming, the project owner must still grant `CTPublisher` the needed tier-adjust permission or publishing stops working.

## 4. DoS Vectors

- **Large batch posts.** `_setupPosts` does O(n^2) duplicate detection within a batch.
- **External hook calls in loops.** Tier-store calls inside the post loop can revert or become gas-heavy.
- **Terminal resolution failure.** If `DIRECTORY.primaryTerminalOf()` returns `address(0)`, payment calls revert.
- **`adjustTiers` revert.** Hook-level tier rules can block the whole `mintFrom` call.

## 5. Reentrancy Surface

- **`mintFrom` external call chain.** The function calls into the hook and terminals. It currently relies on local-call state isolation rather than a `ReentrancyGuard`.
- **Fee payment ordering.** The fee is sent after the main payment. This is safe under the current `msg.value`-based accounting model, but future mutable storage in the publisher would make the surface riskier.

## 6. Integration Risks

- **Null data-hook forwarding in deployer.** `beforePayRecordedWith` and `beforeCashOutRecordedWith` return defaults when `dataHookOf` is null.
- **No hook migration path.** `dataHookOf` is written once and never updated.
- **Sucker support can be absent even when requested.** A launch can complete while omnichain support is still missing.
- **Tier ID prediction.** `_setupPosts` predicts new tier IDs ahead of the actual `adjustTiers` call.
- **CTProjectOwner accepts any project NFT.** Accidentally transferring a non-Croptop project there still grants publisher permissions.
- **Fee payment destination.** If the fee project changes terminal behavior incompatibly, mints fall back to refund or revert.

## 7. Accepted Behaviors

### 7.1 O(n^2) duplicate detection is accepted

Duplicate detection within a batch is quadratic, but expected real-world batch sizes are small enough that this tradeoff is acceptable.

### 7.2 Tier ID prediction assumes no concurrent tier writes

This is a known race. The mitigation is application-layer ordering and the fact that a bad prediction reverts the whole batch cleanly.

### 7.3 Project owners can bypass the publisher path while they still have direct hook permissions

`CTDeployer.deployProjectFor` intentionally grants the initial owner enough hook permissions to manage the collection directly. That is part of the trust model until ownership is moved into a narrower surface.
