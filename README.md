# LatticeNode

A full node for **Lattice** — a protocol where every chain is both a *root chain* (its own blocks, state, and operations) and a *tree of chains* (the subtree rooted at it), and each chain secures its children through one shared proof-of-work. The single root chain is the **Nexus**; every other chain is a descendant, addressed by route, e.g. `Nexus/Payments`.

## Anyone can run — and mine — the Nexus

The base layer is deliberately small so that running it stays within reach of commodity hardware. That accessibility *is* the decentralization story: the more people who can afford to run and mine the root, the harder it is to censor or capture.

- **Tiny, configurable footprint.** A node runs to an explicit resource budget — **default 0.25 GB RAM / 1 GB disk** (e.g. `lattice-node --memory 0.5 --disk 20`, or `--autosize` to fit the host). Local storage is bounded and evicting; data is refetched from peers on demand.
- **Stateless mode holds *no* local chain data.** With `--stateless` the disk CAS budget is `0`: the node keeps nothing locally and **both validates and mines by fetching what it needs from peers on demand**. The minimum-footprint node is still a first-class participant.
- **No mining hardware.** Mining is external — the node serves block templates and an external worker searches nonces. Validating a chain needs no GPUs or ASICs.
- **You only carry the chains you join.** A Nexus-only node never stores child-chain data; child-block validation is the responsibility of nodes that opt into those chains.

**Scale is opt-in, not imposed.** The Nexus stays intentionally lightweight (1-hour blocks, 1 MB) so it remains universally runnable and maximally decentralized. When an application needs throughput, it spawns a **child chain** with its own `ChainSpec` — faster blocks, larger limits — and *only the participants in that child bear its cost*, while it still inherits the full Nexus hash rate through merged mining. Decentralized base, high-throughput edges.

## Why Lattice exists

Most blockchains force a choice: one chain with high security and congestion, or many chains with fragmented hash power and weak guarantees. Lattice eliminates this tradeoff because every chain is *also* a tree of chains that share one proof-of-work. The single root chain is the **Nexus**; any chain can spawn a child chain, and those children can spawn their own. Every chain defines its own operations yet inherits the proof-of-work of its ancestors through merged mining — one hash search, performed once, secures the whole subtree.

This means new chains are cheap to create, require zero additional mining infrastructure, and are secured from block one by the full weight of the Nexus hash rate.

## Design decisions

### Merged mining over sharding

Sharded architectures split validators across partitions, weakening each shard's security proportionally. Lattice takes the opposite approach: every miner searches a single nonce space, and any valid proof is applied to every chain whose target it satisfies. A block that doesn't meet Nexus's target may still satisfy a child chain's higher (easier) target, so no work is wasted. The security of every chain is bounded by the total network hash rate, not a fraction of it.

### Dynamic child chain discovery

Child chains are not hardcoded. A child chain is created by a `GenesisAction` embedded in a parent block, so chain creation is a protocol-level primitive rather than a governance event. Each child chain is assigned a deterministic P2P port from its full chain path, so any node can derive a child's port without coordination while allowing the same directory label to appear under different parents.

A node that already runs a chain in-process detects a newly created child as soon as it accepts the block carrying the `GenesisAction` and registers the child network without a restart. In the production topology, child chains run as separate processes instead — see [Per-process chains](#per-process-chains).

### Content-addressed storage throughout

Blocks and transactions are stored and referenced by their content hash (CID), not by location. This makes the storage layer naturally deduplicating and verifiable: if you have a CID, you can fetch the data from any peer and prove it's correct without trusting the source.

Storage uses a single shared DiskBroker (SQLite) for all chains, with per-chain MemoryBroker (LRU) caches cascading to it. Pins are ref-counted with owner tags, and retention is governed by two orthogonal axes:

- **BlockRetention** (tip / retention / historical) -- controls when block data is unpinned as the chain advances.
- **StorageMode** (stateless / stateful / historical) -- controls when replaced state roots are unpinned via StateDiff.

Block gossip sends block data inline via topic messages, so peers accept blocks without a round-trip fetch.

### Actor-based concurrency

The node is built on Swift's structured concurrency model. `LatticeNode` and `ChainNetwork` are actors with isolated state. There are no locks, no shared mutable memory, and no thread pools to tune. Within a process, each chain gets its own `ChainNetwork` actor and storage pipeline; in the per-process topology each chain is a separate OS process as well, so chains can be scaled, restarted, and resource-limited independently and cannot block one another.

### Per-process chains

Each chain in the tree runs as its own operating-system process. Nexus runs in the root process and exposes a small control plane over RPC; every child chain is launched as a separate `LatticeNode` process bootstrapped from its parent's genesis (`--genesis-hex --chain-directory --subscribe-p2p`). The lifecycle is:

1. **Deploy.** A client calls `POST /api/chain/deploy` on the parent. The parent builds the child's genesis block and returns `genesisHex` (the serialized genesis block + spec + genesis transactions) and `chainP2PAddress` (the parent P2P endpoint the child subscribes to for proof-carrying parent blocks). The parent advertises child genesis availability, but it does not host a child-chain fork-choice view.
2. **Spawn.** An external orchestrator (SDK, operator script, scheduler) starts a new process: `lattice-node --genesis-hex <hex> --chain-directory <name> --subscribe-p2p <parentP2P> …`. The child boots from the embedded genesis instead of building one, and never needs the DHT to find its genesis.
3. **Subscribe.** The child opens a dedicated Ivy connection to its parent's P2P port. A `ParentChainBlockExtractor` receives each parent block, extracts this child's embedded block from `parent.children[directory]` via a sparse content-addressed proof, verifies it against the parent's proof-of-work root hash and parent-state continuity evidence, applies it, and relays it to the child's own gossip network. Here `directory` is the edge label relative to the parent, not the child's global identity.
4. **Register.** The child calls `POST /api/chain/register-rpc` so the parent can advertise the child's RPC endpoint; `GET /api/chain/map` then resolves any chain path to a direct RPC URL.

This gives each chain independent crash, restart, resource, and scaling boundaries while preserving merged mining: verified parent-carrier proofs make the proof-of-work that secures a parent block available to the child blocks embedded within it. The parent is an availability source and proof carrier, not a child-chain fork-choice authority. A parent reorg does not by itself roll back child state; the child reorganizes only according to its own valid blocks and verified proof contributions. The orchestrator is external — the parent serves the control-plane endpoints but does not itself spawn processes. The legacy in-process path (one process hosting a tree of `ChainLevel` children) still exists and is used in tests and single-binary setups.

### Reputation-aware networking

Peers are not treated equally. The Ivy P2P layer tracks trust lines, and Tally scores peer behavior over time. Misbehaving peers — those sending invalid blocks, flooding announcements, or failing to serve data — are rate-limited and eventually disconnected. This makes the network protocol itself resistant to eclipse attacks and resource exhaustion without requiring proof-of-stake or bonding.

### Cross-chain replay protection

Every transaction includes a `chainPath` — a list of directory names from the nexus root to the target chain (e.g., `["Nexus"]` or `["Nexus", "Payments"]`). The chain path is included in the signed `lattice-tx-v1` transaction envelope. The node rejects any transaction whose `chainPath` does not match the validating chain's position in the hierarchy. This prevents a transaction valid on one chain from being replayed on another.

### Sequential nonce enforcement

Transactions carry a `nonce` field. Transactions from the same signer account must use sequential nonces starting from 0, with no gaps. The consensus layer tracks the latest confirmed nonce per signer in the transaction state merkle tree. The mempool applies a softer check, allowing a bounded window of future nonces to support concurrent submission.

### Resource-aware by default

The node autosizes to its host. On startup, it inspects available RAM and disk, then allocates 25% of memory and 50% of free disk across all subscribed chains. Operators on constrained hardware don't need to calculate buffer sizes — the node adapts. Explicit resource presets (`light`, `default`, `heavy`) and per-resource flags are available when fine-grained control is needed.

## Quick start

```bash
swift build -c release

# Run a node (serves block templates; never mines in-process)
swift run LatticeNode --rpc-port 8080

# Mine against it. Bundled LatticeMiner is a CPU worker; for GPU use
# lattice-miner-gpu (auto-detects CUDA / Metal / OpenCL).
swift build
swift run LatticeMiningCoordinatorTool \
  --node http://127.0.0.1:8080/api \
  --rpc-cookie-file ~/.lattice/.cookie \
  --worker-executable .build/debug/LatticeMiner \
  --workers 2

# Join an existing network
swift run LatticeNode --port 4002 --peer <pubkey>@192.168.1.10:4001
```

## Documentation

Full docs live in [`docs/`](docs/index.md). Quick links:

- [Getting started](docs/getting-started.md) — install and first run
- [Protocol specification](docs/protocol.md) — the canonical spec
- [Architecture](docs/architecture.md) — node internals and the per-process topology
- [RPC API reference](docs/rpc-api.md) — the HTTP API
- [Operations](docs/operations.md) and [Deployment](deploy/README.md) — running in production
- [Development](docs/development.md) — building, testing, and reproducing the Linux CI build
- [Whitepaper](docs/whitepaper.md) — vision and design rationale

## How it works

LatticeNode boots from a hardcoded Nexus genesis block and connects to the network via Ivy P2P. From there:

1. **Block production.** The node does not run a nonce-search loop. It owns chain state, transaction selection, block template construction, effective target calculation, child-chain candidate embedding, solution validation, block acceptance, persistence, and block gossip. The E15 mining split adds a `MiningCoordinator` for stale-work handling, non-overlapping nonce-range allocation, worker fan-out, and result submission. `LatticeMiner` workers only search immutable assigned work and return nonce/hash results; they do not know child topology, generate child proofs, hold coinbase private keys, seal blocks, or publish to Ivy. See [Mining role boundaries](docs/design/mining-role-boundaries.md).

2. **Block validation.** Incoming blocks are checked for valid proof-of-work (with 0x00 field-separated hash inputs), timestamp bounds (within 2 hours of median-time-past), size limits (1 MB), Ed25519 signature authenticity, sequential nonce ordering per signer, and chain path correctness. Peer reputation gates how many blocks are accepted per time window.

3. **Chain reorganization.** When a heavier-`trueCumWork` valid chain is observed — fork choice is Hierarchical GHOST (a block's descendant-subtree work plus the merged-mining weight it inherits from its parent chain), not simply the longest chain — orphaned blocks are detected and their fee-paying transactions are recovered to the mempool. Coinbase transactions are discarded since they're only valid in their original block context. There is **no protocol-level finality** — the consensus rule permits any-depth reorgs (defined in the Lattice library, `spec.md §9`). The node may additionally enforce **configurable local guards** — `--finality-confirmations` (a confirmation depth below which it refuses to reorg) and `maxReorgDepth` — which reject deep reorgs as node-local policy, not a consensus rule.

4. **Synchronization.** When a peer is more than a few blocks ahead (the catch-up threshold is 3; smaller gaps are absorbed by normal gossip), the node triggers headers-first sync: download and PoW-verify the header chain, prefetch state in parallel, then finalize through the durable StateStore commit path. While a chain is syncing, `/api/chain/template` returns 503 so external miners don't build on a stale tip.

5. **Persistence.** Nexus chain state is serialized to `<data-dir>/Nexus/chain_state.json`; non-root chains use path-aware namespaces such as `<data-dir>/chains/Nexus/Payments/chain_state.json` every 100 blocks and on graceful shutdown. The SQLite state store (`state.db`) is updated on every block and is crash-safe via WAL. A shared DiskBroker (SQLite, Volume-granular) stores all block and state data across chains with ref-counted pins. Each pin carries an owner tag (e.g., `chain:height`) so that BlockRetention and StorageMode policies can unpin data independently as the chain advances. On restart, the node walks both canonical path-aware namespaces and legacy single-level child directories, then restores all chains — including children discovered in prior sessions. If the node crashed, recovery detects any gap between the stale `chain_state.json` and the authoritative SQLite tip, then replays the missing blocks from the DiskBroker to bring the chain state current.

6. **Peer sync on connect.** When a new peer connects, the node announces its chain tip for each subscribed chain. If the peer is behind, this triggers synchronization without waiting for the next mined block.

## Architecture

In the production per-process topology, Nexus runs in the root process and each child chain runs in its own process:

```
Root process (Nexus)
  └─ LatticeNode (actor — node authority)
       ├─ Lattice (actor — chain hierarchy; in-process children only)
       │    └─ ChainLevel: Nexus
       ├─ ChainNetwork (actor — Nexus)
       │    ├─ Ivy           — P2P gossip and DHT routing
       │    ├─ MemoryBroker  — per-chain LRU cache → shared DiskBroker → IvyFetcher (network)
       │    ├─ Mempool       — pending transactions
       │    └─ Tally         — peer reputation scoring
       ├─ BlockProducer (assembles node-owned work/templates; no nonce loop)
       └─ RPC: POST /api/chain/template · POST /api/chain/deploy · GET /api/chain/map

Child process (e.g. Payments) — launched with --genesis-hex --chain-directory --subscribe-p2p
  └─ LatticeNode (actor — node authority)
       ├─ ChainNetwork (actor — Payments)        — this chain's own gossip
       ├─ ParentChainBlockExtractor (actor)      — dedicated Ivy link to the parent;
       │                                            extracts this chain's block from each
       │                                            parent block via a sparse proof
       └─ RPC                                     — serves clients; can deploy grandchildren

External mining roles (separate processes, any host):
  MiningCoordinator  — work lifecycle, stale detection, range fan-out, result submit
  MiningCoordinator  — fetches work, allocates ranges, submits nonce results
  LatticeMiner       — nonce-search worker over immutable assigned work only
```

The legacy single-process model — one `LatticeNode` hosting a nested tree of `ChainLevel` children under Nexus — remains only for tests and compatibility harnesses. Production deployments use one process per chain.

## RPC API

The node exposes a JSON API over HTTP (default port 8080) for programmatic access.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chain/info` | GET | Chain height, tip hash, target, genesis hash/timestamp |
| `/api/chain/spec` | GET | Genesis parameters |
| `/api/chain/map` | GET | Chain path → RPC endpoint for per-process children |
| `/api/chain/deploy` | POST | Create a child chain; returns `genesisHex` + `chainP2PAddress` (privileged) |
| `/api/chain/register-rpc` | POST | A child process registers its RPC endpoint with the parent |
| `/api/block/latest` | GET | Most recent block |
| `/api/block/{index\|hash}` | GET | Block by height or hash |
| `/api/balance/{address}` | GET | Account balance |
| `/api/nonce/{address}` | GET | Account nonce |
| `/api/proof/{address}` | GET | Sparse Merkle proof for light clients |
| `/api/transaction` | POST | Submit a signed transaction |
| `/api/mempool` | GET | Pending transaction pool |
| `/api/deposits` | GET | Active cross-chain deposits |
| `/api/deposit` | GET | Look up a single deposit by demander/amount/nonce |
| `/api/receipt-state` | GET | Look up a withdrawal receipt on the parent chain |
| `/api/peers` | GET | Connected peer count |
| `/health`, `/metrics` | GET | Health check and Prometheus metrics |

The node does not run an in-process nonce-search loop. Under the E15 target
contract, block sealing, validation, persistence, and gossip stay node-owned;
external mining code coordinates work and performs nonce search only. The
current coordinator CLI follows that boundary. See
[Mining role boundaries](docs/design/mining-role-boundaries.md). `/api/chain/deploy`
is privileged: it requires the generated RPC cookie bearer credential.

## CLI reference

### Startup flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port <N>` | 4001 | P2P listen port |
| `--rpc-port <N>` | — | HTTP API port (RPC server enabled only when set) |
| `--data-dir <path>` | `~/.lattice` | Storage directory |
| `--peer <pubKey@host:port>` | — | Bootstrap peer (repeatable) |
| `--autosize` | off | Auto-allocate memory and disk based on host capacity |
| `--memory <GB>` | 0.25 | In-memory CAS/cache budget |
| `--disk <GB>` | 1.0 | On-disk CAS budget |
| `--local-discovery` | off | Enable mDNS local peer discovery |
| `--stateless` | off | Force the disk CAS budget to `0` (holds no local CAS) |
| `--genesis-hex <hex>` | — | Genesis bytes for a per-process child, from the parent's deploy response |
| `--chain-directory <name>` | — | Which chain this process owns (per-process child) |
| `--subscribe-p2p <pubKey@host:port>` | — | Parent P2P address to subscribe to for block extraction (per-process child) |

### Interactive commands

| Command | Description |
|---------|-------------|
| `mine` | Prints a notice (the node does not mine in-process; run the external miner) |
| `status` | Chain heights, tips, mempool depth |
| `chains` | List registered networks and known child chains |
| `peers` | Connected peer count |
| `quit` / `exit` | Persist state and shut down |

## Deployment

### Docker

```bash
docker build -t lattice-node .
docker run -d --name lattice-miner \
  -p 4001:4001 -p 8080:8080 \
  -v lattice-data:/home/lattice/.lattice \
  lattice-node
```

The image uses a multi-stage build: Swift 6 compiles a static binary, which runs in a minimal Ubuntu 22.04 runtime. A built-in health check monitors `<data-dir>/health` for block recency.

### Bare metal (Linux)

```bash
# Install Swift 6: https://swift.org/install
git clone https://github.com/adalinxx/lattice-node.git
cd lattice-node
swift build -c release
sudo cp .build/release/LatticeNode /usr/local/bin/lattice-node

sudo useradd -r -s /bin/false lattice
sudo mkdir -p /var/lib/lattice
sudo chown lattice:lattice /var/lib/lattice
```

Run the binary under your preferred process supervisor (e.g. a systemd unit) with a dedicated data directory.

### Bootstrapping a network

Start the first node and note its public key (printed at boot). Connect additional nodes by passing `--peer`:

```bash
# Node 1 (genesis node)
lattice-node --rpc-port 8080

# Node 2
lattice-node --peer <node1-pubkey>@<node1-ip>:4001

# Node 3
lattice-node \
  --peer <node1-pubkey>@<node1-ip>:4001 \
  --peer <node2-pubkey>@<node2-ip>:4001
```

Nodes don't run nonce-search loops. During the E15 migration, run the current
external miner against whichever node(s) should produce blocks:

```bash
lattice-mining-coordinator --node http://<node1-ip>:8080/api --rpc-cookie-file <node-data-dir>/.cookie
```

Nodes discover additional peers through the DHT after initial bootstrap.

## Nexus genesis parameters

| Parameter | Value |
|-----------|-------|
| Block time target | 1 hour (3,600,000 ms) |
| Max transactions per block | 5,000 |
| Max block size | 1 MB |
| Initial block reward | 2^20 (1,048,576) |
| Halving interval | 876,600 blocks (~100 years at 1-hour blocks) |
| Premine | 175,320 blocks of reward (~10% of total supply) |
| Retarget window | 120 blocks |
| State growth limit | 3 MB per block |

## Dependencies

All from [adalinxx](https://github.com/adalinxx):

| Library | Role |
|---------|------|
| **Lattice** | Core blockchain protocol — chain state, block validation, consensus rules, Ed25519 signatures |
| **Ivy** | Trust-line DHT for peer discovery, gossip, and authenticated routing |
| **VolumeBroker** | Content-addressed storage: DiskBroker (SQLite), MemoryBroker (LRU), ref-counted pins |
| **Tally** | Peer reputation scoring and rate limiting |
| **cashew** | Merkle tree and sparse Merkle proof construction (with BrokerStorer/BrokerFetcher integration) |

Additional: [Hummingbird](https://github.com/hummingbird-project/hummingbird) for the HTTP transport layer.
