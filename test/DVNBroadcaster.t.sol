// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test, Vm } from "forge-std/Test.sol";
import { DVNBroadcaster } from "../src/DVNBroadcaster.sol";
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

contract DVNBroadcasterTest is Test {
    DVNBroadcaster broadcaster;
    MockReceiveUln recvLib;

    address verifier = makeAddr("verifier");
    address attacker = makeAddr("attacker");

    uint256 constant N = 4;

    function setUp() public {
        recvLib = new MockReceiveUln();
        broadcaster = new DVNBroadcaster(address(recvLib), verifier, N);
    }

    // ---------- constructor ----------

    function test_constructor_setsImmutables() public view {
        assertEq(broadcaster.rcvLib(), address(recvLib));
        assertEq(broadcaster.verifier(), verifier);
        assertEq(broadcaster.getReplicas().length, N);
    }

    function test_constructor_spawnsReplicasWithBroadcasterAsVerifier() public view {
        for (uint256 i = 0; i < N; ++i) {
            DVNReplica r = broadcaster.replicas(i);
            assertTrue(address(r).code.length > 0, "replica has no code");
            assertEq(r.verifier(), address(broadcaster));
        }
    }

    function test_constructor_eachReplicaIsDistinct() public view {
        address r0 = address(broadcaster.replicas(0));
        for (uint256 i = 1; i < N; ++i) {
            assertTrue(address(broadcaster.replicas(i)) != r0);
        }
    }

    function test_constructor_revertsOnZeroReplicas() public {
        vm.expectRevert("DVNBroadcaster/zero-replicas");
        new DVNBroadcaster(address(recvLib), verifier, 0);
    }

    function test_constructor_emitsSpawned() public {
        vm.recordLogs();
        DVNBroadcaster bc = new DVNBroadcaster(address(recvLib), verifier, N);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Spawned(address,address,address[])");
        bool found;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].emitter == address(bc) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), verifier);
                (address rcv, address[] memory rs) = abi.decode(entries[i].data, (address, address[]));
                assertEq(rcv, address(recvLib));
                assertEq(rs.length, N);
                for (uint256 j = 0; j < N; ++j) {
                    assertEq(rs[j], bc.getReplicas()[j]);
                }
                found = true;
                break;
            }
        }
        assertTrue(found, "Spawned event not found");
    }

    function test_getReplicas_matchesIndexedAccess() public view {
        address[] memory rs = broadcaster.getReplicas();
        assertEq(rs.length, N);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(rs[i], address(broadcaster.replicas(i)));
        }
    }

    // ---------- verify ----------

    function test_verify_rejectsUnauthorizedCaller() public {
        vm.prank(attacker);
        vm.expectRevert("DVNBroadcaster/only-verifier");
        broadcaster.verify(hex"01", keccak256("payload"), uint64(0));
    }

    function test_verify_dispatchesToAllReplicas() public {
        bytes memory header = hex"01dead";
        bytes32 hash = keccak256("payload");

        vm.prank(verifier);
        broadcaster.verify(header, hash, uint64(0));

        // Mock keeps last-write semantics; the final replica's call wins.
        assertEq(recvLib.lastCaller(), address(broadcaster.replicas(N - 1)));
        assertEq(recvLib.lastPacketHash(), keccak256(header));
        assertEq(recvLib.lastPayloadHash(), hash);
        assertEq(recvLib.lastConfirmations(), type(uint64).max);
    }
}
