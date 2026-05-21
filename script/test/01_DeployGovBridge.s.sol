// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

import { Addresses } from "./Addresses.sol";

import {
    ILayerZeroEndpointV2,
    SetConfigParam,
    UlnConfig,
    ExecutorConfig
} from "./mocks/LZInterfaces.sol";

import { PauseProxy } from "./mocks/PauseProxy.sol";
import { L1GovernanceRelay } from "./mocks/L1GovernanceRelay.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";
import { GovernanceOAppSender } from "./mocks/GovernanceOAppSender.sol";
import { GovernanceOAppReceiver } from "./mocks/GovernanceOAppReceiver.sol";

import { CCIPDVNAdapter } from "./mocks/CCIPDVNAdapter.sol";
import { ICCIPDVNAdapter } from "./mocks/ICCIPDVNAdapter.sol";
import { MinimalCCIPDVNAdapterFeeLib } from "./mocks/MinimalCCIPDVNAdapterFeeLib.sol";

import { DVNBroadcaster } from "../../src/DVNBroadcaster.sol";

interface DVNAdapterBaseLike {
    struct ReceiveLibParam { address sendLib; uint32 dstEid; bytes32 receiveLib; }
    function setReceiveLibs(ReceiveLibParam[] calldata _params) external;
    function setWorkerFeeLib(address _workerFeeLib) external;
    function setDstConfig(ICCIPDVNAdapter.DstConfigParam[] calldata _params) external;
}

// --------------------------------------------------------------------------
// Test fixture deployed on L2: a counter whose increment is exercised by the
// 02_TriggerCounter end-to-end test. Inlined here because it's only deployed
// here; 02 imports the addresses from deployments.json and uses a local
// interface for the spell selector.
// --------------------------------------------------------------------------

contract Counter {
    uint256 public count;
    function increment() external { count += 1; }
}

/// Delegatecall-safe spell for `L2GovernanceRelay.relay()`. The relay does
/// `target.delegatecall(targetData)`, so `cast(...)` runs in the relay's
/// storage context. Routing the bump through a regular external call keeps
/// Counter's storage isolated from the relay's.
contract CounterIncrementSpell {
    function cast(address counter) external {
        Counter(counter).increment();
    }
}

/// Single-shot deploy of the full Sky LZ governance bridge with the 2-of-3
/// DVN configuration applied directly at construction (no migration needed).
///
/// Phases (in one script run via vm.selectFork; `--multi --broadcast`):
///   1. L1: deploy PauseProxy, L1GovernanceRelay, GovernanceOAppSender,
///          MinimalCCIPDVNAdapterFeeLib, CCIPDVNAdapter.
///   2. L2: deploy GovernanceOAppReceiver, L2GovernanceRelay,
///          MinimalCCIPDVNAdapterFeeLib, CCIPDVNAdapter, CCIP DVNBroadcaster
///          (verifier = L2 CCIPDVNAdapter), msig DVNBroadcaster
///          (verifier = deployer), Counter, CounterIncrementSpell.
///   3. L1: wire send lib + Executor + UlnConfig (8 optional [7 LZ-aligned +
///          L1 CCIPDVNAdapter], NIL required, threshold 8), set peer, wire
///          L1Relay (file l1Oapp + canCallTarget), set L1 CCIPDVNAdapter
///          dstConfig + receiveLibs redirect (-> L2 CCIP broadcaster).
///          Then setDelegate + transferOwnership to PauseProxy.
///   4. L2: wire recv lib + UlnConfig (15 optional [7 LZ-aligned + 4 CCIP
///          replicas + 4 msig replicas], NIL required, threshold 8), set L2
///          CCIPDVNAdapter dstConfig. setDelegate + transferOwnership to
///          L2GovernanceRelay.
///
/// Writes deployments.json. After this runs, 02_TriggerCounter is the next
/// script (no migration in between).
contract DeployGovBridge is Script {
    uint32  internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32  internal constant CONFIG_TYPE_ULN      = 2;
    uint64  internal constant DEFAULT_CONFIRMATIONS = 1;
    uint8   internal constant NIL_DVN_COUNT        = type(uint8).max;
    uint256 internal constant N                    = 4;       // replicas per wing
    uint256 internal constant CCIP_GAS             = 600_000; // L2 ccipReceive budget

    Addresses.LZ internal eth;
    Addresses.LZ internal base;

    uint256 internal deployerKey;
    address internal deployer;
    uint256 internal ethFork;
    uint256 internal baseFork;

    // L1
    PauseProxy                   internal pauseProxy;
    L1GovernanceRelay            internal l1Relay;
    GovernanceOAppSender         internal l1Sender;
    MinimalCCIPDVNAdapterFeeLib  internal l1FeeLib;
    CCIPDVNAdapter               internal l1CcipAdapter;

    // L2
    GovernanceOAppReceiver       internal l2Receiver;
    L2GovernanceRelay            internal l2Relay;
    MinimalCCIPDVNAdapterFeeLib  internal l2FeeLib;
    CCIPDVNAdapter               internal l2CcipAdapter;
    DVNBroadcaster               internal ccipBroadcaster;
    DVNBroadcaster               internal msigBroadcaster;
    Counter                      internal l2Counter;
    CounterIncrementSpell        internal l2CounterSpell;

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
        _phase1_L1Deploy();
        _phase2_L2Deploy();
        _phase3_L1Wire();
        _phase4_L2Wire();
        _writeDeployments();
    }

    // ==========================================================================
    // Phase 1: L1 deployments
    // ==========================================================================
    function _phase1_L1Deploy() internal {
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        pauseProxy = new PauseProxy();
        l1Relay    = new L1GovernanceRelay();
        l1Sender   = new GovernanceOAppSender(eth.endpoint, deployer);

        l1FeeLib       = new MinimalCCIPDVNAdapterFeeLib();
        address[] memory admins = new address[](1);
        admins[0] = deployer;
        l1CcipAdapter = new CCIPDVNAdapter(admins, eth.ccipRouter);
        DVNAdapterBaseLike(address(l1CcipAdapter)).setWorkerFeeLib(address(l1FeeLib));

        vm.stopBroadcast();

        console.log("[L1] PauseProxy             ", address(pauseProxy));
        console.log("[L1] L1GovernanceRelay      ", address(l1Relay));
        console.log("[L1] GovernanceOAppSender   ", address(l1Sender));
        console.log("[L1] CCIP fee lib           ", address(l1FeeLib));
        console.log("[L1] CCIPDVNAdapter         ", address(l1CcipAdapter));
    }

    // ==========================================================================
    // Phase 2: L2 deployments (needs L1 addresses already known)
    // ==========================================================================
    function _phase2_L2Deploy() internal {
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);

        l2Receiver = new GovernanceOAppReceiver(
            eth.eid,
            _toBytes32(address(l1Sender)),
            base.endpoint,
            deployer
        );
        l2Relay = new L2GovernanceRelay(eth.eid, address(l2Receiver), address(l1Relay));

        l2FeeLib       = new MinimalCCIPDVNAdapterFeeLib();
        address[] memory admins = new address[](1);
        admins[0] = deployer;
        l2CcipAdapter = new CCIPDVNAdapter(admins, base.ccipRouter);
        DVNAdapterBaseLike(address(l2CcipAdapter)).setWorkerFeeLib(address(l2FeeLib));

        ccipBroadcaster = new DVNBroadcaster(base.receiveUln302, address(l2CcipAdapter), N);
        ccipReplicas    = ccipBroadcaster.getReplicas();

        msigBroadcaster = new DVNBroadcaster(base.receiveUln302, deployer, N);
        msigReplicas    = msigBroadcaster.getReplicas();

        l2Counter      = new Counter();
        l2CounterSpell = new CounterIncrementSpell();

        // L2 CCIPDVNAdapter dstConfig: peer = L1 CCIPDVNAdapter (known).
        ICCIPDVNAdapter.DstConfigParam[] memory cfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        cfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           eth.eid,
            multiplierBps: 0,
            chainSelector: eth.ccipChainSelector,
            gas:           CCIP_GAS,
            peer:          abi.encode(address(l1CcipAdapter))
        });
        DVNAdapterBaseLike(address(l2CcipAdapter)).setDstConfig(cfg);

        vm.stopBroadcast();

        console.log("[L2] GovernanceOAppReceiver ", address(l2Receiver));
        console.log("[L2] L2GovernanceRelay      ", address(l2Relay));
        console.log("[L2] CCIP fee lib           ", address(l2FeeLib));
        console.log("[L2] CCIPDVNAdapter         ", address(l2CcipAdapter));
        console.log("[L2] CCIP DVNBroadcaster    ", address(ccipBroadcaster));
        for (uint256 i = 0; i < ccipReplicas.length; ++i) {
            console.log("[L2]    ccip replica        ", ccipReplicas[i]);
        }
        console.log("[L2] msig DVNBroadcaster    ", address(msigBroadcaster));
        for (uint256 i = 0; i < msigReplicas.length; ++i) {
            console.log("[L2]    msig replica        ", msigReplicas[i]);
        }
        console.log("[L2] Counter                ", address(l2Counter));
        console.log("[L2] CounterIncrementSpell  ", address(l2CounterSpell));
    }

    // ==========================================================================
    // Phase 3: L1 wiring
    // ==========================================================================
    function _phase3_L1Wire() internal {
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(eth.endpoint);

        // Send library
        ep.setSendLibrary(address(l1Sender), base.eid, eth.sendUln302);

        // Executor + UlnConfig (2-of-3 layout)
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam({
            eid:        base.eid,
            configType: CONFIG_TYPE_EXECUTOR,
            config:     abi.encode(ExecutorConfig({ maxMessageSize: 10000, executor: eth.executor }))
        });
        sendParams[1] = SetConfigParam({
            eid:        base.eid,
            configType: CONFIG_TYPE_ULN,
            config:     abi.encode(_buildL1SendCfg())
        });
        ep.setConfig(address(l1Sender), eth.sendUln302, sendParams);

        // Peer
        l1Sender.setPeer(base.eid, _toBytes32(address(l2Receiver)));

        // L1Relay wiring
        l1Relay.file("l1Oapp", address(l1Sender));
        l1Sender.setCanCallTarget(
            address(l1Relay),
            base.eid,
            _toBytes32(address(l2Relay)),
            true
        );

        // L1 CCIPDVNAdapter: dstConfig + receiveLibs redirect
        ICCIPDVNAdapter.DstConfigParam[] memory cfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        cfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           base.eid,
            multiplierBps: 0,
            chainSelector: base.ccipChainSelector,
            gas:           CCIP_GAS,
            peer:          abi.encode(address(l2CcipAdapter))
        });
        DVNAdapterBaseLike(address(l1CcipAdapter)).setDstConfig(cfg);

        DVNAdapterBaseLike.ReceiveLibParam[] memory rl = new DVNAdapterBaseLike.ReceiveLibParam[](1);
        rl[0] = DVNAdapterBaseLike.ReceiveLibParam({
            sendLib:    eth.sendUln302,
            dstEid:     base.eid,
            receiveLib: bytes32(uint256(uint160(address(ccipBroadcaster))))
        });
        DVNAdapterBaseLike(address(l1CcipAdapter)).setReceiveLibs(rl);

        // Hand control to PauseProxy.
        l1Sender.setDelegate(address(pauseProxy));
        l1Sender.transferOwnership(address(pauseProxy));
        l1Relay.rely(address(pauseProxy));
        l1Relay.deny(deployer);

        vm.stopBroadcast();
        console.log("[L1] Wired send-side (8 optional, NIL required, threshold 8); ownership -> PauseProxy");
    }

    // ==========================================================================
    // Phase 4: L2 wiring
    // ==========================================================================
    function _phase4_L2Wire() internal {
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(base.endpoint);
        ep.setReceiveLibrary(address(l2Receiver), eth.eid, base.receiveUln302, 0);

        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam({
            eid:        eth.eid,
            configType: CONFIG_TYPE_ULN,
            config:     abi.encode(_buildL2RecvCfg())
        });
        ep.setConfig(address(l2Receiver), base.receiveUln302, recvParams);

        // Hand control to L2GovernanceRelay.
        l2Receiver.setDelegate(address(l2Relay));
        l2Receiver.transferOwnership(address(l2Relay));

        vm.stopBroadcast();
        console.log("[L2] Wired recv-side (15 optional, NIL required, threshold 8); ownership -> L2GovernanceRelay");
    }

    // ==========================================================================
    // UlnConfig builders (2-of-3 layout, NIL required)
    // ==========================================================================

    /// L1 send-side: 7 LZ-aligned + 1 L1 CCIPDVNAdapter, threshold 8, no required.
    function _buildL1SendCfg() internal view returns (UlnConfig memory cfg) {
        address[] memory opt = new address[](8);
        for (uint256 i = 0; i < 7; ++i) opt[i] = eth.dvns[i];
        opt[7] = address(l1CcipAdapter);
        _sort(opt);

        cfg = UlnConfig({
            confirmations:        DEFAULT_CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     8,
            optionalDVNThreshold: 8,
            requiredDVNs:         new address[](0),
            optionalDVNs:         opt
        });
    }

    /// L2 recv-side: 7 LZ-aligned + 4 CCIP replicas + 4 msig replicas, threshold 8, no required.
    function _buildL2RecvCfg() internal view returns (UlnConfig memory cfg) {
        address[] memory opt = new address[](15);
        for (uint256 i = 0; i < 7; ++i)  opt[i]      = base.dvns[i];
        for (uint256 i = 0; i < 4; ++i)  opt[7 + i]  = ccipReplicas[i];
        for (uint256 i = 0; i < 4; ++i)  opt[11 + i] = msigReplicas[i];
        _sort(opt);

        cfg = UlnConfig({
            confirmations:        DEFAULT_CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     15,
            optionalDVNThreshold: 8,
            requiredDVNs:         new address[](0),
            optionalDVNs:         opt
        });
    }

    // ==========================================================================
    // Helpers
    // ==========================================================================

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

    function _writeDeployments() internal {
        string memory k = "deployments";
        vm.serializeAddress(k, "deployer",         deployer);
        vm.serializeAddress(k, "pauseProxy",       address(pauseProxy));
        vm.serializeAddress(k, "l1Relay",          address(l1Relay));
        vm.serializeAddress(k, "l1Sender",         address(l1Sender));
        vm.serializeAddress(k, "l2Receiver",       address(l2Receiver));
        vm.serializeAddress(k, "l2Relay",          address(l2Relay));
        vm.serializeAddress(k, "l2Counter",        address(l2Counter));
        vm.serializeAddress(k, "l2CounterSpell",   address(l2CounterSpell));
        vm.serializeAddress(k, "l1FeeLib",         address(l1FeeLib));
        vm.serializeAddress(k, "l1CcipAdapter",    address(l1CcipAdapter));
        vm.serializeAddress(k, "l2FeeLib",         address(l2FeeLib));
        vm.serializeAddress(k, "l2CcipAdapter",    address(l2CcipAdapter));
        vm.serializeAddress(k, "ccipBroadcaster",  address(ccipBroadcaster));
        vm.serializeAddress(k, "ccipReplicas",     ccipReplicas);
        vm.serializeAddress(k, "msigBroadcaster",  address(msigBroadcaster));
        string memory out = vm.serializeAddress(k, "msigReplicas", msigReplicas);
        vm.writeJson(out, "./deployments.json");
        console.log("Wrote deployments.json");
    }
}
