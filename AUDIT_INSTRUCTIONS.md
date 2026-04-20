# Audit Instructions

Croptop is a publishing layer on top of Juicebox projects and the tiered 721 stack. Audit it as a permissions, fee-routing, and project-launch system.

## Audit Objective

Find issues that:

- let publishers create or mint posts outside configured criteria
- let users evade Croptop fees or route them incorrectly
- grant fee-free or privileged cash-outs to the wrong actors
- make tier reuse bypass stale-content, fee, or policy checks
- leave a project in an unintended ownership or admin state

## Scope

In scope:

- `src/CTPublisher.sol`
- `src/CTDeployer.sol`
- `src/CTProjectOwner.sol`
- all interfaces in `src/interfaces/`
- all structs in `src/structs/`
- deployment helpers in `script/`

## Start Here

1. `src/CTPublisher.sol`
2. `src/CTDeployer.sol`
3. `src/CTProjectOwner.sol`

## Security Model

Croptop composes several subsystems:

- `CTPublisher` enforces posting criteria, creates or adjusts tiers, and routes fees
- `CTDeployer` launches projects and wires hooks, criteria, and ownership helpers
- `CTProjectOwner` lets a project follow Croptop-specific admin rules instead of a fixed EOA

Trust boundaries that matter:

- project owners choose policy, but should not be able to bypass the policy they configured
- fee recipients and external hooks may revert or reenter
- sucker-based privileges must stay limited to genuine omnichain components

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project owner | Choose policy and ownership mode | Must not bypass the active policy through helper paths |
| `CTPublisher` | Create or reuse tiers and route fees | Must stay within configured criteria |
| `CTDeployer` | Launch projects and wire helpers | Must not retain unexpected post-launch authority |
| Sucker integration | Access narrow omnichain-only paths | Must be backed by authentic registry state |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-721-hook-v6` | Tier state and tier adjustments match Croptop policy checks | Posting criteria and tier-reuse safety break |
| `nana-core-v6` | Terminal and project routing are authentic | Fee routing and publish settlement drift |
| `nana-ownable-v6` | Ownership helper resolves the intended admin | Projects can end up misowned or stranded |
| `nana-suckers-v6` | Registry identifies genuine omnichain actors | Fee-free or privileged paths widen incorrectly |

## Critical Invariants

1. Minimum price, supply bounds, split limits, category restrictions, and allowlists stay binding on every publish path.
2. Every Croptop mint either pays the configured fee or takes the documented fallback path without underpaying Croptop.
3. Existing tiers cannot be reused in a way that revives stale criteria or dodges fee collection.
4. Sucker-only or fee-exempt paths cannot be reached through spoofed registry state or stale deployment wiring.
5. Ownership handoff and burn-lock flows do not accidentally widen privileges or strand administration.

## Attack Surfaces

- publish and mint entrypoints
- fee computation from user input versus onchain state
- tier creation, adjustment, and reuse logic
- deployer-mediated pay or cash-out data-hook behavior
- permission grants during deployment and ownership transfer

## Accepted Risks Or Behaviors

- Fee routing may degrade to a fallback path rather than block publishing entirely.

## Verification

- `npm install`
- `forge build`
- `forge test`
