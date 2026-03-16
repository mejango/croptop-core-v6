// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {CTDeployer} from "../src/CTDeployer.sol";
import {CTPublisher} from "../src/CTPublisher.sol";
import {ICTPublisher} from "../src/interfaces/ICTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";
import {CTPost} from "../src/structs/CTPost.sol";

// =============================================================================
// Mock: A data hook that always reverts
// =============================================================================
contract RevertingDataHook is IJBRulesetDataHook {
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        revert("DATA_HOOK_REVERTED");
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        revert("DATA_HOOK_REVERTED");
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

// Need JBRuleset import for hasMintPermissionFor
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

// =============================================================================
// Mock: A data hook that returns successfully
// =============================================================================
contract SuccessDataHook is IJBRulesetDataHook {
    uint256 public immutable TAX_RATE;

    constructor(uint256 taxRate) {
        TAX_RATE = taxRate;
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        return (TAX_RATE, context.cashOutCount, context.totalSupply, hookSpecifications);
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return (context.weight, hookSpecifications);
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title TestAuditGaps
/// @notice Tests for audit gaps: data hook proxy failures, sucker impersonation, and allowlist gas scaling.
contract TestAuditGaps is Test {
    CTDeployer deployer;
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address terminalAddr = makeAddr("terminal");
    address poster = makeAddr("poster");
    address unauthorized = makeAddr("unauthorized");
    address fakeSucker = makeAddr("fakeSucker");
    address realSucker = makeAddr("realSucker");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    RevertingDataHook revertingHook;
    SuccessDataHook successHook;

    function setUp() public {
        // Mock permissions for the CTDeployer constructor (it calls setPermissionsFor twice).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        // Mock permissions.hasPermission to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Deploy the publisher.
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        // Deploy the CTDeployer.
        deployer = new CTDeployer(
            permissions, projects, hookDeployer, ICTPublisher(address(publisher)), suckerRegistry, address(0)
        );

        // Deploy mock data hooks.
        revertingHook = new RevertingDataHook();
        successHook = new SuccessDataHook(5000); // 50% tax rate

        // Mock sucker registry: non-sucker addresses return false by default.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        // Mock hook basics.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(hookProjectId));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));

        // Fund test accounts.
        vm.deal(poster, 100 ether);
        vm.deal(unauthorized, 100 ether);
    }

    // =========================================================================
    // SECTION 1: Data Hook Proxy Failure Tests
    // =========================================================================

    /// @notice Helper to build a minimal JBBeforeCashOutRecordedContext.
    function _buildCashOutContext(
        uint256 projectId,
        address holder,
        uint256 cashOutCount,
        uint256 totalSupply
    )
        internal
        pure
        returns (JBBeforeCashOutRecordedContext memory)
    {
        return JBBeforeCashOutRecordedContext({
            terminal: address(0),
            holder: holder,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            surplus: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 1 ether}),
            useTotalSurplus: false,
            cashOutTaxRate: 10_000,
            metadata: ""
        });
    }

    /// @notice Helper to build a minimal JBBeforePayRecordedContext.
    function _buildPayContext(uint256 projectId) internal pure returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: address(0),
            payer: address(0),
            amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 1 ether}),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: address(0),
            weight: 1_000_000 * 1e18,
            reservedPercent: 0,
            metadata: ""
        });
    }

    /// @notice When the underlying data hook reverts, beforeCashOutRecordedWith should bubble up the revert.
    function test_dataHookProxy_cashOut_revertsWhenDataHookReverts() public {
        // Set the data hook for project to revertingHook.
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(revertingHook)));

        // Non-sucker caller, so it will forward to the data hook.
        JBBeforeCashOutRecordedContext memory context =
            _buildCashOutContext(hookProjectId, unauthorized, 100e18, 1000e18);

        vm.expectRevert("DATA_HOOK_REVERTED");
        deployer.beforeCashOutRecordedWith(context);
    }

    /// @notice When the underlying data hook reverts, beforePayRecordedWith should bubble up the revert.
    function test_dataHookProxy_pay_revertsWhenDataHookReverts() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(revertingHook)));

        JBBeforePayRecordedContext memory context = _buildPayContext(hookProjectId);

        vm.expectRevert("DATA_HOOK_REVERTED");
        deployer.beforePayRecordedWith(context);
    }

    /// @notice When the data hook is not set (address(0)), calling beforeCashOutRecordedWith should revert.
    function test_dataHookProxy_cashOut_revertsWhenNoDataHookSet() public {
        // dataHookOf[999] is address(0) by default (never set).
        JBBeforeCashOutRecordedContext memory context = _buildCashOutContext(999, unauthorized, 100e18, 1000e18);

        // Calling a function on address(0) will revert.
        vm.expectRevert();
        deployer.beforeCashOutRecordedWith(context);
    }

    /// @notice When the data hook is not set (address(0)), calling beforePayRecordedWith should revert.
    function test_dataHookProxy_pay_revertsWhenNoDataHookSet() public {
        JBBeforePayRecordedContext memory context = _buildPayContext(999);

        vm.expectRevert();
        deployer.beforePayRecordedWith(context);
    }

    /// @notice When the data hook is set and works, the proxy should forward correctly for cash outs.
    function test_dataHookProxy_cashOut_forwardsToSuccessfulDataHook() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(successHook)));

        JBBeforeCashOutRecordedContext memory context =
            _buildCashOutContext(hookProjectId, unauthorized, 100e18, 1000e18);

        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);

        assertEq(taxRate, 5000, "tax rate should be forwarded from data hook");
        assertEq(cashOutCount, 100e18, "cashOutCount should be forwarded");
        assertEq(totalSupply, 1000e18, "totalSupply should be forwarded");
    }

    /// @notice When the data hook is set and works, the proxy should forward correctly for payments.
    function test_dataHookProxy_pay_forwardsToSuccessfulDataHook() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(successHook)));

        JBBeforePayRecordedContext memory context = _buildPayContext(hookProjectId);

        (uint256 weight,) = deployer.beforePayRecordedWith(context);

        assertEq(weight, 1_000_000 * 1e18, "weight should be forwarded from data hook");
    }

    /// @notice Sucker addresses bypass the data hook proxy entirely for cash outs with 0% tax.
    ///         Even if the underlying data hook would revert, the sucker path should succeed.
    function test_dataHookProxy_cashOut_suckerBypassesRevertingDataHook() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(revertingHook)));

        // Mark realSucker as a valid sucker for this project.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, hookProjectId, realSucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory context = _buildCashOutContext(hookProjectId, realSucker, 100e18, 1000e18);

        // Should NOT revert because suckers bypass the data hook entirely.
        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);

        assertEq(taxRate, 0, "sucker should get 0% tax rate");
        assertEq(cashOutCount, 100e18, "cashOutCount should pass through");
        assertEq(totalSupply, 1000e18, "totalSupply should pass through");
    }

    // =========================================================================
    // SECTION 2: Sucker Impersonation Tests
    // =========================================================================

    /// @notice Non-sucker address should NOT get the 0% tax rate bypass.
    function test_suckerImpersonation_nonSuckerGetsTaxed() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(successHook)));

        // fakeSucker is NOT registered as a sucker (default mock returns false).
        JBBeforeCashOutRecordedContext memory context = _buildCashOutContext(hookProjectId, fakeSucker, 100e18, 1000e18);

        (uint256 taxRate,,,) = deployer.beforeCashOutRecordedWith(context);

        // Should get the data hook's tax rate (5000), not 0.
        assertEq(taxRate, 5000, "non-sucker should not bypass tax");
    }

    /// @notice A sucker for a DIFFERENT project should NOT get the 0% tax rate for this project.
    function test_suckerImpersonation_wrongProjectSucker() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(successHook)));

        // realSucker is registered as a sucker for project 99, not hookProjectId.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, 99, realSucker),
            abi.encode(true)
        );
        // But NOT for hookProjectId (default mock returns false).

        JBBeforeCashOutRecordedContext memory context = _buildCashOutContext(hookProjectId, realSucker, 100e18, 1000e18);

        (uint256 taxRate,,,) = deployer.beforeCashOutRecordedWith(context);

        // Should get the data hook's tax rate, not 0.
        assertEq(taxRate, 5000, "sucker from wrong project should not bypass tax");
    }

    /// @notice A registered sucker for the correct project should get 0% tax.
    function test_suckerImpersonation_validSuckerGetsZeroTax() public {
        _setDataHookForProject(hookProjectId, IJBRulesetDataHook(address(successHook)));

        // Register realSucker for the correct project.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, hookProjectId, realSucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory context = _buildCashOutContext(hookProjectId, realSucker, 100e18, 1000e18);

        (uint256 taxRate,,,) = deployer.beforeCashOutRecordedWith(context);

        assertEq(taxRate, 0, "valid sucker should get 0% tax");
    }

    /// @notice hasMintPermissionFor should only return true for valid suckers.
    function test_suckerImpersonation_mintPermission_nonSuckerDenied() public {
        JBRuleset memory ruleset;

        bool allowed = deployer.hasMintPermissionFor(hookProjectId, ruleset, fakeSucker);
        assertFalse(allowed, "non-sucker should not have mint permission");
    }

    /// @notice hasMintPermissionFor should return true for a valid sucker.
    function test_suckerImpersonation_mintPermission_validSuckerAllowed() public {
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, hookProjectId, realSucker),
            abi.encode(true)
        );

        JBRuleset memory ruleset;

        bool allowed = deployer.hasMintPermissionFor(hookProjectId, ruleset, realSucker);
        assertTrue(allowed, "valid sucker should have mint permission");
    }

    /// @notice hasMintPermissionFor should return false for a sucker registered to a different project.
    function test_suckerImpersonation_mintPermission_wrongProjectDenied() public {
        // realSucker is registered for project 99, not hookProjectId.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, 99, realSucker),
            abi.encode(true)
        );
        // Default mock for hookProjectId returns false.

        JBRuleset memory ruleset;

        bool allowed = deployer.hasMintPermissionFor(hookProjectId, ruleset, realSucker);
        assertFalse(allowed, "sucker for wrong project should not have mint permission");
    }

    // =========================================================================
    // SECTION 3: Allowlist Gas Scaling Tests
    // =========================================================================

    /// @notice Measure gas cost of configuring allowlists of various sizes.
    ///         Ensures that even at 200 addresses, configuration does not hit an unreasonable gas limit.
    function test_allowlistGas_configureScaling() public {
        uint256[] memory sizes = new uint256[](4);
        sizes[0] = 10;
        sizes[1] = 50;
        sizes[2] = 100;
        sizes[3] = 200;

        for (uint256 s; s < sizes.length; s++) {
            uint256 size = sizes[s];

            address[] memory allowlist = new address[](size);
            for (uint256 i; i < size; i++) {
                allowlist[i] = address(uint160(0x1000 + i));
            }

            CTAllowedPost[] memory posts = new CTAllowedPost[](1);
            posts[0] = CTAllowedPost({
                hook: hookAddr,
                // Use different category for each size to avoid interference.
                category: uint24(s + 1),
                minimumPrice: 0,
                minimumTotalSupply: 1,
                maximumTotalSupply: 100,
                maximumSplitPercent: 0,
                allowedAddresses: allowlist
            });

            vm.prank(hookOwner);
            uint256 gasBefore = gasleft();
            publisher.configurePostingCriteriaFor(posts);
            uint256 gasUsed = gasBefore - gasleft();

            // Verify the allowlist was stored correctly.
            (,,,, address[] memory stored) = publisher.allowanceFor(hookAddr, uint24(s + 1));
            assertEq(stored.length, size, "stored allowlist length should match");

            // Log gas for reference. We just need this to not revert (no DoS).
            // Gas should scale roughly linearly with allowlist size.
            emit log_named_uint(string(abi.encodePacked("Gas for allowlist size ", vm.toString(size))), gasUsed);
        }
    }

    /// @notice Test gas cost of _isAllowed (via mintFrom) with increasing allowlist sizes.
    ///         The allowed address is always the last one to exercise the worst-case linear scan.
    function test_allowlistGas_mintFromWorstCaseScan() public {
        _setupMintMocks();

        uint256[] memory sizes = new uint256[](3);
        sizes[0] = 10;
        sizes[1] = 50;
        sizes[2] = 100;

        uint256[] memory gasResults = new uint256[](3);

        for (uint256 s; s < sizes.length; s++) {
            uint256 size = sizes[s];

            // Build allowlist where poster is the LAST entry (worst case).
            address[] memory allowlist = new address[](size);
            for (uint256 i; i < size - 1; i++) {
                allowlist[i] = address(uint160(0x2000 + i));
            }
            allowlist[size - 1] = poster;

            CTAllowedPost[] memory posts = new CTAllowedPost[](1);
            posts[0] = CTAllowedPost({
                hook: hookAddr,
                category: uint24(10 + s),
                minimumPrice: 0,
                minimumTotalSupply: 1,
                maximumTotalSupply: 100,
                maximumSplitPercent: 0,
                allowedAddresses: allowlist
            });

            vm.prank(hookOwner);
            publisher.configurePostingCriteriaFor(posts);

            // Generate a unique IPFS URI per test case.
            bytes32 uri = keccak256(abi.encode("gas-test", s));

            CTPost[] memory mintPosts = new CTPost[](1);
            mintPosts[0] = CTPost({
                encodedIPFSUri: uri,
                totalSupply: 10,
                price: 0.01 ether,
                category: uint24(10 + s),
                splitPercent: 0,
                splits: new JBSplit[](0)
            });

            vm.prank(poster);
            uint256 gasBefore = gasleft();
            // This may revert downstream (mock terminal), but the allowlist check happens before that.
            // We use try-catch to capture the gas used for the allowlist check path.
            try publisher.mintFrom{value: 0.02 ether}(IJB721TiersHook(hookAddr), mintPosts, poster, poster, "", "") {}
                catch {}
            uint256 gasUsed = gasBefore - gasleft();

            gasResults[s] = gasUsed;
            emit log_named_uint(
                string(abi.encodePacked("Gas for mintFrom with allowlist size ", vm.toString(size))), gasUsed
            );
        }

        // Verify gas scales approximately linearly. The gas for size=100 should be less than
        // 5x the gas for size=10 (generous bound to account for fixed costs).
        // This is a sanity check, not a strict bound.
        assertTrue(gasResults[2] < gasResults[0] * 5, "gas should scale roughly linearly, not quadratically");
    }

    /// @notice Verify that an empty allowlist means everyone is allowed.
    function test_allowlistGas_emptyAllowlistAllowsEveryone() public {
        _setupMintMocks();

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 50,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0) // Empty = everyone allowed
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        CTPost[] memory mintPosts = new CTPost[](1);
        mintPosts[0] = CTPost({
            encodedIPFSUri: keccak256("anyone-can-post"),
            totalSupply: 10,
            price: 0.01 ether,
            category: 50,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Anyone (even unauthorized) should pass the allowlist check.
        // The call may revert downstream in mocked terminal calls, but NOT with NotInAllowList.
        vm.prank(unauthorized);
        try publisher.mintFrom{value: 0.02 ether}(
            IJB721TiersHook(hookAddr), mintPosts, unauthorized, unauthorized, "", ""
        ) {}
        catch (bytes memory reason) {
            // Make sure it did NOT revert with CTPublisher_NotInAllowList.
            assertTrue(
                reason.length < 4 || bytes4(reason) != CTPublisher.CTPublisher_NotInAllowList.selector,
                "empty allowlist should not restrict any address"
            );
        }
    }

    /// @notice Verify that a non-empty allowlist blocks addresses not in the list.
    function test_allowlistGas_nonEmptyAllowlistBlocksUnauthorized() public {
        _setupMintMocks();

        address[] memory allowlist = new address[](1);
        allowlist[0] = poster;

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 51,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: allowlist
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        CTPost[] memory mintPosts = new CTPost[](1);
        mintPosts[0] = CTPost({
            encodedIPFSUri: keccak256("restricted-post"),
            totalSupply: 10,
            price: 0.01 ether,
            category: 51,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        publisher.mintFrom{value: 0.02 ether}(IJB721TiersHook(hookAddr), mintPosts, unauthorized, unauthorized, "", "");
    }

    /// @notice Reconfiguring the allowlist should fully replace the old one.
    function test_allowlistGas_reconfigureReplacesOldAllowlist() public {
        // First: allowlist with poster.
        address[] memory allowlist1 = new address[](1);
        allowlist1[0] = poster;

        CTAllowedPost[] memory posts1 = new CTAllowedPost[](1);
        posts1[0] = CTAllowedPost({
            hook: hookAddr,
            category: 52,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: allowlist1
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts1);

        // Verify poster is in the allowlist.
        (,,,, address[] memory stored1) = publisher.allowanceFor(hookAddr, 52);
        assertEq(stored1.length, 1);
        assertEq(stored1[0], poster);

        // Second: replace allowlist with unauthorized only.
        address[] memory allowlist2 = new address[](1);
        allowlist2[0] = unauthorized;

        CTAllowedPost[] memory posts2 = new CTAllowedPost[](1);
        posts2[0] = CTAllowedPost({
            hook: hookAddr,
            category: 52,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: allowlist2
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts2);

        // Verify allowlist was fully replaced.
        (,,,, address[] memory stored2) = publisher.allowanceFor(hookAddr, 52);
        assertEq(stored2.length, 1, "allowlist should have 1 entry");
        assertEq(stored2[0], unauthorized, "allowlist should now contain unauthorized");
    }

    // =========================================================================
    // SECTION 4: CTDeployer interface compliance
    // =========================================================================

    /// @notice CTDeployer should correctly report ERC165 support for its interfaces.
    function test_supportsInterface() public {
        assertTrue(deployer.supportsInterface(type(IJBRulesetDataHook).interfaceId), "should support data hook");
        assertTrue(deployer.supportsInterface(type(IERC721Receiver).interfaceId), "should support ERC721Receiver");
        assertFalse(deployer.supportsInterface(bytes4(0xdeadbeef)), "should not support random interface");
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Use vm.store to set the dataHookOf mapping directly.
    ///      Mapping slot: dataHookOf is at slot determined by the contract layout.
    ///      Since we cannot easily calculate the slot for CTDeployer's mapping,
    ///      we deploy with a known data hook via the mock approach instead.
    function _setDataHookForProject(uint256 projectId, IJBRulesetDataHook hook) internal {
        // dataHookOf is the first (and only) non-immutable storage variable in CTDeployer, so it is at slot 0.
        // For mapping(uint256 => address) at slot 0, the storage slot is keccak256(abi.encode(key, slot)).
        bytes32 slot = keccak256(abi.encode(projectId, uint256(0)));
        vm.store(address(deployer), slot, bytes32(uint256(uint160(address(hook)))));
    }

    /// @dev Set up mocks for mintFrom path on the publisher.
    function _setupMintMocks() internal {
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(uint256(0))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(terminalAddr)
        );
        vm.mockCall(terminalAddr, "", abi.encode(uint256(0)));
    }
}
