# Lattice Node Operations Runbook

## Health Monitoring

### Endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Liveness check: status, height, peers, syncing, uptime |
| `GET /metrics` | Prometheus-format metrics for Grafana/alerting |
| `GET /api/chain/info` | Full chain state: all chains, heights, tips |

For the full HTTP API (request/response shapes for every endpoint), see [`./rpc-api.md`](./rpc-api.md) — the single source of truth for the RPC API.

### Key Metrics (Prometheus)

| Metric | Type | Alert When |
|--------|------|------------|
| `lattice_chain_height{chain="..."}` | gauge | Stale > 5 min |
| `lattice_peer_count` | gauge | < 1 (isolated) |
| `lattice_sync_active` | gauge | = 1 for > 10 min |
| `lattice_mempool_size{chain="..."}` | gauge | > 10000 (backlog) |
| `lattice_blocks_accepted_total` | counter | Rate = 0 for > 5 min |
| `lattice_chain_count` | gauge | Decreases unexpectedly |

### Health Check Status Values

- `ok` — at least 1 connected peer
- `degraded` — 0 peers (cannot receive or send blocks)
- `unhealthy` — one or more chains report an unhealthy state

## RPC Rate Limiting

Built-in token-bucket rate limiter: 50 req/s per IP, burst of 100.
Uses `X-Forwarded-For` or `X-Real-IP` headers behind a reverse proxy.
Returns HTTP 429 with `Retry-After: 1` when exceeded. Applies to all RPC endpoints documented in [`./rpc-api.md`](./rpc-api.md).

## Common Operations

### Start a Node

```bash
LatticeNode node \
  --port 4001 \
  --rpc-port 8080 \
  --data-dir /data/lattice \
  --peer pubkey@host:port
```

**Resource budget.** A node runs to a bounded footprint: `--memory <GB>` (default
`0.25`) and `--disk <GB>` (default `1.0`), or `--autosize` (capped by
`--max-memory` / `--max-disk`). On-disk CAS is bounded and evicting — data over
budget is dropped and refetched from peers on demand. For the lightest possible
operator, `--stateless` forces the disk CAS budget to `0`: the node holds no local
chain data and **validates and mines by fetching from peers on demand**. Mining is
external (see [Local Mining Coordinator Gate](#local-mining-coordinator-gate)), so
no specialized hardware is required to run or mine the Nexus. Throughput-heavy
workloads belong on child chains with their own `ChainSpec`, not on the Nexus.

### Child Chains

In production, child chains run as **separate processes** that subscribe to their parent (Nexus) for blocks. Nexus stays the control plane (`/api/chain/deploy`, `/api/chain/register-rpc`); an orchestrator deploys the child's genesis on the parent, then spawns the child process from it:

```bash
LatticeNode node \
  --genesis-hex "$GENESIS_HEX" \    # genesisHex from POST /api/chain/deploy
  --chain-directory toy \           # the child's own directory
  --chain-path Nexus/toy \          # the child's FULL ancestral path — see note
  --subscribe-p2p "$PARENT_P2P" \   # parent node's pubkey@host:port
  --port 4002 --rpc-port 8081 --data-dir ./toy-data
```

**Always pass `--chain-path` with the child's full ancestral path** (`Nexus/toy`, or `Nexus/toy/toytoy` for a grandchild). It is optional, but omitting it is a trap: the node then advertises only its leaf directory (`["toy"]`) — it still runs and mines, but it no longer knows it descends from Nexus, and `/health` cannot report its true lineage. Worse, **a leaf-only node can be addressed *only* by its leaf**: `tx --chain-path toy` works, but `tx --chain-path Nexus/toy` is rejected as `Unknown chain path`, because relative to a node that thinks its root is `toy`, the path `Nexus/toy` reads as a non-existent descendant `toy/Nexus/toy`. Passing the full path makes both the leaf (`toy`) and absolute (`Nexus/toy`) forms resolve, and lets the parent route to it.

> **Addressing a chain in `tx` / RPC.** `--chain-path` (and `?chainPath=`) is resolved **relative to the node's own chain path**: a path that shares the node's root is taken as absolute; a path that matches a trailing suffix of the node's path names the node's own chain; anything else is treated as a descendant and prepended. So on the **Nexus node**, address a child as `Nexus/<child>`; on a **child node given its full `--chain-path`**, the leaf resolves for *reads* (balance/nonce), but a **`tx` submit must use the full path** (`Nexus/toy`) — the transaction body's chain path is matched for exact equality against the node's. On a **leaf-only child node**, use the leaf directory.

The legacy in-process model — one process hosting the whole tree — is retained only for tests and compatibility harnesses (constructed programmatically, not via a CLI flag). Production deployments use per-process chains so parent processes never own child fork-choice views.

> **`--chain-path` is fixed at genesis — it cannot be changed later.** A chain is mined either as a root or as a parent-anchored child, decided by the `--chain-path` it is *first* spawned with. Spawn a child without `--chain-path` and its entire history is built as a root; re-spawning it later *with* a path makes its next block try to anchor to the parent's state, which the history never established, so consensus rejects it: `breaks parent state root continuity`. Always spawn children with their full `--chain-path` from the very first block.

### Cross-Chain Swaps

A chain and its **direct parent** can run a trustless atomic swap of their native coins — e.g. sell a child chain's coin for its parent chain's coin — via three actions exposed by `tx`:

| Leg | Signer | Chain | `tx` flag |
|-----|--------|-------|-----------|
| Lock coin in escrow at a price | seller (`demander`) | child | `--deposit amountDeposited:amountDemanded:swapNonce` |
| Pay the seller in parent coin | buyer (`withdrawer`) | parent | `--receipt sellerAddr:amountDemanded:swapNonce:childDirectory` |
| Claim the escrowed child coin | buyer (`withdrawer`) | child | `--withdraw amountWithdrawn:sellerAddr:amountDemanded:swapNonce` |

The `swapNonce` (a `UInt128`) ties the three legs together; the rate is free (`amountDeposited` need not equal `amountDemanded`). Atomicity is structural: the withdrawal validates only if **both** the deposit (child state) and the receipt (parent state) exist, so the buyer cannot take the child coin unless the parent-coin payment has settled. The seller is auto-credited the instant the receipt is mined — no separate claim is needed.

**Both chains must be parent-anchored** (spawned with `--chain-path` from genesis, per the note above). Deposits and withdrawals are rejected on a root chain (`not allowed on the nexus chain`); receipts are accepted on any chain, including the root, since a receipt is just an ordinary debit of the buyer in favor of the seller.

## Recovery Procedures

### Symptom: Node Won't Start (Corrupt State)

1. Stop the node
2. Back up the data directory: `cp -r /data/lattice /data/lattice.bak`
3. Delete the chain state file (preserves CAS data):
   ```bash
   rm /data/lattice/Nexus/chain_state.json
   rm /data/lattice/*/chain_state.json  # child chains
   ```
4. Restart — the node restores chain state from CAS by walking blocks backward from the SQLite tip

### Symptom: Node Stuck Syncing

1. Check `/health` — is `syncing: true`?
2. Check `/metrics` — is `lattice_sync_active` stuck at 1?
3. Check logs for `Sync failed` or `notFound` errors
4. If peers are connected but sync fails, the peer may have pruned the blocks. Try adding more peers.
5. If no peers: verify port is reachable, check `--peer` arguments

### Symptom: Chain Height Stalled

1. Confirm the external mining stack is running and pointed at this node. `MiningCoordinator` owns stale-work/range fan-out and result submission; `LatticeMiner` workers perform nonce search only. The node does **not** run a nonce-search loop itself.
2. Check peer count — block propagation needs at least 1 peer
3. Check mempool: if full (`lattice_mempool_size` at cap), transactions may be rejected
4. Check the template endpoint isn't returning 503 (returned while the node is still syncing), and check the `target` — an initial `target` that is too small (too hard) can stall progress
5. If a specific transaction must be included but blocks are slow (high `target`), it can **expire from the mempool before any block includes it** — a pending tx older than `MEMPOOL_TX_EXPIRY_SECONDS` (default 24h) is pruned. Raise that TTL on the mining nodes (the ones building templates), or re-submit the tx periodically, so it survives until inclusion.

### Local Mining Coordinator Gate

Build the mining stack (the coordinator and worker binaries):

```bash
swift build
```

Run a local node:

```bash
swift run LatticeNode --rpc-port 8080
```

Then run one coordinator batch that fans out to two `LatticeMiner` worker
processes:

```bash
.build/debug/LatticeMiningCoordinatorTool \
  --node http://127.0.0.1:8080/api \
  --worker-executable .build/debug/LatticeMiner \
  --rpc-cookie-file <node-data-dir>/.cookie \
  --workers 2 \
  --batch-size 128 \
  --once
```

The E15 end-to-end test gate is executable with:

```bash
swift test --filter MiningCoordinatorEndToEndTests
```

That test starts a local `LatticeNode` RPC server, runs the
`LatticeMiningCoordinatorTool` executable, fans work out to two `LatticeMiner`
worker processes, verifies stale-work cancellation and stale node rejection,
and checks the coordinator/worker sources stay free of gossip, child-proof, and
private-key responsibilities.

### GPU Mining

For real hashrate, replace the CPU `LatticeMiner` worker with
[`lattice-miner-gpu`](https://github.com/adalinxx/lattice-miner-gpu), which
implements the same worker protocol and auto-detects the backend: **Metal**
(Apple Silicon, default), **CUDA** (NVIDIA), or **OpenCL** (AMD/Intel). Point the
coordinator at it via `--worker-executable`:

```bash
LatticeMiningCoordinatorTool \
  --node http://127.0.0.1:8080/api \
  --rpc-cookie-file <data-dir>/.cookie \
  --worker-executable /path/to/lattice-miner-gpu \
  --workers 1 --batch-size 2000000000
```

One worker drives the whole GPU; a large `--batch-size` amortizes per-invocation
kernel setup. CUDA/OpenCL require the matching build feature; the stock build is
Metal + CPU.

**Self-starting deployment (cloud GPUs).** For hands-off rental GPUs, bake the
node, coordinator, and GPU worker into one container whose entrypoint starts the
node, waits for it to sync from the bootstrap seeds (`/api/chain/info` reports
`"syncing": false`), then launches the coordinator. The node discovers the network
via its baked-in seeds (no `--peer` needed); the image needs only a CUDA-runtime
base plus `libcurl4` and `libxml2` for the node. Booting the container then mines
with zero manual setup.

### Merge-Mining Child Chains

One mining stack can advance the parent **and** its children at once. The
coordinator fetches a *merged* template from the parent that embeds each child's
candidate block, searches the **single easiest target** across the whole subtree,
and the node grades every solution **per chain** — so a child block is accepted on
its own proof-of-work the moment a nonce clears *that child's* target, with no
requirement to also clear the (harder) parent target. **Each child advances at its
own difficulty.**

Two wiring steps beyond running the chains ([Child Chains](#child-chains)):

1. **Register each child's RPC with the parent**, so a child block the parent
   mines is delivered back to the process that owns that child:
   ```bash
   NEXUS_COOKIE=$(cat <nexus-data>/.cookie); TOY_COOKIE=$(cat <toy-data>/.cookie)
   curl -s -X POST http://127.0.0.1:8080/api/chain/register-rpc \
     -H "Authorization: Bearer $NEXUS_COOKIE" -H 'Content-Type: application/json' \
     -d "{\"chainPath\":[\"Nexus\",\"toy\"],\"endpoint\":\"http://127.0.0.1:8087/api\",\"authToken\":\"$TOY_COOKIE\"}"
   ```
   Without it the parent can mine a valid child block but has nowhere to deliver
   it.

2. **Run the coordinator with one `--child-node` per child**, each with that
   child's auth token (the parent fetches the child's candidate, an admin-gated
   call):
   ```bash
   LatticeMiningCoordinatorTool \
     --node http://127.0.0.1:8080/api --rpc-cookie-file <nexus-data>/.cookie \
     --child-node http://127.0.0.1:8087/api --child-rpc-token "$TOY_COOKIE" \
     --child-node http://127.0.0.1:8086/api --child-rpc-token "$(cat <etch-data>/.cookie)" \
     --workers 1 --batch-size 100000
   ```
   (`--child-rpc-cookie-file <path>` reads the token from a file, re-read each
   round, instead of a fixed `--child-rpc-token`.)

> **URL forms differ between the two CLIs.** The coordinator's `--node` /
> `--child-node` take the API base **with** `/api` (`http://host:8080/api`); the
> `tx` CLI's `--rpc` takes the bare host **without** `/api` — it appends the path
> itself. The wrong form surfaces as `node unreachable or unknown chain path`.

> **Provision hashrate for the child's `targetBlockTime`.** A child mined far
> faster than its target block time retargets *harder* each window; a burst of
> cheap blocks (e.g. an easy genesis target cleared by a fast worker) can outrun
> the retarget and push difficulty past what the available hardware can clear,
> stalling the child (see [Chain Height Stalled](#symptom-chain-height-stalled)).
> Size the worker to the child's intended block time from the first block.

**Coinbase ≠ premine.** Give every mining node a dedicated `--coinbase-address`
that is **not** the premine/treasury address. Block rewards credit the node's
`--coinbase-address`; point it at the premine and mining income pools into the
treasury, conflating spendable operating funds with the treasury irreversibly.
Generate an operating account up front and pass it to every node:
```bash
LatticeNode keys generate --output coinbase.json   # then --coinbase-address <its address>
```

### Full Wipe and Resync

Use when the node's state is unrecoverable:

```bash
# Stop the node
kill $(pgrep LatticeNode)

# Remove all data (chain state + CAS + SQLite)
rm -rf /data/lattice

# Restart with a bootstrap peer — the node will sync from genesis
LatticeNode node --data-dir /data/lattice --peer pubkey@host:port
```

The node creates a fresh genesis, syncs from the peer, and rebuilds all state.
For child chains in the production per-process model, re-spawn each child process per [`../deploy/README.md`](../deploy/README.md) ("Per-process child chains").

### Partial State Rebuild (Preserve CAS)

If SQLite is corrupted but the CAS (shared volume store) is intact:

```bash
# Back up
cp -r /data/lattice /data/lattice.bak

# Remove only the per-chain state stores (preserve the shared volumes.sqlite)
rm /data/lattice/*/state.db
rm /data/lattice/*/chain_state.json

# Restart — CAS recovery replays blocks from the volume store
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RETENTION_DEPTH` | 1000 | Blocks kept before pruning |
| `PIN_ANNOUNCE_EXPIRY` | 86400 | Pin announcement TTL (seconds) |
| `REANNOUNCE_INTERVAL` | 86400 | Reannounce pinned CIDs interval (seconds) |
| `EVICTION_INTERVAL` | 21600 | Expired pin eviction interval (seconds) |
| `MEMPOOL_TX_EXPIRY_SECONDS` | 86400 | Mempool transaction TTL (seconds); a pending tx is pruned once older than this. **Raise it on chains with long block times** (e.g. early-life or high-`target` chains) so transactions aren't evicted before they can be mined. |

## Security

- Keep the generated RPC `.cookie` private and pass it as a bearer credential for privileged endpoints.
- Rate limiting is always active (50 req/s per IP)
- Place behind a reverse proxy (nginx/caddy) for TLS
- P2P port (default 4001) should be open; RPC port should be firewalled to trusted IPs
