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
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

contract FeeEvasionMockStore {
    mapping(address hook => mapping(address owner => uint256 balance)) public balanceOf;

    function mint(address hook, address owner, uint256 count) external {
        balanceOf[hook][owner] += count;
    }
}

contract FeeEvasionMockTerminal {
    FeeEvasionMockStore internal _store;
    address internal _hook;

    constructor(FeeEvasionMockStore store_, address hook_) {
        _store = store_;
        _hook = hook_;
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        return JBAccountingContext({token: token, decimals: 18, currency: JBCurrencyIds.ETH});
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
        _store.mint({hook: _hook, owner: beneficiary, count: 1});
        return 0;
    }
}

/// @title FeeEvasionRegression
/// @notice Fee evasion for existing tier mints.
///         Existing-tier mints must price from the stored tier, not caller-provided post.price, so the 5% Croptop fee
///         cannot be avoided with post.price = 0.
contract FeeEvasionRegression is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr;
    address terminalAddr;
    address feeTerminalAddr;
    address poster = makeAddr("poster");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    bytes32 constant TEST_URI = keccak256("existing-tier-content");
    uint104 constant TIER_PRICE = 1 ether;

    FeeEvasionMockStore hookStore;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, IPermit2(address(0)), address(0));
        hookStore = new FeeEvasionMockStore();
        hookStoreAddr = address(hookStore);
        terminalAddr = address(new FeeEvasionMockTerminal(hookStore, hookAddr));
        feeTerminalAddr = address(new FeeEvasionMockTerminal(hookStore, hookAddr));

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

    /// @notice Fee is still charged when post.price = 0 for an existing tier.
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

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: TEST_URI,
            totalSupply: 10,
            price: TIER_PRICE,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // First mint to create the tier and populate the mapping.
        vm.prank(poster);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 2 ether, poster, poster, "", 0
        );

        // Verify the mapping was set.
        assertEq(publisher.tierIdForEncodedIpfsUriOf(hookAddr, TEST_URI), 1, "tier ID should be stored");

        // Now the attack: existing tier, but attacker sets post.price = 0.
        // Update mocks for the second mint with maxTierId set to 1.
        _setupMintMocks(1);

        CTPost[] memory attackPosts = new CTPost[](1);
        attackPosts[0] = CTPost({
            encodedIpfsUri: TEST_URI,
            totalSupply: 10,
            price: 0, // Attacker tries to evade fee by setting price = 0.
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // The fee is TIER_PRICE / FEE_DIVISOR = 1 ether / 20 = 0.05 ether.
        // The project payment is TIER_PRICE - fee = 1 ether - 0.05 ether = 0.95 ether.
        // Total required: TIER_PRICE = 1 ether (project gets 0.95 ether, fee is 0.05 ether).
        // The actual tier price (1 ether) is used, so the full msg.value is needed.

        // Sending 0 ETH should revert because totalPrice is the actual tier price (1 ether),
        // not the attacker's 0.
        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0}(
            IJB721TiersHook(hookAddr), attackPosts, JBConstants.NATIVE_TOKEN, 0, poster, poster, "", 0
        );

        // Sending the correct amount should succeed.
        vm.prank(poster);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(hookAddr), attackPosts, JBConstants.NATIVE_TOKEN, 2 ether, poster, poster, "", 0
        );
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
        // First mint to create the tier.
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: TEST_URI,
            totalSupply: 10,
            price: TIER_PRICE,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 2 ether, poster, poster, "", 0
        );

        // Second mint with the existing tier. Even with post.price = 0, the fee
        // should be based on the actual price (1 ether).
        _setupMintMocks(1);

        CTPost[] memory existingPosts = new CTPost[](1);
        existingPosts[0] = CTPost({
            encodedIpfsUri: TEST_URI,
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
        publisher.mintFrom{value: 1.05 ether}(
            IJB721TiersHook(hookAddr), existingPosts, JBConstants.NATIVE_TOKEN, 1.05 ether, poster, poster, "", 0
        );

        // Sending 1.04 ether should fail (1.04 - 0.05 = 0.99 < 1 ether totalPrice).
        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 1.04 ether}(
            IJB721TiersHook(hookAddr), existingPosts, JBConstants.NATIVE_TOKEN, 1.04 ether, poster, poster, "", 0
        );
    }
}
