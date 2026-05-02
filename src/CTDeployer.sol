// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {ICTDeployer} from "./interfaces/ICTDeployer.sol";
import {ICTPublisher} from "./interfaces/ICTPublisher.sol";
import {CTAllowedPost} from "./structs/CTAllowedPost.sol";
import {CTDeployerAllowedPost} from "./structs/CTDeployerAllowedPost.sol";
import {CTProjectConfig} from "./structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "./structs/CTSuckerDeploymentConfig.sol";

interface IJBControllerProjectUri {
    function setUriOf(uint256 projectId, string calldata uri) external;
}

/// @notice A contract that facilitates deploying a simple Juicebox project to receive posts from Croptop templates.
contract CTDeployer is ERC2771Context, JBPermissioned, IJBRulesetDataHook, IERC721Receiver, ICTDeployer {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error CTDeployer_NotOwnerOfProject(uint256 projectId, address hook, address caller);
    error CTDeployer_SuckerDeploymentPermissionRequired(uint256 projectId, address owner);

    //*********************************************************************//
    // ---------------------------- events -------------------------------- //
    //*********************************************************************//

    event CTDeployer_SuckerDeploymentFailed(uint256 indexed projectId, bytes32 indexed salt, bytes reason);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent Juicebox project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The deployer to launch Croptop recorded collections from.
    IJB721TiersHookDeployer public immutable override DEPLOYER;

    /// @notice The Croptop publisher.
    ICTPublisher public immutable override PUBLISHER;

    /// @notice Deploys and tracks suckers for projects.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Each project's data hook provided on deployment.
    /// @custom:param projectId The ID of the project to get the data hook for.
    /// @custom:param rulesetId The ID of the ruleset to get the data hook for.
    mapping(uint256 projectId => IJBRulesetDataHook) public dataHookOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permissions The permissions contract.
    /// @param projects The projects contract.
    /// @param deployer The deployer to launch Croptop projects from.
    /// @param publisher The croptop publisher.
    /// @param suckerRegistry The sucker registry.
    /// @param trustedForwarder The trusted forwarder.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        IJB721TiersHookDeployer deployer,
        ICTPublisher publisher,
        IJBSuckerRegistry suckerRegistry,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
        JBPermissioned(permissions)
    {
        PROJECTS = projects;
        DEPLOYER = deployer;
        PUBLISHER = publisher;
        SUCKER_REGISTRY = suckerRegistry;

        // Give the sucker registry permission to map tokens for all revnets.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.MAP_SUCKER_TOKEN;

        // Give the operator the permission.
        // Set up the permission data.
        JBPermissionsData memory permissionData =
            JBPermissionsData({operator: address(SUCKER_REGISTRY), projectId: 0, permissionIds: permissionIds});

        // Set the permissions.
        PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: permissionData});

        // Set permission for the CTPublisher to adjust the tier.
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;

        // Set permission for the CTPublisher to mint the NFT.
        permissionData = JBPermissionsData({operator: address(PUBLISHER), projectId: 0, permissionIds: permissionIds});

        // Set permission for the CTPublisher to adjust the tier.
        PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: permissionData});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claim ownership of the collection.
    /// @dev Two-step ownership transfer process:
    ///   Step 1 (this function): Transfers hook ownership to the project via `transferOwnershipToProject()`.
    ///     After this call, `hook.owner()` resolves dynamically through `PROJECTS.ownerOf(projectId)`.
    ///   Step 2 (caller must do separately): The project owner grants CTPublisher the `ADJUST_721_TIERS` permission
    ///     for the project so that `mintFrom()` continues to work.
    /// Without the Step 2 permission grant, all subsequent posts will revert. This cannot be done atomically here
    /// because after transferring ownership to the project, this contract no longer has authority to set permissions
    /// on the project's behalf.
    /// @param hook The hook to claim ownership of.
    function claimCollectionOwnershipOf(IJB721TiersHook hook) external override {
        // Get the project ID of the hook.
        uint256 projectId = hook.PROJECT_ID();

        // Make sure the caller is the owner of the project.
        if (PROJECTS.ownerOf(projectId) != _msgSender()) {
            revert CTDeployer_NotOwnerOfProject(projectId, address(hook), _msgSender());
        }

        // Transfer the hook's ownership to the project.
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);
    }

    /// @notice Deploy a simple project meant to receive posts from Croptop templates.
    /// @dev The deployed hook remains owned by `CTDeployer` until the project owner claims collection ownership.
    /// This keeps the publisher path working from the deployer's permissions while avoiding direct stale owner
    /// permissions that would otherwise survive project NFT transfers.
    /// @param owner The address that'll own the project.
    /// @param projectConfig The configuration for the project.
    /// @param suckerDeploymentConfiguration The configuration for the suckers to deploy.
    /// @param controller The controller that will own the project.
    /// @return projectId The ID of the newly created project.
    /// @return hook The hook that was created.
    function deployProjectFor(
        address owner,
        CTProjectConfig calldata projectConfig,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        override
        returns (uint256 projectId, IJB721TiersHook hook)
    {
        if (controller.PROJECTS() != PROJECTS) revert();

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].weight = 1_000_000 * (10 ** 18);
        rulesetConfigurations[0].metadata.baseCurrency = JBCurrencyIds.ETH;

        // Reserve the project ID up front so permissionless project creations cannot invalidate hook deployment.
        projectId = PROJECTS.createFor(address(this));

        // Deploy a blank project.
        // slither-disable-next-line reentrancy-benign
        hook = DEPLOYER.deployHookFor({
            projectId: projectId,
            deployTiersHookConfig: JBDeploy721TiersHookConfig({
                name: projectConfig.name,
                symbol: projectConfig.symbol,
                baseUri: "ipfs://",
                tokenUriResolver: IJB721TokenUriResolver(address(0)),
                contractUri: projectConfig.contractUri,
                tiersConfig: JB721InitTiersConfig({
                    tiers: new JB721TierConfig[](0), currency: JBCurrencyIds.ETH, decimals: 18
                }),
                flags: JB721TiersHookFlags({
                    noNewTiersWithReserves: false,
                    noNewTiersWithVotes: false,
                    noNewTiersWithOwnerMinting: false,
                    preventOverspending: false,
                    issueTokensForSplits: false
                })
            }),
            salt: keccak256(abi.encode(projectConfig.salt, _msgSender()))
        });

        rulesetConfigurations[0].metadata.cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE;
        rulesetConfigurations[0].metadata.dataHook = address(this);
        rulesetConfigurations[0].metadata.useDataHookForPay = true;
        rulesetConfigurations[0].metadata.useDataHookForCashOut = true;

        // Launch the rulesets for the reserved project.
        // slither-disable-next-line unused-return
        controller.launchRulesetsFor({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: projectConfig.terminalConfigurations,
            memo: "Deployed from Croptop"
        });
        if (bytes(projectConfig.projectUri).length != 0) {
            IJBControllerProjectUri(address(controller)).setUriOf({projectId: projectId, uri: projectConfig.projectUri});
        }

        // Set the data hook for the project.
        dataHookOf[projectId] = IJBRulesetDataHook(hook);

        // Configure allowed posts.
        if (projectConfig.allowedPosts.length > 0) {
            _configurePostingCriteriaFor(address(hook), projectConfig.allowedPosts);
        }

        // Deploy the suckers (if applicable).
        // The L2 sucker deployer fallback cascade (try primary, fall back to secondary) is
        // intentionally ordered. If both deployers fail, the deployment proceeds without suckers rather than reverting,
        // allowing projects to launch on unsupported chains with manual sucker setup later.
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            bytes32 suckerSalt = keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender()));
            try SUCKER_REGISTRY.deploySuckersFor({
                projectId: projectId,
                salt: suckerSalt,
                configurations: suckerDeploymentConfiguration.deployerConfigurations
            }) returns (
                address[] memory
            ) {
            // Intentionally ignore the return value. Suckers are discoverable from the registry.
            }
            catch (bytes memory reason) {
                emit CTDeployer_SuckerDeploymentFailed(projectId, suckerSalt, reason);
            }
        }

        //transfer to _owner.
        PROJECTS.transferFrom({from: address(this), to: owner, tokenId: projectId});

        // Direct collection-control permissions are intentionally not granted from CTDeployer to `owner`.
        // Project owners who want direct hook control should call `claimCollectionOwnershipOf(...)`, after which
        // hook permissions resolve through the current project NFT owner instead of the deployer.
    }

    /// @notice Deploy new suckers for an existing project.
    /// @dev Only the juicebox's owner can deploy new suckers.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    function deploySuckersFor(
        uint256 projectId,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers)
    {
        address owner = PROJECTS.ownerOf(projectId);

        // Enforce permissions.
        _requirePermissionFrom({account: owner, projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS});

        if (!_hasPermissionFrom({
                operator: address(this),
                account: owner,
                projectId: projectId,
                permissionId: JBPermissionIds.DEPLOY_SUCKERS
            })) {
            revert CTDeployer_SuckerDeploymentPermissionRequired(projectId, owner);
        }

        // Deploy the suckers.
        // slither-disable-next-line unused-return
        suckers = SUCKER_REGISTRY.deploySuckersFor({
            projectId: projectId,
            salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
            configurations: suckerDeploymentConfiguration.deployerConfigurations
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Allow cash outs from suckers without a tax.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a cash out.
    /// @param context Standard Juicebox cash out context. See `JBBeforeCashOutRecordedContext`.
    /// @return cashOutTaxRate The cash out tax rate, which influences the amount of terminal tokens which get cashed
    /// out.
    /// @return cashOutCount The number of project tokens that are cashed out.
    /// @return totalSupply The total project token supply.
    /// @return surplusValue The surplus value to use for the bonding curve calculation.
    /// @return hookSpecifications The amount of funds and the data to send to cash out hooks (this contract).
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 surplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // If the cash out is from a sucker, return the full cash out amount without taxes or fees.
        if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // If the ruleset has a data hook, forward the call to the datahook.
        IJBRulesetDataHook hook = dataHookOf[context.projectId];
        if (address(hook) == address(0)) {
            return (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
        }
        // slither-disable-next-line unused-return
        return hook.beforeCashOutRecordedWith(context);
    }

    /// @notice Forward the call to the original data hook.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a payment.
    /// @param context Standard Juicebox payment context. See `JBBeforePayRecordedContext`.
    /// @return weight The weight which project tokens are minted relative to. This can be used to customize how many
    /// tokens get minted by a payment.
    /// @return hookSpecifications Amounts (out of what's being paid in) to be sent to pay hooks instead of being paid
    /// into the project. Useful for automatically routing funds from a treasury as payments come in.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Forward the call to the data hook.
        IJBRulesetDataHook hook = dataHookOf[context.projectId];
        if (address(hook) == address(0)) {
            return (context.weight, hookSpecifications);
        }

        // slither-disable-next-line unused-return
        return hook.beforePayRecordedWith(context);
    }

    /// @notice A flag indicating whether an address has permission to mint a project's tokens on-demand.
    /// @dev A project's data hook can allow any address to mint its tokens.
    /// @param projectId The ID of the project whose token can be minted.
    /// @param addr The address to check the token minting permission of.
    /// @return flag A flag indicating whether the address has permission to mint the project's tokens on-demand.
    function hasMintPermissionFor(uint256 projectId, JBRuleset memory, address addr) external view returns (bool flag) {
        // If the address is a sucker for this project.
        return SUCKER_REGISTRY.isSuckerOf({projectId: projectId, addr: addr});
    }

    /// @dev Make sure only mints can be received.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    )
        external
        view
        returns (bytes4)
    {
        data;
        tokenId;
        operator;

        // Make sure the 721 received is the JBProjects contract.
        if (msg.sender != address(PROJECTS)) revert();
        // Make sure the 721 is being received as a mint.
        if (from != address(0)) revert();
        return IERC721Receiver.onERC721Received.selector;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ICTDeployer).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId;
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Configure croptop posting.
    /// @param hook The hook that will be posted to.
    /// @param allowedPosts The type of posts that should be allowed.
    function _configurePostingCriteriaFor(address hook, CTDeployerAllowedPost[] memory allowedPosts) internal {
        // Keep a reference to the number of allowed posts.
        uint256 numberOfAllowedPosts = allowedPosts.length;

        // Keep a reference to the formatted allowed posts.
        CTAllowedPost[] memory formattedAllowedPosts = new CTAllowedPost[](numberOfAllowedPosts);

        // Keep a reference to the post being iterated on.
        CTDeployerAllowedPost memory post;

        // Iterate through each post to add it to the formatted list.
        for (uint256 i; i < numberOfAllowedPosts;) {
            // Set the post being iterated on.
            post = allowedPosts[i];

            // Set the formatted post.
            formattedAllowedPosts[i] = CTAllowedPost({
                hook: hook,
                category: post.category,
                minimumPrice: post.minimumPrice,
                minimumTotalSupply: post.minimumTotalSupply,
                maximumTotalSupply: post.maximumTotalSupply,
                maximumSplitPercent: post.maximumSplitPercent,
                allowedAddresses: post.allowedAddresses
            });

            unchecked {
                ++i;
            }
        }

        // Set up the allowed posts in the publisher.
        PUBLISHER.configurePostingCriteriaFor({allowedPosts: formattedAllowedPosts});
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }
}
