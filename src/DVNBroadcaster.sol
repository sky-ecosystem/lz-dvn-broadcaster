// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { DVNReplica } from "./DVNReplica.sol";

contract DVNBroadcaster {
    event Spawned(address indexed verifier, address rcvLib, address[] replicas);

    address public immutable rcvLib;
    address public immutable verifier;
    DVNReplica[] public replicas;

    constructor(address _rcvLib, address _verifier, uint256 n) {
        require(n > 0, "DVNBroadcaster/zero-replicas");
        rcvLib   = _rcvLib;
        verifier = _verifier;

        address[] memory addrs = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            DVNReplica r = new DVNReplica(address(this));
            replicas.push(r);
            addrs[i] = address(r);
        }
        emit Spawned(_verifier, _rcvLib, addrs);
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
}
