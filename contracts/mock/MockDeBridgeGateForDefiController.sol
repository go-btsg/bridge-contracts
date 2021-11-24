// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../transfers/BridgeGate.sol";

contract MockBridgeGateForDefiController is BridgeGate {
    function init() external {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function sendETH() external payable {}

    function addBridge(
        address tokenAddress,
        uint256 chainId,
        uint256 maxAmount,
        uint256 collectedFees,
        uint256 balance,
        uint256 lockedInStrategies,
        uint16 minReservesBps,
        uint256 chainFee,
        bool exist
    ) public {
        bytes32 bridgeId = getBridgeId(chainId, tokenAddress);
        BridgeInfo storage bridge = getBridge[bridgeId];
        bridge.tokenAddress = tokenAddress;
        bridge.maxAmount = maxAmount;
        getBridgeFeeInfo[bridgeId].collectedFees = collectedFees;
        bridge.balance = balance;
        bridge.lockedInStrategies = lockedInStrategies;
        bridge.minReservesBps = minReservesBps;
        getBridgeFeeInfo[bridgeId].getChainFee[chainId] = chainFee;
        bridge.exist = exist;
    }

    // override chain id
    function getChainId() public pure override returns (uint256 cid) {
        return 1;
    }
}
