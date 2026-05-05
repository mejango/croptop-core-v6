// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {ICTProjectOwner} from "./interfaces/ICTProjectOwner.sol";
import {ICTPublisher} from "./interfaces/ICTPublisher.sol";

/// @notice A dead-end owner for Juicebox projects that locks ownership while preserving Croptop posting. When a project
/// NFT is transferred to this contract via `safeTransferFrom`, it automatically grants the Croptop publisher
/// `ADJUST_721_TIERS` permission so posts can continue. The project can never be transferred out again — effectively
/// burning ownership while keeping the collection alive.
/// @dev This contract does not expose any function to reconfigure posting criteria. Criteria are set before
/// transferring the project here and become immutable once ownership is transferred.
contract CTProjectOwner is IERC721Receiver, ICTProjectOwner {
    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The contract where operator permissions are stored.
    IJBPermissions public immutable override PERMISSIONS;

    /// @notice The contract from which project are minted.
    IJBProjects public immutable override PROJECTS;

    /// @notice The Croptop publisher.
    ICTPublisher public immutable override PUBLISHER;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permissions The contract where operator permissions are stored.
    /// @param projects The contract from which project are minted.
    /// @param publisher The Croptop publisher.
    constructor(IJBPermissions permissions, IJBProjects projects, ICTPublisher publisher) {
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
