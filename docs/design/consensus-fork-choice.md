# Consensus and fork-choice ownership

Consensus is defined by Lattice, not by `lattice-node`. The canonical rules are
the [protocol specification](https://github.com/adalinxx/Lattice/blob/18.0.1/docs/spec.md)
and [work and fork-choice rationale](https://github.com/adalinxx/Lattice/blob/18.0.1/docs/consensus-fork-choice.md).

The node owns only the operational boundary around those rules:

- authenticate immediate-parent and direct-child processes;
- acquire the exact sparse evidence Lattice requests;
- persist accepted fact batches before exposing their effects;
- retain and replay the same immutable facts after restart;
- route monotonic, path-scoped inherited-work snapshots without inventing new
  work quantities; and
- project the one canonical chain delta returned by Lattice.

Work observations are joined by grind identity before they are totaled.
Accepted parent work may affect a child; changing only the parent's canonical
pointer may not. Exact work ties use Lattice's deterministic segment-base CID
rule, never arrival order or an incumbent preference.

The node must not implement a second fork-choice metric, accept peer-supplied
work totals, recursively choose descendant tips, or send parent canonical-tip
commands across the hierarchy plane.
