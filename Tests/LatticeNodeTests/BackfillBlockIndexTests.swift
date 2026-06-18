import XCTest
@testable import LatticeNode

/// UNSTOPPABLE_LATTICE P1 #11: `backfillBlockIndex` re-walks the entire chain
/// on every start, looping `0...height` and paying a ChainState lookup per
/// index. Every `applyBlock` already writes its own (height, hash) row into
/// `block_index` atomically, so on any steady-state restart the table already
/// has `height+1` rows and the scan is pure overhead. The fix skips the scan
/// when `StateStore.getBlockIndexCount() >= height+1`.
///
/// These tests pin the contract that the skip relies on: after N applyBlock
/// calls the count equals N, and `backfillBlockIndex`'s INSERT OR REPLACE is
/// idempotent for identical rows (and overwrites stale ones — F5-4) so a
/// double-call never corrupts the table.
final class BackfillBlockIndexTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(storagePath: dir, chain: "Nexus"), dir)
    }

    func testApplyBlockPopulatesBlockIndexCount() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(store.getBlockIndexCount(), 0, "Fresh store must report zero block_index rows")

        for h in 0..<5 {
            await store.applyBlock(StateChangeset(
                height: UInt64(h),
                blockHash: "hash-\(h)",
                stateRoot: "root-\(h)"
            ))
        }

        // Steady-state invariant the skip relies on.
        XCTAssertEqual(store.getBlockIndexCount(), 5,
                       "After 5 applyBlock calls, block_index must have 5 rows — this is the signal backfillBlockIndex uses to skip the O(height) scan")
    }

    func testBackfillIsIdempotent() async throws {
        // Repeated backfills of identical rows must not duplicate (PRIMARY KEY on
        // height). The insert is INSERT OR REPLACE (F5-4: block_index is the durable
        // canonical commitment), which is idempotent for identical (height, hash).
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entries: [(height: UInt64, blockHash: String)] = (0..<10).map {
            (height: UInt64($0), blockHash: "hash-\($0)")
        }
        await store.backfillBlockIndex(entries)
        await store.backfillBlockIndex(entries)
        await store.backfillBlockIndex(entries)

        XCTAssertEqual(store.getBlockIndexCount(), 10,
                       "Triple backfill must not duplicate rows")
        XCTAssertEqual(store.getBlockHash(atHeight: 7), "hash-7")
    }

    func testBackfillReplacesStaleRow() async throws {
        // F5-4: block_index is the durable canonical main-chain commitment. A reorg or
        // sync reset can change which block is canonical at a height, so backfill must
        // OVERWRITE a stale row with the new canonical hash (INSERT OR REPLACE) — a
        // surviving stale row at a finalized height would bind a wrong PoW root in
        // isCanonicalRoot.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        await store.backfillBlockIndex([(height: 5, blockHash: "old-fork")])
        XCTAssertEqual(store.getBlockHash(atHeight: 5), "old-fork")

        await store.backfillBlockIndex([(height: 5, blockHash: "new-canonical")])
        XCTAssertEqual(store.getBlockHash(atHeight: 5), "new-canonical",
                       "backfill must overwrite a stale row with the canonical hash")
        XCTAssertEqual(store.getBlockIndexCount(), 1, "overwrite, not duplicate")
    }

    func testCommitCanonicalSegmentConnectsBelowKeepsLowerRows() async throws {
        // A connecting segment (extend/headers-first) rewrites its rows + tip and leaves
        // the canonical rows below it intact.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.backfillBlockIndex((1...5).map { (height: UInt64($0), blockHash: "h\($0)") })

        try await store.commitCanonicalSegment(CanonicalSegment(
            blocks: [CanonicalSegmentBlock(height: 6, hash: "h6", stateRoot: "sr6"),
                     CanonicalSegmentBlock(height: 7, hash: "h7", stateRoot: "sr7")],
            connectsBelow: true))

        XCTAssertEqual(store.getBlockHash(atHeight: 1), "h1", "rows below a connecting segment are kept")
        XCTAssertEqual(store.getBlockHash(atHeight: 7), "h7")
        XCTAssertEqual(store.getChainTip(), "h7", "tip marker moves with the segment")
        XCTAssertEqual(store.getHeight(), 7)
    }

    func testCommitCanonicalSegmentNonConnectingRewritesTipAndDeletesBelowInOneTx() async throws {
        // A non-connecting recovery/import segment (!connectsBelow) rewrites the
        // tip AND deletes the now-unverifiable rows below it in a SINGLE transaction,
        // so a crash can't leave the commitment split.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.backfillBlockIndex((1...5).map { (height: UInt64($0), blockHash: "old\($0)") })

        try await store.commitCanonicalSegment(CanonicalSegment(
            blocks: [CanonicalSegmentBlock(height: 9, hash: "newTip", stateRoot: "sr9")],
            connectsBelow: false))

        XCTAssertNil(store.getBlockHash(atHeight: 1), "below-tip unverifiable rows are dropped")
        XCTAssertNil(store.getBlockHash(atHeight: 5))
        XCTAssertEqual(store.getBlockHash(atHeight: 9), "newTip", "the synced tip row is written")
        XCTAssertEqual(store.getChainTip(), "newTip", "tip marker moves in the same commit")
        XCTAssertEqual(store.getHeight(), 9)
    }
}
