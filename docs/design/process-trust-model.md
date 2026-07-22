# Process trust model

## One process, one chain

Each process owns one absolute Nexus-inclusive chain path. External
orchestration decides which processes run; a node starts and supervises no
descendant processes.

The process topology follows direct chain relationships without collapsing
them into one runtime:

```text
Nexus process  ── authenticated facts ──▶  Nexus/Payments process
```

The parent owns only its own chain. The child owns only its own chain. Neither
process grants the other database access, enumeration, mutation, or consensus
authority. An accepted direct relationship may request an exact set of CAS
objects by CID; those read-only bytes are protocol availability, not access to
the process's storage interface.

## Configured parent authority

A non-Nexus process must be started with both:

- its complete path, such as `Nexus/Payments`; and
- its immediate parent fact endpoint, such as
  `<nexus-process-key>@parent.example:4002`.

The configured process public key pins which authenticated Ivy peer may provide
parent facts. A path claim by itself is not authority. Nexus rejects a parent
configuration because it is the single root.

## Verify content independently

Parent authorization and content validity answer different questions:

- The configured key answers: "which process is allowed to speak as my
  immediate parent?"
- CIDs, proof of work, child-inclusion proofs, state continuity, and consensus
  validation answer: "are these facts valid?"

The first never bypasses the second. A correctly authenticated parent can
provide availability and lineage facts, but cannot force invalid bytes into
child state or dictate the child's fork choice.

## Separate planes

Same-chain overlay traffic and parent/child facts use separate Ivy instances.
The hierarchy plane disables relay and carries only direct relationship facts.
This prevents a public overlay peer from becoming a parent merely by claiming a
path.

Direct children authenticate and advertise their absolute path on the hierarchy
plane. The parent may request a candidate or publish a proof only for an
immediate child whose path equals `parentPath + [directory]`.

Exact-CID exchange is explicitly enabled only on this private Ivy plane. A
connection must complete its own compatible hierarchy hello before it may read
content; reconnecting with the same key does not inherit the previous
connection's authorization. Requests cannot enumerate storage and must name a
complete bounded selection. The response is non-secret content-addressed
availability: the receiver verifies every CID and all Lattice evidence before
the bytes can affect state. Any accepted replica for a locally issued direct
child path may participate; a path claim remains routing, not branch authority.

During one bounded child-candidate round, the parent also serves the exact
provisional carrier only when that carrier CID is the request root. The lease
is reference-counted, scoped to the runtime generation, and removed after the
round. It is never persisted and cannot be smuggled into a request rooted at
unrelated durable content.

The hierarchy receiver gives its one configured immediate parent a narrow
transport-liveness exemption from its local Tally bucket. That exemption is
limited to the private plane's exact configured bootstrap key; it does not
weaken the hierarchy hello, path, authenticated-parent, fact, or Lattice
validation gates. Overlay peers and all other hierarchy peers remain
Tally-gated.

## Direct-edge retention, one-way authority

A direct parent-child commitment has one root-independent identity: parent
carrier CID, child directory, child CID, and canonical one-hop sparse proof.
The parent retains an edge when it issues that commitment. The child retains the
incoming edge after validation and may relay complete parent-signed root
attachments to same-chain peers.

No child sends an edge inventory, accepted topology, coverage claim, or work
back to its parent. The parent is child-agnostic outside bounded candidate and
proof publication. The child owns the exact vertical relation used for
consensus projection.
## Genesis authority

Nexus has no parent, so its one unsigned genesis is constructed locally and
pinned by CID:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

The CID is checked before configured root bootstrap, never used as a
peer-admission signature permit. Every child genesis is ordinary content bound
to a parent state. A prepared child intent becomes authoritative only after a
separately signed parent `GenesisAction` transaction is accepted in a carrier
and the child verifies the resulting parent genesis link.

## Inherited work

Inherited work is a trusted, monotone report from the configured immediate
parent, not a proof protocol. For one chain it is the partial function:

`grind -> (block, greatest verified quantity)`

A grind has one block location per chain. Repeating the same location takes the
maximum quantity; another location is a hard conflict even if either block is
unknown, disconnected, or noncanonical.

The parent publishes this generic relation over all connected accepted blocks.
Canonicity does not filter work. Every direct child receives the same relation;
the parent knows no child topology. The child alone owns the partial function
`parent block -> child block` and performs an exact join. Parent ancestry never
invents a child commitment. After the join, ordinary same-chain ancestry makes
a descendant location contribute to each ancestor's GHOST subtree.

The durable table is keyed uniquely by grind and indexed by parent block. A live
delta updates only changed grinds and looks up only matching child edges. A new
edge activates already-durable facts at that exact parent block. Full
materialization is limited to startup and a new/reconnected parent session.

Wire passes are bounded and atomic. All frames share one nondecreasing revision
and end with an ordered empty marker. Incomplete state is discarded when the
exact session changes. The first complete pass from the configured live parent
makes child consensus ready; losing that live authority preserves verified
facts for recovery but pauses consensus publication. This readiness dependency
propagates recursively. Nexus has no incoming parent report.
## Operational consequence

Treat `--parent` as security configuration, not discovery. Changing it changes
who may supply parent facts. Keep process identity keys stable, restrict the
fact-plane port to intended relationships, and back up identity separately from
wipeable chain storage.
