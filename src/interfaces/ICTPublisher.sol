// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";

import {CTAllowedPost} from "../structs/CTAllowedPost.sol";
import {CTPost} from "../structs/CTPost.sol";

interface ICTPublisher {
    event ConfigurePostingCriteria(address indexed hook, CTAllowedPost allowedPost, address caller);
    event Mint(
        uint256 indexed projectId,
        IJB721TiersHook indexed hook,
        address indexed nftBeneficiary,
        address feeBeneficiary,
        CTPost[] posts,
        uint256 postValue,
        uint256 txValue,
        address caller
    );

    /// @notice The divisor that describes the fee percent. Equal to 100 divided by the fee percent.
    /// @return The fee divisor.
    function FEE_DIVISOR() external view returns (uint256);

    /// @notice The directory that contains the projects being posted to.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The ID of the project to which fees will be routed.
    /// @return The fee project ID.
    function FEE_PROJECT_ID() external view returns (uint256);

    /// @notice The tier ID that an IPFS metadata URI has been saved to for a given hook.
    /// @param hook The hook for which the tier ID applies.
    /// @param encodedIPFSUri The encoded IPFS URI to look up.
    /// @return The tier ID, or 0 if the URI has not been published.
    function tierIdForEncodedIPFSUriOf(address hook, bytes32 encodedIPFSUri) external view returns (uint256);

    /// @notice The post allowance for a particular category on a particular hook.
    /// @param hook The hook contract for which this allowance applies.
    /// @param category The category for which this allowance applies.
    /// @return minimumPrice The minimum price a poster must pay to publish a new NFT.
    /// @return minimumTotalSupply The minimum total supply a poster must set for a new NFT.
    /// @return maximumTotalSupply The maximum total supply allowed for a new NFT. 0 means no limit.
    /// @return maximumSplitPercent The maximum split percent allowed for a new NFT.
    /// @return allowedAddresses The addresses allowed to post. Empty if all addresses are allowed.
    function allowanceFor(
        address hook,
        uint256 category
    )
        external
        view
        returns (
            uint256 minimumPrice,
            uint256 minimumTotalSupply,
            uint256 maximumTotalSupply,
            uint256 maximumSplitPercent,
            address[] memory allowedAddresses
        );

    /// @notice Get the tiers for the provided encoded IPFS URIs.
    /// @param hook The hook from which to get tiers.
    /// @param encodedIPFSUris The URIs to get tiers of.
    /// @return tiers The tiers that correspond to the provided encoded IPFS URIs. Empty tiers are returned for URIs
    /// without a tier.
    function tiersFor(address hook, bytes32[] memory encodedIPFSUris) external view returns (JB721Tier[] memory tiers);

    /// @notice Configure the allowed criteria for publishing new NFTs to a hook.
    /// @param allowedPosts An array of criteria for allowed posts.
    function configurePostingCriteriaFor(CTAllowedPost[] memory allowedPosts) external;

    /// @notice Publish NFT posts and mint a first copy of each. A fee is taken for the fee project.
    /// @param hook The hook to mint from.
    /// @param posts An array of posts to publish as NFTs.
    /// @param nftBeneficiary The beneficiary of the NFT mints.
    /// @param feeBeneficiary The beneficiary of the fee project's tokens.
    /// @param additionalPayMetadata Extra metadata bytes to include in the payment.
    /// @param feeMetadata Metadata to send alongside the fee payment.
    function mintFrom(
        IJB721TiersHook hook,
        CTPost[] calldata posts,
        address nftBeneficiary,
        address feeBeneficiary,
        bytes calldata additionalPayMetadata,
        bytes calldata feeMetadata
    )
        external
        payable;
}
