// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {ICTPublisher} from "./interfaces/ICTPublisher.sol";
import {CTAllowedPost} from "./structs/CTAllowedPost.sol";
import {CTPost} from "./structs/CTPost.sol";

/// @notice The Croptop publishing engine. Allows anyone to publish NFT posts to a Juicebox project's 721 hook, subject
/// to per-category posting criteria set by the collection owner (minimum price, supply bounds, allowlist, max split
/// percent). On each mint, the publisher creates new 721 tiers, routes a 5% fee to the fee project, and pays the
/// remainder into the project's terminal. Duplicate IPFS URIs are tracked so subsequent mints of the same content reuse
/// the existing tier rather than creating a new one.
contract CTPublisher is JBPermissioned, ERC2771Context, ICTPublisher {
    // A library that handles optional-return ERC-20 operations.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error CTPublisher_DuplicatePayMetadata(bytes4 payMetadataId);
    error CTPublisher_DuplicatePost(bytes32 encodedIpfsUri);
    error CTPublisher_EmptyEncodedIpfsUri(uint256 postIndex);
    error CTPublisher_FeePaymentFailed(uint256 feeAmount);
    error CTPublisher_InsufficientEthSent(uint256 expected, uint256 sent);
    error CTPublisher_InsufficientPayment(uint256 expected, uint256 sent);
    error CTPublisher_InvalidFeeBeneficiary();
    error CTPublisher_InvalidPaymentTokenContext(
        address token, uint256 tokenCurrency, uint256 tokenDecimals, uint256 pricingCurrency, uint256 pricingDecimals
    );
    error CTPublisher_MaxTotalSupplyLessThanMin(uint256 min, uint256 max);
    error CTPublisher_MintNotDelivered(
        address hook, address beneficiary, uint256 expectedBalance, uint256 actualBalance
    );
    error CTPublisher_MsgValueNotAllowed(uint256 value);
    error CTPublisher_NativeTokenAmountMismatch(uint256 amount, uint256 msgValue);
    error CTPublisher_NoPosts(address caller);
    error CTPublisher_NotInAllowList(address addr, address[] allowedAddresses);
    error CTPublisher_PriceTooSmall(uint256 price, uint256 minimumPrice);
    error CTPublisher_SplitPercentExceedsMaximum(uint256 splitPercent, uint256 maximumSplitPercent);
    error CTPublisher_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);
    error CTPublisher_TotalSupplyTooBig(uint256 totalSupply, uint256 maximumTotalSupply);
    error CTPublisher_TotalSupplyTooSmall(uint256 totalSupply, uint256 minimumTotalSupply);
    error CTPublisher_UnauthorizedToPostInCategory(address hook, uint24 category);
    error CTPublisher_ZeroTotalSupply(address hook, uint24 category);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The divisor that describes the fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent.
    uint256 public constant override FEE_DIVISOR = 20;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory that contains the projects to post to.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The ID of the project to which fees will be routed.
    uint256 public immutable override FEE_PROJECT_ID;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The ID of the tier that an IPFS metadata has been saved to.
    /// @custom:param hook The hook for which the tier ID applies.
    /// @custom:param encodedIpfsUri The IPFS URI.
    mapping(address hook => mapping(bytes32 encodedIpfsUri => uint256)) public override tierIdForEncodedIpfsUriOf;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice Stores addresses that are allowed to post onto a hook category.
    /// @custom:param hook The hook for which this allowance applies.
    /// @custom:param category The category for which the allowance applies.
    /// @custom:param address The address to check an allowance for.
    mapping(address hook => mapping(uint256 category => address[])) internal _allowedAddresses;

    /// @notice Packed values that determine the allowance of posts.
    /// @custom:param hook The hook for which this allowance applies.
    /// @custom:param category The category for which the allowance applies.
    mapping(address hook => mapping(uint256 category => uint256)) internal _packedAllowanceFor;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory that contains the projects to post to.
    /// @param permissions A contract storing permissions.
    /// @param feeProjectId The ID of the project to which fees will be routed.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        uint256 feeProjectId,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = directory;
        FEE_PROJECT_ID = feeProjectId;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Lets collection owners define the rules for what can be posted in each category: minimum price, supply
    /// bounds, maximum split percent, and an optional allowlist of addresses. Each call replaces the existing criteria
    /// for the specified categories.
    /// @param allowedPosts An array of criteria for allowed posts.
    // Categories cannot be fully disabled after creation. This is by design — once a category is
    // created, removing posting would break expectations for existing posters. Projects can set restrictive
    // allowedPost configurations to effectively disable new posts without removing the category.
    function configurePostingCriteriaFor(CTAllowedPost[] memory allowedPosts) external override {
        // Keep a reference to the number of post criteria.
        uint256 numberOfAllowedPosts = allowedPosts.length;

        // For each post criteria, save the specifications.
        for (uint256 i; i < numberOfAllowedPosts;) {
            // Set the post criteria being iterated on.
            CTAllowedPost memory allowedPost = allowedPosts[i];

            emit ConfigurePostingCriteria({hook: allowedPost.hook, allowedPost: allowedPost, caller: _msgSender()});

            // Enforce permissions.
            _requirePermissionFrom({
                account: JBOwnable(allowedPost.hook).owner(),
                projectId: IJB721TiersHook(allowedPost.hook).projectId(),
                permissionId: JBPermissionIds.ADJUST_721_TIERS
            });

            // Make sure there is a minimum supply.
            if (allowedPost.minimumTotalSupply == 0) {
                revert CTPublisher_ZeroTotalSupply({hook: allowedPost.hook, category: allowedPost.category});
            }

            // Make sure the minimum supply does not surpass the maximum supply. A max of 0 means unlimited.
            if (allowedPost.maximumTotalSupply != 0 && allowedPost.minimumTotalSupply > allowedPost.maximumTotalSupply)
            {
                revert CTPublisher_MaxTotalSupplyLessThanMin({
                    min: allowedPost.minimumTotalSupply, max: allowedPost.maximumTotalSupply
                });
            }

            uint256 packed;
            // minimum price in bits 0-103 (104 bits).
            packed |= uint256(allowedPost.minimumPrice);
            // minimum total supply in bits 104-135 (32 bits).
            packed |= uint256(allowedPost.minimumTotalSupply) << 104;
            // maximum total supply in bits 136-167 (32 bits).
            packed |= uint256(allowedPost.maximumTotalSupply) << 136;
            // maximum split percent in bits 168-199 (32 bits).
            packed |= uint256(allowedPost.maximumSplitPercent) << 168;
            // Store the packed value.
            _packedAllowanceFor[allowedPost.hook][allowedPost.category] = packed;

            // Store the allow list. Direct assignment replaces the entire storage array in one operation,
            // avoiding the gas overhead of delete + individual push() calls in a loop.
            if (allowedPost.allowedAddresses.length != 0) {
                _allowedAddresses[allowedPost.hook][allowedPost.category] = allowedPost.allowedAddresses;
            } else {
                delete _allowedAddresses[allowedPost.hook][allowedPost.category];
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Publish one or more NFT posts to a project's 721 hook and mint a first copy of each. For each new post,
    /// a tier is created on the hook. A 5% fee (1/FEE_DIVISOR) is taken from the total tier prices and routed to the
    /// fee project; the remainder is paid into the project's terminal, minting NFTs for the beneficiary.
    /// @dev Reverts if any post violates the category's configured allowance (price, supply, split, allowlist).
    /// @param hook The hook to mint from.
    /// @param posts An array of posts that should be published as NFTs to the specified project.
    /// @param token The terminal token to pay with.
    /// @param amount The total token amount supplied for the post payment and Croptop fee.
    /// @param nftBeneficiary The beneficiary of the NFT mints.
    /// @param feeBeneficiary The beneficiary of the fee project's token.
    /// @param additionalPayMetadata Metadata bytes to include in the payment after Croptop prepends NFT mint metadata.
    function mintFrom(
        IJB721TiersHook hook,
        CTPost[] calldata posts,
        address token,
        uint256 amount,
        address nftBeneficiary,
        address feeBeneficiary,
        bytes calldata additionalPayMetadata
    )
        external
        payable
        override
    {
        if (token == JBConstants.NATIVE_TOKEN) {
            if (amount != msg.value) {
                revert CTPublisher_NativeTokenAmountMismatch({amount: amount, msgValue: msg.value});
            }
        } else {
            if (msg.value != 0) revert CTPublisher_MsgValueNotAllowed({value: msg.value});
            IERC20(token).safeTransferFrom({from: _msgSender(), to: address(this), value: amount});
        }

        _mintFrom({
            hook: hook,
            posts: posts,
            token: token,
            amount: amount,
            nftBeneficiary: nftBeneficiary,
            feeBeneficiary: feeBeneficiary,
            additionalPayMetadata: additionalPayMetadata
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Get the tiers for the provided encoded IPFS URIs.
    /// @dev The returned tier IDs may be stale if the corresponding tiers were removed externally via adjustTiers.
    /// In that case, the store's tierOf call will return a tier with default/empty values. Callers should check
    /// tier fields before relying on them.
    /// @param hook The hook from which to get tiers.
    /// @param encodedIpfsUris The URIs to get tiers of.
    /// @return tiers The tiers that correspond to the provided encoded IPFS URIs.
    function tiersFor(
        address hook,
        bytes32[] memory encodedIpfsUris
    )
        external
        view
        override
        returns (JB721Tier[] memory tiers)
    {
        // Set the number of tiers.
        tiers = new JB721Tier[](encodedIpfsUris.length);

        // Get the hook's store.
        IJB721TiersHookStore store = IJB721TiersHook(hook).STORE();

        // For each encoded IPFS URI being checked.
        for (uint256 i; i < encodedIpfsUris.length;) {
            // Get the tier ID the URI is stored in.
            uint256 tierId = tierIdForEncodedIpfsUriOf[hook][encodedIpfsUris[i]];

            // Get the tier.
            tiers[i] = store.tierOf({hook: hook, id: tierId, includeResolvedUri: true});

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Get the allowance for the provided hook and category.
    /// @param hook The hook to get the allowance for.
    /// @param category The category to get the allowance for.
    /// @return minimumPrice The minimum price.
    /// @return minimumTotalSupply The minimum total supply.
    /// @return maximumTotalSupply The maximum total supply.
    /// @return maximumSplitPercent The maximum split percent.
    /// @return allowedAddresses The addresses that are allowed to post.
    function allowanceFor(
        address hook,
        uint256 category
    )
        public
        view
        override
        returns (
            uint256 minimumPrice,
            uint256 minimumTotalSupply,
            uint256 maximumTotalSupply,
            uint256 maximumSplitPercent,
            address[] memory allowedAddresses
        )
    {
        // Get a reference to the packed allowance for the hook and category.
        uint256 packed = _packedAllowanceFor[hook][category];

        // Get a reference to the minimum price.
        minimumPrice = packed & ((1 << 104) - 1);
        // Get a reference to the minimum total supply.
        minimumTotalSupply = (packed >> 104) & ((1 << 32) - 1);
        // Get a reference to the maximum total supply.
        maximumTotalSupply = (packed >> 136) & ((1 << 32) - 1);
        // Get a reference to the maximum split percent.
        maximumSplitPercent = (packed >> 168) & ((1 << 32) - 1);

        allowedAddresses = _allowedAddresses[hook][category];
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Shared implementation for native and ERC-20 publish payments.
    /// @param hook The hook to mint from.
    /// @param posts An array of posts that should be published as NFTs to the specified project.
    /// @param token The terminal token to pay with.
    /// @param amount The total token amount supplied for the post payment and Croptop fee.
    /// @param nftBeneficiary The beneficiary of the NFT mints.
    /// @param feeBeneficiary The beneficiary of the fee project's token.
    /// @param additionalPayMetadata Metadata bytes to include in the payment after Croptop prepends NFT mint metadata.
    function _mintFrom(
        IJB721TiersHook hook,
        CTPost[] calldata posts,
        address token,
        uint256 amount,
        address nftBeneficiary,
        address feeBeneficiary,
        bytes calldata additionalPayMetadata
    )
        internal
    {
        // Reject empty posts to prevent fee-free metadata shadowing.
        if (posts.length == 0) revert CTPublisher_NoPosts(_msgSender());

        // Reject address(0) as fee beneficiary to prevent burning fee project tokens.
        if (feeBeneficiary == address(0)) revert CTPublisher_InvalidFeeBeneficiary();

        // Keep a reference to the amount being paid, which is `amount` minus the fee.
        uint256 payValue = amount;

        // Keep a reference to the mint metadata.
        bytes memory mintMetadata;

        // Keep a reference to the project's ID.
        uint256 projectId = hook.projectId();

        (uint256 pricingCurrency, uint256 pricingDecimals) = hook.pricingContext();

        // Get a reference to the project's current payment terminal.
        IJBTerminal projectTerminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});

        _requirePaymentTokenMatchesPricing({
            terminal: projectTerminal,
            projectId: projectId,
            token: token,
            pricingCurrency: pricingCurrency,
            pricingDecimals: pricingDecimals
        });

        uint256 mintCount = posts.length;
        {
            // Setup the posts.
            (JB721TierConfig[] memory tiersToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice) =
                _setupPosts({hook: hook, posts: posts});

            if (projectId != FEE_PROJECT_ID) {
                // Keep a reference to the fee that will be paid.
                // Note: integer division truncates, so the fee loses up to (FEE_DIVISOR - 1) wei of dust.
                // For example, a totalPrice of 39 wei with FEE_DIVISOR=20 yields a fee of 1 wei instead of 1.95.
                // This rounding is in the payer's favor and the loss is negligible for practical amounts.
                uint256 fee = totalPrice / FEE_DIVISOR;

                // Make sure enough was sent to cover the fee.
                if (payValue < fee) {
                    _revertInsufficientPayment({token: token, expected: totalPrice + fee, sent: amount});
                }

                payValue -= fee;
            }

            // Make sure the amount sent to this function is at least the specified price of the tier plus the fee.
            if (totalPrice > payValue) {
                _revertInsufficientPayment({token: token, expected: totalPrice, sent: amount});
            }

            // Add the new tiers.
            hook.adjustTiers({tiersToAdd: tiersToAdd, tierIdsToRemove: new uint256[](0)});

            // Keep a reference to the metadata ID target.
            address metadataIdTarget = hook.METADATA_ID_TARGET();

            // Revert if the caller's additional metadata already contains a pay ID — this would shadow Croptop's
            // tier selection, allowing the caller to mint arbitrary tiers.
            {
                bytes4 payId = JBMetadataResolver.getId({purpose: "pay", target: metadataIdTarget});
                (bool exists,) = JBMetadataResolver.getDataFor({id: payId, metadata: additionalPayMetadata});
                if (exists) revert CTPublisher_DuplicatePayMetadata(payId);
            }

            // Add Croptop's pay metadata entry while preserving caller-provided metadata.
            mintMetadata = JBMetadataResolver.addToMetadata({
                originalMetadata: additionalPayMetadata,
                idToAdd: JBMetadataResolver.getId({purpose: "pay", target: metadataIdTarget}),
                dataToAdd: abi.encode(true, tierIdsToMint)
            });

            // Store the referral project ID in the first 32 bytes of the metadata.
            uint256 feeProjectId = FEE_PROJECT_ID;

            assembly {
                mstore(add(mintMetadata, 32), feeProjectId)
            }
        }

        emit Mint({
            projectId: projectId,
            hook: hook,
            token: token,
            nftBeneficiary: nftBeneficiary,
            feeBeneficiary: feeBeneficiary,
            posts: posts,
            postValue: payValue,
            amount: amount,
            caller: _msgSender()
        });

        {
            uint256 balanceBefore = hook.STORE().balanceOf({hook: address(hook), owner: nftBeneficiary});

            // Make the payment.
            _prepareAllowanceFor({token: token, spender: address(projectTerminal), amount: payValue});
            projectTerminal.pay{value: token == JBConstants.NATIVE_TOKEN ? payValue : 0}({
                projectId: projectId,
                token: token,
                amount: payValue,
                beneficiary: nftBeneficiary,
                minReturnedTokens: 0,
                memo: "Minted from Croptop",
                metadata: mintMetadata
            });
            _requireTemporaryAllowanceConsumed({token: token, spender: address(projectTerminal)});

            uint256 expectedBalance = balanceBefore + mintCount;
            uint256 balanceAfter = hook.STORE().balanceOf({hook: address(hook), owner: nftBeneficiary});
            if (balanceAfter < expectedBalance) {
                revert CTPublisher_MintNotDelivered({
                    hook: address(hook),
                    beneficiary: nftBeneficiary,
                    expectedBalance: expectedBalance,
                    actualBalance: balanceAfter
                });
            }
        }

        // Reuse payValue to hold the pre-computed fee amount, avoiding reliance on address(this).balance
        // after the external call above (which could be manipulated by reentrancy or force-sent tokens).
        payValue = amount - payValue;

        // Pay the fee if there is one.
        if (payValue != 0) {
            // Get a reference to the fee project's current payment terminal.
            IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf({projectId: FEE_PROJECT_ID, token: token});

            // Make the fee payment. If the fee sink is unavailable, refund the fee to the caller
            // rather than trapping or silently redirecting protocol funds.
            _prepareAllowanceFor({token: token, spender: address(feeTerminal), amount: payValue});
            try feeTerminal.pay{value: token == JBConstants.NATIVE_TOKEN ? payValue : 0}({
                projectId: FEE_PROJECT_ID,
                amount: payValue,
                token: token,
                beneficiary: feeBeneficiary,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            }) {
                _requireTemporaryAllowanceConsumed({token: token, spender: address(feeTerminal)});
            } catch {
                _clearAllowanceFor({token: token, spender: address(feeTerminal)});
                _refundFee({token: token, amount: payValue});
            }
        }
    }

    //*********************************************************************//
    // ------------------------ internal helpers ------------------------- //
    //*********************************************************************//

    /// @notice Clear a temporary ERC-20 allowance granted by this publisher.
    /// @param token The token whose allowance should be cleared.
    /// @param spender The contract whose allowance should be cleared.
    function _clearAllowanceFor(address token, address spender) internal {
        if (token == JBConstants.NATIVE_TOKEN) return;

        IERC20(token).forceApprove({spender: spender, value: 0});
    }

    /// @notice Check if an address is included in an allow list.
    /// @dev Uses an O(n) linear scan over the `addresses` array. This is acceptable for typical allow list sizes
    /// (fewer than ~100 addresses), where gas cost is negligible. For very large allow lists, a Merkle proof
    /// pattern would scale better, but the added complexity is not warranted for the expected use case.
    /// @param addrs The candidate address.
    /// @param addresses An array of allowed addresses.
    function _isAllowed(address addrs, address[] memory addresses) internal pure returns (bool) {
        // Keep a reference to the number of addresses to check against.
        uint256 numberOfAddresses = addresses.length;

        // Check whether the address is included.
        for (uint256 i; i < numberOfAddresses;) {
            if (addrs == addresses[i]) return true;
            unchecked {
                ++i;
            }
        }

        return false;
    }

    /// @notice Grant a temporary ERC-20 allowance for a downstream terminal payment.
    /// @param token The token being paid.
    /// @param spender The terminal expected to consume the allowance.
    /// @param amount The exact allowance to grant.
    function _prepareAllowanceFor(address token, address spender, uint256 amount) internal {
        if (token == JBConstants.NATIVE_TOKEN) return;

        IERC20(token).forceApprove({spender: spender, value: amount});
    }

    /// @notice Refund a fee payment when the fee terminal is unavailable.
    /// @param token The token to refund.
    /// @param amount The amount to refund.
    function _refundFee(address token, uint256 amount) internal {
        if (token == JBConstants.NATIVE_TOKEN) {
            (bool success,) = _msgSender().call{value: amount}("");
            if (!success) revert CTPublisher_FeePaymentFailed(amount);

            return;
        }

        IERC20(token).safeTransfer({to: _msgSender(), value: amount});
    }

    /// @notice Require the payment token's terminal accounting context to match the hook's pricing context.
    /// @param terminal The terminal being paid.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid.
    /// @param pricingCurrency The hook's pricing currency.
    /// @param pricingDecimals The hook's pricing decimals.
    function _requirePaymentTokenMatchesPricing(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 pricingCurrency,
        uint256 pricingDecimals
    )
        internal
        view
    {
        if (token == JBConstants.NATIVE_TOKEN) {
            bool nativePricing = pricingDecimals == 18
                && (pricingCurrency == JBCurrencyIds.ETH || pricingCurrency == JBConstants.NATIVE_TOKEN_CURRENCY);
            if (!nativePricing) {
                revert CTPublisher_InvalidPaymentTokenContext({
                    token: token,
                    tokenCurrency: JBCurrencyIds.ETH,
                    tokenDecimals: 18,
                    pricingCurrency: pricingCurrency,
                    pricingDecimals: pricingDecimals
                });
            }

            return;
        }

        JBAccountingContext memory context = terminal.accountingContextForTokenOf({projectId: projectId, token: token});

        if (context.token != token || context.currency != pricingCurrency || context.decimals != pricingDecimals) {
            revert CTPublisher_InvalidPaymentTokenContext({
                token: token,
                tokenCurrency: context.currency,
                tokenDecimals: context.decimals,
                pricingCurrency: pricingCurrency,
                pricingDecimals: pricingDecimals
            });
        }
    }

    /// @notice Revert if a downstream terminal did not consume its exact-use ERC-20 allowance.
    /// @param token The token whose allowance was temporarily granted.
    /// @param spender The terminal expected to consume the allowance.
    function _requireTemporaryAllowanceConsumed(address token, address spender) internal view {
        if (token == JBConstants.NATIVE_TOKEN) return;

        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: spender});
        if (allowance != 0) {
            revert CTPublisher_TemporaryAllowanceNotConsumed({token: token, spender: spender, allowance: allowance});
        }
    }

    /// @notice Revert with the native-compatible error for ETH payments, or the token-generic error otherwise.
    /// @param token The token being paid.
    /// @param expected The minimum required amount.
    /// @param sent The supplied amount.
    function _revertInsufficientPayment(address token, uint256 expected, uint256 sent) internal pure {
        if (token == JBConstants.NATIVE_TOKEN) {
            revert CTPublisher_InsufficientEthSent({expected: expected, sent: sent});
        }

        revert CTPublisher_InsufficientPayment({expected: expected, sent: sent});
    }

    /// @notice Setup the posts.
    /// @dev `adjustTiers` expects newly added tiers to be sorted by ascending category, while the pay metadata must
    /// keep `tierIdsToMint` aligned with the caller's `posts` array so the requested NFTs are minted in the requested
    /// order. `_setupPosts` therefore sorts only the tier configs and carries each config's original post index beside
    /// it.
    /// @param hook The NFT hook on which the posts will apply.
    /// @param posts An array of posts that should be published as NFTs to the specified project.
    /// @return tiersToAdd The tiers that will be created to represent the posts.
    /// @return tierIdsToMint The tier IDs of the posts that should be minted once published.
    /// @return totalPrice The total price to pay.
    function _setupPosts(
        IJB721TiersHook hook,
        CTPost[] memory posts
    )
        internal
        returns (JB721TierConfig[] memory tiersToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice)
    {
        // Set the max size of the tier data that will be added.
        tiersToAdd = new JB721TierConfig[](posts.length);

        // Set the size of the tier IDs of the posts that should be minted once published.
        tierIdsToMint = new uint256[](posts.length);

        // Track which post produced each new tier. `tiersToAdd` may be sorted before it is sent to the 721 hook, but
        // `tierIdsToMint` must stay indexed by the original `posts` array for the mint metadata below.
        uint256[] memory newTierPostIndexes = new uint256[](posts.length);

        // Keep a reference to the hook's store for tier lookups.
        IJB721TiersHookStore store = hook.STORE();

        // The tier ID that will be created, and the first one that should be minted from, is one more than the current
        // max.
        uint256 startingTierId = store.maxTierIdOf(address(hook)) + 1;

        // Keep a reference to the total number of tiers being added.
        uint256 numberOfTiersBeingAdded;

        // For each post, create tiers after validating to make sure they fulfill the allowance specified by the
        // project's owner.
        for (uint256 i; i < posts.length;) {
            // Get the current post being iterated on.
            CTPost memory post = posts[i];

            // Make sure the post includes an encodedIpfsUri.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (post.encodedIpfsUri == bytes32("")) {
                revert CTPublisher_EmptyEncodedIpfsUri({postIndex: i});
            }

            // Check for duplicate encodedIpfsUri within the same batch to prevent fee evasion.
            for (uint256 j; j < i;) {
                if (posts[j].encodedIpfsUri == post.encodedIpfsUri) {
                    revert CTPublisher_DuplicatePost({encodedIpfsUri: post.encodedIpfsUri});
                }
                unchecked {
                    ++j;
                }
            }

            // Scoped section to prevent stack too deep.
            {
                // Check if there's an ID of a tier already minted for this encodedIpfsUri.
                uint256 tierId = tierIdForEncodedIpfsUriOf[address(hook)][post.encodedIpfsUri];

                if (tierId != 0) {
                    // Validate the cached tier still exists and its URI still matches.
                    // The cache can become stale if the tier was removed (via adjustTiers) or
                    // its URI was changed (via setMetadata). In either case, clear the stale
                    // mapping and fall through to create a new tier.
                    JB721Tier memory cachedTier =
                        store.tierOf({hook: address(hook), id: tierId, includeResolvedUri: false});
                    if (
                        store.isTierRemoved({hook: address(hook), tierId: tierId})
                            || cachedTier.encodedIpfsUri != post.encodedIpfsUri
                    ) {
                        delete tierIdForEncodedIpfsUriOf[address(hook)][post.encodedIpfsUri];
                    } else {
                        tierIdsToMint[i] = tierId;

                        // For existing tiers, use the actual tier price (not the user-supplied post.price)
                        // to prevent fee evasion by passing price=0 for an existing tier.
                        totalPrice += cachedTier.price;
                    }
                }
            }

            // If no tier already exists, post the tier.
            if (tierIdsToMint[i] == 0) {
                // Scoped error handling section to prevent Stack Too Deep.
                {
                    // Get references to the allowance.
                    (
                        uint256 minimumPrice,
                        uint256 minimumTotalSupply,
                        uint256 maximumTotalSupply,
                        uint256 maximumSplitPercent,
                        address[] memory addresses
                    ) = allowanceFor({hook: address(hook), category: post.category});

                    // Make sure the category being posted to allows publishing.
                    if (minimumTotalSupply == 0) {
                        revert CTPublisher_UnauthorizedToPostInCategory({hook: address(hook), category: post.category});
                    }

                    // Make sure the price being paid for the post is at least the allowed minimum price.
                    if (post.price < minimumPrice) {
                        revert CTPublisher_PriceTooSmall({price: post.price, minimumPrice: minimumPrice});
                    }

                    // Make sure the total supply being made available for the post is at least the allowed minimum
                    // total supply.
                    if (post.totalSupply < minimumTotalSupply) {
                        revert CTPublisher_TotalSupplyTooSmall({
                            totalSupply: post.totalSupply, minimumTotalSupply: minimumTotalSupply
                        });
                    }

                    // Make sure the total supply being made available for the post is at most the allowed maximum total
                    // supply. A max of 0 means unlimited.
                    if (maximumTotalSupply != 0 && post.totalSupply > maximumTotalSupply) {
                        revert CTPublisher_TotalSupplyTooBig({
                            totalSupply: post.totalSupply, maximumTotalSupply: maximumTotalSupply
                        });
                    }

                    // Make sure the split percent is within the allowed maximum.
                    if (post.splitPercent > maximumSplitPercent) {
                        revert CTPublisher_SplitPercentExceedsMaximum({
                            splitPercent: post.splitPercent, maximumSplitPercent: maximumSplitPercent
                        });
                    }

                    // Make sure the address is allowed to post.
                    if (addresses.length != 0 && !_isAllowed({addrs: _msgSender(), addresses: addresses})) {
                        revert CTPublisher_NotInAllowList({addr: _msgSender(), allowedAddresses: addresses});
                    }
                }

                // Set the tier.
                tiersToAdd[numberOfTiersBeingAdded] = JB721TierConfig({
                    price: post.price,
                    initialSupply: post.totalSupply,
                    votingUnits: 0,
                    reserveFrequency: 0,
                    reserveBeneficiary: address(0),
                    encodedIpfsUri: post.encodedIpfsUri,
                    category: post.category,
                    discountPercent: 0,
                    flags: JB721TierConfigFlags({
                        allowOwnerMint: false,
                        useReserveBeneficiaryAsDefault: false,
                        transfersPausable: false,
                        useVotingUnits: true,
                        cantBeRemoved: false,
                        cantIncreaseDiscountPercent: false,
                        cantBuyWithCredits: false
                    }),
                    splitPercent: post.splitPercent,
                    splits: post.splits
                });

                newTierPostIndexes[numberOfTiersBeingAdded] = i;
                numberOfTiersBeingAdded++;

                // For new tiers, use the post's price for totalPrice accumulation.
                totalPrice += post.price;
            }

            unchecked {
                ++i;
            }
        }

        // The 721 store requires new tiers sorted by ascending category. This insertion sort normalizes caller input
        // so multi-category publishes do not revert when posts are supplied in mint order instead of category
        // order. It is intentionally stable: equal-category posts stay in caller order because the loop only moves
        // prior tiers with a strictly greater category.
        for (uint256 i = 1; i < numberOfTiersBeingAdded;) {
            // Keep the tier and its original post index together while shifting larger-category tiers to the right.
            JB721TierConfig memory tierToSort = tiersToAdd[i];
            uint256 postIndexToSort = newTierPostIndexes[i];
            uint256 j = i;

            while (j != 0 && tiersToAdd[j - 1].category > tierToSort.category) {
                // Shift both arrays in lockstep; otherwise the tier ID assigned after sorting would be written back to
                // the wrong post in `tierIdsToMint`.
                tiersToAdd[j] = tiersToAdd[j - 1];
                newTierPostIndexes[j] = newTierPostIndexes[j - 1];

                unchecked {
                    --j;
                }
            }

            // Insert the tier at its category-sorted position with the original post index still attached.
            tiersToAdd[j] = tierToSort;
            newTierPostIndexes[j] = postIndexToSort;

            unchecked {
                ++i;
            }
        }

        // Now that the store-facing tier order is final, translate each newly-created tier ID back into the caller's
        // post order. The pay metadata expects this array to line up with `posts`, not with the sorted `tiersToAdd`.
        for (uint256 i; i < numberOfTiersBeingAdded;) {
            uint256 postIndex = newTierPostIndexes[i];
            uint256 tierId = startingTierId + i;
            tierIdsToMint[postIndex] = tierId;
            tierIdForEncodedIpfsUriOf[address(hook)][posts[postIndex].encodedIpfsUri] = tierId;

            unchecked {
                ++i;
            }
        }

        // Resize the array if there's a mismatch in length.
        if (numberOfTiersBeingAdded != posts.length) {
            assembly ("memory-safe") {
                mstore(tiersToAdd, numberOfTiersBeingAdded)
            }
        }
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Returns the calldata; preferred over `msg.data`.
    /// @return calldata the `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice Returns the sender; preferred over `msg.sender`.
    /// @return sender the sender address of this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }
}
