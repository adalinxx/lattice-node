import XCTest
@testable import Lattice
@testable import LatticeNode
import Foundation
import cashew

/// P1 #6: `fetcherCache()` is hit on every miner round and per-gossip block
/// validation. The previous implementation re-walked every admitted tx and
/// re-serialized tx + body on every call — O(n · serialize) per round.
/// These tests pin the contract that the cache is maintained incrementally
/// and always matches what a full rebuild would produce.
final class MempoolFetcherCacheTests: XCTestCase {

    private func wallet() -> Wallet { Wallet.create() }

    private func tx(_ w: Wallet, nonce: UInt64, fee: UInt64 = 10) -> Transaction {
        w.buildTransfer(to: w.address, amount: 1, fee: fee, nonce: nonce)!
    }

    /// Recompute what fetcherCache SHOULD return by walking allTransactions
    /// and serializing tx + body. The admitted mempool's cache must equal this.
    private func rebuildExpectedCache(from txs: [Transaction]) -> [String: Data] {
        var expected: [String: Data] = [:]
        for t in txs {
            if let data = t.toData() {
                // known-valid local node; CID cannot fail
                expected[try! VolumeImpl<Transaction>(node: t).rawCID] = data
            }
            if let bodyNode = t.body.node, let bodyData = bodyNode.toData() {
                expected[t.body.rawCID] = bodyData
            }
        }
        return expected
    }

    func testCacheReflectsInserts() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()

        _ = await mempool.addTransaction(tx(w, nonce: 0))
        _ = await mempool.addTransaction(tx(w, nonce: 1))
        _ = await mempool.addTransaction(tx(w, nonce: 2))

        let cache = await mempool.fetcherCache()
        let expected = rebuildExpectedCache(from: await mempool.allTransactions())
        XCTAssertEqual(cache, expected, "cache must reflect all admitted transactions")
        XCTAssertEqual(cache.count, 6, "3 tx + 3 body entries")
    }

    func testCacheReflectsExplicitRemoves() async throws {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        let t0 = tx(w, nonce: 0)
        let t1 = tx(w, nonce: 1)
        _ = await mempool.addTransaction(t0)
        _ = await mempool.addTransaction(t1)

        // NodeMempool keys byCID by body rawCID — that's also the `txCID`
        // remove() expects. The cache carries BOTH the tx-wrapper CID and the
        // body CID, and both must be dropped on removal.
        let t0WrapperCID = try VolumeImpl<Transaction>(node: t0).rawCID
        let t0BodyCID = t0.body.rawCID
        await mempool.remove(txCID: t0BodyCID)

        let cache = await mempool.fetcherCache()
        XCTAssertNil(cache[t0WrapperCID], "removed tx-wrapper CID must leave the cache")
        XCTAssertNil(cache[t0BodyCID], "removed body CID must leave the cache")

        let expected = rebuildExpectedCache(from: await mempool.allTransactions())
        XCTAssertEqual(cache, expected, "cache must match rebuild after remove")
    }

    func testCacheReflectsRemoveAll() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        let t0 = tx(w, nonce: 0)
        let t1 = tx(w, nonce: 1)
        let t2 = tx(w, nonce: 2)
        _ = await mempool.addTransaction(t0)
        _ = await mempool.addTransaction(t1)
        _ = await mempool.addTransaction(t2)

        let cids: Set<String> = [t0.body.rawCID, t2.body.rawCID]
        await mempool.removeAll(txCIDs: cids)

        let cache = await mempool.fetcherCache()
        let expected = rebuildExpectedCache(from: await mempool.allTransactions())
        XCTAssertEqual(cache, expected, "cache must match rebuild after bulk remove")
        XCTAssertEqual(cache.count, 2, "only t1 tx+body should remain")
    }

    func testCacheReflectsConfirmedNonceAdvance() async {
        // batchUpdateConfirmedNonces removes entries below the new confirmed
        // nonce without going through removeEntry. The cache must follow.
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        _ = await mempool.addTransaction(tx(w, nonce: 0))
        _ = await mempool.addTransaction(tx(w, nonce: 1))
        _ = await mempool.addTransaction(tx(w, nonce: 2))

        await mempool.updateConfirmedNonce(sender: w.address, nonce: 2)

        let cache = await mempool.fetcherCache()
        let expected = rebuildExpectedCache(from: await mempool.allTransactions())
        XCTAssertEqual(cache, expected, "cache must match rebuild after nonce advance evicts stale txs")
    }

    func testBatchConfirmedNonceUpdateCannotRewindFloor() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 2)
        let w = wallet()

        await mempool.updateConfirmedNonce(sender: w.address, nonce: 5)
        await mempool.batchUpdateConfirmedNonces(updates: [(sender: w.address, nonce: 3)])

        switch await mempool.addTransaction(tx(w, nonce: 4)) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"), "lower batch update must not reopen confirmed nonce 4")
        case .added, .replacedExisting:
            XCTFail("lower batch update must not rewind the confirmed nonce floor")
        }

        switch await mempool.addTransaction(tx(w, nonce: 5)) {
        case .added:
            break
        case .replacedExisting, .rejected:
            XCTFail("current confirmed nonce must remain admissible after lower batch update")
        }

        let selectedNonces = await mempool.selectTransactions(maxCount: 10).compactMap { $0.body.node?.nonce }
        XCTAssertEqual(selectedNonces, [5], "selection must still start at the original higher floor")
    }

    func testRefreshConfirmedNonceEvictsStaleTransactionsAndKeepsFloor() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        _ = await mempool.addTransaction(tx(w, nonce: 0))
        _ = await mempool.addTransaction(tx(w, nonce: 1))
        _ = await mempool.addTransaction(tx(w, nonce: 2))

        await mempool.refreshConfirmedNonce(sender: w.address, nonce: 2)

        let remainingNonces = Set(await mempool.allTransactions().compactMap { $0.body.node?.nonce })
        XCTAssertEqual(remainingNonces, [2], "refresh must evict pending txs below the raised floor")

        let cache = await mempool.fetcherCache()
        let expected = rebuildExpectedCache(from: await mempool.allTransactions())
        XCTAssertEqual(cache, expected, "cache must match rebuild after refresh evicts stale txs")

        switch await mempool.addTransaction(tx(w, nonce: 1)) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"), "refresh must keep the raised floor for later admission")
        case .added, .replacedExisting:
            XCTFail("refresh must not allow nonce below the raised floor back into the mempool")
        }

        switch await mempool.addTransaction(tx(w, nonce: 3)) {
        case .added:
            break
        case .replacedExisting, .rejected:
            XCTFail("higher consecutive nonce should remain admissible after refresh")
        }

        let selectedNonces = await mempool.selectTransactions(maxCount: 10).compactMap { $0.body.node?.nonce }
        XCTAssertEqual(selectedNonces, [2, 3], "selection must continue from the refreshed floor")
    }

    /// SEC-401 contract: removeAll drops drained queues unconditionally (the
    /// nonce floor is NOT durable mempool state — unbounded per-sender entries
    /// otherwise accumulate). Floors are re-derived from the on-chain nonce by
    /// every production admission path: admitToMempool calls
    /// refreshConfirmedNonce(onChainNonce) before addTransaction. This test
    /// exercises that seam contract around a bulk prune.
    func testBulkPruneFloorReestablishedByAdmissionSeam() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        let stale = tx(w, nonce: 2)

        await mempool.refreshConfirmedNonce(sender: w.address, nonce: 2)
        _ = await mempool.addTransaction(stale)
        await mempool.removeAll(txCIDs: [stale.body.rawCID])

        // Mirror the admission seam: refreshConfirmedNonce runs with the
        // sender's on-chain nonce before each addTransaction.
        await mempool.refreshConfirmedNonce(sender: w.address, nonce: 2)
        switch await mempool.addTransaction(tx(w, nonce: 1)) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"), "re-derived floor must reject below-floor nonces")
        case .added, .replacedExisting:
            XCTFail("re-derived floor must not reopen nonces below the on-chain nonce")
        }

        let next = tx(w, nonce: 2)
        await mempool.refreshConfirmedNonce(sender: w.address, nonce: 2)
        switch await mempool.addTransaction(next) {
        case .added:
            break
        case .replacedExisting, .rejected:
            XCTFail("the next tx at the re-derived floor must be admitted")
        }

        let selectedNonces = await mempool.selectTransactions(maxCount: 10).compactMap { $0.body.node?.nonce }
        XCTAssertEqual(selectedNonces, [2], "selection must start from the re-derived floor after bulk prune")
    }

    func testCacheEmptyAfterFullEviction() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        let t0 = tx(w, nonce: 0)
        _ = await mempool.addTransaction(t0)

        await mempool.remove(txCID: t0.body.rawCID)

        let cache = await mempool.fetcherCache()
        XCTAssertTrue(cache.isEmpty, "cache must be empty after the last tx is removed")
    }

    func testCacheReplacesOnRBF() async throws {
        // RBF: new tx at same nonce with higher fee. Old entry removed, new
        // entry inserted. The cache must drop the old CIDs and gain the new.
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        let old = tx(w, nonce: 0, fee: 10)
        _ = await mempool.addTransaction(old)
        let oldCID = try VolumeImpl<Transaction>(node: old).rawCID
        let oldBodyCID = old.body.rawCID

        let replacement = tx(w, nonce: 0, fee: 100)
        _ = await mempool.addTransaction(replacement)

        let cache = await mempool.fetcherCache()
        XCTAssertNil(cache[oldCID], "old RBF'd tx CID must be evicted from cache")
        XCTAssertNil(cache[oldBodyCID], "old RBF'd body CID must be evicted from cache")

        let expected = rebuildExpectedCache(from: await mempool.allTransactions())
        XCTAssertEqual(cache, expected, "cache must match rebuild after RBF replacement")
    }
}
