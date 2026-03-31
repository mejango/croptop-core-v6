# Croptop Core

Croptop turns a Juicebox project with a 721 hook into a permissioned publishing marketplace. Project owners define posting criteria, then anyone who meets those rules can publish new NFT tiers and mint the first copy of each post.

Docs: <https://docs.juicebox.money>  
Site: <https://croptop.eth.limo>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

Croptop is built around three ideas:

- project owners set category-level posting criteria such as price floors, supply bounds, split limits, and optional allowlists
- publishers call `mintFrom` to create or reuse 721 tiers that represent their post
- a one-click deployer can create a full Juicebox project, its 721 hook configuration, and its posting rules in a single transaction

Every mint collects a 5% Croptop fee unless the target project is itself the fee project.

Use this repo when the product is "permissioned publishing on a Juicebox project." Do not use it when you only need plain 721 tier sales; that belongs in `nana-721-hook-v6`.

If a bug looks like ordinary tier issuance or terminal accounting, start in the 721 hook or core repo first. Croptop is where posting policy, fee routing, and publishing-specific project wiring begin.

## Key Contracts

| Contract | Role |
| --- | --- |
| `CTPublisher` | Validates posts, adjusts 721 tiers, mints the first copy, and routes protocol and project payments. |
| `CTDeployer` | Launches a project, configures Croptop posting rules, and can wire in omnichain sucker deployments. |
| `CTProjectOwner` | Burn-lock ownership helper that can permanently route project administration through Croptop's publishing surface. |

## Mental Model

There are two separate concerns here:

1. `CTPublisher` governs whether a post is allowed and how it becomes a tier
2. `CTDeployer` governs how a Croptop-flavored project is packaged and launched

That distinction matters because many "Croptop bugs" are deployment-shape bugs rather than publishing-rule bugs.

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

Deployments are handled through Sphinx using the environments configured in the repo scripts. `CTDeployer` can also compose cross-chain sucker deployments when the target publishing project needs omnichain support.

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
- fee routing depends on the designated fee project remaining correctly configured
- burn-lock ownership is intentionally irreversible and should only be used when immutability is desired
- duplicate-content and stale-tier edge cases are guarded by tests, but integrations should still treat metadata reuse carefully
