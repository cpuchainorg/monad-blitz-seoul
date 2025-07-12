// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IRouterClient } from '@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol';
import { Client } from '@chainlink/contracts-ccip/contracts/libraries/Client.sol';
import { BaseFunctionsConsumer } from './BaseFunctionsConsumer.sol';
import { IERC20 } from '../interfaces/IERC20.sol';

contract CCIPFunctions is BaseFunctionsConsumer {
    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        bytes data, // The data being sent.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

    IERC20 public LINK;
    IRouterClient public router;
    uint64 public destChain;
    address public btcBridge;

    uint256 public latestBlockNumber;
    uint256 public latestTimestamp;

    mapping(uint256 => uint256) public timestamps;

    function initializeFunctions(
        address owner,
        IERC20 _LINK,
        IRouterClient _router,
        uint64 _destChain,
        address _btcBridge
    ) external initializer {
        _initialize(owner);

        LINK = _LINK;
        router = _router;
        destChain = _destChain;
        btcBridge = _btcBridge;
    }

    struct BlockInfo {
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 blockHash;
        bytes32 prevBlockHash;
        bytes32 merkleRoot;
        bytes32 hashRoot;
    }

    function handleResponse(bytes memory funcData) internal override {
        _handleResponse(funcData);
    }

    function pushResponse(bytes memory funcData) external onlySettlers {
        _handleResponse(funcData);
    }

    function _handleResponse(bytes memory funcData) internal {
        // Allocate a new bytes array with the selector skipped
        bytes memory params = new bytes(funcData.length - 4);

        for (uint i = 0; i < params.length; i++) {
            params[i] = funcData[i + 4];
        }

        BlockInfo memory _block = abi.decode(params, (BlockInfo));

        if (latestTimestamp > _block.timestamp) {
            return;
        }

        latestTimestamp = _block.timestamp;
        latestBlockNumber = _block.blockNumber;

        timestamps[_block.blockNumber] = _block.timestamp;

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(btcBridge), // ABI-encoded receiver address
            data: funcData, // ABI-encoded string
            tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array as no tokens are transferred
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit and allowing out-of-order execution.
                // Best Practice: For simplicity, the values are hardcoded. It is advisable to use a more dynamic approach
                // where you set the extra arguments off-chain. This allows adaptation depending on the lanes, messages,
                // and ensures compatibility with future CCIP upgrades. Read more about it here: https://docs.chain.link/ccip/concepts/best-practices/evm#using-extraargs
                Client.GenericExtraArgsV2({
                    gasLimit: 300_000, // Gas limit for the callback on the destination chain
                    allowOutOfOrderExecution: true // Allows the message to be executed out of order relative to other messages from the same sender
                })
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
            feeToken: address(LINK)
        });

        uint256 fees = router.getFee(destChain, evm2AnyMessage);

        LINK.approve(address(router), fees);

        bytes32 messageId = router.ccipSend(destChain, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(messageId, destChain, btcBridge, funcData, address(LINK), fees);
    }

    function toHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory HEX_SYMBOLS = '0123456789abcdef';
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = HEX_SYMBOLS[uint8(data[i] >> 4)];
            str[3 + i * 2] = HEX_SYMBOLS[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
