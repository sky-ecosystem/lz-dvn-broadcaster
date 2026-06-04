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

import { DVNReplica } from "./DVNReplica.sol";

contract DVNBroadcaster {
    event Spawned(address indexed rcvLib, address indexed verifier, address[] replicas);

    address public immutable rcvLib;
    address public immutable verifier;
    DVNReplica[] public replicas;

    constructor(address _rcvLib, address _verifier, uint256 n) {
        require(n > 0, "DVNBroadcaster/zero-replica");
        rcvLib   = _rcvLib;
        verifier = _verifier;

        address[] memory addrs = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            DVNReplica r = new DVNReplica(address(this));
            replicas.push(r);
            addrs[i] = address(r);
        }
        emit Spawned(_rcvLib, _verifier, addrs);
    }

    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64) external {
        require(msg.sender == verifier, "DVNBroadcaster/only-verifier");
        uint256 len = replicas.length;
        for (uint256 i = 0; i < len; ++i) {
            replicas[i].verify(rcvLib, packetHeader, payloadHash);
        }
    }

    function getReplicas() external view returns (address[] memory out) {
        uint256 n = replicas.length;
        out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = address(replicas[i]);
        }
    }

    function getReplicasCount() external view returns (uint256) {
        return replicas.length;
    }
}
