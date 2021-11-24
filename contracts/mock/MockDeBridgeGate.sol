// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../transfers/BridgeGate.sol";

contract MockBridgeGate is BridgeGate {
    uint256 public chainId;

    /* ========== CONSTRUCTOR  ========== */

    /// @dev Constructor that initializes the most important configurations.
    /// @param _signatureVerifier Aggregator address to verify signatures
    /// @param _confirmationAggregator Aggregator address to verify by oracles confirmations
    /// @param _supportedChainIds Chain ids where native token of the current chain can be wrapped.
    /// @param _treasury Address to collect a fee
    function initializeMock(
        uint8 _excessConfirmations,
        address _signatureVerifier,
        address _confirmationAggregator,
        address _callProxy,
        uint256[] memory _supportedChainIds,
        ChainSupportInfo[] memory _chainSupportInfo,
        IWETH _weth,
        address _feeProxy,
        IDefiController _defiController,
        address _treasury,
        uint256 overrideChainId
    ) public initializer {
        // BridgeGate.initialize(_excessConfirmations,
        // _signatureVerifier,
        // _confirmationAggregator,
        // _callProxy,
        // _supportedChainIds,
        // _chainSupportInfo,
        // _weth,
        // _feeProxy,
        // _defiController,
        // _treasury);

        chainId = overrideChainId;
        _addAsset(
            getBridgeId(chainId, address(_weth)),
            address(_weth),
            abi.encodePacked(address(_weth)),
            chainId
        );
        for (uint256 i = 0; i < _supportedChainIds.length; i++) {
            getChainSupport[_supportedChainIds[i]] = _chainSupportInfo[i];
        }

        signatureVerifier = _signatureVerifier;
        confirmationAggregator = _confirmationAggregator;

        callProxyAddresses[0] = _callProxy;
        defiController = _defiController;
        excessConfirmations = _excessConfirmations;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

        weth = _weth;
        feeProxy = _feeProxy;
        treasury = _treasury;

        flashFeeBps = 10;
    }

    // return overrided chain id
    function getChainId() public view override returns (uint256 cid) {
        return chainId;
    }

    /// @dev Calculate submission id.
    /// @param _bridgeId Asset identifier.
    /// @param _chainIdFrom Chain identifier of the chain where tokens are sent from.
    /// @param _chainIdTo Chain identifier of the chain where tokens are sent to.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _nonce Submission id.
    function getSubmissionId(
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        uint256 _chainIdTo,
        uint256 _amount,
        address _receiver,
        uint256 _nonce
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(_bridgeId, _chainIdFrom, _chainIdTo, _amount, _receiver, _nonce)
            );
    }

    // function getEncodePackedFROM(
    //     bytes memory _nativeSender,
    //     bytes32 _bridgeId,
    //     uint256 _chainIdFrom,
    //     uint256 _amount,
    //     address _receiver,
    //     uint256 _nonce,//hello
    //     address _fallbackAddress,
    //     uint256 _executionFee,
    //     bytes memory _data
    // ) public view returns (bytes memory) {
    //     return
    //             abi.encodePacked(
    //                 // To avoid error:
    //                 // Variable value0 is 1 slot(s) too deep inside the stack.
    //                 abi.encodePacked(
    //                     //TODO: ALARM CHECK that we have the same abi.encodePacked from and TO getAutoSubmissionIdTo
    //                     _nativeSender,
    //                     _bridgeId,
    //                     _chainIdFrom
    //                 ),
    //                 getChainId(),//_chainIdTo,
    //                 _amount,
    //                 _receiver,
    //                 _nonce,
    //                 _fallbackAddress,
    //                 _executionFee,
    //                 _data
    //             );
    // }

    // function getEncodePackedTO(
    //     bytes32 _bridgeId,
    //     uint256 _chainIdTo,
    //     uint256 _amount,
    //     bytes memory _receiver,
    //     // uint256 _nonce,
    //     bytes memory _fallbackAddress,
    //     uint256 _executionFee,
    //     bytes memory _data
    // ) public view returns  (bytes memory) {
    //     return
    //             abi.encodePacked(
    //                 address(this), // only for test
    //                 // msg.sender,
    //                 _bridgeId,
    //                 getChainId(),
    //                 _chainIdTo,
    //                 _amount,
    //                 _receiver,
    //                 nonce, //_nonce,
    //                 _fallbackAddress,
    //                 _executionFee,
    //                 _data
    //             );
    // }
}
