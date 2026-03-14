// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @custom:member deployerConfigurations The information for how to suck tokens to other chains.
/// @custom:member salt The salt to use for creating suckers so that they use the same address across chains.
// forge-lint: disable-next-line(pascal-case-struct)
struct CTSuckerDeploymentConfig {
    JBSuckerDeployerConfig[] deployerConfigurations;
    bytes32 salt;
}
