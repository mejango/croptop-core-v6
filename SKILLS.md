# Croptop Core

## Use This File For

- Use this file when the task touches Croptop publishing, project deployment, data-hook forwarding, fee routing, or burn-locked ownership behavior.
- Start here, then jump into the publisher, deployer, or owner contract depending on which path the user is actually asking about.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and expected flow | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Publishing and metadata behavior | [`src/CTPublisher.sol`](./src/CTPublisher.sol) |
| Deployment and fee-project wiring | [`src/CTDeployer.sol`](./src/CTDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`script/ConfigureFeeProject.s.sol`](./script/ConfigureFeeProject.s.sol) |
| Ownership burn-lock behavior | [`src/CTProjectOwner.sol`](./src/CTProjectOwner.sol) |
| Regression, attack, or fork coverage | [`test/regression/`](./test/regression/), [`test/fork/`](./test/fork/), [`test/`](./test/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Types | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Permissioned publishing layer for Juicebox 721 projects. Project owners define posting rules, publishers mint content as tiers through a 721 hook, Croptop routes fees, and the deployer can package the whole project shape in one transaction.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need publisher behavior, fee routing, data-hook forwarding, or the main invariants around posting criteria and tier reuse.
- Open [`references/operations.md`](./references/operations.md) when you need deployer behavior, burn-lock ownership implications, script breadcrumbs, or the common sources of stale assumptions.

## Working Rules

- Start in [`src/CTPublisher.sol`](./src/CTPublisher.sol) for posting-rule and fee behavior, but check [`src/CTDeployer.sol`](./src/CTDeployer.sol) when the bug might come from project shape or hook forwarding.
- Treat posting criteria, fee routing, and duplicate-content handling as treasury-sensitive and product-sensitive at the same time.
- If the task mentions project immutability or admin recovery, inspect [`src/CTProjectOwner.sol`](./src/CTProjectOwner.sol) before changing deployer or publisher code.
- When a bug looks like generic 721 issuance, confirm it is not actually in `nana-721-hook-v6`.
