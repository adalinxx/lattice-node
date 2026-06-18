# Block Content Storage

This note defines what a node must resolve and store when it receives a gossiped
block, under the **object-grain content-store** model (the content-store cutover).

## Mental Model

A gossiped block is not durable chain data yet. It is a compact claim: enough
bytes to identify the block, check cheap header-level properties, and discover
the object roots the receiver must resolve.

A block is stored as **one object closure**: a single `storeRecursively` pass
over the block produces per-boundary volumes joined by VolumeBroker **owned-child
edges**, rooted at the block CID. There is no singleton promotion — content keeps
its closure grain, so a single `retain(blockRoot)` transitively protects the
whole closure. Content is **resolved by CID** (`fetchData(cid:)` over the broker
tier / a cashew `ContentSource`), independent of Volume grain — *not* by entering
or fetching whole Volume roots. (cashew 3.x removed the fetch-side
`VolumeAwareFetcher`/`enterVolume` pre-fetch; resolution is per-CID, batched per
wave.)

## What a block owns vs references

The block's **owned closure** (walked by `storeRecursively`, edged, and protected
by a pin on the block root):

- the block volume, rooted at the block CID, holding the in-package `transactions`
  and `children` dictionary headers
- each transaction's body volume
- the chain `spec` volume (a chain-shared leaf, kept transitively while any block
  of the chain is pinned)
- the `postState` frontier — its `LatticeState` and the five sub-state tries
- descendant `children` block volumes

The block's **references** (cashew `Reference<T>` — *not* owned children, never
walked, never edged, fetched by CID on demand):

- `prevState` — the prior block's already-stored owned `postState`
- `parentState` — the parent chain's state
- `parent` — the ancestor block

Because references are not edged, pinning a block root can never climb backward
into prior/parent state or ancestor blocks — retention cannot leak into history.
The genesis empty state (a reference with no prior producer) is persisted by
`BlockBuilder.buildGenesis`.

## Gossip Acceptance Flow

1. A peer receives a gossiped block.
2. The node parses the bytes and performs cheap checks (CID match, timestamp
   bounds, proof-of-work sanity).
3. The node resolves the block's owned content from local storage or peers,
   **by CID** (`fetchData`). A boundary root missing locally is fetched as a whole
   volume from peers (one round-trip bundles its in-package entries); its internal
   nodes then resolve from the local CAS.
4. The node resolves the sparse state needed for validation — `prevState` /
   `parentState` references are resolved by CID, only as deeply as the
   transactions touch. This is validation input, not part of the block's owned
   closure.
5. The node validates the block. The fail-closed durability gate
   (`requiredCanonicalRoots`/`missingDurableRoots`) confirms the object's boundary
   roots are durably present before consensus mutation.
6. On acceptance, the node stores the owned closure (if not already) and
   `retain`s the block object root under a height-scoped owner.

## Retention (reachability GC)

Retention is mark-and-sweep over the owned-child edge graph: the pinned canonical
block roots (selected by the retention window) are the GC roots; VolumeBroker's
transitive eviction is the sweep. Superseded state reclaims automatically at
window-slide — `unpinAll(ns:pruneHeight)` releases the pruned height's roots, and
structural sharing keeps nodes still reachable from in-window heights while
sweeping the ones reachable only from the released root. There is no replaced-root
ledger and no height-scheduled sub-root unpinning.

## Non-Goals

- Do not store compact gossip bytes as `SerializedVolume(root: blockCID,
  entries: [blockCID: data])`. That shadows the real block volume with an
  incomplete one.
- Do not re-introduce singleton promotion (one volume per CID). It fragments the
  closure and erases the owned-child edges that retention depends on.
- Do not pin or require references (`prevState`/`parentState`/`parent`) under the
  block's owner — they are independently retained by their producers.
