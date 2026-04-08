// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {ICTDeployer} from "./interfaces/ICTDeployer.sol";
import {ICTProjectOwner} from "./interfaces/ICTProjectOwner.sol";
import {ICTPublisher} from "./interfaces/ICTPublisher.sol";

/// @notice A contract that can be sent a project to be burned, while still allowing croptop posts.
/// @dev This contract does not expose any function to reconfigure posting criteria. This is by design: posting
/// criteria are set before transferring the project here, and become immutable once ownership is transferred.
/// The project owner should configure all desired posting criteria before sending the project NFT to this contract.
contract CTProjectOwner is IERC721Receiver, ICTProjectOwner {
    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The Croptop deployer used to look up each project's data hook.
    ICTDeployer public immutable override DEPLOYER;

    /// @notice The contract where operator permissions are stored.
    IJBPermissions public immutable override PERMISSIONS;

    /// @notice The contract from which project are minted.
    IJBProjects public immutable override PROJECTS;

    /// @notice The Croptop publisher.
    ICTPublisher public immutable override PUBLISHER;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param deployer The Croptop deployer used to look up each project's data hook.
    /// @param permissions The contract where operator permissions are stored.
    /// @param projects The contract from which project are minted.
    /// @param publisher The Croptop publisher.
    constructor(ICTDeployer deployer, IJBPermissions permissions, IJBProjects projects, ICTPublisher publisher) {
        DEPLOYER = deployer;
        PERMISSIONS = permissions;
        PROJECTS = projects;
        PUBLISHER = publisher;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Give the croptop publisher permission to post to the project on this contract's behalf.
    /// @dev Make sure to first configure certain posts before sending this contract ownership.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    )
        external
        override
        returns (bytes4)
    {
        data;
        from;
        operator;

        // Make sure the 721 received is the JBProjects contract.
        if (msg.sender != address(PROJECTS)) revert();

        // Revert if the hook is still owned by the deployer (collection ownership not claimed).
        {
            address hookAddress = address(DEPLOYER.dataHookOf(tokenId));
            if (hookAddress != address(0)) {
                (address hookOwner,,) = IJBOwnable(hookAddress).jbOwner();
                if (hookOwner == address(DEPLOYER)) {
                    revert CTProjectOwner_HookNotClaimed();
                }
            }
        }

        // Set the correct permission.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;

        // Give the croptop contract permission to post on this contract's behalf.
        PERMISSIONS.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: address(PUBLISHER),
                // forge-lint: disable-next-line(unsafe-typecast)
                projectId: uint64(tokenId),
                permissionIds: permissionIds
            })
        });

        return IERC721Receiver.onERC721Received.selector;
    }
}
