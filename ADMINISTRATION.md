# Administration

Admin privileges and their scope in croptop-core-v6.

## Roles

### 1. Project Owner

**How assigned:** Receives the JBProjects ERC-721 NFT for the project. Initially set by the `owner` parameter in `CTDeployer.deployProjectFor()` (line 325, `CTDeployer.sol`). Can be transferred via standard ERC-721 transfer.

**Scope:** Per-project. Controls posting rules and hook ownership for a single project.

### 2. Hook Owner

**How assigned:** Determined by `JBOwnable(hook).owner()`. For CTDeployer-launched projects, the deployer initially owns the hook (via `DEPLOYER.deployHookFor()` at line 264). The project owner can later claim hook ownership via `claimCollectionOwnershipOf()` (line 223).

**Scope:** Per-hook. The hook owner (or anyone with `ADJUST_721_TIERS` permission for that hook's project) can configure posting criteria.

### 3. CTDeployer (Contract)

**How assigned:** Immutable singleton deployed at construction. Acts as the `IJBRulesetDataHook` for all CTDeployer-launched projects (set at line 290 of `CTDeployer.sol`).

**Scope:** All Croptop-deployed projects. Proxies pay/cashout data hook calls, grants fee-free cashouts to suckers, and holds broad permissions on behalf of launched projects.

### 4. CTPublisher (Contract)

**How assigned:** Immutable singleton deployed at construction. Receives `ADJUST_721_TIERS` permission from CTDeployer at construction (line 113-119, `CTDeployer.sol`).

**Scope:** All hooks for which it has `ADJUST_721_TIERS` permission. Creates NFT tiers and mints first copies.

### 5. CTProjectOwner (Contract)

**How assigned:** Optional burn-lock proxy. Receives project ownership when a project NFT is `safeTransferFrom`'d to it.

**Scope:** Per-project. Grants `CTPublisher` permanent `ADJUST_721_TIERS` permission for the received project. Once the project is transferred here, human ownership is effectively burned.

### 6. Sucker Registry

**How assigned:** Immutable dependency set at CTDeployer construction (line 98). Receives `MAP_SUCKER_TOKEN` permission at construction (line 101-110, `CTDeployer.sol`).

**Scope:** All projects deployed via CTDeployer. Can map tokens for cross-chain bridging. Determines which addresses get fee-free cashouts.

### 7. Publishers (Poster Addresses)

**How assigned:** Either any address (when allowlist is empty) or explicitly added to a per-hook per-category allowlist via `configurePostingCriteriaFor()`.

**Scope:** Per-hook, per-category. Can create NFT tiers (posts) and mint first copies, subject to posting criteria.

## Privileged Functions

### CTDeployer

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `deployProjectFor()` (line 243) | Anyone | None | Global | Deploys a new Juicebox project with 721 hook, configures posting rules, optionally deploys suckers, transfers ownership to `owner`. No access restriction -- anyone can deploy a project. |
| `claimCollectionOwnershipOf()` (line 223) | Project owner | None (direct `ownerOf` check) | Per-project | Transfers hook ownership to the project via `JBOwnable.transferOwnershipToProject()`. Caller must be `PROJECTS.ownerOf(projectId)`. |
| `deploySuckersFor()` (line 346) | Project owner or delegate | `JBPermissionIds.DEPLOY_SUCKERS` | Per-project | Deploys new cross-chain suckers for an existing project. Uses `_requirePermissionFrom()` against the project owner. |

### CTPublisher

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `configurePostingCriteriaFor()` (line 230) | Hook owner or delegate | `JBPermissionIds.ADJUST_721_TIERS` | Per-hook, per-category | Sets posting rules: minimum price, min/max supply, max split percent, address allowlist. Uses `_requirePermissionFrom()` against `JBOwnable(hook).owner()`. |
| `mintFrom()` (line 297) | Anyone (subject to allowlist) | None (enforced by allowlist in `_setupPosts`) | Per-hook | Publishes posts as 721 tiers, mints first copies, routes 5% fee to `FEE_PROJECT_ID`. Validates all posts against configured criteria. |

### CTProjectOwner

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `onERC721Received()` (line 47) | Anyone who transfers a JBProjects NFT | None | Per-project | On receiving a project NFT from `PROJECTS` (mint only, `from == address(0)` is NOT enforced here), grants `CTPublisher` the `ADJUST_721_TIERS` permission for that project. |

### Permissions Granted at CTDeployer Construction

These permissions are set in the CTDeployer constructor and apply to all projects it will ever deploy (wildcard `projectId: 0`):

| Permission | Granted To | Line | Purpose |
|-----------|-----------|------|---------|
| `MAP_SUCKER_TOKEN` | `SUCKER_REGISTRY` | 101-110 | Allows the sucker registry to map tokens for cross-chain bridging on any project owned by CTDeployer. |
| `ADJUST_721_TIERS` | `PUBLISHER` (CTPublisher) | 113-119 | Allows CTPublisher to add tiers to any hook on any project owned by CTDeployer. |

### Permissions Granted During `deployProjectFor()`

These permissions are set per-project during deployment (line 328-339, `CTDeployer.sol`):

| Permission | Granted To | Line | Purpose |
|-----------|-----------|------|---------|
| `ADJUST_721_TIERS` | `owner` | 329 | Allows the project owner to adjust 721 tiers. |
| `SET_721_METADATA` | `owner` | 330 | Allows the project owner to update 721 metadata. |
| `MINT_721` | `owner` | 331 | Allows the project owner to mint 721 tokens directly. |
| `SET_721_DISCOUNT_PERCENT` | `owner` | 332 | Allows the project owner to set tier discount percentages. |

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
| `dataHookOf[projectId]` | CTDeployer | `deployProjectFor()` (line 307) | Once set during deployment, the data hook for a project can never be changed. Write-once storage. |
| Project weight | CTDeployer | `deployProjectFor()` (line 256) | Hardcoded at `1_000_000 * 10^18` with ETH base currency and max cashout tax rate. |
| Hook deploy salt | CTDeployer | `deployProjectFor()` (line 286) | `keccak256(abi.encode(salt, msg.sender))` -- deterministic but caller-specific. |

## Admin Boundaries

What admins CANNOT do:

1. **Project owners cannot change the fee rate.** `FEE_DIVISOR = 20` (5%) is a compile-time constant. No function exists to modify it.

2. **Project owners cannot change the fee recipient.** `FEE_PROJECT_ID` is immutable. Fees always route to the same project.

3. **Project owners cannot change the data hook.** `dataHookOf[projectId]` is write-once (set during `deployProjectFor`, no setter function). The data hook proxy pattern is permanent.

4. **Project owners cannot disable Croptop posting entirely for a category.** `configurePostingCriteriaFor()` requires `minimumTotalSupply > 0` (line 250-252, `CTPublisher.sol`). The workaround is to set an astronomically high `minimumPrice` with `minimumTotalSupply = maximumTotalSupply = 1`. See finding NM-006.

5. **Project owners cannot bypass posting criteria to mint directly through CTPublisher.** They must use `mintFrom()` like anyone else, which enforces all configured rules. However, owners can adjust tiers directly on the hook (bypassing CTPublisher) if they have `ADJUST_721_TIERS` permission.

6. **CTPublisher cannot mint without paying.** `mintFrom()` requires `msg.value >= totalPrice + fee` (line 332-334). There is no free-mint path through CTPublisher.

7. **CTProjectOwner cannot return project ownership.** Once a project NFT is transferred to CTProjectOwner, there is no function to transfer it back. Ownership is effectively burned.

8. **No admin can modify existing tier prices.** Once a tier is created via `_setupPosts()`, the price is set in the `JB721TiersHookStore`. CTPublisher uses the stored price for fee calculation on subsequent mints (not `post.price`). See H-19 fix.

9. **No admin can drain CTPublisher funds.** CTPublisher has no `withdraw()` function and no `receive()` / `fallback()`. The only ETH that enters the contract is during `mintFrom()` and it is fully routed to the project terminal and fee terminal within the same transaction.

10. **Sucker registry trust is irrevocable.** The `MAP_SUCKER_TOKEN` permission is granted at CTDeployer construction with `projectId: 0` (wildcard). There is no function to revoke this permission from within CTDeployer.
