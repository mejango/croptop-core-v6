# Croptop Core

Croptop turns a Juicebox project with a 721 hook into a permissioned publishing marketplace. Project owners define posting criteria, then anyone who meets those rules can publish new NFT tiers and mint the first copy of each post.

Docs: <https://docs.juicebox.money>  
Site: <https://croptop.eth.limo>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## Overview

Croptop is built around three ideas:

- project owners set category-level posting criteria such as price floors, supply bounds, split limits, and optional allowlists
- publishers call `mintFrom` to create or reuse 721 tiers that represent their post
- a one-click deployer can create a full Juicebox project, its 721 hook configuration, and its posting rules in a single transaction

Every mint collects a 5% Croptop fee unless the target project is itself the fee project. If the configured fee
terminal rejects that fee payment, Croptop refunds the fee portion to `_msgSender()` and still lets the publish
continue. If `_msgSender()` cannot receive ETH, the mint reverts.

Use this repo when the product is "permissioned publishing on a Juicebox project." Do not use it when you only need plain 721 tier sales; that belongs in `nana-721-hook-v6`.

If a bug looks like ordinary tier issuance or terminal accounting, start in the 721 hook or core repo first. Croptop is where posting policy, fee routing, and publishing-specific project wiring begin.

## Key Contracts

| Contract | Role |
| --- | --- |
| `CTPublisher` | Validates posts, adjusts 721 tiers, mints the first copy, and routes protocol and project payments. |
| `CTDeployer` | Launches a project, configures Croptop posting rules, and can wire in omnichain sucker deployments. |
| `CTProjectOwner` | Ownership sink that can permanently hold a project NFT while still delegating the posting permissions Croptop needs. |

## Mental Model

There are two separate concerns here:

1. `CTPublisher` governs whether a post is allowed and how it becomes a tier
2. `CTDeployer` governs how a Croptop-flavored project is packaged and launched

That distinction matters because many "Croptop bugs" are deployment-shape bugs rather than publishing-rule bugs.

## Read These Files First

1. `src/CTPublisher.sol`
2. `src/CTDeployer.sol`
3. `src/CTProjectOwner.sol`
4. `test/CTPublisher.t.sol`
5. `test/ClaimCollectionOwnership.t.sol`

## High-Signal Tests

1. `test/CTPublisher.t.sol`
2. `test/CTDeployer.t.sol`
3. `test/ClaimCollectionOwnership.t.sol`
4. `test/audit/FeeFallbackBlackhole.t.sol`
5. `test/regression/DuplicateUriFeeEvasion.t.sol`

## Integration Traps

- Croptop publishing policy is separate from ordinary 721 tier issuance, so readers often stop in the wrong repo
- fee routing is part of the publish path and has fallback behavior that affects who must be able to receive ETH
- `CTProjectOwner` intentionally changes the project's ownership shape and should be reviewed as part of the trust model
- duplicate-content, stale-tier, and fee-evasion edge cases are first-class surfaces, not only UI concerns

## Where State Lives

- posting criteria and publish-side enforcement live in `CTPublisher`
- deployment-time project wiring lives in `CTDeployer`
- ownership-sink behavior lives in `CTProjectOwner`
- actual tier issuance and treasury accounting still live in sibling Juicebox repos

## Install

```bash
npm install @croptop/core-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`
- `npm run deploy:mainnets:project`
- `npm run deploy:testnets:project`

## Deployment Notes

Deployments are handled through Sphinx using the environments configured in the repo scripts. `CTDeployer` can also compose cross-chain sucker deployments when a nonzero sucker configuration is supplied for the target publishing project.

The deploy script now expects an explicit nonzero `FEE_PROJECT_ID` for production-style deployments. It does not safely
autodiscover a fee project by scanning existing project IDs.

## Repository Layout

```text
src/
  CTPublisher.sol
  CTDeployer.sol
  CTProjectOwner.sol
  interfaces/
  structs/
test/
  publisher, deployer, fork, attack, audit, metadata, and regression coverage
script/
  Deploy.s.sol
  ConfigureFeeProject.s.sol
  helpers/
```

## Risks And Notes

- posting criteria are only as safe as the project owner configures them
- fee routing depends on the designated fee project remaining correctly configured; if its terminal rejects payments,
  Croptop refunds the fee to `_msgSender()` instead of trapping ETH in `CTPublisher`
- parking a project in `CTProjectOwner` is intentionally irreversible in practice and should only be used when immutability is desired
- after routing ownership into `CTProjectOwner`, the previous owner no longer holds the project NFT directly; control is
  intentionally mediated through Croptop's owner helper and hook-admin surface instead of remaining a plain owner EOA
- duplicate-content and stale-tier edge cases are guarded by tests, but integrations should still treat metadata reuse carefully

## For AI Agents

- Do not describe Croptop as a generic 721 marketplace; it is a rules-driven publishing layer on top of Juicebox.
- Read `CTPublisher` before `CTDeployer` when the question is about publish eligibility or fee behavior.
- If the issue is basic tier minting or accounting, move to `nana-721-hook-v6` or `nana-core-v6`.
