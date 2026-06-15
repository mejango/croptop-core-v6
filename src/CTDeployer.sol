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
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBPayerTrackerLib} from "@bananapus/core-v6/src/libraries/JBPayerTrackerLib.sol";
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

/// @notice Deploys Juicebox projects pre-configured for Croptop — a permissionless NFT publishing system. Each
/// deployed project gets a tiered 721 hook (for minting posted NFTs), an optional set of cross-chain suckers, and this
/// contract set as the data hook so suckers get 0% cash-out tax and mint permission. The hook initially remains owned
/// by this deployer (allowing the publisher to add tiers); the project owner can later claim full hook ownership via
/// `claimCollectionOwnershipOf`.
contract CTDeployer is
    ERC2771Context,
    JBPermissioned,
    IJBRulesetDataHook,
    IERC721Receiver,
    IJBPayerTracker,
    ICTDeployer
{
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a caller is not the Juicebox project owner for the hook being claimed.
    error CTDeployer_NotOwnerOfProject(uint256 projectId, address hook, address caller);

    //*********************************************************************//
    // ---------------------------- events -------------------------------- //
    //*********************************************************************//

    /// @notice Emitted when launch-time sucker deployment fails without reverting the collection launch.
    /// @param projectId The project whose sucker deployment failed.
    /// @param salt The salt used for the failed sucker deployment attempt.
    /// @param reason The revert reason returned by the sucker registry.
    /// @param caller The address that launched the project.
    event CTDeployer_SuckerDeploymentFailed(
        uint256 indexed projectId, bytes32 indexed salt, bytes reason, address caller
    );

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The deployer to launch Croptop recorded collections from.
    IJB721TiersHookDeployer public immutable override DEPLOYER;

    /// @notice Mints ERC-721s that represent Juicebox project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The Croptop publisher contract that manages post allowances and content rules.
    ICTPublisher public immutable override PUBLISHER;

    /// @notice Deploys and tracks suckers for projects.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Each project's data hook provided on deployment.
    /// @custom:param projectId The ID of the project to get the data hook for.
    mapping(uint256 projectId => IJBRulesetDataHook) public dataHookOf;

    //*********************************************************************//
    // ------------------- public transient properties ------------------- //
    //*********************************************************************//

    /// @notice The account that paid the creation fee for the project currently being deployed.
    /// @dev Set to the resolved fee payer (this deployer's ERC-2771 caller, or that caller's upstream payer when the
    /// caller is itself an `IJBPayerTracker`) while `JBProjects.createFor` runs, so `JBProjects` attributes the fee to
    /// the true payer instead of this deployer. Cleared back to `address(0)` once the call returns.
    address public transient override originalPayer;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permissions The permissions contract.
    /// @param projects The projects contract.
    /// @param deployer The deployer to launch Croptop projects from.
    /// @param publisher The Croptop publisher.
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

        // Set permission for the CTPublisher to adjust tiers while the deployer temporarily owns new hooks.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;

        JBPermissionsData memory permissionData =
            JBPermissionsData({operator: address(PUBLISHER), projectId: 0, permissionIds: permissionIds});

        PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: permissionData});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claim ownership of the collection.
    /// @dev Two-step ownership transfer process:
    ///   Step 1 (this function): Revokes the deployer-scoped permissions granted at launch, then transfers hook
    ///     ownership to the project via `transferOwnershipToProject()`.
    ///     After this call, `hook.owner()` resolves dynamically through `PROJECTS.ownerOf(projectId)`.
    ///   Step 2 (caller must do separately): The project owner grants CTPublisher the `ADJUST_721_TIERS` permission
    ///     for the project so that `mintFrom()` continues to work.
    /// Without the Step 2 permission grant, all subsequent posts will revert. This cannot be done atomically here
    /// because after transferring ownership to the project, this contract no longer has authority to set permissions
    /// on the project's behalf.
    /// @param hook The hook to claim ownership of.
    function claimCollectionOwnershipOf(IJB721TiersHook hook) external override {
        // Get the project ID of the hook.
        uint256 projectId = hook.projectId();

        // Keep a reference to the caller.
        address caller = _msgSender();

        // Make sure the caller is the owner of the project.
        if (PROJECTS.ownerOf(projectId) != caller) {
            revert CTDeployer_NotOwnerOfProject({projectId: projectId, hook: address(hook), caller: caller});
        }

        // Revoke the deployer-scoped permissions that were granted to the caller during deployment.
        // These permissions (ADJUST_721_TIERS, SET_721_METADATA, MINT_721, SET_721_DISCOUNT_PERCENT) allowed the
        // project owner to manage the hook while the deployer owned it. After transferring hook ownership to the
        // project, these deployer-scoped grants are no longer needed and should be cleaned up to prevent stale
        // permission leakage.
        PERMISSIONS.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: caller,
                // forge-lint: disable-next-line(unsafe-typecast)
                projectId: uint64(projectId),
                permissionIds: new uint8[](0)
            })
        });

        // Transfer the hook's ownership to the project.
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);
    }

    /// @notice Deploy a simple project meant to receive posts from Croptop templates.
    /// @dev The deployed hook remains owned by `CTDeployer` until the project owner claims collection ownership.
    /// The initial owner is granted direct deployer-scoped hook permissions as a launch-time convenience. Those
    /// permissions can bypass Croptop's publisher surface until ownership is claimed away from the deployer.
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
        payable
        override
        returns (uint256 projectId, IJB721TiersHook hook)
    {
        if (controller.PROJECTS() != PROJECTS) revert();

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].weight = 1_000_000 * (10 ** 18);
        rulesetConfigurations[0].metadata.baseCurrency = JBCurrencyIds.ETH;

        // Expose the resolved fee payer so `JBProjects` attributes the creation fee to the true payer (this deployer's
        // caller), not this deployer. The project NFT is still minted to this deployer so it can finish wiring the hook
        // before handing the project to `owner`. Cleared immediately after.
        originalPayer = JBPayerTrackerLib.resolve(_msgSender());

        // Reserve the project ID up front so permissionless project creations cannot invalidate hook deployment.
        projectId = PROJECTS.createFor{value: msg.value}(address(this));

        originalPayer = address(0);

        // Deploy a blank project.
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
        controller.launchRulesetsFor({
            projectId: projectId,
            projectUri: projectConfig.projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: projectConfig.terminalConfigurations,
            memo: "Deployed from Croptop"
        });

        // Set the data hook for the project.
        dataHookOf[projectId] = IJBRulesetDataHook(hook);

        // Configure allowed posts.
        if (projectConfig.allowedPosts.length > 0) {
            _configurePostingCriteriaFor({hook: address(hook), allowedPosts: projectConfig.allowedPosts});
        }

        // Deploy the suckers (if applicable).
        // The L2 sucker deployer fallback cascade (try primary, fall back to secondary) is
        // intentionally ordered. If both deployers fail, the deployment proceeds without suckers rather than reverting,
        // allowing projects to launch on unsupported chains with manual sucker setup later.
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            bytes32 suckerSalt = keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender()));

            // A launch-time project is still owned by this deployer until the final NFT transfer, so check the
            // intended owner before the registry sees `address(this)` as the current project owner.
            _requireExplicitSuckerPeerPermissionFrom({
                account: owner, projectId: projectId, suckerDeploymentConfiguration: suckerDeploymentConfiguration
            });

            // Successful deployments are discoverable from the registry, and failures are reported without reverting
            // the project launch.
            try SUCKER_REGISTRY.deploySuckersFor({
                projectId: projectId,
                salt: suckerSalt,
                configurations: suckerDeploymentConfiguration.deployerConfigurations
            }) returns (
                address[] memory
            ) {
            // no-op
            }
            catch (bytes memory reason) {
                emit CTDeployer_SuckerDeploymentFailed({
                    projectId: projectId, salt: suckerSalt, reason: reason, caller: _msgSender()
                });
            }
        }

        // Transfer the project NFT to its intended owner. Use the safe path so contract owners must explicitly
        // support receiving the project NFT before the launch can finalize.
        PROJECTS.safeTransferFrom(address(this), owner, projectId);

        // Give the initial project owner direct collection-control permissions while CTDeployer remains the hook's
        // owner. This preserves the documented Croptop launch tradeoff: the owner can manage the collection directly
        // before calling `claimCollectionOwnershipOf(...)`, after which hook permissions follow the project NFT owner.
        uint8[] memory permissionIds = new uint8[](4);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;
        permissionIds[1] = JBPermissionIds.SET_721_METADATA;
        permissionIds[2] = JBPermissionIds.MINT_721;
        permissionIds[3] = JBPermissionIds.SET_721_DISCOUNT_PERCENT;

        PERMISSIONS.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: owner,
                // forge-lint: disable-next-line(unsafe-typecast)
                projectId: uint64(projectId),
                permissionIds: permissionIds
            })
        });
    }

    /// @notice Deploy new suckers for an existing project.
    /// @dev Only the Juicebox project owner or a `DEPLOY_SUCKERS` operator can deploy new suckers. Supplying an
    /// explicit non-default peer also requires `SET_SUCKER_PEER`, matching the registry's direct-call rule.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 projectId,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers)
    {
        // Resolve the project owner once because Juicebox permissions are checked against the owner's permission table.
        address owner = PROJECTS.ownerOf(projectId);

        // `DEPLOY_SUCKERS` authorizes this wrapper to ask the registry for new suckers, but it does not authorize
        // choosing a non-default remote peer.
        _requirePermissionFrom({account: owner, projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS});

        // Mirror the registry's explicit-peer gate against the original project authority before this wrapper becomes
        // the registry caller.
        _requireExplicitSuckerPeerPermissionFrom({
            account: owner, projectId: projectId, suckerDeploymentConfiguration: suckerDeploymentConfiguration
        });

        // Deploy the suckers. The sucker registry performs its own permission check against this forwarding helper,
        // so an unapproved CTDeployer fails at the downstream registry boundary without an extra preflight read here.
        suckers = SUCKER_REGISTRY.deploySuckersFor({
            projectId: projectId,
            salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
            configurations: suckerDeploymentConfiguration.deployerConfigurations
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Called before a cash out is recorded. Grants suckers 0% tax so bridged tokens redeem at full value.
    /// For non-sucker holders, delegates to the project's stored data hook (if any) or passes through the original
    /// context values.
    /// @dev Part of `IJBRulesetDataHook`.
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
        // Sucker cash-outs are the bridge accounting path: the value moving out of this chain must stay proportional
        // to this chain's local backing. Do not add remote supply/surplus here.
        if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // If the ruleset has a data hook, forward the call to the data hook.
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
        return hook.beforeCashOutRecordedWith(context);
    }

    /// @notice Called before a payment is recorded. Delegates to the project's stored data hook (the 721 hook) so NFT
    /// tier minting logic runs. If no hook is set, passes through the original weight.
    /// @dev Part of `IJBRulesetDataHook`.
    /// @param context Standard Juicebox payment context. See `JBBeforePayRecordedContext`.
    /// @return weight The weight which project tokens are minted relative to. This can be used to customize how many
    /// tokens get minted by a payment.
    /// @return hookSpecifications Amounts (out of what's paid in) to send to pay hooks instead of adding to the
    /// project. Useful for automatically routing funds from a treasury as payments come in.
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

        return hook.beforePayRecordedWith(context);
    }

    /// @notice Returns whether an address may mint a project's tokens on-demand. Only suckers get this permission, so
    /// bridged tokens can be minted on the destination chain.
    /// @dev Part of `IJBRulesetDataHook`.
    /// @param projectId The ID of the project whose token can be minted.
    /// @param addr The address to check the token minting permission of.
    /// @return flag A flag indicating whether the address has permission to mint the project's tokens on-demand.
    function hasMintPermissionFor(uint256 projectId, JBRuleset memory, address addr) external view returns (bool flag) {
        // If the address is a sucker for this project.
        return SUCKER_REGISTRY.isSuckerOf({projectId: projectId, addr: addr});
    }

    /// @notice Accepts only freshly minted project NFTs sent directly by `JBProjects`.
    /// @dev Rejecting transfers from a non-zero `from` ensures the deployer cannot be handed a project after launch.
    /// @param operator Unused; the transfer is authenticated by `msg.sender` and `from`, not the operator.
    /// @param from Unused except to gate acceptance; a non-zero prior owner means this is not a fresh mint.
    /// @param tokenId Unused; any freshly minted project NFT is accepted.
    /// @param data Unused; no payload is expected on a project mint.
    /// @return magicValue The `IERC721Receiver.onERC721Received` selector that signals a successful receipt.
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

        // Only accept project NFTs from JBProjects.
        if (msg.sender != address(PROJECTS)) revert();
        // Only accept freshly minted project NFTs.
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
            || interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IJBPayerTracker).interfaceId;
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Configure Croptop posting criteria for a newly deployed hook.
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

    /// @notice Revert unless the caller may set explicit sucker peers for `projectId`.
    /// @dev The registry enforces this against its direct caller. Since this deployer wraps the registry call, it must
    /// mirror the check against the original caller so `DEPLOY_SUCKERS` alone cannot smuggle in arbitrary peers.
    /// @param account The project owner account whose permission table is checked.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The sucker deployment configuration to inspect.
    function _requireExplicitSuckerPeerPermissionFrom(
        address account,
        uint256 projectId,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        internal
        view
    {
        // Scan every requested sucker configuration because a single explicit peer changes cross-chain authority.
        for (uint256 i; i < suckerDeploymentConfiguration.deployerConfigurations.length;) {
            // Cache the configured peer so the default/explicit branch is evaluated from the exact value sent onward.
            bytes32 peer = suckerDeploymentConfiguration.deployerConfigurations[i].peer;

            // `peer == 0` preserves the sucker's deterministic same-address peer behavior.
            // Any nonzero peer is written directly into the new sucker and changes who can deliver remote roots.
            if (peer != bytes32(0)) {
                // Require the original project authority, not this wrapper, to authorize explicit remote peers.
                _requirePermissionFrom({
                    account: account, projectId: projectId, permissionId: JBPermissionIds.SET_SUCKER_PEER
                });
                // One explicit peer is enough to prove the caller needs the stronger permission.
                return;
            }

            unchecked {
                // Skip overflow checks because `i` is bounded by the calldata array length.
                ++i;
            }
        }
    }
}
