// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
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

import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";

import {CTPublisher} from "../src/CTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";
import {CTPost} from "../src/structs/CTPost.sol";

/// @notice Unit tests for CTPublisher.
contract TestCTPublisher is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address poster = makeAddr("poster");
    address unauthorized = makeAddr("unauthorized");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        // Mock hook.owner() for permission checks.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));

        // Mock hook.PROJECT_ID() for permission checks.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(hookProjectId));

        // Mock hook.STORE().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Fund poster.
        vm.deal(poster, 100 ether);
    }

    //*********************************************************************//
    // --- Constructor --------------------------------------------------- //
    //*********************************************************************//

    function test_constructor() public {
        assertEq(address(publisher.DIRECTORY()), address(directory));
        assertEq(publisher.FEE_PROJECT_ID(), feeProjectId);
        assertEq(publisher.FEE_DIVISOR(), 20);
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor + allowanceFor Round-Trip ---------- //
    //*********************************************************************//

    function test_configureAndReadAllowance() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 10,
            maximumTotalSupply: 1000,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (uint256 minPrice, uint256 minSupply, uint256 maxSupply, uint256 maxSplit, address[] memory allowed) =
            publisher.allowanceFor(hookAddr, 5);

        assertEq(minPrice, 0.01 ether, "minimum price should match");
        assertEq(minSupply, 10, "minimum supply should match");
        assertEq(maxSupply, 1000, "maximum supply should match");
        assertEq(maxSplit, 0, "maximum split percent should be zero");
        assertEq(allowed.length, 0, "no allowlist");
    }

    function test_configureWithAllowlist() public {
        address[] memory allowList = new address[](2);
        allowList[0] = poster;
        allowList[1] = hookOwner;

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 3,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: allowList
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (,,,, address[] memory allowed) = publisher.allowanceFor(hookAddr, 3);
        assertEq(allowed.length, 2, "should have 2 allowed addresses");
        assertEq(allowed[0], poster);
        assertEq(allowed[1], hookOwner);
    }

    function test_configureMultipleCategories() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](2);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 100,
            minimumTotalSupply: 5,
            maximumTotalSupply: 50,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        posts[1] = CTAllowedPost({
            hook: hookAddr,
            category: 2,
            minimumPrice: 200,
            minimumTotalSupply: 10,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (uint256 minPrice1, uint256 minSupply1, uint256 maxSupply1,,) = publisher.allowanceFor(hookAddr, 1);
        assertEq(minPrice1, 100);
        assertEq(minSupply1, 5);
        assertEq(maxSupply1, 50);

        (uint256 minPrice2, uint256 minSupply2, uint256 maxSupply2,,) = publisher.allowanceFor(hookAddr, 2);
        assertEq(minPrice2, 200);
        assertEq(minSupply2, 10);
        assertEq(maxSupply2, 100);
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Bit Packing Fuzz ----------------- //
    //*********************************************************************//

    function testFuzz_allowanceBitPacking(
        uint104 minPrice,
        uint32 minSupply,
        uint32 maxSupply,
        uint32 maxSplitPercent
    )
        public
    {
        vm.assume(minSupply > 0);
        vm.assume(maxSupply >= minSupply);

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 0,
            minimumPrice: minPrice,
            minimumTotalSupply: minSupply,
            maximumTotalSupply: maxSupply,
            maximumSplitPercent: maxSplitPercent,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (uint256 readPrice, uint256 readMinSupply, uint256 readMaxSupply, uint256 readMaxSplit,) =
            publisher.allowanceFor(hookAddr, 0);
        assertEq(readPrice, uint256(minPrice), "price round-trip");
        assertEq(readMinSupply, uint256(minSupply), "min supply round-trip");
        assertEq(readMaxSupply, uint256(maxSupply), "max supply round-trip");
        assertEq(readMaxSplit, uint256(maxSplitPercent), "max split percent round-trip");
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Validation Errors ----------------- //
    //*********************************************************************//

    function test_configureReverts_zeroMinSupply() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
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

    function test_configureReverts_minGreaterThanMax() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 100,
            maximumTotalSupply: 50,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_MaxTotalSupplyLessThanMin.selector, 100, 50));
        publisher.configurePostingCriteriaFor(posts);
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Permission Checks ----------------- //
    //*********************************************************************//

    function test_configureReverts_ifUnauthorized() public {
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

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Overwrite Previous Config --------- //
    //*********************************************************************//

    function test_configureOverwritesPrevious() public {
        CTAllowedPost[] memory posts1 = new CTAllowedPost[](1);
        posts1[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 100,
            minimumTotalSupply: 10,
            maximumTotalSupply: 50,
            maximumSplitPercent: 500_000_000,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts1);

        CTAllowedPost[] memory posts2 = new CTAllowedPost[](1);
        posts2[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 999,
            minimumTotalSupply: 1,
            maximumTotalSupply: 9999,
            maximumSplitPercent: 1_000_000_000,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts2);

        (uint256 minPrice, uint256 minSupply, uint256 maxSupply, uint256 maxSplit,) =
            publisher.allowanceFor(hookAddr, 1);
        assertEq(minPrice, 999, "price should be overwritten");
        assertEq(minSupply, 1, "min supply should be overwritten");
        assertEq(maxSupply, 9999, "max supply should be overwritten");
        assertEq(maxSplit, 1_000_000_000, "max split should be overwritten");
    }

    //*********************************************************************//
    // --- allowanceFor: Unconfigured Category --------------------------- //
    //*********************************************************************//

    function test_allowanceFor_unconfiguredReturnsZero() public {
        (uint256 minPrice, uint256 minSupply, uint256 maxSupply, uint256 maxSplit, address[] memory allowed) =
            publisher.allowanceFor(hookAddr, 999);

        assertEq(minPrice, 0);
        assertEq(minSupply, 0);
        assertEq(maxSupply, 0);
        assertEq(maxSplit, 0);
        assertEq(allowed.length, 0);
    }

    //*********************************************************************//
    // --- tierIdForEncodedIPFSUriOf ------------------------------------- //
    //*********************************************************************//

    function test_tierIdForEncodedIPFSUriOf_returnsZeroByDefault() public {
        bytes32 uri = keccak256("test");
        assertEq(publisher.tierIdForEncodedIPFSUriOf(hookAddr, uri), 0);
    }

    //*********************************************************************//
    // --- Split Configuration Round-Trip -------------------------------- //
    //*********************************************************************//

    function test_configureWithMaxSplitPercent() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 500_000_000,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (,,, uint256 maxSplit,) = publisher.allowanceFor(hookAddr, 5);
        assertEq(maxSplit, 500_000_000, "max split percent should be 50%");
    }

    function test_configureMaxSplitPercent_fullRange() public {
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

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (,,, uint256 maxSplit,) = publisher.allowanceFor(hookAddr, 5);
        assertEq(maxSplit, JBConstants.SPLITS_TOTAL_PERCENT, "max split should be 100%");
    }

    //*********************************************************************//
    // --- Split Percent Validation in mintFrom -------------------------- //
    //*********************************************************************//

    /// @dev Helper to configure a category with a maximum split percent.
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

    /// @dev Set up mocks for a successful mintFrom path (up to adjustTiers call).
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
            abi.encode(makeAddr("terminal"))
        );
        // Mock terminal.pay() — use a broad mock for the terminal address.
        vm.mockCall(makeAddr("terminal"), "", abi.encode(uint256(0)));
    }

    function test_mintFrom_splitPercentExceedsLimit_reverts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("greedy-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 600_000_000, // 60% exceeds 50% maximum!
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 600_000_000, 500_000_000
            )
        );
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    function test_mintFrom_splitPercentExactlyAtLimit_succeeds() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("exact-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 500_000_000, // Exactly at 50% limit.
            splits: new JBSplit[](0)
        });

        // Should pass validation. May revert downstream in mock, but NOT with split percent error.
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(
                            CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 500_000_000, 500_000_000
                        )
                    ),
                "should not revert with split percent error"
            );
        }
    }

    function test_mintFrom_zeroSplitPercent_alwaysAllowed() public {
        // Configure with zero max split (splits disabled).
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("no-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // splitPercent=0 should always be allowed (0 <= 0).
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 0, 0)
                    ),
                "should not revert with split percent error"
            );
        }
    }

    function test_mintFrom_nonzeroSplitPercent_whenDisabled_reverts() public {
        // Configure with zero max split (splits disabled).
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("sneaky-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 1, // Even 1 should fail when disabled.
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 1, 0));
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    function test_mintFrom_splitPercentWithinLimit_passesValidation() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 500_000_000);
        _setupMintMocks();

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: 250_000_000,
            projectId: 0,
            beneficiary: payable(poster),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("split-content"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 250_000_000, // 25% within 50% limit.
            splits: splits
        });

        // Should pass split validation.
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(
                            CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 250_000_000, 500_000_000
                        )
                    ),
                "should not revert with split percent error"
            );
        }
    }

    //*********************************************************************//
    // --- Split Percent Fuzz -------------------------------------------- //
    //*********************************************************************//

    function testFuzz_splitPercentValidation(uint32 maxSplitPercent, uint32 postSplitPercent) public {
        vm.assume(maxSplitPercent <= uint32(JBConstants.SPLITS_TOTAL_PERCENT));

        _configureCategoryWithSplits(5, 0, 1, 100, maxSplitPercent);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256(abi.encode("fuzz", postSplitPercent)),
            totalSupply: 10,
            price: 0.01 ether,
            category: 5,
            splitPercent: postSplitPercent,
            splits: new JBSplit[](0)
        });

        if (postSplitPercent > maxSplitPercent) {
            vm.prank(poster);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, postSplitPercent, maxSplitPercent
                )
            );
            publisher.mintFrom{value: 0.02 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
        } else {
            vm.prank(poster);
            try publisher.mintFrom{value: 0.02 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
            catch (bytes memory reason) {
                assertTrue(
                    keccak256(reason)
                        != keccak256(
                            abi.encodeWithSelector(
                                CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector,
                                postSplitPercent,
                                maxSplitPercent
                            )
                        ),
                    "should not revert with split percent error when within limit"
                );
            }
        }
    }

    //*********************************************************************//
    // --- Overwrite Split Config ---------------------------------------- //
    //*********************************************************************//

    function test_configureOverwritesSplitPercent() public {
        CTAllowedPost[] memory posts1 = new CTAllowedPost[](1);
        posts1[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 500_000_000,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts1);

        (,,, uint256 maxSplit1,) = publisher.allowanceFor(hookAddr, 1);
        assertEq(maxSplit1, 500_000_000);

        CTAllowedPost[] memory posts2 = new CTAllowedPost[](1);
        posts2[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts2);

        (,,, uint256 maxSplit2,) = publisher.allowanceFor(hookAddr, 1);
        assertEq(maxSplit2, 0, "max split should be overwritten to 0");
    }

    //*********************************************************************//
    // --- Multiple Posts With Different Split Percents ------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // --- Fee Validation in mintFrom ------------------------------------- //
    //*********************************************************************//

    function test_mintFrom_insufficientEthForFee_reverts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("fee-test"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Fee = 1 ether / 20 = 0.05 ether. Total needed = 1.05 ether.
        // Send only 0.04 ether — less than just the fee.
        uint256 fee = 1 ether / 20;
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(CTPublisher.CTPublisher_InsufficientEthSent.selector, 1 ether + fee, 0.04 ether)
        );
        publisher.mintFrom{value: 0.04 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    function test_mintFrom_exactPriceNoFee_reverts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("exact-price"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Send exactly 1 ether — covers price but not the 0.05 fee.
        // After fee deduction: payValue = 1 - 0.05 = 0.95, which is < totalPrice (1).
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_InsufficientEthSent.selector, 1 ether, 1 ether));
        publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    function test_mintFrom_exactPricePlusFee_succeeds() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("exact-fee"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Send exactly 1.05 ether (price + fee). Should not revert with InsufficientEthSent.
        uint256 fee = 1 ether / 20;
        vm.prank(poster);
        try publisher.mintFrom{value: 1 ether + fee}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            assertTrue(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(reason) != CTPublisher.CTPublisher_InsufficientEthSent.selector,
                "should not revert with InsufficientEthSent"
            );
        }
    }

    function test_mintFrom_feeProject_noFeeDeducted() public {
        // Configure a category on a hook whose PROJECT_ID == FEE_PROJECT_ID (1).
        address feeHook = makeAddr("feeHook");
        address feeHookStore = makeAddr("feeHookStore");
        vm.mockCall(feeHook, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        vm.mockCall(feeHook, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(feeProjectId));
        vm.mockCall(feeHook, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(feeHookStore));
        vm.mockCall(
            feeHookStore, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(uint256(0))
        );
        vm.mockCall(feeHook, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(feeHook, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(makeAddr("terminal"))
        );
        vm.mockCall(makeAddr("terminal"), "", abi.encode(uint256(0)));

        CTAllowedPost[] memory allowed = new CTAllowedPost[](1);
        allowed[0] = CTAllowedPost({
            hook: feeHook,
            category: 5,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(allowed);

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("fee-project-post"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Send exactly the price with no fee. Should not revert with InsufficientEthSent.
        vm.prank(poster);
        try publisher.mintFrom{value: 1 ether}(IJB721TiersHook(feeHook), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            assertTrue(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(reason) != CTPublisher.CTPublisher_InsufficientEthSent.selector,
                "fee project should not charge fee"
            );
        }
    }

    //*********************************************************************//
    // --- Multiple Posts With Different Split Percents ------------------- //
    //*********************************************************************//

    function test_mintFrom_nonzeroSplitPercent_passesSplitsToTier() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 500_000_000);
        _setupMintMocks();

        address splitBeneficiary = makeAddr("splitBeneficiary");

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: 500_000_000, // 50% of tier revenue to beneficiary
            projectId: 0,
            beneficiary: payable(splitBeneficiary),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("split-beneficiary-test"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 250_000_000, // 25% split
            splits: splits
        });

        // Build expected tier config to verify splits are passed through.
        JB721TierConfig[] memory expectedTiers = new JB721TierConfig[](1);
        expectedTiers[0] = JB721TierConfig({
            price: 0.1 ether,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: keccak256("split-beneficiary-test"),
            category: 5,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: true,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: 250_000_000,
            splits: splits
        });

        // Verify adjustTiers receives the tier config with the correct split beneficiary and percent.
        vm.expectCall(
            hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector, expectedTiers, new uint256[](0))
        );

        uint256 fee = 0.1 ether / 20;
        vm.prank(poster);
        publisher.mintFrom{value: 0.1 ether + fee}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    function test_mintFrom_multiplePostsDifferentSplits() public {
        // Category 5 allows up to 50% splits.
        _configureCategoryWithSplits(5, 0, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](2);
        // First post: 25% split (within limit).
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("post-1"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 250_000_000,
            splits: new JBSplit[](0)
        });
        // Second post: 60% split (exceeds limit).
        posts[1] = CTPost({
            encodedIPFSUri: keccak256("post-2"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 600_000_000,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 600_000_000, 500_000_000
            )
        );
        publisher.mintFrom{value: 0.4 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }
}
