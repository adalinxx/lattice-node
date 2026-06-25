# Development

How to build, test, and reproduce CI locally.

## Build

```bash
swift build              # debug
swift build -c release   # release — what CI builds
```

Requires Swift 6.1+. CI builds with Swift 6.1; recent Xcode toolchains also work
for local macOS builds.

## Run

```bash
swift run LatticeNode --help
swift run LatticeNode --rpc-port 8080  # a node (does not mine in-process)

# Current legacy block-production path during E15 migration:
swift run LatticeMiningCoordinatorTool --node http://127.0.0.1:8080/api --rpc-cookie-file .lattice/.cookie
```

See [getting-started.md](getting-started.md) for first-run details and child chains,
and [Deployment](../README.md#deployment) for multi-node and cloud/NAT setups.
Mining code should follow the E15 [Mining role boundaries](design/mining-role-boundaries.md):
`LatticeNode` owns chain state, sealing, validation, persistence, and gossip;
`MiningCoordinator` owns work lifecycle and range fan-out; `LatticeMiner`
workers only search assigned nonces.

## Test

```bash
swift test               # unit + integration tests
```

- Test plan and coverage matrix: [testing.md](testing.md).
- End-to-end smoke tests (multi-node lifecycle): [../SmokeTests/README.md](../SmokeTests/README.md).

## Reproduce the Linux CI build locally (from macOS)

CI builds on Linux (`swift:6.1-jammy`), where several things differ from macOS —
`URLSession`/`URLRequest` live in `FoundationNetworking`, `SHA256` is non-`Sendable`,
and `stdout` is a flagged global. **A macOS build can be green while Linux is red**,
so verify on Linux before pushing.

A static Swift SDK can't build this repo (it needs system **libsqlite3**), so use
Docker with the same image CI uses.

### Quick one-off

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.1-jammy bash -lc '
  apt-get update -qq &&
  apt-get install -y --no-install-recommends libsqlite3-dev &&
  swift build -c release --build-path .build-linux'
```

- `--build-path .build-linux` keeps Linux artifacts out of your macOS `.build`.
- On Apple Silicon this builds native arm64-linux, which catches the same
  portability errors. Add `--platform linux/amd64` to match CI's exact x86_64
  target (slower, emulated).

### Faster, repeatable (cached image + build volume)

This repo ships [`Dockerfile.linux`](../Dockerfile.linux) (the thin CI-parity image)
and [`scripts/linux-build.sh`](../scripts/linux-build.sh) (a wrapper that caches the
Linux build in a named volume):

```bash
scripts/linux-build.sh         # swift build -c release  (the CI Build step)
scripts/linux-build.sh test    # build + swift test
scripts/linux-build.sh shell   # poke around inside the Linux image
```

No Docker Desktop? `brew install colima docker && colima start` provides a
Docker-compatible runtime without the GUI.

## Code layout

| Path | What |
|---|---|
| `Sources/LatticeNode` | The node — `Chain`, `Network`, `Mining`, `RPC`, `Storage`, `Sync`, `Mempool`, `Config`, `Daemon`. |
| `Sources/LatticeMiner` | Standalone proof-of-work worker target; nonce search only. |
| `Sources/LatticeMiningCoordinatorTool` | Node-facing coordinator CLI; fetches work, allocates local ranges, and submits nonce results. |
| `Sources/CSQLite` | SQLite C shim. |

Core protocol types (Block, Transaction, ChainState, consensus) live in the
upstream `Lattice`, `cashew`, `Ivy`, `VolumeBroker`, and `Tally` packages. See
[architecture.md](architecture.md).
