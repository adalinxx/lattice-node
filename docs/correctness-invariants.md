# Correctness invariants

## NODE-SEMANTICS-001 — every admission outcome has one node meaning

`canonicalized`, `acceptedSide`, `carrier`, `duplicate`, `unavailable`,
`temporarilyInvalid`, `invalid`, `localFailure`, and `storageFailed` remain
distinct at the node boundary.

## NODE-SEMANTICS-002 — side validity is not canonicity

`acceptedSide` is valid admission but never publishes a canonical tip.

## NODE-SEMANTICS-003 — availability is retriable, not punishable

`unavailable` is retried when availability changes and cannot penalize the supplying peer.

## NODE-SEMANTICS-004 — local durability is not peer behavior

`localFailure` and `storageFailed` are local observations and cannot penalize a
peer.

## NODE-SEMANTICS-005 — only obtained invalid evidence is punishable

Only a complete `invalid` same-chain candidate may be attributed to its
supplier. Authenticated parent evidence establishes parent facts; it never
vouches for a child transition.

Established by: `AdmissionDecisionTests`.

## NODE-STORAGE-001 — peers and persistence exchange complete Volumes

Peer-facing content requests name one complete Volume root. Entry-level CIDs
are internal resolution details, and no Volume becomes locally visible until
its exact membership and CID bytes validate.

## NODE-STORAGE-002 — a durable fact never outruns its content

Live publication orders complete Volume storage, merge retention, then the
SQLite semantic reference. Exact retained-set reconciliation and garbage
collection run only while publication is quiescent.

## NODE-MEMPOOL-001 — the mempool is tip-relative, not consensus

The mempool may retain, order, relay, replace, or retry transactions, but only
Lattice validation against an explicit canonical state can make a transaction
executable or include it in a block.

Local submissions commit a complete transaction Volume before their SQLite
reference and survive restart. Every live pool root also has one process-owner
VolumeBroker pin, updated by pool mutation deltas and removed with the pool
entry. Startup clears that owner before restoring only the durable local roots,
so peer submissions remain serveable while pooled but never become recovery
authority. A valid transaction removed from consensus-admitted canonical
history is the one exception: once Lattice revalidates and persists it in the
bounded pool, its durable root and service-projection checkpoint make recovery
idempotent across crashes. Startup replays the net fork delta from that
checkpoint to the recovered tip. A peer-origin transaction seen only on an
unprojected transient branch remains volatile and requires rebroadcast.
