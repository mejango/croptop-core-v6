// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

// ── Minimal inline mocks (reuse pattern from FeeFallbackBlackhole.t.sol) ──

contract ZBMockPermissions is IJBPermissions {
    // forge-lint: disable-next-line(mixed-case-function)
    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return true;
    }

    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract ZBMockStore {
    mapping(address hook => mapping(address owner => uint256 balance)) public balanceOf;

    function maxTierIdOf(address) external pure returns (uint256) {
        return 0;
    }

    function isTierRemoved(address, uint256) external pure returns (bool) {
        return false;
    }

    function tierOf(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        return tier;
    }

    function mint(address hook, address owner, uint256 count) external {
        balanceOf[hook][owner] += count;
    }
}

contract ZBMockHook {
    uint256 public immutable PROJECT_ID;
    IJB721TiersHookStore public immutable STORE;
    address public immutable OWNER;

    constructor(uint256 projectId_, IJB721TiersHookStore store_, address owner_) {
        PROJECT_ID = projectId_;
        STORE = store_;
        OWNER = owner_;
    }

    function projectId() external view returns (uint256) {
        return PROJECT_ID;
    }

    function adjustTiers(JB721TierConfig[] calldata, uint256[] calldata) external {}

    function METADATA_ID_TARGET() external view returns (address) {
        return address(this);
    }

    function owner() external view returns (address) {
        return OWNER;
    }

    function pricingContext() external pure returns (uint256, uint256) {
        return (JBCurrencyIds.ETH, 18);
    }
}

contract ZBAcceptingTerminal {
    uint256 public totalReceived;

    ZBMockStore internal _store;
    address internal _hook;

    function configure(ZBMockStore store_, address hook_) external {
        _store = store_;
        _hook = hook_;
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
        totalReceived += msg.value;
        _store.mint({hook: _hook, owner: beneficiary, count: 1});
        return 0;
    }
}

contract ZBDirectory {
    address public projectTerminal;
    address public feeTerminal;

    function setTerminals(address projectTerminal_, address feeTerminal_) external {
        projectTerminal = projectTerminal_;
        feeTerminal = feeTerminal_;
    }

    function primaryTerminalOf(uint256 projectId, address) external view returns (IJBTerminal) {
        return IJBTerminal(projectId == 1 ? feeTerminal : projectTerminal);
    }
}

/// @notice `CTPublisher.mintFrom` must revert when `feeBeneficiary` is `address(0)`.
/// @dev Prevents fee project tokens from being minted to the zero address.
contract ZeroAddressFeeBeneficiaryTest is Test {
    ZBMockPermissions permissions;
    ZBDirectory directory;
    ZBMockStore store;
    ZBMockHook hook;
    ZBAcceptingTerminal projectTerminal;
    ZBAcceptingTerminal feeTerminal;
    CTPublisher publisher;

    function setUp() public {
        permissions = new ZBMockPermissions();
        directory = new ZBDirectory();
        store = new ZBMockStore();
        hook = new ZBMockHook(2, IJB721TiersHookStore(address(store)), address(this));
        projectTerminal = new ZBAcceptingTerminal();
        feeTerminal = new ZBAcceptingTerminal();
        projectTerminal.configure({store_: store, hook_: address(hook)});
        feeTerminal.configure({store_: store, hook_: address(hook)});
        publisher = new CTPublisher(IJBDirectory(address(directory)), permissions, 1, address(0));

        directory.setTerminals(address(projectTerminal), address(feeTerminal));

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(hook),
            category: 1,
            minimumPrice: 1,
            minimumTotalSupply: 1,
            maximumTotalSupply: type(uint32).max,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        publisher.configurePostingCriteriaFor(allowedPosts);
    }

    /// @notice Calling `mintFrom` with `address(0)` as fee beneficiary must revert.
    function test_zeroAddressFeeBeneficiary_reverts() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("post"),
            totalSupply: 1,
            price: 100,
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.deal(address(this), 105);

        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_InvalidFeeBeneficiary.selector));
        publisher.mintFrom{value: 105}(
            IJB721TiersHook(address(hook)),
            posts,
            address(this),
            address(0), // zero address fee beneficiary
            bytes("")
        );
    }

    /// @notice Calling `mintFrom` with a valid fee beneficiary should succeed.
    function test_validFeeBeneficiary_succeeds() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("post"),
            totalSupply: 1,
            price: 100,
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.deal(address(this), 105);

        publisher.mintFrom{value: 105}(
            IJB721TiersHook(address(hook)),
            posts,
            address(this),
            address(0xBEEF), // valid fee beneficiary
            bytes("")
        );

        assertEq(projectTerminal.totalReceived(), 100, "project terminal should receive the main payment");
        assertEq(feeTerminal.totalReceived(), 5, "fee terminal should receive the 5% fee");
    }

    receive() external payable {}
}
