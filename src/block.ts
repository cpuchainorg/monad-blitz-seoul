/** Get BTC block to build SPV proofs */
import { Block, Blockbook, sleep, Tx } from 'blockbook-fetcher';
import MerkleTree from 'merkletreejs';
import { parseBlockTransactions } from './parse';
import { reverseBuffer, sha256, sha256d } from './utils';

export interface TxWithHash extends Tx {
    txhash: string;
}

export interface BlockWithHeader extends Omit<Block, 'txs'> {
    txs: TxWithHash[];
    header: string;
    tree: MerkleTree;
    hashTree: MerkleTree;
    hashTreeRoot: string;
}

/** Hash entire transaction with full image (including segwit) */
function hashTx(txhex: string): string {
    return reverseBuffer(sha256d(Buffer.from(txhex, 'hex'))).toString('hex');
}

// todo: remove sleep on production environment
export async function fetchBlock(
    blockbook: Blockbook,
    blockNumber: number,
    headerBytes = 80,
    sleepMs = 0,
): Promise<BlockWithHeader> {
    const [block, rawBlock] = await Promise.all([
        blockbook.getBlock(blockNumber) as Promise<BlockWithHeader>,
        sleep(sleepMs).then(() => blockbook.getRawBlock(blockNumber)),
    ]);

    block.header = rawBlock.slice(0, headerBytes * 2);

    const { page, totalPages } = {
        page: block.page || 0,
        totalPages: block.totalPages || 0,
    };

    if (page < totalPages) {
        const _txs = (
            await Promise.all(
                [...Array(totalPages - page).keys()].map(async (_, i) => {
                    await sleep(sleepMs * (i + 1));

                    return (await blockbook.getBlock(blockNumber, page + i + 1)).txs as TxWithHash[];
                }),
            )
        ).flat();

        block.txs.push(..._txs);
    }

    const { rawTxs, txCount } = parseBlockTransactions(rawBlock, headerBytes);

    if (block.txCount !== block.txs?.length) {
        throw new Error(`Invalid block txs, wants ${block.txCount} have ${block.txs?.length}`);
    }

    if (block.txCount !== txCount) {
        throw new Error(`Invalid raw block txs, wants ${block.txCount} have ${txCount}`);
    }

    const { txids, txhexes } = block.txs.reduce(
        (acc, tx, i) => {
            if (tx.hex && tx.hex !== rawTxs[i]) {
                throw new Error(`Invalid raw block ${blockNumber} tx ${i}`);
            } else if (!tx.hex) {
                tx.hex = rawTxs[i];
            }

            tx.txhash = hashTx(tx.hex);

            acc.txids.push(tx.txid);
            acc.txhexes.push(tx.txhash);

            return acc;
        },
        {
            txids: [] as string[],
            txhexes: [] as string[],
        },
    );

    block.tree = new MerkleTree(txids, sha256, { isBitcoinTree: true });
    block.hashTree = new MerkleTree(txhexes, sha256, { isBitcoinTree: true });

    const treeRoot = block.tree.getRoot().toString('hex');
    block.hashTreeRoot = block.hashTree.getRoot().toString('hex');

    if (block.merkleRoot !== treeRoot) {
        throw new Error(
            `Merkle root for block ${blockNumber} mismatch, wants ${block.merkleRoot} have ${treeRoot}`,
        );
    }

    return block;
}
