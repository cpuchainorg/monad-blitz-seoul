import { createHash } from 'crypto';

export function sleep(ms: number) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Double SHA256 */
export function sha256d(buffer: Buffer): Buffer {
    return createHash('sha256').update(createHash('sha256').update(buffer).digest()).digest();
}

// For merkle root computation
export function sha256(buffer: Buffer): Buffer {
    return createHash('sha256').update(buffer).digest();
}

/** Buffer endianness reversal */
export function reverseBuffer(b: Buffer): Buffer {
    return Buffer.from(b).reverse();
}

export function reverseHexBytes(hex: string): string {
    // reverses LE to BE (or vice versa)
    const hasPrefix = hex.startsWith('0x');

    return (
        (hasPrefix ? '0x' : '') + (hasPrefix ? hex.replace('0x', '') : hex).match(/../g)!.reverse().join('')
    );
}
