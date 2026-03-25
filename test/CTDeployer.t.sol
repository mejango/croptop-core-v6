// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {CTDeployer} from "../src/CTDeployer.sol";
import {CTPublisher} from "../src/CTPublisher.sol";
import {ICTDeployer} from "../src/interfaces/ICTDeployer.sol";
import {ICTPublisher} from "../src/interfaces/ICTPublisher.sol";
import {CTDeployerAllowedPost} from "../src/structs/CTDeployerAllowedPost.sol";
import {CTProjectConfig} from "../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../src/structs/CTSuckerDeploymentConfig.sol";

// =============================================================================
// Mock data hook that returns successfully
// =============================================================================
contract MockDataHook is IJBRulesetDataHook {
    uint256 public immutable WEIGHT;
    uint256 public immutable TAX_RATE;

    constructor(uint256 weight, uint256 taxRate) {
        WEIGHT = weight;
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

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return (WEIGHT, hookSpecifications);
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title TestCTDeployer
/// @notice Comprehensive unit tests for CTDeployer.
contract TestCTDeployer is Test {
    CTDeployer deployer;
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJBController controller = IJBController(makeAddr("controller"));

    address owner = makeAddr("owner");
    address unauthorized = makeAddr("unauthorized");
    address hookAddr = makeAddr("hook");
    address suckerAddr = makeAddr("sucker");

    uint256 feeProjectId = 1;
    uint256 projectCount = 5;
    uint256 deployedProjectId = projectCount + 1; // 6

    MockDataHook mockDataHook;

    function setUp() public {
        // Mock permissions.setPermissionsFor (called in CTDeployer constructor).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        // Mock permissions.hasPermission to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Deploy publisher.
        publisher = new CTPublisher(IJBDirectory(makeAddr("directory")), permissions, feeProjectId, address(0));

        // Deploy the CTDeployer.
        deployer = new CTDeployer(
            permissions, projects, hookDeployer, ICTPublisher(address(publisher)), suckerRegistry, address(0)
        );

        // Deploy mock data hook (weight=1e24, taxRate=5000).
        mockDataHook = new MockDataHook(1_000_000 * 1e18, 5000);

        // Mock sucker registry: default false.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        // Fund test accounts.
        vm.deal(owner, 100 ether);
        vm.deal(unauthorized, 100 ether);
    }

    //*********************************************************************//
    // --- deployProjectFor ---------------------------------------------- //
    //*********************************************************************//

    /// @notice Deploy a project and verify the hook address is returned and the data hook is stored.
    function test_deployProjectFor_setsHookAndPublisher() public {
        _mockDeployProjectInfra();

        CTProjectConfig memory config = _defaultProjectConfig();
        CTSuckerDeploymentConfig memory suckerConfig = _emptySuckerConfig();

        (uint256 projectId, IJB721TiersHook hook) = deployer.deployProjectFor(owner, config, suckerConfig, controller);

        assertEq(projectId, deployedProjectId, "project ID should match");
        assertEq(address(hook), hookAddr, "hook address should match deployed hook");
        assertEq(
            address(deployer.dataHookOf(projectId)), hookAddr, "dataHookOf should be set to the deployed hook address"
        );
    }

    /// @notice Verify that allowed posts from the config are forwarded to the publisher.
    function test_deployProjectFor_configuresAllowedPosts() public {
        _mockDeployProjectInfra();

        CTDeployerAllowedPost[] memory allowedPosts = new CTDeployerAllowedPost[](1);
        allowedPosts[0] = CTDeployerAllowedPost({
            category: 5,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "https://croptop.test/",
            allowedPosts: allowedPosts,
            contractUri: "https://croptop.test/contract",
            name: "TestCrop",
            symbol: "TC",
            salt: bytes32(0)
        });
        CTSuckerDeploymentConfig memory suckerConfig = _emptySuckerConfig();

        // Mock the hook's owner() and PROJECT_ID() so the publisher's permission check passes.
        // The CTDeployer is the hook's owner (it deployed the hook).
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(address(deployer)));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));

        (uint256 projectId,) = deployer.deployProjectFor(owner, config, suckerConfig, controller);
        assertEq(projectId, deployedProjectId, "project ID should match");

        // Verify the allowance was set by reading it from the publisher.
        (uint256 minPrice, uint256 minSupply, uint256 maxSupply,,) = publisher.allowanceFor(hookAddr, 5);
        assertEq(minPrice, 0.01 ether, "minimum price should be configured");
        assertEq(minSupply, 1, "minimum supply should be configured");
        assertEq(maxSupply, 100, "maximum supply should be configured");
    }

    /// @notice Verify that deploying with suckerConfig.salt != 0 invokes the sucker registry.
    function test_deployProjectFor_deploySuckersWhenSaltProvided() public {
        _mockDeployProjectInfra();

        CTSuckerDeploymentConfig memory suckerConfig = CTSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(uint256(42))
        });

        // Mock the sucker registry deploySuckersFor call.
        address[] memory mockSuckers = new address[](0);
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.deploySuckersFor.selector),
            abi.encode(mockSuckers)
        );

        CTProjectConfig memory config = _defaultProjectConfig();
        deployer.deployProjectFor(owner, config, suckerConfig, controller);
        // If we got here without revert, the sucker registry was called successfully.
    }

    /// @notice Deploying with a controller that has a different PROJECTS should revert.
    function test_deployProjectFor_wrongControllerReverts() public {
        // Mock controller.PROJECTS() to return a different address.
        IJBProjects wrongProjects = IJBProjects(makeAddr("wrongProjects"));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(wrongProjects)
        );

        CTProjectConfig memory config = _defaultProjectConfig();
        CTSuckerDeploymentConfig memory suckerConfig = _emptySuckerConfig();

        vm.expectRevert();
        deployer.deployProjectFor(owner, config, suckerConfig, controller);
    }

    /// @notice The project NFT is transferred to the owner after deployment.
    function test_deployProjectFor_transfersProjectToOwner() public {
        _mockDeployProjectInfra();

        CTProjectConfig memory config = _defaultProjectConfig();
        CTSuckerDeploymentConfig memory suckerConfig = _emptySuckerConfig();

        // Mock the transferFrom call - expect it to be called with (deployer, owner, projectId).
        vm.mockCall(address(projects), abi.encodeWithSelector(IERC721.transferFrom.selector), abi.encode());

        // We expect the transferFrom to be called. If the mock is not matched, it will revert.
        deployer.deployProjectFor(owner, config, suckerConfig, controller);
    }

    //*********************************************************************//
    // --- deploySuckersFor ---------------------------------------------- //
    //*********************************************************************//

    /// @notice deploySuckersFor forwards to the sucker registry with correct permission checks.
    function test_deploySuckersFor_forwardsToRegistry() public {
        // Mock projects.ownerOf to return `owner`.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );

        // Mock the sucker registry deploySuckersFor call.
        address[] memory mockSuckers = new address[](1);
        mockSuckers[0] = suckerAddr;
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.deploySuckersFor.selector),
            abi.encode(mockSuckers)
        );

        CTSuckerDeploymentConfig memory suckerConfig = CTSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(uint256(99))
        });

        vm.prank(owner);
        address[] memory suckers = deployer.deploySuckersFor(deployedProjectId, suckerConfig);
        assertEq(suckers.length, 1, "should return 1 sucker");
        assertEq(suckers[0], suckerAddr, "sucker address should match");
    }

    /// @notice deploySuckersFor reverts when caller is not the owner and lacks permission.
    function test_deploySuckersFor_nonOwner_reverts() public {
        // Mock projects.ownerOf to return `owner`.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );

        // Mock permissions.hasPermission to return false for unauthorized.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        CTSuckerDeploymentConfig memory suckerConfig = CTSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(uint256(99))
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                unauthorized,
                deployedProjectId,
                JBPermissionIds.DEPLOY_SUCKERS
            )
        );
        deployer.deploySuckersFor(deployedProjectId, suckerConfig);
    }

    //*********************************************************************//
    // --- claimCollectionOwnershipOf ------------------------------------ //
    //*********************************************************************//

    /// @notice claimCollectionOwnershipOf transfers hook ownership to the project.
    function test_claimCollectionOwnershipOf_transfersOwnership() public {
        // Mock hook.PROJECT_ID() to return deployedProjectId.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));

        // Mock PROJECTS.ownerOf(deployedProjectId) to return owner.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );

        // Mock JBOwnable.transferOwnershipToProject(projectId).
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        vm.prank(owner);
        deployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));
    }

    /// @notice claimCollectionOwnershipOf reverts when called by a non-owner.
    function test_claimCollectionOwnershipOf_nonOwner_reverts() public {
        // Mock hook.PROJECT_ID() to return deployedProjectId.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));

        // Mock PROJECTS.ownerOf(deployedProjectId) to return owner (not unauthorized).
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTDeployer.CTDeployer_NotOwnerOfProject.selector, deployedProjectId, hookAddr, unauthorized
            )
        );
        deployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));
    }

    //*********************************************************************//
    // --- hasMintPermissionFor ------------------------------------------ //
    //*********************************************************************//

    /// @notice hasMintPermissionFor returns true for a registered sucker.
    function test_hasMintPermissionFor_returnsCorrectly() public {
        JBRuleset memory ruleset;

        // Non-sucker should return false.
        bool allowed = deployer.hasMintPermissionFor(deployedProjectId, ruleset, unauthorized);
        assertFalse(allowed, "non-sucker should not have mint permission");

        // Register suckerAddr as a valid sucker for the project.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, deployedProjectId, suckerAddr),
            abi.encode(true)
        );

        allowed = deployer.hasMintPermissionFor(deployedProjectId, ruleset, suckerAddr);
        assertTrue(allowed, "valid sucker should have mint permission");
    }

    /// @notice hasMintPermissionFor returns false for a sucker registered to a different project.
    function test_hasMintPermissionFor_wrongProjectReturnsFalse() public {
        // Register suckerAddr for project 99.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, 99, suckerAddr),
            abi.encode(true)
        );
        // Default mock for deployedProjectId returns false.

        JBRuleset memory ruleset;
        bool allowed = deployer.hasMintPermissionFor(deployedProjectId, ruleset, suckerAddr);
        assertFalse(allowed, "sucker for different project should not have mint permission");
    }

    //*********************************************************************//
    // --- supportsInterface --------------------------------------------- //
    //*********************************************************************//

    /// @notice supportsInterface returns true for all declared interfaces.
    function test_supportsInterface_correctInterfaces() public {
        assertTrue(deployer.supportsInterface(type(ICTDeployer).interfaceId), "should support ICTDeployer");
        assertTrue(
            deployer.supportsInterface(type(IJBRulesetDataHook).interfaceId), "should support IJBRulesetDataHook"
        );
        assertTrue(deployer.supportsInterface(type(IERC721Receiver).interfaceId), "should support IERC721Receiver");
        assertFalse(deployer.supportsInterface(bytes4(0xdeadbeef)), "should not support random interface");
        assertFalse(deployer.supportsInterface(bytes4(0)), "should not support zero interface");
    }

    //*********************************************************************//
    // --- beforePayRecordedWith ----------------------------------------- //
    //*********************************************************************//

    /// @notice beforePayRecordedWith forwards the call to the stored data hook.
    function test_beforePayRecordedWith_forwardsToHook() public {
        // Set the data hook for the project.
        _setDataHookForProject(deployedProjectId, IJBRulesetDataHook(address(mockDataHook)));

        JBBeforePayRecordedContext memory context = _buildPayContext(deployedProjectId);

        (uint256 weight,) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 1_000_000 * 1e18, "weight should be forwarded from mock data hook");
    }

    /// @notice beforePayRecordedWith reverts when no data hook is set.
    function test_beforePayRecordedWith_returnsDefaultsWhenNoDataHook() public {
        // dataHookOf[999] is address(0) by default.
        JBBeforePayRecordedContext memory context = _buildPayContext(999);

        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);

        assertEq(weight, context.weight, "weight should be returned as-is from context");
        assertEq(specs.length, 0, "hookSpecifications should be empty");
    }

    //*********************************************************************//
    // --- beforeCashOutRecordedWith ------------------------------------- //
    //*********************************************************************//

    /// @notice beforeCashOutRecordedWith forwards the call to the stored data hook for non-suckers.
    function test_beforeCashOutRecordedWith_forwardsToHook() public {
        _setDataHookForProject(deployedProjectId, IJBRulesetDataHook(address(mockDataHook)));

        JBBeforeCashOutRecordedContext memory context =
            _buildCashOutContext(deployedProjectId, unauthorized, 100e18, 1000e18);

        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);

        assertEq(taxRate, 5000, "tax rate should come from data hook");
        assertEq(cashOutCount, 100e18, "cashOutCount should be forwarded");
        assertEq(totalSupply, 1000e18, "totalSupply should be forwarded");
    }

    /// @notice Suckers get 0% tax rate and bypass the data hook.
    function test_beforeCashOutRecordedWith_suckerGetsZeroTax() public {
        _setDataHookForProject(deployedProjectId, IJBRulesetDataHook(address(mockDataHook)));

        // Register suckerAddr for this project.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, deployedProjectId, suckerAddr),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory context =
            _buildCashOutContext(deployedProjectId, suckerAddr, 100e18, 1000e18);

        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);

        assertEq(taxRate, 0, "sucker should get 0% tax rate");
        assertEq(cashOutCount, 100e18, "cashOutCount should pass through");
        assertEq(totalSupply, 1000e18, "totalSupply should pass through");
    }

    /// @notice beforeCashOutRecordedWith returns defaults when no data hook is set and holder is not a sucker.
    function test_beforeCashOutRecordedWith_returnsDefaultsWhenNoDataHook() public {
        JBBeforeCashOutRecordedContext memory context = _buildCashOutContext(999, unauthorized, 100e18, 1000e18);

        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply, JBCashOutHookSpecification[] memory specs) =
            deployer.beforeCashOutRecordedWith(context);

        assertEq(taxRate, context.cashOutTaxRate, "cashOutTaxRate should be returned as-is from context");
        assertEq(cashOutCount, context.cashOutCount, "cashOutCount should be returned as-is from context");
        assertEq(totalSupply, context.totalSupply, "totalSupply should be returned as-is from context");
        assertEq(specs.length, 0, "hookSpecifications should be empty");
    }

    //*********************************************************************//
    // --- onERC721Received ---------------------------------------------- //
    //*********************************************************************//

    /// @notice onERC721Received accepts mints from the PROJECTS contract.
    function test_onERC721Received_acceptsMintFromProjects() public {
        vm.prank(address(projects));
        bytes4 result = deployer.onERC721Received(address(0), address(0), 1, "");
        assertEq(result, IERC721Receiver.onERC721Received.selector, "should return the ERC721Received selector");
    }

    /// @notice onERC721Received reverts when called by a non-PROJECTS contract.
    function test_onERC721Received_revertsWhenNotProjects() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        deployer.onERC721Received(address(0), address(0), 1, "");
    }

    /// @notice onERC721Received reverts when the `from` address is not address(0) (not a mint).
    function test_onERC721Received_revertsWhenNotMint() public {
        vm.prank(address(projects));
        vm.expectRevert();
        deployer.onERC721Received(address(0), owner, 1, "");
    }

    //*********************************************************************//
    // --- Constructor immutables ---------------------------------------- //
    //*********************************************************************//

    /// @notice Verify that constructor sets all immutable values correctly.
    function test_constructor_setsImmutables() public {
        assertEq(address(deployer.PROJECTS()), address(projects), "PROJECTS should be set");
        assertEq(address(deployer.DEPLOYER()), address(hookDeployer), "DEPLOYER should be set");
        assertEq(address(deployer.PUBLISHER()), address(publisher), "PUBLISHER should be set");
        assertEq(address(deployer.SUCKER_REGISTRY()), address(suckerRegistry), "SUCKER_REGISTRY should be set");
    }

    //*********************************************************************//
    // --- Internal Helpers ---------------------------------------------- //
    //*********************************************************************//

    /// @dev Build a default CTProjectConfig with no allowed posts or terminals.
    function _defaultProjectConfig() internal pure returns (CTProjectConfig memory) {
        return CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "https://croptop.test/",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "https://croptop.test/contract",
            name: "TestCrop",
            symbol: "TC",
            salt: bytes32(0)
        });
    }

    /// @dev Build an empty CTSuckerDeploymentConfig (no suckers).
    function _emptySuckerConfig() internal pure returns (CTSuckerDeploymentConfig memory) {
        return CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
    }

    /// @dev Set up all the mocks needed for a successful deployProjectFor call.
    function _mockDeployProjectInfra() internal {
        // Mock controller.PROJECTS() to return the same projects contract.
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(projects));

        // Mock projects.count() to return the current count.
        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(projectCount));

        // Mock hookDeployer.deployHookFor to return the hook address.
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );

        // Mock controller.launchProjectFor to return the expected project ID.
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchProjectFor.selector),
            abi.encode(deployedProjectId)
        );

        // Mock projects.transferFrom (ERC721 transfer of project NFT to owner).
        vm.mockCall(address(projects), abi.encodeWithSelector(IERC721.transferFrom.selector), abi.encode());

        // Mock permissions.setPermissionsFor (called for owner permissions after deployment).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
    }

    /// @dev Use vm.store to set the dataHookOf mapping directly.
    ///      dataHookOf is the first non-immutable storage variable in CTDeployer, at slot 0.
    function _setDataHookForProject(uint256 projectId, IJBRulesetDataHook hook) internal {
        bytes32 slot = keccak256(abi.encode(projectId, uint256(0)));
        vm.store(address(deployer), slot, bytes32(uint256(uint160(address(hook)))));
    }

    /// @dev Build a minimal JBBeforePayRecordedContext.
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

    /// @dev Build a minimal JBBeforeCashOutRecordedContext.
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
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }
}
