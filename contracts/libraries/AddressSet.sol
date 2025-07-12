// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal library for address arrays based on OpenZeppelin
library AddressSet {
    struct Set {
        // Storage of set values
        address[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(address value => uint256) _positions;
    }

    /// @dev Add a value to a set. O(1).
    function add(Set storage set, address value) public returns (bool) {
        if (!contains(set, value)) {
            set._values.push(value);
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /// @dev Removes a value from a set. O(1).
    function remove(Set storage set, address value) public returns (bool) {
        uint256 position = set._positions[value];

        if (position != 0) {
            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                address lastValue = set._values[lastIndex];

                set._values[valueIndex] = lastValue;
                set._positions[lastValue] = position;
            }

            set._values.pop();
            delete set._positions[value];
            return true;
        } else {
            return false;
        }
    }

    /// @dev Removes all the values from a set. O(n).
    function clear(Set storage set) public {
        uint256 len = length(set);
        for (uint256 i = 0; i < len; ++i) {
            delete set._positions[set._values[i]];
        }
        address[] storage array = set._values;
        assembly ('memory-safe') {
            sstore(array.slot, 0)
        }
    }

    /// @dev Returns true if the value is in the set. O(1).
    function contains(Set storage set, address value) public view returns (bool) {
        return set._positions[value] != 0;
    }

    /// @dev Returns the number of values on the set. O(1).
    function length(Set storage set) public view returns (uint256) {
        return set._values.length;
    }

    /// @dev Returns the value stored at position `index` in the set. O(1).
    function at(Set storage set, uint256 index) public view returns (address) {
        return set._values[index];
    }

    /// @dev Return the entire set in an array
    function values(Set storage set) public view returns (address[] memory) {
        return set._values;
    }
}
