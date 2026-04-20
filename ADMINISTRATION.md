# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Croptop deployment flow, publish-policy administration, and irreversible project owner sink behavior |
| Control posture | Mixed deployer-managed and project-local control |
| Highest-risk actions | Burn-locking a project into `CTProjectOwner`, misconfiguring posting criteria, and deploying suckers with the wrong authority assumptions |
| Recovery posture | Posting policy can often be changed, but burn-lock and some deployer wiring choices require replacement flows |

## Purpose

`croptop-core-v6` has two distinct control planes: project-local publishing control and deployer-level structural wiring. The high-risk surfaces are posting criteria, hook ownership, publisher permissions, and the irreversible `CTProjectOwner` burn-lock path.

## Control Model

- `CTPublisher` enforces publish policy but does not own the project.
- `CTDeployer` is both a deployment helper and a live ruleset data-hook wrapper.
- The initial project owner receives direct hook-management permissions from `CTDeployer` at deployment time.
- Project owners or delegates administer publishing through the hook owner and `JBPermissions`.
- `CTProjectOwner` is an irreversible ownership sink for projects that want Croptop-mediated control.
- `SUCKER_REGISTRY` and `PUBLISHER` receive structural permissions from `CTDeployer`.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | May grant delegates through `JBPermissions` |
| Hook owner | `JBOwnable(hook).owner()` | Per hook | Often resolves to the project owner after claim |
| `CTDeployer` | Immutable singleton | Global | Launch helper and runtime wrapper |
| `CTPublisher` | Immutable singleton | Global runtime surface | Needs `ADJUST_721_TIERS` authority on relevant hooks |
| `CTProjectOwner` | Receives project NFT transfer | Per project | Burn-lock path; no return function |
| `SUCKER_REGISTRY` | Immutable dependency | Global | Holds wildcard `MAP_SUCKER_TOKEN` from the deployer |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `CTDeployer` | `deployProjectFor(...)` | Anyone | Launches a Croptop-shaped project and configures initial permissions |
| `CTDeployer` | `claimCollectionOwnershipOf(...)` | Current project owner | Transfers hook ownership from the deployer path to the project |
| `CTDeployer` | `deploySuckersFor(...)` | Project owner or `DEPLOY_SUCKERS` delegate | Extends a project with suckers |
| `CTPublisher` | `configurePostingCriteriaFor(...)` | Hook owner or `ADJUST_721_TIERS` delegate | Changes posting policy for a hook and category |
| `CTPublisher` | `mintFrom(...)` | Anyone subject to policy | Publishes posts, mints first copies, and routes the Croptop fee |
| `CTProjectOwner` | `onERC721Received(...)` | Any project NFT transfer into it | Locks the project into the Croptop owner helper and grants `CTPublisher` tier-adjust authority |

The important nuance is:

- after `deployProjectFor(...)`, the initial project owner can directly manage tiers, metadata, minting, and discount percent through permissions granted from `CTDeployer`
- this means the owner can bypass the publisher path until ownership is claimed away from `CTDeployer`

## Immutable And One-Way

- `CTDeployer`'s wildcard permission grants to `SUCKER_REGISTRY` and `CTPublisher` are structural.
- `dataHookOf[projectId]` is write-once through deployment flow.
- Sending a project NFT into `CTProjectOwner` is effectively irreversible.
- `FEE_PROJECT_ID` in `CTPublisher` is constructor-immutable.

## Operational Notes

- Validate posting criteria before broad publisher access; the publisher enforces those rules on every post.
- Decide intentionally whether the project should keep the initial direct-management path or move to project-owned hook control with `claimCollectionOwnershipOf(...)`.
- Use `claimCollectionOwnershipOf(...)` when the project should own the hook directly instead of relying on the deployer as the ownership bridge.
- Treat the burn-lock path as governance finality, not convenience.
- Review Croptop deployer changes as both launch-time and runtime changes.

## Machine Notes

- Do not treat `CTDeployer` as a passive script helper; it is also part of the live runtime path.
- Treat `src/CTPublisher.sol`, `src/CTDeployer.sol`, and `src/CTProjectOwner.sol` as the minimum source set for control-plane crawling.
- If a project NFT has already been sent to `CTProjectOwner`, stop assuming the original owner can recover it.

## Recovery

- If posting policy is wrong but the project still controls the hook, fix it through `configurePostingCriteriaFor(...)`.
- If the wrong hook path or burn-lock path was chosen, recovery usually means a new project or new hook arrangement.
- `CTProjectOwner` is not a reversible safety valve.

## Admin Boundaries

- Neither project owners nor Croptop can change the fixed Croptop fee divisor in `CTPublisher`.
- `CTPublisher` cannot trap fee ETH intentionally; failed fee-terminal payments refund `_msgSender()` or revert.
- `CTProjectOwner` cannot return project ownership once it receives the NFT.
- `CTDeployer` cannot later rewrite `dataHookOf[projectId]` through a setter.
- `CTDeployer` does not stop the initial project owner from using the directly granted hook permissions before ownership is claimed away.

## Source Map

- `src/CTPublisher.sol`
- `src/CTDeployer.sol`
- `src/CTProjectOwner.sol`
- `script/Deploy.s.sol`
- `script/helpers/CroptopDeploymentLib.sol`
- `test/TestAuditGaps.sol`
