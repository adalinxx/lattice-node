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
Only that exact Nexus genesis CID may contain an unsigned transaction with no
signers. Child genesis transactions and every ordinary transaction remain
subject to normal Lattice signature validation.

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

One mined root CID identifies one physical grind. A nested proof can extend its
coverage to several paths, but repeated observations of that root do not create
additional work.

A child candidate is delivered with a sparse proof from the mined root to that
exact child. Admission checks the setup-wide root-work floor before resolving
expensive child content, then verifies the path, carrier continuity, vertical
state binding, the local target, and the local state transition.

Accepted parent work may contribute to a child's fork choice even when the
parent branch is not the parent's current canonical projection. Parent
canonicity alone contributes nothing. An authenticated parent process may issue
root-bound carrier and genesis facts; it cannot declare the child valid or
choose the child's tip.

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

Each path stores operational metadata in `state.db` and complete selected
volumes in `volumes.db`. The node owns acquisition, authentication, retention,
routing, and projections. Lattice owns accepted consensus facts and never uses
storage presence or peer identity as validity.

## Network planes

The node uses two Ivy sessions:

- the public same-chain overlay exchanges announcements and same-path content;
- the private hierarchy plane connects one configured immediate parent with its
  direct children and carries contextual candidates, inherited work, and
  root-bound proof facts.

Hierarchy authorization comes from durable parent-issued directory/genesis
facts, not a process key choosing a branch. Any provider may supply bytes; the
consumer verifies the CIDs and exact Lattice evidence it reads.

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

## HTTP surface

The unauthenticated adapter is loopback-only:

```text
GET  /health
GET  /v1/status
POST /v1/transactions
POST /v1/mining/templates
POST /v1/mining/work
POST /v1/children/intents
```

See [RPC API](rpc-api.md) for DTOs and [Architecture](architecture.md) for
component ownership.
