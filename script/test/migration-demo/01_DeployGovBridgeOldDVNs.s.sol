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
    SetConfigParam,
    UlnConfig,
    ExecutorConfig
} from "../mocks/LZInterfaces.sol";

import { PauseProxy } from "../mocks/PauseProxy.sol";
import { L1GovernanceRelay } from "../mocks/L1GovernanceRelay.sol";
import { L2GovernanceRelay } from "../mocks/L2GovernanceRelay.sol";
import { GovernanceOAppSender } from "../mocks/GovernanceOAppSender.sol";
import { GovernanceOAppReceiver } from "../mocks/GovernanceOAppReceiver.sol";

// L2 test fixture deployed by this script; also inlined in the canonical
// 01_DeployGovBridge.s.sol. Kept here to keep the demo self-contained.
contract Counter {
    uint256 public count;
    function increment() external { count += 1; }
}

contract CounterIncrementSpell {
    function cast(address counter) external {
        Counter(counter).increment();
    }
}

/// @notice Deploys the Sky LZ governance bridge across Ethereum and Base in one run.
///
/// Phases (all in one script via vm.selectFork; `--multi --broadcast` to actually send):
///   1. L1: PauseProxy, L1GovernanceRelay, GovernanceOAppSender (deployer-owned for now).
///   2. L2: GovernanceOAppReceiver (peered to L1 sender), L2GovernanceRelay.
///   3. L1: wire send-side UlnConfig + Executor, set peer, transfer ownership to PauseProxy.
///   4. L2: wire recv-side UlnConfig, transfer ownership to L2GovernanceRelay.
///
/// Reads: PRIVATE_KEY. MAINNET_RPC_URL / BASE_RPC_URL override forge-std's
///        default RPCs when set.
/// Writes: deployments.json (addresses) at repo root via vm.writeJson.
contract DeployGovBridgeOldDVNs is Script {
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 internal constant CONFIG_TYPE_ULN      = 2;
    uint64 internal constant DEFAULT_CONFIRMATIONS = 1; // minimum override; 0 = "use default"

    Addresses.LZ internal eth;
    Addresses.LZ internal base;

    uint256 internal deployerKey;
    address internal deployer;

    uint256 internal ethFork;
    uint256 internal baseFork;

    PauseProxy              internal pauseProxy;
    L1GovernanceRelay       internal l1Relay;
    GovernanceOAppSender    internal l1Sender;
    GovernanceOAppReceiver  internal l2Receiver;
    L2GovernanceRelay       internal l2Relay;
    Counter                 internal l2Counter;
    CounterIncrementSpell   internal l2CounterSpell;

    function setUp() public {
        eth  = Addresses.ethereum();
        base = Addresses.base();

        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer    = vm.addr(deployerKey);

        // Create both forks once. vm.selectFork preserves in-memory state across
        // phase switches (deployed addresses, etc).
        ethFork  = vm.createFork(getChain("mainnet").rpcUrl);
        baseFork = vm.createFork(getChain("base").rpcUrl);
    }

    function run() external {
        // ---------- Phase 1: L1 deployments ----------
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        pauseProxy = new PauseProxy();
        l1Relay    = new L1GovernanceRelay();
        l1Sender   = new GovernanceOAppSender(eth.endpoint, deployer);

        vm.stopBroadcast();

        console.log("[L1] PauseProxy             ", address(pauseProxy));
        console.log("[L1] L1GovernanceRelay      ", address(l1Relay));
        console.log("[L1] GovernanceOAppSender   ", address(l1Sender));

        // ---------- Phase 2: L2 deployments ----------
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);

        l2Receiver = new GovernanceOAppReceiver(
            eth.eid,
            _toBytes32(address(l1Sender)),
            base.endpoint,
            deployer
        );
        l2Relay = new L2GovernanceRelay(eth.eid, address(l2Receiver), address(l1Relay));

        l2Counter      = new Counter();
        l2CounterSpell = new CounterIncrementSpell();

        vm.stopBroadcast();

        console.log("[L2] GovernanceOAppReceiver ", address(l2Receiver));
        console.log("[L2] L2GovernanceRelay      ", address(l2Relay));
        console.log("[L2] Counter                ", address(l2Counter));
        console.log("[L2] CounterIncrementSpell  ", address(l2CounterSpell));

        // ---------- Phase 3: L1 wiring ----------
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        ILayerZeroEndpointV2(eth.endpoint).setSendLibrary(address(l1Sender), base.eid, eth.sendUln302);

        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam({
            eid:        base.eid,
            configType: CONFIG_TYPE_EXECUTOR,
            config:     abi.encode(ExecutorConfig({ maxMessageSize: 10000, executor: eth.executor }))
        });
        sendParams[1] = SetConfigParam({
            eid:        base.eid,
            configType: CONFIG_TYPE_ULN,
            config:     abi.encode(_buildUlnConfig(eth.dvns))
        });
        ILayerZeroEndpointV2(eth.endpoint).setConfig(address(l1Sender), eth.sendUln302, sendParams);

        l1Sender.setPeer(base.eid, _toBytes32(address(l2Receiver)));

        l1Relay.file("l1Oapp", address(l1Sender));
        l1Sender.setCanCallTarget(
            address(l1Relay),
            base.eid,
            _toBytes32(address(l2Relay)),
            true
        );

        // Hand control to the PauseProxy. setDelegate first so the endpoint
        // recognizes PauseProxy as the OApp's delegate for setConfig calls in
        // future spells; transferOwnership second so PauseProxy owns the OApp.
        // The deployer keeps effective control via pauseProxy.exec(...).
        l1Sender.setDelegate(address(pauseProxy));
        l1Sender.transferOwnership(address(pauseProxy));
        l1Relay.rely(address(pauseProxy));
        l1Relay.deny(deployer);

        vm.stopBroadcast();
        console.log("[L1] Wired send-side UlnConfig + Executor; ownership transferred to PauseProxy");

        // ---------- Phase 4: L2 wiring ----------
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);

        ILayerZeroEndpointV2(base.endpoint).setReceiveLibrary(address(l2Receiver), eth.eid, base.receiveUln302, 0);

        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam({
            eid:        eth.eid,
            configType: CONFIG_TYPE_ULN,
            config:     abi.encode(_buildUlnConfig(base.dvns))
        });
        ILayerZeroEndpointV2(base.endpoint).setConfig(address(l2Receiver), base.receiveUln302, recvParams);

        // Hand control to L2GovernanceRelay. setDelegate first so the endpoint
        // recognizes the relay as the OApp's delegate during future spells;
        // transferOwnership second. After this any change goes through an L1 spell.
        l2Receiver.setDelegate(address(l2Relay));
        l2Receiver.transferOwnership(address(l2Relay));

        vm.stopBroadcast();
        console.log("[L2] Wired recv-side UlnConfig; ownership transferred to L2GovernanceRelay");

        // ---------- Persist addresses ----------
        _writeDeployments();
    }

    /// @dev 4-of-7 LZ-aligned DVNs as optional set, no required DVNs.
    function _buildUlnConfig(address[7] memory dvnsIn) internal pure returns (UlnConfig memory cfg) {
        address[7] memory sorted = Addresses.sortDVNs(dvnsIn);
        address[] memory opt = new address[](7);
        for (uint256 i = 0; i < 7; ++i) opt[i] = sorted[i];

        cfg = UlnConfig({
            confirmations:        DEFAULT_CONFIRMATIONS,
            requiredDVNCount:     type(uint8).max, // NIL: explicit "no required DVNs"
            optionalDVNCount:     7,
            optionalDVNThreshold: 4,
            requiredDVNs:         new address[](0),
            optionalDVNs:         opt
        });
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _writeDeployments() internal {
        string memory j = "deployments";
        vm.serializeAddress(j, "deployer",       deployer);
        vm.serializeAddress(j, "pauseProxy",     address(pauseProxy));
        vm.serializeAddress(j, "l1Relay",        address(l1Relay));
        vm.serializeAddress(j, "l1Sender",       address(l1Sender));
        vm.serializeAddress(j, "l2Receiver",     address(l2Receiver));
        vm.serializeAddress(j, "l2Relay",        address(l2Relay));
        vm.serializeAddress(j, "l2Counter",      address(l2Counter));
        string memory out = vm.serializeAddress(j, "l2CounterSpell", address(l2CounterSpell));
        vm.writeJson(out, "./deployments.json");
        console.log("Wrote deployments.json");
    }
}
