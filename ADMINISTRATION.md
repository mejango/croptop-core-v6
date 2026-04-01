# Administration

Admin privileges and their scope in croptop-core-v6.

## At A Glance

| Item | Details |
|------|---------|
| Scope | Croptop project deployment, posting-criteria management, publisher permissions, and project burn-lock ownership flows. |
| Operators | Project owners, hook owners and delegates, the `CTDeployer`, `CTPublisher`, optional `CTProjectOwner`, and the configured sucker registry. |
| Highest-risk actions | Sending a project NFT to `CTProjectOwner`, misconfiguring posting criteria, or relying on the write-once `dataHookOf` mapping without validating the hook first. |
| Recovery posture | Ownership burn-lock mistakes are not recoverable in place. Operational fixes usually mean updating criteria if the project is still controlled, or deploying a new project/hook if it is not. |

## Routine Operations

- Configure posting criteria before broad publisher access, because `mintFrom()` enforces those rules for every post.
- Use `claimCollectionOwnershipOf()` when the project should own its hook directly instead of leaving hook control with the deployer path.
- Treat sucker deployment as a project extension that still depends on the Croptop data-hook proxy remaining correct for the project.
- Avoid transferring project NFTs to `CTProjectOwner` unless the intention is to burn human control permanently.

## One-Way Or High-Risk Actions

- `CTProjectOwner` permanently locks any JBProjects NFT it receives.
- `dataHookOf[projectId]` is set during deployment and has no later setter.
- Constructor-time wildcard permissions granted by `CTDeployer` are structural and cannot be revoked from within the deployer.

## Recovery Notes

- If posting rules are wrong but the project still controls the hook, fix them through the hook-owner surface.
- If ownership was accidentally burned into `CTProjectOwner` or the wrong hook path was deployed, recovery generally means abandoning that control path and redeploying the project or hook composition.

## Roles

### 1. Project Owner

**How assigned:** Receives the JBProjects ERC-721 NFT for the project. Initially set by the `owner` parameter in `CTDeployer.deployProjectFor()`. Can be transferred via standard ERC-721 transfer.

**Scope:** Per-project. Controls posting rules and hook ownership for a single project.

### 2. Hook Owner

**How assigned:** Determined by `JBOwnable(hook).owner()`. For CTDeployer-launched projects, the deployer initially owns the hook (via `DEPLOYER.deployHookFor()`). The project owner can later claim hook ownership via `claimCollectionOwnershipOf()`.

**Scope:** Per-hook. The hook owner (or anyone with `ADJUST_721_TIERS` permission for that hook's project) can configure posting criteria.

### 3. CTDeployer (Contract)

**How assigned:** Immutable singleton deployed at construction. Acts as the `IJBRulesetDataHook` for all CTDeployer-launched projects (set in `deployProjectFor()`).

**Scope:** All Croptop-deployed projects. Proxies pay/cashout data hook calls, grants fee-free cashouts to suckers, and holds broad permissions on behalf of launched projects.

### 4. CTPublisher (Contract)

**How assigned:** Immutable singleton deployed at construction. Receives `ADJUST_721_TIERS` permission from CTDeployer at construction.

**Scope:** All hooks for which it has `ADJUST_721_TIERS` permission. Creates NFT tiers and mints first copies.

### 5. CTProjectOwner (Contract)

**How assigned:** Optional burn-lock proxy. Receives project ownership when a project NFT is `safeTransferFrom`'d to it.

**Scope:** Per-project. Grants `CTPublisher` permanent `ADJUST_721_TIERS` permission for the received project. Once the project is transferred here, human ownership is effectively burned.

- **Important:** `onERC721Received()` accepts project NFTs from any transfer, not only mints. If a project owner accidentally transfers their project NFT to `CTProjectOwner`, it is permanently locked -- there is no recovery function. The only check is that `msg.sender` is the `PROJECTS` contract (ensuring it is a JBProjects NFT, not an arbitrary ERC-721).

### 6. Sucker Registry

**How assigned:** Immutable dependency set at CTDeployer construction. Receives `MAP_SUCKER_TOKEN` permission at construction.

**Scope:** All projects deployed via CTDeployer. Can map tokens for cross-chain bridging. Determines which addresses get fee-free cashouts.

### 7. Publishers (Poster Addresses)

**How assigned:** Either any address (when allowlist is empty) or explicitly added to a per-hook per-category allowlist via `configurePostingCriteriaFor()`.

**Scope:** Per-hook, per-category. Can create NFT tiers (posts) and mint first copies, subject to posting criteria.

## Privileged Functions

### CTDeployer

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `deployProjectFor()` | Anyone | None | Global | Deploys a new Juicebox project with 721 hook, configures posting rules, optionally deploys suckers, transfers ownership to `owner`. No access restriction -- anyone can deploy a project. |
| `claimCollectionOwnershipOf()` | Project owner | None (direct `ownerOf` check) | Per-project | Transfers hook ownership to the project via `JBOwnable.transferOwnershipToProject()`. Caller must be `PROJECTS.ownerOf(projectId)`. |
| `deploySuckersFor()` | Project owner or delegate | `JBPermissionIds.DEPLOY_SUCKERS` | Per-project | Deploys new cross-chain suckers for an existing project. Uses `_requirePermissionFrom()` against the project owner. |

### CTPublisher

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `configurePostingCriteriaFor()` | Hook owner or delegate | `JBPermissionIds.ADJUST_721_TIERS` | Per-hook, per-category | Sets posting rules: minimum price, min/max supply, max split percent, address allowlist. Uses `_requirePermissionFrom()` against `JBOwnable(hook).owner()`. |
| `mintFrom()` | Anyone (subject to allowlist) | None (enforced by allowlist in `_setupPosts`) | Per-hook | Publishes posts as 721 tiers, mints first copies, routes 5% fee to `FEE_PROJECT_ID`. Validates all posts against configured criteria. |

### CTProjectOwner

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `onERC721Received()` | Anyone who transfers a JBProjects NFT | None | Per-project | On receiving a project NFT from `PROJECTS`, grants `CTPublisher` the `ADJUST_721_TIERS` permission for that project. The contract does not restrict this to mint receipts; any transferred JBProjects NFT will be accepted and effectively burn human ownership. |

### Permissions Granted at CTDeployer Construction

These permissions are set in the CTDeployer constructor and apply to all projects it will ever deploy (wildcard `projectId: 0`):

| Permission | Granted To | Purpose |
|-----------|-----------|---------|
| `MAP_SUCKER_TOKEN` | `SUCKER_REGISTRY` | Allows the sucker registry to map tokens for cross-chain bridging on any project owned by CTDeployer. |
| `ADJUST_721_TIERS` | `PUBLISHER` (CTPublisher) | Allows CTPublisher to add tiers to any hook on any project owned by CTDeployer. |

### Permissions Granted During `deployProjectFor()`

These permissions are set per-project during deployment:

| Permission | Granted To | Purpose |
|-----------|-----------|---------|
| `ADJUST_721_TIERS` | `owner` | Allows the project owner to adjust 721 tiers. |
| `SET_721_METADATA` | `owner` | Allows the project owner to update 721 metadata. |
| `MINT_721` | `owner` | Allows the project owner to mint 721 tokens directly. |
| `SET_721_DISCOUNT_PERCENT` | `owner` | Allows the project owner to set tier discount percentages. |

## Data Hook Proxy

When deploying a project, `CTDeployer` sets itself as the project's `dataHook` in the ruleset metadata. It then proxies data hook calls to the project's actual 721 tiers hook:

- **`beforePayRecordedWith`**: Calls `IJBRulesetDataHook(hook).beforePayRecordedWith(context)` where `hook = dataHookOf[context.projectId]`, then returns the 721 hook's specifications.
- **`beforeCashOutRecordedWith`**: Checks if the caller is a registered sucker via `SUCKER_REGISTRY.isSuckerOf()`. If so, returns 0% cash-out tax (fee-free bridging). Otherwise, delegates to the 721 hook.
- **`hasMintPermissionFor`**: Returns `true` for registered suckers, `false` for all other addresses. Does not delegate to the 721 hook.

This proxy pattern exists so that CTDeployer can intercept cash-out calls to grant fee-free bridging to suckers while still supporting the 721 hook's NFT minting logic.

The `dataHookOf[projectId]` mapping is write-once (set during `deployProjectFor`, no setter function). The proxy target cannot be changed after deployment.

## Immutable Configuration

These values are set at deploy time and cannot be changed after deployment:

| Value | Contract | Set At | Description |
|-------|----------|--------|-------------|
| `FEE_DIVISOR` | CTPublisher | Compile time (constant = 20) | Fee percentage: 5% (1/20). Hardcoded, not configurable. |
| `FEE_PROJECT_ID` | CTPublisher | Constructor (immutable) | Project ID that receives all fees. Cannot be changed. |
| `DIRECTORY` | CTPublisher | Constructor (immutable) | JBDirectory for project/terminal lookups. |
| `PROJECTS` | CTDeployer | Constructor (immutable) | JBProjects NFT contract. |
| `DEPLOYER` | CTDeployer | Constructor (immutable) | JB721TiersHookDeployer for hook creation. |
| `PUBLISHER` | CTDeployer | Constructor (immutable) | CTPublisher contract reference. |
| `SUCKER_REGISTRY` | CTDeployer | Constructor (immutable) | Sucker registry for cross-chain bridging. |
| `PERMISSIONS` | CTDeployer, CTProjectOwner | Constructor (immutable) | JBPermissions contract for access control. |
| `trustedForwarder` | CTDeployer, CTPublisher | Constructor (immutable via ERC2771Context) | Meta-transaction trusted forwarder address. |
| `dataHookOf[projectId]` | CTDeployer | `deployProjectFor()` | Once set during deployment, the data hook for a project can never be changed. Write-once storage. |
| Project weight | CTDeployer | `deployProjectFor()` | Hardcoded at `1_000_000 * 10^18` with ETH base currency and max cashout tax rate. |
| Hook deploy salt | CTDeployer | `deployProjectFor()` | `keccak256(abi.encode(salt, msg.sender))` -- deterministic but caller-specific. |

## Admin Boundaries

What admins CANNOT do:

1. **Project owners cannot change the fee rate.** `FEE_DIVISOR = 20` (5%) is a compile-time constant. No function exists to modify it.

2. **Project owners cannot change the fee recipient.** `FEE_PROJECT_ID` is immutable. Fees always route to the same project.

3. **Project owners cannot change the data hook.** `dataHookOf[projectId]` is write-once (set during `deployProjectFor`, no setter function). The data hook proxy pattern is permanent.

4. **Project owners cannot disable Croptop posting entirely for a category.** `configurePostingCriteriaFor()` requires `minimumTotalSupply > 0`. The workaround is to set an astronomically high `minimumPrice` with `minimumTotalSupply = maximumTotalSupply = 1`. See finding NM-006.

5. **Project owners cannot bypass posting criteria through `CTPublisher`, but they may still bypass the publisher surface entirely.** `mintFrom()` enforces all configured rules. Separately, the initial owner/operator can hold direct hook-management permissions from `CTDeployer`, which lets them adjust tiers or mint without going through `CTPublisher` until ownership is claimed away or permissions are narrowed.

6. **CTPublisher cannot mint without paying.** `mintFrom()` requires `msg.value >= totalPrice + fee`. There is no free-mint path through CTPublisher.

7. **CTProjectOwner cannot return project ownership.** Once a project NFT is transferred to CTProjectOwner, there is no function to transfer it back. Ownership is effectively burned.

8. **No admin can modify existing tier prices.** Once a tier is created via `_setupPosts()`, the price is set in the `JB721TiersHookStore`. CTPublisher uses the stored price for fee calculation on subsequent mints (not `post.price`). See H-19 fix.

9. **No admin can drain CTPublisher funds.** CTPublisher has no `withdraw()` function and no `receive()` / `fallback()`. The only ETH that enters the contract is during `mintFrom()` and it is fully routed to the project terminal and fee terminal within the same transaction. If the fee terminal payment fails, the mint now reverts instead of redirecting that ETH elsewhere.

10. **Sucker registry trust is irrevocable.** The `MAP_SUCKER_TOKEN` permission is granted at CTDeployer construction with `projectId: 0` (wildcard). There is no function to revoke this permission from within CTDeployer.
