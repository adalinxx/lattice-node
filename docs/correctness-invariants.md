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
