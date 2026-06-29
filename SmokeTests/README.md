# lattice-node smoke tests

End-to-end scenarios that spawn real `LatticeNode` binaries, hit real RPC, and
assert observable chain state. Each scenario is hermetic: it owns its
`SMOKE_ROOT`, allocates a non-overlapping port range, and tears down its own
processes on exit, SIGINT, or uncaughtException.

> **Local toolchain note (Swift 6.3.x).** The smoke binaries are subject to the
> same Swift 6.3 `-O` crash as any node build — build them unoptimized
> (`xcrun swift build`, or `xcrun swift build -c release -Xswiftc -Onone`). CI and
> tagged releases use Swift 6.1 and keep full `-O`. See
> [getting-started.md → From source](../docs/getting-started.md#from-source) for the
> full explanation and the `xcrun`/SDK-match caveat (single source of truth).

## Architecture

The harness only talks to the node via three surfaces — RPC, the CLI, and
on-disk artifacts under the data directory. There are no language-level
imports of node internals, so this directory is portable to any future node
implementation.

```
SmokeTests/
├── lib/                  # shared harness — node lifecycle, RPC, wallet, probes
├── scenarios/
│   ├── swap/             # cross-chain deposit→receipt→withdrawal cycles
│   ├── network/          # multi-node sync, late-join, partition, mesh convergence
│   ├── follower/         # subscription gate, stateless mode
│   ├── persistence/      # restart resilience
│   └── liveness/         # long-running RSS + height-progress
└── run.mjs               # orchestrator (sequential per-scenario, fresh tmp dir each)
```

Scenario files are self-contained and can be run individually.

## Running

```bash
swift build                    # produce .build/debug/LatticeNode
cd SmokeTests
npm install
npm run all                    # full ungated suite; long-running
SMOKE_FILTER=swap npm run all  # only matching scenarios
SMOKE_TAGS=safety-a npm run all # one CI tag group
SMOKE_FAIL_FAST=1 npm run all  # stop on first failure
SMOKE_FILTER=stability-multichain SMOKE_DURATION_MIN=5 npm run all
```

## Environment variables

| var | meaning |
|---|---|
| `LATTICE_NODE_BIN` | path to the binary (default: `../.build/debug/LatticeNode`) |
| `SMOKE_ROOT` | per-scenario tmp dir (set by `run.mjs`; defaults under `/tmp/` for standalone) |
| `SMOKE_PORT_BASE_START` | force a deterministic run-wide port base; by default `run.mjs` auto-selects a free range |
| `SMOKE_PORT_PROBE_WIDTH` | number of ports to preflight in each per-scenario slice (default 64) |
| `SMOKE_DISABLE_PORT_LOCK` | `1` to skip the `/tmp` suite lock that prevents overlapping full-suite runs |
| `SMOKE_FILTER` | regex; only matching scenarios run |
| `SMOKE_TAGS` | comma/space-separated tags; only matching scenario groups run |
| `SMOKE_FAIL_FAST` | `1` to stop on first failure |
| `SMOKE_DURATION_MIN` | duration for stability test (default 30) |
| `SMOKE_MINER_STALL_MS` | override the miner restart stall window; by default merged-mining scenarios use a longer window than flat-chain scenarios |

## Writing realistic multi-node / cross-chain scenarios

Two-node and deep (Nexus → child → grandchild) scenarios have non-obvious traps.
The rules below cost real debugging. Canonical examples:
`scenarios/follower/parent-dependency.mjs` (deep self-assembly),
`scenarios/network/multichain-late-joiner.mjs` (multi-child join),
`scenarios/swap/toytoy-compound-swap.mjs` (two-node compound grandchild swap).

### General rules (any multi-node / cross-chain scenario)

1. **Cross-node follow is a top-down cascade, not a call.** Boot the joiner with
   `['--peer', root.peerArg(), '--supervise-children']` (+
   `{ env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } }` to speed convergence) and let
   the subtree **self-assemble**. An explicitly `followChild`-ed node does **not**
   supervise its own children, so it will never auto-follow a *grandchild*. Use pure
   auto-follow all the way down and resolve each level's endpoint from its parent's
   `GET /api/chain/map` (walk `Nexus`, then `Nexus/child`, then `Nexus/child/grandchild`).

2. **Order is load-bearing: parent before child.** A child's registration lives in its
   **parent's** state, so the parent must sync before the child even appears in the
   parent's map. The cascade enforces this; assert the parent has caught up
   (`heightAt(parentEp) >= rootHeight - 2`) before resolving/awaiting a deeper level.

3. **Submit each tx to the node that actually hosts that chain.** A node hosts only its
   own chain and its **direct** children. The top-level joiner does not know
   `Nexus/child/grandchild` (that lives under the child follower) — submitting there
   fails with `Unknown chain path`. Resolve the hosting follower's endpoint from
   `chain/map` and point an RPC client at it.

4. **A follower must keep pace with live production — and don't fake it.** A node
   applies blocks at a finite rate (much slower in debug builds). If blocks are produced
   faster than the joiner applies, it *never catches up* and its child follower defers
   forever ("no same-chain connectivity / until synced"). **Don't freeze the chain to let
   a reader catch up** — a real node syncs a live tip. **Don't run two miners** —
   `node.mineUntil(...)` spawns its *own* `LatticeMiner`; with an explicit miner too you
   get a second, racing one. A real chain is paced by difficulty, but dev genesis is
   max-target so it mines as fast as the CPU; pace it with
   `new LatticeMiner(root, [..], { minBlockIntervalMs: 3000 })` (the *value* is a
   harness/debug-build remedy, not a protocol rule). Late-joiner *snapshot* tests may
   freeze once before the join; transactional flows must not.

5. **Genesis is content-addressed and must be byte-identical across nodes.** Followers
   resolve a child's genesis by CID from the on-chain registration; every `ChainSpec`
   field (`targetBlockTime`, premine, reward, …) is baked into that CID, so it must match
   exactly on every node or the follower computes a different CID and rejects the genesis.
   Whoever deploys owns those params — followers just fetch the bytes.

6. **Fund/sell from the identity that actually holds the coin.** Supply originates either
   from a **premine** (held by the premine recipient) or from **mining** (held by the
   miner's coinbase). Use that identity as the funded party; don't assume the root node's
   identity holds a child's coin.

### Choices specific to `toytoy-compound-swap` (NOT general rules)

- **`premine: 0`.** A real chain may have a premine — the only requirement is determinism
  (rule 5). This scenario uses `premine: 0` purely to keep funding to mining and sidestep
  a premine-construction determinism pitfall in the harness.
- **Per-chain coinbase is the seller.** This is a *consequence* of `premine: 0` (rule 6):
  with no premine, mining is the only supply, so each chain's coinbase (`aToy._keypair`,
  `aTt._keypair`) holds its coin. A premined chain would sell from the premine recipient.
