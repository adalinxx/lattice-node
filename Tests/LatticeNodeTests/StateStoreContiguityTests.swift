import XCTest
@testable import LatticeNode

/// the backfill skip-check must gate on CONTIGUITY, not a bare
/// `COUNT(*)`. `block_index.height` is a PRIMARY KEY (no dupes), but nothing
/// deletes rows ABOVE the tip when an inherited-weight / reorg promotion lands a
/// strictly SHORTER canonical chain — a stale over-tip row inflates `COUNT(*)`
/// past `height + 1`. The old gate (`getBlockIndexCount() >= height + 1`) then
/// reads that inflated count as "complete" and skips the repair while an
/// interior height in `[0, height]` is still missing, so `getBlockHash(atHeight:
/// gap) == nil` persists and `isCanonicalRoot` fails closed at a height that is
/// in fact canonical.
///
/// The fix replaces the count gate with `isBlockIndexContiguous(throughHeight:)`,
/// true IFF `MAX(height) == throughHeight` AND `COUNT(*) == throughHeight + 1`.
final class StateStoreContiguityTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(storagePath: dir, chain: "Nexus"), dir)
    }

    func test_skipCheck_repairsInteriorGap_whenCountMasksIt() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build the exact masking shape from the AC: heights {0,1,3,4} then {5}.
        // Height 2 is absent; MAX(height)==5 (a stale over-tip row vs a tip of 4)
        // so COUNT(*)==5 == (4 + 1) — the old gate would read "complete".
        await store.backfillBlockIndex([
            (height: 0, blockHash: "h0"),
            (height: 1, blockHash: "h1"),
            (height: 3, blockHash: "h3"),
            (height: 4, blockHash: "h4"),
        ])
        await store.backfillBlockIndex([(height: 5, blockHash: "h5")])

        // --- PRE (RED on main): the old count gate would skip the repair. ---
        XCTAssertEqual(store.getBlockIndexCount(), 5)
        XCTAssertTrue(store.getBlockIndexCount() >= 4 + 1,
                      "the old `COUNT(*) >= height+1` gate is satisfied and would skip")
        XCTAssertNil(store.getBlockHash(atHeight: 2),
                     "yet height 2 is a real gap — getBlockHash returns nil")

        // The contiguity predicate correctly reports the gap, forcing the walk.
        XCTAssertFalse(store.isBlockIndexContiguous(throughHeight: 4),
                       "MAX(height)==5 (>4) and the interior gap means NOT contiguous")

        // --- POST (GREEN): the forced 0...height walk + INSERT-OR-REPLACE
        // backfill (what the production `backfillBlockIndex(directory:)` does
        // against the in-memory canonical chain) makes every height queryable. ---
        let repaired: [(height: UInt64, blockHash: String)] =
            (0...4).map { (height: $0, blockHash: "h\($0)") }
        await store.backfillBlockIndex(repaired)

        for i in UInt64(0)...4 {
            XCTAssertNotNil(store.getBlockHash(atHeight: i),
                            "after repair, height \(i) must be queryable")
        }
        // The interior gap is gone (every height in [0,4] is dense). The stale
        // over-tip row at 5 is intentionally OUT OF SCOPE for this AC (height
        // density only), so MAX(height)==5 keeps throughHeight:4 reporting
        // non-contiguous — which is exactly the signal that forces the walk.
        XCTAssertFalse(store.isBlockIndexContiguous(throughHeight: 4),
                       "the surviving over-tip row at 5 keeps MAX>4, so the gate still forces a walk (over-tip cleanup is out of scope)")
    }

    /// Clean-startup happy path (keep): a fully-populated contiguous index
    /// reports contiguous, so the production skip-check takes the O(1) path.
    func test_contiguousIndex_skipsRepair() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        await store.backfillBlockIndex((0...4).map { (height: $0, blockHash: "h\($0)") })

        XCTAssertTrue(store.isBlockIndexContiguous(throughHeight: 4),
                      "MAX==4 and COUNT==5 → contiguous, repair is safely skipped")
        // A bare empty table is not contiguous through any real height.
        let (empty, edir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: edir) }
        XCTAssertFalse(empty.isBlockIndexContiguous(throughHeight: 0),
                       "empty block_index is never contiguous through a real height")
    }

    func testParentStateEdgePersistenceIsIdempotent() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.persistParentStateEdge(fromRoot: "parent-a", toRoot: "parent-b")
        try await store.persistParentStateEdge(fromRoot: "parent-a", toRoot: "parent-b")

        XCTAssertTrue(store.hasParentStatePath(from: "parent-a", to: "parent-b"))

        let dbPath = dir.appendingPathComponent("Nexus").appendingPathComponent("state.db").path
        let db = try SQLiteDatabase(path: dbPath)
        let rows = try db.query(
            "SELECT COUNT(*) AS c FROM parent_state_edges WHERE from_root = ?1 AND to_root = ?2",
            params: [.text("parent-a"), .text("parent-b")]
        )
        XCTAssertEqual(
            rows.first?["c"]?.intValue,
            1,
            "duplicate parent_state_edges rows must be ignored at the storage boundary"
        )
    }
}
