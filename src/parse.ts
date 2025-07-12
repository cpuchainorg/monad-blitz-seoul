import { reverseHexBytes } from './utils';

// Helper to get a little-endian integer from hex:
export function readLE(hex: string, bytes: number): number {
    let val = 0;
    for (let i = 0; i < bytes; i++) {
        val += parseInt(hex.substr(i * 2, 2), 16) << (8 * i);
    }
    return val;
}

// Reads a "varint", returns {value, length (in bytes)}
export function readVarInt(hex: string, pos: number): { value: number; length: number } {
    const first = parseInt(hex.substr(pos, 2), 16);
    if (first < 0xfd) return { value: first, length: 1 };
    if (first === 0xfd) return { value: readLE(hex.substr(pos + 2, 4), 2), length: 3 };
    if (first === 0xfe) return { value: readLE(hex.substr(pos + 2, 8), 4), length: 5 };
    return { value: readLE(hex.substr(pos + 2, 16), 8), length: 9 }; // 0xff
}

// Parses one transaction from raw block hex (starting at position), returns {hex, length}
export function parseTransaction(hex: string, start: number): { hex: string; length: number } {
    let pos = start;

    // Version (4 bytes)
    pos += 8;

    // Marker + Flag (for segwit) detection
    let hasWitness = false;
    if (hex.substr(pos, 4) === '0001') {
        // marker = 00, flag = 01
        hasWitness = true;
        pos += 4;
    }

    // Input count (varint)
    const vinVarInt = readVarInt(hex, pos);
    const vinCount = vinVarInt.value;
    pos += vinVarInt.length * 2;

    // Inputs
    for (let i = 0; i < vinCount; i++) {
        pos += 64; // prev txid (32 bytes)
        pos += 8; // prev vout (4 bytes)
        const scriptVarInt = readVarInt(hex, pos);
        pos += scriptVarInt.length * 2;
        pos += scriptVarInt.value * 2; // scriptSig
        pos += 8; // sequence (4 bytes)
    }

    // Output count (varint)
    const voutVarInt = readVarInt(hex, pos);
    const voutCount = voutVarInt.value;
    pos += voutVarInt.length * 2;

    // Outputs
    for (let i = 0; i < voutCount; i++) {
        pos += 16; // value (8 bytes)
        const pkScriptVarInt = readVarInt(hex, pos);
        pos += pkScriptVarInt.length * 2;
        pos += pkScriptVarInt.value * 2; // pk_script
    }

    // Witnesses (if segwit)
    if (hasWitness) {
        for (let i = 0; i < vinCount; i++) {
            const witItemCountVarInt = readVarInt(hex, pos);
            const witItemCount = witItemCountVarInt.value;
            pos += witItemCountVarInt.length * 2;
            for (let j = 0; j < witItemCount; j++) {
                const witItemSizeVarInt = readVarInt(hex, pos);
                const witItemSize = witItemSizeVarInt.value;
                pos += witItemSizeVarInt.length * 2;
                pos += witItemSize * 2;
            }
        }
    }

    // Locktime (4 bytes)
    pos += 8;

    const length = pos - start;
    return {
        hex: hex.substr(start, length),
        length: length,
    };
}

/**
 * Splits a raw Bitcoin block hex into an array of raw transaction hexes.
 *
 * Not compatible with
 *
 * litecoin: Can not parse MWEB txs length (requires additional func)
 * dogecoin: Can not parse AuxPoW header (not included as Block header but you need to parse to parse txs)
 * bitcoin gold: modify the headerBytes value
 */
export function parseBlockTransactions(
    rawBlockHex: string,
    headerBytes = 80,
): { rawTxs: string[]; txCount: number } {
    let pos = 0;
    // Skip block header (80 bytes)
    pos += headerBytes * 2;

    // todo: if for Dogecoin and merged mining coins, the AuxPoW with parent chain block headers should be parsed and skipped here

    // Get transaction count (varint)
    const txCountVarInt = readVarInt(rawBlockHex, pos);
    const txCount = txCountVarInt.value;
    pos += txCountVarInt.length * 2;

    const rawTxs: string[] = [];

    for (let i = 0; i < txCount; i++) {
        const tx = parseTransaction(rawBlockHex, pos);
        rawTxs.push(tx.hex);
        pos += tx.length;
    }

    if (txCount !== rawTxs.length) {
        throw new Error(`Parsing failed wants ${txCount} txs have ${rawTxs.length}`);
    }

    return {
        rawTxs,
        txCount,
    };
}

export function parseBlockHeader(headerHex: string, headerBytes = 80) {
    // todo: support alt blocks (BTG, ZEC, etc)
    if (headerBytes !== 80) {
        throw new Error('Unsupported block header');
    }

    if (headerHex.length !== headerBytes * 2) {
        throw new Error('Block header must be 80 bytes / 160 hex chars');
    }

    const versionLE = headerHex.slice(0, 8);
    const prevBlockLE = headerHex.slice(8, 72);
    const merkleRootLE = headerHex.slice(72, 136);
    const timestampLE = headerHex.slice(136, 144);
    const bitsLE = headerHex.slice(144, 152);
    const nonceLE = headerHex.slice(152, 160);

    return {
        version: parseInt(reverseHexBytes(versionLE), 16),
        previousBlockHash: reverseHexBytes(prevBlockLE),
        merkleRoot: reverseHexBytes(merkleRootLE),
        timestamp: parseInt(reverseHexBytes(timestampLE), 16),
        bits: bitsLE, // as little-endian hex
        bitsInt: parseInt(reverseHexBytes(bitsLE), 16),
        nonce: parseInt(reverseHexBytes(nonceLE), 16),
    };
}
