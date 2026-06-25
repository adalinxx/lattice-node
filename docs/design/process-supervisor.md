# Process Supervisor — spawning the chain tree

Realizes the spawn-tree topology of [process-trust-model.md](process-trust-model.md):
the process tree mirrors the chain tree, and a parent process **spawns and
supervises** its children.

**Scope decision (locked):** **process per chain** only — one OS process per
chain, for crash isolation and independent restart. The process-per-subtree
option is not built.

## What moves into the node

Today the node is purely a *deployer*: `POST /api/chain/deploy` builds the child
genesis and returns `genesisHex` + the parent P2P address, and an **external
orchestrator** (the SmokeTests JS harness, in practice) computes ports, spawns
`lattice-node node --genesis-hex … --chain-directory … --subscribe-p2p …`, and calls
`register-rpc`. There is no process management in the node; cleanup is a global
`pkill`.

The supervisor moves that orchestration into the parent node:

- **Spawn on deploy.** After a child genesis is built, the parent spawns a
  supervised `lattice-node` child process with no manual port/genesis/peer
  wiring — all of it is derived (deterministic ports) or already in hand
  (`genesisHex`, the parent's own P2P address).
- **Supervise.** Track each child process; on unexpected exit, restart it per
  policy (bounded retries + backoff).
- **Quiesce the subtree.** When the parent stops, it signals its children; each
  child's existing SIGTERM path runs `node.stop()`, which quiesces *its* children
  in turn — so stopping the root stops the whole tree, recursively. The smoke
  harness no longer needs a global `pkill`.

## The supervisor

`ChildProcessSupervisor` (actor), one per `LatticeNode`, owns the child
processes this node has spawned:

```
spawn(SupervisedLaunch)   // launch + track + install restart-on-exit
quiesce()                 // SIGTERM all children, wait, SIGKILL stragglers; stop restarting
supervisedLabels() -> [String]  // introspection (tests / RPC status)
```

The supervisor is generic over `SupervisedLaunch`; a `ChildSpec` produces one via
`spec.launch(nodeExecutable:)`.

`ChildSpec` carries exactly what a child boot needs, all derived by the parent:

| field | source |
|---|---|
| `directory`, `chainPath` | the deploy request |
| `genesisHex` | the genesis the parent just built |
| `subscribeP2P` | the parent's own chain P2P address (`<pubkey>@host:port`) |
| `bootstrapPeer` | parent chain gossip endpoint (`chainP2PAddress`) |
| `port` | `deterministicPort(basePort, directory)` (existing FNV-1a scheme) |
| `rpcPort` | `deterministicRPCPort(baseRPCPort, directory)` (same scheme, RPC base) |
| `dataDir` | `<parentDataDir>/children/<directory>` |

The spawned argument vector mirrors what the JS harness builds today
(`lib/lattice.mjs spawnChild`) — it leads with the explicit `node` subcommand and
carries the same genesis/subscription/port flags, so a supervised child is
boot-compatible with a manually-launched one. (The harness's per-child
`--coinbase-address` and identity pre-seed are wired in step 1b, where the smoke
topology actually exercises mining; they are not needed for the default-off
mechanism here.)

```
<self> node --genesis-hex <hex> --chain-directory <dir> --chain-path <a/b/c>
       --subscribe-p2p <parentP2P> --port <port> --rpc-port <rpcPort>
       --data-dir <dataDir> [--peer <bootstrapPeer>]
       [inherited: --min-peer-key-bits, --min-fee-rate, --no-dns-seeds]
       [step 1b: --coinbase-address]
```

`<self>` is this process's own executable (`CommandLine.arguments[0]` resolved),
so the whole tree runs one binary.

### Lifecycle / restart

`Process.terminationHandler` detects exit. An **unexpected** (non-zero) exit with
restarts remaining re-spawns after a bounded backoff (floored so an
instantly-exiting child can never become a spawn loop); a **clean** exit (status
0) is intentional and is not restarted. The child re-attaches to the parent over
`--subscribe-p2p` exactly as a fresh boot does; persisted identity in `dataDir`
avoids a key re-grind. Each launch carries a monotonic *generation* id so a stale
terminationHandler from a replaced/stopped process can never act on the current
one. Re-spawning the same label stops the prior process first, so a re-deploy
never orphans a live child or double-binds its ports. Exhausting the restart
budget surfaces a logged failure; the parent itself stays up.

This handles the child-death case; the parent-death case (child
re-attach after the *parent* restarts) already works via `--subscribe-p2p`
reconnect and is exercised by the `parent-restart-reconnect` scenario.

### Reconcile on restart (deployed-child lifecycle)

Deployed children are persisted metadata, not just live processes. On startup a
supervising parent **reconciles** every non-detached deployed child rather than
blindly respawning, because a parent that crashed/was `SIGKILL`ed cannot have
quiesced its children — one may still be alive holding its deterministic ports.
Each child is brought to one of:

- **DEPLOYED** — staged genesis recorded.
- **RUNNING** — process alive (probe answers HTTP on its RPC port).
- **REGISTERED** — RUNNING and an authenticated `GET /api/chain/auth-check` against
  it returns 200, so the parent has re-registered its live RPC endpoint + cookie
  for mined-block delivery.
- **DETACHED** — the operator ran `unregister-rpc`; persisted as `detached`. Never
  auto-respawned. Re-deploying the same chain path clears the flag (reattach).

The reconcile probe distinguishes three cases against the persisted endpoint:

| Probe result | Meaning | Action |
|---|---|---|
| 200 | alive, token valid | **adopt** — re-register, no spawn |
| HTTP but 401/other | alive, cookie rotated | re-read on-disk cookie, re-probe; adopt if it authenticates, else log + skip (never spawn into the occupied port) |
| connection refused / timeout | dead, port free | **recover** — delete stale cookie, spawn, register only after the fresh process authenticates |

The stale cookie is deleted **before** every recover-spawn so the registration
loop cannot read a pre-restart token; registration always follows a successful
authenticated probe (never mere cookie-file presence). This is the single source
of truth used by fresh deploy, idempotent re-deploy, and startup reconcile.

### Quiesce ordering

`LatticeNode.stop()` calls `supervisor.quiesce()` **before** it tears down its own
networks, so children are signalled while the parent can still serve their final
needs. `quiesce()` sends SIGTERM, waits a grace period, then SIGKILLs any
straggler, and applies recursively down the tree.

**Limitation (graceful path only).** Quiesce runs on the graceful `stop()` path.
A parent that is `SIGKILL`ed or crashes cannot run it, so its descendants are
orphaned (re-parented to init, still holding ports). This is *not* yet full
`pkill` parity — the smoke harness's global `pkill` reaps orphans unconditionally.
A parent-death watchdog (Linux `PR_SET_PDEATHSIG`; a persisted-PID reaper on
restart for macOS) is required before the harness can drop its `pkill` entirely.
Until then, the supervised tree cleans up correctly on graceful shutdown only.

The supervisor is gated behind `--supervise-children` (**default off**): with it
off there is zero behavior change, existing smoke (harness-spawned children) is
untouched, and there is no double-spawn.

## References

- [process-trust-model.md](process-trust-model.md) — the spawn tree and chain of trust.
- [architecture.md](../architecture.md#per-process-topology) — deploy → spawn → extract → register.
