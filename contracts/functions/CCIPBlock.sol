// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CCIPReceiver } from '@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol';
import { Client } from '@chainlink/contracts-ccip/contracts/libraries/Client.sol';

contract CCIPBlock is CCIPReceiver {
    uint64 public ccipChain;
    address public ccipFunctions;

    address public btcBridge;

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        bytes data // The data that was received.
    );

    constructor(
        address _router,
        uint64 _ccipChain,
        address _ccipFunctions,
        address _btcBridge
    ) CCIPReceiver(_router) {
        ccipChain = _ccipChain;
        ccipFunctions = _ccipFunctions;
        btcBridge = _btcBridge;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        address srcSender = abi.decode(any2EvmMessage.sender, (address));

        require(any2EvmMessage.sourceChainSelector == ccipChain, 'Invalid chain');
        require(srcSender == ccipFunctions, 'Invalid sender');

        if (btcBridge != address(0)) {
            (bool success, bytes memory returnData) = btcBridge.call(any2EvmMessage.data);

            /**
             * For production
            if (!success) {
                assembly {
                    revert(add(32, returnData), mload(returnData))
                }
            }
            **/
        }

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            srcSender, // abi-decoding of the sender address,
            any2EvmMessage.data
        );
    }
}
