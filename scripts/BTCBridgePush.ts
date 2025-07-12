import { Blockbook, sleep } from 'blockbook-fetcher';
import { ethers } from 'hardhat';
import { formatEther, Signer, ZeroAddress, FeeData, JsonRpcApiProvider } from 'ethers';
import { address, networks, initEccLib } from 'bitcoinjs-lib';
//import { default as coininfo } from 'coininfo';
import * as ecc from 'tiny-secp256k1';
import { fetchBlock } from '../src/block';
import {
    BTCBridge__factory,
    BTCBridgeLib__factory,
    GroupLib__factory,
    OwnableLib__factory,
    ReentrancyGuardLib__factory,
    SigLib__factory,
} from '../typechain-types';

initEccLib(ecc);

function toOutputScriptFunc(network?: networks.Network) {
    return (addr: string) => {
        return address.toOutputScript(addr, network).toString('hex');
    };
}

/**
 * Get correct fee data without multipliers
 */
async function getFeeData(provider: JsonRpcApiProvider) {
    const [gasPrice, maxFeePerGas, maxPriorityFeePerGas] = await Promise.all([
        (async () => {
            try {
                return BigInt(await provider.send('eth_gasPrice', []));
            } catch {
                return 0n;
            }
        })(),
        (async () => {
            const block = await provider.getBlock('latest');

            return block?.baseFeePerGas ?? null;
        })(),
        (async () => {
            try {
                return BigInt(await provider.send('eth_maxPriorityFeePerGas', []));
            } catch {
                return 0n;
            }
        })(),
    ]);

    return new FeeData(gasPrice, maxFeePerGas, maxPriorityFeePerGas);
}

async function deployLibs() {
    const [owner] = (await ethers.getSigners()) as unknown as Signer[];

    const addressSet = await (await ethers.getContractFactory('AddressSet', owner)).deploy();

    const ownerLib = await new OwnableLib__factory(owner).deploy();

    const groupLib = await new GroupLib__factory(
        {
            'contracts/libraries/AddressSet.sol:AddressSet': addressSet.target as string,
            'contracts/libraries/OwnableLib.sol:OwnableLib': ownerLib.target as string,
        },
        owner,
    ).deploy();

    const reentrancyLib = await new ReentrancyGuardLib__factory(owner).deploy();

    const sigLib = await new SigLib__factory(owner).deploy();

    const bridgeLib = await new BTCBridgeLib__factory(owner).deploy();

    return {
        ownerLib,
        groupLib,
        reentrancyLib,
        sigLib,
        bridgeLib,
    };
}

async function main() {
    const headerBytes = 80;
    const blockbook = new Blockbook('https://btc1.trezor.io');
    const toOutputScript = toOutputScriptFunc(networks.bitcoin);
    //const blockbook = new Blockbook('https://ltc1.trezor.io');
    //const toOutputScript = toOutputScriptFunc(coininfo('LTC').toBitcoinJS());

    /**
     * Fetch block / tx from blockbook
     */

    const blockNumber = (await blockbook.getStatus()).backend.blocks as number;

    await sleep(1000);

    const block = await fetchBlock(blockbook, blockNumber, headerBytes, 1000);

    const txIndex = 1;

    /**
     * Deploy contracts
     */

    const [owner] = (await ethers.getSigners()) as unknown as Signer[];

    const { ownerLib, groupLib, reentrancyLib, sigLib, bridgeLib } = await deployLibs();

    const bridge = await new BTCBridge__factory(
        {
            ['contracts/libraries/OwnableLib.sol:OwnableLib']: ownerLib.target as string,
            ['contracts/libraries/GroupLib.sol:GroupLib']: groupLib.target as string,
            ['contracts/libraries/ReentrancyGuardLib.sol:ReentrancyGuardLib']: reentrancyLib.target as string,
            ['contracts/libraries/SigLib.sol:SigLib']: sigLib.target as string,
            ['contracts/libraries/BTCBridgeLib.sol:BTCBridgeLib']: bridgeLib.target as string,
        },
        owner,
    ).deploy();

    await bridge.initialize(ZeroAddress, [], true);

    /**
     * Prepare tx & tx proof
     */

    const { txid, txhash, hex: txHex, vout } = block.txs[txIndex] || {};
    const { value: btcValue, addresses } = vout?.[0] || {};

    if (!txHex || !btcValue || !addresses) {
        return;
    }

    const value = BigInt(btcValue) * 10n ** (18n - 6n);

    const scriptPubKey = toOutputScript(addresses[0]);

    const txSiblings = block.tree
        .getProof(Buffer.from(txid, 'hex'))
        .map((p) => '0x' + p.data.toString('hex'));

    const hashSiblings = block.hashTree
        .getProof(Buffer.from(txhash, 'hex'))
        .map((p) => '0x' + p.data.toString('hex'));

    /**
     * Test contract
     */

    const bridgeDeployTx = bridge.deploymentTransaction();
    const bridgeDeployTxReceipt = await owner.provider?.getTransactionReceipt(bridgeDeployTx?.hash as string);

    console.log(Number(bridgeDeployTx?.data?.length) / 2, bridgeDeployTxReceipt?.gasUsed);

    const { maxFeePerGas, maxPriorityFeePerGas } = await getFeeData(owner.provider as JsonRpcApiProvider);

    const blockGas = await bridge.pushBlock.estimateGas({
        chain: 1,
        timestamp: block.time as number,
        blockNumber,
        blockHash: '0x' + block.hash,
        prevBlockHash: '0x' + block.previousBlockHash,
        merkleRoot: '0x' + block.merkleRoot,
        hashRoot: '0x' + block.hashTreeRoot,
    });

    const { data: blockInput } = await bridge.pushBlock.populateTransaction({
        chain: 1,
        timestamp: block.time as number,
        blockNumber,
        blockHash: '0x' + block.hash,
        prevBlockHash: '0x' + block.previousBlockHash,
        merkleRoot: '0x' + block.merkleRoot,
        hashRoot: '0x' + block.hashTreeRoot,
    })

    const { data: txInput } = await bridge.pushMint.populateTransaction({
        chain: 1,
                blockNumber,
                txid: '0x' + txid,
                txIndex,
                txHex: '0x' + txHex,
                txSiblings,
                hashSiblings,
                to: ZeroAddress,
                scriptPub: '0x' + scriptPubKey,
                value,
                gasPrice: maxPriorityFeePerGas || 0,
                fees: 0,
    })

    const mintGas = await bridge.pushBlockMints.estimateGas(
        [
            {
                chain: 1,
                timestamp: block.time as number,
                blockNumber,
                blockHash: '0x' + block.hash,
                prevBlockHash: '0x' + block.previousBlockHash,
                merkleRoot: '0x' + block.merkleRoot,
                hashRoot: '0x' + block.hashTreeRoot,
            },
        ],
        [
            {
                chain: 1,
                blockNumber,
                txid: '0x' + txid,
                txIndex,
                txHex: '0x' + txHex,
                txSiblings,
                hashSiblings,
                to: ZeroAddress,
                scriptPub: '0x' + scriptPubKey,
                value,
                gasPrice: maxPriorityFeePerGas || 0,
                fees: 0,
            },
        ],
    );

    const estFees = (BigInt(maxFeePerGas || 0n) + BigInt(maxPriorityFeePerGas || 0n)) * mintGas;

    const fees = Math.min(Number(value), Number(estFees));

    console.log(blockGas, blockInput, txInput, mintGas, formatEther(estFees), formatEther(fees), formatEther(value));

    await bridge.pushBlockMints(
        [
            {
                chain: 1,
                timestamp: block.time as number,
                blockNumber,
                blockHash: '0x' + block.hash,
                prevBlockHash: '0x' + block.previousBlockHash,
                merkleRoot: '0x' + block.merkleRoot,
                hashRoot: '0x' + block.hashTreeRoot,
            },
        ],
        [
            {
                chain: 1,
                blockNumber,
                txid: '0x' + txid,
                txIndex,
                txHex: '0x' + txHex,
                txSiblings,
                hashSiblings,
                to: ZeroAddress,
                scriptPub: '0x' + scriptPubKey,
                value,
                gasPrice: maxPriorityFeePerGas || 0,
                fees,
            },
        ],
    );

    console.log(await bridge.chainInfos(1));

    console.log(await bridge.blockInfos(1, blockNumber));

    console.log(await bridge.getBlocks(1, 0, 100, true));

    console.log(await bridge.hasMintTx(1, '0x' + txid));

    console.log(await bridge.getMintInfo(1, '0x' + txid));

    console.log(await bridge.getMintInfos(1, 0, 100, true));
}
main();
