// SPDX-License-Identifier: Apache-2.0
// Inlined from sky-ecosystem/sky-oapp-oft @ main
pragma solidity ^0.8.22;

import { Ownable } from "./OZ.sol";
import { OAppSender, OAppCore, OAppOptionsType3 } from "./OApp.sol";
import { MessagingFee, MessagingReceipt } from "./LZInterfaces.sol";
import { IGovernanceOAppSender, TxParams } from "./IGovernanceOAppSender.sol";

contract GovernanceOAppSender is OAppSender, OAppOptionsType3, IGovernanceOAppSender {
    uint16 public constant SEND_TX = 1;

    mapping(address srcSender => mapping(uint32 dstEid => mapping(bytes32 dstTarget => bool canCall))) public canCallTarget;

    constructor(address _endpoint, address _owner) OAppCore(_endpoint, _owner) Ownable(_owner) {}

    function setCanCallTarget(address _srcSender, uint32 _dstEid, bytes32 _dstTarget, bool _canCall) external onlyOwner {
        if (canCallTarget[_srcSender][_dstEid][_dstTarget] == _canCall) revert CanCallTargetIdempotent();
        canCallTarget[_srcSender][_dstEid][_dstTarget] = _canCall;
        emit CanCallTargetSet(_srcSender, _dstEid, _dstTarget, _canCall);
    }

    function quoteTx(TxParams calldata _params, bool _payInLzToken) external view returns (MessagingFee memory fee) {
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_params);
        return _quote(_params.dstEid, message, options, _payInLzToken);
    }

    function sendTx(
        TxParams calldata _params,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory msgReceipt) {
        if (!canCallTarget[msg.sender][_params.dstEid][_params.dstTarget]) revert CannotCallTarget();
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_params);
        msgReceipt = _lzSend(_params.dstEid, message, options, _fee, _refundAddress);
        emit GovernanceCallSent(msgReceipt.guid);
    }

    function _buildMsgAndOptions(TxParams calldata _params) internal view returns (bytes memory, bytes memory) {
        bytes32 msgSenderBytes32 = bytes32(uint256(uint160(msg.sender)));
        bytes memory message = abi.encodePacked(msgSenderBytes32, _params.dstTarget, _params.dstCallData);
        bytes memory options = combineOptions(_params.dstEid, SEND_TX, _params.extraOptions);
        return (message, options);
    }
}
