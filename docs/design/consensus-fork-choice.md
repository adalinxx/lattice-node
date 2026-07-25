# Consensus and fork-choice ownership

Consensus is defined by Lattice, not by `lattice-node`. The canonical rules are
the [protocol specification](https://github.com/adalinxx/Lattice/blob/26.0.0/docs/spec.md)
and [work and fork-choice rationale](https://github.com/adalinxx/Lattice/blob/26.0.0/docs/consensus-fork-choice.md).

The node owns only the operational boundary around those rules:

- authenticate immediate-parent and direct-child processes;
- acquire the exact sparse evidence Lattice requests;
- persist accepted fact batches before exposing their effects;
- retain and replay the same immutable facts after restart;
- derive each unique grind's work from its content-addressed child proof; and
- project the one canonical chain delta returned by Lattice.

Work observations are joined by grind identity before they are totaled. One
root contributes at most its strongest target-derived quantity to one
chain-local location; different roots sum. The contribution affects GHOST only
after its terminal child is accepted and connected. Parent admission,
canonicity, and later ancestry do not create or remove that physical work.
Exact work ties use Lattice's deterministic segment-base CID rule, never
arrival order or an incumbent preference.

The node must not implement a second fork-choice metric, accept peer-supplied
work totals, recursively choose descendant tips, or send parent canonical-tip
commands across the hierarchy plane.
