// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReceiveUln {
    function verify(
        bytes calldata _packetHeader,
        bytes32 _payloadHash,
        uint64 _confirmations
    ) external;
}

interface IDVNReplica {
    function verify(
        address receiveLib,
        bytes calldata packetHeader,
        bytes32 payloadHash
    ) external;
}

/// @title DVNReplica
/// @notice One slot of LZ DVN attestation. Listed in the OApp's recv UlnConfig
///         as one of the optional DVN addresses.
///
///         A single verifier (set at construction) can invoke `verify()` to
///         register an attestation under this replica's own msg.sender
///         identity at the recv lib. Deploy N replicas to give the verifier
///         N attestation slots in the OApp's recv quorum.
///
///         Two production roles for this contract:
///           - **CCIP slot**: verifier = the CCIPBroadcaster. The broadcaster
///             receives a CCIP delivery, validates the source peer, then
///             broadcasts `verify()` to each registered replica.
///           - **Msig slot**: verifier = a Gnosis Safe. The Safe batches N
///             `verify()` calls (one per replica) into a single signed
///             transaction. Off-chain, the Safe signers validate the
///             source-chain authenticity of the packet before signing.
///
///         Not an `ILayerZeroDVN`: replicas are never in a send-side UlnConfig
///         and SendUln302 never iterates them, so `assignJob`/`getFee` are
///         unnecessary.
contract DVNReplica {
    uint64 internal constant MAX_CONFIRMATIONS = type(uint64).max;

    /// @notice The single address allowed to call `verify()` on this replica.
    ///         Set once at construction.
    address public immutable verifier;

    constructor(address _verifier) {
        verifier = _verifier;
    }

    /// @notice Record an attestation. Caller must equal `verifier`. Writes
    ///         `verify()` on the recv lib with `msg.sender = this replica`.
    function verify(
        address receiveLib,
        bytes calldata packetHeader,
        bytes32 payloadHash
    ) external {
        require(msg.sender == verifier, "DVNReplica/only-verifier");
        IReceiveUln(receiveLib).verify(packetHeader, payloadHash, MAX_CONFIRMATIONS);
    }
}
