# Architecture

## Process boundary

One `lattice-node` process owns exactly one absolute chain path. `Nexus` is the
only root; every other process is configured with a complete Nexus-inclusive
path and one immediate parent endpoint.

```text
Nexus process
  chain: Nexus
  overlay: 4001
  hierarchy facts: 4002
  RPC: 127.0.0.1:8080

Payments process
  chain: Nexus/Payments
  parent: <nexus-key>@<nexus-host>:4002
  overlay: 4101
  hierarchy facts: 4102
  RPC: 127.0.0.1:8180
```

A parent never owns its child's chain state, mempool, persistence, sync, or fork
choice. External orchestration starts and stops independent chain processes.

## Identity and addressing

`ChainAddress` accepts only absolute paths beginning with `Nexus`. The final
component is also the parent-relative `directory` edge, but a directory alone
is not a chain identity and is never accepted as a public chain path.

Examples:

- `Nexus` — valid root path.
- `Nexus/Payments` — valid child path.
- `Nexus/Payments/Rollups` — valid descendant path.
- `Payments` — invalid chain path.
- `/Nexus/Payments`, `Nexus/`, and `Nexus//Payments` — invalid.

The Nexus process has no parent. Every child must configure `--parent` with the
authenticated immediate parent's fact-plane public key and endpoint.

## Runtime components

```text
LatticeNodeDaemon
  ├─ NodeConfiguration     immutable path, keys, ports, work floor
  ├─ ChainProcess          consensus admission and durable recovery
  ├─ ChainService          transactions, intents, templates, work results
  ├─ NodeStore             state.db: facts, indexes, projections, recovery
  ├─ DiskBroker            volumes.db: materialized CAS volumes
  ├─ Ivy overlay           same-chain peers and content
  ├─ Ivy hierarchy plane   authenticated direct parent/child facts
  └─ loopback HTTP         thin JSON adapter over ChainService
```

`ChainProcess` is the sole consensus-admission boundary. Service and network
code may prepare data, but canonical state changes only through process
admission and its staged durable batch.

## Two network planes

The planes are deliberately separate:

1. The public overlay admits peers that claim the same Nexus genesis, absolute
   chain path, and minimum root-work floor. It carries block announcements and
   content-addressed retrieval.
2. The private hierarchy plane has no relay role. It carries direct-child
   candidate requests, child proofs, parent coverage, and genesis links. A
   configured parent key gates parent facts; a claimed path alone grants no
   authority.

A parent may request candidates only from authenticated direct children. Slow
or absent children are omitted within a bounded deadline, so one child cannot
stall Nexus template creation.

## Child genesis flow

1. Start the child process with its absolute path and parent fact endpoint. It
   opens its durable store in `awaitingGenesis`.
2. Call the parent's `POST /v1/children/intents`. The parent builds and stores a
   child genesis bound to its current state and returns the block and CID.
3. Construct and sign an ordinary parent transaction containing the matching
   `GenesisAction`, then submit it to `POST /v1/transactions`.
4. External mining commits that transaction and child block in a parent
   carrier.
5. The parent durably prepares and publishes the direct-child proof. The child
   verifies the authenticated link, bootstraps, and becomes `active`.

There is no opaque genesis byte channel. The content-addressed genesis block,
its CID, and the parent proof are the bootstrap material.

The process that directly parents an edge retains that edge's exact bounded
validation package before returning a contextual candidate. It replays durable
authorized-genesis availability when the child reconnects. An ancestor does not
become an implicit archive for packages below its direct children.

## Nexus genesis exception

Nexus is the one bootstrap exception because it has no parent. On an empty
Nexus store, `ChainProcess.open` constructs the deterministic unsigned genesis
and requires its CID to equal:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

On recovery, the store metadata and height-zero fact must name that same CID.
No other unsigned transaction or alternate Nexus genesis is accepted.

## External mining pipeline

```text
lattice-mining-coordinator
  │ POST /v1/mining/templates
  ▼
lattice-node (Nexus)
  │ complete nonce-zero candidate + effective search target
  ▼
lattice-miner workers
  │ nonce results
  ▼
lattice-mining-coordinator
  │ POST /v1/mining/work
  ▼
lattice-node admission → durability → overlay and child-proof publication
```

The node owns chain truth and template validity. The coordinator owns work
lifecycle and range allocation. Workers own only proof-of-work search over an
immutable assignment.

## Durability and recovery

Each process directory contains:

```text
<storage>/
  process.key   # default process identity, mode 0600
  state.db      # protocol facts and canonical projection
  volumes.db    # materialized content volumes
```

Admission stages protocol facts and materializes volumes before retained roots
advance. Startup audits the store, reconciles retained roots, verifies every
referenced materialized volume, and reconstructs the chain from the canonical
projection plus staged batches. Nexus additionally verifies the exact genesis
CID.

Legacy databases and volume layouts are not migrated in place. Operators must
remove the entire configured storage directory and resync; keeping only one of
`state.db` or `volumes.db` breaks their durability invariant.

## Testing networks

Deploy a child chain with test-oriented parameters when an application needs a
public or long-lived testing network. Nexus retains its one pinned genesis.
This preserves the same addressing, parent facts,
merged mining, and consensus rules used by every other child.
