// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {JBDenominatedAmount} from "@bananapus/suckers-v6/src/structs/JBDenominatedAmount.sol";
import {JBOutboxTree} from "@bananapus/suckers-v6/src/structs/JBOutboxTree.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBRemoteToken} from "@bananapus/suckers-v6/src/structs/JBRemoteToken.sol";
import {JBSuckerState} from "@bananapus/suckers-v6/src/enums/JBSuckerState.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";
import {CTProjectConfig} from "../../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";
import {CTDeployerAllowedPost} from "../../src/structs/CTDeployerAllowedPost.sol";

contract MockProjects {
    uint256 public countValue;
    mapping(uint256 => address) internal _ownerOf;

    function count() external view returns (uint256) {
        return countValue;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }

    function mintFor(address owner, uint256 projectId) external {
        countValue = projectId;
        _ownerOf[projectId] = owner;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_ownerOf[tokenId] == from, "BAD_FROM");
        _ownerOf[tokenId] = to;
    }
}

contract MockDirectory is IJBDirectory {
    IJBProjects internal immutable _projects;

    constructor(IJBProjects projects_) {
        _projects = projects_;
    }

    function PROJECTS() external view returns (IJBProjects) {
        return _projects;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        revert("UNUSED");
    }

    function isAllowedToSetFirstController(address) external pure returns (bool) {
        revert("UNUSED");
    }

    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        revert("UNUSED");
    }

    function primaryTerminalOf(uint256, address) external pure returns (IJBTerminal) {
        revert("UNUSED");
    }

    function setControllerOf(uint256, IERC165) external pure {
        revert("UNUSED");
    }

    function setIsAllowedToSetFirstController(address, bool) external pure {
        revert("UNUSED");
    }

    function setPrimaryTerminalOf(uint256, address, IJBTerminal) external pure {
        revert("UNUSED");
    }

    function setTerminalsOf(uint256, IJBTerminal[] calldata) external pure {
        revert("UNUSED");
    }

    function terminalsOf(uint256) external pure returns (IJBTerminal[] memory) {
        revert("UNUSED");
    }
}

contract MockController {
    MockProjects public immutable PROJECTS;
    uint256 public immutable nextProjectId;

    constructor(MockProjects projects_, uint256 nextProjectId_) {
        PROJECTS = projects_;
        nextProjectId = nextProjectId_;
    }

    function launchProjectFor(
        address owner,
        string calldata,
        JBRulesetConfig[] calldata,
        JBTerminalConfig[] calldata,
        string calldata
    )
        external
        returns (uint256)
    {
        PROJECTS.mintFor(owner, nextProjectId);
        return nextProjectId;
    }
}

contract MockHook {
    uint256 internal immutable _projectId;

    constructor(uint256 projectId_) {
        _projectId = projectId_;
    }

    function PROJECT_ID() external view returns (uint256) {
        return _projectId;
    }
}

contract MockHookDeployer {
    IJB721TiersHook public hook;

    function setHook(IJB721TiersHook hook_) external {
        hook = hook_;
    }

    function deployHookFor(
        uint256,
        JBDeploy721TiersHookConfig calldata,
        bytes32
    )
        external
        view
        returns (IJB721TiersHook)
    {
        return hook;
    }
}

contract RevertingSuckerRegistry {
    error DeploymentUnavailable();

    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] calldata
    )
        external
        pure
        returns (address[] memory)
    {
        revert DeploymentUnavailable();
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }
}

contract PermissionedMockSucker is JBPermissioned {
    MockProjects internal immutable _projects;
    uint256 internal immutable _projectId;
    uint256 internal immutable _peerChainId;

    constructor(
        IJBPermissions permissions,
        MockProjects projects_,
        uint256 projectId_,
        uint256 peerChainId_
    )
        JBPermissioned(permissions)
    {
        _projects = projects_;
        _projectId = projectId_;
        _peerChainId = peerChainId_;
    }

    function peer() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function peerChainId() external view returns (uint256) {
        return _peerChainId;
    }

    function projectId() external view returns (uint256) {
        return _projectId;
    }

    function state() external pure returns (JBSuckerState) {
        return JBSuckerState.ENABLED;
    }

    function mapTokens(JBTokenMapping[] calldata) external payable {
        _requirePermissionFrom({
            account: _projects.ownerOf(_projectId),
            projectId: _projectId,
            permissionId: JBPermissionIds.MAP_SUCKER_TOKEN
        });
    }

    function outboxOf(address) external pure returns (JBOutboxTree memory) {
        revert("UNUSED");
    }

    function peerChainTotalSupply() external pure returns (uint256) {
        revert("UNUSED");
    }

    function peerChainBalanceOf(uint256, uint256) external pure returns (JBDenominatedAmount memory) {
        revert("UNUSED");
    }

    function peerChainSurplusOf(uint256, uint256) external pure returns (JBDenominatedAmount memory) {
        revert("UNUSED");
    }

    function remoteTokenFor(address) external pure returns (JBRemoteToken memory) {
        revert("UNUSED");
    }

    function claim(JBClaim[] calldata) external pure {
        revert("UNUSED");
    }

    function claim(JBClaim calldata) external pure {
        revert("UNUSED");
    }

    function mapToken(JBTokenMapping calldata) external payable {
        revert("UNUSED");
    }

    function prepare(uint256, bytes32, uint256, address) external payable {
        revert("UNUSED");
    }

    function toRemote(address, bytes calldata) external payable {
        revert("UNUSED");
    }

    function enableEmergencyHatchFor(address) external payable {
        revert("UNUSED");
    }

    function exitThroughEmergencyHatch(address, uint256, address payable) external {
        revert("UNUSED");
    }

    function setPeer(bytes32) external payable {
        revert("UNUSED");
    }

    function setPeerChainId(uint256) external payable {
        revert("UNUSED");
    }

    function setDeprecation(uint40) external payable {
        revert("UNUSED");
    }
}

contract MockSuckerDeployer {
    IJBPermissions internal immutable _permissions;
    MockProjects internal immutable _projects;
    uint256 internal immutable _peerChainId;

    constructor(IJBPermissions permissions_, MockProjects projects_, uint256 peerChainId_) {
        _permissions = permissions_;
        _projects = projects_;
        _peerChainId = peerChainId_;
    }

    function createForSender(uint256 localProjectId, bytes32) external returns (IJBSucker sucker) {
        sucker = IJBSucker(address(new PermissionedMockSucker(_permissions, _projects, localProjectId, _peerChainId)));
    }
}

contract CodexNemesisFreshRoundTest is Test {
    address internal owner = makeAddr("owner");

    function _emptyProjectConfig() internal pure returns (CTProjectConfig memory config) {
        config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "ipfs://project",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "ipfs://contract",
            name: "Croptop",
            symbol: "CT",
            salt: bytes32(uint256(123))
        });
    }

    function test_deployProjectFor_revertsInsteadOfFailingOpenWhenSuckerDeploymentFails() public {
        JBPermissions permissions = new JBPermissions(address(0));
        MockProjects projects = new MockProjects();
        MockHookDeployer hookDeployer = new MockHookDeployer();
        MockHook hook = new MockHook(1);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));
        MockController controller = new MockController(projects, 1);
        MockDirectory directory = new MockDirectory(IJBProjects(address(projects)));
        CTPublisher publisher = new CTPublisher(directory, permissions, 1, address(0));
        CTDeployer deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(new RevertingSuckerRegistry())),
            address(0)
        );

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32("salt")});

        vm.expectRevert(RevertingSuckerRegistry.DeploymentUnavailable.selector);
        deployer.deployProjectFor(owner, _emptyProjectConfig(), suckerConfig, IJBController(address(controller)));
    }

    function test_directRegistryDeploymentAfterOwnershipTransferStillLacksMapPermission() public {
        JBPermissions permissions = new JBPermissions(address(0));
        MockProjects projects = new MockProjects();
        MockDirectory directory = new MockDirectory(IJBProjects(address(projects)));
        JBSuckerRegistry registry = new JBSuckerRegistry(directory, permissions, address(this), address(0));
        MockHookDeployer hookDeployer = new MockHookDeployer();
        MockHook hook = new MockHook(1);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));
        MockController controller = new MockController(projects, 1);
        CTPublisher publisher = new CTPublisher(directory, permissions, 999, address(0));
        CTDeployer deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(registry)),
            address(0)
        );

        address[] memory deployers = new address[](1);
        MockSuckerDeployer suckerDeployer = new MockSuckerDeployer(permissions, projects, 10);
        deployers[0] = address(suckerDeployer);
        registry.allowSuckerDeployers(deployers);

        CTSuckerDeploymentConfig memory emptySuckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
        deployer.deployProjectFor(owner, _emptyProjectConfig(), emptySuckerConfig, IJBController(address(controller)));

        assertEq(projects.ownerOf(1), owner, "project ownership should leave CTDeployer after launch");

        JBSuckerDeployerConfig[] memory deployerConfigurations = new JBSuckerDeployerConfig[](1);
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({localToken: address(0xBEEF), minGas: 200_000, remoteToken: bytes32(uint256(1))});
        deployerConfigurations[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(suckerDeployer)), mappings: mappings});

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                address(registry),
                1,
                JBPermissionIds.MAP_SUCKER_TOKEN
            )
        );
        registry.deploySuckersFor(1, bytes32("later"), deployerConfigurations);
    }
}
