// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal single owner authorization mixin based on Solmate & OpenZeppelin
library OwnableLib {
    bytes32 private constant OWNR = keccak256(abi.encodePacked('OwnableLib'));

    error Initialized();

    error OwnableUnauthorizedAccount(address account);

    event OwnershipTransferred(address indexed user, address indexed newOwner);

    struct Owner {
        address owner;
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function getOwner() internal pure returns (Owner storage s) {
        bytes32 ownr = OWNR;
        assembly {
            s.slot := ownr
        }
    }

    function _onlyOwner() internal view {
        Owner storage _owner = getOwner();
        if (_owner.owner != msg.sender && _owner.owner != address(0)) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    // Can use as initializer
    function initializer() public view {
        if (getOwner().owner != address(0)) {
            revert Initialized();
        }
    }

    function owner() public view returns (address) {
        return getOwner().owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        Owner storage _owner = getOwner();
        emit OwnershipTransferred(_owner.owner, newOwner);
        _owner.owner = newOwner;
    }
}
