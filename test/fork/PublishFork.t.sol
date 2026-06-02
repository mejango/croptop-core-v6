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
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";

// 721 hook — deploy fresh within fork.
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
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
import {CTAllowedPost} from "./../../src/structs/CTAllowedPost.sol";
import {CTPublisher} from "./../../src/CTPublisher.sol";
import {CTPost} from "./../../src/structs/CTPost.sol";

contract CroptopForkNonReceiverOwner {
    function codeHashAnchor() external pure returns (bytes32) {
        return keccak256("NOT_ERC721_RECEIVER");
    }
}

contract ForkMockERC20 {
    uint8 public immutable decimals;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ForkPermit2Wallet {
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    function approveToken(address token, address spender, uint256 amount) external {
        ForkMockERC20(token).approve(spender, amount);
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return ERC1271_MAGIC_VALUE;
    }

    function publishWithPermit2(
        CTPublisher publisher,
        IJB721TiersHook hook,
        CTPost[] calldata posts,
        address token,
        uint256 amount,
        address nftBeneficiary,
        address feeBeneficiary,
        JBSingleAllowance memory permit2Allowance,
        bytes calldata additionalPayMetadata
    )
        external
    {
        bytes4 permit2Id = JBMetadataResolver.getId({purpose: "permit2", target: address(publisher)});
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: additionalPayMetadata, idToAdd: permit2Id, dataToAdd: abi.encode(permit2Allowance)
        });

        publisher.mintFrom(hook, posts, token, amount, nftBeneficiary, feeBeneficiary, metadata, 0);
    }
}

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
    IPermit2 permit2;

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
        publisher = new CTPublisher(jbDirectory, jbPermissions, 1, permit2, trustedForwarder);
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
        publisher.mintFrom{value: totalValue}(
            testHook, posts, JBConstants.NATIVE_TOKEN, totalValue, nftBeneficiary, feeBeneficiary, "", 0
        );

        // Verify NFT was minted to the beneficiary.
        uint256 balanceAfter = IERC721(address(testHook)).balanceOf(nftBeneficiary);
        assertEq(balanceAfter, balanceBefore + 1, "NFT should be minted to beneficiary");
    }

    function testFork_MintFromSupportsTokenPricingAndPermit2() public {
        _assertMintFromPullsErc20WithPermit2();
        _assertMintFromSupportsDifferentPaymentCurrencyThroughPriceFeed();
        _assertMintFromSupportsUsdPricedUsdcProject();
    }

    function _assertMintFromPullsErc20WithPermit2() internal {
        ForkMockERC20 usdc = new ForkMockERC20(6);
        (uint256 projectId, IJB721TiersHook hook) = _launchDirectPricedProject({
            paymentToken: address(usdc),
            paymentDecimals: 6,
            paymentCurrency: JBCurrencyIds.USD,
            hookCurrency: JBCurrencyIds.USD,
            hookDecimals: 6
        });

        ForkPermit2Wallet permitPoster = new ForkPermit2Wallet();
        uint256 price = 100e6;
        uint256 fee = price / 20;
        uint256 totalAmount = price + fee;

        usdc.mint(address(permitPoster), totalAmount);
        permitPoster.approveToken(address(usdc), address(permit2), totalAmount);

        JBSingleAllowance memory permit2Allowance = JBSingleAllowance({
            sigDeadline: block.timestamp + 1 days,
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(totalAmount),
            expiration: uint48(block.timestamp + 2 days),
            nonce: 0,
            signature: ""
        });

        uint256 balanceBefore = IERC721(address(hook)).balanceOf(nftBeneficiary);
        uint256 projectBalanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, address(usdc));
        CTPost[] memory posts = _singlePost(TEST_URI, uint104(price), POST_SUPPLY, POST_CATEGORY);

        permitPoster.publishWithPermit2(
            publisher, hook, posts, address(usdc), totalAmount, nftBeneficiary, feeBeneficiary, permit2Allowance, ""
        );

        assertEq(IERC721(address(hook)).balanceOf(nftBeneficiary), balanceBefore + 1, "NFT should mint");
        assertEq(
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, address(usdc)) - projectBalanceBefore,
            price,
            "project should receive the post price"
        );
        assertEq(usdc.allowance(address(permitPoster), address(publisher)), 0, "publisher approval should stay unset");
    }

    function _assertMintFromSupportsDifferentPaymentCurrencyThroughPriceFeed() internal {
        ForkMockERC20 weth = new ForkMockERC20(18);
        (uint256 projectId, IJB721TiersHook hook) = _launchDirectPricedProject({
            paymentToken: address(weth),
            paymentDecimals: 18,
            paymentCurrency: JBCurrencyIds.ETH,
            hookCurrency: JBCurrencyIds.USD,
            hookDecimals: 6
        });

        MockPriceFeed ethPerUsd = new MockPriceFeed(5e14, 18);
        vm.prank(multisig);
        jbPrices.addPriceFeedFor({
            projectId: 0, pricingCurrency: JBCurrencyIds.ETH, unitCurrency: JBCurrencyIds.USD, feed: ethPerUsd
        });

        uint256 price = 100e6;
        uint256 convertedPrice = 5e16;
        uint256 fee = convertedPrice / 20;
        uint256 totalAmount = convertedPrice + fee;

        weth.mint(poster, totalAmount);
        vm.prank(poster);
        weth.approve(address(publisher), totalAmount);

        uint256 balanceBefore = IERC721(address(hook)).balanceOf(nftBeneficiary);
        uint256 projectBalanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, address(weth));
        CTPost[] memory posts = _singlePost(TEST_URI, uint104(price), POST_SUPPLY, POST_CATEGORY);

        vm.prank(poster);
        publisher.mintFrom(hook, posts, address(weth), totalAmount, nftBeneficiary, feeBeneficiary, "", 0);

        assertEq(IERC721(address(hook)).balanceOf(nftBeneficiary), balanceBefore + 1, "NFT should mint");
        assertEq(
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, address(weth)) - projectBalanceBefore,
            convertedPrice,
            "project should receive the converted post price"
        );
    }

    function _assertMintFromSupportsUsdPricedUsdcProject() internal {
        ForkMockERC20 usdc = new ForkMockERC20(6);
        (uint256 projectId, IJB721TiersHook hook) = _launchDirectPricedProject({
            paymentToken: address(usdc),
            paymentDecimals: 6,
            paymentCurrency: JBCurrencyIds.USD,
            hookCurrency: JBCurrencyIds.USD,
            hookDecimals: 6
        });

        uint256 price = 100e6;
        uint256 fee = price / 20;
        uint256 totalAmount = price + fee;

        usdc.mint(poster, totalAmount);
        vm.prank(poster);
        usdc.approve(address(publisher), totalAmount);

        uint256 balanceBefore = IERC721(address(hook)).balanceOf(nftBeneficiary);
        uint256 projectBalanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, address(usdc));
        CTPost[] memory posts = _singlePost(TEST_URI, uint104(price), POST_SUPPLY, POST_CATEGORY);

        vm.prank(poster);
        publisher.mintFrom(hook, posts, address(usdc), totalAmount, nftBeneficiary, feeBeneficiary, "", 0);

        assertEq(IERC721(address(hook)).balanceOf(nftBeneficiary), balanceBefore + 1, "NFT should mint");
        assertEq(
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, address(usdc)) - projectBalanceBefore,
            price,
            "project should receive the post price"
        );
    }

    function testFork_DeployProjectForRequiresSafeProjectNftReceiver() public {
        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: _ethTerminalConfig(),
            projectUri: "https://safe-transfer.croptop.eth/",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "https://safe-transfer.croptop.eth/contract",
            name: "SafeCrop",
            symbol: "SAFE",
            salt: bytes32(uint256(999))
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        address nonReceiverOwner = address(new CroptopForkNonReceiverOwner());

        vm.expectRevert();
        deployer.deployProjectFor(nonReceiverOwner, config, suckerConfig, jbController);
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
        publisher.mintFrom{value: totalValue}(
            testHook, posts, JBConstants.NATIVE_TOKEN, totalValue, nftBeneficiary, feeBeneficiary, "", 0
        );

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
        publisher.mintFrom{value: insufficientValue}(
            testHook, posts, JBConstants.NATIVE_TOKEN, insufficientValue, nftBeneficiary, feeBeneficiary, "", 0
        );
    }

    /// @notice Verify that minting the same encodedIpfsUri twice reuses the existing tier ID.
    function testFork_MintFromDuplicatePostReusesExistingTier() public {
        CTPost[] memory posts = _singlePost(TEST_URI, POST_PRICE, POST_SUPPLY, POST_CATEGORY);

        uint256 fee = uint256(POST_PRICE) / 20;
        uint256 totalValue = uint256(POST_PRICE) + fee;

        // First mint.
        vm.prank(poster);
        publisher.mintFrom{value: totalValue}(
            testHook, posts, JBConstants.NATIVE_TOKEN, totalValue, nftBeneficiary, feeBeneficiary, "", 0
        );

        // Record the tier ID assigned to this URI after the first mint.
        uint256 tierIdAfterFirst = publisher.tierIdForEncodedIpfsUriOf(address(testHook), TEST_URI);
        assertGt(tierIdAfterFirst, 0, "Tier ID should be non-zero after first mint");

        // Second mint with the same URI. The existing tier should be reused.
        vm.prank(poster);
        publisher.mintFrom{value: totalValue}(
            testHook, posts, JBConstants.NATIVE_TOKEN, totalValue, nftBeneficiary, feeBeneficiary, "", 0
        );

        // Verify the tier ID is unchanged — no new tier was created.
        uint256 tierIdAfterSecond = publisher.tierIdForEncodedIpfsUriOf(address(testHook), TEST_URI);
        assertEq(tierIdAfterFirst, tierIdAfterSecond, "Tier ID should be reused for duplicate encodedIpfsUri");

        // Verify two NFTs were minted total.
        assertEq(IERC721(address(testHook)).balanceOf(nftBeneficiary), 2, "Two NFTs should be minted across both calls");
    }

    /// @notice Verify unsorted multi-category posts are normalized before crossing into the canonical 721 store.
    function testFork_MintFromUnsortedCategoriesPublishesBothNFTs() public {
        CTPost[] memory posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIpfsUri: TEST_URI_2,
            price: POST_PRICE,
            totalSupply: POST_SUPPLY,
            category: 2,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIpfsUri: TEST_URI,
            price: POST_PRICE,
            totalSupply: POST_SUPPLY,
            category: POST_CATEGORY,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 totalPrice = uint256(POST_PRICE) * posts.length;
        uint256 fee = totalPrice / 20;

        uint256 balanceBefore = IERC721(address(testHook)).balanceOf(nftBeneficiary);

        vm.prank(poster);
        publisher.mintFrom{value: totalPrice + fee}(
            testHook, posts, JBConstants.NATIVE_TOKEN, totalPrice + fee, nftBeneficiary, feeBeneficiary, "", 0
        );

        assertEq(IERC721(address(testHook)).balanceOf(nftBeneficiary), balanceBefore + 2, "both NFTs should mint");
        assertEq(publisher.tierIdForEncodedIpfsUriOf(address(testHook), TEST_URI), 1, "category 1 tier sorted first");
        assertEq(publisher.tierIdForEncodedIpfsUriOf(address(testHook), TEST_URI_2), 2, "category 2 tier sorted second");
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

        permit2 = IPermit2(deployPermit2());

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            permit2,
            trustedForwarder
        );
    }

    function _deploy721Hook() internal {
        JB721TiersHookStore store = new JB721TiersHookStore();
        JBAddressRegistry addressRegistry = new JBAddressRegistry();
        JB721CheckpointsDeployer checkpointsDeployer = new JB721CheckpointsDeployer(store);

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

        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: opSuckerDeployer,
            directory: jbDirectory,
            permissions: jbPermissions,
            prices: jbPrices,
            tokens: jbTokens,
            feeProjectId: 1,
            registry: suckerRegistry,
            trustedForwarder: trustedForwarder
        });
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
        CTDeployerAllowedPost[] memory allowedPosts = new CTDeployerAllowedPost[](2);
        allowedPosts[0] = CTDeployerAllowedPost({
            category: POST_CATEGORY,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 10_000,
            maximumSplitPercent: 500_000_000, // 50%
            allowedAddresses: new address[](0) // anyone can post
        });
        allowedPosts[1] = CTDeployerAllowedPost({
            category: 2,
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

    function _launchDirectPricedProject(
        address paymentToken,
        uint8 paymentDecimals,
        uint32 paymentCurrency,
        uint32 hookCurrency,
        uint8 hookDecimals
    )
        internal
        returns (uint256 projectId, IJB721TiersHook hook)
    {
        projectId = jbProjects.count() + 1;
        hook = _deployPricedHook({projectId: projectId, hookCurrency: hookCurrency, hookDecimals: hookDecimals});

        uint256 launchedProjectId = _launchPricedRulesetFor({
            hook: hook,
            hookCurrency: hookCurrency,
            terminalConfigurations: _singleTokenTerminalConfig({
                token: paymentToken, decimals: paymentDecimals, currency: paymentCurrency
            })
        });
        assertEq(launchedProjectId, projectId, "hook/project ids should align");

        _grantPublisherTierPermission(projectId);
        _configureOpenPostCategory(hook);
    }

    function _configureOpenPostCategory(IJB721TiersHook hook) internal {
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

    function _grantPublisherTierPermission(uint256 projectId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;
        jbPermissions.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: address(publisher),
                // forge-lint: disable-next-line(unsafe-typecast)
                projectId: uint64(projectId),
                permissionIds: permissionIds
            })
        });
    }

    function _deployPricedHook(
        uint256 projectId,
        uint32 hookCurrency,
        uint8 hookDecimals
    )
        internal
        returns (IJB721TiersHook hook)
    {
        JB721InitTiersConfig memory tiersConfig =
            JB721InitTiersConfig({tiers: new JB721TierConfig[](0), currency: hookCurrency, decimals: hookDecimals});
        JB721TiersHookFlags memory flags = JB721TiersHookFlags({
            noNewTiersWithReserves: false,
            noNewTiersWithVotes: false,
            noNewTiersWithOwnerMinting: false,
            preventOverspending: false,
            issueTokensForSplits: false
        });
        JBDeploy721TiersHookConfig memory config = JBDeploy721TiersHookConfig({
            name: "PricedCrop",
            symbol: "PRICE",
            baseUri: "ipfs://",
            tokenUriResolver: IJB721TokenUriResolver(address(0)),
            contractUri: "ipfs://priced",
            tiersConfig: tiersConfig,
            flags: flags
        });

        hook =
            hookDeployer.deployHookFor({projectId: projectId, deployTiersHookConfig: config, salt: bytes32(projectId)});
    }

    function _launchPricedRulesetFor(
        IJB721TiersHook hook,
        uint32 hookCurrency,
        JBTerminalConfig[] memory terminalConfigurations
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].weight = 1_000_000 * (10 ** 18);
        rulesetConfigs[0].metadata.baseCurrency = hookCurrency;
        rulesetConfigs[0].metadata.dataHook = address(hook);
        rulesetConfigs[0].metadata.useDataHookForPay = true;
        rulesetConfigs[0].metadata.useDataHookForCashOut = true;

        projectId = jbController.launchProjectFor({
            owner: projectOwner,
            projectUri: "ipfs://priced-project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigurations,
            memo: "priced project"
        });
    }

    function _singleTokenTerminalConfig(
        address token,
        uint8 decimals,
        uint32 currency
    )
        internal
        view
        returns (JBTerminalConfig[] memory configs)
    {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: token, decimals: decimals, currency: currency});

        configs = new JBTerminalConfig[](1);
        configs[0] =
            JBTerminalConfig({terminal: IJBTerminal(address(jbMultiTerminal)), accountingContextsToAccept: contexts});
    }

    /// @notice Build a single-element CTPost array.
    function _singlePost(
        // forge-lint: disable-next-line(mixed-case-variable)
        bytes32 encodedIpfsUri,
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
            encodedIpfsUri: encodedIpfsUri,
            price: price,
            totalSupply: totalSupply,
            category: category,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }
}
