import { Blockbook, sleep } from 'blockbook-fetcher';
import { ethers } from 'hardhat';
import { Signer } from 'ethers';
import { address, networks } from 'bitcoinjs-lib';
//import { default as coininfo } from 'coininfo';
import { fetchBlock } from '../src/block';
import { BTCBridgeLib__factory } from '../typechain-types';

function toOutputScriptFunc(network?: networks.Network) {
    return (addr: string) => {
        return address.toOutputScript(addr, network).toString('hex');
    };
}

async function main() {
    const headerBytes = 80;
    const blockbook = new Blockbook('https://btc1.trezor.io');
    const toOutputScript = toOutputScriptFunc(networks.bitcoin);
    //const blockbook = new Blockbook('https://doge1.trezor.io');
    //const toOutputScript = toOutputScriptFunc(coininfo('DOGE').toBitcoinJS());

    const blockNumber = (await blockbook.getStatus()).backend.blocks as number;

    await sleep(1000);

    const block = await fetchBlock(blockbook, blockNumber, headerBytes, 1000);

    //const txIndex = block.txs.length - 1;
    const txIndex = 1;

    const [owner] = (await ethers.getSigners()) as unknown as Signer[];

    const bridgeLib = await new BTCBridgeLib__factory(owner).deploy();

    /**
     * Verify header via contract
     */
    const [prevBlockHash, timestamp, parsedMerkleRoot] = await bridgeLib.extractBlockHeader(
        '0x' + block.header,
    );

    if (prevBlockHash === '0x' + block.previousBlockHash) {
        console.log('Prev block hash verified');
    }

    if (Number(timestamp) === block.time) {
        console.log('Timestamp verified');
    }

    if (parsedMerkleRoot === '0x' + block.merkleRoot) {
        console.log('Merkle root verfied');
    }

    /**
     * Verify inclusion proof via contract
     */
    const { txid, txhash } = block.txs[txIndex];

    const txSiblings = block.tree
        .getProof(Buffer.from(txid, 'hex'))
        .map((p) => '0x' + p.data.toString('hex'));

    const verified = await bridgeLib.checkBtcMerkleProof(
        '0x' + txid,
        txSiblings,
        txIndex,
        '0x' + block.merkleRoot,
    );

    const txSiblings2 = block.hashTree
        .getProof(Buffer.from(txhash, 'hex'))
        .map((p) => '0x' + p.data.toString('hex'));

    const verified2 = await bridgeLib.checkBtcMerkleProof(
        '0x' + txhash,
        txSiblings2,
        txIndex,
        '0x' + block.hashTreeRoot,
    );

    if (verified) {
        console.log(`Merkle proof for tx ${txid} ${txIndex} verified from contract`);
    }

    if (verified2) {
        console.log(`Hex merkle proof for tx ${txid} ${txIndex} verified from contract`);
    }

    /**
     * Verify tx output via contract
     */
    const txhex = block.txs[txIndex].hex;
    const { value, addresses } = block.txs[txIndex].vout[0] || {};

    if (!txhex || !value || !addresses) {
        return;
    }

    const scriptPubKey = toOutputScript(addresses[0]);

    const verifyOutput = await bridgeLib.hasOutput('0x' + txhex, value, '0x' + scriptPubKey);

    if (verifyOutput) {
        console.log(`Verified output for tx ${txid} ${txIndex} output 0`);
    }
}

main();
