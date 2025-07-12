// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    AutomationCompatible
} from '@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol';
import { WithSettler } from '../common/WithSettler.sol';
import { FunctionsClient } from './FunctionsClient.sol';

/**
 * @title Functions Consumer contract used for Chainlink Automation.
 */
contract BaseFunctionsConsumer is FunctionsClient, AutomationCompatible, WithSettler {
    /**
     * @dev Chainlink Settings
     */
    address public upkeepContract;
    bytes public request;
    uint64 public subscriptionId;
    uint32 public gasLimit;
    bytes32 public donID;
    bytes32 public s_lastRequestId;

    error UnexpectedRequestID(bytes32 requestId);

    event SetConsumer(address indexed router, address indexed upkeepContract);
    event Response(bytes32 indexed requestId, bytes response, bytes err);

    /**
     * @notice Reverts if called by anyone other than the contract owner or automation registry.
     */
    modifier onlyUpkeep() {
        require(msg.sender == owner() || msg.sender == upkeepContract, 'NotAllowedCaller');
        _;
    }

    function setConsumer(address _router, address _upkeepContract) public onlyOwner {
        _initializeFuncClient(_router);
        upkeepContract = _upkeepContract;

        emit SetConsumer(_router, _upkeepContract);
    }

    /// @notice Update the request settings
    /// @dev Only callable by the owner of the contract
    /// @param _request The new encoded CBOR request to be set. The request is encoded offchain
    /// @param _subscriptionId The new subscription ID to be set
    /// @param _gasLimit The new gas limit to be set
    /// @param _donID The new job ID to be set
    function updateRequest(
        bytes memory _request,
        uint64 _subscriptionId,
        uint32 _gasLimit,
        bytes32 _donID
    ) public onlyOwner {
        request = _request;
        subscriptionId = _subscriptionId;
        gasLimit = _gasLimit;
        donID = _donID;
    }

    /**
     * @dev Upkeep settings
     * Use this when custom upkeep is enabled
     */
    function _checkUpkeepCondition() internal view virtual returns (bool) {
        return false;
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        cannotExecute
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        return (_checkUpkeepCondition(), new bytes(0));
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        if (_checkUpkeepCondition()) {
            s_lastRequestId = _sendRequest(request, subscriptionId, gasLimit, donID);
        }
    }

    /**
     * @notice Send a pre-encoded CBOR request
     * @return requestId The ID of the sent request
     */
    function sendRequestCBOR() external onlyUpkeep returns (bytes32 requestId) {
        s_lastRequestId = _sendRequest(request, subscriptionId, gasLimit, donID);
        return s_lastRequestId;
    }

    function handleResponse(bytes memory response) internal virtual {}

    /**
     * @notice Store latest result/error
     * @param requestId The request ID, returned by sendRequest()
     * @param response Aggregated response from the user code
     * @param err Aggregated error from the user code or from the execution pipeline
     * Either response or error parameter will be set, but never both
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId);
        }
        if (response.length != 0 && err.length == 0) {
            handleResponse(response);
        }
        emit Response(requestId, response, err);
    }
}
