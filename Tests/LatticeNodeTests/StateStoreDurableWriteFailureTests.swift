import XCTest
import Foundation
import VolumeBroker
@testable import Lattice
@testable import LatticeNode
import Lattice

/// peripheral StateStore writes must surface durable-write failures to
/// the caller (no silent `try?` swallow), the shared `transaction {}` helper
/// must bound-retry `SQLITE_BUSY`, and `SQLiteDatabase` must checkpoint-truncate
/// the WAL on close. These tests fail (RED) on origin/main and pass with the fix.
final class StateStoreDurableWriteFailureTests: XCTestCase {

    private func makeStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try StateStore(storagePath: dir, chain: "Nexus")
        return (store, dir)
    }

    private func makePaths() -> (dbPath: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("t.db").path, dir)
    }

    // MARK: - 1. Every peripheral write propagates failure

    /// With the write-fault seam armed, each peripheral write must throw rather
    /// than silently return as success. Each call re-arms the seam (it consumes
    /// itself on the first write statement).
    func testPeripheralWritesPropagateFailure() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.indexTransaction(address: "a", txCID: "t", blockHash: "b", height: 1) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.setGeneral(key: "k", value: Data([0x01]), atHeight: 1) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.persistBlockProof(height: 1, blockHash: "h", proofID: "p", proof: Data([0x02])) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.deleteBlockProofs(height: 1) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.deleteBlockProof(height: 1, blockHash: "h") }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.persistParentHeader(parentHash: "p", previousHash: nil, height: 1) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.persistValidatorPin(height: 1, childCID: "c", parentCID: "p") }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.deleteValidatorPins(height: 1) }

        await store._armWriteFault()
        await assertThrowsAsync {
            try await store.batchIndexReceipts(
                generalEntries: [(key: "g", value: Data([0x03]), height: 1)],
                txHistory: [(address: "a", txCID: "t", blockHash: "b", height: 1)]
            )
        }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.deleteReceiptsForOrphanedTxCIDs(["cid"]) }
    }

    // MARK: - 1b. Remaining peripheral writes propagate failure

    /// the peripheral writes left out of the durable-write locus must also
    /// surface durable-write failure instead of `try?`-swallowing it.
    func testRemainingPeripheralWritesPropagateFailure() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.persistStoredRoots(height: 1, roots: ["r1"]) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.deleteStoredRoots(height: 1) }

        await store._armWriteFault()
        await assertThrowsAsync { try await store.persistChildParentAnchor(childHash: "c", parentHash: "p", height: 1) }

        await store._armWriteFault()
        await assertThrowsAsync { _ = try await store.pruneTransactionHistory(belowHeight: 5, keepAddress: "me") }
    }

    // MARK: - 2. Happy path survives, including restart

    func testHealthyWritesSucceedAndSurviveRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let store = try StateStore(storagePath: dir, chain: "Nexus")

            // Validator pin write + delete is observable in-process.
            try await store.persistValidatorPin(height: 5, childCID: "child", parentCID: "parent")
            XCTAssertEqual(store.getValidatorParent(childCID: "child"), "parent")
            try await store.deleteValidatorPins(height: 5)
            XCTAssertTrue(store.getValidatorPins(height: 5).isEmpty)

            // Receipt index + general metadata persisted for the restart check.
            try await store.batchIndexReceipts(
                generalEntries: [(key: "meta-x", value: Data("hello".utf8), height: 7)],
                txHistory: [(address: "alice", txCID: "tx7", blockHash: "blk7", height: 7)]
            )
            try await store.setGeneral(key: "standalone", value: Data("world".utf8), atHeight: 7)
        } // close: deinit checkpoints + closes the connections

        // Reopen the same path: the rows must still be present.
        let reopened = try StateStore(storagePath: dir, chain: "Nexus")
        XCTAssertEqual(reopened.getGeneral(key: "meta-x"), Data("hello".utf8))
        XCTAssertEqual(reopened.getGeneral(key: "standalone"), Data("world".utf8))
        let hist = reopened.getTransactionHistory(address: "alice")
        XCTAssertEqual(hist.count, 1)
        XCTAssertEqual(hist.first?.txCID, "tx7")
    }

    // MARK: - 3. Bounded BUSY retry

    /// Two transient BUSY faults (within the 3-attempt bound) must be retried
    /// and the transaction must ultimately commit. Uses the deterministic
    /// busy-fault seam so the retry loop is exercised directly rather than via
    /// `busy_timeout`, which would absorb a real short-lived lock.
    func testBusyRetryThenSucceeds() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE tx_history (address TEXT, txCID TEXT, blockHash TEXT, height INTEGER, PRIMARY KEY (address, txCID))")

        db._armBusyFault(times: 2) // first two write attempts throw BUSY, third succeeds
        _ = try db.transaction {
            try db.execute("INSERT INTO tx_history (address, txCID, blockHash, height) VALUES ('y','retried','b2',2)")
        }

        let rows = try db.query("SELECT txCID FROM tx_history WHERE address = 'y'")
        XCTAssertEqual(rows.first?["txCID"]?.textValue, "retried")
    }

    /// BUSY beyond the retry bound (4 faults vs 3 attempts) must surface, not
    /// silently drop the write.
    func testBusyBeyondBoundSurfaces() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE tx_history (address TEXT, txCID TEXT, blockHash TEXT, height INTEGER, PRIMARY KEY (address, txCID))")

        db._armBusyFault(times: 4)
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO tx_history (address, txCID, blockHash, height) VALUES ('z','dropped','b3',3)")
        }) { error in
            guard case SQLiteError.busy = error else {
                return XCTFail("expected SQLiteError.busy, got \(error)")
            }
        }
        let rows = try db.query("SELECT COUNT(*) AS c FROM tx_history WHERE address = 'z'")
        XCTAssertEqual(rows.first?["c"]?.intValue, 0)
    }

    // MARK: - 3b. Validator-pin retry through production prune

    func testValidatorPinReleaseRetryLedgerThroughAcceptedBlockPruneAfterRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let kp = CryptoUtils.generateKeyPair()
        let genesis = testGenesis()
        let storagePath = dir.appendingPathComponent("node")
        let retentionDepth: UInt64 = 1
        let childCID = "child-production-prune"
        let parentCID = "parent-production-prune"
        let owner = "validates:\(childCID)"

        func makeNode(port: UInt16) async throws -> LatticeNode {
            let config = LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: port,
                storagePath: storagePath,
                enableLocalDiscovery: false,
                retentionDepth: retentionDepth,
                blockRetention: .retention, minPeerKeyBits: 0
            )
            return try await LatticeNode(config: config, genesisConfig: genesis)
        }

        do {
            let node = try await makeNode(port: nextTestPort())
            do {
                try await mineBlocks(1, on: node)

                guard let chain = await node.chain(for: "Nexus"),
                      let store = await node.stateStore(for: "Nexus"),
                      let network = await node.network(for: "Nexus") else {
                    XCTFail("missing nexus chain/store/network")
                    await node.stop()
                    return
                }
                let heightAfterSetup = await chain.getHighestBlockHeight()
                XCTAssertEqual(heightAfterSetup, 1)

                try await store.persistValidatorPin(height: 1, childCID: childCID, parentCID: parentCID)
                let diskBroker = await network.diskBroker
                try await diskBroker.pin(root: parentCID, owner: owner)

                await node.installValidatorPinReleaserForTesting(FailingValidatorPinReleaser())

                let acceptedDuringFailure = await node.produceAndSubmitBlock(timestampOverride: now())
                XCTAssertTrue(acceptedDuringFailure, "block acceptance should not roll back after durable storage when prune cleanup fails")
                let heightAfterFailure = await chain.getHighestBlockHeight()
                XCTAssertEqual(heightAfterFailure, 2, "failed prune cleanup must not hide the accepted block")
                XCTAssertEqual(store.getValidatorParent(childCID: childCID), parentCID)
                let ownersAfterFailure = await diskBroker.owners(root: parentCID)
                XCTAssertTrue(ownersAfterFailure.contains(owner))
            } catch {
                await node.stop()
                throw error
            }
            await node.stop()
        }

        do {
            let reopenedAfterFailure = try StateStore(storagePath: storagePath, chain: "Nexus")
            XCTAssertEqual(
                reopenedAfterFailure.getValidatorParent(childCID: childCID),
                parentCID,
                "failed production prune must leave validator_pins durable across a store reopen"
            )
            let reopenedBrokerAfterFailure = try DiskBroker(path: storagePath.appendingPathComponent("volumes.sqlite").path)
            let reopenedOwnersAfterFailure = await reopenedBrokerAfterFailure.owners(root: parentCID)
            XCTAssertTrue(
                reopenedOwnersAfterFailure.contains(owner),
                "failed production prune must leave the broker owner durable across a broker reopen"
            )
        }

        do {
            let restarted = try await makeNode(port: nextTestPort())
            do {
                guard let restartedStore = await restarted.stateStore(for: "Nexus"),
                      let restartedNetwork = await restarted.network(for: "Nexus") else {
                    XCTFail("missing restarted nexus store/network")
                    await restarted.stop()
                    return
                }
                let restartedBroker = await restartedNetwork.diskBroker
                XCTAssertEqual(
                    restartedStore.getValidatorParent(childCID: childCID),
                    parentCID,
                    "failed production prune must leave validator_pins as the restart retry ledger"
                )
                let restartedOwnersAfterFailure = await restartedBroker.owners(root: parentCID)
                XCTAssertTrue(
                    restartedOwnersAfterFailure.contains(owner),
                    "failed production prune must leave the broker owner for retry after restart"
                )

                try await mineBlocks(2, on: restarted)

                XCTAssertNil(restartedStore.getValidatorParent(childCID: childCID))
                let ownersAfterRetry = await restartedBroker.owners(root: parentCID)
                XCTAssertFalse(
                    ownersAfterRetry.contains(owner),
                    "successful production prune retry must clear the broker owner"
                )
            } catch {
                await restarted.stop()
                throw error
            }
            await restarted.stop()
        }
    }

    // MARK: - 3. Transaction-bodied failure rolls back (no partial write)

    func testFailedBatchIndexLeavesNoPartialRows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store._armWriteFault()
        await assertThrowsAsync {
            try await store.batchIndexReceipts(
                generalEntries: [(key: "g1", value: Data([0x01]), height: 1)],
                txHistory: [(address: "a", txCID: "t", blockHash: "b", height: 1)]
            )
        }
        XCTAssertNil(store.getGeneral(key: "g1"), "failed batch must roll back, leaving no partial row")
        XCTAssertTrue(store.getTransactionHistory(address: "a").isEmpty)

        try await store.indexTransaction(address: "a", txCID: "t2", blockHash: "b", height: 2)
        XCTAssertEqual(store.getTransactionHistory(address: "a").first?.txCID, "t2")
    }

    // MARK: - 4. WAL is checkpoint-truncated on close

    func testCloseTruncatesWAL() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let walPath = path + "-wal"

        do {
            let db = try SQLiteDatabase(path: path)
            try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")
            // Grow the WAL: many writes without an explicit checkpoint.
            let blob = Data(repeating: 0xAB, count: 4096)
            try db.beginTransaction()
            for i in 0..<500 {
                try db.execute("INSERT INTO t (id, v) VALUES (?1, ?2)", params: [.int(Int64(i)), .blob(blob)])
            }
            try db.commit()
            // Sanity: the WAL has material before close (otherwise the test is vacuous).
            let walSize = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0
            XCTAssertGreaterThan(walSize, 0, "expected a non-empty WAL before close")
        } // deinit -> wal_checkpoint(TRUNCATE) + close

        // After close, the WAL must be absent or 0 bytes.
        if FileManager.default.fileExists(atPath: walPath) {
            let size = (try FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0
            XCTAssertEqual(size, 0, "WAL must be truncated to 0 bytes on close")
        }
    }

    // MARK: - Helpers

    private struct FailingValidatorPinReleaser: LatticeNode.ValidatorPinReleaser {
        struct InjectedUnpinFailure: Error {}
        func unpinAllBatch(owners: [String]) async throws {
            throw InjectedUnpinFailure()
        }
    }

    private func assertThrowsAsync(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected the peripheral write to throw", file: file, line: line)
        } catch {
            // expected
        }
    }
}
