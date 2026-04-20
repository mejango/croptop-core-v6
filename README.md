# Croptop Core

Croptop turns a Juicebox project with a 721 hook into a permissioned publishing marketplace. Project owners define posting rules, then anyone who meets those rules can publish new NFT tiers and mint the first copy of each post.

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

- project owners set category-level posting rules such as price floors, supply bounds, split limits, and optional allowlists
- publishers call `mintFrom` to create or reuse 721 tiers that represent their post
- a one-click deployer can create a full Juicebox project, its 721 hook config, and its posting rules in one transaction

Every mint collects a 5% Croptop fee unless the target project is itself the fee project. If the fee terminal rejects that fee payment, Croptop refunds the fee portion to `_msgSender()` and still lets the publish continue. If `_msgSender()` cannot receive ETH, the mint reverts.

Use this repo when the product is permissioned publishing on top of a Juicebox project. Do not use it for plain 721 tier sales.

## Key Contracts

| Contract | Role |
| --- | --- |
| `CTPublisher` | Validates posts, adjusts 721 tiers, mints the first copy, and routes protocol and project payments. |
| `CTDeployer` | Launches a project, configures Croptop posting rules, and can wire in omnichain sucker deployments. |
| `CTProjectOwner` | Ownership sink that can permanently hold a project NFT while still delegating the posting permissions Croptop needs. |

## Mental Model

There are two separate concerns here:

1. `CTPublisher` decides whether a post is allowed and how it becomes a tier
2. `CTDeployer` decides how a Croptop-flavored project is packaged and launched

Many Croptop bugs are really deployment-shape bugs or posting-policy bugs, not generic 721 bugs.

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

- Croptop publishing policy is separate from ordinary 721 tier issuance
- fee routing is part of the publish path and its fallback behavior matters
- `CTProjectOwner` intentionally changes the ownership model and should be reviewed as part of the trust model
- duplicate-content, stale-tier, and fee-evasion edge cases are runtime behavior, not just UI concerns

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

Deployments are handled through Sphinx. `CTDeployer` can also compose cross-chain sucker deployments when a nonzero sucker configuration is supplied. The deploy script expects an explicit nonzero `FEE_PROJECT_ID` for production-style deployments.

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
- fee routing depends on the fee project staying correctly configured
- parking a project in `CTProjectOwner` is effectively irreversible
- after routing ownership into `CTProjectOwner`, the old owner no longer holds the project NFT directly
- duplicate-content and stale-tier edge cases are economically relevant, not cosmetic

## For AI Agents

- Do not describe Croptop as a generic 721 marketplace.
- Read `CTPublisher` before `CTDeployer` when the question is about publish eligibility or fee behavior.
- If the issue is basic tier minting or accounting, move to `nana-721-hook-v6` or `nana-core-v6`.
