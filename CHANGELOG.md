# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `croptop-core-v5` in `../../v5/evm` with the current `croptop-core-v6` repo.

## Current V6 Surface

- `CTDeployer`
- `CTProjectOwner`
- `CTPublisher`
- `CTAllowedPost`
- `CTDeployerAllowedPost`
- `CTPost`
- `CTProjectConfig`
- `CTSuckerDeploymentConfig`

## Summary

- Croptop posts can now carry split-routing data. A post can route part of its payment through `JBSplit[]` recipients instead of assuming all value goes to the project treasury.
- Publisher mints are token-aware. `CTPublisher.mintFrom(...)` accepts a payment token and amount, supports native-token payments and ERC-20 payments, and can use Permit2 metadata for publisher-targeted ERC-20 pulls.
- Cross-currency post pricing now reads the 721 hook's `PRICES` oracle when the payment token differs from the post's pricing currency.
- The deployer acts as the V6 data hook entry point rather than wiring the 721 hook directly.
- `CTDeployer` advertises the resolved fee payer through `IJBPayerTracker` while it forwards a project-creation fee to `JBProjects.createFor`, so a `pay`-routing fee receiver credits the end user who launched the project instead of the deployer.
- V6 adds checks for duplicate posts, stale tier mappings, missing fee terminals, and terminal paths that accept payment without delivering the expected NFTs.

## ABI, Event, and Error Changes

- Changed structs:
  - `CTPost` gained `splitPercent` and `JBSplit[] splits`.
  - `CTAllowedPost` gained `maximumSplitPercent`.
  - `CTDeployerAllowedPost` gained `maximumSplitPercent`.
- Changed function shapes:
  - `ICTPublisher.allowanceFor(...)` returns one more value because it now includes `maximumSplitPercent`.
  - `CTPublisher.mintFrom(...)` includes token-aware payment inputs and no longer matches the V5 native-payment-only shape.
- Added view surface:
  - `PERMIT2()` on the publisher interface.
  - `originalPayer()` on `CTDeployer`, which now implements `IJBPayerTracker` and reports the resolved creation-fee payer while `deployProjectFor` forwards the fee to `JBProjects`.
- Indexer impact:
  - Any log or calldata decoder that embeds `CTPost`, `CTAllowedPost`, or `CTDeployerAllowedPost` must be regenerated from the V6 ABI.
  - Do not infer "all payment goes to treasury" from V5 Croptop posts once split-bearing posts are live.

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `croptop-core-v5`.
- Own-source ABI artifacts compared: V6 `6`, V5 `11`.
- Contract/interface coverage: `0` added, `5` removed, `4` shared names with ABI changes, `2` shared names ABI-identical.
- Shared-name ABI item deltas: `38` added, `16` removed, `4` modified.

Removed V5 ABI artifacts:
- `CTAllowedPost` from `src/structs/CTAllowedPost.sol`: `0` functions, `0` events, `0` errors.
- `CTDeployerAllowedPost` from `src/structs/CTDeployerAllowedPost.sol`: `0` functions, `0` events, `0` errors.
- `CTPost` from `src/structs/CTPost.sol`: `0` functions, `0` events, `0` errors.
- `CTProjectConfig` from `src/structs/CTProjectConfig.sol`: `0` functions, `0` events, `0` errors.
- `CTSuckerDeploymentConfig` from `src/structs/CTSuckerDeploymentConfig.sol`: `0` functions, `0` events, `0` errors.

Shared ABI artifacts with changes:
- `CTDeployer`: `4` added, `3` removed, `1` modified ABI items.
- `CTPublisher`: `27` added, `8` removed, `2` modified ABI items.
- `ICTDeployer`: `2` added, `2` removed, `0` modified ABI items.
- `ICTPublisher`: `5` added, `3` removed, `1` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `CTDeployer_SuckerDeploymentFailed`, `Mint`, `Permit2AllowanceFailed`.
- Event names removed or replaced:
  - `Mint`.
- Error names added:
  - `CTPublisher_DuplicatePayMetadata`, `CTPublisher_DuplicatePost`, `CTPublisher_EmptyEncodedIpfsUri`, `CTPublisher_FeePaymentFailed`, `CTPublisher_InsufficientPayment`, `CTPublisher_InvalidFeeBeneficiary`, `CTPublisher_InvalidPaymentTokenContext`, `CTPublisher_MintNotDelivered`.
  - `CTPublisher_MsgValueNotAllowed`, `CTPublisher_NativeTokenAmountMismatch`, `CTPublisher_NoPosts`, `CTPublisher_OverflowAlert`, `CTPublisher_PermitAllowanceNotEnough`, `CTPublisher_PriceFeedUnavailable`, `CTPublisher_ReentrantTokenTransfer`, `CTPublisher_TemporaryAllowanceNotConsumed`.
  - `CTPublisher_UnauthorizedToPostInCategory`, `CTPublisher_ZeroTotalSupply`, `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_MetadataTooLong`, `JBMetadataResolver_MetadataTooShort`, `SafeERC20FailedOperation`.
- Error names removed or replaced:
  - `CTPublisher_EmptyEncodedIPFSUri`, `CTPublisher_UnauthorizedToPostInCategory`, `CTPublisher_ZeroTotalSupply`, `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_MetadataTooShort`.

Shared ABI artifacts checked with no ABI item changes:
- `CTProjectOwner`, `ICTProjectOwner`.

## Migration Notes

- Rebuild frontend, indexer, and backend types from the V6 interfaces and structs.
- Update publisher payment flows to pass the terminal token and amount, and add Permit2 metadata when using Permit2-backed ERC-20 payments.
- Treat the deployer as part of the active data-hook path in V6.
