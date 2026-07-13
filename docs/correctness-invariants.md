# Correctness invariants

## NODE-SEMANTICS-001 — every Lattice outcome has one node meaning

`canonicalized`, `acceptedSide`, `duplicate`, `unavailable`, `invalid`, and `storageFailed` remain distinct at the node boundary.

## NODE-SEMANTICS-002 — side validity is not canonicity

`acceptedSide` is valid admission but never publishes a canonical tip.

## NODE-SEMANTICS-003 — availability is retriable, not punishable

`unavailable` is retried when availability changes and cannot penalize the supplying peer.

## NODE-SEMANTICS-004 — local durability is not peer behavior

`storageFailed` maps to a local Tally observation and cannot penalize the peer.

## NODE-SEMANTICS-005 — only obtained invalid evidence is punishable

Only `invalid` maps to remote invalid-evidence attribution.

Established by: `NodeConsensusDecisionTests`.
