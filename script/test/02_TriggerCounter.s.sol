// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { Script, console } from "forge-std/Script.sol";

import { Addresses } from "./Addresses.sol";

import {
    ILayerZeroEndpointV2,
    MessagingFee
} from "./mocks/LZInterfaces.sol";

import { PauseProxy } from "./mocks/PauseProxy.sol";
import { GovernanceOAppSender } from "./mocks/GovernanceOAppSender.sol";
import { TxParams } from "./mocks/IGovernanceOAppSender.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";
import { CCIPDVNAdapter } from "./mocks/CCIPDVNAdapter.sol";

interface IDVNBroadcaster {
    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64 confirmations) external;
}

/// Selector for the CounterIncrementSpell that 01_DeployGovBridge deployed on
/// L2. Only the function signature matters here; the script just needs it to
/// encode the cross-chain calldata.
interface ICounterIncrementSpell {
    function cast(address counter) external;
}

// --------------------------------------------------------------------------
// Spell used only by this script; inlined here to keep mocks/ limited to
// shared infrastructure.
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

struct L1RelayParams {
    address      l1Relay;
    uint32       dstEid;
    address      l2Relay;
    address      l2Target;
    bytes        l2CallData;
    bytes        extraOptions;
    MessagingFee fee;
}

/// Generic relay spell. Delegate-called by `PauseProxy.exec()`; forwards an
/// arbitrary L2 call through the LZ governance bridge.
contract L1RelaySpell {
    function cast(L1RelayParams calldata p) external payable {
        L1RelayLike(p.l1Relay).relayEVM{ value: p.fee.nativeFee }(
            p.dstEid,
            p.l2Relay,
            p.l2Target,
            p.l2CallData,
            p.extraOptions,
            p.fee,
            address(this)
        );
    }
}

/// End-to-end bridge test. Sends a counter-increment payload from L1 through
/// the governance bridge, then attests on L2 as the multisig wing.
///
/// After the L1 send lands, this script switches to L2 and calls
/// `msigBroadcaster.verify(...)` to inject 4 msig replica attestations.
/// Once 4 LZ-aligned DVNs also attest off-chain, the threshold (8) is met
/// and an executor delivers; Counter.count() goes 0 -> 1.
contract TriggerCounter is Script {
    uint128 internal constant LZ_RECEIVE_GAS = 250_000;

    // Assembled in setUp(): type 3 | executor | size=17 | lzReceive | uint128 gas.
    bytes internal extraOptions;

    Addresses.LZ internal eth;
    Addresses.LZ internal base;

    uint256 internal deployerKey;
    address internal deployer;

    uint256 internal ethFork;
    uint256 internal baseFork;

    // CCIP DVN adapter doesn't keep ETH in steady state, but on the first send
    // the SendLib forwards (totalFee) and the adapter spends (ccipFee); a small
    // topup buffers any quote/execution timing skew. 0.001 ETH covers a
    // mainnet→Base CCIP fee (~0.0001 ETH) with multiplier overhead ~5x over.
    uint256 internal constant CCIP_TOPUP = 0.001 ether;

    // From deployments.json
    PauseProxy           internal pauseProxy;
    address              internal l1Relay;
    GovernanceOAppSender internal l1Sender;
    address              internal l2Receiver;
    address              internal l2Relay;
    address              internal l2Counter;
    address              internal l2CounterSpell;
    address              internal msigBroadcaster;
    address payable      internal l1CcipAdapter;

    L1RelaySpell internal l1Spell;

    /// Toggle: inject msig DVNBroadcaster attestations on L2?
    /// MSIG=true  (default) → 4 msig + 4-of-7 LZ-aligned reaches threshold
    /// MSIG=false           → relies on the CCIP wing's 4 replicas + LZ-aligned
    ///                        DVNs; exercises the receiveLibs redirect path
    bool internal useMsig;

    function setUp() public {
        eth  = Addresses.ethereum();
        base = Addresses.base();

        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer    = vm.addr(deployerKey);

        ethFork  = vm.createFork(vm.envString("ETH_RPC_URL"));
        baseFork = vm.createFork(vm.envString("BASE_RPC_URL"));

        extraOptions = abi.encodePacked(
            uint16(3),               // type 3
            uint8(1),                // executor worker
            uint16(17),              // option size: option_type(1) + gas(16)
            uint8(1),                // lzReceive option
            uint128(LZ_RECEIVE_GAS)
        );

        useMsig = vm.envOr("MSIG", true);

        _readDeployments();
    }

    function run() external {
        // ---------- Phase 1: deploy the L1 relay spell ----------
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);
        l1Spell = new L1RelaySpell();
        vm.stopBroadcast();
        console.log("[L1] L1RelaySpell        ", address(l1Spell));

        // ---------- Phase 2: build the L2 payload ----------
        // l2CallData is the dstCallData embedded in the LZ packet. The L2 receiver
        // decodes (srcSender || dstTarget || dstCallData) and calls dstTarget.call(dstCallData).
        // For our case, dstTarget = l2Relay, dstCallData = relay(spell, cast(counter)).
        bytes memory counterCast = abi.encodeCall(ICounterIncrementSpell.cast, (l2Counter));
        bytes memory l2RelayCall = abi.encodeCall(L2GovernanceRelay.relay, (l2CounterSpell, counterCast));

        // ---------- Phase 3: quote LZ fee ----------
        TxParams memory probe = TxParams({
            dstEid:       base.eid,
            dstTarget:    _toBytes32(l2Relay),
            dstCallData:  l2RelayCall,
            extraOptions: extraOptions
        });
        MessagingFee memory fee = l1Sender.quoteTx(probe, false);
        console.log("[L1] LZ native fee (wei)  ", fee.nativeFee);

        // ---------- Phase 4: pre-compute packet info for msig attestation ----------
        // The endpoint advances nonce on send; capture the next-send values BEFORE broadcasting.
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(eth.endpoint);
        bytes32 receiverB32 = _toBytes32(l2Receiver);
        uint64 nextNonce = ep.outboundNonce(address(l1Sender), base.eid, receiverB32) + 1;
        bytes32 guid     = ep.nextGuid(address(l1Sender), base.eid, receiverB32);

        // OApp packs: bytes32(msgSender) || bytes32(dstTarget) || dstCallData.
        // msg.sender at l1Sender.sendTx is l1Relay (it forwards on our behalf).
        bytes memory lzMessage = abi.encodePacked(
            _toBytes32(l1Relay),
            _toBytes32(l2Relay),
            l2RelayCall
        );
        bytes memory packetHeader = _packetHeader(
            nextNonce,
            eth.eid,
            address(l1Sender),
            base.eid,
            l2Receiver
        );
        bytes32 payloadHash = keccak256(abi.encodePacked(guid, lzMessage));

        // ---------- Phase 5: fire the trigger via PauseProxy ----------
        L1RelayParams memory p = L1RelayParams({
            l1Relay:      l1Relay,
            dstEid:       base.eid,
            l2Relay:      l2Relay,
            l2Target:     l2CounterSpell,
            l2CallData:   counterCast,
            extraOptions: extraOptions,
            fee:          fee
        });
        bytes memory l1SpellData = abi.encodeCall(L1RelaySpell.cast, (p));

        vm.startBroadcast(deployerKey);

        // Topup the L1 CCIP DVN adapter so its `assignJob` can cover the CCIP
        // fee. Atomic with the spell call so failure paths leave nothing stuck.
        (bool topupOk,) = l1CcipAdapter.call{ value: CCIP_TOPUP }("");
        require(topupOk, "TriggerCounter/topup-failed");
        console.log("[L1] Topup to CCIPDVNAdapter (wei)", CCIP_TOPUP);

        pauseProxy.exec{ value: fee.nativeFee }(address(l1Spell), l1SpellData);

        // Recover everything left in the adapter (topup leftover + multiplier
        // profit). withdrawToken with token=0 sends native ETH.
        uint256 leftover = l1CcipAdapter.balance;
        if (leftover > 0) {
            CCIPDVNAdapter(l1CcipAdapter).withdrawToken(address(0), deployer, leftover);
            console.log("[L1] Recovered from CCIPDVNAdapter (wei)", leftover);
        }

        vm.stopBroadcast();

        console.log("[L1] Sent. guid:");
        console.logBytes32(guid);
        console.log("[L1] nonce:", nextNonce);

        // ---------- Phase 6: msig attestation on L2 (optional) ----------
        if (useMsig) {
            vm.selectFork(baseFork);
            vm.startBroadcast(deployerKey);
            IDVNBroadcaster(msigBroadcaster).verify(packetHeader, payloadHash, type(uint64).max);
            vm.stopBroadcast();
            console.log("[L2] Msig wing attested via DVNBroadcaster (4 optional slots).");
            console.log("     Threshold 8 = 4 msig + 4-of-7 LZ-aligned (natural).");
        } else {
            console.log("[L2] MSIG=false; msig wing skipped.");
            console.log("     Threshold 8 must come from CCIP wing (4 replicas via the");
            console.log("     receiveLibs redirect) + 4-of-7 LZ-aligned (natural).");
        }
        console.log("     LZ Scan:");
        console.log(string.concat("       https://scan.layerzero-api.com/v1/messages/guid/", vm.toString(guid)));
    }

    // ---------- Helpers ----------

    /// LZ v2 packet header: version(uint8=1) || nonce(uint64) || srcEid(uint32)
    ///                  || sender(bytes32) || dstEid(uint32) || receiver(bytes32) = 81 bytes
    function _packetHeader(
        uint64  nonce,
        uint32  srcEid,
        address sender,
        uint32  dstEid,
        address receiver
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), nonce, srcEid, _toBytes32(sender), dstEid, _toBytes32(receiver));
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
        l2Counter       = vm.parseJsonAddress(j, ".l2Counter");
        l2CounterSpell  = vm.parseJsonAddress(j, ".l2CounterSpell");
        msigBroadcaster = vm.parseJsonAddress(j, ".msigBroadcaster");
        l1CcipAdapter   = payable(vm.parseJsonAddress(j, ".l1CcipAdapter"));
    }
}
