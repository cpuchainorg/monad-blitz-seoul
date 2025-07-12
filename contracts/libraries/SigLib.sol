// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev https://github.com/Uniswap/permit2/blob/main/src/libraries/SignatureVerification.sol
library SigLib {
    /// @notice Thrown when the passed in signature is not a valid length
    error InvalidSignatureLength();

    bytes32 constant UPPER_BIT_MASK =
        (0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);

    function toVRS(bytes calldata signature) public pure returns (uint8 v, bytes32 r, bytes32 s) {
        if (signature.length == 65) {
            (r, s) = abi.decode(signature, (bytes32, bytes32));
            v = uint8(signature[64]);
        } else if (signature.length == 64) {
            // EIP-2098
            bytes32 vs;
            (r, vs) = abi.decode(signature, (bytes32, bytes32));
            s = vs & UPPER_BIT_MASK;
            v = uint8(uint256(vs >> 255)) + 27;
        } else {
            revert InvalidSignatureLength();
        }
    }
}
