# Testing

Run the complete node, daemon, coordinator, worker, and proof-verifier suite with:

```sh
swift test
```

The suites are grouped by the boundary they actually cross:

- `NodeStoreTests`: atomic admission, crash recovery, retained hierarchy evidence,
  immutable-index audit, and monotone inherited-work raw-fact durability.
- `ChainProcessTests`: one-path admission, restart, child bootstrap, proof composition, cancellation, and explicit local-versus-network acquisition boundaries.
- `NetworkTrustTests`: real-network integration tests, not E2E. They exercise
  overlay/fact-plane separation, bounded/canonical wire input, real
  peer-to-runtime async delegate delivery, root-scoped content attribution,
  per-connection hierarchy authorization, lifecycle fencing, and inherited-work
  fragment retry/high-cardinality packing.
- `MultichainInvariantTests`: direct-parent-only package acceptance, ancestor-path rejection, and durable exact-edge recovery across process reopen.
- `ChainServiceTests`: transaction, accepted-content reads, canonical account
  proofs, child-deploy, template, work-submission, reconciliation ordering, and
  publication despite optional hierarchy availability failures. Recovery tests
  crash between the durable consensus commit and service projection, replay the
  net endpoint fork delta, reopen twice, cover replacement between unrelated
  child genesis roots, and freeze the intentional A-to-B-to-A transient-branch
  boundary.
- `DaemonHTTPTests`: in-process HTTP router contracts, including rejection of
  loose block content and independent verification of returned account proofs.
- `LatticeNodeE2ETests`: black-box independent node processes. Consensus
  scenarios may only
  start, stop, suspend, and configure shipped processes; call public HTTP
  endpoints; run the shipped miner/coordinator; or participate as a real Ivy
  peer. They never instantiate `ChainProcess`, install runtime callbacks, or
  seed internal consensus state. One operator-recovery scenario copies stopped
  stores and deliberately combines mismatched halves to prove fail-closed
  restore behavior. The suite exercises direct-child
  bootstrap/restart, public WASM-policy child deployment retained across a
  parent restart, accepted policy traffic, rejection without tip movement,
  and subsequent child liveness; accepted block, transaction, and account-proof
  reads over a real daemon socket, with the exact proof response verified by
  the shipped proof-verifier before and after node restart; same-chain portable genesis and continuity
  recovery with a fully synchronized wrong-key process on the exact parent
  fact port while consensus remains unavailable,
  composed with Ivy's causal transport-identity tests and lattice-node's
  deterministic exact-parent hierarchy-role tests,
  reopen with every source offline, recursive three-level readiness revocation
  while transaction ingress
  stays available, same-path transaction relay and inclusion after the
  submitting replica stops, causal proof that a noncanonical message from an
  authenticated Ivy peer is ignored while that session and honest consensus
  traffic remain usable, three-level
  late join, a suspended
  non-responsive authenticated sibling, durable side-branch bootstrap after a
  reorg, same-path higher-work and segment-base-tie convergence, and a live competing-genesis
  reorg driven by noncanonical parent work without a restart; a second
  same-path replica then reconnects late and reaches the same result from the
  complete parent snapshot. The exchange
  scenarios run real Nexus and child
  daemons: one pits wrong-withdrawer, replay, and overclaim withdrawals against
  a fee-prioritized valid variable-rate claim, rejects a fresh-nonce replay
  after the deposit is permanently spent, and hands the next spend to a fresh
  same-path replica, while another settles two child
  chains through one co-signed Nexus transaction, moves Nexus to a strictly
  heavier conflicting-nonce branch that excludes the settlement, and spends
  both already-withdrawn child proceeds from the winning parent branch. These
  tests use only public HTTP APIs and Ivy sockets; they do not inject parent
  packages in-process.
- `LatticeMinerCoreTests` and `LatticeMiningCoordinatorTests`: nonce search, work allocation, staleness, subprocess cancellation, and current RPC payloads.
- `LatticeLightClientTests`: self-contained account witness verification,
  tampering and missing-node rejection, nonce absence, and verifier CLI
  stdin/file/exit-code contracts.

The test bar is boundary-focused rather than timing-focused. Tests inject missing
content, blocked acquisition, cancellation, restart, and publication failure at
the component that owns the consequence. In particular, they preserve these
cross-component invariants:

- only traced network admission may acquire remote content; RPC, mining, and
  reconciliation fail locally rather than fetching peers;
- each root-scoped acquisition gets an independent cashew coalescer, so one
  candidate cannot inherit another candidate's Ivy attribution;
- a hierarchy connection cannot read CAS content before its own compatible
  hello, and a provisional carrier can be served only as its leased request
  root and is never persisted;
- a durable canonical commit reserves reconciliation before a later template,
  transaction, or child intent can observe the new chain state;
- optional child-proof materialization never suppresses canonical publication
  or inherited-work refresh;
- inherited-work storage records one exact child-block location and the
  greatest raw work observed for each physical grind. Recovery rejects a
  grind relocated to another block, while replayed or older fragments cannot
  lose or multiply weight;
- an outbound inherited-work cursor advances only after every frame is locally
  queued; transient Ivy/Tally or transport pressure retries the same frame in
  order without inventing a receiver acknowledgement protocol;
- evidence and direct-edge inventories retain their exact cursor across
  transient Ivy/Tally pressure on a live parent session;
- a failed hierarchy hello or durable evidence hint recycles only that exact
  session; reconnect repeats authorization and the complete evidence index;
- proof recovery on a connected noncanonical carrier is announced after an
  already-completed empty index without changing the parent's canonical tip;
- a parent remains child-agnostic: child topology and derived weight stay in
  the child process and are never returned upstream;
- successor attachments received before child genesis wait on their exact
  same-chain predecessor instead of being misclassified as malformed genesis;
- a suspended authenticated direct child cannot block a healthy sibling's
  bounded root round;
- every accepted parent branch refreshes inherited work live; restart and
  reconnect are tested separately as durable catch-up paths, not prerequisites;
- peer-supplied portable continuity can restore verified history, but only a
  complete export from the live configured parent session activates consensus;
  disconnect revokes that activation recursively for descendants;
- staged facts and retained Volume roots reopen together, or recovery fails
  closed.
- a service-projection checkpoint advances only after bounded mempool and child
  intent reconciliation; startup replays the net canonical delta from the last
  projected tip to the recovered current tip before network or RPC exposure.
  Peer-only transactions from an unprojected transient branch that returns to
  the checkpoint remain volatile and require rebroadcast.

Keep concurrency tests deterministic: assert explicit latches, persisted
facts, or recorded content requests. Cashew owns the lower-level best-effort
batching algorithm tests; lattice-node tests the source and root boundaries
that decide which content is allowed to batch.

Consensus validation and signature compatibility live in the Lattice dependency and are tested in that repository; the direct process E2E additionally confirms that a legacy body-CID signature still reaches that validator through public node ingress. Storage and transport primitives are likewise tested in VolumeBroker, cashew, Ivy, and Tally. This repository pins those released revisions and tests their node-facing integration; their complete suites remain owned by their own release gates.

During release-bundle assembly, `.github/scripts/smoke-lattice-node.sh` runs
against the bundle's node, coordinator, miner, and proof verifier. After the archive is
assembled, the release workflow extracts it and reruns `LatticeNodeE2ETests`
against the archived `lattice-node` executable. The smoke test verifies the
exact Nexus genesis, mines and persists one block through the external mining
pipeline, restarts the shipped node and verifies the same tip, and confirms the
verifier executable starts successfully.

The scheduled nightly gate runs `scripts/stress-critical-paths.sh` against
release binaries. It repeatedly exercises the small set of timing-sensitive,
black-box paths where independent processes, live hierarchy sessions, durable
state, and external mining meet. Each iteration also runs three logged,
reproducible seeds of a bounded operational sequence covering transaction
relay, clean stop, SIGKILL, SIGSTOP, restart healing, exact template contents,
late join, and three-replica convergence. Pull requests run eight rounds;
nightly runs 24 rounds per seed. Set `LATTICE_STRESS_ITERATIONS` and
`LATTICE_STRESS_ROUNDS` (1 through 155) to tune the same gate locally; the
defaults are five iterations and 24 rounds.
