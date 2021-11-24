// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ICallProxy.sol";

contract CallProxy is AccessControl, ICallProxy {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    uint256 public constant PROXY_WITH_SENDER_FLAG = 100; //Flag to call proxy with sender contract
    bytes32 public constant Bridge_GATE_ROLE = keccak256("Bridge_GATE_ROLE"); // role allowed to withdraw fee

    /* ========== ERRORS ========== */

    error BridgeGateBadRole();

    /* ========== MODIFIERS ========== */

    modifier onlyGateRole() {
        if (!hasRole(Bridge_GATE_ROLE, msg.sender)) revert BridgeGateBadRole();
        _;
    }

    /* ========== CONSTRUCTOR  ========== */

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function call(
        address _reserveAddress,
        address _receiver,
        bytes memory _data,
        uint8 _reservedFlag,
        bytes memory _nativeSender
    ) external payable override onlyGateRole returns (bool _result) {
        // Add last argument is sender from original network
        if (_reservedFlag == PROXY_WITH_SENDER_FLAG) {
            _data = abi.encodePacked(_data, _nativeSender);
        }

        _result = externalCall(_receiver, msg.value, _data.length, _data);
        if (!_result) {
            payable(_reserveAddress).transfer(msg.value);
        }
    }

    function callERC20(
        address _token,
        address _reserveAddress,
        address _receiver,
        bytes memory _data,
        uint8 _reservedFlag,
        bytes memory _nativeSender
    ) external override onlyGateRole returns (bool _result) {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeApprove(_receiver, 0);
        IERC20(_token).safeApprove(_receiver, amount);

        // Add last argument is sender from original network
        if (_reservedFlag == PROXY_WITH_SENDER_FLAG) {
            _data = abi.encodePacked(_data, _nativeSender);
        }

        _result = externalCall(_receiver, 0, _data.length, _data);
        amount = IERC20(_token).balanceOf(address(this));
        if (!_result || amount > 0) {
            IERC20(_token).safeTransfer(_reserveAddress, amount);
        }
    }

    //gnosis
    //https://github.com/gnosis/MultiSigWallet/blob/ca981359cf5acd6a1f9db18e44777e45027df5e0/contracts/MultiSigWallet.sol#L244-L261

    function externalCall(
        address destination,
        uint256 value,
        uint256 dataLength,
        bytes memory data
    ) internal returns (bool) {
        bool result;
        assembly {
            let x := mload(0x40) // "Allocate" memory for output (0x40 is where "free memory" pointer is stored by convention)
            let d := add(data, 32) // First 32 bytes are the padded length of data, so exclude that
            result := call(
                sub(gas(), 34710), // 34710 is the value that solidity is currently emitting
                // It includes callGas (700) + callVeryLow (3, to pay for SUB) + callValueTransferGas (9000) +
                // callNewAccountGas (25000, in case the destination address does not exist and needs creating)
                destination,
                value,
                d,
                dataLength, // Size of the input (in bytes) - this is what fixes the padding problem
                x,
                0 // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }
}
