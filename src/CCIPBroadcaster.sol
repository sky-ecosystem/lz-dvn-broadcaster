// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { DVNAdapterMessageCodec } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/libs/DVNAdapterMessageCodec.sol";

import { IDVNReplica } from "./DVNReplica.sol";

// Minimal local declarations of the Chainlink CCIP types this contract uses.
// Keeps the dependency surface tight: we don't pull in the full
// @chainlink/contracts-ccip package, just these two struct shapes.
struct EVMTokenAmount {
    address token;
    uint256 amount;
}

struct Any2EVMMessage {
    bytes32 messageId;
    uint64  sourceChainSelector;
    bytes   sender;
    bytes   data;
    EVMTokenAmount[] destTokenAmounts;
}

/// @title CCIPBroadcaster
/// @notice Destination-side dispatcher. When CCIP delivers an attestation
///         from the paired source-side CCIPDVNAdapter (on Ethereum mainnet),
///         this contract validates the source identity, decodes the LZ packet,
///         and broadcasts `verify()` to N DVNReplica contracts.
///
///         The broadcaster has no source-side role. On Ethereum, a stock
///         upstream-unmodified `CCIPDVNAdapter` is the actual DVN listed in
///         the OApp's send UlnConfig. That adapter is configured to send CCIP
///         messages to this broadcaster as its destination peer.
///
///         Fully immutable: router, srcPeer, and the replicas list are all set
///         once at construction and never change. To rotate any of them,
///         redeploy the broadcaster + replicas and ship a single L1 gov spell
///         that updates the source-side CCIPDVNAdapter's peer (direct L1 tx)
///         and relays a gov message to L2 updating OApp UlnConfig with new
///         replica addresses.
contract CCIPBroadcaster {
    /// @notice The Chainlink CCIP router on this (destination) chain.
    address public immutable router;

    /// @notice CCIP chain selector for Ethereum mainnet. Assigned by Chainlink.
    /// @dev    Canonical sources:
    ///           https://docs.chain.link/ccip/directory/mainnet/chain/mainnet
    ///           https://github.com/smartcontractkit/chain-selectors
    uint64 public constant srcChainSelector = 5009297550715157269;

    /// @notice LZ V2 endpoint id for Ethereum mainnet. Fixed by LayerZero.
    uint32 public constant srcEid = 30101;

    /// @notice The source-side CCIPDVNAdapter address on Ethereum mainnet.
    address public immutable srcPeer;

    /// @notice The DVNReplica contracts to broadcast attestations to.
    ///         Set once at construction; never modified.
    /// @dev    Dynamic arrays cannot use the Solidity `immutable` keyword, but
    ///         no setter exists for this array, so it is effectively immutable.
    ///         The auto-generated public getter `replicas(uint256 i)` returns
    ///         a single element by index; pair with `replicaCount()` to
    ///         iterate from off-chain callers.
    address[] public replicas;

    constructor(address _router, address _srcPeer, address[] memory _replicas) {
        router   = _router;
        srcPeer  = _srcPeer;
        replicas = _replicas;
    }

    function replicaCount() external view returns (uint256) {
        return replicas.length;
    }

    /// @notice Called by the Chainlink CCIP router on this chain when an
    ///         attestation arrives from the paired source-side adapter.
    function ccipReceive(Any2EVMMessage calldata message) external {
        require(msg.sender == router, "CCIPBroadcaster/only-router");
        require(
            message.sourceChainSelector == srcChainSelector,
            "CCIPBroadcaster/wrong-src-chain"
        );
        require(
            keccak256(message.sender) == keccak256(abi.encode(srcPeer)),
            "CCIPBroadcaster/wrong-peer"
        );

        uint32 encodedSrcEid = DVNAdapterMessageCodec.srcEid(message.data);
        require(encodedSrcEid == srcEid, "CCIPBroadcaster/invalid-src-eid");

        (address receiveLib, bytes memory packetHeader, bytes32 payloadHash) =
            DVNAdapterMessageCodec.decode(message.data);

        uint256 len = replicas.length;
        for (uint256 i = 0; i < len; ++i) {
            IDVNReplica(replicas[i]).verify(receiveLib, packetHeader, payloadHash);
        }
    }
}
