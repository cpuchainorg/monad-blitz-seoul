// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library BTCBridgeLib {
    // Computes Bitcoin block hash (double-SHA256, returns little-endian as bytes32)
    function hashBlock(bytes memory header) public pure returns (bytes32) {
        require(header.length == 80, 'Header must be 80 bytes');
        // Reverse bytes for little-endian Bitcoin convention
        return reverse32(sha256(abi.encodePacked(sha256(header))));
    }

    // Does not work with segwit transactions see above
    // https://bitcoin.stackexchange.com/questions/120354/how-to-compute-a-txid-of-any-bitcoin-transaction-in-python
    function hashTx(bytes memory txHex) public pure returns (bytes32) {
        return reverse32(sha256(abi.encodePacked(sha256(txHex))));
    }

    // Extract Bitcoin block's prev block hash
    function extractPrevBlock(bytes memory header) public pure returns (bytes32 prev) {
        assembly {
            prev := mload(add(add(header, 32), 4))
        }
        prev = reverse32(prev);
    }

    // Extract Bitcoin block's timestamp
    function extractTimestamp(bytes memory header) public pure returns (uint32) {
        bytes4 res;
        assembly {
            res := mload(add(add(header, 32), 68))
        }
        return uint32(reverse4(res));
    }

    // Extract Bitcoin block's merkle root (bytes36-68 in header)
    function extractMerkleRoot(bytes memory header) public pure returns (bytes32 merkleRoot) {
        assembly {
            merkleRoot := mload(add(header, 68))
        }
        return reverse32(merkleRoot);
    }

    function extractBlockHeader(
        bytes memory header
    ) public pure returns (bytes32 previousBlock, uint32 timestamp, bytes32 merkleRoot) {
        require(header.length == 80, 'header must be 80 bytes');
        previousBlock = extractPrevBlock(header);
        timestamp = extractTimestamp(header);
        merkleRoot = extractMerkleRoot(header);
    }

    // Verify Merkle inclusion proof
    function checkMerkleProof(
        bytes32 leaf,
        bytes32[] memory proof,
        uint index,
        bytes32 root
    ) public pure returns (bool) {
        bytes32 computed = leaf;
        for (uint i = 0; i < proof.length; i++) {
            if ((index & 1) == 1) {
                computed = sha256(abi.encodePacked(proof[i], computed));
                computed = sha256(abi.encodePacked(computed));
            } else {
                computed = sha256(abi.encodePacked(computed, proof[i]));
                computed = sha256(abi.encodePacked(computed));
            }
            index >>= 1;
        }
        return computed == root;
    }

    function checkBtcMerkleProof(
        bytes32 txid,
        bytes32[] memory txSiblings,
        uint16 txIndex,
        bytes32 merkleRoot
    ) public pure returns (bool) {
        txid = reverse32(txid);
        txSiblings = reverse32Arr(txSiblings);
        merkleRoot = reverse32(merkleRoot);

        return checkMerkleProof(txid, txSiblings, txIndex, merkleRoot);
    }

    /**
     * Checks if rawTx has an OP_RETURN output with targetData.
     *
     * @param rawTx Bitcoin tx as bytes
     * @param opReturnData the expected OP_RETURN data (not including 0x6a or push opcode)
     */
    function hasOpReturnOutput(
        bytes memory rawTx,
        bytes memory opReturnData
    ) public pure returns (bool) {
        uint offset = 4; // Skip version
        // -- Detect SegWit: If marker=0 and flag=1 at next two bytes
        if (rawTx[4] == 0x00 && rawTx[5] == 0x01) {
            offset += 2;
        }
        (uint nInputs, uint off) = readVarInt(rawTx, offset);
        offset = off;
        // Skip inputs
        for (uint i = 0; i < nInputs; i++) {
            offset += 32 + 4; // prev txid + vout
            (uint scriptLen, uint scriptOff) = readVarInt(rawTx, offset);
            offset = scriptOff + scriptLen + 4; // script + sequence
        }
        // Parse output count
        (uint nOutputs, uint outOff) = readVarInt(rawTx, offset);
        offset = outOff;

        for (uint i = 0; i < nOutputs; i++) {
            offset += 8; // skip value
            (uint pkLen, uint pkOff) = readVarInt(rawTx, offset);
            offset = pkOff;
            if (pkLen > 0 && uint8(rawTx[offset]) == 0x6a) {
                // scriptPubKey starts with OP_RETURN
                if (pkLen < 2) {
                    // At minimum must be op_return + push 0 (0 length)
                    offset += pkLen;
                    continue;
                }
                uint pushLen = uint8(rawTx[offset + 1]);
                // Check opcode is a push (0x01...0x4b OK, 0? Or maybe could be OP_PUSHDATA/N? Here, supporting only <= 0x4b)
                uint dataStart = offset + 2;
                if (
                    pushLen == opReturnData.length &&
                    pkLen >= (2 + opReturnData.length) &&
                    compareBytesSlice(rawTx, dataStart, opReturnData)
                ) {
                    return true;
                }
            }
            offset += pkLen;
        }
        return false;
    }

    /**
     * Checks if rawTx has an output with (value, scriptPubKey)
     * @param rawTx Bitcoin tx as bytes
     * @param valueSats output value in sats
     * @param scriptPub the expected scriptPubKey (bytes, not address! e.g. 0x001475... for P2WPKH)
     */
    function hasOutput(
        bytes memory rawTx,
        uint64 valueSats,
        bytes memory scriptPub
    ) public pure returns (bool) {
        // parse version (4 bytes)
        uint offset = 4;
        // -- Detect SegWit: If marker=0 and flag=1 at next two bytes
        if (rawTx[4] == 0x00 && rawTx[5] == 0x01) {
            offset += 2;
        }
        // parse input count (varint)
        (uint nInputs, uint off) = readVarInt(rawTx, offset);
        offset = off;
        // skip all inputs
        for (uint i = 0; i < nInputs; i++) {
            offset += 32 + 4; // prev txid + vout
            (uint scriptLen, uint scriptOff) = readVarInt(rawTx, offset);
            offset = scriptOff + scriptLen + 4; // script + sequence
        }
        // parse output count (varint)
        (uint nOutputs, uint outOff) = readVarInt(rawTx, offset);
        offset = outOff;
        for (uint i = 0; i < nOutputs; i++) {
            uint64 val = readLE8(rawTx, offset); // 8 bytes value, little-endian
            offset += 8;
            (uint pkLen, uint pkOff) = readVarInt(rawTx, offset);
            offset = pkOff;
            bytes memory spk = new bytes(pkLen);
            for (uint j = 0; j < pkLen; j++) {
                spk[j] = rawTx[offset + j];
            }
            offset += pkLen;
            if (val == valueSats && compareBytes(spk, scriptPub)) {
                return true;
            }
        }
        return false;
    }

    function readLE8(bytes memory bs, uint off) internal pure returns (uint64) {
        // Read 8 bytes as uint64 little-endian
        uint64 r = 0;
        for (uint64 i = 0; i < 8; i++) {
            r |= uint64(uint8(bs[off + i])) << uint64(8 * i);
        }
        return r;
    }

    // Reads a Bitcoin varint at offset. Returns (value, newOffset)
    function readVarInt(bytes memory data, uint off) internal pure returns (uint, uint) {
        uint8 fb = uint8(data[off]);
        if (fb < 0xfd) return (fb, off + 1);
        if (fb == 0xfd) return ((uint8(data[off + 1]) | (uint8(data[off + 2]) << 8)), off + 3);
        if (fb == 0xfe)
            return (
                (uint(uint8(data[off + 1])) |
                    (uint(uint8(data[off + 2])) << 8) |
                    (uint(uint8(data[off + 3])) << 16) |
                    (uint(uint8(data[off + 4])) << 24)),
                off + 5
            );
        // 0xff
        uint val = 0;
        for (uint i = 0; i < 8; i++) {
            val |= (uint(uint8(data[off + 1 + i])) << (8 * i));
        }
        return (val, off + 9);
    }

    function compareBytes(bytes memory a, bytes memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    // Compare opReturnData to C[offset:offset+data.length]
    function compareBytesSlice(
        bytes memory c,
        uint offset,
        bytes memory data
    ) internal pure returns (bool) {
        if (offset + data.length > c.length) return false;
        for (uint i = 0; i < data.length; i++) {
            if (c[offset + i] != data[i]) return false;
        }
        return true;
    }

    // Helper to reverse bytes4 (for little-endian hash)
    function reverse4(bytes4 input) internal pure returns (bytes4 v) {
        for (uint256 i = 0; i < 4; i++) {
            v |= ((input >> (i * 8)) & bytes4(uint32(0xFF))) << ((3 - i) * 8);
        }
    }

    // Helper to reverse bytes32 (for little-endian hash)
    function reverse32(bytes32 input) internal pure returns (bytes32 v) {
        for (uint256 i = 0; i < 32; i++) {
            v |= ((input >> (i * 8)) & bytes32(uint256(0xFF))) << ((31 - i) * 8);
        }
    }

    function reverse32Arr(bytes32[] memory inputs) internal pure returns (bytes32[] memory) {
        bytes32[] memory outputs = new bytes32[](inputs.length);

        for (uint i; i < outputs.length; ++i) {
            outputs[i] = reverse32(inputs[i]);
        }

        return outputs;
    }
}
