// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./AggregatorBase.sol";
import "../interfaces/ISignatureVerifier.sol";
import "../periphery/WrappedAsset.sol";
import "../libraries/SignatureUtil.sol";

contract SignatureVerifier is AggregatorBase, ISignatureVerifier {
    using SignatureUtil for bytes;
    using SignatureUtil for bytes32;

    /* ========== STATE VARIABLES ========== */

    uint8 public confirmationThreshold; // required confirmations per block after extra check enabled
    uint8 public excessConfirmations; // minimal required confirmations in case of too many confirmations

    uint40 public submissionsInBlock; //submissions count in current block
    uint40 public currentBlock; //Current block

    address public wrappedAssetAdmin; // admin for any deployed wrapped asset
    address public bridgeAddress; // Bridge gate address

    mapping(bytes32 => bytes32) public confirmedDeployInfo; // bridge Id => deploy Id
    mapping(bytes32 => BridgeDeployInfo) public getDeployInfo; // mint id => bridge info
    mapping(bytes32 => address) public override getWrappedAssetAddress; // bridge id => wrapped asset address

    /* ========== ERRORS ========== */

    error NotConfirmedByRequiredOracles();
    error NotConfirmedThreshold();
    error SubmissionNotConfirmed();
    error DuplicateSignatures();

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

    /// @dev Confirms the transfer request.
    function confirmNewAsset(
        bytes memory _tokenAddress,
        uint256 _chainId,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        bytes memory _signatures
    ) external {
        bytes32 bridgeId = getBridgeId(_chainId, _tokenAddress);
        if (getWrappedAssetAddress[bridgeId] != address(0)) revert DeployedAlready();

        bytes32 deployId = getDeployId(bridgeId, _name, _symbol, _decimals);
        BridgeDeployInfo storage bridgeInfo = getDeployInfo[deployId];
        bridgeInfo.name = _name;
        bridgeInfo.symbol = _symbol;
        bridgeInfo.nativeAddress = _tokenAddress;
        bridgeInfo.chainId = _chainId;
        bridgeInfo.decimals = _decimals;

        // Count of required(DSRM) oracles confirmation
        uint256 currentRequiredOraclesCount;
        // stack variable to aggregate confirmations and write to storage once
        uint8 confirmations = bridgeInfo.confirmations;

        uint256 signaturesCount = _countSignatures(_signatures);
        address[] memory validators = new address[](signaturesCount);
        for (uint256 i = 0; i < signaturesCount; i++) {
            (bytes32 r, bytes32 s, uint8 v) = _signatures.parseSignature(i * 65);
            address oracle = ecrecover(deployId.getUnsignedMsg(), v, r, s);
            if (getOracleInfo[oracle].isValid) {
                for (uint256 k = 0; k < i; k++) {
                    if (validators[k] == oracle) revert DuplicateSignatures();
                }
                validators[i] = oracle;
                emit DeployConfirmed(deployId, oracle);
                confirmations += 1;
                if (getOracleInfo[oracle].required) {
                    currentRequiredOraclesCount += 1;
                }
            }
        }

        if (confirmations < minConfirmations) revert DeployNotConfirmed();
        if (currentRequiredOraclesCount != requiredOraclesCount)
            revert NotConfirmedByRequiredOracles();

        bridgeInfo.confirmations = confirmations;
        confirmedDeployInfo[bridgeId] = deployId;
    }

    /// @dev Confirms the mint request.
    /// @param _submissionId Submission identifier.
    /// @param _signatures Array of signatures by oracles.
    function submit(
        bytes32 _submissionId,
        bytes memory _signatures,
        uint8 _excessConfirmations
    ) external override onlyBridgeGate {
        //Need confirmation to confirm submission
        uint8 needConfirmations = _excessConfirmations > minConfirmations
            ? _excessConfirmations
            : minConfirmations;
        // Count of required(DSRM) oracles confirmation
        uint256 currentRequiredOraclesCount;
        // stack variable to aggregate confirmations and write to storage once
        uint8 confirmations;
        uint256 signaturesCount = _countSignatures(_signatures);
        address[] memory validators = new address[](signaturesCount);
        for (uint256 i = 0; i < signaturesCount; i++) {
            (bytes32 r, bytes32 s, uint8 v) = _signatures.parseSignature(i * 65);
            address oracle = ecrecover(_submissionId.getUnsignedMsg(), v, r, s);
            if (getOracleInfo[oracle].isValid) {
                for (uint256 k = 0; k < i; k++) {
                    if (validators[k] == oracle) revert DuplicateSignatures();
                }
                validators[i] = oracle;

                confirmations += 1;
                emit Confirmed(_submissionId, oracle);
                if (getOracleInfo[oracle].required) {
                    currentRequiredOraclesCount += 1;
                }
                if (
                    confirmations >= needConfirmations &&
                    currentRequiredOraclesCount >= requiredOraclesCount
                ) {
                    break;
                }
            }
        }

        if (currentRequiredOraclesCount != requiredOraclesCount)
            revert NotConfirmedByRequiredOracles();

        if (confirmations >= minConfirmations) {
            if (currentBlock == uint40(block.number)) {
                submissionsInBlock += 1;
            } else {
                currentBlock = uint40(block.number);
                submissionsInBlock = 1;
            }
            emit SubmissionApproved(_submissionId);
        }

        if (submissionsInBlock > confirmationThreshold) {
            if (confirmations < excessConfirmations) revert NotConfirmedThreshold();
        }

        if (confirmations < needConfirmations) revert SubmissionNotConfirmed();
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

    /// @dev Check is valid signature
    /// @param _submissionId Submission identifier.
    /// @param _signature signature by oracle.
    function isValidSignature(bytes32 _submissionId, bytes memory _signature)
        external
        view
        returns (bool)
    {
        (bytes32 r, bytes32 s, uint8 v) = _signature.splitSignature();
        address oracle = ecrecover(_submissionId.getUnsignedMsg(), v, r, s);
        return getOracleInfo[oracle].isValid;
    }

    /* ========== INTERNAL ========== */

    function _countSignatures(bytes memory _signatures) internal pure returns (uint256) {
        return _signatures.length % 65 == 0 ? _signatures.length / 65 : 0;
    }
}
