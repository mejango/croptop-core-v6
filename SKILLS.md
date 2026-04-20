# Croptop Core

## Use This File For

- Use this file when the task touches Croptop publishing, project deployment, data-hook forwarding, fee routing, or burn-locked ownership.
- Start here, then decide whether the issue is posting-policy validation, tier reuse and content identity, deployer-packaged project shape, or burn-locked ownership.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and expected flow | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Publishing and metadata behavior | [`src/CTPublisher.sol`](./src/CTPublisher.sol) |
| Deployment and fee-project wiring | [`src/CTDeployer.sol`](./src/CTDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`script/ConfigureFeeProject.s.sol`](./script/ConfigureFeeProject.s.sol) |
| Ownership burn-lock behavior | [`src/CTProjectOwner.sol`](./src/CTProjectOwner.sol) |
| Runtime and operational invariants | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Publishing, metadata, and attack coverage | [`test/CTPublisher.t.sol`](./test/CTPublisher.t.sol), [`test/Test_MetadataGeneration.t.sol`](./test/Test_MetadataGeneration.t.sol), [`test/CroptopAttacks.t.sol`](./test/CroptopAttacks.t.sol) |
| Deployment, ownership, and fork coverage | [`test/CTDeployer.t.sol`](./test/CTDeployer.t.sol), [`test/CTProjectOwner.t.sol`](./test/CTProjectOwner.t.sol), [`test/ClaimCollectionOwnership.t.sol`](./test/ClaimCollectionOwnership.t.sol), [`test/Fork.t.sol`](./test/Fork.t.sol), [`test/TestAuditGaps.sol`](./test/TestAuditGaps.sol) |

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

- Open [`references/runtime.md`](./references/runtime.md) for publisher behavior, fee routing, data-hook forwarding, and the main invariants around posting criteria and tier reuse.
- Open [`references/operations.md`](./references/operations.md) for deployer behavior, burn-lock implications, script breadcrumbs, and common stale assumptions.

## Working Rules

- Start in [`src/CTPublisher.sol`](./src/CTPublisher.sol) for posting-rule and fee behavior, but check [`src/CTDeployer.sol`](./src/CTDeployer.sol) when the bug might come from project shape or hook forwarding.
- Treat posting criteria, fee routing, and duplicate-content handling as treasury-sensitive and product-sensitive at the same time.
- Category policy is part of the product surface. Changes to allowlists, supply bounds, or split caps change what can be published.
- If the task mentions project immutability or admin recovery, inspect [`src/CTProjectOwner.sol`](./src/CTProjectOwner.sol) before changing deployer or publisher code.
- Metadata bugs can be publishing bugs, resolver-shape bugs, or duplicate-content bugs. Check all three before assuming a simple formatting issue.
- Duplicate-post and tier-reuse behavior are runtime semantics, not convenience logic.
- When a bug looks like generic 721 issuance, confirm it is not actually in `nana-721-hook-v6`.
