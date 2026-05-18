# lz-gov-dvns

Auxiliary verification contracts for the **Sky LZ governance bridge**. An
L1 → L2 governance packet can be verified across three independent
attestation paths, any two of which suffice to deliver.

## The three wings

1. **CCIP wing**: attestation relayed via Chainlink CCIP. `CCIPBroadcaster`
   on L2 receives the CCIP message and dispatches `verify()` to N
   `DVNReplica` instances.
2. **Multisig wing**: a Sky-controlled Gnosis Safe. Signers validate the
   source packet off-chain, then batch-call `verify()` on N `DVNReplica`
   instances in one signed tx.
3. **LZ-aligned DVN wing**: a quorum across LZ-aligned DVNs (e.g.
   LZ Labs, Nethermind, Horizen, Deutsche Telekom, Canary, Luganodes, P2P)
   listed in the OApp's `UlnConfig`.

Each wing contributes DVN addresses ("slots") to the OApp's optional set,
weighted so any two wings together meet the threshold but no single wing
does. For a parameter N ≥ 1:

| Wing | Slots |
|---|---|
| CCIP | N |
| Multisig | N |
| LZ-aligned | 2N − 1 |

Threshold = 2N. Any pair of wings reaches 2N exactly; any single wing alone
contributes at most 2N − 1 and falls short.

Concrete example for N = 4 (4 CCIP slots + 4 multisig slots + 7 LZ-aligned
DVNs, threshold 8):

| Combination | CCIP | Multisig | LZ-aligned | Total |
|---|---|---|---|---|
| CCIP + Multisig | 4 | 4 | 0 | 8 |
| CCIP + 4-of-7 DVNs | 4 | 0 | 4 | 8 |
| Multisig + 4-of-7 DVNs | 0 | 4 | 4 | 8 |

Any single wing alone (4, 4, or 7) falls short of 8.

## UlnConfig

Asymmetric: replicas only appear on the recv side.

**L1 send-side** (`GovernanceOAppSender` to L2 EID):

```
requiredDVNs:         []
requiredDVNCount:     255 (NIL)
optionalDVNs:         [7 LZ-aligned DVNs on Eth, CCIPDVNAdapter]
optionalDVNCount:     8
optionalDVNThreshold: 1
```

The `CCIPDVNAdapter`'s `dstConfig.peer` for the L2 EID is set to the
`CCIPBroadcaster` address.

**L2 recv-side** (`GovernanceOAppReceiver` from L1 EID):

```
requiredDVNs:         []
requiredDVNCount:     255 (NIL)
optionalDVNs:         [
    7 LZ-aligned DVNs on L2,
    4 CCIP replicas (verifier = CCIPBroadcaster),
    4 multisig replicas (verifier = Gnosis Safe)
]
optionalDVNCount:     15
optionalDVNThreshold: 8
```
