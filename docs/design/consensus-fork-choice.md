# Consensus and fork-choice ownership

Consensus is defined by Lattice, not by `lattice-node`. The canonical rules are
the [protocol specification](https://github.com/adalinxx/Lattice/blob/24.0.0/docs/spec.md)
and [work and fork-choice rationale](https://github.com/adalinxx/Lattice/blob/24.0.0/docs/consensus-fork-choice.md).

The node owns only the operational boundary around those rules:

- authenticate immediate-parent and direct-child processes;
- acquire the exact sparse evidence Lattice requests;
- persist accepted fact batches before exposing their effects;
- retain and replay the same immutable facts after restart;
- persist the unique `grind -> parent block` relation and join it only through
  child-owned exact `parent block -> child block` edges;
- stream changed work facts by revision, using a full snapshot only for a new
  or reconnected child session; and
- project the one canonical chain delta returned by Lattice.

Work observations are joined by grind identity before they are totaled.
Accepted parent work affects a child only at an exact committed edge; parent
ancestry never invents one. Changing only the parent's canonical pointer may
not change weight. Exact work ties use Lattice's deterministic segment-base CID
rule, never arrival order or an incumbent preference.

The node must not implement a second fork-choice metric, accept peer-supplied
work totals, recursively choose descendant tips, or send parent canonical-tip
commands across the hierarchy plane.
