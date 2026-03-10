// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../src/CTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";
import {CTPost} from "../src/structs/CTPost.sol";

/// @title CroptopAttacks
/// @notice Adversarial security tests for CTPublisher focusing on mintFrom edge cases,
///         allowlist bypasses, input validation, and split percent enforcement.
contract CroptopAttacks is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address terminalAddr = makeAddr("terminal");
    address poster = makeAddr("poster");
    address unauthorized = makeAddr("unauthorized");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        // Mock hook.owner().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        // Mock hook.PROJECT_ID().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(hookProjectId));
        // Mock hook.STORE().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Fund test accounts so they can send ETH with mintFrom.
        vm.deal(poster, 100 ether);
        vm.deal(unauthorized, 100 ether);
    }

    /// @dev Configure a standard category for testing.
    function _configureCategory(uint24 category, uint104 minPrice, uint32 minSupply, uint32 maxSupply) internal {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: category,
            minimumPrice: minPrice,
            minimumTotalSupply: minSupply,
            maximumTotalSupply: maxSupply,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    /// @dev Configure a category with an allowlist.
    function _configureCategoryWithAllowlist(uint24 category, address[] memory allowed) internal {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: category,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: allowed
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    /// @dev Configure a category with a maximum split percent.
    function _configureCategoryWithSplits(
        uint24 category,
        uint104 minPrice,
        uint32 minSupply,
        uint32 maxSupply,
        uint32 maxSplitPercent
    )
        internal
    {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: category,
            minimumPrice: minPrice,
            minimumTotalSupply: minSupply,
            maximumTotalSupply: maxSupply,
            maximumSplitPercent: maxSplitPercent,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    /// @dev Set up mocks for mintFrom path.
    function _setupMintMocks() internal {
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(uint256(0))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        // METADATA_ID_TARGET() selector.
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(terminalAddr)
        );
        vm.mockCall(terminalAddr, "", abi.encode(uint256(0)));
    }

    // =========================================================================
    // Test 1: Post to unconfigured category — should revert
    // =========================================================================
    function test_mintFrom_unconfiguredCategory_reverts() public {
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("test-content"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 999,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 2: Post with price below minimum — should revert
    // =========================================================================
    function test_mintFrom_belowMinPrice_reverts() public {
        _configureCategory(5, 0.1 ether, 1, 100);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("cheap-content"),
            totalSupply: 10,
            price: 0.01 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 3: Post with supply above maximum — should revert
    // =========================================================================
    function test_mintFrom_exceedsMaxSupply_reverts() public {
        _configureCategory(5, 0, 1, 50);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("big-supply"),
            totalSupply: 100,
            price: 0.01 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 4: Post with supply below minimum — should revert
    // =========================================================================
    function test_mintFrom_belowMinSupply_reverts() public {
        _configureCategory(5, 0, 10, 100);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("small-supply"),
            totalSupply: 5,
            price: 0.01 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 5: Allowlist bypass — non-allowed address posts to restricted category
    // =========================================================================
    function test_mintFrom_allowlistBypass_reverts() public {
        address[] memory allowed = new address[](1);
        allowed[0] = poster;

        _configureCategoryWithAllowlist(7, allowed);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("sneaky-content"),
            totalSupply: 10,
            price: 0.01 ether,
            category: 7,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, unauthorized, unauthorized, "", "");
    }

    // =========================================================================
    // Test 6: Zero IPFS URI — should revert
    // =========================================================================
    function test_mintFrom_zeroIPFSUri_reverts() public {
        _configureCategory(5, 0, 1, 100);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: bytes32(0),
            totalSupply: 10,
            price: 0.01 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 7: Configure with zero minSupply reverts
    // =========================================================================
    function test_configure_zeroMinSupply_reverts() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0,
            minimumTotalSupply: 0,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        vm.expectRevert(CTPublisher.CTPublisher_ZeroTotalSupply.selector);
        publisher.configurePostingCriteriaFor(posts);
    }

    // =========================================================================
    // Test 8: Configure without permission — should revert
    // =========================================================================
    function test_configure_noPermission_reverts() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        publisher.configurePostingCriteriaFor(posts);
    }

    // =========================================================================
    // Test 9: Split percent exceeds maximum — should revert
    // =========================================================================
    function test_mintFrom_splitPercentExceedsMaximum_reverts() public {
        _configureCategoryWithSplits(5, 0, 1, 100, 500_000_000); // 50% max
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("greedy-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 750_000_000, // 75% exceeds 50%
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 750_000_000, 500_000_000
            )
        );
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 10: Split percent when splits disabled (max=0) — should revert
    // =========================================================================
    function test_mintFrom_splitPercentWhenDisabled_reverts() public {
        _configureCategoryWithSplits(5, 0, 1, 100, 0); // Splits disabled
        _setupMintMocks();

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: 100_000_000,
            projectId: 0,
            beneficiary: payable(poster),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("sneaky-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 100_000_000, // Any amount when disabled
            splits: splits
        });

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 100_000_000, 0)
        );
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 11: Attacker re-configures to raise split percent
    // =========================================================================
    function test_reconfigure_raiseSplitPercent_requiresPermission() public {
        // Owner configures with 50% max split.
        _configureCategoryWithSplits(5, 0, 1, 100, 500_000_000);

        // Mock permissions to return false for unauthorized.
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(IJBPermissions.hasPermission.selector, unauthorized),
            abi.encode(false)
        );

        // Attacker tries to reconfigure with 100% max split.
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            allowedAddresses: new address[](0)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        publisher.configurePostingCriteriaFor(posts);
    }

    // =========================================================================
    // Test 12: Multiple posts — first valid, second exceeds split
    // =========================================================================
    function test_mintFrom_batchWithOneExceedingSplit_reverts() public {
        _configureCategoryWithSplits(5, 0, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("post-ok"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 250_000_000, // 25% OK
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIPFSUri: keccak256("post-bad"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 999_000_000, // 99.9% exceeds
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 999_000_000, 500_000_000
            )
        );
        publisher.mintFrom{value: 0.4 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }
}
