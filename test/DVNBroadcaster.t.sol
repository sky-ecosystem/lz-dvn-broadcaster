// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DVNBroadcaster } from "../src/DVNBroadcaster.sol";

interface IReceiveUln {
    function hashLookup(bytes32 headerHash, bytes32 payloadHash, address dvn)
        external view returns (bool submitted, uint64 confirmations);
}

contract DVNBroadcasterTest is Test {
    address constant BASE_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant BASE_RECVLIB  = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
    uint32  constant ETH_EID       = 30101;
    uint32  constant BASE_EID      = 30184;
    address constant RCVR          = address(uint160(0xbeef));
    uint256 constant N             = 4;

    DVNBroadcaster broadcaster;

    address verifier = makeAddr("verifier");

    function setUp() public {
        vm.createSelectFork(getChain("base").rpcUrl);
        broadcaster = new DVNBroadcaster(BASE_ENDPOINT, verifier, N);
    }

    // ---------- constructor ----------

    function test_constructor_setsImmutables() public view {
        assertEq(broadcaster.endpoint(), BASE_ENDPOINT);
        assertEq(broadcaster.verifier(), verifier);
        assertEq(broadcaster.getReplicas().length, N);
    }

    function test_constructor_spawnsReplicasWithBroadcasterAsVerifier() public view {
        address[] memory rs = broadcaster.getReplicas();
        for (uint256 i = 0; i < N; ++i) {
            assertTrue(rs[i].code.length > 0, "replica has no code");
            assertEq(broadcaster.replicas(i).verifier(), address(broadcaster));
        }
    }

    function test_constructor_eachReplicaIsDistinct() public view {
        address[] memory rs = broadcaster.getReplicas();
        for (uint256 i = 0; i < rs.length; ++i) {
            for (uint256 j = i + 1; j < rs.length; ++j) {
                assertTrue(rs[i] != rs[j], "duplicate replica address");
            }
        }
    }

    function test_constructor_revertsOnZeroReplica() public {
        vm.expectRevert("DVNBroadcaster/zero-replica");
        new DVNBroadcaster(BASE_ENDPOINT, verifier, 0);
    }

    function test_constructor_emitsSpawned() public {
        // Predict the broadcaster's address and the addresses of the N replicas
        // it will deploy. Contract nonce starts at 1, so the i-th replica is at
        // computeCreateAddress(broadcaster, i + 1).
        address predictedBroadcaster = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address[] memory expected = new address[](N);
        for (uint256 i = 0; i < N; ++i) {
            expected[i] = vm.computeCreateAddress(predictedBroadcaster, i + 1);
        }

        vm.expectEmit(true, false, false, true, predictedBroadcaster);
        emit DVNBroadcaster.Spawned(verifier, expected);
        new DVNBroadcaster(BASE_ENDPOINT, verifier, N);
    }

    function test_getReplicas_matchesIndexedAccess() public view {
        address[] memory rs = broadcaster.getReplicas();
        assertEq(rs.length, N);
        assertEq(broadcaster.getReplicasCount(), N);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(rs[i], address(broadcaster.replicas(i)));
        }
    }

    // ---------- verify ----------

    function test_verify_rejectsUnauthorizedCaller() public {
        vm.expectRevert("DVNBroadcaster/only-verifier");
        broadcaster.verify("", bytes32(0), uint64(0));
    }

    function test_verify_rejectsBadHeaderVersion() public {
        // Same shape as _buildHeader() but with version byte set to 2.
        bytes memory badHeader = abi.encodePacked(
            uint8(2),                                          // version (BAD)
            uint64(1),                                         // nonce
            ETH_EID,                                           // srcEid
            bytes32(uint256(uint160(0xdead))),                 // sender
            BASE_EID,                                          // dstEid
            bytes32(uint256(uint160(RCVR)))                    // receiver
        );

        vm.expectRevert("DVNBroadcaster/bad-header-version");
        vm.prank(verifier);
        broadcaster.verify(badHeader, keccak256("payload"), type(uint64).max);
    }

    function test_verify_dispatchesToAllReplicas() public {
        bytes memory header = _buildHeader();
        bytes32 payloadHash = keccak256("payload");

        // The dummy receiver has no custom receive-lib on Base, so the endpoint
        // returns the default for srcEid=ETH_EID, which is BASE_RECVLIB. Each
        // replica forwards there with the caller-supplied confirmations.
        vm.expectCall(
            BASE_RECVLIB,
            abi.encodeWithSignature(
                "verify(bytes,bytes32,uint64)", header, payloadHash, uint64(123)
            ),
            uint64(N)
        );

        vm.prank(verifier);
        broadcaster.verify(header, payloadHash, uint64(123));

        // Each replica should be recorded as an attester on the resolved lib
        // with the caller-supplied confirmations forwarded as-is.
        bytes32 headerHash = keccak256(header);
        address[] memory replicas = broadcaster.getReplicas();
        for (uint256 i = 0; i < N; ++i) {
            (bool submitted, uint64 confirmations) =
                IReceiveUln(BASE_RECVLIB).hashLookup(headerHash, payloadHash, replicas[i]);
            assertTrue(submitted, "replica not recorded as attester");
            assertEq(confirmations, 123);
        }
    }

    function test_verify_followsLibRotation() public {
        bytes memory header = _buildHeader();
        bytes32 payloadHash = keccak256("payload-rotate");
        address newLib = makeAddr("newLib");

        // Simulate the endpoint having rotated the active library to newLib for
        // (receiver=RCVR, srcEid=ETH_EID). The broadcaster should follow.
        vm.mockCall(
            BASE_ENDPOINT,
            abi.encodeWithSignature("getReceiveLibrary(address,uint32)", RCVR, ETH_EID),
            abi.encode(newLib, false)
        );
        vm.mockCall(
            newLib,
            abi.encodeWithSignature("verify(bytes,bytes32,uint64)", header, payloadHash, type(uint64).max),
            ""
        );

        // Replicas should now attest to newLib, not BASE_RECVLIB.
        vm.expectCall(
            newLib,
            abi.encodeWithSignature("verify(bytes,bytes32,uint64)", header, payloadHash, type(uint64).max),
            uint64(N)
        );
        vm.expectCall(
            BASE_RECVLIB,
            abi.encodeWithSignature("verify(bytes,bytes32,uint64)", header, payloadHash, type(uint64).max),
            uint64(0)
        );

        vm.prank(verifier);
        broadcaster.verify(header, payloadHash, type(uint64).max);
    }

    // ---------- helpers ----------

    /// Build an 81-byte packet header that passes ReceiveUln302._assertHeader:
    /// length 81, version 1, dstEid bytes (45..49) == localEid. Other fields
    /// are free.
    function _buildHeader() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(1),                                          // version
            uint64(1),                                         // nonce
            ETH_EID,                                           // srcEid
            bytes32(uint256(uint160(0xdead))),                 // sender
            BASE_EID,                                          // dstEid (must match localEid)
            bytes32(uint256(uint160(RCVR)))                    // receiver
        );
    }
}
