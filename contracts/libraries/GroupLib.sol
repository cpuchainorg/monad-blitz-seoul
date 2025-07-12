// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AddressSet } from './AddressSet.sol';
import { OwnableLib } from './OwnableLib.sol';

library GroupLib {
    using AddressSet for AddressSet.Set;

    event AddMember(bytes32 indexed slot, address newMember);
    event RemoveMember(bytes32 indexed slot, address oldMember);

    error DuplicatedMember(bytes32 slot, address account);
    error InvalidMember(bytes32 slot, address account);
    error NotMember(bytes32 slot, address account);

    modifier onlyOwner() {
        OwnableLib._onlyOwner();
        _;
    }

    modifier onlyMember(bytes32 slot) {
        _onlyMember(slot);
        _;
    }

    function _onlyMember(bytes32 slot) public view {
        AddressSet.Set storage group = addrSet(slot);
        address owner = OwnableLib.owner();
        if (
            !group.contains(msg.sender) &&
            group.length() != 0 &&
            owner != msg.sender &&
            owner != address(0)
        ) {
            revert NotMember(slot, msg.sender);
        }
    }

    function addrSet(bytes32 slot) internal pure returns (AddressSet.Set storage s) {
        assembly {
            s.slot := slot
        }
    }

    function members(bytes32 slot) public view returns (address[] memory) {
        return addrSet(slot).values();
    }

    function membersLength(bytes32 slot) public view returns (uint256) {
        return addrSet(slot).length();
    }

    function addMember(bytes32 slot, address member) public onlyOwner {
        AddressSet.Set storage group = addrSet(slot);
        if (group.contains(member)) {
            revert DuplicatedMember(slot, member);
        }
        group.add(member);
        emit AddMember(slot, member);
    }

    function removeMember(bytes32 slot, address member) public onlyOwner {
        AddressSet.Set storage group = addrSet(slot);
        if (!group.contains(member)) {
            revert InvalidMember(slot, member);
        }
        group.remove(member);
        emit RemoveMember(slot, member);
    }
}
