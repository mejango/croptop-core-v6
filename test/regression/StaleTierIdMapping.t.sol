// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

contract StaleTierStore {
    mapping(address hook => mapping(address owner => uint256 balance)) public balanceOf;

    uint256 public maxTierId;

    function maxTierIdOf(address) external view returns (uint256) {
        return maxTierId;
    }

    function mint(address hook, address owner, uint256 count) external {
        balanceOf[hook][owner] += count;
    }

    function setMaxTierId(uint256 value) external {
        maxTierId = value;
    }
}

contract StaleTierTerminal {
    StaleTierStore public store;

    address public hook;
    uint256 public mintCount;

    function configure(StaleTierStore store_, address hook_, uint256 mintCount_) external {
        store = store_;
        hook = hook_;
        mintCount = mintCount_;
    }

    function pay(
        uint256,
        address,
        uint256,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        if (mintCount != 0) store.mint({hook: hook, owner: beneficiary, count: mintCount});
        return 0;
    }
}

/// @title StaleTierIdMappingRegression
/// @notice Stale tierIdForEncodedIpfsUriOf mapping after external tier removal.
///         When a tier is removed externally via adjustTiers(), the publisher clears the stale mapping and allows the
///         post to fall through to new-tier creation.
contract StaleTierIdMappingRegression is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr;
    address terminalAddr;
    address poster = makeAddr("poster");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    bytes32 constant TEST_URI = keccak256("removable-content");

    StaleTierStore hookStore;
    StaleTierTerminal terminal;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        hookStore = new StaleTierStore();
        terminal = new StaleTierTerminal();
        hookStoreAddr = address(hookStore);
        terminalAddr = address(terminal);

        // Mock hook.owner().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        // Mock hook.projectId().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.projectId.selector), abi.encode(hookProjectId));
        // Mock hook.STORE().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));
        // Mock hook.pricingContext().
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.ETH), uint256(18))
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
        hookStore.setMaxTierId(maxTierId);
        terminal.configure({store_: hookStore, hook_: hookAddr, mintCount_: 100});
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(terminalAddr)
        );
    }

    /// @notice After a tier is removed externally, the stale mapping should be cleared
    ///         so that the same encodedIpfsUri can be re-posted as a new tier.
    function test_staleMappingClearedWhenTierRemoved() public {
        _configureCategory();

        // First mint: create tier 1 for TEST_URI.
        _setupMintMocks(0);

        // Mock isTierRemoved to return false (tier exists).
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, hookAddr, 1),
            abi.encode(false)
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: TEST_URI,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "");

        // Verify tier ID 1 was stored in the mapping.
        assertEq(
            publisher.tierIdForEncodedIpfsUriOf(hookAddr, TEST_URI), 1, "tier ID should be stored after first mint"
        );

        // Now simulate external tier removal: isTierRemoved returns true for tier 1.
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, hookAddr, 1),
            abi.encode(true)
        );

        // Mock tierOf for the removed tier because cache validation reads tier data before checking isTierRemoved.
        JB721Tier memory removedTier;
        removedTier.id = 1;
        removedTier.encodedIpfsUri = TEST_URI;
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.tierOf.selector, hookAddr, 1, false),
            abi.encode(removedTier)
        );

        // Update maxTierId to 1 so new tier gets ID 2.
        _setupMintMocks(1);

        // Second mint with the same URI should succeed by clearing the stale mapping and creating a new tier.
        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "");

        // Verify the mapping points to the new tier ID (2).
        assertEq(
            publisher.tierIdForEncodedIpfsUriOf(hookAddr, TEST_URI),
            2,
            "tier ID should be updated to new tier after re-post"
        );
    }

    /// @notice When a tier is NOT removed, the mapping should be used as-is (no re-creation).
    function test_existingTierNotRemovedUsesMapping() public {
        _configureCategory();

        // First mint: create tier 1 for TEST_URI.
        _setupMintMocks(0);

        // Mock isTierRemoved to return false (tier exists).
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, hookAddr, 1),
            abi.encode(false)
        );

        // Mock tierOf for tier 1 so the existing-tier price lookup succeeds.
        JB721Tier memory tier = JB721Tier({
            id: 1,
            price: 0.1 ether,
            remainingSupply: 9,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: TEST_URI,
            category: 5,
            discountPercent: 0,
            flags: JB721TierFlags({
                allowOwnerMint: false,
                transfersPausable: false,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
            splitPercent: 0,
            resolvedUri: ""
        });
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.tierOf.selector, hookAddr, 1, false),
            abi.encode(tier)
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: TEST_URI,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "");

        assertEq(publisher.tierIdForEncodedIpfsUriOf(hookAddr, TEST_URI), 1);

        // Second mint with existing tier (not removed) — should reuse tier ID 1.
        _setupMintMocks(1);

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "");

        // Mapping should still point to tier 1.
        assertEq(
            publisher.tierIdForEncodedIpfsUriOf(hookAddr, TEST_URI),
            1,
            "tier ID should remain unchanged when tier is not removed"
        );
    }
}
