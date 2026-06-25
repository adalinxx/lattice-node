# Lattice Documentation

**Lattice** is a protocol in which every chain is both a *root chain* (its own blocks, state, and operations) and a *tree of chains* (the subtree rooted at it), with each chain securing its children through one shared proof-of-work. The single root chain is the **Nexus**; every other chain is a descendant beneath it. See [Fractal structure](design/fractal-structure.md) for the core philosophy.

> **Light by design.** A node runs to a configurable resource budget — default **0.25 GB RAM / 1 GB disk** — and in `--stateless` mode holds *no* local chain data, both validating and mining by fetching from peers on demand. The Nexus stays deliberately small (1-hour blocks, 1 MB) so anyone can run and mine it; throughput is opt-in via [child chains](design/fractal-structure.md) that set their own faster/larger `ChainSpec` and inherit Nexus security through merged mining. See [Getting started](getting-started.md#run-a-node).

Start here, then follow the path that matches what you're doing.

## By goal

| I want to… | Read |
|---|---|
| Understand what Lattice is and why it exists | [Whitepaper](whitepaper.md) · [README](../README.md) |
| Run a node for the first time | [Getting started](getting-started.md) |
| Call the HTTP API | [RPC API reference](rpc-api.md) |
| Operate a node in production | [Operations runbook](operations.md) · [Deployment](../README.md#deployment) |
| Deploy or manage child chains | [Deploy & Announce a Child Chain](getting-started.md#deploy--announce-a-child-chain) |
| Understand the protocol in depth | [Protocol specification](protocol.md) |
| Understand the node's internals | [Architecture](architecture.md) |
| Understand the core design philosophy | [Fractal structure](design/fractal-structure.md) |
| Understand chain paths and directories | [Chain addressing model](design/chain-addressing.md) |
| Understand the process tree & what a chain trusts | [Process trust model](design/process-trust-model.md) |
| Understand mining roles and worker boundaries | [Mining role boundaries](design/mining-role-boundaries.md) |
| Understand merged-mining incentives & centralization | [Merged-mining incentive & centralization analysis](analysis/merged-mining-incentives.md) |
| Build, test, or reproduce CI locally | [Development](development.md) |
| Understand upgrades & forks | [Protocol versioning](protocol-versioning.md) |
| Write or run tests | [Testing plan](testing.md) · [Smoke tests](../SmokeTests/README.md) |

## Canonical references

- **[protocol.md](protocol.md)** — the single source of truth for protocol behavior: data structures, consensus, networking, state model, and the RPC surface at the protocol level.
- **[architecture.md](architecture.md)** — how the node is built: actors, the storage broker cascade, and the per-process chain topology.
- **[rpc-api.md](rpc-api.md)** — the HTTP API, endpoint by endpoint. The single source of truth for the API.
- **[operations.md](operations.md)** — monitoring, recovery, security, and environment variables for running a node.
- **[whitepaper.md](whitepaper.md)** — the vision and design rationale.

## Design records & history

Background on *why* things are shaped the way they are — design notes, not API or operational references.

- [design/fractal-structure.md](design/fractal-structure.md) — the organizing-protocol philosophy: Lattice secures heterogeneous chains via PoW; only the organizing relationship is fractal.
- [design/chain-addressing.md](design/chain-addressing.md) — the chain path / directory mental model.
- [design/process-trust-model.md](design/process-trust-model.md) — the spawn tree: process-per-chain topology, single-root Nexus, and the spawn chain of trust (authority is verified, never assumed; content is still verified, never trusted).
- [design/mining-role-boundaries.md](design/mining-role-boundaries.md) — the E15 node/coordinator/worker mining contract.
- [design/consensus-fork-choice.md](design/consensus-fork-choice.md) — node-side realization of the consensus model (single-`trueCumWork` fork choice, acceptance chokepoint, inherited-weight wiring, proof-carrying sync). The consensus model itself is defined in the Lattice library — `spec.md §9` + its `consensus-fork-choice.md`.
- [design/content-addressed-ingress.md](design/content-addressed-ingress.md) — the ingress invariant for externally supplied content-addressed data.
- [design/block-content-storage.md](design/block-content-storage.md) — the gossiped-block resolution and storage invariant.
- [design/storage-layer-state-retention.md](design/storage-layer-state-retention.md) — storage-layer retained roots for state retention, with load-bearing requirements and adversarial review record.
- [analysis/merged-mining-incentives.md](analysis/merged-mining-incentives.md) — merged-mining incentive & centralization analysis on the corrected per-chain-independent / opt-in model; records the human-gated economic decisions that remain open.
