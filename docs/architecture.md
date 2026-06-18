# Lattice Node Architecture

## Overview

Lattice is a protocol where a chain is both a root chain and the tree of chains rooted at it. Each chain defines its own operations, state, and economics, and secures its children through one shared proof-of-work (merged mining) — its core philosophy is [fractal structure](design/fractal-structure.md). The single root chain is the **Nexus**; every other chain is a descendant beneath it. In production the tree is spread across separate OS processes — see [Per-Process Topology](#per-process-topology).

```
┌─────────────────────────────────────────────────────┐
│  CLI (swift-argument-parser)                         │
│  node | devnet | cluster | keys | status | query     │
├─────────────────────────────────────────────────────┤
│  Daemon                                              │
│  Signal handling, background loops, lifecycle        │
├──────────┬──────────┬───────────┬───────────────────┤
│  Chain   │  Mempool │  Network  │  RPC              │
│  Blocks  │  NodeMem │  Ivy P2P  │  Hummingbird HTTP │
│  Sync    │  Validat │  Peers    │  Auth             │
│  State   │  Persist │  Diversity│  Prometheus       │
│  Persist │  RBF     │  Anchors  │  Receipts         │
├──────────┼──────────┼───────────┼───────────────────┤
│ Produce  │  Storage      │  Config   │  Health           │
│ Work     │  DiskBroker   │  NodeConf │  Logger           │
│ + Merged │  MemoryBroker │  Protocol │  Metrics          │
│ commits  │  SQLite/PBSS  │  Version  │                   │
├──────────┴───────────────┴───────────┴───────────────────┤
│  Lattice (external): Consensus, ChainState, Blocks,       │
│    Cross-chain Deposits / Withdrawals / Receipts          │
│  Ivy (external): P2P, DHT, Tally                         │
│  VolumeBroker (external): DiskBroker, MemoryBroker, Pins  │
│  cashew (external): Merkle trees, BrokerStorer/Fetcher    │
└───────────────────────────────────────────────────────────┘
```

## Per-Process Topology

In production, the chain tree spans operating-system processes rather than living inside one node. Nexus runs in the root process; each child chain runs as its own `LatticeNode` bootstrapped from its parent's genesis (`--genesis-hex --chain-directory --subscribe-p2p`).

Lattice addressing is path-based. `Nexus` is the root handle used by external clients to enter the tree. A child `directory` is the relative edge label from a parent chain to one of its children, not a globally unique chain identity. The canonical address of a chain is its full path from Nexus, such as `Nexus/Payments` or `Nexus/Games/Payments`. See [Chain Addressing Model](design/chain-addressing.md).

```
Root process (Nexus)
  LatticeNode
    ├─ Lattice / ChainLevel: Nexus
    ├─ ChainNetwork: Nexus
    │    └─ Ivy (Nexus gossip)
    ├─ BlockProducer (node work; no nonce loop)
    └─ RPC control plane:
         ├─ POST /api/chain/deploy
         ├─ POST /api/chain/register-rpc
         └─ GET  /api/chain/map

Child process (e.g. Mid, --genesis-hex --chain-directory --subscribe-p2p)
  LatticeNode
    ├─ ChainNetwork: Mid (own gossip)
    ├─ ParentChainBlockExtractor
    │    └─ dedicated Ivy link to parent P2P blocks
    ├─ BlockProducer (node work; no nonce loop)
    └─ RPC (serves clients; deploy grandchildren)
```

1. **Deploy** — `POST /api/chain/deploy` on the parent builds the child genesis and returns `genesisHex` (genesis block + spec + genesis transactions) and `chainP2PAddress` (the parent P2P endpoint the child subscribes to for proof-carrying parent blocks). The parent advertises child genesis availability, but it does not create a child `ChainState` or fork-choice view.
2. **Spawn** — an external orchestrator launches `lattice-node --genesis-hex <hex> --chain-directory <name> --subscribe-p2p <parentP2P>`. The child boots from the embedded genesis; no DHT lookup is needed.
3. **Extract** — the child's `ParentChainBlockExtractor` opens a dedicated Ivy link to the parent, receives parent-block gossip, extracts `parent.children[directory]` via a sparse content-addressed proof (`ChildBlockProof`), validates it against the parent's proof-of-work root hash and parent-state continuity evidence, applies it, and relays it to the child's own gossip.
4. **Register** — the child calls `POST /api/chain/register-rpc`; `GET /api/chain/map` then resolves any chain path to a direct RPC URL.

Each child's P2P port is `basePort + 1 + FNV1a(directory) mod 16384`, where `directory` is the child's edge label relative to its parent. Both sides can agree on the port without coordination. The deterministic port plus `genesisHex` mean a child can be launched on any host with no shared state beyond the parent's P2P address.

Legacy in-process child registration exists only as a compatibility/test harness. The production topology is per-process: each chain owns its own `ChainState`, P2P network, sync, and fork choice, while parents only provide proof-carrying blocks and genesis/bootstrap availability.

The process tree mirrors the chain tree, with Nexus as the single root. What a child process may trust about the parent that spawned it — lineage and authority are verified (spawn certificates), block content is never trusted (always cryptographically verified) — is the [process trust model](design/process-trust-model.md).

That boundary is deliberate. Parent blocks are proof carriers, not child-chain
views. A child may fetch parent bytes and state Volumes from its parent process,
but it accepts them only after content-address, PoW, inclusion, and state-root
verification. Parent canonicity therefore does not by itself roll back child
state or rewrite child fork choice; it only affects what the parent mines and
serves next. This keeps child chains independent, keeps parent processes from
being polluted by child state, and lets the same parent→child rule recurse to
grandchildren without any Nexus-specific authority path.

## Mining Role Split

The E15 mining contract keeps chain authority inside `LatticeNode` while moving
hash search out to narrow workers. `LatticeNode` owns template/work creation,
effective target calculation, merged-mining proof handling, solution validation,
block sealing, acceptance, persistence, and gossip. `MiningCoordinator` owns
stale-work detection, retry/backoff, nonce-range fan-out, and result submission.
`LatticeMiner` workers only search assigned immutable work and return nonce/hash
results. They do not hold miner private keys, know child-chain topology, build
child proofs, seal blocks, or publish to Ivy.

See [Mining role boundaries](design/mining-role-boundaries.md).

## CAS-First Principle

The Content-Addressed Storage (CAS) is the single source of truth. All other storage is derived.

The broker cascade for each chain is: per-chain **MemoryBroker** (LRU) -> shared **DiskBroker** (SQLite, Volume-granular) -> **IvyFetcher** (network). The DiskBroker is shared across all chains; each chain only has its own MemoryBroker. Pins are ref-counted with owner tags (e.g., `chain:height`), and two retention policies control when data is unpinned:

- **BlockRetention** (tip / retention / historical) -- governs block data lifetime.
- **StorageMode** (stateless / stateful / historical) -- governs state root lifetime via StateDiff.

| Layer | What it stores | Derived from |
|-------|---------------|--------------|
| MemoryBroker (per-chain LRU) | Hot blocks, recent state | DiskBroker |
| DiskBroker (shared SQLite) | All pinned blocks, transactions, state trees | Original data |
| IvyFetcher (network) | Remote block/state data | Peers |
| PBSS (SQLite) | Account balances, block index | DiskBroker postState |
| Mempool persistence | Transaction CIDs | DiskBroker tx bodies |
| Receipt index | txCID -> blockHash | DiskBroker block data |

## Data Flow

### Block Acceptance
```
Block received (inline via topic message)
  → Broker resolution (MemoryBroker → DiskBroker → IvyFetcher)
  → PoW validation
  → State update via CAS diff (prevState → postState)
  → Pin block data in DiskBroker with owner tag
  → Unpin replaced state roots per StorageMode (StateDiff)
  → PBSS StateStore updated
  → Receipt index written
  → Metrics incremented
  → Subscription events emitted
  → Peer reputation updated (Tally)
```

### Transaction Lifecycle
```
Submit via RPC
  → Validate (signatures, fees, nonces, balances)
  → Add to NodeMempool (fee-ordered) + Mempool (Ivy)
  → Store tx body in CAS
  → Announce CID to peers
  → Selected by miner (highest fee first)
  → Included in block → confirmed
  → Removed from both mempools
```

### Reorg Recovery
```
New tip diverges from old tip
  → Walk back to common ancestor
  → CAS diff each orphaned block via DiskBroker (postState → prevState)
  → Roll back StateStore account balances
  → Unpin orphaned block data; pin new chain's blocks
  → Collect new chain's confirmed tx CIDs
  → Remove confirmed txs from both mempools
  → Re-validate orphaned txs against new state
  → Add valid txs to both mempools
```

## Key Design Decisions

1. **CAS diffing over transaction replay**: State changes derived from merkle tree diffs, not by re-executing transactions. Correct by construction.

2. **Inline block propagation**: Block data is sent inline via topic messages, eliminating the round-trip fetch peers previously needed.

3. **Two-tier receipts**: Full receipt for recent blocks, CAS-derived for historical.

4. **Dual mempool**: NodeMempool (fee-ordered, for mining) alongside Ivy Mempool (for network compatibility). Both kept in sync.

5. **PBSS as cache**: SQLite provides O(1) reads; the shared DiskBroker is authoritative. PBSS rebuilt from DiskBroker after sync.

### Crash Recovery
```
Node starts with existing data directory
  → Restore chain state from chain_state.json (may be stale)
  → Read authoritative tip from SQLite (crash-safe via WAL)
  → If SQLite tip > chain state tip:
      Walk backwards through DiskBroker from SQLite tip to chain state tip
      Replay missing blocks forward via processBlockHeader
      Persist recovered chain state
  → Resume normal operation at full height
```

Pinned data in the shared DiskBroker is crash-safe (SQLite WAL), and the PBSS state store updates on every block acceptance. Only `chain_state.json` can be stale (written every `persistInterval` blocks). This means any blocks confirmed between the last persist and an ungraceful shutdown are recoverable from the DiskBroker without peers.

Path-aware persistence stores Nexus under `<data-dir>/Nexus` for compatibility and non-root chains under `<data-dir>/chains/<full-chain-path>`, such as `<data-dir>/chains/Nexus/Games/Payments`. Startup still reads legacy single-level child directories when present, then writes future state back to the canonical path-aware namespace.
