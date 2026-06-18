import XCTest
@testable import LatticeNode

private actor ReorgMetaProbe {
    private let metas: [String: LatticeNode.ReorgWalkMeta]
    private var requested: [String] = []

    init(metas: [String: LatticeNode.ReorgWalkMeta]) {
        self.metas = metas
    }

    func resolve(_ hash: String) -> LatticeNode.ReorgWalkMeta? {
        requested.append(hash)
        return metas[hash]
    }

    func requestedHashes() -> [String] {
        requested
    }
}

/// S3: `retentionDepth` is a consensus-safety parameter, not just a storage
/// knob. A reorg deeper than `retentionDepth` cannot have its orphan set
/// correctly identified — we'd walk the retention window worth of old-tip
/// ancestors and still not hit the common ancestor, silently proceeding
/// with a truncated orphan list that corrupts mempool recovery and child-
/// chain rollback.
///
/// These tests pin the two halves of that contract:
///   1. When the fork is shallower than `retentionDepth`, the walk finds
///      the common ancestor and emits the correct orphan set.
///   2. When the fork exceeds `retentionDepth`, `foundCommonAncestor`
///      stays false so the caller refuses recovery (logged ERROR; caller
///      returns rather than acting on partial data).
final class ReorgRetentionBoundTests: XCTestCase {

    /// Build a simple chain parent map as a dictionary: child hash → parent hash.
    /// Returns a resolveParent closure that reads from it.
    private func parentResolver(
        _ parents: [String: String]
    ) -> (String) async -> String? {
        return { hash in parents[hash] }
    }

    func testShallowReorgFindsCommonAncestor() async {
        // Common history: G → A → B
        // Old chain: G → A → B → X1 → X2
        // New chain: G → A → B → Y1 → Y2 → Y3
        // Common ancestor: B. Depth from oldTip (X2) to B = 2. retentionDepth = 10.
        let parents = [
            "A": "G", "B": "A",
            "X1": "B", "X2": "X1",
            "Y1": "B", "Y2": "Y1", "Y3": "Y2",
        ]
        let newChainHashes: Set<String> = ["Y3", "Y2", "Y1", "B", "A", "G"]

        let result = await LatticeNode.walkOrphansToCommonAncestor(
            oldTip: "X2",
            newChainHashes: newChainHashes,
            retentionDepth: 10,
            resolveParent: parentResolver(parents)
        )

        XCTAssertTrue(result.foundCommonAncestor, "common ancestor B is within retentionDepth=10")
        XCTAssertEqual(result.orphans, ["X2", "X1"], "exactly the orphan set between oldTip and B")
    }

    func testDeepReorgBeyondRetentionDepthReportsNoCommonAncestor() async {
        // Old chain: G → O1 → O2 → … → O10 (oldTip = O10)
        // New chain: G → N1 → N2 → … → N11 (forked at genesis)
        // retentionDepth = 3. We can only walk back 3 blocks from O10, which
        // reaches O7. The new chain in our window doesn't extend back to G,
        // so no common ancestor appears. The caller MUST refuse.
        var parents: [String: String] = [:]
        parents["O1"] = "G"
        for i in 2...10 { parents["O\(i)"] = "O\(i - 1)" }
        parents["N1"] = "G"
        for i in 2...11 { parents["N\(i)"] = "N\(i - 1)" }

        // newChainHashes is what `collectAncestors` would return with
        // limit=retentionDepth=3 starting from N11 — i.e., only {N11, N10, N9}.
        let newChainHashes: Set<String> = ["N11", "N10", "N9"]

        let result = await LatticeNode.walkOrphansToCommonAncestor(
            oldTip: "O10",
            newChainHashes: newChainHashes,
            retentionDepth: 3,
            resolveParent: parentResolver(parents)
        )

        XCTAssertFalse(
            result.foundCommonAncestor,
            "fork is deeper than retentionDepth=3 — must report no common ancestor so the caller refuses"
        )
        // Orphans is bounded at retentionDepth (the walk iterates at most that
        // many times); the exact contents matter less than the refusal signal.
        XCTAssertEqual(result.orphans.count, 3, "walk stops at retentionDepth iterations")
    }

    func testWalkTerminatesAtGenesisWithoutCommonAncestor() async {
        // Old chain is shorter than retentionDepth but the new chain's
        // retention window doesn't include genesis. Walk runs out of history
        // (no parent for "G") before hitting retention limit. Must still
        // report foundCommonAncestor=false so the caller refuses.
        let parents = ["A": "G", "B": "A"]
        let newChainHashes: Set<String> = ["N3", "N2", "N1"]

        let result = await LatticeNode.walkOrphansToCommonAncestor(
            oldTip: "B",
            newChainHashes: newChainHashes,
            retentionDepth: 100,
            resolveParent: parentResolver(parents)
        )

        XCTAssertFalse(result.foundCommonAncestor)
        XCTAssertEqual(result.orphans, ["B", "A", "G"])
    }

    func testBoundedWalkStopsAtActualForkDepthNotRetentionDepth() async {
        // Common history: G -> A -> B
        // Old chain: G -> A -> B -> X1 -> X2
        // New chain: G -> A -> B -> Y1 -> Y2 -> Y3
        let probe = ReorgMetaProbe(metas: [
            "G": LatticeNode.ReorgWalkMeta(parentBlockHash: nil, blockHeight: 0),
            "A": LatticeNode.ReorgWalkMeta(parentBlockHash: "G", blockHeight: 1),
            "B": LatticeNode.ReorgWalkMeta(parentBlockHash: "A", blockHeight: 2),
            "X1": LatticeNode.ReorgWalkMeta(parentBlockHash: "B", blockHeight: 3),
            "X2": LatticeNode.ReorgWalkMeta(parentBlockHash: "X1", blockHeight: 4),
            "Y1": LatticeNode.ReorgWalkMeta(parentBlockHash: "B", blockHeight: 3),
            "Y2": LatticeNode.ReorgWalkMeta(parentBlockHash: "Y1", blockHeight: 4),
            "Y3": LatticeNode.ReorgWalkMeta(parentBlockHash: "Y2", blockHeight: 5),
        ])

        let result = await LatticeNode.boundedReorgWalk(
            oldTip: "X2",
            newTip: "Y3",
            retentionDepth: 1_000
        ) { hash in
            await probe.resolve(hash)
        }

        XCTAssertTrue(result.foundCommonAncestor)
        XCTAssertEqual(result.orphaned, ["X2", "X1"])
        XCTAssertEqual(result.promoted.map(\.hash), ["Y3", "Y2", "Y1"])
        XCTAssertEqual(result.newChainHashes, ["Y3", "Y2", "Y1", "B"])

        let requested = await probe.requestedHashes()
        XCTAssertEqual(requested.count, 7, "two initial tip reads plus actual fork-depth parent reads")
        XCTAssertFalse(requested.contains("A"))
        XCTAssertFalse(requested.contains("G"))
    }
}
