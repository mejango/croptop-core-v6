// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {CTDeployerAllowedPost} from "../structs/CTDeployerAllowedPost.sol";

/// @notice Configuration for deploying a new Croptop project via CTDeployer.
/// @custom:member terminalConfigurations The terminals that the project uses to accept payments through.
/// @custom:member projectUri The metadata URI containing project info.
/// @custom:member allowedPosts The posting criteria that define what kinds of NFTs can be published to each category.
/// @custom:member contractUri A link to the 721 collection's metadata (e.g. OpenSea-compatible contract-level
/// metadata).
/// @custom:member name The name of the 721 collection where posts will be minted.
/// @custom:member symbol The symbol of the 721 collection where posts will be minted.
/// @custom:member salt A salt for deterministic deployment of the 721 hook (includes msg.sender for replay
/// protection).
struct CTProjectConfig {
    JBTerminalConfig[] terminalConfigurations;
    string projectUri;
    CTDeployerAllowedPost[] allowedPosts;
    string contractUri;
    string name;
    string symbol;
    bytes32 salt;
}
