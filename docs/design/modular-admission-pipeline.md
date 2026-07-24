# Composable Node Architecture

> **Status: proposed — implementation requires explicit approval.**

## Core Principle

Modularity means orthogonal pieces of logic that retain their own meaning and
can be composed into different useful workflows.

The architecture is not a universal six-stage pipeline. Candidate admission is
one workflow:

```text
gossip/sync
    -> block/segment acquisition
    -> validation
    -> persistence
    -> insertion
    -> fork choice
```

Restart, transaction gossip, hierarchy evidence, inherited work, and provider
publication compose the same lower-level capabilities differently. They do not
pretend to pass through stages they do not need.

Composition happens through concrete immutable values, closures, and Cashew's
existing `ContentSource`, `Fetcher`, and `VolumeStorer` protocols. Atomicity is
preserved at the actor mutation boundary. Orthogonal does not mean that every
mutation becomes independently public.

## Chain Namespace

Ivy and VolumeBroker behave like IPFS inside one absolute chain namespace.
Ivy shares physical transport across namespaces; it does not share one logical
network.

The namespace is the existing Nexus genesis identity plus absolute
`ChainAddress`; it is not part of the CID. Identical bytes still produce the
same globally verifiable CID on every chain.

Each chain namespace independently owns:

- its Ivy router/DHT membership, overlay peer set, and provider registry;
- `VolumeAvailable` observations;
- its `volumes.db`, memory budget, eviction policy, and retained roots;
- its request, bandwidth, token-bucket, and send-pressure budgets;
- accepted-forest inventory and candidate scheduling.

The production boundary is one process and one physical VolumeBroker per chain,
plus one concrete `IvyHost` transport in the node/operator supervisor. If
storage is ever physically shared, quota and eviction isolation must be
enforced below the broker API; key prefixes over one global eviction budget are
insufficient.

### Shared transport, isolated Ivy networks

`IvyHost` owns only node-wide transport concerns:

- one stable authenticated node identity;
- listening, dialing, encryption, NAT/address discovery, and connection health;
- one physical connection to a remote node when several local chain namespaces
  communicate with that same remote node;
- multiplexed logical streams;
- host/peer resource reservations and bounded cross-chain Tally evidence.

Every logical stream is bound during authenticated negotiation to:

```text
(Nexus genesis CID, absolute ChainAddress, plane, protocol version)
```

The binding is routing and authorization context, not content identity. It is
never inserted into a Volume member CID.

Each chain process registers one bounded namespace endpoint with the supervisor.
The supervisor routes frames to that endpoint but cannot enumerate or mutate
the process's accepted forest, provider registry, VolumeBroker, `NodeStore`,
mempool, inherited-work projection, or fork choice. A chain process owns those
facts and re-registers its streams after a supervisor restart.

Overlay and hierarchy are independent logical streams with independent ingress
limits, flow control, queues, and protocol authorization. The implementation
must use genuine multiplexing or a fair bounded stream scheduler. It must not
put chain-tagged messages into one global FIFO where a noisy child can
head-of-line block parent work. Nexus and authenticated live-parent traffic
retain reserved host capacity.

Transport authentication alone grants no hierarchy authority. The logical
stream also binds the exact configured parent identity, parent chain namespace,
child namespace, and hierarchy role. A peer connected for one chain is not
implicitly a peer, provider, parent, or child on another chain.

One shared transport increases operational blast radius but not consensus blast
radius. Losing it disconnects current streams across local chains; it cannot
change any durable chain fact. Each chain independently restores networking
from its own durable state.

Resource accounting is hierarchical. Before allocating, an operation reserves
against every applicable scope:

```text
host -> authenticated peer -> chain namespace -> plane/protocol -> operation
```

Exhausting any scope rejects or backpressures the operation. Chain-local limits
prevent a child from consuming its parent's logical quota; host and peer limits
prevent many individually compliant children from exhausting the machine.
OS/container limits remain the outer failure boundary rather than the primary
network scheduler.

A noisy child therefore cannot cross the node's logical, storage, or
chain-network accounting boundary:

- populate its parent's provider table;
- evict parent content;
- consume parent cache or reserved network quota;
- create parent block candidates;
- publish into the parent's accepted forest.

The same CID may be copied into two chain namespaces and pass identical
CID/`SerializedVolume.validate()` byte checks. Lattice semantic validity remains
bound to the absolute chain path and state, so the same block or transaction
may correctly fail in another namespace. Global byte identity does not import
the sender's providers, retention ownership, or routing authority.

### Full-history availability

Lattice uses complete verifiable replication rather than erasure-coded partial
storage. A chain is historically available when at least one live reachable
node can serve the complete retained Volume closure of every accepted fact for
that chain. One archive is the retrieval threshold; additional archives on
independent hosts provide operational fault tolerance.

The full-history closure is the union of the exact Volume boundaries selected
by every durable accepted admission. It includes genesis/spec content, every
block in the accepted forest including noncanonical branches, and all selected
transaction, state, module, policy, and hierarchy-evidence Volumes required to
replay or verify those facts. Canonical grind identities and their locations
remain semantic admission facts rather than invented archive payloads. The
closure excludes rejected candidates, temporary attempt content, evicted
mempool entries, and uncommitted child intents.

A full node retains this accepted-history closure merge-only. Canonicity never
releases it. VolumeBroker may evict only content with no durable accepted or
other live owner. A future explicitly pruned/light role is a separate product
decision and does not complicate the full node.

Pinning is local retention authority, not a remote proof of availability.
Short renewable per-chain provider leases route exact Volume requests; the
receiver verifies every complete Volume. Losing the final archive makes history
unavailable but does not invalidate accepted facts. No erasure coding,
availability sampling, or proof-of-storage protocol is required by this model.

Historical data availability remains orthogonal to inherited work. Any
same-chain archive peer may supply verifiable history, while a child still
requires its configured live authenticated parent to complete the current
inherited-work pass before operational consensus.

### Cross-chain Tally

Tally is not part of a chain namespace. Its evidence key is the authenticated
transport identity, and Tally's own `TALLY-001` law makes that evidence
peer-global. The score remains local operator policy and is never exchanged as
network authority.

Three concerns must stay separate:

```text
node/operator-wide hard peer evidence
    -> chain-independent attributable violations, challenge work, identity work

chain/plane-scoped contribution
    -> capped and decaying useful exchange observations

chain/plane-local admission control
    -> request tokens + send pressure + connection/bandwidth capacity
```

A noisy child may contribute genuine attributable evidence about a peer, but it
cannot multiply positive reputation by repeating the same useful exchange
across many children, consume the parent's admission tokens, or make child
traffic appear as parent send pressure. Scoped positive contribution has a
per-chain/plane cap before aggregation. Empty content, timeout, failed dial,
route quality, chain-semantic rejection, and local overload remain
chain/plane-local service observations and never become node-wide hard
evidence.

Today Tally packages peer evidence and process-local admission control in one
value. The lower-level integration should split one supervisor-owned bounded
peer-evidence backend from chain/plane-local `AdmissionController` values.
Chain processes submit typed observations rather than arbitrary score deltas.
`IvyHost` supplies the authenticated PeerID and scope so one child cannot forge
another chain's observation.

### Explicit cross-chain bridges

Only these values cross a chain boundary:

1. Validation authority:
   `ChildValidationPackage`, `ParentCarrierLink`, `ParentGenesisLink`, and
   validated direct-child edges.
2. Consensus work:
   the authenticated immediate parent's current `InheritedWorkSnapshot`.
3. Availability:
   an explicit authenticated parent-to-child transfer may deliver complete
   CID-verifiable Volume bytes into the child's own temporary memory.

The receiver independently validates and, if selected, stores the Volume in its
own namespace. Provider registries, caches, pins, bandwidth credit, and
accepted-block notices never cross automatically. Tally evidence is not routed
as chain data; authenticated observations are submitted independently to the
shared peer-evidence backend.

The parent does not import child payloads, provider facts, or consensus state.
When it encounters nested child data, it routes the relevant immutable
reference/evidence to that child process and remains otherwise child-agnostic.

## Orthogonal Capability Families

### 1. Knowledge and scheduling

These are synchronous domain-specific value reducers. They traffic in facts and
commands, never content bytes.

#### Accepted forest knowledge

```swift
struct AcceptedBlockNotice: Sendable {
    let blockCID: String
}

struct AcceptedLeafSync {
    mutating func handle(_ event: Event) -> [Effect]
}
```

`AcceptedLeafSync` owns pagination, snapshot cursors, request timeout, peer
disconnect, and one bounded ingress reservation. It emits accepted block CIDs,
not providers or canonical-tip commands.

Lattice synchronizes every accepted forest leaf rather than only a peer's
canonical tip because noncanonical accepted branches still carry work.

#### Volume availability knowledge

```swift
struct VolumeAvailable: Sendable {
    let rootCID: String
}
```

`VolumeAvailable` updates only the current chain's Ivy provider registry. The
root might be a block, transaction, state, spec, policy, or evidence Volume.
The notice never creates a block candidate or causes the root to be decoded as
a block.

Availability is a short renewable lease keyed by exact authenticated
`(session, rootCID)`. The receiver grants a protocol-fixed, locally monotonic,
capped TTL; the sender cannot choose an expiry. Renewal refreshes only that
lease, and disconnect or local owner-union release stops renewal. A replacement
session never inherits the old session's claim. Generic `.empty`, timeout, and
local-capacity responses are not authenticated withdrawals: they neither revoke
the lease nor blame the peer. Bounded staleness ends only at local lease expiry
or disconnect.

If a known candidate has the same root, its next content request may use the
provider. Availability does not imply accepted-forest membership.

#### Block dependency frontier

`CandidateAcquirer` owns only block-domain scheduling:

- accepted or evidence-authorized block knowledge;
- authenticated child packages keyed by root/grind CID;
- same-chain predecessor dependencies returned by Lattice;
- descendants parked behind a predecessor;
- retry deadlines and exact active-attempt tickets;
- bounded recovery and ingress reservations.

It does not fetch bytes, store providers, decode Cashew data, validate blocks,
punish peers, persist facts, compute work, or choose a tip.

When Lattice returns predecessor `P` for descendant `D`, the frontier parks `D`,
schedules `P`, and repeats until one block connects. Successful admission wakes
descendants in order. A "segment" is this recursive scheduling relationship,
not a serialized Volume or durable database object.

#### Durable recovery pager

`NodeStore` exposes stable snapshot-sequenced pages of unresolved predecessor
edges and evidence roots:

```swift
struct RecoveryPage {
    let snapshotSequence: Int64
    let nextCursor: RecoveryCursor?
    let obligations: [DurableAcquisitionObligation]
}
```

The runtime requests only as many obligations as the frontier has reserved
capacity for. It loads another page when attempts free capacity. Facts arriving
during a scan enter through ordinary ingress; backpressure sets one rescan bit.
No durable root is dropped or granted an overflow exemption.

### 2. Content access and Volume lifetime

This family is generic. Blocks, transactions, state, specs, policies, evidence,
and child-genesis content use the same implementation.

#### Temporary attempt Volumes

Remote content is resolved in bounded memory and discarded when the workflow
ends. It does not enter the chain's DiskBroker merely because a peer supplied
valid bytes.

The per-chain composition root creates it:

```swift
struct ChainVolumeNamespace: Sendable {
    let chainID: String
    let disk: DiskBroker
    let ivy: Ivy

    func withAttempt<T: Sendable>(
        rootCID: String,
        limits: VolumeAttemptLimits,
        routesByRoot: [String: VolumeRoute] = [:],
        _ body: @Sendable (VolumeAttempt) async throws -> T
    ) async throws -> (T, VolumeAttemptReport)
}
```

There is no node-global broker fallback. A `VolumeRoute` contains preferred
authenticated sessions for one exact root only. `withAttempt` closes the
temporary content and selection views on every return, throw, timeout, or
cancellation so an escaped reference cannot keep fetching or retaining memory.

Conceptual attempt types:

```swift
struct VolumeAttempt: Sendable {
    let content: any ContentSource
    let selected: SelectedVolumes
}

final class AttemptState: @unchecked Sendable {
    /// Accept one complete, validated Volume into the bounded MemoryBroker.
    func acceptAcquired(_ volume: SerializedVolume) async throws
    func select(_ volume: SerializedVolume) async throws
    func fetch(_ cids: Set<String>) async -> [String: Data]
    func selectedSnapshot() -> SelectedVolumeSnapshot
    func close()
}

struct SelectedVolumes: VolumeStorer {
    let state: AttemptState

    /// Cashew/Lattice matching store paths call this with exact complete
    /// boundaries.
    func store(volume: SerializedVolume) async throws
    func snapshot() -> SelectedVolumeSnapshot
    func close()
}

struct SelectedVolumeSnapshot: Sendable {
    let volumesByRoot: [String: SerializedVolume]
    let manifestsByRoot: [String: VolumeBoundaryManifest]
}

struct VolumeBoundaryManifest: Sendable {
    let memberCount: Int
    /// Overflow-checked sum of `entries.values` Data byte counts.
    let payloadBytes: UInt64
    /// SHA-256 over the exact canonical encoding defined below.
    let membershipDigest: Data
}
```

Manifest v1 bytes are unambiguous:

```text
ASCII("lattice/volume-boundary-manifest/v1\0")
    || frame(canonical root CID UTF-8)
    || u64be(member count)
    || frame(each canonical member CID UTF-8, sorted bytewise)

frame(x) = u32be(x.byteCount) || x
membershipDigest = SHA-256(the bytes above)
```

`payloadBytes` is audit/budget redundancy, not the security commitment. Every
active claim for one root must carry the identical manifest. Claim staging or
workset coalescing that sees a conflicting manifest fails as fatal local
invariant corruption.

`ChainVolumeNamespace` builds `content` with Cashew's existing
`CompositeContentSource` and the existing root-bound
`IvyRootContentSource.Session`; it does not introduce a second resolver API.
`AttemptState` exposes narrow acquisition-content and selection-storer views
over the same accounting and MemoryBroker.

The implementation therefore uses one private bounded attempt state with two
narrow views:

- acquisition can add complete Volumes but cannot mark them selected;
- Cashew's matching store traversal can mark selected Volume roots but cannot
  fetch arbitrary remote content.

`SelectedVolumes` validates and deduplicates exact boundaries and freezes a
compact membership manifest for each one. `Data` and
`SerializedVolume` are copy-on-write values, so selection does not require a
second physical payload copy. Acquisition, selection, and locally materialized
state reserve against one aggregate member/byte budget before retaining a new
value. Its immutable snapshot performs no resolution or network request.

The attempt aggregate is bounded by the applicable consensus/session limits and
lives for one actual validation attempt. If validation parks on missing evidence
or a predecessor, the lexical attempt ends and releases every byte. A later
attempt may reacquire immutable content. Cross-attempt caching, if ever measured
as necessary, is a separate bounded chain-cache policy rather than an escaped
attempt lifetime.

#### Root-scoped Ivy acquisition

For one requested root, Cashew's `CompositeContentSource` composes:

```text
this chain's DiskBroker
    -> optional bounded chain-local mempool content
    -> pending selected-payload content
    -> attempt MemoryBroker
    -> IvyRootContentSource.Session:
         exact live providers registered for this exact root
         -> current chain's Ivy public provider discovery
```

The provider identity is `(public key, session ID, root CID)`. A provider for
block `D` is never preferred for predecessor `P`, transaction `T`, spec `S`, or
policy `W`.

For each remote response:

1. Enforce the session-wide Volume/member/byte/deadline limits.
2. Require the requested root exactly.
3. Require a complete `SerializedVolume`.
4. Run `SerializedVolume.validate()`.
5. Put the valid complete Volume into the attempt state's bounded MemoryBroker.
6. Return the requested member bytes from that validated complete Volume.
7. Record a blameable fault only for an authenticated wrong-root or invalid
   complete response.
8. Treat timeout, disconnect, `.empty`, partial transport, enqueue failure, and
   local-capacity failure as unattributed availability failures.

The content capability reports attribution; it does not call Tally. The runtime
submits only cryptographically blameable protocol faults to shared peer
evidence. Availability/retry outcomes stay in the current chain's service
policy.

#### Cashew composition

Cashew already provides the needed composition:

```text
OverlayContentSource(authenticated sparse evidence)
    + CompositeContentSource(chain-local sources + IvyRootContentSource)
    + CoalescingFetcher
    + typed resolve paths
    + matching Volume store paths
```

The existing Ivy root source checks the composed chain-local sources first. For
each remaining requested boundary it consults only routes registered for that
exact root, then current-chain discovery, validates one complete Volume, accepts
it into the attempt state, and satisfies the Cashew request. This same concrete
composition serves block, transaction, evidence, spec, policy, and state
resolution.

Lattice chooses block/state validation paths. Transaction and evidence code
choose their own typed paths. The node does not build a generic graph planner.

Nested Volumes remain independent boundaries. Selecting an outer block does not
implicitly select referenced transaction, state, policy, parent, child, or
evidence Volumes.

#### Chain-local durable content

Only selected complete Volumes cross from attempt memory into that chain's
`DiskBroker`.

VolumeBroker gains one genuine multi-implementation durability requirement:

```swift
struct RetainedVolumeWrite: Sendable {
    let volume: SerializedVolume
    let scopes: Set<String>
}

protocol AtomicRetainedVolumeBroker: RetainedRootMergeBroker {
    func storeAndMergeRetained(_ writes: [RetainedVolumeWrite]) async throws
}
```

`DiskBroker` validates and stores the selected complete Volumes and merges their
roots into every current retained scope in one SQLite transaction. Memory and
test brokers implement the same protocol requirement with their own atomic
semantics. There is no default store-then-merge implementation, no unpinned
Disk window, and no temporary pins, owners, TTLs, or cleanup protocol.

Selected Volume persistence is deliberately asynchronous with live insertion
and fork choice. Before semantic staging, one scoped admission permit owns both
the exact consensus reservation and a payload-handoff ticket. The ticket
reserves root/workset metadata, then atomically rebinds the immutable selected
snapshot's existing aggregate byte charge from the attempt to the backlog—no
second MemoryBroker insertion, payload copy, or double charge occurs. Any
incremental materialized bytes were reserved before creation.

After staging and live apply, committing the prepared handoff is only a
nonthrowing root-table ownership transition. `withAttempt.close()` releases
only untransferred charge. The backlog serves directly from its owned immutable
snapshots through a narrow `ContentSource` view; that view is in-flight
lifecycle state over bytes already acquired through VolumeBroker, not another
durable/custom CAS. The backlog deduplicates by root and calls
`storeAndMergeRetained` in the background.

The backlog is one root-keyed workset plus one fair single-worker ready deque;
it does not serialize independent CIDs in chain order because content identity
is immutable and semantic ownership is already durable. Independent roots may
complete out of order, while repeated semantic owners of one root coalesce to
one payload, one memory charge, and one physical write. A root-specific failure
backs off only that root; a global SQLite failure opens one circuit breaker.
The backlog is bounded by selected bytes and root count and applies backpressure
to new admissions rather than growing without limit. Pending selected Volumes
remain directly servable from memory.

`NodeStore`, not the workset, owns durable claims
`(claim ID, root, retained scope, publishable)`. Before a write, the worker reads
the current active claims, discards bytes with no owner, and atomically stores
the Volume plus every current scope. Claim addition and release share one
per-chain storage-ownership lane with realization. After the broker transaction,
the worker re-reads active claims and loops until every current scope is
realized before marking the root complete. A removed scope may remain
conservatively retained until reconciliation, but a newly added scope is never
missed. Release commits claim removal in `NodeStore` first, then unretains the
broker scope; a crash can therefore cause only safe conservative
over-retention, never deletion while a durable claim still exists. A same CID
with different bytes is fatal local corruption.

Attempts, selection/materialization, the payload backlog, and the mempool all
reserve from one per-chain aggregate memory budget in addition to their local
limits. The envelope includes Ivy assembly buffers, MemoryBroker's ownership
copy, locally materialized state, map/framing overhead, mempool replacement
overlap, and Disk-writer scratch—not only logical payload bytes. A child cannot
multiply its allowance by moving the same bytes between capabilities.

`NodeStore`'s active selected-root claims are durable acquisition obligations;
the immutable admission manifest may remain audit history but is not lifetime
authority. Releasing the last claim cancels pending/backoff/recovery work. If a
process dies before a pending Volume reaches DiskBroker, restart restores the
consensus fact immediately and schedules:

```text
active durable claims
    minus complete roots retained for every current scope
```

For each missing root, ordinary Ivy acquisition runs
`SerializedVolume.validate()` and requires the exact journaled
`VolumeBoundaryManifest` before atomic store-and-retain. Missing, partial, or
extra-member archives fail the availability attempt. Consensus recovery does
not rerun block validation or typed state transitions.

Genesis bootstrap is the one availability exception: every selected genesis
Volume is stored and retained before the runtime is exposed, because no earlier
durable chain can recover without its base.

#### Intentional storage-invariant revision

This proposal intentionally changes lattice-node's current
`NODE-STORAGE-002`/`docs/architecture.md` ordering. The old node rule is:

```text
DiskBroker store-and-retain -> NodeStore semantic fact -> visibility
```

The proposed rule is:

```text
freeze exact complete Volume + canonical boundary manifest in bounded memory
    -> NodeStore semantic fact + active recovery/retention claim
    -> visibility
    -> asynchronous DiskBroker store-and-retain
```

Lattice's load-bearing “semantic durability precedes visibility” law remains
unchanged. What changes is the node availability invariant: a durable fact may
temporarily outrun local payload materialization, but it may never outrun an
exact active root/boundary claim from which any peer's bytes are independently
verifiable. During implementation, the canonical node architecture and
correctness-invariant documents must be revised together with the code and
tests; leaving the old statement in place would be a contradiction.

This is a deliberate latency/availability trade: common admission no longer
waits on bulk SQLite payload writes, while a crash can leave exact missing-root
obligations that depend on a peer or deterministic rematerialization. Genesis
stays synchronous as the recovery base. Existing on-disk layouts are not
migrated; operators resync under the already planned destructive upgrade.

Other ownership policies remain independent compositions:

- the default bounded mempool owns accepted transaction Volumes in its own
  `MemoryBroker` until inclusion/eviction; an explicitly configured durable
  mempool may instead use an atomic retained DiskBroker scope;
- child-intent ownership retains an issued candidate until handoff/release;
- durable chain/hierarchy retention drives provider publication.

Fetch/decode is reusable across domains; promotion policy is deliberately not
universal. A read-only or rejected workflow discards everything. An accepted
mempool transaction follows the bounded per-chain mempool policy. Lattice
admission promotes only the exact selected snapshot. Evidence persistence uses
its own semantic authorization before promoting an evidence boundary.

While a mempool, selected-payload backlog, or child-intent owner has a
complete Volume, the live session may advertise a short, renewable Ivy provider
lease for that root. Eviction, release, disconnect, or restart stops renewal;
remote records expire at the advertised deadline. Ephemeral ownership never
enters the durable provider-reprojection index. A handoff to durable retention
renews the same root without an availability gap.

### 3. Typed domain logic

Content access knows nothing about protocol meaning. Typed logic consumes
Cashew `Fetcher` and `VolumeStorer` capabilities.

#### Lattice verification capability

The existing concrete API is the reusable seam:

```swift
let preflight = try await level.preflightBlockHeaderChainLocal(
    header,
    fetcher: CoalescingFetcher(attempt.content),
    childPackage: package,
    validationContentStorer: attempt.selected
)
```

It:

- uses immutable `ChainRuntimeContext` for the absolute chain path;
- resolves through the injected Cashew fetcher;
- asks the injected storer to select validation Volume boundaries;
- returns a concrete level-bound one-use token;
- mutates no accepted graph.

`PreparedChainAdmission` is temporal authority, not a strategy protocol.

Target misses and carrier-only results reuse the same verification capability
without persistence or graph insertion.

#### Immutable admission algebra

Lattice constructs `ChainAdmissionBatch` once. `ChainAdmissionStagingContext`
combines that exact batch with verified hierarchy facts the node must stage
atomically.

The batch contains:

- one immutable block fact when the block is newly accepted;
- one exact observed `(block CID, grind CID, quantity)` work fact.

Repeated observations for a grind join by maximum quantity inside `ChainState`.
The batch records the exact observation proved by this validation.

The same `stagingContext.batch` value is persisted, applied live, returned in
`ChainAcceptance`, and replayed after restart.

#### Pre-durability consensus reservation

No bytes become durable until the exact semantic mutation is known to remain
applicable. Under the single `ChainProcess` mutation lane, Lattice:

1. constructs the final `ChainAdmissionStagingContext`;
2. pure-projects current durable parent facts through existing direct edges
   plus any new validated edge in that context;
3. validates graph compatibility, every local and inherited grind location,
   and revision capacity against current `ChainState`; and
4. reserves that exact batch and prospective inherited-work delta.

Conceptually:

```swift
let reservation = try chain.reserve(
    stagingContext,
    prospectiveInheritedWork: projectedParentWork
)
```

The reservation is an internal one-use value bound to the exact batch,
prospective inherited delta, and reserved revision. It is exclusive across the
reentrant durability await: while outstanding, every other `ChainState`
mutation route—including inherited-work merge, replay/apply, reevaluation, and
local-work mutation—waits behind the reservation or returns busy before it can
persist anything. Only matching apply or explicit release consumes it.

A failure before semantic commit releases the reservation.
`applyReservedStaged` accepts only the matching reservation and has no expected
failure path. This remains private Lattice/`ChainProcess` machinery, not a
general reservation service or public mutation API.

This is load-bearing for a newly admitted direct edge: parent work already
known for `P` may become located at new child block `C`. That prospective
projection must be checked together with insertion of `P -> C`, before the
`NodeStore` commits either semantic fact. Payload storage follows
asynchronously.

#### Pure inherited-work projection

The exact parent-to-child join should be a reusable value operation rather than
an actor-specific procedure:

```swift
public extension InheritedWorkSnapshot {
    func projected(
        through childBlockByParentBlock: [String: String]
    ) -> InheritedWorkSnapshot?
}
```

Input:

```text
parent work fact:    (parent block P, grind G, quantity Q)
durable direct edge: (parent block P -> child block C)
```

Output:

```text
locate (G, Q) at C in the child chain
```

No exact edge means no contribution. A sibling edge contributes only to its
sibling. Noncanonical accepted `P` counts when the edge exists; a canonicity
change by itself changes nothing.

The operation validates canonical identifiers and unique grind location,
preserves the source revision, joins repeated quantity by maximum, and is
deterministic without actor state.

Every hierarchy level repeats the same projection through its immediate edges.
No ancestor sends an entire descendant tree.

#### Lattice reducer and projections

`ChainState.applyReservedStaged` and `ChainState.replay` are live/recovery forms
of the same durable-batch reducer. Internal orthogonal helpers own:

- accepted graph insertion;
- legal grind-location joining;
- disconnected descendant grafting;
- segment/prefix-work index updates;
- optimized and reference GHOST projection.

These helpers are independently testable, but the mutation remains atomic:

```text
apply one durable batch
    -> graph/work/index updates
    -> one derived fork projection
    -> one revision advance
```

There is no public `GraphInserter` or replaceable `ForkChoiceStrategy`. Exposing
one would permit observation of a partially updated consensus forest.

`ChainCommit` and `ForkChoiceSnapshot` are immutable projection outputs, not
durable authority.

### 4. Semantic durability and derived effects

`NodeStore` owns typed semantic transactions, not Cashew traversal.

Its independently useful operations include:

- stage one exact admission context, its exact selected-Volume durable claims
  (root, scope, publication policy), and hierarchy metadata in one journal
  transaction;
- persist the current authenticated parent-work fact table and cursor;
- persist hierarchy/evidence facts;
- page durable recovery inputs;
- page semantically publishable Volume roots;
- audit rebuildable sync indexes.

The only synchronous persistence in admission is the small `NodeStore`
transaction. After it commits, the workflow must not observe cancellation or
return an expected error before applying the exact batch and handing its
already-reserved selected snapshot to the background writer. Failure to apply a
Lattice-minted durable batch is fatal corruption/restart territory, not a
retriable peer error.

Before `NodeStore` commits, any throw or cancellation releases both halves of
the scoped admission permit: consensus reservation and payload-handoff ticket.
After commit the permit is irrevocable; exact apply and backlog ownership
transfer finish despite task cancellation. Graceful shutdown therefore orders:

```text
stop ingress
    -> let every semantically committed mutation-lane operation finish apply
       and backlog handoff
    -> stop provider-lease renewal and the payload worker
```

The backlog need not drain on shutdown because active durable claims reconstruct
missing work. Process death at any point relies on the same recovery path.

Each selected-root claim records its typed semantic owner, boundary manifest,
and publication policy. It is semantic recovery data, not a second content
store. Restart subtracts complete retained DiskBroker roots from active claims
and never reruns Cashew traversal to guess which Volumes an admission selected.

An authorized-but-missing root is content-degraded, not consensus-invalid.
Consensus graph/work/tip and inherited-work export restore immediately from
`NodeStore`. Only operations that need the missing bytes—such as a dependent
validation, template, state query, or evidence response—park until exact-root
reacquisition succeeds. Parent readiness remains solely the separate live,
complete authenticated parent-work condition.

Disk or payload degradation never disables accepted-fact gossip, canonical
semantic publication, existing fork choice, descendant securing-work export,
or readiness established by a complete live parent pass. Doing so would make
availability policy change consensus weight. A full bounded backlog may
backpressure new admissions, but already durable work continues to flow.

Derived effects are separate capabilities:

- `ChainService` reconciles mempool, templates, and RPC projections from
  `ChainCommit`;
- the selected-Volume writer persists semantically owned payloads without
  blocking insertion or fork choice;
- provider publication pages roots explicitly authorized by durable admission
  and hierarchy/evidence semantics, filters for locally servable roots, and
  announces them through the current chain's Ivy;
- accepted-block gossip derives from durable accepted facts;
- metrics observe workflows without becoming authority.

Provider publication is paged and rate-limited on startup and refresh.
Semantic authorization and current local serviceability are both required:
private child-intent, inbox, cache, and prepared roots remain undiscoverable,
and a semantically owned but not-yet-acquired root is not advertised. The
publishable index is reconstructed/audited from typed `NodeStore` facts and
never stored as consensus truth. Removing semantic ownership stops refresh;
provider records expire naturally.

The publication set is precisely:

```text
NodeStore semantically public root obligations
    intersection complete retained DiskBroker Volumes
```

Pending memory may advertise only a short live lease; it never enters startup
reprojection.

## Composition Recipes

| Workflow | Capabilities composed |
|---|---|
| Same-chain block sync | AcceptedLeafSync + CandidateAcquirer + VolumeAttempt + Ivy + Cashew + Lattice admission |
| Live block announcement | AcceptedBlockNotice + CandidateAcquirer; VolumeAvailable independently enriches Ivy |
| Target-miss carrier relay | VolumeAttempt + Cashew + Lattice verification result; no admission batch |
| Transaction gossip | Transaction inventory reducer + VolumeAttempt + Ivy + Cashew transaction validation + mempool ownership |
| Child evidence fetch | Evidence inventory + VolumeAttempt + Ivy/hierarchy exact provider + Cashew + Lattice evidence verification |
| Candidate recovery | NodeStore recovery pager + CandidateAcquirer, then ordinary block-sync composition |
| Restart | NodeStore audit + `ChainState.restore`, then independent missing-root refill; consensus restore does no acquisition or validation |
| Parent-work update | Parent authentication + pure edge projection + consensus reservation + NodeStore transaction + reserved merge |
| Provider reprojection | Publishable-semantic-root pager + current chain's Ivy; no validation or consensus mutation |
| Differential audit | Exact durable batches + live/replay reducer + optimized/reference fork projection |

### Candidate admission workflow

The user's six concerns compose here:

```text
1. Accepted block/evidence knowledge enters CandidateAcquirer.
2. A bounded VolumeAttempt resolves exact complete Volumes through this
   chain's Ivy.
3. Lattice preflight validates and selects Volume boundaries in memory.
4. Under the mutation lane, `commitPreflight` stores materialized state into
   the same selection and constructs the final staging context.
5. It pure-projects durable parent facts through existing plus newly admitted
   direct edges, then reserves the exact combined Lattice mutation.
6. Its stage closure prepares the no-copy selected-snapshot ownership transfer
   and backlog metadata capacity, then stages the exact context, active claims,
   boundary manifests, and hierarchy facts in one small `NodeStore`
   transaction. It performs no `volumes.db` I/O.
7. Lattice consumes the matching reservation, atomically applies the batch and
   inherited-work delta to graph/work/segment indexes, and derives one
   fork-choice projection.
8. The selected snapshot transfers to the already-reserved background
   persistence slot; live service may serve it from memory immediately.
9. The rest of the attempt MemoryBroker is discarded. DiskBroker persistence,
   retention, and durable provider publication happen asynchronously.
```

`commitPreflight` remains one atomic composition:

```text
consume level-bound token
    -> store materialized state into attempt selection
    -> construct exact context and prospective inherited projection
    -> reserve exact combined mutation
    -> prepare bounded no-copy selected-payload ownership transfer
    -> invoke small semantic durability closure
    -> apply the exact reserved batch and inherited work
    -> update all consensus indexes
    -> project one tip
    -> nonthrowing handoff to selected-Volume writer
    -> return acceptance carrying the same batch
```

Bootstrap uses the same exact-context rule but synchronously stores every
selected genesis Volume before durable restore exposes the runtime.

An acceptance response keeps its existing meaning: the exact Lattice semantic
fact is durable and visible. It does not claim that every selected payload has
already reached DiskBroker. Payload backlog count/bytes, missing selected roots,
oldest pending age, and last storage error are availability health/metrics, not
a second consensus acknowledgement protocol.

### Restart workflow

Restart intentionally skips content acquisition and validation:

```text
exclusive directory lock
    -> audit chain identity and semantic facts
    -> restore ChainState from exact admission batches/revision floor
    -> pure-project durable parent work through durable direct edges
    -> page active claims whose exact manifested Volumes/scopes are incomplete
    -> start bounded ordinary acquisition/store obligations
    -> rebuild service/provider projections from currently servable roots
```

Durable facts may reconstruct a provisional child tip, but restart and parent
disconnect always set a child to `awaitingParent`. Same-chain validation and
persistence may continue. Mining, canonical publication, descendant work
export, and operational consensus remain disabled until the configured live
authenticated parent completes its current work pass.

### Parent-work workflow

Parent work is orthogonal to content availability:

```text
authenticate bounded revisioned parent fact pages + completion
    -> form one monotone candidate fact table/delta
    -> pure-project through durable P -> C edges
    -> under the mutation lane reserve the exact accepted projection
    -> persist exact parent facts/source/revision/cursor/floor
    -> consume the reservation and atomically merge affected child work
    -> update affected segment bases/ancestors
    -> derive fork choice
```

The parent publishes a current fact table, not append-only history. Facts join
monotonically at the child: an unseen valid location is added and an observation
for the same grind/location joins by maximum quantity. The pass revision is
only a progress watermark, stored as `max(retainedRevision, passRevision)`.
An older or equal revision may still carry an unseen valid fact or a stronger
quantity and must be joined. The child indexes direct edges by parent block CID
and updates only affected locations. Parent canonicity is not an input.

The parent remains child-agnostic: it never ingests child state, child fork
choice, provider registry, cache, or topology.

A pass is authenticated completely before any candidate is formed. An
incomplete pass persists nothing. A wrong source/session/cursor generation,
noncanonical identifier, or grind-location conflict fails atomically; lower
revision alone is not staleness or invalidity. If persistence fails, the
reservation is released. Only a complete pass for the current authenticated
live-parent session enables readiness, even when an older valid pass contributes
monotone facts. A newly admitted direct edge is handled by the combined
admission reservation above, so there is no window where its already known
inherited work can fail after the edge is durable.

### Hierarchy/evidence durability workflow

Hierarchy evidence is durable only after semantic verification:

```text
bounded VolumeAttempt
    -> verify carrier/target-miss/evidence with Cashew and Lattice
    -> select exact evidence Volumes
    -> prepare bounded no-copy selected-payload handoff
    -> one NodeStore hierarchy transaction with active claims + manifests
    -> hand selected snapshot to the background writer
    -> publish derived availability only when locally servable and public
```

Outgoing evidence this chain issues to a child creates no
`ChainAdmissionBatch`, graph insertion, work fact, or fork-choice mutation.
Private prepared child intents use a nonpublishable scope.

An incoming authenticated direct edge for an already accepted child block is
consensus-relevant even when it arrives after the block:

```text
verify P -> existing C and select its evidence Volumes
    -> project durable parent work through existing edges + prospective P -> C
    -> reserve exact edge mapping + inherited-work delta
    -> prepare bounded no-copy selected-payload handoff
    -> one NodeStore transaction for edge/evidence/claims/manifests/floor
    -> consume reservation, merge exact work, derive one fork projection
    -> hand selected snapshot to the background writer
```

If the process dies after the edge transaction, restart projects durable parent
facts through the durable edge. The in-memory reservation is never recovery
authority.

### Transaction/mempool workflow

The default mempool is bounded and ephemeral:

```text
transaction inventory
    -> bounded VolumeAttempt
    -> typed Cashew/Lattice transaction validation and selection
    -> copy the selected complete Volume into the chain mempool MemoryBroker
    -> atomically make the mempool entry visible
    -> advertise only while the live owner remains
```

One mempool mutation lane owns capacity reservation, chosen evictions, exact
Volume insertion/removal, transaction metadata, and provider-lease transitions.
Its MemoryBroker does not independently auto-evict semantic entries. The safe
order is reserve and choose evictions, store the complete selected Volume,
insert metadata with no remaining failure path, remove evicted metadata and
bytes, then update renewable leases. The reservation charges the transient
old-plus-new overlap until removal; choosing an eviction does not prematurely
free its bytes from the aggregate budget.

Rejected or evicted transactions disappear without pins or cleanup records.
Block admission later selects and durably retains the exact transaction Volume
through the ordinary background persistence workflow. Inclusion transfers
ownership from mempool to the selected-payload backlog before removing the
mempool entry, so the node never advertises bytes it cannot serve and never
drops availability during the eventual durable handoff. If durable mempool mode
is explicitly configured, atomic store-and-retain must precede visible
insertion; no store-then-retain window is permitted.

## Atomic Compositions That Must Not Be Split

Orthogonal internal logic remains atomically composed at these boundaries:

1. `commitPreflight`: exact durable context and exact live batch application.
2. Admission reservation: final batch, prospective direct edges, and projected
   inherited work are accepted or rejected before any durable write.
3. `ChainState.applyStaged` / `applyReservedStaged`: graph, grind location,
   segment indexes, fork projection, and revision.
4. Parent-work reservation and `ChainState.mergeInheritedWork`:
   unique-location validation, monotone merge,
   affected index updates, fork projection, and revision.
5. Genesis bootstrap: selected Volume storage, context staging, restore, then
   runtime exposure.
6. Parent-work readiness: only a complete current authenticated pass may enable
   child operation.
7. Selected-payload handoff: reserve bounded capacity before semantic staging;
   after staging, exact live apply and backlog transfer have no expected failure
   or cancellation point.

Private functions may express these pieces clearly. None becomes an
independently callable public mutation.

## Failure Semantics

| Failure | Result |
|---|---|
| Inventory timeout/disconnect | Retry another peer/cursor without inventing availability |
| Exact provider absent | Try another provider for the same root, then current-chain discovery |
| Authenticated wrong-root/invalid complete Volume | Discard, report blameable fault, try another route |
| Empty/timeout/partial transport/local capacity | Discard without blame and retry |
| Missing nested Volume | Keep typed workflow parked; independently acquire that exact dependency root |
| Missing child package | Keep block parked until authenticated evidence arrives |
| Missing predecessor | Park descendant and schedule the typed predecessor |
| Temporary validation failure | Bounded timed retry |
| Protocol-invalid content/evidence | Terminal for that exact semantic attempt |
| Rejected/duplicate attempt | Discard temporary MemoryBroker unless another workflow selected content |
| Selected-payload backlog full | Backpressure before semantic staging or visible mutation |
| Crash before semantic stage | Discard temporary content; no accepted fact |
| Crash after stage, before live apply | Replay exact batch; reacquire any missing selected roots |
| Crash after apply, before/during async Volume persistence | Replay exact batch; reacquire any missing selected roots |
| Background DiskBroker failure | Keep bounded selected snapshot, retry with backoff, and backpressure new promotion |
| Crash after payload persistence, before publication | Rebuild service/provider projections |
| Parent-work persistence failure | Release reservation; merge nothing |

Every queue, page, memory broker, provider result, evidence-root set, and retry
set has an explicit bound.

## Minimal Source Boundaries

Modules are capability boundaries; they do not require one file each.

| Area | Responsibility |
|---|---|
| `IvyHost` | Shared authenticated connections, logical-stream multiplexing, fair flow control, and host/peer resource scopes |
| Ivy namespace endpoint | One chain/plane's router, peer set, provider registry, admission budget, and bounded supervisor route |
| `AcceptedLeafSync` | Accepted-forest inventory facts and paging commands |
| `CandidateAcquirer` | Block/evidence/predecessor/retry scheduling only |
| `ChainVolumeNamespace` | One chain's DiskBroker, Ivy namespace handle, routes, and attempt factory |
| `VolumeAttempt` | Bounded temporary complete Volumes, attribution, and Cashew selection |
| `IvyContentBridge` | Exact-root acquisition and attribution into VolumeAttempt |
| Selected-Volume writer | Bounded root-deduplicated payload backlog, async atomic store-and-retain, retry, and missing-root refill |
| `ChainProcess` | Workflow composition and one durability/mutation lane |
| `NodeStore` | Typed semantic transactions, selected roots, publication authority, and recovery pages |
| `ChainService` | Domain capabilities and derived projection reconciliation |
| `NodeNetworkRuntime` | One chain's namespace registration, local admission pressure, reducer effects, typed Tally observations, and gossip |
| Lattice `ChainLocalAdmission` | Verification, opaque preparation, exact staging context |
| Lattice `Chain` | Durable reducer, work algebra, segment indexes, GHOST projections |

Do not add a universal `AdmissionPipeline`, generic network job, actor per
capability, validator/stager/inserter/fork-choice protocols, broker wrapper
types, or a custom/durable candidate-specific CAS. The bounded ephemeral
`VolumeAttempt` is intentional.

## Verification

### Composability

- the same `VolumeAttempt`/Ivy/Cashew composition resolves a block,
  transaction, evidence attachment, spec, policy, and state witness;
- acquisition can run without validation, and rejected content leaves no
  durable chain storage;
- carrier verification can return a usable link without graph insertion;
- consensus restart restores from exact batches without Ivy, Cashew resolution,
  or block validation; missing selected payload roots refill independently
  afterward;
- provider publication reads semantically publishable roots without invoking
  admission;
- inherited-work projection is deterministic without a `ChainState` actor.

### Namespace isolation

- child `VolumeAvailable(T)` is invisible to parent discovery;
- a child cache/traffic flood cannot evict parent content or consume parent
  storage, request-token, send-pressure, connection, or bandwidth quota;
- many individually compliant children cannot exceed the host/peer hard limits
  or consume capacity reserved for Nexus and live-parent traffic;
- two chains sharing one authenticated connection retain independent stream
  flow control, queues, routing tables, peer sets, provider registries, and
  admission decisions;
- a blocked child stream cannot head-of-line block a parent hierarchy stream;
- a transport restart disconnects and restores namespace streams without
  changing either chain's durable facts or fork choice;
- the same CID exists and validates in both namespaces without shared provider
  state;
- the same authenticated peer accumulates one cross-chain Tally evidence record,
  while chain/plane-local request and pressure decisions remain independent;
- useful exchange across many child namespaces cannot exceed its scoped
  contribution caps;
- a cryptographically attributable violation observed on a child changes shared
  peer evidence, while child timeout/empty/local-overload observations change
  neither shared evidence nor parent admission state;
- an explicit evidence bridge copies verified bytes into receiver attempt
  memory without importing sender provider state; only the receiver's own
  authenticated exchange observation enters shared Tally evidence;
- stopping one chain does not disturb another chain's retained roots or
  provider refresh.

### Full-history availability

- every accepted branch, not only the canonical projection, remains in the
  full-node archive closure;
- the retained closure equals the union of exact boundaries selected by durable
  accepted facts and contains no rejected or merely fetched Volume;
- one reachable full archive can bootstrap a fresh same-chain node through
  public inventory and exact Volume requests without erasure-coded fragments;
- losing the last archive changes availability health but not validity, work,
  or fork choice;
- an archive serving malformed bytes is rejected by CID/Volume validation,
  while a missing response does not become a consensus fact;
- a host archiving several chains remains one operational failure domain and
  never turns its chain-scoped provider lease into cross-chain availability;
- a child with complete archived history remains non-operational until its live
  configured parent completes inherited-work readiness.

### Knowledge and content

- accepted inventory never creates an exact provider;
- generic `VolumeAvailable` never creates a block candidate;
- block `D` provider is never queried for predecessor `P` or nested `T/S/W`;
- malformed provider A followed by valid B succeeds and blames only A;
- empty/timeout responses never penalize a peer;
- generic empty/timeout/local-capacity does not revoke a provider lease; local
  monotonic expiry/disconnect does;
- renewal ordering, replacement sessions, bounded per-session lease counts, and
  mempool-to-backlog-to-Disk owner-union handoff cannot create an immortal or
  unservable claim;
- recursive `D -> P -> Q` wake-up is order-independent;
- parking or retry releases every attempt byte before later reacquisition;
- recovery pages refill with no overflow exemption or root truncation.

### Temporary and durable Volume lifetime

- valid remote content remains only in attempt memory until selected;
- Lattice/Cashew matching store paths select the exact complete boundaries;
- unselected temporary Volumes disappear when the attempt ends;
- active claims and canonical boundary manifests are journaled before
  visibility and only their exact complete Volumes enter the correct chain's
  asynchronous writer;
- insertion and fork choice complete without awaiting DiskBroker;
- selected storage and retained-root merge are one broker transaction;
- validation, broker-store, retention-merge, and concurrent-eviction failures
  never expose a partially retained selected set;
- once stored-and-retained, selected Volumes survive restart and eviction;
- a failed background write retains bounded pending bytes, retries
  idempotently, and backpressures new promotion;
- restart uses active claims, never released historical selection alone, and
  never reruns semantic validation; missing roots reacquire through ordinary
  Ivy and must match the exact canonical boundary manifest;
- missing-member, unrelated-extra-member, and same-root conflicting archives
  never satisfy or retain a recovery claim;
- two claims for the same root with different manifests fail as fatal local
  invariant corruption before coalescing;
- release-before-write, release-during-backoff, and restart-after-release never
  reacquire a root after its last active claim disappears;
- provider reprojection publishes only semantically authorized, currently
  retained roots in the correct namespace;
- private retained child-intent/inbox/cache roots are never published;
- an accepted ephemeral mempool root is advertised only while its exact Volume
  remains live and is absent after eviction/restart;
- every accepted Lattice admission explicitly selects its block root; the node
  never adds it implicitly because it happens to be processing a block.

### Lattice algebra and atomicity

- preflight mutates no accepted state;
- exact batch plus prospective inherited work is reserved before semantic
  durability;
- staged, applied, returned, and replayed batches are exactly equal;
- persistence failure produces no visible insertion;
- live apply and recovery replay produce identical graph, work, and tip;
- duplicate/stronger grind observations join once at maximum quantity;
- grind relocation fails atomically live and on replay;
- an outstanding reservation excludes every competing `ChainState` mutation
  while its stage callback is blocked; only matching apply or release proceeds;
- admission, parent-work, and late-edge reservations release on pre-stage
  cancellation/`NodeStore` failure; reject mismatched or double consumption;
  successful consumption advances exactly one combined revision/projection;
- precommit failure releases both consensus and payload-handoff halves of the
  scoped permit; exact-limit and deduplicated-root transfers rebind aggregate
  memory ownership without a second charge;
- claim add/release racing a payload write cannot miss a new retention scope;
- restart after semantic commit needs no in-memory reservation token;
- `P/G/Q + P -> C` counts at C;
- no edge or only a sibling edge contributes nothing at C;
- noncanonical P counts with an edge; canonicity-only changes do not;
- three-level recursive projection equals the direct reference;
- optimized segment GHOST matches reference GHOST across randomized forests;
- no public call can project between graph insertion and index update.

### Crash and readiness

Use subprocess kill points after `NodeStore` commit, `ChainState` apply,
selected-payload backlog handoff, broker store-and-retain, parent-work commit, and
service publication.

Before semantic commit, ordinary errors/cancellation expose no fact. After
commit, only process death may interrupt exact live apply and selected-snapshot
handoff. Volume persistence failures occur afterward and never roll back
consensus.

Exercise cancellation before backlog reservation and before semantic staging.
After `NodeStore` commits, deliberately injected cancellation cannot prevent
exact apply or backlog handoff. Kill before and during the background write;
restart must restore consensus first and reacquire only missing selected roots.
Test `NodeStore` failure for permit leaks and graceful stop during the
post-commit apply/handoff window.

On restart, assert graph, grind locations, hierarchy bindings, active claims,
boundary manifests, retained roots/scopes, publishable semantic roots, revision
floor, provisional tip, and parent-work cursor. Assert that canonical tip,
main-chain membership, cumulative/subtree work, and segment caches are not
durable authority. Assert that private retained roots are not re-advertised.

Test parent disconnect, incomplete pass, restart after durable parent work, and
restart after live merge. None restores operational readiness until a new
complete authenticated pass.

For parent revision semantics, test older/equal revision plus an unseen fact,
older/equal revision plus a stronger same-location quantity, lower revision
plus a relocation conflict, and a valid complete pass lacking the current live
readiness handshake that joins facts without enabling readiness.

### Realistic end to end

Production scenarios use public node behavior: transactions, templates,
external work submission, peer connections, chain subscription/deployment,
start/stop, and RPC reads.

Required scenarios:

1. Three-node same-chain partition with independent valid branches; heal and
   converge by exact Lattice work.
2. Multi-block late join, then restart the joining node with its source offline.
3. Child obtains all CID-verifiable content from same-chain peers while parent
   is offline, but remains non-operational until the live parent work pass.
4. Parent reconnect converges through public behavior using bounded revision
   deltas/pages. A separate instrumented integration/performance assertion
   proves no ancestry replay.
5. Accept child block `C` first, then deliver authenticated `P -> C` evidence
   later through the real hierarchy path. Already durable noncanonical parent
   work affects exactly C once. Subprocess kills after edge `NodeStore` commit
   before live merge and after merge before evidence-payload persistence both
   recover identically; no edge-row injection is permitted.
6. Three-level hierarchy receives newest descendant `D`, disconnects D's
   source before predecessor `P` is requested, restarts while parked, then
   connects to a P provider and acquires predecessors through ordinary
   networking. No test-only orphan injection is permitted.
7. Existing cross-chain receipt/withdrawal/swap coverage is mapped and extended
   through a parent/child reorganization rather than duplicated.
8. Transaction A-to-B lifecycle: A gossips a transaction root and live Volume
   availability; B fetches, validates, relays, and serves it while resident; an
   external miner includes it; the mempool-to-selected-writer-to-Disk handoff
   has no unservable interval; eviction/restart removes ephemeral ownership
   without breaking retained block serving.
9. The parent deploys/spawns a noisy child through the production child-chain
   path. Saturate the child's allowed connections, content requests, and
   storage quota while asserting the parent still admits blocks, publishes
   inherited work, and serves RPC within configured bounds. Repeat across many
   individually compliant children and assert the shared host/peer governor
   preserves Nexus and live-parent reserved capacity.
10. Real-daemon subprocess fault injection externally stalls the production
    DiskBroker (or waits until RPC/metrics report pending payloads). Admission,
    insertion, accepted-leaf gossip, and fork choice complete; the block's
    selected Volumes remain servable from bounded memory. Release the stall and
    assert atomic retention and provider publication without another consensus
    mutation.
11. With another normal peer having fetched the live payload (or the original
    supplier still online), kill after semantic commit/live apply while metrics
    show pending payloads. Restart restores the accepted graph from `NodeStore`,
    reacquires only missing manifested roots through ordinary Ivy, and reaches
    identical work/tip without revalidation or double-counting. Repeat with no
    provider: the same graph/work/tip restores content-degraded, then a later
    normal peer repairs it without block re-admission.
12. Accept a block with nested transaction/state/evidence Volumes and wait
    until the retaining node reports backlog empty and every public root
    complete. Stop the original supplier, restart the retaining node, and let
    its bounded reprovider make those exact roots discoverable to a fresh peer.
    A retained private child-intent/inbox root remains undiscoverable.
13. Two nodes subscribe to two chains over one physical authenticated
    connection. Flood one child namespace while the other extends normally and
    its hierarchy pass completes. Assert independent stream flow control,
    provider tables, Tally contribution caps, and exact per-scope resource
    accounting. Restart only the shared transport supervisor; both chain
    processes preserve consensus and independently restore their namespaces.
14. Bootstrap a fresh node from the only reachable full archive after creating
    canonical and noncanonical accepted branches with nested state,
    transaction, module, and hierarchy-evidence Volumes. The source supplies
    the entire selected closure through public behavior. Removing that archive
    reports history unavailable without changing another recovered node's
    validity or GHOST projection.

Malformed wire bytes belong in real-Ivy hostile-peer integration tests because
the production daemon has no public API for serving corrupt content.

Instrumented memory tests, distinct from public-behavior E2Es, drive concurrent
maximum Cashew frontier responses plus materialized state while mempool/backlog
bytes already consume quota. They measure resident-byte high-water marks,
network-buffer/ownership-copy/writer overlap, cancellation cleanup, exact-limit
snapshot transfer, mempool old-plus-new replacement, and pre-`NodeStore`
backpressure.

## Rejected Designs

- A universal six-stage service pipeline.
- Six actors or one-implementation stage protocols.
- A serialized or persisted "segment Volume."
- A node-owned validation dependency planner.
- A global cross-chain provider registry or shared eviction quota.
- One global Ivy router, DHT, provider table, admission budget, or send queue.
- Chain-tagged messages on one ordered connection without independent stream
  flow control.
- Per-chain physical listeners and duplicate authenticated connections when the
  same two nodes share several chain namespaces.
- Putting the namespace into the CID.
- Treating a local archive pin or provider advertisement as proof of
  availability.
- Erasure coding or availability sampling while full replicated archives are
  the configured Lattice availability model.
- Persisting every valid fetched Volume before Lattice selects it.
- Temporary pin owners/TTLs for bounded attempt content.
- Public graph insertion or replaceable fork-choice strategy.
- Persistent canonical tip, main-chain projection, cumulative/subtree work, or
  GHOST segment caches.
- A generic `persistThenApply` framework that hides the authoritative semantic
  transaction.

## Review Score

The earlier capability/persistence design completed adversarial review. The
shared-transport, hierarchical-resource, scoped-Tally, and full-history
availability amendments require a fresh adversarial review before
implementation.

| Dimension | Consensus reviewer | Crash/lifecycle reviewer | E2E/realism reviewer |
|---|---:|---:|---:|
| Simplicity | B+ | 9/10 | A- |
| Elegance | A- | 9/10 | A |
| Intuitiveness | A- | 9/10 | A |
| Correctness | A | 9.5/10 | A |
| Efficiency | A- | — | A- |
| Composability | A | — | A |

The strongest dissent was that synchronous selected-Volume storage is simpler
and preserves the old `NODE-STORAGE-002` invariant. That claim is correct in
isolation and caused the invariant migration and crash tradeoff to be made
explicit. The design nevertheless keeps asynchronous payload persistence
because it is the approved requirement; semantic Lattice durability remains
synchronous and write-ahead.
