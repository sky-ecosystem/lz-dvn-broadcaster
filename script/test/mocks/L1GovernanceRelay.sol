// SPDX-License-Identifier: AGPL-3.0-or-later
// Inlined from sky-ecosystem/lz-governance-relay @ master
pragma solidity ^0.8.22;

import { IGovernanceOAppSender, TxParams } from "./IGovernanceOAppSender.sol";
import { MessagingFee } from "./LZInterfaces.sol";

interface TokenLike {
    function approve(address spender, uint256 amount) external;
    function transfer(address recipient, uint256 amount) external;
}

interface L2GovernanceRelayLike {
    function relay(address target, bytes calldata targetData) external;
}

contract L1GovernanceRelay {
    mapping(address => uint256) public wards;
    TokenLike                   public lzToken;
    IGovernanceOAppSender       public l1Oapp;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);

    modifier auth() {
        require(wards[msg.sender] == 1, "L1GovernanceRelay/not-authorized");
        _;
    }

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, address data) external auth {
        if      (what == "lzToken") lzToken = TokenLike(data);
        else if (what == "l1Oapp")  l1Oapp  = IGovernanceOAppSender(data);
        else revert("L1GovernanceRelay/file-unrecognized-param");
        emit File(what, data);
    }

    receive() external payable {}

    function reclaim(address receiver, uint256 amount) external auth {
        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "L1GovernanceRelay/failed-to-send-ether");
    }

    function reclaimLzToken(address receiver, uint256 amount) external auth {
        lzToken.transfer(receiver, amount);
    }

    function relayEVM(
        uint32                dstEid,
        address               l2GovernanceRelay,
        address               target,
        bytes calldata        targetData,
        bytes calldata        extraOptions,
        MessagingFee calldata fee,
        address               refundAddress
    ) external payable auth {
        TxParams memory txParams = TxParams({
            dstEid       : dstEid,
            dstTarget    : bytes32(uint256(uint160(address(l2GovernanceRelay)))),
            dstCallData  : abi.encodeCall(L2GovernanceRelayLike.relay, (target, targetData)),
            extraOptions : extraOptions
        });
        _send(txParams, fee, refundAddress);
    }

    function relayRaw(
        TxParams calldata     txParams,
        MessagingFee calldata fee,
        address               refundAddress
    ) external payable auth {
        _send(txParams, fee, refundAddress);
    }

    function _send(
        TxParams memory       txParams,
        MessagingFee calldata fee,
        address               refundAddress
    ) internal {
        if (fee.lzTokenFee > 0) lzToken.approve(address(l1Oapp), fee.lzTokenFee);
        l1Oapp.sendTx{value: fee.nativeFee}(txParams, fee, refundAddress);
    }
}
