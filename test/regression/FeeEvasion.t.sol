// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

/// @title H19_FeeEvasion
/// @notice Fee evasion for existing tier mints.
///         Before the fix, a user could set post.price = 0 for an existing tier
///         to evade the 5% Croptop fee entirely. The fix reads the actual tier price
///         from the store for existing tiers.
contract H19_FeeEvasion is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address terminalAddr = makeAddr("terminal");
    address feeTerminalAddr = makeAddr("feeTerminal");
    address poster = makeAddr("poster");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    bytes32 constant TEST_URI = keccak256("existing-tier-content");
    uint104 constant TIER_PRICE = 1 ether;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        // Mock hook.owner().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        // Mock hook.PROJECT_ID().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(hookProjectId));
        // Mock hook.STORE().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));

        // Mock isTierRemoved to return false by default (tier exists).
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector), abi.encode(false)
        );

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Fund poster.
        vm.deal(poster, 100 ether);
    }

    function _configureCategory() internal {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    function _setupMintMocks(uint256 maxTierId) internal {
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(maxTierId)
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
    }

    /// @notice Test that fee is still charged when post.price = 0 for an existing tier.
    ///         Before the fix, the attacker could set post.price = 0 and pay exactly 0 ETH
    ///         for the fee. After the fix, the actual tier price is read from the store.
    function test_feeChargedForExistingTierEvenWithZeroPostPrice() public {
        _configureCategory();

        // First mint: create tier 1 with TIER_PRICE.
        _setupMintMocks(0);

        // Mock tierOf for tier 1 to return a tier with TIER_PRICE.
        JB721Tier memory tier = JB721Tier({
            id: 1,
            price: TIER_PRICE,
            remainingSupply: 9,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: TEST_URI,
            category: 5,
            discountPercent: 0,
            allowOwnerMint: false,
            transfersPausable: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: 0,
            resolvedUri: ""
        });
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.tierOf.selector, hookAddr, 1, false),
            abi.encode(tier)
        );

        // Mock terminals.
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, hookProjectId),
            abi.encode(terminalAddr)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, feeProjectId),
            abi.encode(feeTerminalAddr)
        );

        // Mock terminal.pay() to succeed and record the value sent.
        vm.mockCall(terminalAddr, "", abi.encode(uint256(0)));
        vm.mockCall(feeTerminalAddr, "", abi.encode(uint256(0)));

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            totalSupply: 10,
            price: TIER_PRICE,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // First mint to create the tier and populate the mapping.
        vm.prank(poster);
        publisher.mintFrom{value: 2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");

        // Verify the mapping was set.
        assertEq(publisher.tierIdForEncodedIPFSUriOf(hookAddr, TEST_URI), 1, "tier ID should be stored");

        // Now the attack: existing tier, but attacker sets post.price = 0.
        // Update mocks for the second mint (maxTierId is now 1).
        _setupMintMocks(1);

        CTPost[] memory attackPosts = new CTPost[](1);
        attackPosts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            totalSupply: 10,
            price: 0, // Attacker tries to evade fee by setting price = 0.
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // The fee is TIER_PRICE / FEE_DIVISOR = 1 ether / 20 = 0.05 ether.
        // The project payment is TIER_PRICE - fee = 1 ether - 0.05 ether = 0.95 ether.
        // Total required: TIER_PRICE = 1 ether (project gets 0.95 ether, fee is 0.05 ether).
        // With the fix, the actual tier price (1 ether) is used, so the full msg.value is needed.

        // Sending 0 ETH should revert because totalPrice is now the actual tier price (1 ether),
        // not the attacker's 0.
        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0}(IJB721TiersHook(hookAddr), attackPosts, poster, poster, "", "");

        // Sending the correct amount should succeed.
        vm.prank(poster);
        publisher.mintFrom{value: 2 ether}(IJB721TiersHook(hookAddr), attackPosts, poster, poster, "", "");
    }

    /// @notice Test that the correct fee amount is deducted for existing tier mints.
    ///         The fee should be based on the actual tier price, not post.price.
    function test_correctFeeDeductedForExistingTier() public {
        _configureCategory();

        // Create tier 1 with TIER_PRICE.
        _setupMintMocks(0);

        // Mock tierOf for tier 1.
        JB721Tier memory tier = JB721Tier({
            id: 1,
            price: TIER_PRICE,
            remainingSupply: 9,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: TEST_URI,
            category: 5,
            discountPercent: 0,
            allowOwnerMint: false,
            transfersPausable: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: 0,
            resolvedUri: ""
        });
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.tierOf.selector, hookAddr, 1, false),
            abi.encode(tier)
        );

        // Mock terminals.
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, hookProjectId),
            abi.encode(terminalAddr)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, feeProjectId),
            abi.encode(feeTerminalAddr)
        );
        vm.mockCall(terminalAddr, "", abi.encode(uint256(0)));
        vm.mockCall(feeTerminalAddr, "", abi.encode(uint256(0)));

        // First mint to create the tier.
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            totalSupply: 10,
            price: TIER_PRICE,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");

        // Second mint with the existing tier. Even with post.price = 0, the fee
        // should be based on the actual price (1 ether).
        _setupMintMocks(1);

        CTPost[] memory existingPosts = new CTPost[](1);
        existingPosts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            totalSupply: 10,
            price: 0, // Attacker sets price to 0.
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Fee = 1 ether / 20 = 0.05 ether
        // payValue = msg.value - fee = msg.value - 0.05 ether
        // totalPrice = 1 ether (from the store, not post.price)
        // Need: totalPrice <= payValue, i.e., 1 ether <= msg.value - 0.05 ether
        // So msg.value >= 1.05 ether

        // Sending exactly 1.05 ether should succeed.
        vm.prank(poster);
        publisher.mintFrom{value: 1.05 ether}(IJB721TiersHook(hookAddr), existingPosts, poster, poster, "", "");

        // Sending 1.04 ether should fail (1.04 - 0.05 = 0.99 < 1 ether totalPrice).
        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 1.04 ether}(IJB721TiersHook(hookAddr), existingPosts, poster, poster, "", "");
    }
}
