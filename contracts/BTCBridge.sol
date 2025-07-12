// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20Mintable } from './interfaces/IERC20.sol';
import { BTCBridgeLib } from './libraries/BTCBridgeLib.sol';
import { OwnableLib } from './libraries/OwnableLib.sol';
import { GroupLib } from './libraries/GroupLib.sol';
import { ReentrancyGuardLib } from './libraries/ReentrancyGuardLib.sol';
import { SigLib } from './libraries/SigLib.sol';

interface ITokenPriceCalculator {
    // Converts ETH cost to token amount
    function convert(uint256 ethAmount) external view returns (uint256);
}

interface INativeTransfer {
    function transfer(address to, uint256 value) external;
}

contract NativeTransferMock {
    receive() external payable {}

    function transfer(address to, uint256 value) external {}
}

/**
 * BTC (forks) - EVM bridge
 *
 * 1. Verifies block hash -> block header -> block merkle root -> txid -> tx hash (light SPV without PoW validation)
 * 2. Records all necessary information to contract for data retrival & statistics
 * so that it doesn't require additional centralized DB
 * 3. Failover in mind, even if one of the proof fails it will still push params to state without settling order.
 */
contract BTCBridge {
    bytes32 private constant BLKPUSH = keccak256(abi.encodePacked('BlockPusher'));

    /**
     * Inherited from libraries for ABI
     */
    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event AddMember(bytes32 indexed slot, address newMember);
    event RemoveMember(bytes32 indexed slot, address oldMember);

    /**
     * - BlockNumber on events are BTC blocks
     */
    event UpdateNativeTransfer(INativeTransfer nativeTransfer);
    event UpdateChain(
        uint32 indexed chain,
        ChainType chainType,
        IERC20Mintable token,
        ITokenPriceCalculator tokenPriceCalculator,
        string depositAddress,
        bytes32 depositScriptPub,
        uint64 mintConfs,
        uint64 burnConfs,
        bool handleReorgs
    );

    event Block(
        uint32 indexed chain,
        uint64 indexed blockNumber,
        uint64 timestamp,
        bytes32 blockHash,
        bytes32 prevBlockHash,
        bytes32 merkleRoot,
        bytes32 hashRoot
    );
    event RemovedBlock(uint32 indexed chain, uint64 indexed blockNumber);
    event Mint(
        uint32 indexed chain,
        uint64 indexed index,
        uint64 blockNumber,
        uint64 timestamp,
        bytes32 indexed txid,
        bytes32 txHash,
        uint16 txIndex,
        address to,
        uint256 value,
        uint256 fees,
        bytes txHex
    );
    event MintError(uint64 indexed index, bytes returnData);
    event Burn(
        uint32 indexed chain,
        uint64 indexed index,
        uint64 blockNumber,
        uint64 timestamp,
        bytes32 indexed txid,
        bytes32 burnTx,
        uint16 txIndex
    );
    event BurnRequested(
        uint32 indexed chain,
        uint64 indexed index,
        uint64 timestamp,
        string to,
        uint256 value,
        uint256 fees
    );

    INativeTransfer public nativeTransfer;

    /// @dev To support different type of BTC variations (LTC, DOGE, etc)
    enum ChainType {
        BTC
    }

    /**
     * @dev BTC chain configuration
     * @param token                         Wrapped token for BTC chain (if zero native transfer will be used)
     * @param tokenPriceCalculator (mint)   Token price calculator against native token to calculate fees
     * @param depositAddress       (mint)   BTC address to accept deposit to (off-chain logic)
     * @param depositScriptPub     (mint)   ScriptPubHash of BTC address for accepting deposits
     * @param mintConfs            (mint)   Required confirmations to accept mint requests (off-chain logic)
     * @param burnConfs            (burn)   Required confirmations to accept burn requests (off-chain logic)
     * @param firstBlockNum        (blocks) First block number of block storage
     * @param lastBlockNum         (blocks) Last block number of block storage
     * @param blocks               (blocks) count of block storage
     * @param lastMint             (mint)   Latest mint block (of btc chain)
     * @param lastBurn             (burn)   Latest burn block (of evm chain)
     */
    struct ChainInfo {
        // configs
        ChainType chainType;
        IERC20Mintable token;
        ITokenPriceCalculator tokenPriceCalculator;
        string depositAddress;
        bytes32 depositScriptPub;
        uint64 mintConfs;
        uint64 burnConfs;
        bool handleReorgs;
        // state
        uint64 firstBlockNum;
        uint64 lastBlockNum;
        uint64 blocks;
        uint64 lastMint;
        uint64 lastBurn;
    }

    /// @dev chainInfos[chain] => ChainInfo BTC chain mapped by SLIP-44
    mapping(uint32 => ChainInfo) public chainInfos;

    /**
     * @dev BTC chain block
     * @param blockNumber    (blockHeader) Block number
     * @param timestamp      (blockHeader) UTC timestamp
     * @param blockHash      (blockHeader) Block hash
     * @param prevBlockHash  (blockHeader) Prev block hash
     * @param merkleRoot     (blockHeader) Merkle root of txids
     * @param hashRoot       (custom)      Merkle root of fully hashed txs
     */
    struct BlockInfo {
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 blockHash;
        bytes32 prevBlockHash;
        bytes32 merkleRoot;
        bytes32 hashRoot;
    }

    // SLIP44 => Block Hash => Block Num
    mapping(uint32 => mapping(bytes32 => uint64)) public blockHashNum;

    // SLIP44 => Block Num => BlockInfo
    mapping(uint32 => mapping(uint64 => BlockInfo)) public blockInfos;

    /**
     * @dev Mint info
     * @param blockNumber  (BTC)      Block number
     * @param timestamp    (BTC)      UTC timestamp
     * @param txid         (BTC)      TXID on BTC
     * @param txHash       (BTC)      sha256d hashed tx hash (differs with txid when segwit)
     * @param mintTx       (EVM)      TXID on EVM (optional, only available when minted by proposers)
     * @param txIndex      (BTC)      TXINDEX of BTC block
     * @param to           (EVM)      To address on EVM
     * @param value        (BTC,EVM)  Amount on EVM (with 18 decimals for all tokens)
     * @param fees         (EVM)      Fee on EVM (calculated from chain gas fees multiplied by token price)
     */
    struct MintInfo {
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 txid;
        bytes32 txHash;
        bytes32 mintTx;
        uint16 txIndex;
        address to;
        uint256 value;
        uint256 fees;
    }

    mapping(uint32 => mapping(bytes32 => uint64)) public mintIndex;

    mapping(uint32 => MintInfo[]) private mintInfos;

    /**
     * @dev Burn info
     * @param blockNumber  (BTC)      Block number
     * @param timestamp    (BTC)      UTC timestamp
     * @param txid         (BTC)      TXID on BTC
     * @param burnTx       (EVM)      TXID on EVM
     * @param txIndex      (BTC)      TXINDEX of BTC block
     * @param from         (EVM)      From address on EVM (in case of refund)
     * @param to           (BTC)      To address for BTC
     * @param value        (BTC,EVM)  Amount on EVM (with 18 decimals for all tokens)
     * @param fees         (EVM)      Fee on EVM (calculated from chain gas fees)
     */
    struct BurnInfo {
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 txid;
        bytes32 burnTx;
        uint16 txIndex;
        address from;
        string to;
        uint256 value;
        uint256 fees;
    }

    mapping(uint32 => mapping(bytes32 => uint64)) public burnIndex;

    mapping(uint32 => BurnInfo[]) private burnInfos;

    bool public isDebug;

    /**
     * Modifiers
     */
    modifier nonReentrant() {
        ReentrancyGuardLib.lock();
        _;
        ReentrancyGuardLib.unlock();
    }

    modifier initializer() {
        OwnableLib.initializer();
        _;
    }

    modifier onlyOwner() {
        OwnableLib._onlyOwner();
        _;
    }

    modifier onlyBlockPusher() {
        GroupLib._onlyMember(BLKPUSH);
        _;
    }

    /**
     * Functions
     */
    function initialize(
        INativeTransfer _nativeTransfer,
        ChainConfig[] memory chains,
        bool debug
    ) external initializer {
        OwnableLib.transferOwnership(msg.sender);
        setNativeTransfer(_nativeTransfer);

        for (uint i; i < chains.length; ++i) {
            setChain(chains[i]);
        }

        if (debug) {
            isDebug = debug;

            setNativeTransfer(INativeTransfer(address(new NativeTransferMock())));
        }
    }

    function setNativeTransfer(INativeTransfer _nativeTransfer) public onlyOwner {
        nativeTransfer = _nativeTransfer;
        emit UpdateNativeTransfer(_nativeTransfer);
    }

    struct ChainConfig {
        uint32 chain;
        ChainType chainType;
        IERC20Mintable token;
        ITokenPriceCalculator tokenPriceCalculator;
        string depositAddress;
        bytes32 depositScriptPub;
        uint64 mintConfs;
        uint64 burnConfs;
        bool handleReorgs;
    }

    function setChain(ChainConfig memory config) public onlyOwner {
        ChainInfo storage chain = chainInfos[config.chain];

        chain.chainType = config.chainType;
        chain.token = config.token;
        chain.tokenPriceCalculator = config.tokenPriceCalculator;
        chain.depositAddress = config.depositAddress;
        chain.depositScriptPub = config.depositScriptPub;
        chain.mintConfs = config.mintConfs;
        chain.burnConfs = config.burnConfs;
        chain.handleReorgs = config.handleReorgs;

        emit UpdateChain(
            config.chain,
            config.chainType,
            config.token,
            config.tokenPriceCalculator,
            config.depositAddress,
            config.depositScriptPub,
            config.mintConfs,
            config.burnConfs,
            config.handleReorgs
        );
    }

    /**
     * Block functions
     */
    struct PushBlock {
        uint32 chain;
        uint64 timestamp;
        uint64 blockNumber;
        bytes32 blockHash;
        bytes32 prevBlockHash;
        bytes32 merkleRoot;
        bytes32 hashRoot;
    }

    function pushBlock(PushBlock memory _block) public onlyBlockPusher {
        ChainInfo storage chain = chainInfos[_block.chain];

        // Update earliest block
        if (chain.firstBlockNum == uint64(0) || chain.firstBlockNum > _block.blockNumber) {
            chain.firstBlockNum = _block.blockNumber;
        }

        if (chain.lastBlockNum >= _block.blockNumber) {
            // In case of reorg simply remove all future blocks (optional)
            if (chain.handleReorgs) {
                handleReorg(_block.chain, _block.blockNumber);

                // If not reorg skip overriding blocks
            } else if (
                blockInfos[_block.chain][_block.blockNumber].blockNumber == _block.blockNumber
            ) {
                return;
            }
        } else {
            chain.lastBlockNum = _block.blockNumber;
        }

        // Check if we have a legit "block chain"
        BlockInfo storage prevBlock = blockInfos[_block.chain][_block.blockNumber - 1];
        require(
            prevBlock.blockHash == bytes32(0) || prevBlock.blockHash == _block.prevBlockHash,
            'Invalid block chain'
        );

        if (blockInfos[_block.chain][_block.blockNumber].timestamp == uint64(0)) {
            chain.blocks++;
        }

        blockHashNum[_block.chain][_block.blockHash] = _block.blockNumber;

        blockInfos[_block.chain][_block.blockNumber] = BlockInfo({
            blockNumber: _block.blockNumber,
            timestamp: _block.timestamp,
            blockHash: _block.blockHash,
            prevBlockHash: _block.prevBlockHash,
            merkleRoot: _block.merkleRoot,
            hashRoot: _block.hashRoot
        });

        emit Block(
            _block.chain,
            _block.blockNumber,
            _block.timestamp,
            _block.blockHash,
            _block.prevBlockHash,
            _block.merkleRoot,
            _block.hashRoot
        );
    }

    function handleReorg(uint32 chainId, uint64 blockNumber) internal {
        ChainInfo storage chain = chainInfos[chainId];

        for (uint64 i = blockNumber; i < chain.lastBlockNum + 1; ++i) {
            if (blockInfos[chainId][i].timestamp != uint64(0)) {
                delete blockInfos[chainId][i];
                chain.blocks--;
                emit RemovedBlock(chainId, i);
            }
        }
    }

    function hasBlock(uint32 chain, uint64 blockNumber) public view returns (bool) {
        return blockInfos[chain][blockNumber].timestamp != uint64(0);
    }

    function hasBlockHash(uint32 chain, bytes32 blockHash) public view returns (bool) {
        uint64 blockNumber = blockHashNum[chain][blockHash];
        return blockInfos[chain][blockNumber].blockHash == blockHash;
    }

    function getBlockByHash(
        uint32 chain,
        bytes32 blockHash
    ) public view returns (BlockInfo memory blk) {
        uint64 blockNumber = blockHashNum[chain][blockHash];
        BlockInfo storage _block = blockInfos[chain][blockNumber];
        if (_block.blockHash == blockHash) {
            blk = _block;
        }
    }

    // Pagination function
    function getBlocks(
        uint32 chain,
        uint64 start,
        uint64 count,
        bool asc
    ) external view returns (BlockInfo[] memory, uint64) {
        BlockInfo[] memory filtered = new BlockInfo[](count);
        uint64 firstIndex;
        uint64 j;

        ChainInfo memory chainInfo = chainInfos[chain];

        if (asc) {
            for (uint64 i = chainInfo.firstBlockNum + start; i < count * 100; i++) {
                BlockInfo storage blockInfo = blockInfos[chain][i];

                if (blockInfo.timestamp == uint64(0)) {
                    continue;
                }

                filtered[j] = blockInfo;

                if (j == 0) {
                    firstIndex = i;
                }

                j++;

                if (count == j) {
                    break;
                }
            }
        } else {
            for (uint64 i = chainInfo.lastBlockNum - start; i < count * 100; i--) {
                BlockInfo storage blockInfo = blockInfos[chain][i];

                if (blockInfo.timestamp == uint64(0)) {
                    continue;
                }

                filtered[j] = blockInfo;

                if (j == 0) {
                    firstIndex = i;
                }

                j++;

                if (count == j) {
                    break;
                }
            }
        }

        BlockInfo[] memory result = new BlockInfo[](j + 1);

        for (uint i; i < result.length; ++i) {
            result[i] = filtered[i];
        }

        return (result, firstIndex);
    }

    /**
     * Mint functions
     */
    struct PushMint {
        uint32 chain;
        uint64 blockNumber;
        bytes32 txid;
        uint16 txIndex;
        bytes txHex;
        bytes32[] txSiblings;
        bytes32[] hashSiblings;
        address to;
        bytes scriptPub;
        uint256 value;
        uint256 gasPrice;
        uint256 fees;
    }

    function pushMint(PushMint memory _mint) public nonReentrant {
        uint256 gasStart = gasleft();

        // Should be known chain & known block
        require(
            _mint.txid != bytes32(0) && _mint.txHex.length != 0 && _mint.scriptPub.length != 0,
            'Invalid tx'
        );
        require(_mint.gasPrice < 10 gwei, 'Invalid gas price');

        BlockInfo memory _block = blockInfos[_mint.chain][_mint.blockNumber];
        bytes32 txHash = BTCBridgeLib.hashTx(_mint.txHex);

        require(_block.timestamp != 0, 'Invalid block');
        // Check if tx is already mined (to prevent double spend)
        require(
            !hasMintTx(_mint.chain, _mint.txid) && !hasMintHash(_mint.chain, txHash),
            'Duplicated tx'
        );
        require(
            BTCBridgeLib.checkBtcMerkleProof(
                txHash,
                _mint.hashSiblings,
                _mint.txIndex,
                _block.hashRoot
            ),
            'Invalid merkle'
        );
        require(
            BTCBridgeLib.checkBtcMerkleProof(
                _mint.txid,
                _mint.txSiblings,
                _mint.txIndex,
                _block.merkleRoot
            ),
            'Invalid hex merkle'
        );
        require(
            ((chainInfos[_mint.chain].depositScriptPub == sha256(_mint.scriptPub)) || isDebug) &&
                BTCBridgeLib.hasOutput(_mint.txHex, toBTCValue(_mint.value), _mint.scriptPub),
            'Invalid output'
        );
        require(
            BTCBridgeLib.hasOpReturnOutput(_mint.txHex, abi.encodePacked(_mint.to)) || isDebug,
            'Invalid to'
        );

        // Mint / Transfer bridged tokens here
        {
            IERC20Mintable token = chainInfos[_mint.chain].token;
            uint256 value = _mint.value - _mint.fees;

            if (address(token) == address(0)) {
                nativeTransfer.transfer(_mint.to, value);
                nativeTransfer.transfer(msg.sender, _mint.fees);
            } else {
                token.mint(_mint.to, value);
                token.mint(msg.sender, _mint.fees);
            }

            if (chainInfos[_mint.chain].lastMint < _mint.blockNumber) {
                chainInfos[_mint.chain].lastMint = _mint.blockNumber;
            }
        }

        uint64 index = uint64(mintInfos[_mint.chain].length);

        mintIndex[_mint.chain][_mint.txid] = index;
        mintIndex[_mint.chain][txHash] = index;

        mintInfos[_mint.chain].push(
            MintInfo({
                blockNumber: _mint.blockNumber,
                timestamp: _block.timestamp,
                txid: _mint.txid,
                txHash: txHash,
                mintTx: bytes32(0),
                txIndex: _mint.txIndex,
                to: _mint.to,
                value: _mint.value,
                fees: _mint.fees
            })
        );

        emit Mint(
            _mint.chain,
            index,
            _mint.blockNumber,
            _block.timestamp,
            _mint.txid,
            txHash,
            _mint.txIndex,
            _mint.to,
            _mint.value,
            _mint.fees,
            _mint.txHex
        );

        uint256 estFees = calculateFee(
            chainInfos[_mint.chain].tokenPriceCalculator,
            _mint.gasPrice,
            gasStart - gasleft(),
            400_000
        );
        require(_mint.fees < estFees, 'Invalid fees');
    }

    struct PushMintTx {
        uint32 chain;
        uint64 index;
        bytes32 mintTx;
    }

    function pushMintTxs(PushMintTx[] memory mintTxs) external onlyBlockPusher {
        for (uint i; i < mintTxs.length; ++i) {
            PushMintTx memory mintTx = mintTxs[i];
            mintInfos[mintTx.chain][mintTx.index].mintTx = mintTx.mintTx;
        }
    }

    function pushBlockMints(PushBlock[] memory blocks, PushMint[] memory mints) external {
        for (uint i; i < blocks.length; ++i) {
            pushBlock(blocks[i]);
        }
        for (uint i; i < mints.length; ++i) {
            pushMint(mints[i]);
        }
    }

    function hasMintTx(uint32 chain, bytes32 txid) public view returns (bool) {
        uint64 index = mintIndex[chain][txid];
        return mintInfos[chain].length != 0 && mintInfos[chain][index].txid == txid;
    }

    function hasMintHash(uint32 chain, bytes32 txHash) public view returns (bool) {
        uint64 index = mintIndex[chain][txHash];
        return mintInfos[chain].length != 0 && mintInfos[chain][index].txHash == txHash;
    }

    function getMintInfo(uint32 chain, bytes32 txid) public view returns (MintInfo memory) {
        uint64 index = mintIndex[chain][txid];
        return mintInfos[chain][index];
    }

    function getMintInfoByIndex(uint32 chain, uint64 index) public view returns (MintInfo memory) {
        return mintInfos[chain][index];
    }

    function getMintInfosLength(uint32 chain) public view returns (uint64) {
        return uint64(mintInfos[chain].length);
    }

    // Pagination function
    function getMintInfos(
        uint32 chain,
        uint64 start,
        uint64 count,
        bool asc
    ) external view returns (MintInfo[] memory, uint64) {
        MintInfo[] storage infos = mintInfos[chain];
        uint64 total = uint64(infos.length);
        if (start >= total) {
            return (new MintInfo[](0), 0);
        }
        uint64 end = start + count;
        if (end > total) {
            end = total;
        }
        uint64 resultCount = end - start;
        MintInfo[] memory result = new MintInfo[](resultCount);
        uint64 firstIndex;

        for (uint64 i = 0; i < resultCount; i++) {
            if (asc) {
                result[i] = infos[start + i];

                if (i == 0) {
                    firstIndex = start + i;
                }
            } else {
                result[i] = infos[end - 1 - i];

                if (i == 0) {
                    firstIndex = end - 1 - i;
                }
            }
        }

        return (result, firstIndex);
    }

    /**
     * Burn functions
     */
    struct RequestBurn {
        uint32 chain;
        string to;
        uint256 value;
        uint256 fees;
        uint256 deadline;
        bytes signature;
    }

    function requestBurn(RequestBurn memory _burn) public payable nonReentrant {
        ChainInfo storage chain = chainInfos[_burn.chain];

        require(chain.depositScriptPub != bytes32(0), 'Invalid chain');
        require(_burn.value > _burn.fees, 'Invalid value');
        require(_burn.fees != 0, 'Invalid fees');

        // Native transfers
        if (address(chain.token) == address(0)) {
            require(msg.value == _burn.value, 'Invalid msg value');

            // Token transfers
        } else {
            // Permit
            if (_burn.signature.length != 0) {
                (uint8 v, bytes32 r, bytes32 s) = SigLib.toVRS(_burn.signature);

                chain.token.permit(msg.sender, address(this), _burn.value, _burn.deadline, v, r, s);
            }

            chain.token.transferFrom(msg.sender, address(this), _burn.value);
        }

        uint64 index = uint64(burnInfos[_burn.chain].length);

        burnInfos[_burn.chain].push(
            BurnInfo({
                blockNumber: uint64(0),
                timestamp: uint64(0),
                txid: bytes32(0),
                burnTx: bytes32(0),
                txIndex: uint16(0),
                from: msg.sender,
                to: _burn.to,
                value: _burn.value,
                fees: _burn.fees
            })
        );

        emit BurnRequested(
            _burn.chain,
            index,
            uint64(block.timestamp),
            _burn.to,
            _burn.value,
            _burn.fees
        );
    }

    struct PushBurn {
        uint32 chain;
        uint64 index;
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 txid;
        bytes32 burnTx;
        uint16 txIndex;
    }

    function pushBurn(PushBurn memory _burn) public onlyBlockPusher {
        ChainInfo storage chain = chainInfos[_burn.chain];
        require(chain.depositScriptPub != bytes32(0), 'Invalid chain');

        BurnInfo storage burn = burnInfos[_burn.chain][_burn.index];
        uint256 value = burn.value - burn.fees;

        // Native transfers
        if (address(chain.token) == address(0)) {
            bool success;
            bytes memory returnData;

            (success, returnData) = address(nativeTransfer).call{ value: value }('');
            if (!success) {
                assembly {
                    revert(add(32, returnData), mload(returnData))
                }
            }

            (success, returnData) = msg.sender.call{ value: burn.fees }('');
            if (!success) {
                assembly {
                    revert(add(32, returnData), mload(returnData))
                }
            }

            // Token transfers
        } else {
            chain.token.burn(value);
            chain.token.transfer(msg.sender, burn.fees);
        }

        if (chain.lastBurn < _burn.blockNumber) {
            chain.lastBurn = _burn.blockNumber;
        }

        burnIndex[_burn.chain][_burn.txid] = _burn.index;
        burnIndex[_burn.chain][_burn.burnTx] = _burn.index;

        burn.blockNumber = _burn.blockNumber;
        burn.timestamp = _burn.timestamp;
        burn.txid = _burn.txid;
        burn.burnTx = _burn.burnTx;
        burn.txIndex = _burn.txIndex;

        emit Burn(
            _burn.chain,
            _burn.index,
            _burn.blockNumber,
            _burn.timestamp,
            _burn.txid,
            _burn.burnTx,
            _burn.txIndex
        );
    }

    function pushBurns(PushBurn[] memory burns) external {
        for (uint i; i < burns.length; ++i) {
            pushBurn(burns[i]);
        }
    }

    function hasBurnTx(uint32 chain, bytes32 burnTx) public view returns (bool) {
        uint64 index = burnIndex[chain][burnTx];
        return burnInfos[chain].length != 0 && burnInfos[chain][index].burnTx == burnTx;
    }

    function getBurnInfo(uint32 chain, bytes32 burnTx) public view returns (BurnInfo memory) {
        uint64 index = burnIndex[chain][burnTx];
        return burnInfos[chain][index];
    }

    function getBurnInfoByIndex(uint32 chain, uint64 index) public view returns (BurnInfo memory) {
        return burnInfos[chain][index];
    }

    function getBurnInfosLength(uint32 chain) public view returns (uint64) {
        return uint64(burnInfos[chain].length);
    }

    // Pagination function
    function getBurnInfos(
        uint32 chain,
        uint64 start,
        uint64 count,
        bool asc
    ) external view returns (BurnInfo[] memory, uint64) {
        BurnInfo[] storage infos = burnInfos[chain];
        uint64 total = uint64(infos.length);
        if (start >= total) {
            return (new BurnInfo[](0), 0);
        }
        uint64 end = start + count;
        if (end > total) {
            end = total;
        }
        uint64 resultCount = end - start;
        BurnInfo[] memory result = new BurnInfo[](resultCount);
        uint64 firstIndex;

        for (uint64 i = 0; i < resultCount; i++) {
            if (asc) {
                result[i] = infos[start + i];

                if (i == 0) {
                    firstIndex = start + i;
                }
            } else {
                result[i] = infos[end - 1 - i];

                if (i == 0) {
                    firstIndex = end - 1 - i;
                }
            }
        }

        return (result, firstIndex);
    }

    function toBTCValue(uint256 value) public pure returns (uint64) {
        return uint64(value / 10 ** (18 - 6));
    }

    function fromBTCValue(uint64 value) public pure returns (uint256) {
        return uint256(value * 10 ** (18 - 6));
    }

    function calculateFee(
        ITokenPriceCalculator tokenCalculator,
        uint256 gasPrice,
        uint256 gasLimit,
        uint256 gasOverhead
    ) public view returns (uint256) {
        uint256 gasCost = (block.basefee + gasPrice) * (gasLimit + gasOverhead);

        if (address(tokenCalculator) == address(0)) {
            return gasCost;
        } else {
            return tokenCalculator.convert(gasCost);
        }
    }

    /**
     * From role libraries
     */
    function owner() public view returns (address) {
        return OwnableLib.owner();
    }

    function transferOwnership(address newOwner) public {
        OwnableLib.transferOwnership(newOwner);
    }

    function blockPushers() public view returns (address[] memory) {
        return GroupLib.members(BLKPUSH);
    }

    function blockPushersLength() public view returns (uint256) {
        return GroupLib.membersLength(BLKPUSH);
    }

    function addBlockPushers(address pusher) external {
        GroupLib.addMember(BLKPUSH, pusher);
    }

    function removeBlockPushers(address pusher) external {
        GroupLib.removeMember(BLKPUSH, pusher);
    }
}
