// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";

import {ICTPublisher} from "./ICTPublisher.sol";

/// @notice A contract that can receive a Juicebox project NFT (via `safeTransferFrom`) and automatically grants the
/// Croptop publisher permission to manage the project's 721 tiers. Once the project is transferred to this contract,
/// its ownership is effectively burned while still allowing croptop posts.
interface ICTProjectOwner {
    /// @notice The contract where operator permissions are stored.
    /// @return The permissions contract.
    function PERMISSIONS() external view returns (IJBPermissions);

    /// @notice The contract from which Juicebox projects are minted as ERC-721 tokens.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The Croptop publisher that manages posting criteria and minting.
    /// @return The publisher contract.
    function PUBLISHER() external view returns (ICTPublisher);
}
