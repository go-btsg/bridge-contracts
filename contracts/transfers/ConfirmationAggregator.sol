// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./AggregatorBase.sol";
import "../interfaces/IConfirmationAggregator.sol";
import "../periphery/WrappedAsset.sol";

contract ConfirmationAggregator is AggregatorBase, IConfirmationAggregator {
    /* ========== STATE VARIABLES ========== */

    uint8 public confirmationThreshold; // required confirmations per block after extra check enabled
    uint8 public excessConfirmations; // minimal required confirmations in case of too many confirmations
    address public wrappedAssetAdmin; // admin for any deployed wrapped asset
    address public bridgeAddress; // Bridge gate address

    mapping(bytes32 => bytes32) public confirmedDeployInfo; // bridge Id => deploy Id
    mapping(bytes32 => BridgeDeployInfo) public getDeployInfo; // mint id => bridge info
    mapping(bytes32 => address) public override getWrappedAssetAddress; // bridge id => wrapped asset address
    mapping(bytes32 => SubmissionInfo) public getSubmissionInfo; // mint id => submission info

    uint40 public submissionsInBlock; //submissions count in current block
    uint40 public currentBlock; //Current block

    /* ========== MODIFIERS ========== */

    modifier onlyBridgeGate() {
        if (msg.sender != bridgeAddress) revert BridgeGateBadRole();
        _;
    }

    /* ========== CONSTRUCTOR  ========== */

    /// @dev Constructor that initializes the most important configurations.
    /// @param _minConfirmations Common confirmations count.
    /// @param _confirmationThreshold Confirmations per block after extra check enabled.
    /// @param _excessConfirmations Confirmations count in case of excess activity.
    function initialize(
        uint8 _minConfirmations,
        uint8 _confirmationThreshold,
        uint8 _excessConfirmations,
        address _wrappedAssetAdmin,
        address _bridgeAddress
    ) public initializer {
        AggregatorBase.initializeBase(_minConfirmations);
        confirmationThreshold = _confirmationThreshold;
        excessConfirmations = _excessConfirmations;
        wrappedAssetAdmin = _wrappedAssetAdmin;
        bridgeAddress = _bridgeAddress;
    }

    /* ========== ORACLES  ========== */

    /// @dev Confirms few transfer requests.
    /// @param _submissionIds Submission identifiers.
    function submitMany(bytes32[] memory _submissionIds) external override onlyOracle {
        for (uint256 i; i < _submissionIds.length; i++) {
            _submit(_submissionIds[i]);
        }
    }

    /// @dev Confirms the transfer request.
    function confirmNewAsset(
        bytes memory _tokenAddress,
        uint256 _chainId,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) external onlyOracle {
        bytes32 bridgeId = getBridgeId(_chainId, _tokenAddress);
        if (getWrappedAssetAddress[bridgeId] != address(0)) revert DeployedAlready();

        bytes32 deployId = getDeployId(bridgeId, _name, _symbol, _decimals);
        BridgeDeployInfo storage bridgeInfo = getDeployInfo[deployId];
        if (bridgeInfo.hasVerified[msg.sender]) revert SubmittedAlready();

        bridgeInfo.name = _name;
        bridgeInfo.symbol = _symbol;
        bridgeInfo.nativeAddress = _tokenAddress;
        bridgeInfo.chainId = _chainId;
        bridgeInfo.decimals = _decimals;
        bridgeInfo.confirmations += 1;
        if (getOracleInfo[msg.sender].required) {
            bridgeInfo.requiredConfirmations += 1;
        }
        bridgeInfo.hasVerified[msg.sender] = true;

        if (bridgeInfo.confirmations >= minConfirmations) {
            confirmedDeployInfo[bridgeId] = deployId;
        }

        emit DeployConfirmed(deployId, msg.sender);
    }

    /// @dev Confirms the transfer request.
    /// @param _submissionId Submission identifier.
    function submit(bytes32 _submissionId) external override onlyOracle {
        _submit(_submissionId);
    }

    /// @dev Confirms single transfer request.
    /// @param _submissionId Submission identifier.
    function _submit(bytes32 _submissionId) internal {
        SubmissionInfo storage submissionInfo = getSubmissionInfo[_submissionId];
        if (submissionInfo.hasVerified[msg.sender]) revert SubmittedAlready();

        submissionInfo.confirmations += 1;
        if (getOracleInfo[msg.sender].required) {
            submissionInfo.requiredConfirmations += 1;
        }
        submissionInfo.hasVerified[msg.sender] = true;
        if (submissionInfo.confirmations >= minConfirmations) {
            if (currentBlock != uint40(block.number)) {
                currentBlock = uint40(block.number);
                submissionsInBlock = 0;
            }
            bool requireExtraCheck = submissionsInBlock >= confirmationThreshold;

            if (
                submissionInfo.requiredConfirmations >= requiredOraclesCount &&
                !submissionInfo.isConfirmed &&
                (!requireExtraCheck ||
                    (requireExtraCheck && submissionInfo.confirmations >= excessConfirmations))
            ) {
                submissionsInBlock += 1;
                submissionInfo.isConfirmed = true;
                emit SubmissionApproved(_submissionId);
            }
        }
        emit Confirmed(_submissionId, msg.sender);
    }

    /* ========== deployAsset ========== */

    /// @dev deploy wrapped token, called by BridgeGate.
    function deployAsset(bytes32 _bridgeId)
        external
        override
        onlyBridgeGate
        returns (
            address wrappedAssetAddress,
            bytes memory nativeAddress,
            uint256 nativeChainId
        )
    {
        if (getWrappedAssetAddress[_bridgeId] != address(0)) revert DeployedAlready();
        bytes32 deployId = confirmedDeployInfo[_bridgeId];
        if (deployId == "") revert DeployNotFound();

        BridgeDeployInfo storage bridgeInfo = getDeployInfo[deployId];
        address[] memory minters = new address[](1);
        minters[0] = bridgeAddress;
        WrappedAsset wrappedAsset = new WrappedAsset(
            bridgeInfo.name,
            bridgeInfo.symbol,
            bridgeInfo.decimals,
            wrappedAssetAdmin,
            minters
        );
        getWrappedAssetAddress[_bridgeId] = address(wrappedAsset);
        emit DeployApproved(deployId);
        return (address(wrappedAsset), bridgeInfo.nativeAddress, bridgeInfo.chainId);
    }

    /* ========== ADMIN ========== */

    /// @dev Sets minimal required confirmations.
    /// @param _excessConfirmations Confirmation info.
    function setExcessConfirmations(uint8 _excessConfirmations) public onlyAdmin {
        excessConfirmations = _excessConfirmations;
    }

    /// @dev Sets minimal required confirmations.
    /// @param _confirmationThreshold Confirmation info.
    function setThreshold(uint8 _confirmationThreshold) public onlyAdmin {
        confirmationThreshold = _confirmationThreshold;
    }

    /// @dev Set admin for any deployed wrapped asset.
    /// @param _wrappedAssetAdmin Admin address.
    function setWrappedAssetAdmin(address _wrappedAssetAdmin) public onlyAdmin {
        wrappedAssetAdmin = _wrappedAssetAdmin;
    }

    /// @dev Sets core bridge conrtact address.
    /// @param _bridgeAddress Bridge address.
    function setBridgeAddress(address _bridgeAddress) public onlyAdmin {
        bridgeAddress = _bridgeAddress;
    }

    /* ========== VIEW ========== */

    /// @dev Returns whether transfer request is confirmed.
    /// @param _submissionId Submission identifier.
    /// @return _confirmations number of confirmation.
    /// @return _isConfirmed is confirmed sumbission.
    function getSubmissionConfirmations(bytes32 _submissionId)
        external
        view
        override
        returns (uint8 _confirmations, bool _isConfirmed)
    {
        SubmissionInfo storage submissionInfo = getSubmissionInfo[_submissionId];

        return (submissionInfo.confirmations, submissionInfo.isConfirmed);
    }
}
