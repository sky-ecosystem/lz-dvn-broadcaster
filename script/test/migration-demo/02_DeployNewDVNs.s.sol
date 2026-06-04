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
import { DVNBroadcaster } from "../../../src/DVNBroadcaster.sol";

import { CCIPDVNAdapter } from "../mocks/CCIPDVNAdapter.sol";
import { ICCIPDVNAdapter } from "../mocks/ICCIPDVNAdapter.sol";
import { MinimalCCIPDVNAdapterFeeLib } from "../mocks/MinimalCCIPDVNAdapterFeeLib.sol";

interface DVNAdapterBaseLike {
    struct ReceiveLibParam { address sendLib; uint32 dstEid; bytes32 receiveLib; }
    function setReceiveLibs(ReceiveLibParam[] calldata _params) external;
    function setWorkerFeeLib(address _workerFeeLib) external;
    function setDstConfig(ICCIPDVNAdapter.DstConfigParam[] calldata _params) external;
}

/// Deploys both new DVN wings used by the 2-of-3 migration.
///
/// L1: CCIPDVNAdapter + fee lib. Configures dstConfig (peer = L2 CCIPDVNAdapter)
///     and receiveLibs[sendLib][BASE_EID] = L2 CCIP broadcaster, both filled
///     in once the L2 addresses are known.
/// L2: CCIPDVNAdapter + CCIP DVNBroadcaster (verifier = L2
///     CCIPDVNAdapter) + msig DVNBroadcaster (verifier = deployer). N=4
///     replicas per broadcaster.
contract DeployNewDVNs is Script {
    uint256 internal constant N = 4;
    uint256 internal constant CCIP_GAS = 600_000; // L2 ccipReceive: 1 dispatch + 4 replica verify calls

    Addresses.LZ internal eth;
    Addresses.LZ internal base;

    uint256 internal deployerKey;
    address internal deployer;

    uint256 internal ethFork;
    uint256 internal baseFork;

    // L1
    MinimalCCIPDVNAdapterFeeLib internal l1FeeLib;
    CCIPDVNAdapter              internal l1CcipAdapter;

    // L2
    CCIPDVNAdapter              internal l2CcipAdapter;
    DVNBroadcaster              internal ccipBroadcaster;
    DVNBroadcaster              internal msigBroadcaster;

    address[] internal ccipReplicas;
    address[] internal msigReplicas;

    function setUp() public {
        eth  = Addresses.ethereum();
        base = Addresses.base();

        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer    = vm.addr(deployerKey);

        ethFork  = vm.createFork(getChain("mainnet").rpcUrl);
        baseFork = vm.createFork(getChain("base").rpcUrl);
    }

    function run() external {
        address[] memory admins = new address[](1);
        admins[0] = deployer;

        // ---------- Phase 1: L1 partial deploy (peer/receiveLibs filled in Phase 3) ----------
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        l1FeeLib      = new MinimalCCIPDVNAdapterFeeLib();
        l1CcipAdapter = new CCIPDVNAdapter(admins, eth.ccipRouter);
        DVNAdapterBaseLike(address(l1CcipAdapter)).setWorkerFeeLib(address(l1FeeLib));

        vm.stopBroadcast();
        console.log("[L1] CCIPDVNAdapter      ", address(l1CcipAdapter));
        console.log("[L1] CCIP fee lib        ", address(l1FeeLib));

        // ---------- Phase 2: L2 full deploy ----------
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);

        l2CcipAdapter = new CCIPDVNAdapter(admins, base.ccipRouter);

        // CCIP wing: broadcaster's verifier is the L2 CCIPDVNAdapter (reached
        // via receiveLibs redirect from L1).
        ccipBroadcaster = new DVNBroadcaster(base.receiveUln302, address(l2CcipAdapter), N);
        ccipReplicas    = ccipBroadcaster.getReplicas();

        // Msig wing: broadcaster's verifier is the deployer (acting as the Safe).
        msigBroadcaster = new DVNBroadcaster(base.receiveUln302, deployer, N);
        msigReplicas    = msigBroadcaster.getReplicas();

        // L2 CCIPDVNAdapter peer = L1 CCIPDVNAdapter (now known).
        ICCIPDVNAdapter.DstConfigParam[] memory l2Cfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        l2Cfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           eth.eid,
            multiplierBps: 0, // use defaultMultiplierBps (12000)
            chainSelector: eth.ccipChainSelector,
            gas:           CCIP_GAS,
            peer:          abi.encode(address(l1CcipAdapter))
        });
        DVNAdapterBaseLike(address(l2CcipAdapter)).setDstConfig(l2Cfg);

        vm.stopBroadcast();
        console.log("[L2] CCIPDVNAdapter      ", address(l2CcipAdapter));
        console.log("[L2] CCIP DVNBroadcaster ", address(ccipBroadcaster));
        for (uint256 i = 0; i < ccipReplicas.length; ++i) {
            console.log("[L2]    ccip replica     ", ccipReplicas[i]);
        }
        console.log("[L2] msig DVNBroadcaster ", address(msigBroadcaster));
        for (uint256 i = 0; i < msigReplicas.length; ++i) {
            console.log("[L2]    msig replica     ", msigReplicas[i]);
        }

        // ---------- Phase 3: L1 finalize (peer + receiveLibs) ----------
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        ICCIPDVNAdapter.DstConfigParam[] memory l1Cfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        l1Cfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           base.eid,
            multiplierBps: 0,
            chainSelector: base.ccipChainSelector,
            gas:           CCIP_GAS,
            peer:          abi.encode(address(l2CcipAdapter))
        });
        DVNAdapterBaseLike(address(l1CcipAdapter)).setDstConfig(l1Cfg);

        // receiveLibs redirect: when the L1 adapter relays a packet via CCIP,
        // the payload encodes this address as the receive lib. The L2 adapter
        // pulls it out and calls verify(...) on it directly, landing in the
        // CCIP broadcaster instead of the actual L2 ReceiveUln302.
        DVNAdapterBaseLike.ReceiveLibParam[] memory rl = new DVNAdapterBaseLike.ReceiveLibParam[](1);
        rl[0] = DVNAdapterBaseLike.ReceiveLibParam({
            sendLib:    eth.sendUln302,
            dstEid:     base.eid,
            receiveLib: bytes32(uint256(uint160(address(ccipBroadcaster))))
        });
        DVNAdapterBaseLike(address(l1CcipAdapter)).setReceiveLibs(rl);

        vm.stopBroadcast();
        console.log("[L1] dstConfig peer + receiveLibs redirect set");

        _appendDeployments();
    }

    function _appendDeployments() internal {
        string memory path = "./deployments.json";
        string memory j = vm.readFile(path);
        address[8] memory keep = [
            vm.parseJsonAddress(j, ".deployer"),
            vm.parseJsonAddress(j, ".pauseProxy"),
            vm.parseJsonAddress(j, ".l1Relay"),
            vm.parseJsonAddress(j, ".l1Sender"),
            vm.parseJsonAddress(j, ".l2Receiver"),
            vm.parseJsonAddress(j, ".l2Relay"),
            vm.parseJsonAddress(j, ".l2Counter"),
            vm.parseJsonAddress(j, ".l2CounterSpell")
        ];

        string memory k = "deployments";
        vm.serializeAddress(k, "deployer",         keep[0]);
        vm.serializeAddress(k, "pauseProxy",       keep[1]);
        vm.serializeAddress(k, "l1Relay",          keep[2]);
        vm.serializeAddress(k, "l1Sender",         keep[3]);
        vm.serializeAddress(k, "l2Receiver",       keep[4]);
        vm.serializeAddress(k, "l2Relay",          keep[5]);
        vm.serializeAddress(k, "l2Counter",        keep[6]);
        vm.serializeAddress(k, "l2CounterSpell",   keep[7]);
        vm.serializeAddress(k, "l1FeeLib",         address(l1FeeLib));
        vm.serializeAddress(k, "l1CcipAdapter",    address(l1CcipAdapter));
        vm.serializeAddress(k, "l2CcipAdapter",    address(l2CcipAdapter));
        vm.serializeAddress(k, "ccipBroadcaster",  address(ccipBroadcaster));
        vm.serializeAddress(k, "ccipReplicas",     ccipReplicas);
        vm.serializeAddress(k, "msigBroadcaster",  address(msigBroadcaster));
        string memory out = vm.serializeAddress(k, "msigReplicas", msigReplicas);
        vm.writeJson(out, path);
        console.log("Updated deployments.json");
    }
}
