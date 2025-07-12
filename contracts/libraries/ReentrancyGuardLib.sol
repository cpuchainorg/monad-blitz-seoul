// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal reentrancy protection based on Solmate & OpenZeppelin
library ReentrancyGuardLib {
    bytes32 private constant REENTER = keccak256(abi.encodePacked('ReentrancyGuardLib'));

    error ReentrancyGuardReentrantCall();

    struct Locked {
        bool locked;
    }

    modifier nonReentrant() {
        lock();
        _;
        unlock();
    }

    function lock() public {
        Locked storage locked = getLocked();
        if (locked.locked) {
            revert ReentrancyGuardReentrantCall();
        }
        locked.locked = true;
    }

    function unlock() public {
        Locked storage locked = getLocked();
        locked.locked = false;
    }

    function getLocked() internal pure returns (Locked storage l) {
        bytes32 reenter = REENTER;
        assembly {
            l.slot := reenter
        }
    }
}
