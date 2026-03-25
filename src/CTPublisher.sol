// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {ICTPublisher} from "./interfaces/ICTPublisher.sol";
import {CTAllowedPost} from "./structs/CTAllowedPost.sol";
import {CTPost} from "./structs/CTPost.sol";

/// @notice A contract that facilitates the permissioned publishing of NFT posts to a Juicebox project.
contract CTPublisher is JBPermissioned, ERC2771Context, ICTPublisher {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    // forge-lint: disable-next-line(mixed-case-variable)
    error CTPublisher_DuplicatePost(bytes32 encodedIPFSUri);
    error CTPublisher_EmptyEncodedIPFSUri();
    error CTPublisher_InsufficientEthSent(uint256 expected, uint256 sent);
    error CTPublisher_MaxTotalSupplyLessThanMin(uint256 min, uint256 max);
    error CTPublisher_NotInAllowList(address addr, address[] allowedAddresses);
    error CTPublisher_PriceTooSmall(uint256 price, uint256 minimumPrice);
    error CTPublisher_SplitPercentExceedsMaximum(uint256 splitPercent, uint256 maximumSplitPercent);
    error CTPublisher_TotalSupplyTooBig(uint256 totalSupply, uint256 maximumTotalSupply);
    error CTPublisher_TotalSupplyTooSmall(uint256 totalSupply, uint256 minimumTotalSupply);
    error CTPublisher_UnauthorizedToPostInCategory();
    error CTPublisher_ZeroTotalSupply();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The divisor that describes the fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent.
    uint256 public constant override FEE_DIVISOR = 20;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory that contains the projects being posted to.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The ID of the project to which fees will be routed.
    uint256 public immutable override FEE_PROJECT_ID;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The ID of the tier that an IPFS metadata has been saved to.
    /// @custom:param hook The hook for which the tier ID applies.
    /// @custom:param encodedIPFSUri The IPFS URI.
    // forge-lint: disable-next-line(mixed-case-variable)
    mapping(address hook => mapping(bytes32 encodedIPFSUri => uint256)) public override tierIdForEncodedIPFSUriOf;

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
    /// @custom:param category The category for which the allowance applies
    mapping(address hook => mapping(uint256 category => uint256)) internal _packedAllowanceFor;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory that contains the projects being posted to.
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
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Get the tiers for the provided encoded IPFS URIs.
    /// @dev The returned tier IDs may be stale if the corresponding tiers were removed externally via adjustTiers.
    /// In that case, the store's tierOf call will return a tier with default/empty values. Callers should check
    /// the returned tier's initialSupply or other fields to confirm the tier still exists.
    /// @param hook The hook from which to get tiers.
    /// @param encodedIPFSUris The URIs to get tiers of.
    /// @return tiers The tiers that correspond to the provided encoded IPFS URIs. If there's no tier yet, an empty tier
    /// is returned.
    function tiersFor(
        address hook,
        // forge-lint: disable-next-line(mixed-case-variable)
        bytes32[] memory encodedIPFSUris
    )
        external
        view
        override
        returns (JB721Tier[] memory tiers)
    {
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 numberOfEncodedIPFSUris = encodedIPFSUris.length;

        // Initialize the tier array being returned.
        tiers = new JB721Tier[](numberOfEncodedIPFSUris);

        // Get the tier for each provided encoded IPFS URI.
        for (uint256 i; i < numberOfEncodedIPFSUris; i++) {
            // Check if there's a tier ID stored for the encoded IPFS URI.
            uint256 tierId = tierIdForEncodedIPFSUriOf[hook][encodedIPFSUris[i]];

            // If there's a tier ID stored, resolve it.
            if (tierId != 0) {
                // slither-disable-next-line calls-loop
                tiers[i] = IJB721TiersHook(hook).STORE().tierOf({hook: hook, id: tierId, includeResolvedUri: false});
            }
        }
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Post allowances for a particular category on a particular hook.
    /// @param hook The hook contract for which this allowance applies.
    /// @param category The category for which this allowance applies.
    /// @return minimumPrice The minimum price that a poster must pay to record a new NFT.
    /// @return minimumTotalSupply The minimum total number of available tokens that a minter must set to record a new
    /// NFT.
    /// @return maximumTotalSupply The max total supply of NFTs that can be made available when minting. Must be >=
    /// minimumTotalSupply.
    /// @return maximumSplitPercent The maximum split percent that a poster can set. 0 means splits are not allowed.
    /// @return allowedAddresses The addresses allowed to post. Returns empty if all addresses are allowed.
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
        // Get a reference to the packed values.
        uint256 packed = _packedAllowanceFor[hook][category];

        // minimum price in bits 0-103 (104 bits).
        // forge-lint: disable-next-line(unsafe-typecast)
        minimumPrice = uint256(uint104(packed));
        // minimum supply in bits 104-135 (32 bits).
        // forge-lint: disable-next-line(unsafe-typecast)
        minimumTotalSupply = uint256(uint32(packed >> 104));
        // maximum supply in bits 136-167 (32 bits).
        // forge-lint: disable-next-line(unsafe-typecast)
        maximumTotalSupply = uint256(uint32(packed >> 136));
        // maximum split percent in bits 168-199 (32 bits).
        // forge-lint: disable-next-line(unsafe-typecast)
        maximumSplitPercent = uint256(uint32(packed >> 168));

        allowedAddresses = _allowedAddresses[hook][category];
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Check if an address is included in an allow list.
    /// @dev Uses an O(n) linear scan over the `addresses` array. This is acceptable for typical allow list sizes
    /// (fewer than ~100 addresses), where gas cost is negligible. For very large allow lists, a Merkle proof
    /// pattern would scale better, but the added complexity is not warranted for the expected use case.
    /// @param addrs The candidate address.
    /// @param addresses An array of allowed addresses.
    function _isAllowed(address addrs, address[] memory addresses) internal pure returns (bool) {
        // Keep a reference to the number of address to check against.
        uint256 numberOfAddresses = addresses.length;

        // Check if the address is included
        for (uint256 i; i < numberOfAddresses; i++) {
            if (addrs == addresses[i]) return true;
        }

        return false;
    }

    /// @notice Returns the calldata, prefered to use over `msg.data`
    /// @return calldata the `msg.data` of this call
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice Returns the sender, prefered to use over `msg.sender`
    /// @return sender the sender address of this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Collection owners can set the allowed criteria for publishing a new NFT to their project.
    /// @param allowedPosts An array of criteria for allowed posts.
    // Categories cannot be fully disabled after creation. This is by design — once a category is
    // created, removing posting would break expectations for existing posters. Projects can set restrictive
    // allowedPost configurations to effectively disable new posts without removing the category.
    function configurePostingCriteriaFor(CTAllowedPost[] memory allowedPosts) external override {
        // Keep a reference to the number of post criteria.
        uint256 numberOfAllowedPosts = allowedPosts.length;

        // For each post criteria, save the specifications.
        for (uint256 i; i < numberOfAllowedPosts; i++) {
            // Set the post criteria being iterated on.
            CTAllowedPost memory allowedPost = allowedPosts[i];

            emit ConfigurePostingCriteria({hook: allowedPost.hook, allowedPost: allowedPost, caller: _msgSender()});

            // Enforce permissions.
            // slither-disable-next-line reentrancy-events,calls-loop
            _requirePermissionFrom({
                account: JBOwnable(allowedPost.hook).owner(),
                projectId: IJB721TiersHook(allowedPost.hook).PROJECT_ID(),
                permissionId: JBPermissionIds.ADJUST_721_TIERS
            });

            // Make sure there is a minimum supply.
            if (allowedPost.minimumTotalSupply == 0) {
                revert CTPublisher_ZeroTotalSupply();
            }

            // Make sure the minimum supply does not surpass the maximum supply.
            if (allowedPost.minimumTotalSupply > allowedPost.maximumTotalSupply) {
                revert CTPublisher_MaxTotalSupplyLessThanMin(
                    allowedPost.minimumTotalSupply, allowedPost.maximumTotalSupply
                );
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

            // Store the allow list.
            uint256 numberOfAddresses = allowedPost.allowedAddresses.length;
            // Reset the addresses.
            delete _allowedAddresses[allowedPost.hook][allowedPost.category];
            // Add the number allowed addresses.
            if (numberOfAddresses != 0) {
                // Keep a reference to the storage of the allowed addresses.
                for (uint256 j = 0; j < numberOfAddresses; j++) {
                    _allowedAddresses[allowedPost.hook][allowedPost.category].push(allowedPost.allowedAddresses[j]);
                }
            }
        }
    }

    /// @notice Publish an NFT to become mintable, and mint a first copy.
    /// @dev A fee is taken into the appropriate treasury.
    /// @param hook The hook to mint from.
    /// @param posts An array of posts that should be published as NFTs to the specified project.
    /// @param nftBeneficiary The beneficiary of the NFT mints.
    /// @param feeBeneficiary The beneficiary of the fee project's token.
    /// @param additionalPayMetadata Metadata bytes that should be included in the pay function's metadata. This
    /// prepends the
    /// payload needed for NFT creation.
    /// @param feeMetadata The metadata to send alongside the fee payment.
    function mintFrom(
        IJB721TiersHook hook,
        CTPost[] calldata posts,
        address nftBeneficiary,
        address feeBeneficiary,
        bytes calldata additionalPayMetadata,
        bytes calldata feeMetadata
    )
        external
        payable
        override
    {
        // Keep a reference to the amount being paid, which is msg.value minus the fee.
        uint256 payValue = msg.value;

        // Keep a reference to the mint metadata.
        bytes memory mintMetadata;

        // Keep a reference to the project's ID.
        uint256 projectId = hook.PROJECT_ID();

        {
            // Setup the posts.
            (JB721TierConfig[] memory tiersToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice) =
                _setupPosts(hook, posts);

            if (projectId != FEE_PROJECT_ID) {
                // Keep a reference to the fee that will be paid.
                // Note: integer division truncates, so the fee loses up to (FEE_DIVISOR - 1) wei of dust.
                // For example, a totalPrice of 39 wei with FEE_DIVISOR=20 yields a fee of 1 wei instead of 1.95.
                // This rounding is in the payer's favor and the loss is negligible for practical amounts.
                uint256 fee = totalPrice / FEE_DIVISOR;

                // Make sure enough ETH was sent to cover the fee.
                if (payValue < fee) {
                    revert CTPublisher_InsufficientEthSent(totalPrice + fee, msg.value);
                }

                payValue -= fee;
            }

            // Make sure the amount sent to this function is at least the specified price of the tier plus the fee.
            if (totalPrice > payValue) {
                revert CTPublisher_InsufficientEthSent(totalPrice, msg.value);
            }

            // Add the new tiers.
            // slither-disable-next-line reentrancy-events
            hook.adjustTiers({tiersToAdd: tiersToAdd, tierIdsToRemove: new uint256[](0)});

            // Keep a reference to the metadata ID target.
            address metadataIdTarget = hook.METADATA_ID_TARGET();

            // Create the metadata for the payment to specify the tier IDs that should be minted. We create manually the
            // original metadata, following
            // the specifications from the JBMetadataResolver library.
            mintMetadata = JBMetadataResolver.addToMetadata({
                originalMetadata: additionalPayMetadata,
                idToAdd: JBMetadataResolver.getId({purpose: "pay", target: metadataIdTarget}),
                dataToAdd: abi.encode(true, tierIdsToMint)
            });

            // Store the referal id in the first 32 bytes of the metadata (push to stack for immutable in assembly)
            uint256 feeProjectId = FEE_PROJECT_ID;

            assembly {
                mstore(add(mintMetadata, 32), feeProjectId)
            }
        }

        emit Mint({
            projectId: projectId,
            hook: hook,
            nftBeneficiary: nftBeneficiary,
            feeBeneficiary: feeBeneficiary,
            posts: posts,
            postValue: payValue,
            txValue: msg.value,
            caller: _msgSender()
        });

        {
            // Get a reference to the project's current ETH payment terminal.
            IJBTerminal projectTerminal =
                DIRECTORY.primaryTerminalOf({projectId: projectId, token: JBConstants.NATIVE_TOKEN});

            // Make the payment.
            // slither-disable-next-line unused-return
            projectTerminal.pay{value: payValue}({
                projectId: projectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: payValue,
                beneficiary: nftBeneficiary,
                minReturnedTokens: 0,
                memo: "Minted from Croptop",
                metadata: mintMetadata
            });
        }

        // Reuse payValue to hold the pre-computed fee amount, avoiding reliance on address(this).balance
        // after the external call above (which could be manipulated by reentrancy or force-sent ETH).
        payValue = msg.value - payValue;

        // Pay the fee if there is one.
        if (payValue != 0) {
            // Get a reference to the fee project's current ETH payment terminal.
            IJBTerminal feeTerminal =
                DIRECTORY.primaryTerminalOf({projectId: FEE_PROJECT_ID, token: JBConstants.NATIVE_TOKEN});

            // Make the fee payment.
            // slither-disable-next-line unused-return
            feeTerminal.pay{value: payValue}({
                projectId: FEE_PROJECT_ID,
                amount: payValue,
                token: JBConstants.NATIVE_TOKEN,
                beneficiary: feeBeneficiary,
                minReturnedTokens: 0,
                memo: "",
                metadata: feeMetadata
            });
        }
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Setup the posts.
    /// @param hook The NFT hook on which the posts will apply.
    /// @param posts An array of posts that should be published as NFTs to the specified project.
    /// @return tiersToAdd The tiers that will be created to represent the posts.
    /// @return tierIdsToMint The tier IDs of the posts that should be minted once published.
    /// @return totalPrice The total price being paid.
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

        // Keep a reference to the hook's store for tier lookups.
        IJB721TiersHookStore store = hook.STORE();

        // The tier ID that will be created, and the first one that should be minted from, is one more than the current
        // max.
        uint256 startingTierId = store.maxTierIdOf(address(hook)) + 1;

        // Keep a reference to the total number of tiers being added.
        uint256 numberOfTiersBeingAdded;

        // For each post, create tiers after validating to make sure they fulfill the allowance specified by the
        // project's owner.
        for (uint256 i; i < posts.length; i++) {
            // Get the current post being iterated on.
            CTPost memory post = posts[i];

            // Make sure the post includes an encodedIPFSUri.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (post.encodedIPFSUri == bytes32("")) {
                revert CTPublisher_EmptyEncodedIPFSUri();
            }

            // Check for duplicate encodedIPFSUri within the same batch to prevent fee evasion.
            for (uint256 j; j < i; j++) {
                if (posts[j].encodedIPFSUri == post.encodedIPFSUri) {
                    revert CTPublisher_DuplicatePost(post.encodedIPFSUri);
                }
            }

            // Scoped section to prevent stack too deep.
            {
                // Check if there's an ID of a tier already minted for this encodedIPFSUri.
                uint256 tierId = tierIdForEncodedIPFSUriOf[address(hook)][post.encodedIPFSUri];

                if (tierId != 0) {
                    // If the tier was removed externally (via adjustTiers), clear the stale mapping
                    // so the code falls through to create a new tier.
                    // slither-disable-next-line calls-loop
                    if (hook.STORE().isTierRemoved(address(hook), tierId)) {
                        delete tierIdForEncodedIPFSUriOf[address(hook)][post.encodedIPFSUri];
                    } else {
                        tierIdsToMint[i] = tierId;

                        // For existing tiers, use the actual tier price (not the user-supplied post.price)
                        // to prevent fee evasion by passing price=0 for an existing tier.
                        // slither-disable-next-line calls-loop
                        totalPrice += store.tierOf({hook: address(hook), id: tierId, includeResolvedUri: false}).price;
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
                        revert CTPublisher_UnauthorizedToPostInCategory();
                    }

                    // Make sure the price being paid for the post is at least the allowed minimum price.
                    if (post.price < minimumPrice) {
                        revert CTPublisher_PriceTooSmall(post.price, minimumPrice);
                    }

                    // Make sure the total supply being made available for the post is at least the allowed minimum
                    // total supply.
                    if (post.totalSupply < minimumTotalSupply) {
                        revert CTPublisher_TotalSupplyTooSmall(post.totalSupply, minimumTotalSupply);
                    }

                    // Make sure the total supply being made available for the post is at most the allowed maximum total
                    // supply.
                    if (post.totalSupply > maximumTotalSupply) {
                        revert CTPublisher_TotalSupplyTooBig(post.totalSupply, maximumTotalSupply);
                    }

                    // Make sure the split percent is within the allowed maximum.
                    if (post.splitPercent > maximumSplitPercent) {
                        revert CTPublisher_SplitPercentExceedsMaximum(post.splitPercent, maximumSplitPercent);
                    }

                    // Make sure the address is allowed to post.
                    if (addresses.length != 0 && !_isAllowed({addrs: _msgSender(), addresses: addresses})) {
                        revert CTPublisher_NotInAllowList(_msgSender(), addresses);
                    }
                }

                // Set the tier.
                tiersToAdd[numberOfTiersBeingAdded] = JB721TierConfig({
                    price: post.price,
                    initialSupply: post.totalSupply,
                    votingUnits: 0,
                    reserveFrequency: 0,
                    reserveBeneficiary: address(0),
                    encodedIPFSUri: post.encodedIPFSUri,
                    category: post.category,
                    discountPercent: 0,
                    allowOwnerMint: false,
                    useReserveBeneficiaryAsDefault: false,
                    transfersPausable: false,
                    useVotingUnits: true,
                    cannotBeRemoved: false,
                    cannotIncreaseDiscountPercent: false,
                    splitPercent: post.splitPercent,
                    splits: post.splits
                });

                // Set the ID of the tier to mint.
                tierIdsToMint[i] = startingTierId + numberOfTiersBeingAdded++;

                // Save the encodedIPFSUri as minted.
                tierIdForEncodedIPFSUriOf[address(hook)][post.encodedIPFSUri] = tierIdsToMint[i];

                // For new tiers, use the post's price for totalPrice accumulation.
                totalPrice += post.price;
            }
        }

        // Resize the array if there's a mismatch in length.
        if (numberOfTiersBeingAdded != posts.length) {
            assembly ("memory-safe") {
                mstore(tiersToAdd, numberOfTiersBeingAdded)
            }
        }
    }
}
