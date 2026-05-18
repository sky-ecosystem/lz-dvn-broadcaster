// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { DVNReplica } from "../src/DVNReplica.sol";

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

contract DVNReplicaTest is Test {
    DVNReplica     replica;
    MockReceiveUln recvLib;

    address verifier = makeAddr("verifier");
    address attacker = makeAddr("attacker");

    function setUp() public {
        replica = new DVNReplica(verifier);
        recvLib = new MockReceiveUln();
    }

    function test_constructor_setsVerifier() public view {
        assertEq(replica.verifier(), verifier);
    }

    function test_verify_callableOnlyByVerifier() public {
        bytes memory header = hex"01";
        bytes32 hash = keccak256("payload");

        vm.expectRevert("DVNReplica/only-verifier");
        vm.prank(attacker);
        replica.verify(address(recvLib), header, hash);
    }

    function test_verify_writesToRecvLibAsThisReplica() public {
        bytes memory header = hex"01dead";
        bytes32 hash = keccak256("payload");

        vm.prank(verifier);
        replica.verify(address(recvLib), header, hash);

        assertEq(recvLib.lastPacketHash(), keccak256(header));
        assertEq(recvLib.lastPayloadHash(), hash);
        assertEq(recvLib.lastConfirmations(), type(uint64).max);
        assertEq(recvLib.lastCaller(), address(replica));
    }

    function test_verify_supportsRepeatedCalls() public {
        bytes memory header = hex"01dead";
        bytes32 hash = keccak256("payload");

        vm.prank(verifier);
        replica.verify(address(recvLib), header, hash);

        vm.prank(verifier);
        replica.verify(address(recvLib), header, hash);

        assertEq(recvLib.lastCaller(), address(replica));
    }
}
