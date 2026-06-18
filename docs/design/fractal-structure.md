# Fractal Structure

The addressing-layer consequences are spelled out in [chain-addressing.md](chain-addressing.md); this document states the broader organizing principle.

## The principle

Lattice does **not** make every chain run the same operations. Each chain defines its **own** operations — its own rules, state transitions, validity, and economics. A Payments chain and a Rollups chain can be completely different.

What Lattice defines is the **protocol that organizes chains so they secure each other via proof-of-work.** That *organizing protocol* — not the chains' operations — is what is fractal: the relationship by which a parent secures its children (merged-mined PoW, parent-state anchoring, content-addressing, relative routing) is **self-similar** and repeats at **every edge** of the tree, recursively.

The recursion is literal: a **Lattice chain** is itself both a *root chain* (its own blocks, state, operations) and a *tree of chains* (the subtree rooted at it). Chain and tree are the same object — that identity is the source of the self-similarity. The outermost chain — the one whose parent is the external world — is the **Nexus**, the single root; every other chain is a descendant spawned beneath it ([process trust model](process-trust-model.md)).

So there are two layers, and only one of them is universal:

- **The Lattice protocol (universal, self-similar).** How a chain relates to its parent and its children: a parent's single proof-of-work secures the child blocks embedded under it; a child anchors to its parent's state; chains are addressed by relative route. The *same securing relationship* holds at every parent→child edge — `Nexus→Payments` is the same kind of edge as `Payments→Rollups`.
- **Chain operations (per-chain, heterogeneous).** What a given chain actually *does* — its transaction and state rules. These differ from chain to chain. A child is not a copy of its parent; it is its own chain, **secured by** its parent.

## Relative, not absolute

The organizing protocol is **relative**: every chain is defined and secured *relative to its parent*. `Nexus` is the single root — the one chain whose parent is the external world — but that does **not** make it a privileged global frame in protocol code: the root→child edge is the *same* self-similar edge as any other, and code must never special-case Nexus as an absolute frame. From inside, a chain knows only "my parent" and "my child edges." The route-based addressing model ([chain-addressing.md](chain-addressing.md)) is this relativity applied to names: identity is the whole route, and a `directory` is a relative edge label, never a global identity.

## Self-similar where it counts

The recursion lives in the **securing and organizing relationship**, not in the operations:

- **Merged mining** is the core fractal: a parent's proof-of-work secures the child blocks embedded under it, and that child in turn secures *its* children the same way. One proof secures the whole route, applied recursively — and the chains it secures can each have different rules.
- **Anchoring** — a child block is validated *relative to its parent*, via `parentState`, parent-state continuity proofs, and the parent's PoW root hash. The anchoring mechanism is universal; the child's own block-validity rules are the child's.
- **Per-process topology** — each chain runs as its own process, subscribes to its **immediate parent**, and relays accepted blocks onto its own gossip so its children subscribe to it in turn. The same subscription relationship repeats at every level. The process tree mirrors the chain tree, and what a process may trust about the children it spawns is the [process trust model](process-trust-model.md).
- **Sync** recurses by the same rule down the tree.

This is a proof-availability relationship, not a parent-canonicality
relationship. A parent makes blocks, state roots, and proofs available; a child
decides whether those bytes are valid by content-addressing, PoW, inclusion
proofs, and state-root continuity. The parent's current canonical tip is not an
authority over child state. That distinction is what lets each level repeat the
same rule without requiring the parent to host a view of every descendant.

## What is and isn't a violation

- **Expected and correct:** chains defining different operations, rules, or economics. Heterogeneity is the point — Lattice organizes diverse chains, it does not homogenize them.
- **A violation:** baking the *organizing protocol* into an absolute frame — special-casing `Nexus` as a privileged frame against "children" (the single-root *topology* is fine; treating that root as a global frame that owns the whole tree is not), assuming a globally unique name, treating a `directory` edge label as a global chain identity ([chain-addressing.md](chain-addressing.md)), or making a child's validity depend on the parent's current canonical branch rather than on verified proof availability. The securing relationship must stay relative and self-similar even though the chains it relates do not.

## Why it matters

Separating the universal *organizing protocol* from per-chain *operations* is what lets Lattice secure an open-ended variety of chains with a single proof-of-work, while keeping each chain free to define what it does. The protocol is the part that must be self-similar and relative; the chains are free to differ.

When changing protocol-level code, ask: **does this securing/organizing relationship hold the same way one level down, expressed relative to the parent — without assuming the child runs the same operations?**
