# lz-dvn-broadcaster

`DVNBroadcaster` and `DVNReplica`: a LayerZero V2 building block that lets
an OApp verify a cross-chain message across multiple independent
attestation paths ("wings"); a configurable quorum of them suffices to
deliver. Examples of wings include Chainlink CCIP, Circle CCTP, a
multisig, or a quorum of LZ-aligned DVNs.

The rest of this document describes a concrete example: the **Sky LZ
governance bridge**, with three wings (Chainlink CCIP, a Sky-controlled
multisig, and a quorum of LZ-aligned DVNs), any two sufficient to deliver.

## Wings

1. **CCIP**: attestation relayed via Chainlink CCIP. The L2
   `CCIPDVNAdapter`'s `ccipReceive` reaches `DVNBroadcaster.verify(...)`
   via the LayerZero receiveLibs redirect (see below).
2. **Multisig**: a Sky-controlled Gnosis Safe whose signers validate
   the source packet off-chain, then call `DVNBroadcaster.verify(...)`.
3. **LZ-aligned DVNs**: a quorum across LZ-aligned DVN providers (e.g.
   LZ Labs, Nethermind, Horizen, Deutsche Telekom, Canary, Luganodes, P2P).

Each wing contributes DVN addresses ("slots") to the OApp's optional set,
weighted so any two wings together meet the threshold but no single wing
does. For a parameter N ≥ 1:

| Wing       | Slots  |
| ---------- | ------ |
| CCIP       | N      |
| Multisig   | N      |
| LZ-aligned | 2N − 1 |

Threshold = 2N. Any pair of wings reaches at least 2N; any single wing alone
contributes at most 2N − 1 and falls short.

Concrete example for N = 4 (4 CCIP slots + 4 multisig slots + 7 LZ-aligned
DVNs, threshold 8):

| Combination            | CCIP | Multisig | LZ-aligned | Total |
| ---------------------- | ---- | -------- | ---------- | ----- |
| CCIP + Multisig        | 4    | 4        | 0          | 8     |
| CCIP + 4-of-7 DVNs     | 4    | 0        | 4          | 8     |
| Multisig + 4-of-7 DVNs | 0    | 4        | 4          | 8     |

Any single wing alone (4, 4, or 7) falls short of 8.

## Broadcaster + replicas

The CCIP and multisig wings each use a `DVNBroadcaster` that controls N
`DVNReplica` contracts. The N replica addresses sit in the OApp's recv-side
optional set; a single attestation by the wing's authorized source (the L2
`CCIPDVNAdapter` for CCIP; a Sky-controlled Safe for multisig) fans out so
each replica attests, yielding the wing's N slots toward the quorum. The
LZ-aligned wing's slots are independent third-party DVN addresses listed
directly.

## The receiveLibs redirect

LayerZero's `CCIPDVNAdapter` is used on both L1 and L2 unmodified.
It encodes the destination `receiveLib` from `receiveLibs[sendLib][dstEid]`
into each outbound CCIP message. On the destination, the inherited
`_decodeAndVerify` extracts that address from the payload and calls
`IReceiveUln(addr).verify(...)` on it.

By setting `receiveLibs[L1_sendLib][L2_eid]` on L1 to the CCIP
broadcaster's address, that broadcaster receives the CCIP-attested
`verify(...)` call instead of the L2 receive lib. Its replicas then call
the actual L2 receive lib under their own identities.

The `receiveLibs` mapping is only consumed by source-side `assignJob` in
`DVNAdapterBase` / `CCIPDVNAdapter`; on the receive side the decoded
address is used directly as the `verify(...)` call target with no
validation, so this redirect requires no fork of the adapter.

## UlnConfig

Asymmetric: replicas only appear on the recv side.

**L1 send-side** (`GovernanceOAppSender` to L2 EID):

```
requiredDVNs:         []
requiredDVNCount:     255 (NIL)
optionalDVNs:         [7 LZ-aligned DVNs on Eth, CCIPDVNAdapter]
optionalDVNCount:     8
optionalDVNThreshold: 8   # must be > 1; LZ-aligned DVNs refuse to attest otherwise
```

The `CCIPDVNAdapter`'s `dstConfig.peer` for the L2 EID is set to the L2
`CCIPDVNAdapter` address. `receiveLibs[L1_sendLib][L2_eid]` is set to the
CCIP `DVNBroadcaster` address on L2.

**L2 recv-side** (`GovernanceOAppReceiver` from L1 EID):

```
requiredDVNs:         []
requiredDVNCount:     255 (NIL)
optionalDVNs:         [
    7 LZ-aligned DVNs on L2,
    4 CCIP `DVNReplica`s,
    4 multisig `DVNReplica`s
]
optionalDVNCount:     15
optionalDVNThreshold: 8
```

## Design scope

This broadcaster-replica design is scoped to governance bridging and may not be suitable for other contexts such as token bridging. In particular, the timeout receive library is not supported.
