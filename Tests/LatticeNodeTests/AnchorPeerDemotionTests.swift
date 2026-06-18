import XCTest
import Ivy
@testable import LatticeNode

/// S9: anchor peers must not be pinned into the bootstrap set forever.
/// A peer that goes Byzantine after it was first trusted has to be evictable
/// on a periodic cadence, and insertion has to be score-gated so the next
/// `update(peers:)` from the peer-refresh loop can't silently re-add it.
final class AnchorPeerDemotionTests: XCTestCase {

    private func endpoint(_ key: String, port: UInt16 = 30000) -> PeerEndpoint {
        PeerEndpoint(publicKey: key, host: "127.0.0.1", port: port)
    }

    private func makeAnchor() -> (AnchorPeers, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AnchorPeers(dataDir: dir), dir)
    }

    func testUpdateRejectsZeroReputationPeers() async {
        let (anchors, dir) = makeAnchor()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidates = [endpoint("good"), endpoint("bad")]
        let scoring: ReputationScoring = { $0.publicKey == "good" ? 1.0 : 0 }

        await anchors.update(peers: candidates, scoring: scoring)
        let saved = await anchors.current
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.publicKey, "good")
    }

    func testEvictLowScoringRemovesExistingAnchors() async {
        let (anchors, dir) = makeAnchor()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Seed: both peers insert with no scoring.
        await anchors.update(peers: [endpoint("a"), endpoint("b"), endpoint("c")])
        let beforeCount = await anchors.current.count
        XCTAssertEqual(beforeCount, 3)

        // Now "b" has gone Byzantine — eviction must drop exactly it.
        let scoring: ReputationScoring = { $0.publicKey == "b" ? -5.0 : 2.0 }
        let removed = await anchors.evictLowScoring(scoring: scoring)
        XCTAssertEqual(removed, 1)
        let after = await anchors.current.map { $0.publicKey }.sorted()
        XCTAssertEqual(after, ["a", "c"])
    }

    func testEvictLowScoringNoopWhenAllGood() async {
        let (anchors, dir) = makeAnchor()
        defer { try? FileManager.default.removeItem(at: dir) }
        await anchors.update(peers: [endpoint("a"), endpoint("b")])
        let scoring: ReputationScoring = { _ in 1.0 }
        let removed = await anchors.evictLowScoring(scoring: scoring)
        XCTAssertEqual(removed, 0, "well-reputed peers must survive eviction pass")
    }

    func testEvictionPersistsAcrossReload() async throws {
        // Regression guard: prior behavior only rewrote anchors.json from
        // `update(peers:)`. If eviction forgets to persist, the evicted peer
        // comes right back on next load().
        let (anchors, dir) = makeAnchor()
        defer { try? FileManager.default.removeItem(at: dir) }
        await anchors.update(peers: [endpoint("a"), endpoint("b")])
        _ = await anchors.evictLowScoring(scoring: { $0.publicKey == "b" ? -1.0 : 1.0 })

        let fresh = AnchorPeers(dataDir: dir)
        let loaded = await fresh.load().map { $0.publicKey }
        XCTAssertEqual(loaded, ["a"], "evicted peer must not resurrect from disk on reload")
    }
}
