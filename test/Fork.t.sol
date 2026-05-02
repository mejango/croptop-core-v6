// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

// JB core — deploy fresh within fork.
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

// 721 hook — deploy fresh within fork.
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

// Suckers — deploy fresh within fork.
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBOptimismSuckerDeployer} from "@bananapus/suckers-v6/src/deployers/JBOptimismSuckerDeployer.sol";
import {JBOptimismSucker} from "@bananapus/suckers-v6/src/JBOptimismSucker.sol";

import {IOPMessenger} from "@bananapus/suckers-v6/src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "@bananapus/suckers-v6/src/interfaces/IOPStandardBridge.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {IJBSuckerDeployer} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerDeployer.sol";

import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

// Croptop — wildcard import pulls in all structs (CTProjectConfig, CTDeployerAllowedPost, etc.).
// forge-lint: disable-next-line(unaliased-plain-import)
import "./../src/CTDeployer.sol";
import {CTPublisher} from "./../src/CTPublisher.sol";

/// @notice Fork tests for Croptop. Deploys all JB infrastructure fresh within a mainnet fork.
contract ForkTest is Test {
    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

    // OP L1 bridge contracts (exist on Ethereum mainnet).
    IOPMessenger constant OP_L1_MESSENGER = IOPMessenger(0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1);
    IOPStandardBridge constant OP_L1_BRIDGE = IOPStandardBridge(0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1);

    // ───────────────────────── JB core (deployed fresh)
    // ───────────────────

    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBController jbController;

    // ───────────────────────── 721 hook (deployed fresh)
    // ──────────────────

    JB721TiersHookDeployer hookDeployer;

    // ───────────────────────── Suckers (deployed fresh)
    // ───────────────────

    JBSuckerRegistry suckerRegistry;
    JBOptimismSuckerDeployer opSuckerDeployer;

    // ───────────────────────── Croptop
    // ────────────────────────────────────

    CTPublisher publisher;
    CTDeployer deployer;

    function setUp() public {
        // Fork ETH mainnet.
        vm.createSelectFork("ethereum");

        // Deploy all JB core contracts fresh within the fork.
        _deployJBCore();

        // Deploy the 721 hook infrastructure.
        _deploy721Hook();

        // Deploy the sucker infrastructure.
        _deploySuckers();

        // Deploy the croptop contracts.
        publisher = new CTPublisher(jbDirectory, jbPermissions, 1, trustedForwarder);
        deployer = new CTDeployer(jbPermissions, jbProjects, hookDeployer, publisher, suckerRegistry, trustedForwarder);
    }

    function testDeployProject(address owner) public {
        vm.assume(owner != address(0) && owner.code.length == 0);

        // Create the project config.
        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "https://croptop.eth.sucks/",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "https://croptop.eth.sucks/",
            name: "Croptop",
            symbol: "CROP",
            salt: bytes32(0)
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        deployer.deployProjectFor(owner, config, suckerConfig, jbController);
    }

    function testDeployProjectWithSuckers(address owner, bytes32 salt, bytes32 suckerSalt) public {
        vm.assume(owner != address(0) && owner.code.length == 0);
        vm.assume(suckerSalt != bytes32(0));

        // Create the project config.
        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "https://croptop.eth.sucks/",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "https://croptop.eth.sucks/",
            name: "Croptop",
            symbol: "CROP",
            salt: salt
        });

        // Create the sucker config.
        JBTokenMapping[] memory tokens = new JBTokenMapping[](1);
        tokens[0] = JBTokenMapping({
            localToken: address(JBConstants.NATIVE_TOKEN),
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory deployerConfigurations = new JBSuckerDeployerConfig[](1);
        deployerConfigurations[0] = JBSuckerDeployerConfig({
            deployer: IJBSuckerDeployer(address(opSuckerDeployer)), peer: bytes32(0), mappings: tokens
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: deployerConfigurations, salt: suckerSalt});

        // Deploy the project.
        (uint256 projectId,) = deployer.deployProjectFor(owner, config, suckerConfig, jbController);

        // Check that the projectId has a sucker.
        assertEq(suckerRegistry.suckersOf(projectId).length, deployerConfigurations.length);
    }

    // ───────────────────────── Internal deployment helpers
    // ────────────────

    // forge-lint: disable-next-line(mixed-case-function)
    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0), // omnichainRulesetOperator
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);
    }

    function _deploy721Hook() internal {
        JB721TiersHookStore store = new JB721TiersHookStore();
        JBAddressRegistry addressRegistry = new JBAddressRegistry();
        JB721CheckpointsDeployer checkpointsDeployer = new JB721CheckpointsDeployer();

        JB721TiersHook hookImpl = new JB721TiersHook(
            jbDirectory, jbPermissions, jbPrices, jbRulesets, store, jbSplits, checkpointsDeployer, trustedForwarder
        );

        hookDeployer = new JB721TiersHookDeployer(hookImpl, store, addressRegistry, trustedForwarder);
    }

    function _deploySuckers() internal {
        suckerRegistry = new JBSuckerRegistry(jbDirectory, jbPermissions, multisig, trustedForwarder);

        // Deploy the OP sucker deployer with `multisig` as the configurator.
        opSuckerDeployer =
            new JBOptimismSuckerDeployer(jbDirectory, jbPermissions, jbTokens, multisig, trustedForwarder);

        // Configure the OP sucker deployer with L1 bridge addresses.
        vm.startPrank(multisig);
        opSuckerDeployer.setChainSpecificConstants(OP_L1_MESSENGER, OP_L1_BRIDGE);

        // Deploy and configure the singleton.
        JBOptimismSucker singleton = new JBOptimismSucker(
            opSuckerDeployer, jbDirectory, jbPermissions, jbTokens, 1, suckerRegistry, trustedForwarder
        );
        opSuckerDeployer.configureSingleton(singleton);

        // Allow the deployer in the registry.
        suckerRegistry.allowSuckerDeployer(address(opSuckerDeployer));
        vm.stopPrank();
    }
}
