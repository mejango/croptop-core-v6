# Changelog

## Scope

This file describes the verified change from `croptop-core-v5` to the current `croptop-core-v6` repo.

## Current v6 surface

- `CTDeployer`
- `CTProjectOwner`
- `CTPublisher`
- `CTAllowedPost`
- `CTDeployerAllowedPost`
- `CTPost`

## Summary

- `CTPost` and the related allowlist structs now carry split-routing data, so a post can route part of its payment through `JBSplit[]` recipients.
- The deployer now acts as the data-hook entry point instead of wiring the 721 hook directly, which is what enables the intended omnichain and sucker-aware cash-out behavior.
- v6 closes several correctness gaps that were easy to miss in v5: duplicate posts in a batch are rejected, existing tiers use on-chain pricing instead of caller-supplied pricing, and stale tier mappings are recreated when tiers were removed externally.
- The repo was moved to the v6 dependency set and Solidity `0.8.28`.

## Verified deltas

- `CTPost` gained `splitPercent` and `JBSplit[] splits`.
- `CTAllowedPost` and `CTDeployerAllowedPost` gained `maximumSplitPercent`.
- `ICTPublisher.allowanceFor(...)` now returns five values instead of four because `maximumSplitPercent` is part of the result.
- `CTDeployer` now points project metadata to itself as the data hook instead of pointing directly at the 721 hook.
- The repo carries dedicated regression tests for duplicate-URI fee evasion, stale tier mappings, and existing-tier pricing.

## Breaking ABI changes

- `CTPost` is not v5-compatible because it now includes `splitPercent` and `splits`.
- `CTAllowedPost` and `CTDeployerAllowedPost` are not v5-compatible because they now include `maximumSplitPercent`.
- `ICTPublisher.allowanceFor(...)` return decoding changed because of the added field.

## Indexer impact

- Any event or log decoding path that embeds `CTPost` or `CTAllowedPost` must be updated for the new struct layouts.
- Post-publishing integrations should not assume the old "all payment goes to treasury" model once split-bearing posts are live.

## Migration notes

- Rebuild any ABI or indexer code that decodes `CTPost` or `CTAllowedPost`. Their layouts are not v5-compatible.
- If you integrated the deployer as if the 721 hook were the direct data hook, update that assumption. The deployer is now part of the routing path.
- Re-check any fee logic that trusted caller-supplied prices for existing tiers. That is not the v6 behavior.

## ABI appendix

- Changed structs
  - `CTPost`
  - `CTAllowedPost`
  - `CTDeployerAllowedPost`
- Changed decoding expectations
  - `ICTPublisher.allowanceFor(...)`
- Behaviorally important surface shift
  - deployer acts as the data-hook entrypoint
