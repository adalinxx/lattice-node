import XCTest
import Ivy
@testable import LatticeNode

/// Module 6: persisted router candidates carry a provenance `source` tag and
/// peers.json written before Module 6 (no `source`) still loads.
final class PeerStoreSourceTests: XCTestCase {

    private func makeStore() -> (PeerStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (PeerStore(dataDir: dir), dir)
    }

    private func endpoint(_ key: String) -> PeerEndpoint {
        PeerEndpoint(publicKey: String(repeating: key, count: 64), host: "203.0.113.7", port: 40001)
    }

    func testSourceIsPersistedAndCandidatesRoundTrip() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peers = [endpoint("a"), endpoint("b")]
        await store.save(peers, source: "anchor")

        // The on-disk record carries the provenance tag.
        let raw = try String(contentsOf: dir.appendingPathComponent("peers.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"source\""))
        XCTAssertTrue(raw.contains("anchor"))

        // Candidates load back as endpoints.
        let loaded = await store.load()
        XCTAssertEqual(Set(loaded.map { $0.publicKey }), Set(peers.map { $0.publicKey }))
    }

    func testLoadsLegacyEntriesWithoutSource() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A pre-Module-6 peers.json has no `source` field.
        let legacy = """
        [{"publicKey":"\(String(repeating: "c", count: 64))","host":"198.51.100.3","port":40002}]
        """
        try legacy.write(to: dir.appendingPathComponent("peers.json"), atomically: true, encoding: .utf8)

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.host, "198.51.100.3")
    }
}
