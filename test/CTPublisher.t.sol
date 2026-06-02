// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "@uniswap/permit2/test/utils/DeployPermit2.sol";

import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {CTPublisher} from "../src/CTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";
import {CTPost} from "../src/structs/CTPost.sol";

contract MockCroptopERC20 {
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

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

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockCroptopReentrantERC20 is MockCroptopERC20 {
    CTPublisher public publisher;
    IJB721TiersHook public hook;
    bool public reenter;

    function configureReentry(CTPublisher publisher_, IJB721TiersHook hook_) external {
        publisher = publisher_;
        hook = hook_;
        reenter = true;

        balanceOf[address(this)] = type(uint256).max;
        allowance[address(this)][address(publisher_)] = type(uint256).max;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (reenter) {
            reenter = false;

            CTPost[] memory posts = new CTPost[](1);
            posts[0] = CTPost({
                encodedIpfsUri: keccak256("reentrant-token-transfer"),
                totalSupply: 1,
                price: 1,
                category: 1,
                splitPercent: 0,
                splits: new JBSplit[](0)
            });

            publisher.mintFrom(hook, posts, address(this), 1, from, from, "", 0);
        }

        return super.transferFrom({from: from, to: to, amount: amount});
    }
}

contract MockCroptopHookStore {
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

contract MockCroptopPrices {
    uint256 public price;

    function pricePerUnitOf(uint256, uint256, uint256, uint256) external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

contract MockCroptopTerminal {
    mapping(address token => JBAccountingContext context) public contextForToken;

    MockCroptopHookStore public store;

    address public hook;
    uint256 public mintCount;

    function configure(MockCroptopHookStore store_, address hook_, uint256 mintCount_) external {
        store = store_;
        hook = hook_;
        mintCount = mintCount_;
    }

    function accountingContextForTokenOf(uint256, address token) external view returns (JBAccountingContext memory) {
        return contextForToken[token];
    }

    function pay(
        uint256,
        address token,
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
        if (token != JBConstants.NATIVE_TOKEN) {
            IERC20(token).transferFrom({from: msg.sender, to: address(this), value: amount});
        }
        if (mintCount != 0) store.mint({hook: hook, owner: beneficiary, count: mintCount});
        return 0;
    }

    function setAccountingContext(address token, uint8 decimals, uint32 currency) external {
        contextForToken[token] = JBAccountingContext({token: token, decimals: decimals, currency: currency});
    }
}

/// @notice Unit tests for CTPublisher.
contract TestCTPublisher is Test, DeployPermit2 {
    IPermit2 public constant _PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    bytes32 public constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 public constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr;
    address poster = makeAddr("poster");
    address unauthorized = makeAddr("unauthorized");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    MockCroptopHookStore hookStore;
    MockCroptopTerminal terminal;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, _PERMIT2, address(0));

        hookStore = new MockCroptopHookStore();
        hookStoreAddr = address(hookStore);
        terminal = new MockCroptopTerminal();

        // Mock hook.owner() for permission checks.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));

        // Mock hook.projectId() for permission checks.
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
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_ZeroTotalSupply.selector, hookAddr, 1));
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

    function test_configureAllowsZeroMaxSupplyAsUnlimited() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 100,
            maximumTotalSupply: 0,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (, uint256 minSupply, uint256 maxSupply,,) = publisher.allowanceFor(hookAddr, 1);
        assertEq(minSupply, 100, "minimum supply should be stored");
        assertEq(maxSupply, 0, "zero max should mean unlimited");
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
    // --- tierIdForEncodedIpfsUriOf ------------------------------------- //
    //*********************************************************************//

    function test_tierIdForEncodedIpfsUriOf_returnsZeroByDefault() public {
        bytes32 uri = keccak256("test");
        assertEq(publisher.tierIdForEncodedIpfsUriOf(hookAddr, uri), 0);
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
        hookStore.setMaxTierId(0);
        terminal.configure({store_: hookStore, hook_: hookAddr, mintCount_: 100});
        terminal.setAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        // METADATA_ID_TARGET() selector.
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );
    }

    function test_mintFrom_splitPercentExceedsLimit_reverts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("greedy-split"),
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
        publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        );
    }

    function test_mintFrom_splitPercentExactlyAtLimit_succeeds() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("exact-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 500_000_000, // Exactly at 50% limit.
            splits: new JBSplit[](0)
        });

        // Should pass validation. May revert downstream in mock, but NOT with split percent error.
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        ) {}
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
            encodedIpfsUri: keccak256("no-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // splitPercent=0 should always be allowed (0 <= 0).
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        ) {}
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
            encodedIpfsUri: keccak256("sneaky-split"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 1, // Even 1 should fail when disabled.
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_SplitPercentExceedsMaximum.selector, 1, 0));
        publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        );
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
            encodedIpfsUri: keccak256("split-content"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 250_000_000, // 25% within 50% limit.
            splits: splits
        });

        // Should pass split validation.
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        ) {}
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

    function test_mintFrom_zeroMaxSupplyAllowsAnyUint32Supply() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 0, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("unbounded-supply"),
            totalSupply: type(uint32).max,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        );
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
            encodedIpfsUri: keccak256(abi.encode("fuzz", postSplitPercent)),
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
            publisher.mintFrom{value: 0.02 ether}(
                IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.02 ether, poster, poster, "", 0
            );
        } else {
            vm.prank(poster);
            try publisher.mintFrom{value: 0.02 ether}(
                IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.02 ether, poster, poster, "", 0
            ) {}
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
            encodedIpfsUri: keccak256("fee-test"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Fee = 1 ether / 20 = 0.05 ether. Total needed = 1.05 ether.
        // Send only 0.04 ether: less than the fee.
        uint256 fee = 1 ether / 20;
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(CTPublisher.CTPublisher_InsufficientEthSent.selector, 1 ether + fee, 0.04 ether)
        );
        publisher.mintFrom{value: 0.04 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.04 ether, poster, poster, "", 0
        );
    }

    function test_mintFrom_exactPriceNoFee_reverts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("exact-price"),
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
        publisher.mintFrom{value: 1 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 1 ether, poster, poster, "", 0
        );
    }

    function test_mintFrom_exactPricePlusFee_succeeds() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("exact-fee"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Send exactly 1.05 ether (price + fee). Should not revert with InsufficientEthSent.
        uint256 fee = 1 ether / 20;
        vm.prank(poster);
        try publisher.mintFrom{value: 1 ether + fee}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 1 ether + fee, poster, poster, "", 0
        ) {}
        catch (bytes memory reason) {
            assertTrue(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(reason) != CTPublisher.CTPublisher_InsufficientEthSent.selector,
                "should not revert with InsufficientEthSent"
            );
        }
        assertEq(publisher.totalFeeVolume(), 0, "zero referral should not credit referrals");
    }

    function test_mintFrom_referralCreditTracksCpnFee() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("referral-fee"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 fee = 1 ether / 20;
        uint256 referralProjectId = 7;

        vm.prank(poster);
        publisher.mintFrom{value: 1 ether + fee}(
            IJB721TiersHook(hookAddr),
            posts,
            JBConstants.NATIVE_TOKEN,
            1 ether + fee,
            poster,
            poster,
            "",
            referralProjectId
        );

        assertEq(publisher.feeVolumeByReferralOf(block.chainid, referralProjectId), fee, "referral fee volume");
        assertEq(publisher.totalFeeVolume(), fee, "total fee volume");
    }

    function test_mintFrom_referralCreditSupportsPackedCrossChainProjectId() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("cross-chain-referral-fee"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 fee = 1 ether / 20;
        uint256 referralChainId = 42_161;
        uint256 referralProjectId = 9;
        uint256 packedReferralProjectId = (referralChainId << 48) | referralProjectId;

        vm.prank(poster);
        publisher.mintFrom{value: 1 ether + fee}(
            IJB721TiersHook(hookAddr),
            posts,
            JBConstants.NATIVE_TOKEN,
            1 ether + fee,
            poster,
            poster,
            "",
            packedReferralProjectId
        );

        assertEq(publisher.feeVolumeByReferralOf(referralChainId, referralProjectId), fee, "packed referral volume");
        assertEq(publisher.feeVolumeByReferralOf(block.chainid, referralProjectId), 0, "no current-chain credit");
        assertEq(publisher.totalFeeVolume(), fee, "total fee volume");
    }

    function test_mintFrom_referralCreditNormalizesErc20CpnFee() public {
        _configureCategoryWithSplits(5, 1_000_000, 1, 100, 0);
        _setupMintMocks();
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.USD), uint256(6))
        );

        MockCroptopERC20 token = new MockCroptopERC20();
        token.mint(poster, 1_050_000);
        terminal.setAccountingContext({token: address(token), decimals: 6, currency: JBCurrencyIds.USD});

        MockCroptopPrices prices = new MockCroptopPrices();
        prices.setPrice(2e3 ether);
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.PRICES.selector), abi.encode(address(prices)));

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("erc20-referral-fee"),
            totalSupply: 10,
            price: 1_000_000,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 referralProjectId = 7;

        vm.prank(poster);
        token.approve(address(publisher), 1_050_000);

        vm.prank(poster);
        publisher.mintFrom(
            IJB721TiersHook(hookAddr), posts, address(token), 1_050_000, poster, poster, "", referralProjectId
        );

        assertEq(
            publisher.feeVolumeByReferralOf(block.chainid, referralProjectId),
            25_000_000_000_000,
            "normalized referral fee volume"
        );
        assertEq(publisher.totalFeeVolume(), 25_000_000_000_000, "total fee volume");
    }

    function test_mintFrom_feeProject_noFeeDeducted() public {
        // Configure a category on a hook whose PROJECT_ID == FEE_PROJECT_ID (1).
        address feeHook = makeAddr("feeHook");
        vm.mockCall(feeHook, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        vm.mockCall(feeHook, abi.encodeWithSelector(IJB721Hook.projectId.selector), abi.encode(feeProjectId));
        vm.mockCall(feeHook, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(address(hookStore)));
        vm.mockCall(
            feeHook,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.ETH), uint256(18))
        );
        hookStore.setMaxTierId(0);
        terminal.configure({store_: hookStore, hook_: feeHook, mintCount_: 100});
        terminal.setAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        vm.mockCall(feeHook, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(feeHook, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

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
            encodedIpfsUri: keccak256("fee-project-post"),
            totalSupply: 10,
            price: 1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Send exactly the price with no fee. Should not revert with InsufficientEthSent.
        vm.prank(poster);
        try publisher.mintFrom{value: 1 ether}(
            IJB721TiersHook(feeHook), posts, JBConstants.NATIVE_TOKEN, 1 ether, poster, poster, "", 0
        ) {}
        catch (bytes memory reason) {
            assertTrue(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(reason) != CTPublisher.CTPublisher_InsufficientEthSent.selector,
                "fee project should not charge fee"
            );
        }
    }

    function test_mintFrom_revertsWhenPriceFeedReturnsZeroForDifferentCurrency() public {
        _configureCategoryWithSplits(5, 1_000_000, 1, 100, 0);
        _setupMintMocks();
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.USD), uint256(6))
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("usd-priced"),
            totalSupply: 10,
            price: 1_000_000,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        MockCroptopPrices prices = new MockCroptopPrices();
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.PRICES.selector), abi.encode(address(prices)));

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTPublisher.CTPublisher_PriceFeedUnavailable.selector,
                uint256(JBCurrencyIds.ETH),
                uint256(JBCurrencyIds.USD)
            )
        );
        publisher.mintFrom{value: 1 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 1 ether, poster, poster, "", 0
        );
    }

    function test_mintFrom_supportsErc20PaymentConvertedFromPricingContext() public {
        _configureCategoryWithSplits(5, 1_000_000, 1, 100, 0);
        _setupMintMocks();
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.USD), uint256(6))
        );

        MockCroptopERC20 token = new MockCroptopERC20();
        uint256 convertedPrice = 5e14;
        uint256 convertedFee = convertedPrice / 20;
        token.mint(poster, convertedPrice + convertedFee);
        terminal.setAccountingContext({token: address(token), decimals: 18, currency: JBCurrencyIds.ETH});

        MockCroptopPrices prices = new MockCroptopPrices();
        prices.setPrice(convertedPrice);
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.PRICES.selector), abi.encode(address(prices)));

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("usd-token-converted"),
            totalSupply: 10,
            price: 1_000_000,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        token.approve(address(publisher), convertedPrice + convertedFee);

        vm.prank(poster);
        publisher.mintFrom(
            IJB721TiersHook(hookAddr), posts, address(token), convertedPrice + convertedFee, poster, poster, "", 0
        );

        assertEq(
            token.balanceOf(address(terminal)), convertedPrice + convertedFee, "terminal should receive converted value"
        );
    }

    function test_mintFrom_supportsErc20PricingContext() public {
        _configureCategoryWithSplits(5, 1_000_000, 1, 100, 0);
        _setupMintMocks();
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.USD), uint256(6))
        );

        MockCroptopERC20 token = new MockCroptopERC20();
        token.mint(poster, 1_050_000);
        terminal.setAccountingContext({token: address(token), decimals: 6, currency: JBCurrencyIds.USD});

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("usd-token"),
            totalSupply: 10,
            price: 1_000_000,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        token.approve(address(publisher), 1_050_000);

        vm.prank(poster);
        publisher.mintFrom(IJB721TiersHook(hookAddr), posts, address(token), 1_050_000, poster, poster, "", 0);

        assertEq(token.balanceOf(address(terminal)), 1_050_000, "terminal should receive price plus fee");
        assertEq(token.allowance(address(publisher), address(terminal)), 0, "temporary allowance consumed");
    }

    function test_mintFrom_revertsOnReentrantTokenTransfer() public {
        MockCroptopReentrantERC20 token = new MockCroptopReentrantERC20();
        token.configureReentry({publisher_: publisher, hook_: IJB721TiersHook(hookAddr)});
        token.mint(poster, 1 ether);

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("outer-token-transfer"),
            totalSupply: 10,
            price: 1,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        token.approve(address(publisher), 1 ether);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_ReentrantTokenTransfer.selector, address(token)));
        publisher.mintFrom(IJB721TiersHook(hookAddr), posts, address(token), 1 ether, poster, poster, "", 0);
    }

    function test_mintFrom_refundsErc20FeeWhenFeeTerminalMissing() public {
        _configureCategoryWithSplits(5, 1_000_000, 1, 100, 0);
        hookStore.setMaxTierId(0);
        terminal.configure({store_: hookStore, hook_: hookAddr, mintCount_: 100});

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.USD), uint256(6))
        );

        MockCroptopERC20 token = new MockCroptopERC20();
        uint256 price = 1_000_000;
        uint256 fee = price / 20;
        token.mint(poster, price + fee);
        terminal.setAccountingContext({token: address(token), decimals: 6, currency: JBCurrencyIds.USD});

        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, hookProjectId, address(token)),
            abi.encode(address(terminal))
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, feeProjectId, address(token)),
            abi.encode(address(0))
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("missing-fee-terminal"),
            totalSupply: 10,
            price: uint104(price),
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        token.approve(address(publisher), price + fee);

        vm.prank(poster);
        publisher.mintFrom(IJB721TiersHook(hookAddr), posts, address(token), price + fee, poster, poster, "", 0);

        assertEq(token.balanceOf(address(terminal)), price, "project terminal should receive price only");
        assertEq(token.balanceOf(poster), fee, "fee should be refunded");
        assertEq(token.balanceOf(address(publisher)), 0, "publisher should not retain fee");
    }

    function test_mintFrom_supportsErc20Permit2Payment() public {
        deployPermit2();

        _configureCategoryWithSplits(5, 1_000_000, 1, 100, 0);
        _setupMintMocks();
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            abi.encode(uint256(JBCurrencyIds.USD), uint256(6))
        );

        uint256 permitPosterKey = 0xB0B;
        address permitPoster = vm.addr(permitPosterKey);
        uint256 totalAmount = 1_050_000;

        MockCroptopERC20 token = new MockCroptopERC20();
        token.mint(permitPoster, totalAmount);
        terminal.setAccountingContext({token: address(token), decimals: 6, currency: JBCurrencyIds.USD});

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("permit2-token"),
            totalSupply: 10,
            price: 1_000_000,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        address permit2 = address(publisher.PERMIT2());
        vm.prank(permitPoster);
        token.approve(permit2, totalAmount);

        JBSingleAllowance memory permit2Allowance =
            _permit2AllowanceFor({token: address(token), amount: totalAmount, privateKey: permitPosterKey});
        bytes memory permit2Metadata = _permit2MetadataFor(permit2Allowance);

        vm.prank(permitPoster);
        publisher.mintFrom(
            IJB721TiersHook(hookAddr),
            posts,
            address(token),
            totalAmount,
            permitPoster,
            permitPoster,
            permit2Metadata,
            0
        );

        assertEq(token.allowance(permitPoster, address(publisher)), 0, "publisher should not need ERC-20 approval");
        assertEq(token.balanceOf(address(terminal)), totalAmount, "terminal should receive permit-paid tokens");
    }

    function test_mintFrom_supportsNativeTokenPricingAlias() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();
        terminal.setAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJB721TiersHook.pricingContext.selector),
            // forge-lint: disable-next-line(unsafe-typecast)
            abi.encode(uint256(uint32(uint160(JBConstants.NATIVE_TOKEN))), uint256(18))
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("native-priced"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 fee = 0.1 ether / 20;
        vm.prank(poster);
        publisher.mintFrom{value: 0.1 ether + fee}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.1 ether + fee, poster, poster, "", 0
        );
    }

    function test_mintFrom_supportsNativeTokenAccountingAliasWithEthPricing() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();
        terminal.setAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("native-alias-eth-priced"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 fee = 0.1 ether / 20;
        vm.prank(poster);
        publisher.mintFrom{value: 0.1 ether + fee}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.1 ether + fee, poster, poster, "", 0
        );
    }

    function _permit2AllowanceFor(
        address token,
        uint256 amount,
        uint256 privateKey
    )
        internal
        view
        returns (JBSingleAllowance memory permit2Allowance)
    {
        uint256 deadline = block.timestamp + 1 days;
        uint48 expiration = uint48(block.timestamp + 2 days);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: token,
                // forge-lint: disable-next-line(unsafe-typecast)
                amount: uint160(amount),
                expiration: expiration,
                nonce: 0
            }),
            spender: address(publisher),
            sigDeadline: deadline
        });

        bytes32 permitHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permitSingle.details));
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                publisher.PERMIT2().DOMAIN_SEPARATOR(),
                keccak256(abi.encode(_PERMIT_SINGLE_TYPEHASH, permitHash, permitSingle.spender, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        permit2Allowance = JBSingleAllowance({
            sigDeadline: deadline,
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(amount),
            expiration: expiration,
            nonce: 0,
            signature: bytes.concat(r, s, bytes1(v))
        });
    }

    function _permit2MetadataFor(JBSingleAllowance memory permit2Allowance) internal view returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        bytes[] memory datas = new bytes[](1);

        ids[0] = JBMetadataResolver.getId({purpose: "permit2", target: address(publisher)});
        datas[0] = abi.encode(permit2Allowance);

        return JBMetadataResolver.createMetadata({ids: ids, datas: datas});
    }

    function test_mintFrom_revertsWhenPaymentDoesNotMintRequestedNfts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();
        terminal.configure({store_: hookStore, hook_: hookAddr, mintCount_: 0});

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("no-delivery"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint256 fee = 0.1 ether / 20;
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(CTPublisher.CTPublisher_MintNotDelivered.selector, hookAddr, poster, 1, 0)
        );
        publisher.mintFrom{value: 0.1 ether + fee}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.1 ether + fee, poster, poster, "", 0
        );
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
            encodedIpfsUri: keccak256("split-beneficiary-test"),
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
            encodedIpfsUri: keccak256("split-beneficiary-test"),
            category: 5,
            discountPercent: 0,
            flags: JB721TierConfigFlags({
                allowOwnerMint: false,
                useReserveBeneficiaryAsDefault: false,
                transfersPausable: false,
                useVotingUnits: true,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
            splitPercent: 250_000_000,
            splits: splits
        });

        // Verify adjustTiers receives the tier config with the correct split beneficiary and percent.
        vm.expectCall(
            hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector, expectedTiers, new uint256[](0))
        );

        uint256 fee = 0.1 ether / 20;
        vm.prank(poster);
        publisher.mintFrom{value: 0.1 ether + fee}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.1 ether + fee, poster, poster, "", 0
        );
    }

    function test_mintFrom_multiplePostsDifferentSplits() public {
        // Category 5 allows up to 50% splits.
        _configureCategoryWithSplits(5, 0, 1, 100, 500_000_000);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](2);
        // First post: 25% split (within limit).
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("post-1"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 250_000_000,
            splits: new JBSplit[](0)
        });
        // Second post: 60% split (exceeds limit).
        posts[1] = CTPost({
            encodedIpfsUri: keccak256("post-2"),
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
        publisher.mintFrom{value: 0.4 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.4 ether, poster, poster, "", 0
        );
    }

    function test_mintFrom_sortsNewTiersByCategoryAndPreservesMintOrder() public {
        _configureCategoryWithSplits(1, 0, 1, 100, 0);
        _configureCategoryWithSplits(2, 0, 1, 100, 0);
        _setupMintMocks();

        bytes32 categoryTwoUri = keccak256("category-two");
        bytes32 categoryOneUri = keccak256("category-one");

        CTPost[] memory posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIpfsUri: categoryTwoUri,
            totalSupply: 10,
            price: 0.1 ether,
            category: 2,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIpfsUri: categoryOneUri,
            totalSupply: 10,
            price: 0.1 ether,
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        JB721TierConfig[] memory expectedTiers = new JB721TierConfig[](2);
        expectedTiers[0] = _expectedTierConfig({encodedIpfsUri: categoryOneUri, category: 1});
        expectedTiers[1] = _expectedTierConfig({encodedIpfsUri: categoryTwoUri, category: 2});

        vm.expectCall(
            hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector, expectedTiers, new uint256[](0))
        );

        uint256[] memory expectedTierIdsToMint = new uint256[](2);
        expectedTierIdsToMint[0] = 2;
        expectedTierIdsToMint[1] = 1;

        bytes memory expectedMetadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId({purpose: "pay", target: address(0)}),
            dataToAdd: abi.encode(true, expectedTierIdsToMint)
        });
        uint256 feeProjectIdForMetadata = feeProjectId;
        assembly {
            mstore(add(expectedMetadata, 32), feeProjectIdForMetadata)
        }

        vm.expectCall(
            address(terminal),
            0.2 ether,
            abi.encodeWithSelector(
                IJBTerminal.pay.selector,
                hookProjectId,
                JBConstants.NATIVE_TOKEN,
                0.2 ether,
                poster,
                0,
                "Minted from Croptop",
                expectedMetadata
            )
        );

        vm.prank(poster);
        publisher.mintFrom{value: 0.21 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.21 ether, poster, poster, "", 0
        );

        assertEq(publisher.tierIdForEncodedIpfsUriOf(hookAddr, categoryOneUri), 1);
        assertEq(publisher.tierIdForEncodedIpfsUriOf(hookAddr, categoryTwoUri), 2);
    }

    //*********************************************************************//
    // --- Fee Beneficiary Validation ------------------------------------ //
    //*********************************************************************//

    function test_mintFrom_zeroFeeBeneficiary_reverts() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("fee-beneficiary-zero"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_InvalidFeeBeneficiary.selector));
        publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, address(0), "", 0
        );
    }

    function test_mintFrom_nonzeroFeeBeneficiary_passesValidation() public {
        _configureCategoryWithSplits(5, 0.01 ether, 1, 100, 0);
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: keccak256("fee-beneficiary-valid"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Should pass the feeBeneficiary check. May revert downstream in mocks, but NOT with
        // InvalidFeeBeneficiary.
        vm.prank(poster);
        try publisher.mintFrom{value: 0.2 ether}(
            IJB721TiersHook(hookAddr), posts, JBConstants.NATIVE_TOKEN, 0.2 ether, poster, poster, "", 0
        ) {}
        catch (bytes memory reason) {
            assertTrue(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(reason) != CTPublisher.CTPublisher_InvalidFeeBeneficiary.selector,
                "should not revert with InvalidFeeBeneficiary"
            );
        }
    }

    function _expectedTierConfig(
        bytes32 encodedIpfsUri,
        uint24 category
    )
        internal
        pure
        returns (JB721TierConfig memory tier)
    {
        tier = JB721TierConfig({
            price: 0.1 ether,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: encodedIpfsUri,
            category: category,
            discountPercent: 0,
            flags: JB721TierConfigFlags({
                allowOwnerMint: false,
                useReserveBeneficiaryAsDefault: false,
                transfersPausable: false,
                useVotingUnits: true,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }
}
