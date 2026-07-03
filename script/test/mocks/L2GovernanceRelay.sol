// SPDX-License-Identifier: AGPL-3.0-or-later
// Inlined from sky-ecosystem/lz-governance-relay @ master
pragma solidity ^0.8.22;

import { IGovernanceOAppReceiver, MessageOrigin } from "./IGovernanceOAppReceiver.sol";

contract L2GovernanceRelay {
    IGovernanceOAppReceiver public l2Oapp;
    address                 public l1GovernanceRelay;

    uint32 immutable public l1Eid;

    event File(bytes32 indexed what, address data);

    modifier messageAuth() {
        MessageOrigin memory mo = l2Oapp.messageOrigin();
        require(
            msg.sender                                == address(l2Oapp) &&
            mo.srcEid                                 == l1Eid &&
            address(uint160(uint256(mo.srcSender)))   == l1GovernanceRelay,
            "L2GovernanceRelay/bad-message-auth"
        );
        _;
    }

    constructor(uint32 _l1Eid, address _l2Oapp, address _l1GovernanceRelay) {
        l1Eid             = _l1Eid;
        l2Oapp            = IGovernanceOAppReceiver(_l2Oapp);
        l1GovernanceRelay = _l1GovernanceRelay;
    }

    function file(bytes32 what, address data) external {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        if      (what == "l2Oapp")            l2Oapp            = IGovernanceOAppReceiver(data);
        else if (what == "l1GovernanceRelay") l1GovernanceRelay = data;
        else revert("L2GovernanceRelay/file-unrecognized-param");
        emit File(what, data);
    }

    function relay(address target, bytes calldata targetData) external messageAuth {
        (bool success, bytes memory result) = target.delegatecall(targetData);
        if (!success) {
            if (result.length == 0) revert("L2GovernanceRelay/delegatecall-error");
            assembly ("memory-safe") {
                revert(add(32, result), mload(result))
            }
        }
    }
}
