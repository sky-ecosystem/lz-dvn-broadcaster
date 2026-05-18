// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { CCIPBroadcaster, Any2EVMMessage, EVMTokenAmount } from "../src/CCIPBroadcaster.sol";
import { DVNReplica } from "../src/DVNReplica.sol";
import { DVNAdapterMessageCodec } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/libs/DVNAdapterMessageCodec.sol";

contract MockReceiveUln {
    bytes32 public lastPacketHash;
    bytes32 public lastPayloadHash;
    uint64  public lastConfirmations;
    address public lastCaller;

    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64 confirmations) external {
        lastPacketHash    = keccak256(packetHeader);
        lastPayloadHash   = payloadHash;
        lastConfirmations = confirmations;
        lastCaller        = msg.sender;
    }
}

contract CCIPBroadcasterTest is Test {
    CCIPBroadcaster broadcaster;
    MockReceiveUln  recvLib;

    address attacker      = makeAddr("attacker");
    address router        = makeAddr("ccipRouter");
    address sourceAdapter = makeAddr("sourceAdapter");

    DVNReplica r0;
    DVNReplica r1;

    function setUp() public {
        recvLib = new MockReceiveUln();

        // Replicas need the broadcaster's address as their `verifier`, but
        // the broadcaster's constructor also wants the replica addresses.
        // Predict the broadcaster's CREATE address (this deployer's next-nonce
        // + 2, since we'll deploy r0 and r1 first) and use it for the
        // replicas. Production uses the same CREATE2 / counterfactual pattern.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        r0 = new DVNReplica(predicted);
        r1 = new DVNReplica(predicted);

        address[] memory replicas = new address[](2);
        replicas[0] = address(r0);
        replicas[1] = address(r1);
        broadcaster = new CCIPBroadcaster(router, sourceAdapter, replicas);

        assertEq(predicted, address(broadcaster));
    }

    // ---------- constructor ----------

    function test_constructor_setsState() public view {
        assertEq(broadcaster.router(), router);
        assertEq(broadcaster.srcChainSelector(), 5009297550715157269);
        assertEq(uint256(broadcaster.srcEid()), 30101);
        assertEq(broadcaster.srcPeer(), sourceAdapter);
        assertEq(broadcaster.replicaCount(), 2);
        assertEq(broadcaster.replicas(0), address(r0));
        assertEq(broadcaster.replicas(1), address(r1));
    }

    // ---------- ccipReceive ----------

    function _buildPacketHeaderWithSrcEid(uint32 _srcEid) internal returns (bytes memory) {
        return abi.encodePacked(
            uint8(1),
            uint64(42),
            _srcEid,
            bytes32(uint256(uint160(makeAddr("sender")))),
            uint32(30184),
            bytes32(uint256(uint160(makeAddr("receiver"))))
        );
    }

    function _buildPacketHeader() internal returns (bytes memory) {
        return _buildPacketHeaderWithSrcEid(broadcaster.srcEid());
    }

    function _buildPayload() internal returns (bytes memory) {
        return DVNAdapterMessageCodec.encode(
            bytes32(uint256(uint160(address(recvLib)))),
            _buildPacketHeader(),
            keccak256("payload")
        );
    }

    function _buildMessage() internal returns (Any2EVMMessage memory) {
        return Any2EVMMessage({
            messageId:           bytes32(uint256(0xdead)),
            sourceChainSelector: broadcaster.srcChainSelector(),
            sender:              abi.encode(sourceAdapter),
            data:                _buildPayload(),
            destTokenAmounts:    new EVMTokenAmount[](0)
        });
    }

    function test_ccipReceive_onlyRouter() public {
        Any2EVMMessage memory msg_ = _buildMessage();

        vm.prank(attacker);
        vm.expectRevert("CCIPBroadcaster/only-router");
        broadcaster.ccipReceive(msg_);
    }

    function test_ccipReceive_revertsOnWrongSourceChain() public {
        Any2EVMMessage memory msg_ = _buildMessage();
        msg_.sourceChainSelector = 99999;

        vm.prank(router);
        vm.expectRevert("CCIPBroadcaster/wrong-src-chain");
        broadcaster.ccipReceive(msg_);
    }

    function test_ccipReceive_revertsOnInvalidSrcEid() public {
        // Encode a packet header with srcEid != broadcaster.srcEid().
        bytes memory badPayload = DVNAdapterMessageCodec.encode(
            bytes32(uint256(uint160(address(recvLib)))),
            _buildPacketHeaderWithSrcEid(uint32(40231)), // not 30101
            keccak256("payload")
        );
        Any2EVMMessage memory msg_ = Any2EVMMessage({
            messageId:           bytes32(uint256(0xdead)),
            sourceChainSelector: broadcaster.srcChainSelector(),
            sender:              abi.encode(sourceAdapter),
            data:                badPayload,
            destTokenAmounts:    new EVMTokenAmount[](0)
        });

        vm.prank(router);
        vm.expectRevert("CCIPBroadcaster/invalid-src-eid");
        broadcaster.ccipReceive(msg_);
    }

    function test_ccipReceive_revertsOnUntrustedPeer() public {
        Any2EVMMessage memory msg_ = _buildMessage();
        msg_.sender = abi.encode(makeAddr("wrongPeer"));

        vm.prank(router);
        vm.expectRevert("CCIPBroadcaster/wrong-peer");
        broadcaster.ccipReceive(msg_);
    }

    function test_ccipReceive_dispatchesToReplicas() public {
        Any2EVMMessage memory msg_ = _buildMessage();
        bytes32 payloadHash = keccak256("payload");

        vm.prank(router);
        broadcaster.ccipReceive(msg_);

        assertEq(recvLib.lastCaller(), address(r1));
        assertEq(recvLib.lastPayloadHash(), payloadHash);
        assertEq(recvLib.lastConfirmations(), type(uint64).max);
    }
}
