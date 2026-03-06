// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

/// @notice A post to be published.
/// @custom:member encodedIPFSUri The encoded IPFS URI of the post that is being published.
/// @custom:member totalSupply The number of NFTs that should be made available, including the 1 that will be minted
/// alongside this transaction.
/// @custom:member price The price being paid for buying the post that is being published.
/// @custom:member category The category that the post should be published in.
/// @custom:member splitPercent The percent of the tier's price to route to the splits (out of
/// JBConstants.SPLITS_TOTAL_PERCENT).
/// @custom:member splits The splits to route funds to when this tier is minted.
struct CTPost {
    bytes32 encodedIPFSUri;
    uint32 totalSupply;
    uint104 price;
    uint24 category;
    uint32 splitPercent;
    JBSplit[] splits;
}
