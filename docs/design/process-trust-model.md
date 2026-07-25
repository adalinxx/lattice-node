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

Nexus has no parent, so its genesis is constructed locally and pinned by CID:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

The CID is checked before configured root bootstrap, never used as a
peer-admission signature permit. Every child genesis is ordinary content bound
to a parent state. A prepared child intent becomes authoritative only after a
separately signed parent `GenesisAction` transaction is accepted in a carrier
and the child verifies the resulting parent genesis link. The action and link
identify only the child directory and exact genesis CID. Parent-process trust
is local configuration authenticated by Ivy; it is not committed in the child
`ChainSpec` and can rotate without changing blockchain content.

Signature and signer fields inside a genesis block carry no authority and need
no special empty shape. The exact genesis CID is the authorization: local
configuration for Nexus and the parent action commitment for a child. Ordinary
transactions after genesis remain signature-strict.

## Parent-state continuity and work

The immediate parent answers one authority question for a non-genesis child
candidate: is the new parent-state reference equal to, or transitively reachable
from, the predecessor's reference through connected accepted parent blocks?
The answer is signed over the Nexus genesis, exact parent path, and exact state
pair. It is immutable and portable, so any peer may relay it. Parent canonicity
does not affect this reachability fact.

Work is not a parent assertion. Lattice derives it from the candidate's
content-addressed directory proof: the root grind must beat the terminal target
and commit uniquely to that child along the directory path. One grind counts at
most once at a chain-local location, independent grinds sum, and work affects
fork choice only after the terminal child is accepted and connected.

The parent therefore publishes no work totals, revisions, readiness marker, or
child topology. Data availability remains separate: Ivy and VolumeBroker move
the proof and certificate Volumes, while Lattice independently verifies the
facts they contain.
## Operational consequence

Treat `--parent` as security configuration and preferred live authority, not as
the only possible data source. Changing it changes who may issue new parent
facts. Keep process identity keys stable, restrict the fact-plane port to
intended relationships, and back up identity separately from wipeable chain
storage.
