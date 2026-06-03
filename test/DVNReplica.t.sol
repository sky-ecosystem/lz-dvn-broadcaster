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
import { DVNReplica } from "../src/DVNReplica.sol";

interface IReceiveUln {
    function hashLookup(bytes32 headerHash, bytes32 payloadHash, address dvn)
        external view returns (bool submitted, uint64 confirmations);
}

contract DVNReplicaTest is Test {
    address constant BASE_RECVLIB = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
    uint32  constant BASE_EID     = 30184;

    DVNReplica replica;

    address verifier = makeAddr("verifier");

    function setUp() public {
        vm.createSelectFork(getChain("base").rpcUrl);
        replica = new DVNReplica(verifier);
    }

    function test_constructor_setsVerifier() public view {
        assertEq(replica.verifier(), verifier);
    }

    function test_verify_callableOnlyByVerifier() public {
        vm.expectRevert("DVNReplica/only-verifier");
        replica.verify(address(0), "", bytes32(0));
    }

    function test_verify_writesToRecvLibAsThisReplica() public {
        bytes memory header = _buildHeader();
        bytes32 payloadHash = keccak256("payload");

        vm.expectCall(
            BASE_RECVLIB,
            abi.encodeWithSignature(
                "verify(bytes,bytes32,uint64)", header, payloadHash, type(uint64).max
            ),
            uint64(1)
        );

        vm.prank(verifier);
        replica.verify(BASE_RECVLIB, header, payloadHash);

        (bool submitted, uint64 confirmations) =
            IReceiveUln(BASE_RECVLIB).hashLookup(keccak256(header), payloadHash, address(replica));
        assertTrue(submitted, "replica not recorded as attester");
        assertEq(confirmations, type(uint64).max);
    }

    // ---------- helpers ----------

    /// Build an 81-byte packet header that passes ReceiveUln302._assertHeader:
    /// length 81, version 1, dstEid bytes (73..77) == localEid. Other fields
    /// are free.
    function _buildHeader() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(1),                                          // version
            uint64(1),                                         // nonce
            uint32(30101),                                     // srcEid (Eth)
            bytes32(uint256(uint160(0xdead))),                 // sender
            BASE_EID,                                          // dstEid (must match localEid)
            bytes32(uint256(uint160(0xbeef)))                  // receiver
        );
    }
}
