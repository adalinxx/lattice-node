import XCTest
import Foundation
import Ivy
import VolumeBroker
import cashew
import UInt256
@testable import Lattice
@testable import LatticeNode

/// ANCHOR proof for the diff-driven state-death retention redesign
/// (`docs/readiness/state-retention-diff-death-design.md`).
///
/// The accepted design models a state trie node's lifetime as `[BIRTH, DEATH]`:
///   - BIRTH = the block whose `stateDiff.created` first introduced the node.
///   - DEATH = the block that REPLACED the node's trie path (so it was LAST
///     referenced by `death - 1`; reclaimable once the retention floor passes
///     `death - 1`, i.e. once every block `< death` is pruned).
/// Reads (serve/evict) then become O(1) "is this node in the live set?" with no
/// recursive reachability walk.
///
/// This file proves the diff-driven model is CORRECT by cross-checking it against
/// the already-proven reachability GROUND TRUTH — `DiskBroker.isPinReachable` over
/// `volume_entries`, which `ProvenClosureRetentionTests` /
/// `ReferenceRetentionProofTests` established as the trustworthy retention oracle.
/// If the diff-driven death verdict EVER disagrees with reachability, the diff
/// model is design-invalidating WRONG and the failure is reported LOUDLY — the
/// test is not massaged to pass.
///
/// `StateDiff` (Lattice `State/ReplacedCIDs.swift`) carries `created`/`replaced`,
/// but to keep this proof self-contained and independent of the production diff
/// emitter, we compute BOTH sets in-test as a TRIE SET-DIFFERENCE of the two
/// states' full owned node-sets (mirroring `collectStateVolumes`):
///   created(N→N+1) = nodeSet(postState_{N+1}) \ nodeSet(postState_N)
///   replaced(N→N+1) = nodeSet(postState_N) \ nodeSet(postState_{N+1})
/// where nodeSet(state) = `LatticeStateHeader.storeRecursively`'s `storedRoots`.
final class StateDeathTrackingProofTests: XCTestCase {

    // MARK: - Fixtures (mirror ReferenceRetentionProofTests)

    private func tempDiskBroker() throws -> DiskBroker {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)
    }

    private func makeNetwork(disk: DiskBroker) async throws -> ChainNetwork {
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    private func buildMultiVolumeGenesis(accountCount: Int, fetcher: Fetcher) async throws -> Block {
        var transactions: [Transaction] = []
        for i in 0..<accountCount {
            let owner = "premine-owner-\(i)-\(UUID().uuidString)"
            let action = AccountAction(owner: owner, delta: Int64(1000 + i))
            let body = TransactionBody(
                accountActions: [action], actions: [], depositActions: [],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 0, nonce: 0
            )
            let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
            transactions.append(Transaction(signatures: [owner: "genesis"], body: bodyHeader))
        }
        return try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            transactions: transactions,
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: fetcher
        )
    }

    /// Build a CONSUMER block on top of `producer`, applying `transferCount`
    /// account credits to FRESH owners (nonce 0 per distinct signer) so the
    /// accounts trie genuinely branches+mutates and postState_{child} differs
    /// from postState_{producer}. `salt` keeps owners distinct across heights so
    /// each transition replaces a different path.
    private func buildConsumerBlock(on producer: Block, transferCount: Int, salt: String, fetcher: Fetcher) async throws -> Block {
        var transactions: [Transaction] = []
        for i in 0..<transferCount {
            let owner = "consumer-\(salt)-\(i)-\(UUID().uuidString)"
            let action = AccountAction(owner: owner, delta: Int64(5000 + i))
            let body = TransactionBody(
                accountActions: [action], actions: [], depositActions: [],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 0, nonce: 0
            )
            let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
            transactions.append(Transaction(signatures: [owner: "consumer"], body: bodyHeader))
        }
        return try await BlockBuilder.buildBlock(
            previous: producer,
            transactions: transactions,
            timestamp: producer.timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )
    }

    /// The REAL node store path for a BLOCK closure (mirror `collectBlockVolumes`).
    private func collectBlockVolumes(
        _ block: Block,
        blockHash: String,
        broker: any VolumeBroker
    ) throws -> (volumes: [SerializedVolume], roots: [String]) {
        let storer = BrokerStorer(broker: broker)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: blockHash)
        return (volumes, storer.storedRoots)
    }

    /// The full owned STATE-trie node-set of a block's postState frontier. We
    /// serialize the postState through the SAME `BrokerStorer` +
    /// `storeRecursively` + `collectVolumes` path as `collectStateVolumes`, then
    /// take the UNION of every serialized volume's entry CIDs — i.e. EVERY
    /// individual trie node CID owned by the state, not just the volume-boundary
    /// roots (`storedRoots` lists only the bracketed boundaries). `block.postState`
    /// is a materialized `LatticeStateHeader` (= `VolumeImpl<LatticeState>`)
    /// straight out of `BlockBuilder`, so no fetch is needed.
    ///
    /// Returns (nodeSet, volumeRoots) so callers can also see the per-boundary
    /// granularity the production pin path actually pins.
    private func stateNodeSet(_ block: Block) throws -> (nodes: Set<String>, volumeRoots: Set<String>) {
        let storer = BrokerStorer(broker: MemoryBroker())
        try block.postState.storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: block.postState.rawCID)
        var nodes: Set<String> = []
        for v in volumes { nodes.formUnion(v.entries.keys) }
        return (nodes, Set(storer.storedRoots))
    }

    // MARK: - Diff-model bookkeeping

    /// Per-node lifetime derived purely from the diff model.
    private struct Lifetime {
        var birth: UInt64           // first height whose created introduced it
        var death: UInt64?          // first height (>birth) whose REPLACED dropped its path; nil = survives to tip
        var rebirths: [UInt64] = [] // later heights that re-created it (re-introduction)
    }

    // MARK: - TEST 1 — diff-driven death == reachability ground truth, all nodes, all floors

    func testDiffDrivenDeathMatchesReachabilityGroundTruthAcrossAChain() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()

        // 1. Chain G(0) -> B1(1) -> B2(2) -> B3(3). Each transition credits FRESH
        //    owners so the accounts trie branches+mutates and every postState
        //    differs (verified below).
        let g  = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: fetcher)
        let b1 = try await buildConsumerBlock(on: g,  transferCount: 3, salt: "h1", fetcher: fetcher)
        let b2 = try await buildConsumerBlock(on: b1, transferCount: 3, salt: "h2", fetcher: fetcher)
        let b3 = try await buildConsumerBlock(on: b2, transferCount: 3, salt: "h3", fetcher: fetcher)
        let chain = [g, b1, b2, b3]

        // Every postState must be distinct (real mutation each height).
        let postCIDs = chain.map { $0.postState.rawCID }
        XCTAssertEqual(Set(postCIDs).count, chain.count,
            "each transition must produce a DISTINCT postState; got \(postCIDs)")

        // 2. Per-block STATE node-sets (trie owned roots) at each height.
        var nodeSetAt: [UInt64: Set<String>] = [:]
        for (h, blk) in chain.enumerated() {
            nodeSetAt[UInt64(h)] = try stateNodeSet(blk).nodes
        }
        let heights = chain.indices.map { UInt64($0) }
        let tip = heights.last!

        // 3. DIFF MODEL: created(i) / replaced(i) via trie set-difference, then
        //    assign BIRTH / DEATH / rebirths per node.
        var created: [UInt64: Set<String>] = [:]   // created AT height h (vs h-1)
        var replaced: [UInt64: Set<String>] = [:]  // replaced going h-1 -> h
        created[0] = nodeSetAt[0]!                  // genesis: all nodes are born
        for h in heights.dropFirst() {
            let prev = nodeSetAt[h - 1]!
            let cur  = nodeSetAt[h]!
            created[h]  = cur.subtracting(prev)
            replaced[h] = prev.subtracting(cur)     // dropped going (h-1) -> h
        }

        // Build lifetimes. BIRTH = first height whose created contains the node.
        // A node "replaced" at the (h-1 -> h) transition was last referenced by
        // h-1, so its diff DEATH = h. Re-creation at a later height re-births it.
        var lifetime: [String: Lifetime] = [:]
        for h in heights {
            for cid in created[h]! {
                if lifetime[cid] == nil {
                    lifetime[cid] = Lifetime(birth: h, death: nil)
                } else {
                    // Re-introduction: same CID reappears after having been dropped.
                    lifetime[cid]!.rebirths.append(h)
                    // It is alive again; clear any earlier-recorded death — the
                    // "last contiguous reference" notion is wrong here and the
                    // membership-based recompute below is the source of truth.
                    lifetime[cid]!.death = nil
                }
            }
            for cid in (replaced[h] ?? []) {  // height 0 has no inbound transition
                // Record death only if not subsequently re-created (handled by the
                // membership recompute). Provisional: dropped going (h-1)->h.
                if var lt = lifetime[cid], lt.death == nil {
                    lt.death = h
                    lifetime[cid] = lt
                }
            }
        }

        // Snapshot the death as produced PURELY by the `replaced`-set model (the
        // exact mechanism the design proposes: deathHeight = the transition height
        // whose `replaced` dropped the node's path). We compare this to the
        // membership-canonical death below — in a chain with NO re-introduction
        // they must be identical, which proves the `replaced`-set model itself
        // (not just the membership recompute) is the thing matching reachability.
        let replacedSetDeath: [String: UInt64?] = lifetime.mapValues { $0.death }

        // CANONICAL diff-death from membership (handles re-introduction +
        // structural sharing exactly): a node's DEATH is one past the LAST height
        // whose node-set contains it. nil (never) if it lives at the tip.
        // This is the verdict the production death index must converge to.
        func lastReferencingHeight(_ cid: String) -> UInt64? {
            var last: UInt64? = nil
            for h in heights where nodeSetAt[h]!.contains(cid) { last = h }
            return last
        }
        for cid in lifetime.keys {
            if let last = lastReferencingHeight(cid) {
                lifetime[cid]!.death = (last == tip) ? nil : last + 1
            }
        }

        // The `replaced`-set death must equal the membership-canonical death for
        // EVERY node (this real chain has no exact-CID re-introduction — Test 2
        // covers that case). If these diverge, the `replaced`-set mechanism is NOT
        // a faithful death oracle on its own.
        var deathModelMismatches: [String] = []
        for (cid, lt) in lifetime {
            let viaReplaced = replacedSetDeath[cid] ?? nil
            if viaReplaced != lt.death {
                deathModelMismatches.append("cid=\(String(cid.prefix(16)))… replacedSetDeath=\(String(describing: viaReplaced)) membershipDeath=\(String(describing: lt.death))")
            }
        }
        XCTAssertTrue(deathModelMismatches.isEmpty, """
        The `replaced`-set death model diverged from the membership-canonical death on a
        chain with NO re-introduction — the proposed deathHeight mechanism is not faithful:
        \(deathModelMismatches.prefix(15).joined(separator: "\n"))
        """)

        // Sanity: the diff bookkeeping covered EXACTLY the union of all node-sets.
        let allNodes = heights.reduce(into: Set<String>()) { $0.formUnion(nodeSetAt[$1]!) }
        XCTAssertEqual(Set(lifetime.keys), allNodes,
            "every state node across the chain must have a diff lifetime; missing=\(allNodes.subtracting(Set(lifetime.keys)).prefix(5))")

        // 4. REACHABILITY GROUND TRUTH. Store every block's full closure into ONE
        //    DiskBroker. Pin the object-roots [blockHash, postState] per block —
        //    the design's "non-state stays object-grain, state pinned per-node"
        //    is cross-checked here against the WHOLE object-grain closure pins
        //    (the proven oracle), which is the strongest available ground truth.
        var blockHashAt: [UInt64: String] = [:]
        for (h, blk) in chain.enumerated() {
            let bh = try VolumeImpl<Block>(node: blk).rawCID
            blockHashAt[UInt64(h)] = bh
            let (vols, _) = try collectBlockVolumes(blk, blockHash: bh, broker: disk)
            try await network.storeVolumesDurably(vols)
        }

        // Pin each block's object roots under its height-owner.
        for h in heights {
            let bh = blockHashAt[h]!
            let ps = chain[Int(h)].postState.rawCID
            try await network.pinBatchDurably(roots: [bh, ps], owner: "Nexus:\(h)")
        }

        // 5. THE CROSS-CHECK. Slide the retention FLOOR over every position
        //    0...tip+1. floor F means: every block with height < F has been
        //    pruned (its height-owner unpinned); blocks height >= F stay retained.
        //
        //    DIFF verdict (reclaimable): node is dead once all blocks < death are
        //    gone, i.e. reclaimable iff death != nil && floor >= death  (floor has
        //    passed death-1, the last referencing height). A live-at-tip node
        //    (death == nil) is never reclaimable while the tip is retained.
        //
        //    REACHABILITY verdict (reclaimable): !isPinReachable from the retained
        //    pins.
        //
        //    They must AGREE for every node at every floor.
        //
        //    Floor range is 0...tip: the retention floor is ALWAYS <= tip — a node
        //    never prunes the tip block it is building on. The diff model's
        //    "death == nil => never reclaimable" is, by the design's own wording,
        //    conditioned on "while the tip is retained"; pruning the tip (floor =
        //    tip+1) is outside the operating regime and is checked separately below
        //    as a sanity boundary, not as a model-equivalence point.
        struct Disagreement { let cid: String; let floor: UInt64; let diffReclaimable: Bool; let reachReclaimable: Bool; let birth: UInt64; let death: UInt64? }
        var disagreements: [Disagreement] = []

        for floor in 0...tip {
            // Advance the floor: unpin every height strictly below `floor`.
            // (Re-running unpinAll for already-unpinned owners is harmless.)
            for h in heights where h < floor {
                try await network.unpinAllDurably(owner: "Nexus:\(h)")
            }

            for (cid, lt) in lifetime {
                let diffReclaimable: Bool = {
                    guard let d = lt.death else { return false } // survives to tip
                    return floor >= d
                }()
                let reachReclaimable = !(await disk.isPinReachable(cid: cid))
                if diffReclaimable != reachReclaimable {
                    disagreements.append(Disagreement(
                        cid: cid, floor: floor,
                        diffReclaimable: diffReclaimable,
                        reachReclaimable: reachReclaimable,
                        birth: lt.birth, death: lt.death))
                }
            }
        }

        print("[StateDeathProof] chain heights = \(heights), tip = \(tip)")
        print("[StateDeathProof] total distinct state nodes = \(allNodes.count)")
        print("[StateDeathProof] nodes-per-height = \(heights.map { (h: $0, n: nodeSetAt[$0]!.count) })")
        print("[StateDeathProof] nodes that survive to tip (death==nil) = \(lifetime.values.filter { $0.death == nil }.count)")
        print("[StateDeathProof] nodes with a finite death = \(lifetime.values.filter { $0.death != nil }.count)")
        print("[StateDeathProof] floors checked = 0...\(tip) (in-regime; tip always retained)")
        print("[StateDeathProof] disagreements = \(disagreements.count)")

        if !disagreements.isEmpty {
            let detail = disagreements.prefix(25).map {
                "cid=\(String($0.cid.prefix(16)))… floor=\($0.floor) birth=\($0.birth) death=\(String(describing: $0.death)) diffReclaimable=\($0.diffReclaimable) reachReclaimable=\($0.reachReclaimable)"
            }.joined(separator: "\n")
            XCTFail("""
            DESIGN-INVALIDATING FINDING: the diff-driven death model DISAGREES with the
            proven reachability ground truth for \(disagreements.count) (node, floor) pairs.
            The diff-driven retention redesign (state-retention-diff-death-design.md) would
            \(disagreements.contains { $0.diffReclaimable && !$0.reachReclaimable } ? "EVICT LIVE STATE (consensus break)" : "LEAK dead state")
            for at least one node. The diff model is NOT equivalent to reachability and must
            NOT be adopted as specified. First \(min(25, disagreements.count)) disagreements:
            \(detail)
            """)
        }

        // Positive control: the cross-check must have EXERCISED both verdicts —
        // some nodes reclaimable at some floor, some never — else it is vacuous.
        let everReclaimableByDiff = lifetime.values.contains { $0.death != nil }
        XCTAssertTrue(everReclaimableByDiff,
            "vacuous proof guard: at least one node must DIE within the chain (finite death) so the reclaim path is exercised")
        // And the in-regime cross-check must have observed at least one ACTUAL
        // reclaim (a node that reachability reports gone at some in-regime floor),
        // not merely "everything stays alive" — otherwise the agreement is trivial.
        var sawAReclaimInRegime = false
        for floor in 0...tip {
            for h in heights where h < floor { try await network.unpinAllDurably(owner: "Nexus:\(h)") }
            for (cid, _) in lifetime where !(await disk.isPinReachable(cid: cid)) { sawAReclaimInRegime = true; break }
            if sawAReclaimInRegime { break }
        }
        XCTAssertTrue(sawAReclaimInRegime,
            "non-vacuous guard: at least one node must become reachability-reclaimable at an in-regime floor")

        // BOUNDARY sanity (out of regime): pruning the tip too (floor = tip+1)
        // unpins everything, so reachability reclaims ALL nodes. The diff model
        // would only agree here once you also retire the tip — consistent, but
        // outside the "tip always retained" operating regime, so asserted as a
        // boundary fact, not a model-equivalence point.
        for h in heights { try await network.unpinAllDurably(owner: "Nexus:\(h)") }
        var anyStillReachable = false
        for cid in allNodes where await disk.isPinReachable(cid: cid) { anyStillReachable = true; break }
        XCTAssertFalse(anyStillReachable,
            "boundary: with the tip itself pruned, no state node may remain pin-reachable")
    }

    // MARK: - TEST 2 — re-introduction self-heals (same CID dies then is re-born)

    func testReintroductionSelfHeals() async throws {
        // We assert the re-introduction PRINCIPLE on the membership-faithful diff
        // model directly, using a minimal synthetic lifetime trace, because an
        // exact-CID re-introduction is content-address-rare and not reliably
        // constructible with the available account builders (each credit mints a
        // FRESH random owner, so an identical prior trie node almost never recurs).
        // The principle being proven: DEATH must be the LAST referencing height,
        // NOT the first contiguous drop — otherwise re-introduced nodes are wrongly
        // reclaimed. (Limitation noted: synthetic CIDs, real trie wiring is covered
        // by Test 1's membership recompute which already handles re-introduction.)
        let heights: [UInt64] = [0, 1, 2, 3, 4]

        // Node X: born@0, dropped going 1->2 (replaced@2), RE-CREATED@4 (same CID
        // returns — e.g. a balance reverting to a prior exact value).
        let X = "X-reintroduced-node"
        let nodeSet: [UInt64: Set<String>] = [
            0: [X, "a"],
            1: [X, "b"],
            2: ["c"],        // X dropped here
            3: ["d"],
            4: [X, "e"],     // X re-created here
        ]

        // Diff-model "first contiguous drop" death (the WRONG, naive notion).
        // X is replaced going 1->2, so naive death = 2.
        func naiveContiguousDeath(_ cid: String) -> UInt64? {
            var born = false
            for h in heights {
                let present = nodeSet[h]!.contains(cid)
                if present { born = true }
                else if born { return h } // first drop after birth
            }
            return nil
        }
        // Membership-faithful death = one past the LAST referencing height.
        func lastReferencingHeight(_ cid: String) -> UInt64? {
            var last: UInt64? = nil
            for h in heights where nodeSet[h]!.contains(cid) { last = h }
            return last
        }
        let tip = heights.last!
        func healedDeath(_ cid: String) -> UInt64? {
            guard let last = lastReferencingHeight(cid) else { return nil }
            return last == tip ? nil : last + 1
        }

        let naive = naiveContiguousDeath(X)
        let healed = healedDeath(X)
        print("[StateDeathProof][reintro] X naive-contiguous death = \(String(describing: naive)), healed death = \(String(describing: healed))")

        // The naive contiguous-death model declares X dead at 2.
        XCTAssertEqual(naive, 2, "naive contiguous-drop death must fire at the first drop (height 2)")

        // X is re-created at 4 (== tip), so it is ALIVE at the tip: healed death is nil.
        XCTAssertTrue(nodeSet[4]!.contains(X), "re-introduction precondition: X reappears at height 4")
        XCTAssertNil(healed, "re-introduced X lives at the tip → healed death must be nil (never reclaimable while tip retained)")

        // THE BUG the model must avoid: using the naive death (2) would declare X
        // reclaimable once floor >= 2, but X is genuinely referenced again at 4 →
        // that would EVICT LIVE STATE. The healed/self-healing model (death = last
        // reference) does not. Demonstrate the divergence explicitly at floor 3.
        let floor: UInt64 = 3
        let naiveReclaimable = naive.map { floor >= $0 } ?? false
        let healedReclaimable = healed.map { floor >= $0 } ?? false
        XCTAssertTrue(naiveReclaimable,
            "naive model WOULD reclaim X at floor 3 (death=2) — the latent bug")
        XCTAssertFalse(healedReclaimable,
            "self-healing model must NOT reclaim X at floor 3 — it is referenced again at height 4")

        // Demonstrate re-birth via the production `created`/`replaced` set-difference
        // bookkeeping too: created(4) must contain X (its re-birth), proving the
        // birth delta re-stores it (the design's self-heal mechanism).
        let created4 = nodeSet[4]!.subtracting(nodeSet[3]!)
        XCTAssertTrue(created4.contains(X),
            "created(4) must re-introduce X (re-birth pins it again) — the diff self-heal")
    }

    // MARK: - TEST 3 — created(N+1) is the BIRTH DELTA, not the full frontier

    func testCreatedIsTheBirthDeltaNotTheFullFrontier() async throws {
        let fetcher = cas()
        // A large genesis frontier, then a SMALL single-credit consumer block.
        let g  = try await buildMultiVolumeGenesis(accountCount: 16, fetcher: fetcher)
        let b1 = try await buildConsumerBlock(on: g, transferCount: 1, salt: "delta", fetcher: fetcher)

        let frontierG  = try stateNodeSet(g).nodes
        let frontierB1 = try stateNodeSet(b1).nodes
        XCTAssertNotEqual(g.postState.rawCID, b1.postState.rawCID,
            "the small transfer must still mutate state (distinct postState)")

        let created = frontierB1.subtracting(frontierG)   // birth delta at B1
        let replaced = frontierG.subtracting(frontierB1)  // death delta at B1
        let fullFrontier = frontierB1.count

        print("[StateDeathProof][delta] |postState_G| = \(frontierG.count)")
        print("[StateDeathProof][delta] |postState_B1| (full frontier) = \(fullFrontier)")
        print("[StateDeathProof][delta] created(B1) (birth delta) = \(created.count)")
        print("[StateDeathProof][delta] replaced(B1) (death delta) = \(replaced.count)")
        print("[StateDeathProof][delta] birth delta / full frontier = \(Double(created.count) / Double(fullFrontier))")

        // The perf claim: birth pins the DELTA (O(changed)), not the whole frontier
        // (O(frontier)). For a single-credit mutation the delta must be a small
        // fraction of the frontier — strictly less than half, and in practice a
        // handful of nodes (the touched root-to-leaf path).
        XCTAssertGreaterThan(created.count, 0, "a real mutation must create at least one new node")
        XCTAssertLessThan(created.count, fullFrontier,
            "birth delta must be SMALLER than the full frontier (O(delta) not O(frontier))")
        XCTAssertLessThan(Double(created.count), Double(fullFrontier) / 2.0,
            "for a single small credit, the birth delta must be much smaller than the full frontier; got created=\(created.count) frontier=\(fullFrontier)")
    }
}
