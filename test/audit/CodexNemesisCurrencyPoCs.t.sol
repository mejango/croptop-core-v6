// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

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
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";

import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "@uniswap/permit2/test/utils/DeployPermit2.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTDeployerAllowedPost} from "../../src/structs/CTDeployerAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";
import {CTProjectConfig} from "../../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

contract CodexNemesisCurrencyPoCs is Test, DeployPermit2 {
    address internal constant MULTISIG = address(0xBEEF);
    address internal constant PROJECT_OWNER = address(0xA11CE);
    address internal constant POSTER = address(0xB0B);
    address internal constant NFT_BENEFICIARY = address(0xCAFE);
    address internal constant FEE_BENEFICIARY = address(0xFEE);

    uint104 internal constant POST_PRICE = 0.1 ether;
    uint32 internal constant POST_SUPPLY = 100;
    uint24 internal constant POST_CATEGORY = 1;
    bytes32 internal constant TEST_URI = bytes32("nemesis-uri");

    JBPermissions internal jbPermissions;
    JBProjects internal jbProjects;
    JBDirectory internal jbDirectory;
    JBRulesets internal jbRulesets;
    JBTokens internal jbTokens;
    JBSplits internal jbSplits;
    JBPrices internal jbPrices;
    JBFundAccessLimits internal jbFundAccessLimits;
    JBController internal jbController;
    JBFeelessAddresses internal jbFeelessAddresses;
    JBTerminalStore internal jbTerminalStore;
    JBMultiTerminal internal jbMultiTerminal;
    JB721TiersHookDeployer internal hookDeployer;
    JBSuckerRegistry internal suckerRegistry;

    function test_deployerProjectsNeedAnUndeclaredIdentityPriceFeed() public {
        _deployCore();
        _deployTerminal();
        _deployHookInfra();
        suckerRegistry = new JBSuckerRegistry(jbDirectory, jbPermissions, MULTISIG, address(0));

        uint256 feeProjectId = _launchProject({
            owner: PROJECT_OWNER,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            dataHook: address(0),
            useDataHookForPay: false,
            useDataHookForCashOut: false
        });

        CTPublisher publisher = new CTPublisher(jbDirectory, jbPermissions, feeProjectId, address(0));
        CTDeployer deployer =
            new CTDeployer(jbPermissions, jbProjects, hookDeployer, publisher, suckerRegistry, address(0));

        (uint256 projectId, IJB721TiersHook hook) = _launchViaCTDeployer(deployer, PROJECT_OWNER);
        assertEq(projectId, 2, "expected the first Croptop project to be project 2");

        vm.deal(POSTER, 1 ether);

        vm.prank(POSTER);
        vm.expectRevert();
        publisher.mintFrom{value: _totalValue()}(hook, _singlePost(), NFT_BENEFICIARY, FEE_BENEFICIARY, "", "");

        MockPriceFeed identityFeed = new MockPriceFeed(1e18, 18);
        vm.prank(MULTISIG);
        jbPrices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            unitCurrency: JBCurrencyIds.ETH,
            feed: identityFeed
        });

        vm.prank(POSTER);
        publisher.mintFrom{value: _totalValue()}(hook, _singlePost(), NFT_BENEFICIARY, FEE_BENEFICIARY, "", "");
    }

    function test_misconfiguredFeeProjectRefundsAllCroptopFees() public {
        _deployCore();
        _deployTerminal();
        _deployHookInfra();

        uint256 feeProjectId = _launchProject({
            owner: PROJECT_OWNER,
            baseCurrency: JBCurrencyIds.ETH,
            dataHook: address(0),
            useDataHookForPay: false,
            useDataHookForCashOut: false
        });

        CTPublisher publisher = new CTPublisher(jbDirectory, jbPermissions, feeProjectId, address(0));

        (uint256 projectId, IJB721TiersHook hook) = _launchDirectProjectWithHook({
            publisher: publisher,
            owner: PROJECT_OWNER,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        assertEq(projectId, 2, "expected the publish target to be project 2");

        vm.deal(POSTER, 1 ether);
        uint256 posterBalanceBefore = POSTER.balance;
        uint256 feeProjectBalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        uint256 targetBalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, JBConstants.NATIVE_TOKEN);

        vm.prank(POSTER);
        publisher.mintFrom{value: _totalValue()}(hook, _singlePost(), NFT_BENEFICIARY, FEE_BENEFICIARY, "", "");

        uint256 feeProjectBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        uint256 targetBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, JBConstants.NATIVE_TOKEN);

        assertEq(feeProjectBalanceAfter - feeProjectBalanceBefore, 0, "fee project should not receive the fee");
        assertEq(targetBalanceAfter - targetBalanceBefore, POST_PRICE, "target project should still receive the post");
        assertEq(
            posterBalanceBefore - POSTER.balance,
            POST_PRICE,
            "the fee should be refunded back to the caller after the fee-project pay reverts"
        );
    }

    function _deployCore() internal {
        jbPermissions = new JBPermissions(address(0));
        jbProjects = new JBProjects(MULTISIG, address(0), address(0));
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, MULTISIG);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, MULTISIG, address(0));
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
            address(0),
            address(0)
        );

        vm.prank(MULTISIG);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);
    }

    function _deployTerminal() internal {
        jbFeelessAddresses = new JBFeelessAddresses(MULTISIG);
        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        address permit2 = deployPermit2();

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            IPermit2(permit2),
            address(0)
        );
    }

    function _deployHookInfra() internal {
        JB721TiersHookStore store = new JB721TiersHookStore();
        JBAddressRegistry addressRegistry = new JBAddressRegistry();
        JB721CheckpointsDeployer checkpointsDeployer = new JB721CheckpointsDeployer();

        JB721TiersHook hookImpl = new JB721TiersHook(
            jbDirectory, jbPermissions, jbPrices, jbRulesets, store, jbSplits, checkpointsDeployer, address(0)
        );

        hookDeployer = new JB721TiersHookDeployer(hookImpl, store, addressRegistry, address(0));
    }

    function _launchProject(
        address owner,
        uint32 baseCurrency,
        address dataHook,
        bool useDataHookForPay,
        bool useDataHookForCashOut
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].weight = 1_000_000 * (10 ** 18);
        rulesetConfigs[0].metadata.baseCurrency = baseCurrency;
        rulesetConfigs[0].metadata.dataHook = dataHook;
        rulesetConfigs[0].metadata.useDataHookForPay = useDataHookForPay;
        rulesetConfigs[0].metadata.useDataHookForCashOut = useDataHookForCashOut;

        projectId = jbController.launchProjectFor({
            owner: owner,
            projectUri: "ipfs://project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: _ethTerminalConfig(),
            memo: "nemesis launch"
        });
    }

    function _launchViaCTDeployer(
        CTDeployer deployer,
        address owner
    )
        internal
        returns (uint256 projectId, IJB721TiersHook hook)
    {
        CTDeployerAllowedPost[] memory allowedPosts = new CTDeployerAllowedPost[](1);
        allowedPosts[0] = CTDeployerAllowedPost({
            category: POST_CATEGORY,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 10_000,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: _ethTerminalConfig(),
            projectUri: "ipfs://croptop",
            allowedPosts: allowedPosts,
            contractUri: "ipfs://contract",
            name: "Croptop",
            symbol: "CROP",
            salt: bytes32(uint256(1))
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        (projectId, hook) = deployer.deployProjectFor(owner, config, suckerConfig, jbController);
    }

    function _launchDirectProjectWithHook(
        CTPublisher publisher,
        address owner,
        uint32 baseCurrency
    )
        internal
        returns (uint256 projectId, IJB721TiersHook hook)
    {
        projectId = jbProjects.count() + 1;
        hook = hookDeployer.deployHookFor({
            projectId: projectId,
            deployTiersHookConfig: JBDeploy721TiersHookConfig({
                name: "DirectCrop",
                symbol: "DIR",
                baseUri: "ipfs://",
                tokenUriResolver: IJB721TokenUriResolver(address(0)),
                contractUri: "ipfs://contract",
                tiersConfig: JB721InitTiersConfig({
                    tiers: new JB721TierConfig[](0),
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    decimals: 18
                }),
                flags: JB721TiersHookFlags({
                    noNewTiersWithReserves: false,
                    noNewTiersWithVotes: false,
                    noNewTiersWithOwnerMinting: false,
                    preventOverspending: false,
                    issueTokensForSplits: false
                })
            }),
            salt: bytes32(uint256(2))
        });

        uint256 launchedProjectId = _launchProject({
            owner: owner,
            baseCurrency: baseCurrency,
            dataHook: address(hook),
            useDataHookForPay: true,
            useDataHookForCashOut: true
        });
        assertEq(launchedProjectId, projectId, "hook/project ids should stay aligned");

        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;
        jbPermissions.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: address(publisher),
                projectId: uint64(projectId),
                permissionIds: permissionIds
            })
        });

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(hook),
            category: POST_CATEGORY,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 10_000,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        publisher.configurePostingCriteriaFor(allowedPosts);
    }

    function _ethTerminalConfig() internal view returns (JBTerminalConfig[] memory configs) {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        configs = new JBTerminalConfig[](1);
        configs[0] =
            JBTerminalConfig({terminal: IJBTerminal(address(jbMultiTerminal)), accountingContextsToAccept: contexts});
    }

    function _singlePost() internal pure returns (CTPost[] memory posts) {
        posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            price: POST_PRICE,
            totalSupply: POST_SUPPLY,
            category: POST_CATEGORY,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }

    function _totalValue() internal pure returns (uint256) {
        return POST_PRICE + (POST_PRICE / 20);
    }
}
