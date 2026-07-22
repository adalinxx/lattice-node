# Lattice Node Protocol Boundary

The Lattice library is the normative owner of validation, state transitions,
work accounting, and fork choice. Its `spec.md`, `foundational-architecture.md`,
`consensus-fork-choice.md`, and `philosophy.md` define protocol behavior. This
document records how `lattice-node` realizes that boundary.

## Chain identity

A process owns exactly one absolute Nexus-inclusive path:

```text
Nexus
Nexus/Payments
Nexus/Payments/Receipts
```

The path is immutable setup, not transaction-selected routing state. A process
never embeds child runtimes. Nested child commitments are data; each child
process validates its own sparse route and chooses its own canonical projection.

The pinned Nexus genesis CID is:

```text
bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq
```

It contains the deterministic premine transaction for public key
`ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d`.
On an empty store, the node constructs it locally, recomputes its CID, and
uses it only for configured root bootstrap. The CID is a trust anchor, never a
peer-admission signature permit. Child genesis transactions and every ordinary
transaction remain subject to normal Lattice signature validation.

This genesis is a storage cutover. Existing node data is not migrated; remove
the old chain directory before starting this version.

## Transactions

HTTP and hierarchy messages carry concrete transaction bodies with their
signatures. A cashew header alone is not a complete transaction payload.
`lattice-node` binds the concrete body back to its CID before admission, then
Lattice validates the transaction for the process's absolute path.

Lattice accepts both the current domain-separated transaction preimage and the
historical body-CID preimage. Mixed multisignature envelopes are valid when each
individual signature verifies under one accepted form. This compatibility does
not weaken body, signer, nonce, or path validation.

Mining rewards are ordinary externally signed transactions. Process identity is
never converted into wallet identity, and the node does not receive a reward
private key.

## Work and hierarchy evidence

One mined root CID identifies one physical grind. It has one terminal block
location per chain and may be projected across exact hierarchy edges. Repeated
observations of that root do not create additional work.

Wire and durable work facts use the unique canonical CID spelling for that
identity. An alternate multibase spelling is rejected before it can become a
second work key. This encoding rule is distinct from branch canonicity: every
accepted branch's eligible work still counts whether or not that branch is the
current canonical projection.

A child candidate is delivered with a sparse proof from the mined root to that
exact child. Admission checks the setup-wide root-work floor before resolving
expensive child content, then verifies the path, carrier continuity, vertical
state binding, the local target, and the local state transition.

Accepted parent work may contribute to a child's fork choice even when the
parent branch is not the parent's current canonical projection. Parent
canonicity alone contributes nothing. An authenticated parent process may issue
root-bound carrier and genesis facts; it cannot declare the child valid or
choose the child's tip.

Immutable carrier/genesis facts may be relayed by same-chain peers with the
parent's certificate. Current inherited weight may not: after each parent
reconnect, nonempty monotone fragments end with an ordered empty snapshot on
that exact session. Every pass carries one nondecreasing revision; equal or
older revisions may add previously unseen monotone facts, and reconnect may
replay the same relation at the same watermark. Its marker must match;
a mismatch revokes the session. Until that marker arrives, the child keeps the bounded
incomplete batch out of fork choice. Before the first marker it exposes no
current canonical decision and produces no mining work; during later deltas the
last complete view remains operational. Disconnecting discards an incomplete
batch and revokes readiness.

`parentState` commits the carrier's `prevState`. It is not a parent-block
backlink and is never inverted to discover ancestry.

## Admission and durability

All ingress follows one sequence:

```text
acquire
  -> verify
  -> store sparse validation content and complete selected volumes
  -> retain required roots
  -> atomically stage one immutable Lattice batch
  -> apply that exact batch
  -> project one chain
```

The stage callback is the durability boundary. Success means the complete batch
is durable; failure exposes none of it. Live execution and recovery both apply
the same staged facts. Publication, proof replay, and other post-commit network
effects cannot rewrite an already durable admission result.

Each path stores operational metadata and Volume-root references in `state.db`,
and every content-addressed byte in `volumes.db`. VolumeBroker is the only
durable local CID-to-bytes store. The node owns acquisition, authentication,
retention, routing, and operational projections. Lattice owns accepted
consensus facts and never uses storage presence or peer identity as validity.

## Network planes

The node uses two Ivy sessions:

- the public same-chain overlay exchanges announcements and same-path content;
- the private hierarchy plane connects one configured immediate parent with its
  direct children and carries contextual candidates, inherited work, and
  root-bound proof facts.

Both planes currently require node protocol version 2. Portable signed parent
facts are versioned wire semantics, so mixed-version peers refuse the session
and must be upgraded together.

Peer content exchange is Volume-native. An announcer names one complete Volume
by its root CID and must serve that Volume from the exact authenticated session
that made the claim. Each connection must complete a compatible hello before it
may request a Volume, including a same-key replacement connection. Entry CIDs,
bounded framing, and atomic publication are transport/storage details; node
protocol messages never request arbitrary CID selections.
During a candidate round, the parent may serve the ephemeral provisional
carrier only as that request's root and only for the lifetime of the round.

Hierarchy authorization comes from the configured immediate-parent key or a
durable parent-issued child directory/genesis relationship, not a process key
choosing a branch. CAS bytes are non-secret availability and grant no validity:
the consumer verifies every CID and the exact Lattice evidence it reads.

### Child-evidence availability

The root-independent direct edge belongs to one ordinary child-evidence Volume.
Its canonical manifest commits the envelope and exact sorted acquisition-member
CIDs; those members retain their original content addresses. Missing, extra,
duplicate, or CID-mismatched members invalidate the whole Volume. A parent
persists the edge when it issues the child commitment; a child persists the
incoming edge when it validates that commitment. Children never return edge
inventories or topology to parents.

On the same-chain overlay, a child can advertise a child-evidence Volume whose
envelope contains the complete proof plus detached parent carrier/genesis
certificates. Each
certificate is bound to the Nexus genesis, absolute parent path, fact fields,
and configured Ed25519 parent authority. It authenticates only the immutable
parent fact; Lattice still derives work and validates the child. A genesis
attachment requires both certificates. Nexus neither requests nor accepts
portable attachments.

Both inventories are cursor-bound and name one exact Volume at a time. Each
current Ivy response is one frame-bounded complete Volume; oversized Volumes
are rejected rather than partially published. Ivy owns request deadlines and session fencing,
while the node caps concurrent acquisition and recycles a silent or malformed
session. Exact-announcer binding provides accountability and prevents one peer
from making the node search the wider network for arbitrary roots; it is not a
source of content validity.

Parent-to-child evidence uses the same shape: each index or live summary names
the child CID, physical root CID, and complete attachment Volume CID. The child
fetches that Volume directly from the exact parent session. Multiple roots for
one child are separate summaries. No proof-root pagination or evidence
request/response layer exists beneath this inventory.

Inherited work flows only parent to child. The parent exports one generic,
monotone `grind -> (parent block, quantity)` relation to every direct child.
The child alone joins those locations through its durable exact
`parent block -> child block` edges. A completion marker makes each stream pass
atomic; the first completed pass from the configured live parent grants
consensus readiness.

### Transaction pool

The mempool is operationally first-class but never consensus authority.
Transactions are same-chain Volumes: peers advertise a transaction Volume root,
the receiver pulls it from that exact session, resolves the transaction, and
re-materializes the canonical typed Volume locally. Unrelated peer-supplied
members are never retained or relayed. Lattice then validates the transaction
against the current state, and the node relays only a newly admitted root.
Parent-child hierarchy sessions never merge mempools.

The pool separates executable, future-nonce, and temporarily unavailable
transactions by signer nonce. Template selection advances a dependency
frontier across every signer, choosing the highest-fee eligible transaction
without copying state validity out of Lattice. The pool applies
bounded replacement, expiry, and low-value eviction, and revalidates after every
canonical change. Transactions confirmed on the new chain leave the pool;
ordinary transactions from removed blocks are reinserted when still valid.
Successfully revalidated transactions from disconnected canonical history are
durable, bounded reorg candidates: their bytes already belong to accepted block
Volumes. On restart, a non-equal service checkpoint replays the net fork delta
to the current canonical tip. An unprojected transient branch that returns to
the checkpoint is not replayed; peer-origin transactions seen only on that
branch require rebroadcast. Unconfirmed peer gossip remains volatile.
Locally submitted transaction roots survive restart and are revalidated before
becoming visible again. Live pool roots use process-owner VolumeBroker pin
deltas and are unpinned on removal; startup clears that owner before restoring
explicitly durable rows: local submissions and successfully projected reorg
candidates. Ordinary unconfirmed peer gossip is serveable while pooled but
never becomes restart authority.

## External mining

The node constructs the final nonce-zero template and owns transaction
selection, contextual child candidates, target calculation, admission,
durability, and publication. It never runs a nonce-search loop.

`lattice-mining-coordinator` fetches work, allocates disjoint ranges, detects a
changed tip, and submits `workID + nonce`. `lattice-miner` only searches one
immutable serialized block/range assignment.

The miner-facing API is:

```text
POST /v1/mining/templates
POST /v1/mining/work
```

Template requests may contain externally signed reward transactions keyed by
absolute chain path. The node partitions those rewards through the hierarchy
request and issues only the final parent template.

The request mode defaults to `normal`, which excludes every transaction that
contains a `GenesisAction`. `deployment` selects one fully backed local or
descendant deployment subtree per round and propagates its hardest target to
Nexus. This separation prevents unavailable child content from poisoning
ordinary mining.

## HTTP surface

The unauthenticated adapter is loopback-only:

```text
GET  /health
GET  /v1/status
GET  /v1/blocks/:cid
GET  /v1/transactions/:cid
GET  /v1/accounts/:address/proof
POST /v1/transactions
POST /v1/mining/templates
POST /v1/mining/work
POST /v1/children/intents
```

See [RPC API](rpc-api.md) for DTOs and [Architecture](architecture.md) for
component ownership.
