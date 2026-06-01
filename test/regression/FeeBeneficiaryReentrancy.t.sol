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
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

contract MockPermissions is IJBPermissions {
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

contract MockStore {
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

    // Accept direct ether transfers (required alongside payable fallback to silence compiler warning 3628).
    receive() external payable {}

    fallback() external payable {}
}

contract MockHook {
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

    // Accept direct ether transfers (required alongside payable fallback to silence compiler warning 3628).
    receive() external payable {}

    fallback() external payable {}
}

contract MockDirectory {
    address public projectTerminal;
    address public feeTerminal;

    function setTerminals(address projectTerminal_, address feeTerminal_) external {
        projectTerminal = projectTerminal_;
        feeTerminal = feeTerminal_;
    }

    function primaryTerminalOf(uint256 projectId, address) external view returns (IJBTerminal) {
        return IJBTerminal(projectId == 1 ? feeTerminal : projectTerminal);
    }

    // Accept direct ether transfers (required alongside payable fallback to silence compiler warning 3628).
    receive() external payable {}

    fallback() external payable {}
}

contract FeeTerminalRecorder {
    uint256 public callCount;
    uint256 public totalReceived;
    address public lastBeneficiary;
    uint256 public lastAmount;

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        return JBAccountingContext({token: token, decimals: 18, currency: JBCurrencyIds.ETH});
    }

    function pay(
        uint256,
        address,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        callCount++;
        totalReceived += msg.value;
        lastBeneficiary = beneficiary;
        lastAmount = amount;
        return 0;
    }

    // Accept direct ether transfers (required alongside payable fallback to silence compiler warning 3628).
    receive() external payable {}

    fallback() external payable {}
}

contract ReentrantProjectTerminal {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    CTPublisher public immutable publisher;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IJB721TiersHook public immutable hook;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    MockStore public immutable store;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable attackerFeeBeneficiary;
    bool internal entered;

    constructor(CTPublisher publisher_, IJB721TiersHook hook_, MockStore store_, address attackerFeeBeneficiary_) {
        publisher = publisher_;
        hook = hook_;
        store = store_;
        attackerFeeBeneficiary = attackerFeeBeneficiary_;
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
        if (!entered) {
            entered = true;

            CTPost[] memory posts = new CTPost[](1);
            posts[0] = CTPost({
                encodedIpfsUri: keccak256("inner"),
                totalSupply: 1,
                price: 20,
                category: 1,
                splitPercent: 0,
                splits: new JBSplit[](0)
            });

            publisher.mintFrom{value: 21}(
                hook, posts, JBConstants.NATIVE_TOKEN, 21, address(this), attackerFeeBeneficiary, bytes("")
            );
        }

        store.mint({hook: address(hook), owner: beneficiary, count: 1});
        return 0;
    }

    receive() external payable {}
}

contract FeeBeneficiaryReentrancyTest is Test {
    MockPermissions permissions;
    MockDirectory directory;
    MockStore store;
    MockHook hook;
    FeeTerminalRecorder feeTerminal;
    ReentrantProjectTerminal projectTerminal;
    CTPublisher publisher;

    address victimFeeBeneficiary = makeAddr("victimFeeBeneficiary");
    address attackerFeeBeneficiary = makeAddr("attackerFeeBeneficiary");

    function setUp() public {
        permissions = new MockPermissions();
        directory = new MockDirectory();
        store = new MockStore();
        hook = new MockHook(2, IJB721TiersHookStore(address(store)), address(this));
        publisher = new CTPublisher(IJBDirectory(address(directory)), permissions, 1, IPermit2(address(0)), address(0));
        feeTerminal = new FeeTerminalRecorder();
        projectTerminal =
            new ReentrantProjectTerminal(publisher, IJB721TiersHook(address(hook)), store, attackerFeeBeneficiary);
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

    function test_reentrantInnerCallCannotStealOuterFee() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("outer"),
            totalSupply: 1,
            price: 100,
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        publisher.mintFrom{value: 105}(
            IJB721TiersHook(address(hook)),
            posts,
            JBConstants.NATIVE_TOKEN,
            105,
            address(this),
            victimFeeBeneficiary,
            bytes("")
        );

        // Fee amounts are pinned before external calls, so both inner and outer fees are paid separately with correct
        // beneficiaries.
        assertEq(feeTerminal.callCount(), 2, "both inner and outer fee payments should execute");
        assertEq(feeTerminal.totalReceived(), 6, "total fees should be inner(1) + outer(5) = 6");
        assertEq(feeTerminal.lastBeneficiary(), victimFeeBeneficiary, "outer fee should go to victim beneficiary");
        assertEq(address(publisher).balance, 0, "publisher balance should be empty after both fee payments");
    }
}
