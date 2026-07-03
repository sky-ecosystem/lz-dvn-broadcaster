// SPDX-License-Identifier: Apache-2.0
// Inlined from sky-ecosystem/sky-oapp-oft @ main
pragma solidity ^0.8.22;

struct MessageOrigin {
    uint32 srcEid;
    bytes32 srcSender;
}

interface IGovernanceOAppReceiver {
    error GovernanceCallFailed();

    event GovernanceCallReceived(bytes32 indexed guid);

    function messageOrigin() external view returns (MessageOrigin memory);
}
