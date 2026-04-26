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
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";

// 721 hook — deploy fresh within fork.
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Suckers — deploy fresh within fork.
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBOptimismSuckerDeployer} from "@bananapus/suckers-v6/src/deployers/JBOptimismSuckerDeployer.sol";
import {JBOptimismSucker} from "@bananapus/suckers-v6/src/JBOptimismSucker.sol";
import {IOPMessenger} from "@bananapus/suckers-v6/src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "@bananapus/suckers-v6/src/interfaces/IOPStandardBridge.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

// Permit2
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "@uniswap/permit2/test/utils/DeployPermit2.sol";

// Croptop
// forge-lint: disable-next-line(unaliased-plain-import)
import "./../../src/CTDeployer.sol";
import {CTPublisher} from "./../../src/CTPublisher.sol";
import {CTPost} from "./../../src/structs/CTPost.sol";

/// @notice Fork tests for CTPublisher.mintFrom(). Deploys all JB infrastructure fresh within a mainnet fork,
///         then exercises the publish-and-mint flow end-to-end.
contract PublishForkTest is Test, DeployPermit2 {
    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

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

    // Terminal infrastructure.
    JBFeelessAddresses jbFeelessAddresses;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

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

    // ───────────────────────── Test actors & state
    // ────────────────────────

    address projectOwner = address(0xA11CE);
    address poster = address(0xB0B);
    address nftBeneficiary = address(0xCAFE);
    address feeBeneficiary = address(0xFEE);

    uint256 feeProjectId; // project 1
    uint256 testProjectId;
    IJB721TiersHook testHook;

    // ───────────────────────── Constants
    // ──────────────────────────────────

    uint104 constant POST_PRICE = 0.1 ether;
    uint32 constant POST_SUPPLY = 100;
    uint24 constant POST_CATEGORY = 1;
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 constant TEST_URI = bytes32("test_ipfs_uri");
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 constant TEST_URI_2 = bytes32("test_ipfs_uri_2");

    // ───────────────────────── Setup
    // ─────────────────────────────────────

    function setUp() public {
        // Fork ETH mainnet at a pinned block to avoid RPC tip-of-chain flakiness.
        vm.createSelectFork("ethereum", 24_960_000);

        // Deploy all JB core contracts fresh within the fork.
        _deployJBCore();

        // CTDeployer hardcodes baseCurrency = JBCurrencyIds.ETH (1), but the accounting context
        // uses currency = uint32(uint160(NATIVE_TOKEN)) = 61166. Add an identity price feed
        // so JBPrices can convert between them.
        MockPriceFeed identityFeed = new MockPriceFeed(1e18, 18);
        vm.prank(multisig);
        jbPrices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            unitCurrency: JBCurrencyIds.ETH,
            feed: identityFeed
        });

        // Deploy the terminal infrastructure.
        _deployTerminal();

        // Deploy the 721 hook infrastructure.
        _deploy721Hook();

        // Deploy the sucker infrastructure.
        _deploySuckers();

        // Deploy the croptop contracts.
        publisher = new CTPublisher(jbDirectory, jbPermissions, 1, trustedForwarder);
        deployer = new CTDeployer(jbPermissions, jbProjects, hookDeployer, publisher, suckerRegistry, trustedForwarder);

        // Launch the fee project (project 1) with a terminal that accepts ETH.
        feeProjectId = _launchFeeProject();

        // Launch a test project via CTDeployer with a terminal + allowed posts.
        (testProjectId, testHook) = _launchTestProject();

        // Fund the poster.
        vm.deal(poster, 10 ether);
    }

    // ───────────────────────── Tests
    // ─────────────────────────────────────

    /// @notice Verify that mintFrom() mints an NFT to the specified beneficiary.
    function testFork_MintFromPublishesNFT() public {
        // Build a valid post.
        CTPost[] memory posts = _singlePost(TEST_URI, POST_PRICE, POST_SUPPLY, POST_CATEGORY);

        // Calculate required msg.value: price + fee.
        uint256 fee = uint256(POST_PRICE) / 20;
        uint256 totalValue = uint256(POST_PRICE) + fee;

        // Check NFT balance before.
        uint256 balanceBefore = IERC721(address(testHook)).balanceOf(nftBeneficiary);

        // Mint.
        vm.prank(poster);
        publisher.mintFrom{value: totalValue}(testHook, posts, nftBeneficiary, feeBeneficiary, "", "");

        // Verify NFT was minted to the beneficiary.
        uint256 balanceAfter = IERC721(address(testHook)).balanceOf(nftBeneficiary);
        assertEq(balanceAfter, balanceBefore + 1, "NFT should be minted to beneficiary");
    }

    /// @notice Verify 5% fee is routed to fee project and the rest to the test project.
    function testFork_MintFromFeeDistribution() public {
        CTPost[] memory posts = _singlePost(TEST_URI, POST_PRICE, POST_SUPPLY, POST_CATEGORY);

        uint256 fee = uint256(POST_PRICE) / 20;
        uint256 totalValue = uint256(POST_PRICE) + fee;

        // Record terminal balances before minting.
        uint256 feeProjectBalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        uint256 testProjectBalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), testProjectId, JBConstants.NATIVE_TOKEN);

        // Mint.
        vm.prank(poster);
        publisher.mintFrom{value: totalValue}(testHook, posts, nftBeneficiary, feeBeneficiary, "", "");

        // Verify fee project terminal balance increased by the fee amount.
        uint256 feeProjectBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            feeProjectBalanceAfter - feeProjectBalanceBefore,
            fee,
            "Fee project balance should increase by totalPrice / 20"
        );

        // Verify test project terminal balance increased by the post price.
        uint256 testProjectBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), testProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            testProjectBalanceAfter - testProjectBalanceBefore,
            uint256(POST_PRICE),
            "Test project balance should increase by post price"
        );
    }

    /// @notice Verify that sending less ETH than required reverts.
    function testFork_MintFromInsufficientFeeReverts() public {
        CTPost[] memory posts = _singlePost(TEST_URI, POST_PRICE, POST_SUPPLY, POST_CATEGORY);

        // Send only the post price, not the post price + fee.
        uint256 insufficientValue = uint256(POST_PRICE);

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: insufficientValue}(testHook, posts, nftBeneficiary, feeBeneficiary, "", "");
    }

    /// @notice Verify that minting the same encodedIPFSUri twice reuses the existing tier ID.
    function testFork_MintFromDuplicatePostReusesExistingTier() public {
        CTPost[] memory posts = _singlePost(TEST_URI, POST_PRICE, POST_SUPPLY, POST_CATEGORY);

        uint256 fee = uint256(POST_PRICE) / 20;
        uint256 totalValue = uint256(POST_PRICE) + fee;

        // First mint.
        vm.prank(poster);
        publisher.mintFrom{value: totalValue}(testHook, posts, nftBeneficiary, feeBeneficiary, "", "");

        // Record the tier ID assigned to this URI after the first mint.
        uint256 tierIdAfterFirst = publisher.tierIdForEncodedIPFSUriOf(address(testHook), TEST_URI);
        assertGt(tierIdAfterFirst, 0, "Tier ID should be non-zero after first mint");

        // Second mint with the same URI. The existing tier should be reused.
        vm.prank(poster);
        publisher.mintFrom{value: totalValue}(testHook, posts, nftBeneficiary, feeBeneficiary, "", "");

        // Verify the tier ID is unchanged — no new tier was created.
        uint256 tierIdAfterSecond = publisher.tierIdForEncodedIPFSUriOf(address(testHook), TEST_URI);
        assertEq(tierIdAfterFirst, tierIdAfterSecond, "Tier ID should be reused for duplicate encodedIPFSUri");

        // Verify two NFTs were minted total.
        assertEq(IERC721(address(testHook)).balanceOf(nftBeneficiary), 2, "Two NFTs should be minted across both calls");
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

    function _deployTerminal() internal {
        jbFeelessAddresses = new JBFeelessAddresses(multisig);
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
            trustedForwarder
        );
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

        opSuckerDeployer =
            new JBOptimismSuckerDeployer(jbDirectory, jbPermissions, jbTokens, multisig, trustedForwarder);

        vm.startPrank(multisig);
        opSuckerDeployer.setChainSpecificConstants(OP_L1_MESSENGER, OP_L1_BRIDGE);

        JBOptimismSucker singleton = new JBOptimismSucker(
            opSuckerDeployer, jbDirectory, jbPermissions, jbTokens, 1, suckerRegistry, trustedForwarder
        );
        opSuckerDeployer.configureSingleton(singleton);

        suckerRegistry.allowSuckerDeployer(address(opSuckerDeployer));
        vm.stopPrank();
    }

    /// @notice Launch fee project (project 1) with ETH terminal so it can receive fees.
    function _launchFeeProject() internal returns (uint256 projectId) {
        // Build terminal config accepting native ETH.
        JBTerminalConfig[] memory terminalConfigs = _ethTerminalConfig();

        // A simple ruleset with no special rules.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].weight = 1_000_000 * (10 ** 18);
        rulesetConfigs[0].metadata.baseCurrency = JBCurrencyIds.ETH;

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "Fee Project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: "Fee project launch"
        });

        // Sanity check: fee project must be project 1.
        assertEq(projectId, 1, "Fee project must be project ID 1");
    }

    /// @notice Launch a test project via CTDeployer with ETH terminal and allowed posts.
    function _launchTestProject() internal returns (uint256 projectId, IJB721TiersHook hook) {
        // Build terminal config accepting native ETH.
        JBTerminalConfig[] memory terminalConfigs = _ethTerminalConfig();

        // Build allowed posts for the deployer.
        CTDeployerAllowedPost[] memory allowedPosts = new CTDeployerAllowedPost[](1);
        allowedPosts[0] = CTDeployerAllowedPost({
            category: POST_CATEGORY,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 10_000,
            maximumSplitPercent: 500_000_000, // 50%
            allowedAddresses: new address[](0) // anyone can post
        });

        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: terminalConfigs,
            projectUri: "https://test.croptop.eth/",
            allowedPosts: allowedPosts,
            contractUri: "https://test.croptop.eth/contract",
            name: "TestCrop",
            symbol: "TCROP",
            salt: bytes32(uint256(1))
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        (projectId, hook) = deployer.deployProjectFor(projectOwner, config, suckerConfig, jbController);
    }

    /// @notice Build a JBTerminalConfig[] with a single entry for native ETH.
    function _ethTerminalConfig() internal view returns (JBTerminalConfig[] memory configs) {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        configs = new JBTerminalConfig[](1);
        configs[0] =
            JBTerminalConfig({terminal: IJBTerminal(address(jbMultiTerminal)), accountingContextsToAccept: contexts});
    }

    /// @notice Build a single-element CTPost array.
    function _singlePost(
        // forge-lint: disable-next-line(mixed-case-variable)
        bytes32 encodedIPFSUri,
        uint104 price,
        uint32 totalSupply,
        uint24 category
    )
        internal
        pure
        returns (CTPost[] memory posts)
    {
        posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: encodedIPFSUri,
            price: price,
            totalSupply: totalSupply,
            category: category,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }
}
