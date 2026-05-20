// SPDX-License-Identifier: Apache-2.0
// Inlined from sky-ecosystem/sky-oapp-oft @ main
// ReentrancyGuard inlined here (single-use within this file).
pragma solidity ^0.8.22;

import { Ownable } from "./OZ.sol";
import { OAppReceiver, OAppCore } from "./OApp.sol";
import { Origin } from "./LZInterfaces.sol";
import { IGovernanceOAppReceiver, MessageOrigin } from "./IGovernanceOAppReceiver.sol";

// --- ReentrancyGuard (OZ, simplified to a plain status slot) ---
abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED     = 2;
    uint256 private _status;

    error ReentrancyGuardReentrantCall();

    constructor() { _status = NOT_ENTERED; }

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrancyGuardReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

contract GovernanceOAppReceiver is OAppReceiver, ReentrancyGuard, IGovernanceOAppReceiver {
    MessageOrigin private _messageOrigin;

    constructor(
        uint32 _governanceOAppSenderEid,
        bytes32 _governanceOAppSenderAddress,
        address _endpoint,
        address _owner
    ) OAppCore(_endpoint, _owner) Ownable(_owner) {
        _setPeer(_governanceOAppSenderEid, _governanceOAppSenderAddress);
    }

    function messageOrigin() external view returns (MessageOrigin memory) {
        return _messageOrigin;
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override nonReentrant {
        bytes32 srcSender = bytes32(_payload[0:32]);
        address dstTarget = address(uint160(bytes20(_payload[44:64])));
        bytes memory dstCallData = _payload[64:];

        _messageOrigin = MessageOrigin({ srcEid: _origin.srcEid, srcSender: srcSender });

        (bool success, bytes memory returnData) = dstTarget.call{ value: msg.value }(dstCallData);
        if (!success) {
            if (returnData.length == 0) revert GovernanceCallFailed();
            assembly ("memory-safe") {
                revert(add(32, returnData), mload(returnData))
            }
        }

        _messageOrigin = MessageOrigin({ srcEid: 0, srcSender: bytes32(0) });

        emit GovernanceCallReceived(_guid);
    }
}
