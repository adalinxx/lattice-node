# Chain Addressing Model

> This addressing model is the names-layer expression of Lattice's broader [fractal structure](fractal-structure.md) — the organizing protocol that secures heterogeneous chains via PoW. Read that first for the operational principle; this document is the addressing specifics.

## Summary

A **Lattice chain** is both a root chain and the tree of chains rooted at it; **Lattice** is the protocol that defines this. The **Nexus** is the single root and the primary entry from outside; every other chain is a descendant spawned beneath it (see [process trust model](process-trust-model.md)). A `directory` is not a globally unique chain identity; it is an edge label used to move from one chain node to one of its children.

```
external client
  |
  v
Nexus
  | Payments
  v
child chain
  | Rollups
  v
grandchild chain
```

In this example, `Payments` and `Rollups` are directories: relative edge labels. The canonical address of the grandchild chain is the full path:

```
Nexus/Payments/Rollups
```

## Terms

| Term | Meaning |
|------|---------|
| Lattice | The protocol: every chain is both a root chain and the tree of chains rooted at it |
| Nexus | The single root — the primary entry from outside; every other chain is a descendant |
| Chain node | A node in the tree with its own state, blocks, mempool, and network |
| Directory | The edge label from a parent chain to a child chain |
| Relative path | A sequence of directory edges interpreted from the chain node being queried |
| Chain path | The normalized route to a target chain; Nexus-rooted form is the canonical global representation |
| Chain address | The normalized internal representation of a chain path |

## Rules

1. **Canonical identity is a chain path.** Internally, a chain is identified by its absolute route from Nexus, not by the final directory component.

2. **Directories are relative.** A directory only has meaning relative to a parent chain. `Payments` under `Nexus` and `Payments` under `Nexus/Games` are different edges and may point to different chains.

3. **Selectors are relative to the queried chain.** A selector like `Payments/Rollups` is interpreted from the chain node that receives the query. When that node is `Nexus`, the selector may also be written as the Nexus-rooted canonical form `Nexus/Payments/Rollups`.

4. **The root label is reserved in selectors.** If a selector starts with the current tree's root label, it is interpreted as the Nexus-rooted canonical form rather than as a child edge under the queried chain.

5. **Relative paths require context.** A relative path like `Payments/Rollups` is valid only when the caller has already selected a parent context.

6. **No bare-directory public APIs.** External APIs accept chain paths. A bare directory name is valid only inside code that already has an explicit parent-chain context.

7. **Storage namespaces must not depend on leaf uniqueness.** Per-chain state, mempool persistence, caches, metrics, and peer-tip state should be namespaced by chain path or a stable encoding of chain path.

## Implementation Implications

The following should be treated as migration targets:

- Public RPC and CLI surfaces should use `chainPath`; `network(for directory:)` is an internal compatibility shim only.
- Internal maps such as `networks`, `miners`, `persisters`, `stateStores`, `tipCaches`, `postStateCaches`, `knownPeerTips`, and sync bookkeeping should be keyed by chain address.
- Iteration should prefer `ChainNetwork` values or chain paths, not leaf directories.
- Persistence should write under a path-aware namespace such as `chains/Nexus/Payments`, or a stable encoded equivalent if filesystem constraints require it.
- `ChainSpec.directory` should be read as the child edge label selected by the parent, not as a globally unique chain id.
- Transaction `chainPath` remains load-bearing replay protection and should compare against the canonical chain address of the validating chain.

## Migration Shape

The safe migration path is incremental:

1. Introduce a small `ChainAddress` type around `[String]`.
2. Add path-aware lookup and persistence helpers while keeping existing directory APIs.
3. Convert internal maps and iteration to `ChainAddress`.
4. Move per-chain disk namespaces to path-aware locations with backward-compatible reads from legacy leaf directories.
5. Add tests with duplicate edge labels, for example `Nexus/A/Payments` and `Nexus/B/Payments`.
6. Remove ambiguous bare-directory API surfaces; keep `directory` only for parent-relative edges.

The goal is not to rename every `directory` immediately. The goal is to make every new or changed call site explicit about whether it is handling an edge label, a relative path, or an absolute chain address.
