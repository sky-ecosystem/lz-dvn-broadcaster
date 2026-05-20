// SPDX-License-Identifier: AGPL-3.0-or-later
// Minimal Sky/Maker DSPauseProxy analog: ward-gated delegatecall executor.
pragma solidity ^0.8.22;

contract PauseProxy {
    mapping(address => uint256) public wards;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Exec(address indexed target, bytes data);

    modifier auth() {
        require(wards[msg.sender] == 1, "PauseProxy/not-authorized");
        _;
    }

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    receive() external payable {}

    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }

    function exec(address target, bytes calldata data) external payable auth returns (bytes memory out) {
        bool ok;
        (ok, out) = target.delegatecall(data);
        if (!ok) {
            if (out.length == 0) revert("PauseProxy/delegatecall-error");
            assembly ("memory-safe") { revert(add(32, out), mload(out)) }
        }
        emit Exec(target, data);
    }
}
