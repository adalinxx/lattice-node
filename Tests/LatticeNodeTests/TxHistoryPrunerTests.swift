import XCTest
@testable import LatticeNode

/// P0 #4: tx_history table grows forever without a pruner. Foreign addresses
/// must be evictable below a retention window; the node's own address rows
/// must survive because startup pin rebuild depends on them.
final class TxHistoryPrunerTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try StateStore(storagePath: tmpDir, chain: "Nexus")
        return (store, tmpDir)
    }

    func testPruneDropsForeignRowsBelowHeight() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let me = "ownerSelf"
        let them = "ownerOther"

        try await store.indexTransaction(address: them, txCID: "tx1", blockHash: "b1", height: 10)
        try await store.indexTransaction(address: them, txCID: "tx2", blockHash: "b2", height: 100)
        try await store.indexTransaction(address: me,   txCID: "tx3", blockHash: "b3", height: 10)

        let removed = try await store.pruneTransactionHistory(belowHeight: 50, keepAddress: me)
        XCTAssertEqual(removed, 1, "only foreign row below threshold must be counted")

        let themHistory = store.getTransactionHistory(address: them)
        XCTAssertEqual(themHistory.count, 1, "tx1 should be gone; tx2 (>=50) stays")
        XCTAssertEqual(themHistory.first?.height, 100)

        // Own-address history must be untouched even if it's ancient — the
        // startup pin rebuild (rebuildAccountPinsFromTxHistory) walks all rows
        // for nodeAddress and an empty result would silently drop pin coverage.
        let myHistory = store.getTransactionHistory(address: me)
        XCTAssertEqual(myHistory.count, 1, "own rows must NEVER be pruned")
    }

    func testPruneBelowZeroIsNoop() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await store.indexTransaction(address: "x", txCID: "tx1", blockHash: "b", height: 5)
        let removed = try await store.pruneTransactionHistory(belowHeight: 0, keepAddress: "me")
        XCTAssertEqual(removed, 0, "zero threshold must be a no-op, not a full wipe")
        XCTAssertEqual(store.getTransactionHistory(address: "x").count, 1)
    }

    func testPruneIdempotent() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await store.indexTransaction(address: "x", txCID: "tx1", blockHash: "b", height: 5)
        _ = try await store.pruneTransactionHistory(belowHeight: 10, keepAddress: "me")
        let secondPass = try await store.pruneTransactionHistory(belowHeight: 10, keepAddress: "me")
        XCTAssertEqual(secondPass, 0, "rerunning after a prune must find nothing left")
    }
}
