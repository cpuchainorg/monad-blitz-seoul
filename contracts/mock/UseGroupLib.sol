// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { GroupLib, OwnableLib } from '../libraries/GroupLib.sol';

contract UseGroupLib {
    // For ABI purpose
    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event AddMember(bytes32 indexed slot, address newMember);
    event RemoveMember(bytes32 indexed slot, address oldMember);

    bytes32 private constant TST = keccak256(abi.encodePacked('Group'));

    constructor() {
        OwnableLib.transferOwnership(msg.sender);
    }

    function owner() public view returns (address) {
        return OwnableLib.owner();
    }

    function transferOwnership(address newOwner) public {
        OwnableLib.transferOwnership(newOwner);
    }

    function tstMembers() external view returns (address[] memory) {
        return GroupLib.members(TST);
    }

    function tstMembersLength() external view returns (uint256) {
        return GroupLib.membersLength(TST);
    }

    function addTstMember(address member) external {
        GroupLib.addMember(TST, member);
    }

    function removeTstMember(address member) external {
        GroupLib.removeMember(TST, member);
    }
}
