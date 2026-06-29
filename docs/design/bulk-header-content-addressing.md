# Bulk Header Content-Addressing

## Context

Headers-first sync can request a batch of block headers from a peer. The peer
returns `(cid, data)` pairs, and `HeaderChain.downloadHeaders` parses each
`data` as a `Block`, validates proof-of-work, appends a `SyncBlockHeader`, and
stores the bytes locally for later snapshot/state sync.

That bulk path currently trusts the peer-supplied `cid`. This violates the core
content-addressing rule: a CID names bytes, so any bytes received for a CID must
hash back to that CID before they are stored or used as that CID.

This is one instance of the general content-addressed ingress invariant. See
[Content-addressed ingress](content-addressed-ingress.md).

## Problem

In the bulk header path, a malicious peer can return valid block bytes under a
different CID. The code checks:

- `Block(data:)` succeeds
- `block.validateProofOfWork(nexusHash: block.proofOfWorkHash())`
- parent continuity is partly implied by `block.parent?.rawCID`

But it does not check:

```swift
cid == VolumeImpl<Block>(node: block).rawCID
```

So the node can store valid bytes under a peer-chosen name. Later code may refer
to that forged name as if it were the content address of the block.

Sequential sync is less exposed because it fetches bytes by `currentCID` through
the normal fetcher path, but the same invariant should still be explicit at the
header acceptance boundary.

## Design

Add one local validation step before a downloaded block is accepted as a header,
and make path continuity explicit:

1. Track the next expected CID before decoding:
   - for the first bulk item, this is the requested cursor (`nextCID`)
   - for later bulk items, this is the previous accepted block's
     `parent.rawCID`
   - for sequential sync, this is `currentCID`
2. Require the peer's tuple CID to equal the next expected CID.
3. Decode `Block(data:)`.
4. Compute the canonical block CID with `VolumeImpl<Block>(node: block).rawCID`.
5. Reject the header if the canonical CID does not equal the expected CID.
6. Only after that, validate proof-of-work, append the header, report progress,
   and store the bytes.

This should be implemented as a small helper on `HeaderChain` so both paths use
the same check and the error behavior stays consistent.

## Error Semantics

Introduce a specific `HeaderChainError.cidMismatch(expected:actual:)`.

This is not a fetch failure and not a PoW failure. It means the peer supplied
bytes that do not satisfy the content-addressing contract. The offending batch is
rejected and never falls through to store poisoned data — but the node does **not**
abort the whole sync on it: it rolls back, penalizes that peer, and rotates to the
next candidate, because one bad peer must not wedge sync. See
[Source-agnostic header sync](source-agnostic-sync.md).

Keep `HeaderChainError.chainContinuityBroken(expected:got:)` for a different
case: the peer returned a tuple CID that does not match the next CID in the
walk. In other words:

- `chainContinuityBroken`: the peer gave the wrong next header
- `cidMismatch`: the peer gave bytes that do not hash to the header CID being
  accepted

## Non-Goals

- Do not redesign header sync or fork choice.
- Do not add a new trust model for peers.
- Do not verify full block state here. State validation remains in normal block
  processing.
- Do not synthesize or store alternate roots. The only valid root for block bytes
  is the block's canonical content address.
