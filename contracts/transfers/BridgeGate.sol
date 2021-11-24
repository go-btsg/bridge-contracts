// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../interfaces/IWrappedAsset.sol";
import "../interfaces/ISignatureVerifier.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IBridgeGate.sol";
import "../interfaces/IDefiController.sol";
import "../interfaces/IConfirmationAggregator.sol";
import "../interfaces/ICallProxy.sol";
import "../interfaces/IFlashCallback.sol";
import "../libraries/SignatureUtil.sol";

contract BridgeGate is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IBridgeGate
{
    using SafeERC20 for IERC20;
    using SignatureUtil for bytes;

    /* ========== STATE VARIABLES ========== */

    // Basis points or bps equal to 1/10000
    // used to express relative values (fees)
    uint256 public constant BPS_DENOMINATOR = 10000;
    bytes32 public constant GOVMONITORING_ROLE = keccak256("GOVMONITORING_ROLE"); // role allowed to stop transfers
    uint256 public constant PROXY_WITH_SENDER_FLAG = 100; //Flag to call proxy with sender contract

    address public signatureVerifier; // current signatureVerifier address to verify signatures
    address public confirmationAggregator; // current aggregator address to verify by oracles confirmations
    address public treasury; //address of treasury
    uint8 public excessConfirmations; // minimal required confirmations in case of too many confirmations
    uint256 public flashFeeBps; // fee in basis points (1/10000)
    uint256 public nonce; //outgoing submissions count

    mapping(uint256 => address) public callProxyAddresses; // proxy to execute user's calls
    mapping(bytes32 => BridgeInfo) public getBridge; // bridgeId (i.e. hash(native chainId, native tokenAddress)) => token
    mapping(bytes32 => BridgeFeeInfo) public getBridgeFeeInfo;
    mapping(bytes32 => bool) public isSubmissionUsed; // submissionId (i.e. hash( bridgeId, amount, receiver, nonce)) => whether is claimed
    mapping(bytes32 => bool) public isBlockedSubmission; // submissionId  => is blocked
    mapping(bytes32 => uint256) public getAmountThreshold; // bridge => amount threshold
    mapping(uint256 => ChainSupportInfo) public getChainSupport; // whether the chain for the asset is supported
    mapping(address => DiscountInfo) public feeDiscount; //fee discount for address

    mapping(address => TokenInfo) public getNativeInfo; //return native token info by wrapped token address

    IDefiController public defiController; // proxy to use the locked assets in Defi protocols
    address public feeProxy; // proxy to convert the collected fees into Link's
    IWETH public weth; // wrapped native token contract

    /* ========== ERRORS ========== */

    error FeeProxyBadRole();
    error DefiControllerBadRole();
    error AdminBadRole();
    error GovMonitoringBadRole();
    error BridgeNotFound();

    error WrongChain();
    error WrongTargedChain();
    error WrongArgument();

    error TransferAmountTooHigh();

    error NotSupportedFixedFee();
    error TransferAmountNotCoverFees();

    error SubmissionUsed();
    error SubmissionNotConfirmed();
    error SubmissionAmountNotConfirmed();
    error SubmissionBlocked();

    error AmountMismatch();

    error AssetAlreadyExist();
    error WrappedAssetNotFound();
    error ZeroAddress();

    error ProposedFeeTooHigh();
    error FeeNotPaid();

    error NotEnoughReserves();

    /* ========== MODIFIERS ========== */

    modifier onlyFeeProxy() {
        if (feeProxy != msg.sender) revert FeeProxyBadRole();
        _;
    }

    modifier onlyDefiController() {
        if (address(defiController) != msg.sender) revert DefiControllerBadRole();
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AdminBadRole();
        _;
    }

    modifier onlyGovMonitoring() {
        if (!hasRole(GOVMONITORING_ROLE, msg.sender)) revert GovMonitoringBadRole();
        _;
    }

    /* ========== CONSTRUCTOR  ========== */

    /// @dev Constructor that initializes the most important configurations.
    /// @param _signatureVerifier Aggregator address to verify signatures
    /// @param _confirmationAggregator Aggregator address to verify by oracles confirmations
    /// @param _supportedChainIds Chain ids where native token of the current chain can be wrapped.
    /// @param _treasury Address to collect a fee
    function initialize(
        uint8 _excessConfirmations,
        address _signatureVerifier,
        address _confirmationAggregator,
        address _callProxy,
        uint256[] memory _supportedChainIds,
        ChainSupportInfo[] memory _chainSupportInfo,
        IWETH _weth,
        address _feeProxy,
        IDefiController _defiController,
        address _treasury
    ) public initializer {
        _addAsset(
            getBridgeId(getChainId(), address(_weth)),
            address(_weth),
            abi.encodePacked(address(_weth)),
            getChainId()
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

    /* ========== send, mint, burn, claim ========== */

    /// @dev Locks asset on the chain and enables minting on the other chain.
    /// @param _tokenAddress Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount to be transfered (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    function send(
        address _tokenAddress,
        bytes memory _receiver,
        uint256 _amount,
        uint256 _chainIdTo,
        bool _useAssetFee,
        uint32 _referralCode
    ) external payable override nonReentrant whenNotPaused {
        bytes32 bridgeId;
        // the amount will be reduced by the protocol fee
        (_amount, bridgeId) = _send(
            _tokenAddress,
            _amount,
            _chainIdTo,
            _useAssetFee,
            _referralCode
        );

        bytes32 sentId = getSubmissionIdTo(bridgeId, _chainIdTo, _amount, _receiver);
        emit Sent(sentId, bridgeId, _amount, _receiver, nonce, _chainIdTo, _referralCode);
        nonce++;
    }

    /// @dev Mints wrapped asset on the current chain.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: without applyed fee).
    /// @param _nonce Submission id.
    /// @param _signatures Array of oracles signatures.
    function mint(
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        address _receiver,
        uint256 _amount,
        uint256 _nonce,
        bytes memory _signatures
    ) external override nonReentrant whenNotPaused {
        bytes32 submissionId = getSubmissionIdFrom(
            _bridgeId,
            _chainIdFrom,
            _amount,
            _receiver,
            _nonce
        );

        _checkAndDeployAsset(
            _bridgeId,
            _signatures.length > 0 ? signatureVerifier : confirmationAggregator
        );

        _checkConfirmations(submissionId, _bridgeId, _amount, _signatures);

        _mint(submissionId, _bridgeId, _receiver, _amount, address(0), 0, "", 0, "");

        emit Minted(submissionId, _bridgeId, _amount, _receiver, _nonce, _chainIdFrom);
    }

    /// @dev Burns wrapped asset and allowss to claim it on the other chain.
    /// @param _bridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    /// @param _permit deadline + signature for approving the spender by signature.
    function burn(
        bytes32 _bridgeId,
        bytes memory _receiver,
        uint256 _amount,
        uint256 _chainIdTo,
        bytes memory _permit,
        bool _useAssetFee,
        uint32 _referralCode
    ) external payable override nonReentrant whenNotPaused {
        // the amount will be reduced by the protocol fee
        _amount = _burn(_bridgeId, _amount, _chainIdTo, _permit, _useAssetFee, _referralCode);

        bytes32 burntId = getSubmissionIdTo(_bridgeId, _chainIdTo, _amount, _receiver);
        emit Burnt(burntId, _bridgeId, _amount, _receiver, nonce, _chainIdTo, _referralCode);
        nonce++;
    }

    /// @dev Unlock the asset on the current chain and transfer to receiver.
    /// @param _bridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _nonce Submission id.

    function claim(
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        address _receiver,
        uint256 _amount,
        uint256 _nonce,
        bytes memory _signatures
    ) external override nonReentrant whenNotPaused {
        bytes32 submissionId = getSubmissionIdFrom(
            _bridgeId,
            _chainIdFrom,
            _amount,
            _receiver,
            _nonce
        );

        _checkConfirmations(submissionId, _bridgeId, _amount, _signatures);

        _claim(submissionId, _bridgeId, _receiver, _amount, address(0), 0, "", 0, "");

        emit Claimed(submissionId, _bridgeId, _amount, _receiver, nonce, _chainIdFrom);
    }

    /* ========== AUTO send, mint, burn, claim ========== */

    /// @dev Locks asset on the chain and enables minting on the other chain.
    /// @param _tokenAddress Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount to be transfered (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    /// @param _fallbackAddress Receiver of the tokens if the call fails.
    /// @param _executionFee Fee paid to the transaction executor.
    /// @param _data Chain id of the target chain.
    function autoSend(
        address _tokenAddress,
        bytes memory _receiver,
        uint256 _amount,
        uint256 _chainIdTo,
        bytes memory _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        bool _useAssetFee,
        uint8 _reservedFlag,
        uint32 _referralCode
    ) external payable override nonReentrant whenNotPaused {
        bytes32 bridgeId;
        // the amount will be reduced by the protocol fee
        (_amount, bridgeId) = _send(
            _tokenAddress,
            _amount,
            _chainIdTo,
            _useAssetFee,
            _referralCode
        );
        if (_amount < _executionFee) revert ProposedFeeTooHigh();
        _amount -= _executionFee;

        emit AutoSent(
            // //Avoid Stack too deep  error
            getAutoSubmissionIdTo(
                bridgeId,
                _chainIdTo,
                _amount,
                _receiver,
                _fallbackAddress,
                _executionFee,
                _data,
                _reservedFlag
            ),
            bridgeId,
            _amount,
            _receiver,
            nonce,
            _chainIdTo,
            _executionFee,
            _fallbackAddress,
            _data,
            _referralCode,
            _reservedFlag,
            msg.sender
        );
        nonce++;
    }

    /// @dev Mints wrapped asset on the current chain.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: without applyed fee).
    /// @param _nonce Submission id.
    /// @param _signatures Array of oracles signatures.
    /// @param _fallbackAddress Receiver of the tokens if the call fails.
    /// @param _executionFee Fee paid to the transaction executor.
    /// @param _data Chain id of the target chain.
    function autoMint(
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        address _receiver,
        uint256 _amount,
        uint256 _nonce,
        bytes memory _signatures,
        address _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        uint8 _reservedFlag,
        bytes memory _nativeSender
    ) external override nonReentrant whenNotPaused {
        bytes32 submissionId = getAutoSubmissionIdFrom(
            _nativeSender,
            _bridgeId,
            _chainIdFrom,
            _amount,
            _receiver,
            _nonce,
            _fallbackAddress,
            _executionFee,
            _data,
            _reservedFlag
        );

        _checkAndDeployAsset(
            _bridgeId,
            _signatures.length > 0 ? signatureVerifier : confirmationAggregator
        );

        _checkConfirmations(submissionId, _bridgeId, _amount, _signatures);

        _mint(
            submissionId,
            _bridgeId,
            _receiver,
            _amount,
            _fallbackAddress,
            _executionFee,
            _data,
            _reservedFlag,
            _nativeSender
        );

        emit AutoMinted(
            submissionId,
            _bridgeId,
            _amount,
            _receiver,
            _nonce,
            // _chainIdFrom,
            _executionFee,
            _fallbackAddress,
            _data,
            _reservedFlag
            // _nativeSender
        );
    }

    /// @dev Burns wrapped asset and allowss to claim it on the other chain.
    /// @param _bridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    /// @param _fallbackAddress Receiver of the tokens if the call fails.
    /// @param _executionFee Fee paid to the transaction executor.
    /// @param _data Chain id of the target chain.
    /// @param _permit deadline + signature for approving the spender by signature.
    function autoBurn(
        bytes32 _bridgeId,
        bytes memory _receiver,
        uint256 _amount,
        uint256 _chainIdTo,
        bytes memory _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        bytes memory _permit,
        bool _useAssetFee,
        uint8 _reservedFlag,
        uint32 _referralCode
    ) external payable override nonReentrant whenNotPaused {
        // the amount will be reduced by the protocol fee
        _amount = _burn(_bridgeId, _amount, _chainIdTo, _permit, _useAssetFee, _reservedFlag);
        if (_amount < _executionFee) revert ProposedFeeTooHigh();
        _amount -= _executionFee;

        emit AutoBurnt(
            getAutoSubmissionIdTo(
                _bridgeId,
                _chainIdTo,
                _amount,
                _receiver,
                _fallbackAddress,
                _executionFee,
                _data,
                _reservedFlag
            ),
            _bridgeId,
            _amount,
            _receiver,
            nonce,
            _chainIdTo,
            _executionFee,
            _fallbackAddress,
            _data,
            _referralCode,
            _reservedFlag,
            msg.sender
        );
        nonce++;
    }

    /// @dev Unlock the asset on the current chain and transfer to receiver.
    /// @param _bridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _nonce Submission id.
    function autoClaim(
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        address _receiver,
        uint256 _amount,
        uint256 _nonce,
        bytes memory _signatures,
        address _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        uint8 _reservedFlag,
        bytes memory _nativeSender
    ) external override nonReentrant whenNotPaused {
        bytes32 submissionId = getAutoSubmissionIdFrom(
            _nativeSender,
            _bridgeId,
            _chainIdFrom,
            _amount,
            _receiver,
            _nonce,
            _fallbackAddress,
            _executionFee,
            _data,
            _reservedFlag
        );

        _checkConfirmations(submissionId, _bridgeId, _amount, _signatures);

        _claim(
            submissionId,
            _bridgeId,
            _receiver,
            _amount,
            _fallbackAddress,
            _executionFee,
            _data,
            _reservedFlag,
            _nativeSender
        );

        emit AutoClaimed(
            submissionId,
            _bridgeId,
            _amount,
            _receiver,
            _nonce,
            // _chainIdFrom,
            _executionFee,
            _fallbackAddress,
            _data,
            _reservedFlag
            // _nativeSender
        );
    }

    function flash(
        address _tokenAddress,
        address _receiver,
        uint256 _amount,
        bytes memory _data
    )
        external
        override
        nonReentrant
        whenNotPaused // noDelegateCall
    {
        bytes32 bridgeId = getBridgeId(getChainId(), _tokenAddress);
        if (!getBridge[bridgeId].exist) revert BridgeNotFound();
        uint256 currentFlashFee = (_amount * flashFeeBps) / BPS_DENOMINATOR;
        uint256 balanceBefore = IERC20(_tokenAddress).balanceOf(address(this));

        IERC20(_tokenAddress).safeTransfer(_receiver, _amount);
        IFlashCallback(msg.sender).flashCallback(currentFlashFee, _data);

        uint256 balanceAfter = IERC20(_tokenAddress).balanceOf(address(this));
        if (balanceBefore + currentFlashFee > balanceAfter) revert FeeNotPaid();

        uint256 paid = balanceAfter - balanceBefore;
        getBridgeFeeInfo[bridgeId].collectedFees += paid;
        emit Flash(msg.sender, _tokenAddress, _receiver, _amount, paid);
    }

    /* ========== ADMIN ========== */

    /// @dev Update asset's fees.
    /// @param _supportedChainIds Chain identifiers.
    /// @param _chainSupportInfo Chain support info.
    function updateChainSupport(
        uint256[] memory _supportedChainIds,
        ChainSupportInfo[] memory _chainSupportInfo
    ) external onlyAdmin {
        for (uint256 i = 0; i < _supportedChainIds.length; i++) {
            getChainSupport[_supportedChainIds[i]] = _chainSupportInfo[i];
        }
        emit ChainsSupportUpdated(_supportedChainIds);
    }

    /// @dev Update asset's fees.
    /// @param _bridgeId Asset identifier.
    /// @param _supportedChainIds Chain identifiers.
    /// @param _assetFeesInfo Chain support info.
    function updateAssetFixedFees(
        bytes32 _bridgeId,
        uint256[] memory _supportedChainIds,
        uint256[] memory _assetFeesInfo
    ) external onlyAdmin {
        BridgeFeeInfo storage bridgeFee = getBridgeFeeInfo[_bridgeId];
        for (uint256 i = 0; i < _supportedChainIds.length; i++) {
            bridgeFee.getChainFee[_supportedChainIds[i]] = _assetFeesInfo[i];
        }
    }

    function updateExcessConfirmations(uint8 _excessConfirmations) external onlyAdmin {
        excessConfirmations = _excessConfirmations;
    }

    /// @dev Set support for the chains where the token can be transfered.
    /// @param _chainId Chain id where tokens are sent.
    /// @param _isSupported Whether the token is transferable to the other chain.
    function setChainSupport(uint256 _chainId, bool _isSupported) external onlyAdmin {
        getChainSupport[_chainId].isSupported = _isSupported;
        emit ChainSupportUpdated(_chainId, _isSupported);
    }

    /// @dev Set proxy address.
    /// @param _address Address of the proxy that executes external calls.
    function setCallProxy(uint256 version, address _address) external onlyAdmin {
        callProxyAddresses[version] = _address;
        emit CallProxyUpdated(version, _address);
    }

    /// @dev Add support for the asset.
    /// @param _bridgeId Asset identifier.
    /// @param _maxAmount Maximum amount of current chain token to be wrapped.
    /// @param _minReservesBps Minimal reserve ration in BPS.
    function updateAsset(
        bytes32 _bridgeId,
        uint256 _maxAmount,
        uint16 _minReservesBps,
        uint256 _amountThreshold
    ) external onlyAdmin {
        BridgeInfo storage bridge = getBridge[_bridgeId];
        bridge.maxAmount = _maxAmount;
        bridge.minReservesBps = _minReservesBps;
        getAmountThreshold[_bridgeId] = _amountThreshold;
    }

    /// @dev Set aggregator address.
    /// @param _aggregator Submission aggregator address.
    function setAggregator(address _aggregator) external onlyAdmin {
        confirmationAggregator = _aggregator;
    }

    /// @dev Set signature verifier address.
    /// @param _verifier Signature verifier address.
    function setSignatureVerifier(address _verifier) external onlyAdmin {
        signatureVerifier = _verifier;
    }

    /// @dev Set defi controoler.
    /// @param _defiController Defi controller address address.
    function setDefiController(IDefiController _defiController) external onlyAdmin {
        // TODO: claim all the reserves before
        // loop lockedInStrategies
        // defiController.claimReserve(
        //     _bridge.tokenAddress,
        //     requestedReserves
        // );
        defiController = _defiController;
    }

    /// @dev Stop all transfers.
    function pause() external onlyGovMonitoring {
        _pause();
    }

    /// @dev Allow transfers.
    function unpause() external onlyAdmin whenPaused {
        _unpause();
    }

    /// @dev Withdraw fees.
    /// @param _bridgeId Asset identifier.
    function withdrawFee(bytes32 _bridgeId) external override nonReentrant onlyFeeProxy {
        BridgeFeeInfo storage bridgeFee = getBridgeFeeInfo[_bridgeId];
        // Amount for transfer to treasure
        uint256 amount = bridgeFee.collectedFees - bridgeFee.withdrawnFees;
        bridgeFee.withdrawnFees += amount;

        if (amount == 0) revert NotEnoughReserves();

        if (_bridgeId == getBridgeId(getChainId(), address(0))) {
            payable(feeProxy).transfer(amount);
        } else {
            // don't need this check as we check that amount is not zero
            // if (!getBridge[_bridgeId].exist) revert BridgeNotFound();
            IERC20(getBridge[_bridgeId].tokenAddress).safeTransfer(feeProxy, amount);
        }
        emit WithdrawnFee(_bridgeId, amount);
    }

    /// @dev Request the assets to be used in defi protocol.
    /// @param _tokenAddress Asset address.
    /// @param _amount Amount of tokens to request.
    function requestReserves(address _tokenAddress, uint256 _amount)
        external
        override
        onlyDefiController
    {
        bytes32 bridgeId = getBridgeId(getChainId(), _tokenAddress);
        BridgeInfo storage bridge = getBridge[bridgeId];
        if (!bridge.exist) revert BridgeNotFound();
        uint256 minReserves = (bridge.balance * bridge.minReservesBps) / BPS_DENOMINATOR;

        if (minReserves + _amount > IERC20(_tokenAddress).balanceOf(address(this)))
            revert NotEnoughReserves();

        IERC20(_tokenAddress).safeTransfer(address(defiController), _amount);
        bridge.lockedInStrategies += _amount;
    }

    /// @dev Return the assets that were used in defi protocol.
    /// @param _tokenAddress Asset address.
    /// @param _amount Amount of tokens to claim.
    function returnReserves(address _tokenAddress, uint256 _amount)
        external
        override
        onlyDefiController
    {
        bytes32 bridgeId = getBridgeId(getChainId(), _tokenAddress);
        BridgeInfo storage bridge = getBridge[bridgeId];
        if (!bridge.exist) revert BridgeNotFound();
        IERC20(bridge.tokenAddress).safeTransferFrom(
            address(defiController),
            address(this),
            _amount
        );
        bridge.lockedInStrategies -= _amount;
    }

    /// @dev Set fee converter proxy.
    /// @param _feeProxy Fee proxy address.
    function setFeeProxy(address _feeProxy) external onlyAdmin {
        feeProxy = _feeProxy;
    }

    function blockSubmission(bytes32[] memory _submissionIds, bool isBlocked) external onlyAdmin {
        for (uint256 i = 0; i < _submissionIds.length; i++) {
            isBlockedSubmission[_submissionIds[i]] = isBlocked;
            if (isBlocked) {
                emit Blocked(_submissionIds[i]);
            } else {
                emit Unblocked(_submissionIds[i]);
            }
        }
    }

    /// @dev Update flash fees.
    /// @param _flashFeeBps new fee in BPS
    function updateFlashFee(uint16 _flashFeeBps) external onlyAdmin {
        flashFeeBps = _flashFeeBps;
    }

    /// @dev Update discount.
    /// @param _address customer address
    /// @param _discountFixBps  fix discount in BPS
    /// @param _discountTransferBps transfer % discount in BPS
    function updateFeeDiscount(
        address _address,
        uint16 _discountFixBps,
        uint16 _discountTransferBps
    ) external onlyAdmin {
        if (_discountFixBps > BPS_DENOMINATOR) revert WrongArgument();
        if (_discountTransferBps > BPS_DENOMINATOR) revert WrongArgument();
        DiscountInfo storage discountInfo = feeDiscount[_address];
        discountInfo.discountFixBps = _discountFixBps;
        discountInfo.discountTransferBps = _discountTransferBps;
    }

    function updateTreasury(address _address) external onlyAdmin {
        treasury = _address;
    }

    // we need to accept ETH sends to unwrap WETH
    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
    }

    /* ========== INTERNAL ========== */

    function _checkAndDeployAsset(bytes32 _bridgeId, address _aggregatorAddress) internal {
        if (!getBridge[_bridgeId].exist) {
            (
                address wrappedAssetAddress,
                bytes memory nativeAddress,
                uint256 nativeChainId
            ) = IConfirmationAggregator(_aggregatorAddress).deployAsset(_bridgeId);
            if (wrappedAssetAddress == address(0)) revert WrappedAssetNotFound();
            _addAsset(_bridgeId, wrappedAssetAddress, nativeAddress, nativeChainId);
        }
    }

    function _checkConfirmations(
        bytes32 _submissionId,
        bytes32 _bridgeId,
        uint256 _amount,
        bytes memory _signatures
    ) internal {
        if (isBlockedSubmission[_submissionId]) revert SubmissionBlocked();
        if (_signatures.length > 0) {
            // inside check is confirmed
            ISignatureVerifier(signatureVerifier).submit(
                _submissionId,
                _signatures,
                _amount >= getAmountThreshold[_bridgeId] ? excessConfirmations : 0
            );
        } else {
            (uint8 confirmations, bool confirmed) = IConfirmationAggregator(confirmationAggregator)
                .getSubmissionConfirmations(_submissionId);

            if (!confirmed) revert SubmissionNotConfirmed();
            if (_amount >= getAmountThreshold[_bridgeId]) {
                if (confirmations < excessConfirmations) revert SubmissionAmountNotConfirmed();
            }
        }
    }

    /// @dev Add support for the asset.
    /// @param _bridgeId Asset identifier.
    /// @param _tokenAddress Address of the asset on the current chain.
    /// @param _nativeAddress Address of the asset on the native chain.
    /// @param _chainId Current chain id.
    function _addAsset(
        bytes32 _bridgeId,
        address _tokenAddress,
        bytes memory _nativeAddress,
        uint256 _chainId
    ) internal {
        BridgeInfo storage bridge = getBridge[_bridgeId];

        if (bridge.exist) revert AssetAlreadyExist();
        if (_tokenAddress == address(0)) revert ZeroAddress();

        bridge.exist = true;
        bridge.tokenAddress = _tokenAddress;
        bridge.chainId = _chainId;
        //Don't override if the admin already set maxAmount
        if (bridge.maxAmount == 0) {
            bridge.maxAmount = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        }
        // bridge.minReservesBps = BPS;
        if (getAmountThreshold[_bridgeId] == 0) {
            getAmountThreshold[
                _bridgeId
            ] = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        }

        TokenInfo storage tokenInfo = getNativeInfo[_tokenAddress];
        tokenInfo.chainId = _chainId;
        tokenInfo.nativeAddress = _nativeAddress;

        emit PairAdded(_bridgeId, _tokenAddress, _chainId, bridge.maxAmount, bridge.minReservesBps);
    }

    /// @dev Locks asset on the chain and enables minting on the other chain.
    /// @param _amount Amount to be transfered (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    function _send(
        address _tokenAddress,
        uint256 _amount,
        uint256 _chainIdTo,
        bool _useAssetFee,
        uint32 _referralCode
    ) internal returns (uint256 newAmount, bytes32 bridgeId) {
        //We use WETH bridgeId for transfer ETH
        bridgeId = getBridgeId(
            getChainId(),
            _tokenAddress == address(0) ? address(weth) : _tokenAddress
        );

        BridgeInfo storage bridge = getBridge[bridgeId];
        if (!bridge.exist) {
            _addAsset(
                bridgeId,
                _tokenAddress == address(0) ? address(weth) : _tokenAddress,
                abi.encodePacked(_tokenAddress),
                getChainId()
            );
        }
        if (bridge.chainId != getChainId()) revert WrongChain();
        if (!getChainSupport[_chainIdTo].isSupported) revert WrongTargedChain();
        if (_amount > bridge.maxAmount) revert TransferAmountTooHigh();

        if (_tokenAddress == address(0)) {
            if (_amount != msg.value) revert AmountMismatch();
            weth.deposit{value: msg.value}();
            _useAssetFee = true;
        } else {
            IERC20 token = IERC20(_tokenAddress);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), _amount);
            // Received real amount
            _amount = token.balanceOf(address(this)) - balanceBefore;
        }
        _amount = _processFeeForTransfer(
            bridgeId,
            _amount,
            _chainIdTo,
            _useAssetFee,
            _referralCode
        );
        bridge.balance += _amount;
        return (_amount, bridgeId);
    }

    /// @dev Burns wrapped asset and allowss to claim it on the other chain.
    /// @param _bridgeId Asset identifier.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    /// @param _permit deadline + signature for approving the spender by signature.
    function _burn(
        bytes32 _bridgeId,
        uint256 _amount,
        uint256 _chainIdTo,
        bytes memory _permit,
        bool _useAssetFee,
        uint32 _referralCode
    ) internal returns (uint256) {
        BridgeInfo storage bridge = getBridge[_bridgeId];
        if (!bridge.exist) revert BridgeNotFound();
        if (bridge.chainId == getChainId()) revert WrongChain();
        if (!getChainSupport[_chainIdTo].isSupported) revert WrongTargedChain();
        if (_amount > bridge.maxAmount) revert TransferAmountTooHigh();
        IWrappedAsset wrappedAsset = IWrappedAsset(bridge.tokenAddress);
        if (_permit.length > 0) {
            //First dealine, next is signature
            uint256 deadline = _permit.toUint256(0);
            (bytes32 r, bytes32 s, uint8 v) = _permit.parseSignature(32);
            wrappedAsset.permit(msg.sender, address(this), _amount, deadline, v, r, s);
        }
        wrappedAsset.transferFrom(msg.sender, address(this), _amount);
        _amount = _processFeeForTransfer(
            _bridgeId,
            _amount,
            _chainIdTo,
            _useAssetFee,
            _referralCode
        );
        wrappedAsset.burn(_amount);
        bridge.balance -= _amount;
        return _amount;
    }

    function _processFeeForTransfer(
        bytes32 _bridgeId,
        uint256 _amount,
        uint256 _chainIdTo,
        bool _useAssetFee,
        uint32 _referralCode
    ) internal returns (uint256) {
        ChainSupportInfo memory chainSupportInfo = getChainSupport[_chainIdTo];
        DiscountInfo memory discountInfo = feeDiscount[msg.sender];
        BridgeFeeInfo storage bridgeFee = getBridgeFeeInfo[_bridgeId];
        uint256 fixedFee;
        if (_useAssetFee) {
            fixedFee = bridgeFee.getChainFee[_chainIdTo];
            if (fixedFee == 0) revert NotSupportedFixedFee();
        } else {
            // collect native fees
            if (
                msg.value <
                chainSupportInfo.fixedNativeFee -
                    (chainSupportInfo.fixedNativeFee * discountInfo.discountFixBps) /
                    BPS_DENOMINATOR
            ) revert TransferAmountNotCoverFees();
            bytes32 nativeBridgeId = getBridgeId(getChainId(), address(0));
            getBridgeFeeInfo[nativeBridgeId].collectedFees += msg.value;
            emit CollectedFee(nativeBridgeId, _referralCode, msg.value);
        }
        uint256 transferFee = (_amount * chainSupportInfo.transferFeeBps) /
            BPS_DENOMINATOR +
            fixedFee;
        transferFee =
            transferFee -
            (transferFee * discountInfo.discountTransferBps) /
            BPS_DENOMINATOR;
        if (_amount < transferFee) revert TransferAmountNotCoverFees();
        bridgeFee.collectedFees += transferFee;
        emit CollectedFee(_bridgeId, _referralCode, transferFee);
        _amount -= transferFee;
        return _amount;
    }

    /// @dev Mints wrapped asset on the current chain.
    /// @param _submissionId Submission identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: without applyed fee).
    /// @param _fallbackAddress Receiver of the tokens if the call fails.
    /// @param _executionFee Fee paid to the transaction executor.
    /// @param _data Chain id of the target chain.
    function _mint(
        bytes32 _submissionId,
        bytes32 _bridgeId,
        address _receiver,
        uint256 _amount,
        address _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        uint8 _reservedFlag,
        bytes memory _nativeSender
    ) internal {
        _markAsUsed(_submissionId);

        BridgeInfo storage bridge = getBridge[_bridgeId];
        if (!bridge.exist) revert BridgeNotFound();
        if (bridge.chainId == getChainId()) revert WrongChain();

        if (_executionFee > 0) {
            IWrappedAsset(bridge.tokenAddress).mint(msg.sender, _executionFee);
        }
        if (_data.length > 0) {
            address callProxyAddress = _reservedFlag == PROXY_WITH_SENDER_FLAG
                ? callProxyAddresses[PROXY_WITH_SENDER_FLAG]
                : callProxyAddresses[0];
            IWrappedAsset(bridge.tokenAddress).mint(callProxyAddress, _amount);
            bool status = ICallProxy(callProxyAddress).callERC20(
                bridge.tokenAddress,
                _fallbackAddress,
                _receiver,
                _data,
                _reservedFlag,
                _nativeSender
            );
            emit AutoRequestExecuted(_submissionId, status);
        } else {
            IWrappedAsset(bridge.tokenAddress).mint(_receiver, _amount);
        }
        bridge.balance += _amount + _executionFee;
    }

    /// @dev Unlock the asset on the current chain and transfer to receiver.
    /// @param _bridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _fallbackAddress Receiver of the tokens if the call fails.
    /// @param _executionFee Fee paid to the transaction executor.
    /// @param _data Chain id of the target chain.
    function _claim(
        bytes32 _submissionId,
        bytes32 _bridgeId,
        address _receiver,
        uint256 _amount,
        address _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        uint8 _reservedFlag,
        bytes memory _nativeSender
    ) internal {
        BridgeInfo storage bridge = getBridge[_bridgeId];
        if (bridge.chainId != getChainId()) revert WrongChain();
        _markAsUsed(_submissionId);

        bridge.balance -= _amount;

        if (_executionFee > 0) {
            IERC20(bridge.tokenAddress).safeTransfer(msg.sender, _executionFee);
        }
        if (_data.length > 0) {
            address callProxyAddress = _reservedFlag == PROXY_WITH_SENDER_FLAG
                ? callProxyAddresses[PROXY_WITH_SENDER_FLAG]
                : callProxyAddresses[0];

            IERC20(bridge.tokenAddress).safeTransfer(callProxyAddress, _amount);
            bool status = ICallProxy(callProxyAddress).callERC20(
                bridge.tokenAddress,
                _fallbackAddress,
                _receiver,
                _data,
                _reservedFlag,
                _nativeSender
            );
            emit AutoRequestExecuted(_submissionId, status);
        } else {
            IERC20(bridge.tokenAddress).safeTransfer(_receiver, _amount);
        }
    }

    /// @dev Mark submission as used.
    /// @param _submissionId Submission identifier.
    function _markAsUsed(bytes32 _submissionId) internal {
        if (isSubmissionUsed[_submissionId]) revert SubmissionUsed();
        isSubmissionUsed[_submissionId] = true;
    }

    /* VIEW */

    function getDefiAvaliableReserves(address _tokenAddress)
        external
        view
        override
        returns (uint256)
    {
        BridgeInfo storage bridge = getBridge[getBridgeId(getChainId(), _tokenAddress)];
        return (bridge.balance * (BPS_DENOMINATOR - bridge.minReservesBps)) / BPS_DENOMINATOR;
    }

    /// @dev Calculates asset identifier.
    /// @param _chainId Current chain id.
    /// @param _tokenAddress Address of the asset on the other chain.
    function getBridgeId(uint256 _chainId, address _tokenAddress) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainId, _tokenAddress));
    }

    /// @dev Calculate submission id.
    /// @param _bridgeId Asset identifier.
    /// @param _chainIdFrom Chain identifier of the chain where tokens are sent from.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _nonce Submission id.
    function getSubmissionIdFrom(
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        uint256 _amount,
        address _receiver,
        uint256 _nonce
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(_bridgeId, _chainIdFrom, getChainId(), _amount, _receiver, _nonce)
            );
    }

    function getSubmissionIdTo(
        bytes32 _bridgeId,
        uint256 _chainIdTo,
        uint256 _amount,
        bytes memory _receiver
    ) private view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(_bridgeId, getChainId(), _chainIdTo, _amount, _receiver, nonce)
            );
    }

    /// @dev Calculate submission id for auto claimable transfer.
    /// @param _bridgeId Asset identifier.
    /// @param _chainIdFrom Chain identifier of the chain where tokens are sent from.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _nonce Submission id.
    /// @param _fallbackAddress Receiver of the tokens if the call fails.
    /// @param _executionFee Fee paid to the transaction executor.
    /// @param _data Chain id of the target chain.

    function getAutoSubmissionIdFrom(
        bytes memory _nativeSender,
        bytes32 _bridgeId,
        uint256 _chainIdFrom,
        uint256 _amount,
        address _receiver,
        uint256 _nonce,
        address _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        uint8 _reservedFlag
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    // To avoid error:
                    // Variable value0 is 1 slot(s) too deep inside the stack.
                    abi.encodePacked(_nativeSender, _bridgeId, _chainIdFrom),
                    getChainId(), //_chainIdTo,
                    _amount,
                    _receiver,
                    _nonce,
                    _fallbackAddress,
                    _executionFee,
                    _data,
                    _reservedFlag
                )
            );
    }

    function getAutoSubmissionIdTo(
        bytes32 _bridgeId,
        uint256 _chainIdTo,
        uint256 _amount,
        bytes memory _receiver,
        bytes memory _fallbackAddress,
        uint256 _executionFee,
        bytes memory _data,
        uint8 _reservedFlag
    ) private view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    msg.sender,
                    _bridgeId,
                    getChainId(),
                    _chainIdTo,
                    _amount,
                    _receiver,
                    nonce, //_nonce,
                    _fallbackAddress,
                    _executionFee,
                    _data,
                    _reservedFlag
                )
            );
    }

    function getNativeTokenInfo(address currentTokenAddress)
        external
        view
        override
        returns (uint256 chainId, bytes memory nativeAddress)
    {
        TokenInfo memory tokenInfo = getNativeInfo[currentTokenAddress];
        return (tokenInfo.chainId, tokenInfo.nativeAddress);
    }

    function getChainId() public view virtual returns (uint256 cid) {
        assembly {
            cid := chainid()
        }
    }
}
