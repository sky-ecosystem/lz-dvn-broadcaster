// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IReceiveUln {
    function verify(
        bytes calldata _packetHeader,
        bytes32 _payloadHash,
        uint64 _confirmations
    ) external;
}

contract DVNReplica {
    uint64 internal constant MAX_CONFIRMATIONS = type(uint64).max;

    address public immutable verifier;

    constructor(address _verifier) {
        verifier = _verifier;
    }

    function verify(
        address receiveLib,
        bytes calldata packetHeader,
        bytes32 payloadHash
    ) external {
        require(msg.sender == verifier, "DVNReplica/only-verifier");
        IReceiveUln(receiveLib).verify(packetHeader, payloadHash, MAX_CONFIRMATIONS);
    }
}
