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

## Chosen design: direct-parent-query child-peer tracker

Keep the pinning/DHT model **exactly as-is**. Add a small, node-level tracker: the parent
chain a child subscribes to is the natural rendezvous for that child's peers, because every
child subscribes to its parent anyway.

1. **Register** — on subscribe, a child sends `registerChildPeer(directory, chainEndpoint)`
   to its parent over the parent-subscription link (`chainEndpoint` = its chain-gossip
   `pubkey@host:port`). Re-sent periodically (TTL).
2. **Parent registry** — the parent keeps `{directChildDirectory → {chainEndpoint}}`, evicted
   on subscriber disconnect / TTL. **Direct children only** — a parent knows only its own
   immediate subscribers; it has no business answering for a grandchild's peers (those
   subscribe to the child, not to it). So the query takes a single child directory, not an
   arbitrary chainPath.
3. **Query** — `getChildPeers(directory)` request/response, modeled on `ConsensusProvider`
   (`pending`-correlated, response accepted only from the queried peer, manual bounded wire
   format). Answered from the registry **plus a bounded 1-hop forward** to the parent's own
   connected parent-network peers (so a follower asking *its* parent still reaches peers that
   registered with a *sibling* parent — "ask the parent, and the parent asks its immediate
   peers," not a recursive DHT walk).
4. **Follower** — on follow/spawn, the child sends `getChildPeers(itsDirectory)` to its
   parent, connects its chain-gossip Ivy to the returned endpoints, and headers-first syncs.
   Connections are verify-not-trust: the handshake authenticates the dialed identity and
   consensus validates the chain, so a bogus endpoint costs only a wasted dial.

### Transport
- Topic-based `peerMessage` (`ivy.broadcastMessage`/`sendMessage`) over the existing
  parent-subscription link — the same path `chainAnnounce`/`childBlock` already use.
- Request/response: copy the `ConsensusProvider` shape (`requestTopic`/`responseTopic`,
  `pending[id]`, `handleRequest`/`handleResponse`, `encode/decodeRequest/Response`).
- Dispatch the three topics (`registerChildPeer`, `getChildPeers` request, response) in
  `ChainNetwork+IvyDelegate` where `peerMessage` topics are routed.
- Hook register + query in `startParentChainSubscription` (`BackgroundLoops.swift`), after the
  parent link is up and on each reconnect/periodic tick.

## Properties / trade-offs
- **Pinning model untouched** — pure identity-only provider records, two-step resolve.
- **No Ivy/protocol change** — entirely node-level (new peerMessage topics + a registry).
- **Separate per-chain DHTs preserved** — the parent is only a bootstrap rendezvous; the
  child's own DHT stays isolated (Sybil resistance).
- **Reach** — a direct parent only knows its direct subscribers; the bounded 1-hop forward
  extends reach to sibling parents without a DHT walk. Realistic seed-based topologies (many
  children + followers touching common seed/parent nodes) converge quickly. Document the
  bound; it is *not* full network-wide discovery.
- **Sybil** — the parent serves endpoints only for chains it actually has subscribers for;
  there is no on-chain authority claim, and the follower verifies every dialed peer.

## Validation
Upgrade the `permissionless-child-join` smoke from asserting *spawn/registration* to asserting
**full headers-first sync**: B follows `Nexus/toy`, its reconciler-spawned Toy finds A's Toy
via `getChildPeers` over the parent link, connects, and converges to A's Toy height — with no
operator-supplied `--peer`/`--subscribe-p2p`/`--genesis-hex`. Plus a unit test for the
registry (record/evict/direct-children-only) and the `getChildPeers` request/response.

## Status
Discovery + follow + genesis self-resolution shipped (this PR). The tracker above is the
focused next build; the design is locked and requires no Ivy or pinning changes.
