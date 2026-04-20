// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Criteria for allowed posts.
/// @custom:member category A category that should allow posts.
/// @custom:member minimumPrice The minimum price that a post to the specified category should cost.
/// @custom:member minimumTotalSupply The minimum total supply of NFTs that can be made available when minting.
/// @custom:member maxTotalSupply The max total supply of NFTs that can be made available when minting. Leave as 0 for
/// max.
/// @custom:member maximumSplitPercent The maximum split percent (out of JBConstants.SPLITS_TOTAL_PERCENT) that a
/// poster can set. 0 means splits are not allowed.
/// @custom:member allowedAddresses A list of addresses that are allowed to post on the category through Croptop.
struct CTDeployerAllowedPost {
    uint24 category;
    uint104 minimumPrice;
    uint32 minimumTotalSupply;
    uint32 maximumTotalSupply;
    uint32 maximumSplitPercent;
    address[] allowedAddresses;
}
