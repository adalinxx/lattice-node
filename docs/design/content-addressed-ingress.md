# Content-Addressed Ingress

## Status

Design invariant. This document describes the rule every implementation path
must preserve when accepting externally supplied content-addressed data.

## Principle

In Lattice, a CID is not a peer assertion. It is the name of canonical bytes.
Any external ingress that accepts `(cid, bytes)` or a serialized volume root
must verify that the bytes hash back to that CID before the data is stored,
indexed, relayed, announced, marked available, or used by consensus code.

Equivalently:

```swift
computedCID(canonicalDecode(bytes)) == claimedCID
```

For volumes, the root and every fetched child entry must satisfy the same
content-addressing contract through the Volume/Cashew resolution path.

## Ingress Surface

This invariant applies at every trust boundary, including:

- P2P full block gossip.
- Child block extraction and proof payloads.
- Header sync and bulk header batches.
- Ivy fetch responses and provider records.
- Storage APIs that accept caller-supplied CIDs or volume roots.
- RPC or mining endpoints that accept serialized content-addressed objects.
- DHT/provider availability paths before local availability is advertised.

The exact implementation should live at the lowest primitive boundary that has
enough information to check it. For example, generic volume child verification
belongs in Cashew/Volume resolution, while header-chain walk continuity belongs
in header sync because only that layer knows the next expected block CID.

## Failure Semantics

On mismatch, the node must reject the ingress item and must not:

- store the bytes under the claimed CID;
- pin or index the claimed CID;
- relay or announce the claimed CID as available;
- continue consensus validation as if the content address were valid.

CID validity is separate from protocol validity. Content-addressing proves the
bytes are the bytes named by the CID; block validation, proof-of-work, state
transition checks, signatures, and chain continuity are still required after the
content-addressing check passes.
