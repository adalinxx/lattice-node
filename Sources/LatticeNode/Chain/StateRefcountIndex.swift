import Lattice
import Foundation
import VolumeBroker
import cashew

// SHADOW state REFCOUNT-index maintenance for the reference-counting retention
// redesign (the K-block retention-window model). This is the pivot of the prior
// "death-height oracle" shadow to an EDGE REFERENCE COUNT over the retained state
// versions: `refcount[X]` = number of parent trie-edges pointing to state node X
// across the retained post-states. X is reclaimable when `refcount[X] == 0` (no
// retained parent) and X is not itself a retained block's post-state root.
//
// This file wires the durable refcount bookkeeping (`StateStore`'s
// `state_node_refcount` / `state_node_edges` / `state_node_created` /
// `state_node_replaced` / `state_node_root` tables) into the node's accept / prune /
// reorg paths in SHADOW mode: it is maintained ALONGSIDE the live object-grain
// pin/prune mechanism and drives NO unpin/reclaim.
//
// CRITICAL — SHADOW means ZERO behavior change. Every entry point here is
// best-effort: it resolves its StateStore, runs the bookkeeping inside a `do`, and
// on ANY error LOGS and returns. It never throws into, blocks, or otherwise perturbs
// the caller's accept/prune/reorg flow. A shadow index that breaks accept is far
// worse than no index, so the maintenance is strictly additive.

extension LatticeNode {

    /// ACCEPT (increment): record block N's membership-faithful `created`/`replaced`
    /// state-node sets and the outgoing child edges of every `created` node, and
    /// increment `refcount[child]` for every created→child edge. Called from
    /// `commitBlockStorage`/`finalizeDurableBlockStorage` after the block is committed.
    ///
    /// IMPORTANT — diff source. The node DOES populate `stateDiff.replaced`/`.created`
    /// (produced by Lattice's `diffCIDs(old:new:)` inside `proveAndUpdateState`), BUT
    /// `diffCIDs` is a PATH-WISE delta: it lists the nodes on the changed trie paths
    /// without checking whether a "replaced" CID is still referenced elsewhere in the
    /// new frontier (content-addressed structural sharing across non-adjacent heights).
    /// It is therefore NOT membership-faithful — it both over- and under-reports the
    /// true edge set, which would CORRUPT the refcounts. The refcount index instead
    /// uses the MEMBERSHIP-faithful adjacent trie set-difference:
    ///   created(N)  = nodeSet(postState_N) \ nodeSet(prevState_N)
    ///   replaced(N) = nodeSet(prevState_N) \ nodeSet(postState_N)
    /// `created(N)` is the changed root→leaf path; its nodes' children include new and
    /// inherited/shared subtrees — incrementing a shared child is CORRECT (post_N now
    /// also references it). Re-introduction self-heals: a CID re-appearing in a later
    /// `created` re-increments it. Genesis (height 0) creates the whole trie → its
    /// increments are O(frontier), one-time.
    func recordStateRefcountOnAccept(
        block: Block,
        height: UInt64,
        network: ChainNetwork,
        directory: String
    ) async {
        // The index must be MAINTAINED whenever the shadow OR the reclamation flip is
        // on (the flip drives retention off this index, so it cannot be empty).
        guard stateDeathIndexShadowEnabled || stateRetentionViaRefcount else { return }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        let key = chainKey(forDirectory: directory)
        let fetcher = network.canonicalContentFetcher()
        do {
            // POST (perf): reuse the node-set + edges the accept path ALREADY resolved
            // in `storeAcceptedStateDiffRoots` (captured into `stateRefcountPendingPost`
            // from the materialized `updatedHeader`). Only re-resolve if the pending
            // capture is absent or stale (e.g. an early-return accept that skipped
            // capture), so the common path does O(0) post re-resolution.
            let post: StateGraph
            if let pending = stateRefcountPendingPost[key], pending.cid == block.postState.rawCID {
                post = pending.graph
            } else {
                post = try await resolvedStateGraph(stateCID: block.postState.rawCID, fetcher: fetcher)
            }
            // The pending capture is consumed; never let it leak into a later block.
            stateRefcountPendingPost[key] = nil
            let prev: StateGraph
            if height == 0 || block.prevState.rawCID.isEmpty {
                prev = StateGraph(nodes: [], edges: [:])
            } else if let last = stateRefcountLastPost[key], last.cid == block.prevState.rawCID {
                // PREV (perf): prevState_N == postState_{N-1}. Reuse the PREVIOUS
                // accept's post node-set as this block's prev — no prev re-resolution
                // on the steady-state in-order accept path. A cache miss (cold start,
                // restart, reorg, gap) falls back to a full resolve below.
                prev = last.graph
            } else {
                prev = try await resolvedStateGraph(stateCID: block.prevState.rawCID, fetcher: fetcher)
                // GENESIS SEED. The genesis frontier (height 0) is committed OUTSIDE
                // this accept hook, so its created edges / root pin are never recorded
                // by its own accept. The first non-genesis accept (height 1) resolves
                // `prev` = post_0 = the genesis state; seed height 0 from it (idempotent
                // — `recordStateRefcountDiff` no-ops if height 0's root is already
                // recorded) so the genesis root is a first-class pinned root, its unique
                // nodes are
                // reclaimed once it leaves the window. Without this the genesis root
                // never releases → a shadow LEAK vs reachability.
                if height == 1 && !genesisRefcountSeeded.contains(key) {
                    let genesisEdges: [StateStore.StateNodeEdges] = prev.nodes.compactMap { cid in
                        guard let children = prev.edges[cid], !children.isEmpty else { return nil }
                        return StateStore.StateNodeEdges(parent: cid, children: children)
                    }
                    try await store.recordStateRefcountDiff(
                        height: 0,
                        root: block.prevState.rawCID,
                        created: Array(prev.nodes),
                        replaced: [],
                        createdEdges: genesisEdges
                    )
                    // FLIP: the genesis frontier is committed outside this hook, so its
                    // nodes were never refcount-pinned. Seed their per-node pins here so
                    // the whole genesis state trie is retained by the index (not by an
                    // object-grain postState pin) from the first non-genesis accept.
                    await pinRefcountStateNodes(prev.nodes.union([block.prevState.rawCID]), network: network)
                }
            }
            let created = post.nodes.subtracting(prev.nodes)
            let replaced = prev.nodes.subtracting(post.nodes)
            // PREV cache for the NEXT block: this block's post IS height N+1's prev.
            // Set it unconditionally on success (even if the diff below is empty / the
            // record short-circuits) so the next in-order accept reuses it.
            if !block.postState.rawCID.isEmpty {
                stateRefcountLastPost[key] = (cid: block.postState.rawCID, graph: post)
            }
            // Edges of exactly the CREATED nodes (their adjacency captured in the post
            // walk). Incrementing over created→child edges is the accept increment.
            let createdEdges: [StateStore.StateNodeEdges] = created.compactMap { cid in
                guard let children = post.edges[cid], !children.isEmpty else {
                    // A created node with no outgoing edges (a leaf trie node) still
                    // exists as a node; it just contributes no increments.
                    return nil
                }
                return StateStore.StateNodeEdges(parent: cid, children: children)
            }
            guard !created.isEmpty || !replaced.isEmpty || !block.postState.rawCID.isEmpty else { return }
            try await store.recordStateRefcountDiff(
                height: height,
                root: block.postState.rawCID,
                created: Array(created),
                replaced: Array(replaced),
                createdEdges: createdEdges
            )
            // FLIP: pin every CREATED state node (plus the post-state ROOT, which a
            // no-op block may leave out of `created`) per-node so the index — not the
            // object-grain `postState.rawCID` pin — retains the trie. A shared node
            // re-created at a later height re-pins idempotently under its per-node
            // owner (reachability cares only that the pin exists, count is harmless).
            await pinRefcountStateNodes(created.union([block.postState.rawCID]), network: network)
        } catch {
            NodeLogger("staterefcount").error("\(directory): shadow refcount-index accept record failed at height \(height) (SHADOW — live retention unaffected): \(error)")
        }
    }

    /// GENESIS SEED (at genesis-commit time). The genesis frontier (height 0) is
    /// committed OUTSIDE the `commitBlockStorage`/`finalizeDurableBlockStorage` accept
    /// hook (it is stored directly during node init), so its `created(0)` set, its
    /// root pin, and — in FLIP mode — its per-node refcount pins are otherwise never
    /// seeded until the FIRST non-genesis accept (height 1) resolves `prev` = post_0
    /// and seeds height 0 from it. That leaves a narrow gate-ON window: a node that
    /// commits genesis then STALLS before height 1 (longer than the eviction grace
    /// window) has NO refcount pin on its genesis state nodes — they live as their own
    /// volume tree, not under the genesis blockHash object pin — so an eviction sweep
    /// could drop live genesis state. This method closes that window by seeding the
    /// genesis frontier's refcount index entry AND its per-node pins at genesis-commit
    /// time (called from `start()` after recovery, the choke point every node passes).
    ///
    /// It is the EXACT same work the height-1 accept performs for the genesis frontier,
    /// just earlier, and is IDEMPOTENT with it: `recordStateRefcountDiff` no-ops when
    /// (height 0, root) is already recorded (so the later height-1 seed sees it done and
    /// double-counts nothing), and `pinRefcountStateNodes` re-pins under the SAME
    /// per-node owner (a harmless count bump; reachability is count>0).
    ///
    /// DEFAULT-OFF: gated identically to `recordStateRefcountOnAccept` — a no-op unless
    /// the shadow OR the flip is on, and the pins are taken only under the flip. With
    /// both flags off this records nothing and pins nothing (byte-identical to today).
    /// Best-effort / non-throwing: it MUST NEVER perturb genesis commit / startup.
    func seedGenesisStateRefcountIfNeeded(directory: String, network: ChainNetwork) async {
        guard stateDeathIndexShadowEnabled || stateRetentionViaRefcount else { return }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        let genesisRootCID = genesisResult.block.postState.rawCID
        guard !genesisRootCID.isEmpty else { return }
        let fetcher = network.canonicalContentFetcher()
        do {
            let genesis = try await resolvedStateGraph(stateCID: genesisRootCID, fetcher: fetcher)
            let genesisEdges: [StateStore.StateNodeEdges] = genesis.nodes.compactMap { cid in
                guard let children = genesis.edges[cid], !children.isEmpty else { return nil }
                return StateStore.StateNodeEdges(parent: cid, children: children)
            }
            // created(0) = the whole genesis frontier (no prev), replaced = ∅. Idempotent:
            // a prior seed (this method on a restart, or the height-1 accept seed) recorded
            // (height 0, genesisRootCID) → recordStateRefcountDiff returns without double-
            // incrementing any edge.
            try await store.recordStateRefcountDiff(
                height: 0,
                root: genesisRootCID,
                created: Array(genesis.nodes),
                replaced: [],
                createdEdges: genesisEdges
            )
            // FLIP: pin every genesis state node (plus the root) per-node so the index —
            // not the object-grain genesis blockHash pin — retains the genesis state trie
            // from genesis-commit time. No-op unless the flip is on. Idempotent re-pin.
            await pinRefcountStateNodes(genesis.nodes.union([genesisRootCID]), network: network)
            // Mark this chain's genesis as seeded so the first non-genesis accept skips
            // its (now redundant) genesis re-seed/re-pin — avoiding a re-pin of genesis
            // nodes the floor-1 reclaim just released.
            genesisRefcountSeeded.insert(chainKey(forDirectory: directory))
        } catch {
            NodeLogger("staterefcount").error("\(directory): genesis refcount seed failed (best-effort — genesis commit / startup unaffected): \(error)")
        }
    }

    /// The owned state-trie node set + parent→child edge multiset of a frontier,
    /// resolving the (possibly unhydrated) state by its root CID. The node set mirrors
    /// `StateDeathTrackingProofTests.stateNodeSet` (the universe the reachability
    /// oracle protects); the edges are captured during the SAME structural walk.
    struct StateGraph {
        var nodes: Set<String>
        /// parent cid -> (child cid -> edge multiplicity).
        var edges: [String: [String: Int]]
    }

    private func resolvedStateGraph(stateCID: String, fetcher: Fetcher) async throws -> StateGraph {
        let resolved = try await LatticeStateHeader(rawCID: stateCID, node: nil, encryptionInfo: nil)
            .resolveRecursive(fetcher: fetcher)
        var graph = StateGraph(nodes: [], edges: [:])
        resolved.collectStateRefEdges(into: &graph)
        return graph
    }

    // MARK: - RECLAMATION FLIP (refcount-driven STATE retention; gated, default OFF)

    /// Per-node refcount pin owner. ONE owner per state-node CID so reclaim is a clean
    /// `unpinAll(owner:)` per node — no pin-count arithmetic to drift against the index.
    /// Re-creating a shared node at a later height re-pins under the SAME per-node
    /// owner (count bumps, harmless: reachability is count>0), and reclaim deletes the
    /// node's pin row wholesale. Distinct from the `<ns>:<height>` / `candidate:` /
    /// `account:` / `validates:` owner namespaces (own `staterefcount-node:` prefix).
    static func refcountStateNodeOwner(cid: String) -> String { "staterefcount-node:\(cid)" }

    /// FLIP ACCEPT: pin each given state node per-node so the refcount index — not the
    /// object-grain postState pin — retains the STATE trie. Best-effort and gated: a
    /// no-op unless `stateRetentionViaRefcount` is on, so OFF takes ZERO pins (byte-
    /// identical to today). A pin failure is logged; the index still records the node,
    /// so a later re-pin / availability gate can recover — fail-safe direction is LEAK
    /// (the missing pin can at worst evict a node the index thinks retained, which the
    /// availability gate re-materializes; it can NEVER unpin a live node here).
    func pinRefcountStateNodes(_ cids: Set<String>, network: ChainNetwork) async {
        guard stateRetentionViaRefcount else { return }
        for cid in cids where !cid.isEmpty {
            do {
                try await network.pinDurably(root: cid, owner: Self.refcountStateNodeOwner(cid: cid))
            } catch {
                NodeLogger("staterefcount").error("refcount-flip: failed to pin state node \(String(cid.prefix(16)))… (retention may under-protect this node; availability gate re-materializes): \(error)")
            }
        }
    }

    /// FLIP PRUNE: reclaim (unpin) exactly the refcount-0 state nodes at `floor` — the
    /// set the verification mode already proves == reachability. Drives the actual
    /// state eviction when `stateRetentionViaRefcount` is on; a no-op otherwise.
    ///
    /// FAIL-SAFE (the load-bearing safety property). Eviction of LIVE state is a
    /// consensus break; over-retention is a benign leak. So the reclaim is guarded to
    /// fail toward LEAK, never toward live eviction:
    ///   1. STRUCTURAL CROSS-CHECK (always on, cheap, non-circular). Before unpinning,
    ///      we recompute the RETAINED set a SECOND, independent way — a forward BFS from
    ///      the retained post-state roots over `state_node_edges`
    ///      (`retainedStateNodes(atFloor:)`) — and assert the reclaim set (a backward
    ///      refcount-0 CASCADE) is DISJOINT from it. If ANY reclaim node is also
    ///      forward-reachable from a retained root, the index is internally inconsistent
    ///      (a node structurally inside a retained version was declared dead) → we ABORT
    ///      the whole reclaim at this floor and LEAK. Two independent algorithms over the
    ///      same structure: a bug in either is caught here and fails toward retention.
    ///   2. Each unpin is `unpinAll(owner: per-node)` — it releases ONLY this node's
    ///      refcount pin. A node still held by a surviving pin (object-grain block pin,
    ///      or another retained closure) stays reachable: unpinning its refcount owner
    ///      cannot evict it. So even absent the guard, the worst case of an unpin is a
    ///      node losing its refcount pin while another pin keeps it alive (leak), not a
    ///      live eviction.
    func reclaimRefcountStateNodes(floor: UInt64, directory: String, network: ChainNetwork) async {
        guard stateRetentionViaRefcount else { return }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        let reclaimable = store.reclaimableStateNodes(atFloor: floor).filter { !$0.isEmpty }
        guard !reclaimable.isEmpty else { return }

        // FAIL-SAFE guard (1): the reclaim set must be disjoint from the independently
        // recomputed forward-reachable retained set. Any overlap means a still-live
        // (retained-root-reachable) node was declared reclaimable — abort and LEAK.
        let retained = store.retainedStateNodes(atFloor: floor)
        let liveInReclaim = reclaimable.filter { retained.contains($0) }
        if !liveInReclaim.isEmpty {
            let detail = liveInReclaim.prefix(10).map { String($0.prefix(16)) + "…" }.joined(separator: ",")
            NodeLogger("staterefcount").error("""
            refcount-flip: ABORTING reclaim at floor \(floor) — \(liveInReclaim.count) reclaim-set node(s) \
            are STILL forward-reachable from a retained root (a refcount bug would EVICT LIVE state). \
            FAIL-SAFE: no unpin performed (LEAK), verdict retried next prune. First: \(detail)
            """)
            return
        }

        var reclaimed = 0
        for cid in reclaimable {
            do {
                // Release ONLY this node's refcount pin. If another pin still reaches
                // the node it stays alive (benign over-retention), never evicted here.
                try await network.unpinAllDurably(owner: Self.refcountStateNodeOwner(cid: cid))
                reclaimed += 1
            } catch {
                // Fail-safe: an unpin failure LEAKS (node stays pinned). Never fatal.
                NodeLogger("staterefcount").warn("refcount-flip: failed to unpin reclaimed state node \(String(cid.prefix(16)))… (LEAK — node stays retained): \(error)")
            }
        }
        if reclaimed > 0 {
            NodeLogger("staterefcount").debug("\(directory): refcount-flip reclaimed \(reclaimed) state node(s) at floor \(floor)")
        }
    }

    /// PRUNE (shadow): at the retention floor advance, compute the shadow refcount
    /// index's reclaim verdict (the nodes that reach refcount 0 once the prune
    /// boundary releases the pruned heights' root pins, with cascade) and LOG it.
    /// SHADOW — this does NOT unpin anything; the live object-grain pin/prune remains
    /// the sole retention mechanism. `floor` is the height through which blocks have
    /// been pruned (the value passed to `reclaimableStateNodes(atFloor:)`).
    func logStateRefcountReclaimVerdict(floor: UInt64, directory: String) async {
        guard stateDeathIndexShadowEnabled else { return }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        let reclaimable = store.reclaimableStateNodes(atFloor: floor)
        guard !reclaimable.isEmpty else { return }
        NodeLogger("staterefcount").debug("\(directory): SHADOW refcount-index would reclaim \(reclaimable.count) state node(s) at floor \(floor) (no unpin performed)")
    }

    /// PRODUCTION VERIFICATION (de-risk the eventual reclamation flip; drives NO
    /// eviction). When `stateRefcountVerifyAgainstReachability` is ON, this runs at the
    /// prune boundary — AFTER the live object-grain prune has already released the
    /// pruned heights' root pins — and asserts the refcount index's reclaim verdict
    /// (`reclaimableStateNodes(atFloor:)`) agrees with the live ground truth (which of
    /// the index's known state nodes are NOT pin-reachable in the per-chain DiskBroker).
    /// On ANY divergence it logs LOUDLY: this is the in-production proof that flipping
    /// reclamation onto the index would be safe. It STILL drives no unpin — read-only
    /// compare + log. Best-effort / non-throwing, exactly like the rest of the shadow.
    ///
    /// `floor` is the post-prune retention floor (every height < floor is pruned), so
    /// the index verdict and the already-pruned live broker describe the SAME boundary.
    func verifyStateRefcountAgainstReachability(floor: UInt64, directory: String, network: ChainNetwork) async {
        guard stateDeathIndexShadowEnabled, stateRefcountVerifyAgainstReachability else { return }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        let indexReclaimable = Set(store.reclaimableStateNodes(atFloor: floor))
        let universe = store.allKnownStateNodes()
        guard !universe.isEmpty else { return }
        let broker = network.diskBroker
        var divergences: [(cid: String, indexReclaimable: Bool, unreachable: Bool)] = []
        for cid in universe where !cid.isEmpty {
            let idx = indexReclaimable.contains(cid)
            // Ground truth: a node is reclaimable-by-reachability iff it is NOT
            // pin-reachable from any live object-root pin in the per-chain broker.
            let unreachable = !(await broker.isPinReachable(cid: cid))
            if idx == unreachable { continue }
            // FLIP-AWARE: when retention is refcount-driven, the reclaim has ALREADY
            // run before this verify. A node that is index-reclaimable yet still
            // reachable is a BENIGN structural-sharing leak (its OWN refcount pin was
            // released by reclaim; it survives only as a non-root entry inside a
            // still-retained node's volume closure) — NOT a live-eviction risk. Suppress
            // it from divergences so the verify reports the true (eviction) risk only.
            if stateRetentionViaRefcount, idx, !unreachable {
                let ownReleased = !(await broker.owners(root: cid)).contains(Self.refcountStateNodeOwner(cid: cid))
                if ownReleased { continue }   // reclaim released the own-pin → safe leak
            }
            divergences.append((cid: cid, indexReclaimable: idx, unreachable: unreachable))
        }
        if divergences.isEmpty {
            NodeLogger("staterefcount").debug("\(directory): refcount-index VERIFY OK at floor \(floor) — verdict == reachability over \(universe.count) node(s) (no unpin performed)")
            return
        }
        // LOUD: a divergence means the eventual reclamation flip would either EVICT
        // LIVE state (index says reclaimable, broker still reaches it) or LEAK dead
        // state (index keeps it, broker can't reach it). Log every divergence loudly;
        // still no unpin is driven.
        let wouldEvict = divergences.contains { $0.indexReclaimable && !$0.unreachable }
        let detail = divergences.prefix(25).map {
            "cid=\(String($0.cid.prefix(16)))… indexReclaimable=\($0.indexReclaimable) unreachable=\($0.unreachable)"
        }.joined(separator: "; ")
        NodeLogger("staterefcount").error("""
        \(directory): REFCOUNT-INDEX VERIFY DIVERGENCE at floor \(floor) for \(divergences.count) node(s) — \
        the reclamation flip would \(wouldEvict ? "EVICT LIVE STATE" : "LEAK dead state"). \
        SHADOW — no unpin performed. First \(min(25, divergences.count)): \(detail)
        """)
    }

    /// SHADOW (testing / negative-control): expose whether the in-production
    /// verification would find a divergence right now, WITHOUT logging or perturbing
    /// anything. Returns the diverging (cid, indexReclaimable, unreachable) triples so a
    /// test can assert the verification is non-vacuous (detects an injected wrong
    /// refcount) and otherwise clean (the perf fix changed no verdict).
    ///
    /// `reachabilityBroker` lets a test supply an INDEPENDENT reachability oracle (a
    /// clean DiskBroker built from the node's resolved post-state closures, mirroring
    /// `shadow refcount proof tests`'s oracle) so the comparison LOGIC is exercised
    /// against a deterministic ground truth instead of the live broker's pin churn.
    /// nil uses the live per-chain DiskBroker (the actual production path).
    func stateRefcountVerificationDivergences(
        floor: UInt64,
        directory: String = "Nexus",
        reachabilityBroker: DiskBroker? = nil
    ) async -> [(cid: String, indexReclaimable: Bool, unreachable: Bool)] {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return [] }
        let broker: DiskBroker
        if let reachabilityBroker {
            broker = reachabilityBroker
        } else if let network = network(for: directory) {
            broker = network.diskBroker
        } else {
            return []
        }
        let indexReclaimable = Set(store.reclaimableStateNodes(atFloor: floor))
        var divergences: [(cid: String, indexReclaimable: Bool, unreachable: Bool)] = []
        for cid in store.allKnownStateNodes() where !cid.isEmpty {
            let idx = indexReclaimable.contains(cid)
            let unreachable = !(await broker.isPinReachable(cid: cid))
            if idx != unreachable {
                divergences.append((cid: cid, indexReclaimable: idx, unreachable: unreachable))
            }
        }
        return divergences
    }

    /// SHADOW (testing): toggle the production verification gate.
    func setStateRefcountVerifyAgainstReachabilityForTests(_ enabled: Bool) {
        stateRefcountVerifyAgainstReachability = enabled
    }

    /// FLIP (testing): toggle the refcount-driven STATE retention gate (default OFF).
    func setStateRetentionViaRefcountForTests(_ enabled: Bool) {
        stateRetentionViaRefcount = enabled
    }

    /// RETAINED ROOTS (testing): toggle the storage-layer state-retention gate.
    func setStateRetentionViaRetainedRootsForTests(_ enabled: Bool) {
        stateRetentionViaRetainedRoots = enabled
    }

    /// GENESIS SEED (testing): run the genesis-commit refcount seed on demand. The
    /// production call site is `start()`, which runs BEFORE a test can flip the
    /// retention gate on; this lets a test enable the flip and then prove the genesis
    /// frontier is refcount-pin-protected immediately — before any height-1 accept.
    func seedGenesisStateRefcountForTests(directory: String = "Nexus") async {
        guard let network = network(for: directory) else { return }
        await seedGenesisStateRefcountIfNeeded(directory: directory, network: network)
    }

    /// FLIP (testing): the per-chain StateStore (refcount index) for direct queries
    /// (`allKnownStateNodes` / `reclaimableStateNodes` / `retainedStateNodes`).
    func shadowStateStoreForTests(directory: String = "Nexus") -> StateStore? {
        stateStores[chainKey(forDirectory: directory)]
    }

    /// FLIP (testing): the live-broker pin owners of `cid` — lets a test prove a node
    /// that survives reclaim is held by a NON-refcount owner (structural-sharing leak),
    /// never by a refcount pin the reclaim failed to release.
    func stateNodePinOwnersForTests(cid: String, directory: String = "Nexus") async -> Set<String> {
        guard let network = network(for: directory) else { return [] }
        return await network.diskBroker.owners(root: cid)
    }

    /// FLIP (testing): per-node refcount pin owner string for `cid`.
    static func refcountStateNodeOwnerForTests(cid: String) -> String {
        refcountStateNodeOwner(cid: cid)
    }

    /// FLIP (testing): is `cid` currently pin-reachable in the per-chain live broker?
    /// Lets a test assert refcount-driven retention/reclaim against the SAME ground
    /// truth the verification uses.
    func isStateNodePinReachableForTests(cid: String, directory: String = "Nexus") async -> Bool {
        guard let network = network(for: directory) else { return false }
        return await network.diskBroker.isPinReachable(cid: cid)
    }

    /// SHADOW (testing): the cached last-post frontier root the perf fix reuses as the
    /// NEXT block's prev. Non-nil after at least one in-order accept proves the
    /// post-node-set reuse path was actually taken (not the fallback re-resolve).
    func stateRefcountLastPostCID(directory: String = "Nexus") -> String? {
        stateRefcountLastPost[chainKey(forDirectory: directory)]?.cid
    }

    /// REORG REVERT (shadow): undo the abandoned fork heights' accept increments from
    /// the refcount index. The new branch's blocks re-enter the index automatically
    /// through the normal accept path (`recordStateRefcountOnAccept`), so revert only
    /// has to inverse-apply the orphaned heights' increments. SHADOW — best-effort,
    /// never perturbs reorg recovery.
    ///
    /// FLIP NOTE (fail-safe): a fork-ONLY state node's per-node refcount pin is NOT
    /// unpinned here — forgetting the height removes the node from the index universe,
    /// so the prune-boundary reclaim never sees it again. This is a deliberate LEAK
    /// (over-retention of orphaned-fork-only state), the safe failure direction: a
    /// reorg-revert unpin would risk evicting a node the NEW branch re-references
    /// (re-introduction). Orphan-only state is bounded by fork depth; the safe choice
    /// is to retain it, never to evict-live.
    func forgetStateRefcountOnReorg(orphanedHeights: [UInt64], directory: String) async {
        guard stateDeathIndexShadowEnabled || stateRetentionViaRefcount else { return }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        // The post-graph perf caches may point at an orphaned frontier after a reorg.
        // The accept hook already guards reuse on CID equality (a stale entry simply
        // misses → full resolve), so this is defensive memory hygiene, not correctness.
        let key = chainKey(forDirectory: directory)
        stateRefcountPendingPost[key] = nil
        stateRefcountLastPost[key] = nil
        for height in orphanedHeights {
            do {
                try await store.forgetStateRefcountHeight(height)
            } catch {
                NodeLogger("staterefcount").error("\(directory): shadow refcount-index reorg-forget failed at height \(height) (SHADOW — live retention unaffected): \(error)")
            }
        }
    }

    // MARK: - Testing accessors

    /// SHADOW reclaim verdict from the LIVE node-maintained refcount index — the set
    /// of state-node CIDs the index reports reclaimable once the retention floor
    /// passes `floor`. Used by `shadow refcount proof tests` to cross-check the live
    /// index against the reachability oracle.
    public func shadowReclaimableStateNodes(atFloor floor: UInt64, directory: String = "Nexus") -> [String] {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return [] }
        return store.reclaimableStateNodes(atFloor: floor)
    }

    /// SHADOW: the full live edge-refcount view from the live refcount index.
    public func shadowStateNodeRefcounts(directory: String = "Nexus") -> [(cid: String, refcount: Int)] {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return [] }
        return store.stateNodeRefcounts()
    }
}

// MARK: - Type-erased state-trie edge enumeration

extension Header {
    /// Walk this resolved header's owned subtree, recording every node CID and every
    /// parent→child edge into `graph`. Mirrors cashew's `storeRecursively` traversal
    /// (`Node.properties()`/`get(property:)` for children, plus a RadixNode `value`
    /// that is itself a Header), so the captured node set is identical to the one
    /// `collectVolumes` produces and every outgoing edge is captured exactly once per
    /// distinct (parent, child) content-addressed pair.
    ///
    /// `references` (cashew `Reference` back/shared links, e.g. a block's prev/parent
    /// state) are deliberately NOT children here and are never resolved/walked, so the
    /// graph never climbs backward into unrelated history — exactly the boundary
    /// `BrokerStorer.exitVolume` documents for the live pin reachability graph.
    func collectStateRefEdges(into graph: inout LatticeNode.StateGraph) {
        // The structural subtree walk is owned by cashew (`walkOwnedSubtree`); the
        // node only decides how the walked nodes/edges populate its retention graph.
        var visited = graph.nodes   // preserve cross-call dedup of an already-walked frontier
        walkOwnedSubtree(visited: &visited) { parent, childEdges in
            graph.nodes.insert(parent)
            if !childEdges.isEmpty { graph.edges[parent] = childEdges }
        }
    }
}
