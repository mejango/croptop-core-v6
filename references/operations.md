# Croptop Operations

## Deployment Surface

- [`src/CTDeployer.sol`](../src/CTDeployer.sol) is the first stop for project launch shape, hook forwarding, and optional sucker integration.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) and [`script/ConfigureFeeProject.s.sol`](../script/ConfigureFeeProject.s.sol) cover the current deployment and fee-project wiring.
- [`src/structs/`](../src/structs/) contains config types that often drift from memory.

## Change Checklist

- If you edit posting criteria, verify both direct publisher calls and deployer-created project flows.
- If you edit fee behavior, check both the designated fee project path and any exemption behavior.
- If you edit burn-lock ownership assumptions, confirm the intended irreversibility still holds.
- If you edit data-hook forwarding, re-check sucker-related fee-free cash-out behavior.

## Common Failure Modes

- Publishing bug is blamed on the publisher when the deployer packaged the project or hook incorrectly.
- Immutable-owner expectations are missed after ownership moves into [`src/CTProjectOwner.sol`](../src/CTProjectOwner.sol).
- Content reuse or duplicate-post behavior changes and silently alters user-facing publishing semantics.

## Useful Proof Points

- [`test/fork/`](../test/fork/) when deployment shape matters.
- [`script/helpers/`](../script/helpers/) if the issue is really script/config assembly.
