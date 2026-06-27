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
