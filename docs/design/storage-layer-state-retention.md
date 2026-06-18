# Storage-Layer State Retention

Status: **implemented in this branch**. The storage primitive lives in
VolumeBroker 3.9.0; lattice-node declares canonical state roots to it.

## Thesis

State retention is a storage-layer problem. `LatticeNode` decides which
canonical state roots are live. `VolumeBroker` decides which CAS entries are
protected, serveable, and reclaimable.

The old refcount-driven path moved in the right direction by dropping the coarse
object-grain `postState.rawCID` pin, but it put too much garbage-collection logic
inside `LatticeNode`: node-set membership, genesis seeding, per-node owners,
reclaim cross-checks, and crash sweeps. That is the wrong ownership boundary.

## Ownership Boundary

- `cashew`: Merkle DAG/type layer. It defines roots, owned children, references,
  deterministic CIDs, and traversal helpers.
- `VolumeBroker`: storage and GC layer. It owns CAS bytes, volume entries, pins,
  retained-root sets, reachability, eviction, and idempotent crash retry.
- `LatticeNode`: chain policy. It computes canonical membership and retention
  windows, then declares the state roots that must remain live.
- `StateStore`: consensus and chain metadata. It is not the CAS liveness source
  of truth.

## Primitive

`RetainedRootBroker` exposes:

```swift
try await broker.advanceRetainedRoots(
    scope: "Nexus:state-retained-roots",
    roots: retainedPostStateRoots,
    operationID: payloadBoundOperationID
)
```

The operation has full-set semantics: `roots` is the complete retained set for
the scope after the operation, not an add/remove patch. Startup, reorg repair,
and crash retry converge by re-declaring the current canonical truth.

The operation is idempotent and payload-bound. Repeating the same
`operationID` with the same scope/root set is a no-op. Reusing it with different
payload fails closed. lattice-node includes the sorted root-set digest in the
operation ID so config changes at the same tip hash do not collide.

## Load-Bearing Requirements

1. **No live state eviction.** Every CID reachable from a declared retained state
   root remains fetchable and serveable after prune/eviction. If optimized
   reclaim ever disagrees with reachability, leak instead of evicting.
2. **Full-set convergence.** The caller supplies the complete root set for a
   scope. Correctness must not depend on receiving every historical mutation.
3. **Atomic storage boundary.** The retained-root set and operation marker commit
   in one VolumeBroker transaction.
4. **Store before retain.** The broker rejects missing or visibly incomplete
   stored retained roots before replacing the old scope. The node stores the
   cashew state closure before declaration.
5. **Owned edges only.** Reachability follows VolumeBroker/cashew owned volume
   entries. `Reference` links such as `prevState`, `parentState`, and parent
   blocks are not retention edges.
6. **Genesis is explicit.** Height 0 is included while the retention window
   covers it. Startup re-advances the scope from the recovered tip.
7. **Non-state content stays object-grain.** Blocks, transactions, specs,
   proofs, account pins, candidate pins, and validator pins keep their existing
   owner/count model.
8. **Canonical membership only.** Retained roots come from the canonical chain
   after fork choice. Side forks may leak until swept, but must never replace the
   canonical retained-root set. Accepted side forks still need temporary
   height-owner protection for their verified content and post-state roots so
   peers can fetch and evaluate the side branch until normal pruning.
9. **Crash retry is idempotent.** Repeating the same retained-root advance is
   safe. A later complete root set converges. In-memory refcount caches are not
   required for recovery.
10. **Retention-policy parity.** `.tip` retains only the current canonical state
    root; `.retention` retains the configured canonical window and fails toward
    keeping the tip when depth is zero; historical state mode retains all
    canonical state roots regardless of block-retention depth.
11. **Serving parity.** Retained roots seed the same reachability predicate used
    by serve gates and eviction, not only a private GC table.
12. **Cutover ordering.** In production cutover, retained-root advance happens
    before prune releases the old protective state. Sync pre-publishes a
    retained-root superset (new canonical roots plus the previously retained
    scope) and pins synced block consensus roots before publishing the
    canonical segment, then shrinks to the exact new retained-root set after
    the durable publish and stored-root metadata writes succeed. A failed
    publish or post-publish shrink can leak roots, but must not drop the old
    canonical state. Reading the previous scope for that pre-publish superset
    must fail closed; treating an unavailable durable scope as an empty set is
    a data-loss bug.

## Adversarial Review Record

Closed findings in this implementation:

- **Side-fork retention overwrite:** fixed by advancing from block-accept paths
  only when the block hash is the current canonical tip.
- **Operation ID not payload-bound:** fixed by hashing the sorted retained-root
  payload into the operation ID.
- **Stateless sync retained missing roots:** fixed by making retained-root
  advance a stateful-storage-only operation.
- **Sync tip postState fallback pin:** removed; sync now uses
  `consensusPinRoots(block:)` like live acceptance.
- **Sync commit before retained-root advance:** fixed by advancing retained roots
  after materialization and before `StateStore.commitCanonicalSegment`.
- **Sync retained-root advance drops old live roots on publish failure:** fixed
  by pre-publishing the union of the new canonical retained roots and the
  existing retained-root scope, then shrinking to the exact new set only after
  the durable canonical segment and block pins are committed. The failure mode
  is now over-retention, not loss of the pre-existing canonical state.
- **Sync canonical segment commits before block consensus pins:** fixed by
  pre-pinning each synced block's consensus roots before
  `StateStore.commitCanonicalSegment`. A pin failure now aborts before canonical
  history changes; stored-root metadata failures after publish leave durable pins
  behind and mark the chain unhealthy rather than risking eviction of canonical
  content.
- **Accepted side-fork content/state eviction:** fixed by separating final
  consensus roots from accepted-block protection roots. Canonical blocks release
  the temporary post-state pin after retained-root advancement; side forks keep
  the full verified stored-root set under the height owner until pruned.
- **Durable candidate finalizer ignored retained-root failure:** fixed by making
  `finalizeDurableBlockStorage` return `false` and routing callers through the
  durable failure path.
- **Zero retention depth could retain no state:** fixed to fail toward retaining
  the tip root.
- **Incomplete stored retained root:** fixed in VolumeBroker by validating the
  stored volume graph it can observe before replacing the retained scope.
- **Same-height candidate owner aliasing:** fixed by including the block CID in
  candidate storage owners and pruning stale candidate pins strictly below the
  promoted height. Concurrent same-height candidates no longer share a pin owner.
- **Bare-root first responder shadowing:** fixed by treating known block-volume
  roots as complete-bundle fetches. A peer that serves only the root node is
  suppressed for that root instead of being cached ahead of a complete holder.
- **Deficient bundle false reorg:** fixed by running sync and gossip durable
  materialization under Ivy's volume trace, reporting served roots as deficient
  on resolution failure, force-refetching around punished peers, and treating an
  unavailable full block bundle as retryable before fork-choice/reorg handling.
- **Unattributed CAS miss reported as hard failure:** fixed by treating a
  resolution miss with no remembered deficient server as a retryable sync/announce
  abort. The node still fails closed before durable publish; it no longer turns a
  transient availability race into a hard content-invalid log.
- **Historical state mode collapsed to block-retention window:** fixed by making
  retained-root advancement run for `.historical` state storage and forcing its
  retained state-root set to every canonical height, independent of
  `BlockRetention`.

No open findings remain for this rollout. Deliberate non-goals:

- The legacy `StateRefcountIndex` remains as a shadow/test facility.
- `StateStore.commitCanonicalSegment(connectsBelow: false)` is not deleted in
  this pass; it requires a separate recovery-path proof.
