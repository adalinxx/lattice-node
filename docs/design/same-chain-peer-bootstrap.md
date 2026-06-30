# Same-chain peer bootstrap (follow-up to permissionless child-chain follow)

## Problem

A per-process child node (e.g. a *followed* `Nexus/toy` spawned by the reconciler) needs
**same-chain peers** to headers-first sync its chain. Today that requires an explicit
operator-supplied `--peer <child node>` (every existing child-join test passes one). A node
that only *follows* a child has no peer address — it has the child's genesis (self-resolved
from the parent's on-chain `GenesisState`, shipped in the discovery+follow PR) but nowhere to
sync it from. This note specifies how a followed child finds its same-chain peers
automatically.

## What was ruled out (and why)

The journey matters, because each "obvious" approach hit a wall:

1. **Reuse one identity across the parent-sub link and the chain-gossip Ivy** (so the
   chain endpoint is `findNode`-resolvable on the parent DHT). **Empirically flaps**: a node
   then runs two Ivy instances under the same identity → duplicate-identity eviction loop
   (connect/disconnect every ~200ms). The separate parent-subscription identity is
   **load-bearing**, not just grind-caching.

2. **Carry the chain endpoint in the DHT pin announcement** (so `discoverPinners` returns a
   dialable chain endpoint). **Changes the pinning model**: IPFS/libp2p deliberately keep
   provider records *identity-only* and resolve addresses separately (FindProviders →
   FindPeer), so addresses stay fresh and content records stay pure. Baking a *forwarding*
   address (to a different identity/network) into the pin record breaks that two-step model
   and can go stale. Rejected — the pinning model stays untouched.

3. **Chain-scoped peer identity** (`(pubkey, chainPath)`), so the chain line is a distinct,
   derivable, `findNode`-resolvable identity — preserving the IPFS two-step. **Principled and
   correct long-term**, but an invasive Ivy core change (identity equality, handshake,
   routing-table keys, every message carrying an identity, PoW admission, spawn-cert/eclipse
   machinery). Deferred as the eventual foundation; out of scope here.

## Chosen design: live-subscriber `getChildPeers` (no registry, no forward)

Keep the pinning/DHT model **exactly as-is**. The parent chain a child subscribes to is the
natural rendezvous for that child's peers, because every child subscribes to its parent
anyway — and the parent **already tracks its connected subscribers**. So there is no separate
registry to build; the parent serves straight from its live connection set.

1. **Advertise** — while its parent link is up, a child periodically sends
   `childpeers-advertise(directory, chainEndpoint)` to its parent(s) (`chainEndpoint` = its
   chain-gossip `pubkey@host:port`, from `externalAddress` or loopback for local/test). The
   parent stores it against the connected peer, evicted on disconnect. The only thing carried
   is the chain-gossip endpoint — a deliberately *separate* identity from the parent-sub link
   (reusing one identity flaps with duplicate-identity eviction), so it cannot be inferred and
   must be stated.
2. **Query** — a follower sends `getChildPeers(directory)` (request/response, modeled on
   `ConsensusProvider`: `pending`-correlated, response accepted only from the queried peer,
   manual bounded wire format) to **each** parent it is connected to. The fan-out is on the
   *asker*, so no parent-side 1-hop forward is needed — in a seed-based topology every child's
   parent link converges on common seeds that accumulate the subscriber set.
3. **Serve** — the parent answers from its **live connected subscribers** that advertised that
   directory, excluding the asker. The directory is *self-declared*, not proven (no spawn cert
   is required, so this works in federated deployments too); that is safe by verify-not-trust —
   the follower's dial authenticates the identity and consensus validates the chain, so a bogus
   directory/endpoint costs only a wasted dial (rate-limited at the parent).
4. **Follower** — until it has a same-chain peer (no chain-gossip peer, or height still 0), the
   reconciler-spawned child queries its parents and dials the returned endpoints on its
   chain-gossip Ivy. The existing `didConnectPeer` → tip-exchange → headers-first-sync machinery
   takes over. A *followed* child spawns with no operator `--peer` (an empty `bootstrapPeer`),
   so its only same-chain peer comes from `getChildPeers`.

### Transport
- Topic-based `peerMessage` over the existing parent-subscription link — same path
  `chainAnnounce`/`childBlock`/`cw-request` use. Three topics: `childpeers-advertise`,
  `childpeers-request`, `childpeers-response`.
- Request/response copies the `ConsensusProvider` shape (`pending[id]`, anti-spoof responder
  gate, bounded `ByteCursor` wire codec). Serve uses the node's per-network context (live
  subscribers), so the node owns it via the provider's static codec.
- Dispatch in `ChainNetwork+IvyDelegate` (parent: advertise + request) and
  `ParentChainBlockExtractor` (follower: response over the parent-sub link).
- Advertise + query/dial are driven by a periodic task in `startParentChainSubscription`
  (`BackgroundLoops.swift`): tight cadence while still hunting a peer, relaxed once synced.

## Properties / trade-offs
- **Pinning model untouched; no Ivy/protocol change** — entirely node-level (new peerMessage
  topics + an advertised-endpoint table read from the live connection set).
- **Separate per-chain DHTs preserved** — the parent is only a bootstrap rendezvous; the
  child's own DHT stays isolated (Sybil resistance).
- **Reach** — bounded by the parents a follower is connected to; with no forward, a follower
  finds a peer iff one of *its* parents currently has that child subscribed. Realistic
  seed-based topologies (children + followers converging on common seeds) satisfy this; it is
  *not* full network-wide discovery.
- **Sybil** — the parent serves only endpoints currently-connected subscribers advertised,
  there is no on-chain authority claim, and the follower verifies every dialed peer.
