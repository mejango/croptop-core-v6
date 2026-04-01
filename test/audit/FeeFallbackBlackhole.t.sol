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
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

contract BlackholeMockPermissions is IJBPermissions {
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

contract BlackholeMockStore {
    function maxTierIdOf(address) external pure returns (uint256) {
        return 0;
    }

    function isTierRemoved(address, uint256) external pure returns (bool) {
        return false;
    }

    function tierOf(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        return tier;
    }
}

contract BlackholeMockHook {
    uint256 public immutable PROJECT_ID;
    IJB721TiersHookStore public immutable STORE;
    address public immutable OWNER;

    constructor(uint256 projectId, IJB721TiersHookStore store_, address owner_) {
        PROJECT_ID = projectId;
        STORE = store_;
        OWNER = owner_;
    }

    function adjustTiers(JB721TierConfig[] calldata, uint256[] calldata) external {}

    function METADATA_ID_TARGET() external view returns (address) {
        return address(this);
    }

    function owner() external view returns (address) {
        return OWNER;
    }
}

contract AcceptingProjectTerminal {
    uint256 public totalReceived;

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        totalReceived += msg.value;
        return 0;
    }
}

contract RevertingFeeTerminal {
    error FeeTerminalDown();

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        revert FeeTerminalDown();
    }
}

contract BlackholeDirectory {
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

contract RejectingFeeBeneficiary {
    receive() external payable {
        revert("no fee");
    }
}

contract RejectingMintCaller {
    function execute(
        CTPublisher publisher,
        IJB721TiersHook hook,
        CTPost[] memory posts,
        address nftBeneficiary,
        address feeBeneficiary
    )
        external
        payable
    {
        publisher.mintFrom{value: msg.value}(hook, posts, nftBeneficiary, feeBeneficiary, bytes(""), bytes(""));
    }

    receive() external payable {
        revert("no refund");
    }
}

contract FeeFallbackBlackholeTest is Test {
    BlackholeMockPermissions permissions;
    BlackholeDirectory directory;
    BlackholeMockStore store;
    BlackholeMockHook hook;
    AcceptingProjectTerminal projectTerminal;
    RevertingFeeTerminal feeTerminal;
    RejectingFeeBeneficiary feeBeneficiary;
    RejectingMintCaller caller;
    CTPublisher publisher;

    function setUp() public {
        permissions = new BlackholeMockPermissions();
        directory = new BlackholeDirectory();
        store = new BlackholeMockStore();
        hook = new BlackholeMockHook(2, IJB721TiersHookStore(address(store)), address(this));
        projectTerminal = new AcceptingProjectTerminal();
        feeTerminal = new RevertingFeeTerminal();
        feeBeneficiary = new RejectingFeeBeneficiary();
        caller = new RejectingMintCaller();
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

        vm.deal(address(caller), 105);
    }

    function test_feePaymentFailure_revertsInsteadOfBlackholingFunds() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("post"),
            totalSupply: 1,
            price: 100,
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(address(caller));
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_FeePaymentFailed.selector, 5));
        caller.execute{value: 105}(
            publisher, IJB721TiersHook(address(hook)), posts, address(this), address(feeBeneficiary)
        );

        assertEq(projectTerminal.totalReceived(), 0, "main project payment should roll back with the fee failure");
        assertEq(address(feeTerminal).balance, 0, "fee terminal should receive nothing after reverting");
        assertEq(address(feeBeneficiary).balance, 0, "fee beneficiary should receive nothing");
        assertEq(address(caller).balance, 105, "caller should retain funds when the mint reverts");
        assertEq(address(publisher).balance, 0, "publisher should not retain trapped fees");
    }
}
