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
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";

contract CodexNemesisPolicyReuseTest is Test {
    CTPublisher internal publisher;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));

    address internal hookOwner = makeAddr("hookOwner");
    address internal hookAddr = makeAddr("hook");
    address internal hookStoreAddr = makeAddr("hookStore");
    address internal projectTerminal = makeAddr("projectTerminal");
    address internal feeTerminal = makeAddr("feeTerminal");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant FEE_PROJECT_ID = 1;
    uint256 internal constant PROJECT_ID = 42;
    bytes32 internal constant URI = keccak256("stale-policy-uri");
    uint104 internal constant PRICE = 1 ether;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, FEE_PROJECT_ID, address(0));

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(PROJECT_ID));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));

        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, PROJECT_ID),
            abi.encode(projectTerminal)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, FEE_PROJECT_ID),
            abi.encode(feeTerminal)
        );
        vm.mockCall(projectTerminal, "", abi.encode(uint256(0)));
        vm.mockCall(feeTerminal, "", abi.encode(uint256(0)));
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector), abi.encode(false)
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_existingTierReuseIgnoresUpdatedAllowlist() public {
        uint256 mintValue = PRICE + (PRICE / publisher.FEE_DIVISOR());

        _configureAllowlist(alice);

        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(uint256(0))
        );

        CTPost[] memory initialPosts = _singlePost();

        vm.prank(alice);
        publisher.mintFrom{value: mintValue}(IJB721TiersHook(hookAddr), initialPosts, alice, alice, "", "");

        assertEq(publisher.tierIdForEncodedIPFSUriOf(hookAddr, URI), 1, "initial publish should store tier id");

        _configureAllowlist(bob);

        CTPost[] memory blockedNewUri = new CTPost[](1);
        blockedNewUri[0] = CTPost({
            encodedIPFSUri: keccak256("new-uri"),
            totalSupply: 10,
            price: PRICE,
            category: 7,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(uint256(1))
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_NotInAllowList.selector, alice, _asArray(bob)));
        publisher.mintFrom{value: mintValue}(IJB721TiersHook(hookAddr), blockedNewUri, alice, alice, "", "");

        JB721Tier memory existingTier = JB721Tier({
            id: 1,
            price: PRICE,
            remainingSupply: 9,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: URI,
            category: 7,
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
            abi.encode(existingTier)
        );

        vm.prank(alice);
        publisher.mintFrom{value: mintValue}(IJB721TiersHook(hookAddr), initialPosts, alice, alice, "", "");
    }

    function _configureAllowlist(address allowedPoster) internal {
        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 7,
            minimumPrice: PRICE,
            minimumTotalSupply: 1,
            maximumTotalSupply: 10,
            maximumSplitPercent: 0,
            allowedAddresses: _asArray(allowedPoster)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(allowedPosts);
    }

    function _singlePost() internal pure returns (CTPost[] memory posts) {
        posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: URI, totalSupply: 10, price: PRICE, category: 7, splitPercent: 0, splits: new JBSplit[](0)
        });
    }

    function _asArray(address addr) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = addr;
    }
}
