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

import { Script, console } from "forge-std/Script.sol";

import { Addresses } from "../Addresses.sol";

import {
    ILayerZeroEndpointV2,
    UlnConfig,
    MessagingFee,
    SetConfigParam
} from "../mocks/LZInterfaces.sol";

import { PauseProxy } from "../mocks/PauseProxy.sol";
import { GovernanceOAppSender } from "../mocks/GovernanceOAppSender.sol";
import { TxParams } from "../mocks/IGovernanceOAppSender.sol";

// --------------------------------------------------------------------------
// Spells used only by this migration script; inlined here to keep mocks/
// limited to shared infrastructure.
// --------------------------------------------------------------------------

interface L1RelayLike {
    function relayEVM(
        uint32 dstEid,
        address l2GovernanceRelay,
        address target,
        bytes calldata targetData,
        bytes calldata extraOptions,
        MessagingFee calldata fee,
        address refundAddress
    ) external payable;
}

struct L1MigrationParams {
    address      l1Endpoint;
    address      l1Oapp;
    address      sendLib;
    uint32       dstEid;
    UlnConfig    newSendCfg;
    address      l1Relay;
    address      l2Relay;
    address      l2Spell;
    bytes        l2SpellCallData;
    bytes        extraOptions;
    MessagingFee fee;
}

/// L1 leg of the DVN migration. Delegate-called by `PauseProxy.exec()`, so the
/// call runs in the proxy's context; `msg.sender` at the endpoint is the
/// PauseProxy (set as the OApp's delegate by 01_DeployGovBridgeOldDVNs), and
/// `msg.sender` at the L1 relay is the PauseProxy (its ward).
///
/// Sends the L2 leg first under the still-active old UlnConfig, then rewrites
/// the L1 send-side UlnConfig. Doing relay-then-setConfig avoids re-tasking
/// the new CCIP wing for a message whose recv-side can't count those
/// attestations yet.
contract L1DVNMigrationSpell {
    uint32 internal constant CONFIG_TYPE_ULN = 2;

    function cast(L1MigrationParams calldata p) external payable {
        L1RelayLike(p.l1Relay).relayEVM{ value: p.fee.nativeFee }(
            p.dstEid,
            p.l2Relay,
            p.l2Spell,
            p.l2SpellCallData,
            p.extraOptions,
            p.fee,
            address(this)
        );

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid:        p.dstEid,
            configType: CONFIG_TYPE_ULN,
            config:     abi.encode(p.newSendCfg)
        });
        ILayerZeroEndpointV2(p.l1Endpoint).setConfig(p.l1Oapp, p.sendLib, params);
    }
}

/// L2 leg. Delegate-called by `L2GovernanceRelay.relay()` so the call runs in
/// the relay's context; the endpoint sees `msg.sender = l2Relay` which must
/// be the OApp's delegate.
contract L2DVNMigrationSpell {
    uint32 internal constant CONFIG_TYPE_ULN = 2;

    function cast(
        address endpoint,
        address oapp,
        address recvLib,
        uint32  srcEid,
        UlnConfig calldata newCfg
    ) external payable {
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid:        srcEid,
            configType: CONFIG_TYPE_ULN,
            config:     abi.encode(newCfg)
        });
        ILayerZeroEndpointV2(endpoint).setConfig(oapp, recvLib, params);
    }
}

/// Atomic migration spell, fired from L1 via the PauseProxy. In one tx:
///   1. Sends an L2 reconfig payload through the governance bridge that
///      updates the L2 recv-side UlnConfig to 7 LZ + 4 CCIP + 4 msig
///      replicas, threshold 8.
///   2. Updates L1 send-side UlnConfig to 7 LZ + 1 L1 CCIPDVNAdapter,
///      threshold 8.
///
/// L1 spell deployed inline here so its bytecode lives on-chain (matches the
/// Maker spell pattern). L2 spell likewise deployed on L2.
contract MigrateDVNs is Script {
    uint64  internal constant CONFIRMATIONS    = 1;
    // L2 recv-side setConfig with 15 DVN addresses is ~15 cold SSTOREs alone
    // (~330k). With the 63/64 rule across 4 frames, the executor needs to
    // forward roughly 700k+ to leave enough for setConfig. Budget 1.5M to be
    // safe; unused gas isn't paid for.
    uint128 internal constant LZ_RECEIVE_GAS   = 1_500_000;
    // 0 in UlnConfig = "fall back to default" (which on ETH→Base defaults to
    // LZ Labs + Google as required). 255 = NIL = explicit override-to-nothing.
    // We want a pure optional/threshold quorum, so 255 in both directions.
    uint8   internal constant NIL_DVN_COUNT    = type(uint8).max;

    // type-3 options: lzReceive with LZ_RECEIVE_GAS gas, 0 value.
    // 0003 (type) | 01 (executor) | 0011 (size=17) | 01 (lzReceive) | gas as uint128
    bytes internal extraOptions;

    Addresses.LZ internal eth;
    Addresses.LZ internal base;

    uint256 internal deployerKey;
    address internal deployer;

    uint256 internal ethFork;
    uint256 internal baseFork;

    // From deployments.json
    PauseProxy            internal pauseProxy;
    address               internal l1Relay;
    GovernanceOAppSender  internal l1Sender;
    address               internal l2Receiver;
    address               internal l2Relay;
    address               internal l1CcipAdapter;
    address               internal ccipBroadcaster;
    address[] internal ccipReplicas;
    address               internal msigBroadcaster;
    address[] internal msigReplicas;

    L1DVNMigrationSpell internal l1Spell;
    L2DVNMigrationSpell internal l2Spell;

    function setUp() public {
        eth  = Addresses.ethereum();
        base = Addresses.base();

        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer    = vm.addr(deployerKey);

        ethFork  = vm.createFork(getChain("mainnet").rpcUrl);
        baseFork = vm.createFork(getChain("base").rpcUrl);

        extraOptions = abi.encodePacked(
            uint16(3),               // type 3
            uint8(1),                // executor worker
            uint16(17),              // option size: option_type(1) + gas(16)
            uint8(1),                // lzReceive option
            uint128(LZ_RECEIVE_GAS)
        );

        _readDeployments();
    }

    function run() external {
        // ---------- Phase 1: deploy L2 spell ----------
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);
        l2Spell = new L2DVNMigrationSpell();
        vm.stopBroadcast();
        console.log("[L2] L2DVNMigrationSpell  ", address(l2Spell));

        // ---------- Phase 2: deploy L1 spell ----------
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);
        l1Spell = new L1DVNMigrationSpell();
        vm.stopBroadcast();
        console.log("[L1] L1DVNMigrationSpell  ", address(l1Spell));

        // ---------- Build new UlnConfigs ----------
        UlnConfig memory newSendCfg = _buildL1SendCfg();
        UlnConfig memory newRecvCfg = _buildL2RecvCfg();

        // ---------- Encode the L2 leg ----------
        bytes memory l2CallData = abi.encodeCall(
            L2DVNMigrationSpell.cast,
            (base.endpoint, l2Receiver, base.receiveUln302, eth.eid, newRecvCfg)
        );

        // ---------- Quote LZ fee on L1 ----------
        vm.selectFork(ethFork);
        TxParams memory probe = TxParams({
            dstEid:       base.eid,
            dstTarget:    _toBytes32(l2Relay),
            dstCallData:  abi.encodeWithSignature("relay(address,bytes)", address(l2Spell), l2CallData),
            extraOptions: extraOptions
        });
        MessagingFee memory fee = l1Sender.quoteTx(probe, false);
        console.log("[L1] LZ native fee (wei)   ", fee.nativeFee);

        // Capture the GUID the next send will use (deterministic from
        // nextGuid; endpoint advances on send).
        bytes32 guid = ILayerZeroEndpointV2(eth.endpoint).nextGuid(
            address(l1Sender), base.eid, _toBytes32(l2Receiver)
        );

        // ---------- Phase 3: fire the spell via PauseProxy ----------
        L1MigrationParams memory p = L1MigrationParams({
            l1Endpoint:      eth.endpoint,
            l1Oapp:          address(l1Sender),
            sendLib:         eth.sendUln302,
            dstEid:          base.eid,
            newSendCfg:      newSendCfg,
            l1Relay:         l1Relay,
            l2Relay:         l2Relay,
            l2Spell:         address(l2Spell),
            l2SpellCallData: l2CallData,
            extraOptions:    extraOptions,
            fee:             fee
        });
        bytes memory l1SpellData = abi.encodeCall(L1DVNMigrationSpell.cast, (p));

        vm.startBroadcast(deployerKey);
        pauseProxy.exec{ value: fee.nativeFee }(address(l1Spell), l1SpellData);
        vm.stopBroadcast();

        console.log("[L1] Migration spell cast. guid:");
        console.logBytes32(guid);
        console.log("     Waits on the OLD 4-of-7 LZ quorum to deliver this message to L2.");
        console.log("     LZ Scan:");
        console.log(string.concat("       https://scan.layerzero-api.com/v1/messages/guid/", vm.toString(guid)));
        console.log("     After delivery the L2 UlnConfig becomes 7 LZ + 4 CCIP + 4 msig, threshold 8.");

        _appendSpellAddresses();
    }

    /// Patch existing deployments.json with the two spell addresses (everything
    /// else preserved).
    function _appendSpellAddresses() internal {
        vm.writeJson(vm.toString(address(l1Spell)), "./deployments.json", ".l1MigrationSpell");
        vm.writeJson(vm.toString(address(l2Spell)), "./deployments.json", ".l2MigrationSpell");
        console.log("Wrote spell addresses to deployments.json");
    }

    // ---------- UlnConfig builders ----------

    /// Send-side: 7 LZ-aligned + 1 L1 CCIPDVNAdapter, threshold 8 (matches recv-side).
    function _buildL1SendCfg() internal view returns (UlnConfig memory cfg) {
        address[] memory opt = new address[](8);
        for (uint256 i = 0; i < 7; ++i) opt[i] = eth.dvns[i];
        opt[7] = l1CcipAdapter;
        _sort(opt);

        cfg = UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     8,
            optionalDVNThreshold: 8,
            requiredDVNs:         new address[](0),
            optionalDVNs:         opt
        });
    }

    /// Recv-side: 7 LZ-aligned + 4 CCIP replicas + 4 msig replicas, threshold 8.
    function _buildL2RecvCfg() internal view returns (UlnConfig memory cfg) {
        address[] memory opt = new address[](15);
        for (uint256 i = 0; i < 7; ++i)  opt[i]      = base.dvns[i];
        for (uint256 i = 0; i < 4; ++i)  opt[7 + i]  = ccipReplicas[i];
        for (uint256 i = 0; i < 4; ++i)  opt[11 + i] = msigReplicas[i];
        _sort(opt);

        cfg = UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     15,
            optionalDVNThreshold: 8,
            requiredDVNs:         new address[](0),
            optionalDVNs:         opt
        });
    }

    // ---------- Helpers ----------

    function _sort(address[] memory arr) internal pure {
        uint256 n = arr.length;
        for (uint256 i = 1; i < n; ++i) {
            address k = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > k) {
                arr[j] = arr[j - 1];
                unchecked { --j; }
            }
            arr[j] = k;
        }
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _readDeployments() internal {
        string memory j = vm.readFile("./deployments.json");
        pauseProxy      = PauseProxy(payable(vm.parseJsonAddress(j, ".pauseProxy")));
        l1Relay         = vm.parseJsonAddress(j, ".l1Relay");
        l1Sender        = GovernanceOAppSender(payable(vm.parseJsonAddress(j, ".l1Sender")));
        l2Receiver      = vm.parseJsonAddress(j, ".l2Receiver");
        l2Relay         = vm.parseJsonAddress(j, ".l2Relay");
        l1CcipAdapter   = vm.parseJsonAddress(j, ".l1CcipAdapter");
        ccipBroadcaster = vm.parseJsonAddress(j, ".ccipBroadcaster");
        ccipReplicas    = vm.parseJsonAddressArray(j, ".ccipReplicas");
        msigBroadcaster = vm.parseJsonAddress(j, ".msigBroadcaster");
        msigReplicas    = vm.parseJsonAddressArray(j, ".msigReplicas");
        require(ccipReplicas.length == 4, "Migrate/ccip-replicas-count");
        require(msigReplicas.length == 4, "Migrate/msig-replicas-count");
    }
}
