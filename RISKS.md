# Croptop Core Risk Register

This file focuses on the publishing, fee-routing, and hook-composition risks that matter once third parties can create NFT tiers on someone else's Juicebox project.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections for contract-level reasoning about posting criteria, fee routing, and deployer composition.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the boundary between intentional tradeoffs and defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Hook/store and terminal trust | `mintFrom` depends on hook storage, hook pricing, price feeds, and directory terminal resolution; a bad integration can misprice posts or redirect value. | Payment-token accounting context guard, price-feed availability checks, post-payment NFT delivery check, review integration assumptions, verify hook/store pairings, and monitor terminal configuration. |
| P1 | Tier ID race during concurrent posting | `_setupPosts` predicts future tier IDs before `adjustTiers`; concurrent writes can shift those IDs and break the batch. | Application-layer ordering, atomic reverts on mismatch, and operator awareness. |
| P1 | Fee-path degradation without mint failure | The fee terminal is fail-open via try/catch, so publishing continues even if the fee project temporarily stops receiving revenue or referral volume. | Terminal health monitoring, fallback-beneficiary handling, explicit fee-routing checks, and referral-volume monitoring. |
| P1 | Launch-time hook permissions persist until claim | `CTDeployer` grants the deploy-time `owner` four direct-hook permissions (`ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT`) that persist on the deployer's permission table until `claimCollectionOwnershipOf` is called. A subsequent project NFT transfer does not revoke these — the original recipient can still act on the hook during the pre-claim window. | Project NFT sellers should call `claimCollectionOwnershipOf` before transfer; buyers of pre-claim NFTs should call it immediately on receipt. Marketplaces should surface claim status. |

## 1. Trust Assumptions

- **Trusted forwarder.** ERC-2771 `_msgSender()` is trusted in both publisher and deployer for permission checks, allowlists, and payment routing.
- **CTDeployer as permanent data-hook proxy.** `CTDeployer` sets itself as the data hook for projects it deploys. `dataHookOf[projectId]` is set once and has no setter.
- **Sucker registry.** `CTDeployer.beforeCashOutRecordedWith` trusts `SUCKER_REGISTRY.isSuckerOf()` for 0% tax
  cash outs. Those sucker cash-outs use local supply/surplus because they are bridge accounting, not ordinary global
  cash-outs.
- **Sucker deployment is fail-open at launch time.** Launch can continue on chains where the configured sucker deployer cascade cannot complete.
- **CTProjectOwner as burn target.** Projects transferred to `CTProjectOwner` cannot be recovered.
- **JBDirectory / terminal resolution.** `CTPublisher.mintFrom` trusts `DIRECTORY.primaryTerminalOf()`.
- **721 hook store.** `_setupPosts` trusts the hook store for tier state, removal checks, prices, and the post-payment balance check.

## 2. Economic And Manipulation Risks

- **Fee evasion via duplicate posts across hooks.** Duplicate-content checks are keyed per hook, so the same URI can be reused across different hooks.
- **Fee calculation rounding.** Fee is `totalPrice / 20`, so integer division truncates small amounts.
- **Fee settlement uses the converted tier price.** Force-sent ETH, force-sent tokens, or caller overpayment do not increase the fee calculation or fee refund path.
- **Payment token is terminal-selected, then priced into terminal units.** The project terminal must expose an accounting context for the selected `token`. If that context uses a different currency than the hook's tier pricing, the hook's `PRICES` oracle must provide a nonzero conversion into the payment currency. Missing terminal support or missing price feeds revert before value can be stranded.
- **Fee terminal fallback refunds the caller.** If the fee project has no terminal for the selected token or cannot accept the fee, Croptop refunds `_msgSender()`. Native refunds to relayers or contracts that cannot receive ETH will make the mint revert.
- **CPN referral volume only follows successful, normalized fee payments.** Missing fee terminals, fee-terminal reverts, missing token accounting context, missing price feeds, or zero prices prevent referral credit even when the publish itself can continue.
- **Split percent manipulation.** Posters can direct large shares of tier revenue away from the project if `maximumSplitPercent` is configured high.

## 3. Access Control

- **Allowlist is O(n).** `_isAllowed` linearly scans the full allowlist.
- **Categories cannot be disabled cleanly.** Once configured, a category can only be made impractical through stricter bounds.
- **CTDeployer grants broad permissions.** Wildcard permissions to the sucker registry and publisher apply to all projects deployed by that deployer instance.
- **Launch-time grants to `owner` persist until `claimCollectionOwnershipOf` is called.** `CTDeployer.deployProjectFor` grants the deploy-time `owner` four collection-control permissions on the deployer's permission table — `ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT` (`src/CTDeployer.sol`). These grants are keyed on the deploy-time recipient's address, not on "whoever currently owns the project NFT." They stay live until `claimCollectionOwnershipOf` revokes the caller's row and migrates hook ownership to the project NFT. The dangerous window is between transferring the project NFT to a new owner and the new owner calling claim — during that window, the original deploy-time recipient can still call hook-gated functions (add tiers with owner-mint, mint to themselves, mutate metadata, set discounts) even though they no longer own the project. See Accepted Behavior 7.6 for the operator runbook for both sellers and buyers, and INVARIANTS.md Section E.3 for the full reasoning.
- **Explicit sucker peers require peer-setting authority.** `CTDeployer.deploySuckersFor` mirrors the sucker registry's
  rule: default same-address peering only needs `DEPLOY_SUCKERS`, but non-default explicit peers also require
  `SET_SUCKER_PEER` from the original caller.
- **`deployProjectFor` is permissionless for new projects.** Anyone can create a project with arbitrary owners.
- **`claimCollectionOwnershipOf` only checks current NFT ownership.** After claiming, the project owner must still grant `CTPublisher` the needed tier-adjust permission or publishing stops working.

## 4. DoS Vectors

- **Large batch posts.** `_setupPosts` does O(n^2) duplicate detection within a batch.
- **External hook calls in loops.** Tier-store calls inside the post loop can revert or become gas-heavy.
- **Terminal resolution failure.** If `DIRECTORY.primaryTerminalOf()` returns `address(0)`, payment calls revert.
- **`adjustTiers` revert.** Hook-level tier rules can block the whole `mintFrom` call.

## 5. Reentrancy Surface

- **`mintFrom` external call chain.** The function calls into the hook and terminals. It currently relies on local-call state isolation rather than a `ReentrancyGuard`.
- **Fee payment ordering.** The fee is sent after the main payment. This is safe under the current `amount`-based accounting model, but future mutable storage in the publisher would make the surface riskier.

## 6. Integration Risks

- **Null data-hook forwarding in deployer.** `beforePayRecordedWith` and `beforeCashOutRecordedWith` return defaults when `dataHookOf` is null.
- **No hook migration path.** `dataHookOf` is written once and never updated.
- **Sucker support can be absent even when requested.** A launch can complete while omnichain support is still missing.
- **Tier ID prediction.** `_setupPosts` predicts new tier IDs ahead of the actual `adjustTiers` call.
- **CTProjectOwner accepts any project NFT.** Accidentally transferring a non-Croptop project there still grants publisher permissions.
- **Fee payment destination.** If the fee project changes terminal behavior incompatibly, mints fall back to refund or revert.
- **Referral accounting denomination.** Non-native fee credits depend on the fee terminal's token accounting context and the hook's price feed so the referral ledger can normalize to native-token units.

## 7. Accepted Behaviors

### 7.1 O(n^2) duplicate detection is accepted

Duplicate detection within a batch is quadratic, but expected real-world batch sizes are small enough that this tradeoff is acceptable.

### 7.2 Tier ID prediction assumes no concurrent tier writes

This is a known race. The mitigation is application-layer ordering and the fact that a bad prediction reverts the whole batch cleanly.

### 7.3 Project owners can bypass the publisher path while they still have direct hook permissions

`CTDeployer.deployProjectFor` intentionally grants the initial owner enough hook permissions to manage the collection directly. That is part of the trust model until ownership is moved into a narrower surface.

`CTDeployer` safe-transfers the final project NFT to the requested owner. Contract recipients must implement
`onERC721Received`, otherwise the launch reverts before the project NFT can be stranded in a contract that cannot
operate or transfer it.

### 7.4 The 5% Croptop fee only applies to new tier creation via `CTPublisher.mintFrom`

Croptop's core value is allowing anyone to **post new items** (create new 721 tiers) to a project's collection by minting the first copy. This posting action can only happen through `CTPublisher.mintFrom`, which collects the 5% fee. Once a tier exists, anyone can mint additional copies of that tier by paying the project's terminal directly — these direct terminal payments do not go through CTPublisher and do not incur the Croptop fee. This is by design: the fee gates content creation (posting new tiers), not minting from existing tiers. Direct terminal payments to mint existing tiers are a standard Juicebox feature and are not restricted.

When `mintFrom` includes a nonzero `referralProjectId`, Croptop credits referral volume only for the CPN fee that is actually paid to the fee project. If the fee is skipped, refunded, or cannot be normalized, the referral ledger is not credited.

### 7.5 EIP-7702 delegated EOAs can bypass allowlist restrictions

`_setupPosts` authorizes restricted categories using `_msgSender()`, which identifies the allowlisted EOA. EIP-7702 allows an EOA to delegate code execution to a contract, so an allowlisted EOA that signs a 7702 delegation can have arbitrary code run under its identity. This enables attacker-chosen code to publish to restricted categories while `_msgSender()` still returns the legitimate allowlisted address. This is accepted: EIP-7702 delegation requires the allowlisted EOA's explicit signature — if an allowlisted party delegates execution, they are responsible for the code they delegate to. This is equivalent to an allowlisted EOA voluntarily sharing their private key. The allowlist is a trust boundary, and 7702 delegation is within the allowlisted party's control.

### 7.6 Direct collection-control permissions are tied to the deploy-time recipient until claim

`CTDeployer.deployProjectFor` grants the initial `owner` argument four collection-control permissions (`ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT`) on `account = address(this)` (the deployer). These grants are operator-specific — they are keyed on the deploy-time recipient's address, not on "whoever currently owns the project NFT."

Two parts of the design make this safe by claim:

1. **The hook owner is static-then-dynamic.** Before `claimCollectionOwnershipOf`, `hook.owner() == address(CTDeployer)`. After claim, `JBOwnable.transferOwnershipToProject` makes `hook.owner()` resolve dynamically through `PROJECTS.ownerOf(projectId)`. Permission checks on the hook are gated by `_requirePermissionFrom({account: hook.owner(), ...})`, so post-claim they consult the current project NFT holder's permission table — the deploy-time recipient's grants on `account = deployer` become inert.
2. **The current project NFT holder can always claim.** `claimCollectionOwnershipOf` only requires the caller to be the current project NFT owner. There is no time lock and no deploy-time-recipient requirement, so a buyer of a pre-claim project NFT can close the window themselves.

**Window of concern:** between (a) a project NFT transfer from the deploy-time recipient to a new owner and (b) the new owner calling `claimCollectionOwnershipOf`, the deploy-time recipient retains those four permissions and can still call hook-gated functions even though they no longer own the project NFT. The deploy-time recipient can in principle add a tier with owner-mint enabled, mint NFTs to themselves, corrupt metadata, or set discounts during this window.

**Operator runbook for sellers:** call `claimCollectionOwnershipOf` *before* transferring the project NFT. After claim, hook permissions automatically follow the NFT.

**Operator runbook for buyers of pre-claim project NFTs:** call `claimCollectionOwnershipOf` immediately after receiving the NFT. The call is permissionless against the current NFT owner check, so the buyer can close the window without cooperation from the prior owner.

Frontends and marketplaces listing Croptop-launched project NFTs should surface whether claim has been performed and prompt the buyer to claim immediately on transfer if it has not.

### 7.7 `CTProjectOwner.onERC721Received` accepts any project NFT and grants `ADJUST_721_TIERS` on its ID

`CTProjectOwner.onERC721Received` (line 52) checks `msg.sender == address(PROJECTS)` but explicitly discards the `from` argument (`from;` at line 63). It then calls `PERMISSIONS.setPermissionsFor` to grant `ADJUST_721_TIERS` to the `PUBLISHER` for the received `tokenId`, regardless of whether the transfer was a mint or a stray transfer of an existing project NFT.

Anyone holding any project NFT can `safeTransferFrom` it to this contract and trigger a real on-chain permission grant: the PUBLISHER address gains `ADJUST_721_TIERS` authority on whatever projectId was transferred. The grant is dormant in current code because `CTPublisher` only invokes `ADJUST_721_TIERS` against project NFTs that the publisher actually administers via the Croptop deployer flow, and stray transfers do not bring the publisher's deployer state along. But the on-chain grant is real and would activate if any future publisher code path acts on caller-supplied project IDs. The same shape exists in `DefifaProjectOwner` for the `SET_SPLIT_GROUPS` permission.

Accepted because the grants are dormant against the current publisher surface and the contract is not the recipient of hostile transfers in canonical flows. Anyone integrating `CTProjectOwner` into a publisher / deployer pair that operates on arbitrary projectIds must add the `require(from == address(0))` guard before relying on it.

### 7.8 Registered sucker cash-outs use local backing

`CTDeployer.beforeCashOutRecordedWith` gives registered suckers the documented 0% tax path. That branch intentionally
returns the local `context.totalSupply` and `context.surplus.value` instead of adding remote sucker registry snapshots.
A sucker cash-out is the cross-chain movement path, so the value leaving a chain should be proportional to that chain's
funds.
