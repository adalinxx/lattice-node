import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker

// MARK: - Test Helpers

private func makeWallet() -> Wallet {
    Wallet.create()
}

private func makeTx(wallet: Wallet, fee: UInt64, nonce: UInt64 = 0, recipientAddress: String? = nil) -> Transaction {
    let recipient = recipientAddress ?? makeWallet().address
    return wallet.buildTransfer(
        to: recipient,
        amount: 1,
        fee: fee,
        nonce: nonce
    )!
}

// ============================================================================
// MARK: - NodeMempool Tests
// ============================================================================

final class NodeMempoolTests: XCTestCase {

    func testSelectTransactionsReturnHighestFeeFirst() async {
        let mempool = NodeMempool(maxSize: 100)

        let wallets = (0..<5).map { _ in makeWallet() }
        let fees: [UInt64] = [5, 50, 10, 100, 25]
        for (i, fee) in fees.enumerated() {
            let tx = makeTx(wallet: wallets[i], fee: fee, nonce: 0)
            let added = await mempool.add(transaction: tx)
            XCTAssertTrue(added, "Transaction with fee \(fee) should be added")
        }

        let selected = await mempool.selectTransactions(maxCount: 5)
        XCTAssertEqual(selected.count, 5)

        var previousFee: UInt64 = UInt64.max
        for tx in selected {
            let body = tx.body.node!
            XCTAssertGreaterThanOrEqual(previousFee, body.fee,
                "Transactions should be returned in descending fee order")
            previousFee = body.fee
        }
    }

    func testPerAccountLimitEnforced() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 3)
        let wallet = makeWallet()

        for i: UInt64 in 0..<3 {
            let tx = makeTx(wallet: wallet, fee: 10, nonce: i)
            let added = await mempool.add(transaction: tx)
            XCTAssertTrue(added, "Transaction \(i) should be accepted")
        }

        let tx4 = makeTx(wallet: wallet, fee: 10, nonce: 3)
        let added = await mempool.add(transaction: tx4)
        XCTAssertFalse(added, "4th transaction from same account should be rejected")

        let count = await mempool.count
        XCTAssertEqual(count, 3)
    }

    func testReorgResetCanLowerConfirmedNonceForRecoveredTransactions() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 10)
        let wallet = makeWallet()

        await mempool.refreshConfirmedNonce(sender: wallet.address, nonce: 6)
        await mempool.resetConfirmedNoncesAfterReorg(updates: [(sender: wallet.address, nonce: 4)])

        let recovered = makeTx(wallet: wallet, fee: 10, nonce: 4)
        let added = await mempool.add(transaction: recovered)
        XCTAssertTrue(added, "reorg recovery must be able to re-admit a nonce orphaned by the abandoned branch")

        let selected = await mempool.selectTransactions(maxCount: 1)
        XCTAssertEqual(selected.first?.body.node?.nonce, 4)
    }

    // (BIP125 RBF): a same-(sender,nonce) replacement must clear
    // the conflicting-package fee plus the `existing/10 + 1` bump. With a single
    // resident (no descendants) at fee=100 the bar is 100 + 11 = 111: equal and
    // +1 are rejected; >= 111 replaces.
    func testReplaceByFeeBIP125() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx1 = makeTx(wallet: wallet, fee: 100, nonce: 1)
        let added1 = await mempool.add(transaction: tx1)
        XCTAssertTrue(added1)

        // Equal fee: rejected.
        let addedEqual = await mempool.add(transaction: makeTx(wallet: wallet, fee: 100, nonce: 1))
        XCTAssertFalse(addedEqual, "Equal-fee same-nonce tx must be rejected")

        // +1 over the resident: still below the 10%+1 bump → rejected.
        let addedBump = await mempool.add(transaction: makeTx(wallet: wallet, fee: 101, nonce: 1))
        XCTAssertFalse(addedBump, "A +1 fee below the bump threshold must NOT replace under BIP125")

        // Clearing the package + bump (>= 111): replaces.
        let addedReplace = await mempool.add(transaction: makeTx(wallet: wallet, fee: 111, nonce: 1))
        XCTAssertTrue(addedReplace, "A fee clearing the package + bump (>=111) must replace")

        let count = await mempool.count
        XCTAssertEqual(count, 1, "RBF should replace, not add")
    }

    func testEvictionRemovesLowestFee() async {
        let mempool = NodeMempool(maxSize: 3)

        let w1 = makeWallet()
        let w2 = makeWallet()
        let w3 = makeWallet()
        let w4 = makeWallet()

        let tx10 = makeTx(wallet: w1, fee: 10, nonce: 0)
        let tx20 = makeTx(wallet: w2, fee: 20, nonce: 0)
        let tx30 = makeTx(wallet: w3, fee: 30, nonce: 0)

        let _ = await mempool.add(transaction: tx10)
        let _ = await mempool.add(transaction: tx20)
        let _ = await mempool.add(transaction: tx30)

        let countBefore = await mempool.count
        XCTAssertEqual(countBefore, 3)

        let tx25 = makeTx(wallet: w4, fee: 25, nonce: 0)
        let added = await mempool.add(transaction: tx25)
        XCTAssertTrue(added, "Tx with fee 25 should evict lowest fee and be added")

        let countAfter = await mempool.count
        XCTAssertEqual(countAfter, 3, "Mempool should remain at max size")

        let cid10 = tx10.body.rawCID
        let contains10 = await mempool.contains(txCID: cid10)
        XCTAssertFalse(contains10, "Lowest fee tx (fee=10) should have been evicted")

        let cid25 = tx25.body.rawCID
        let contains25 = await mempool.contains(txCID: cid25)
        XCTAssertTrue(contains25, "New tx (fee=25) should be present")
    }

    func testEvictionRejectsTooLowFee() async {
        let mempool = NodeMempool(maxSize: 3)

        let w1 = makeWallet()
        let w2 = makeWallet()
        let w3 = makeWallet()
        let w4 = makeWallet()

        let _ = await mempool.add(transaction: makeTx(wallet: w1, fee: 10, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w2, fee: 20, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w3, fee: 30, nonce: 0))

        let txLow = makeTx(wallet: w4, fee: 5, nonce: 0)
        let added = await mempool.add(transaction: txLow)
        XCTAssertFalse(added, "Tx with fee lower than the minimum in full mempool should be rejected")
    }

    func testPruneExpiredRemovesOldEntries() async throws {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx = makeTx(wallet: wallet, fee: 10, nonce: 0)
        let _ = await mempool.add(transaction: tx)

        let countBefore = await mempool.count
        XCTAssertEqual(countBefore, 1)

        try await Task.sleep(for: .milliseconds(50))

        await mempool.pruneExpired(olderThan: .milliseconds(10))

        let countAfter = await mempool.count
        XCTAssertEqual(countAfter, 0, "Expired entries should be pruned")
    }

    func testCountAndTotalFees() async {
        let mempool = NodeMempool(maxSize: 100)
        let w1 = makeWallet()
        let w2 = makeWallet()
        let w3 = makeWallet()

        let _ = await mempool.add(transaction: makeTx(wallet: w1, fee: 10, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w2, fee: 20, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w3, fee: 30, nonce: 0))

        let count = await mempool.count
        XCTAssertEqual(count, 3)

        let total = await mempool.totalFees()
        XCTAssertEqual(total, 60)
    }

    func testRemoveTransaction() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx = makeTx(wallet: wallet, fee: 50, nonce: 0)
        let cid = tx.body.rawCID
        let _ = await mempool.add(transaction: tx)

        let containsBefore = await mempool.contains(txCID: cid)
        XCTAssertTrue(containsBefore)

        await mempool.remove(txCID: cid)

        let containsAfter = await mempool.contains(txCID: cid)
        XCTAssertFalse(containsAfter)

        let count = await mempool.count
        XCTAssertEqual(count, 0)
    }

    func testDuplicateTransactionRejected() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx = makeTx(wallet: wallet, fee: 50, nonce: 0)
        let added1 = await mempool.add(transaction: tx)
        XCTAssertTrue(added1)

        let added2 = await mempool.add(transaction: tx)
        XCTAssertFalse(added2, "Duplicate transaction should be rejected")

        let count = await mempool.count
        XCTAssertEqual(count, 1)
    }

    func testCurrentGenerationTracksContentChangingMutatorsOnly() async throws {
        let mempool = NodeMempool(maxSize: 100)
        var generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 0)

        let rbfWallet = makeWallet()
        let tx = makeTx(wallet: rbfWallet, fee: 100, nonce: 0)
        let added = await mempool.add(transaction: tx)
        XCTAssertTrue(added)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 1)

        let duplicateAdded = await mempool.add(transaction: tx)
        XCTAssertFalse(duplicateAdded, "duplicate add is a no-op")
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 1)
        let lowRBFAdded = await mempool.add(transaction: makeTx(wallet: rbfWallet, fee: 101, nonce: 0))
        XCTAssertFalse(lowRBFAdded, "below-threshold replacement is a no-op")
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 1)

        let replacement = makeTx(wallet: rbfWallet, fee: 111, nonce: 0)
        let replaced = await mempool.add(transaction: replacement)
        XCTAssertTrue(replaced)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 2)

        await mempool.remove(txCID: tx.body.rawCID)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 2, "removing a non-resident CID is a no-op")
        await mempool.remove(txCID: replacement.body.rawCID)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 3)

        let bulkA = makeTx(wallet: makeWallet(), fee: 10, nonce: 0)
        let bulkB = makeTx(wallet: makeWallet(), fee: 11, nonce: 0)
        let bulkAAdded = await mempool.add(transaction: bulkA)
        let bulkBAdded = await mempool.add(transaction: bulkB)
        XCTAssertTrue(bulkAAdded)
        XCTAssertTrue(bulkBAdded)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 5)
        await mempool.removeAll(txCIDs: ["missing"])
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 5)
        await mempool.removeAll(txCIDs: [bulkA.body.rawCID, "missing"])
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 6)

        let spendWallet = makeWallet()
        let unaffordable = makeTx(wallet: spendWallet, fee: 1, nonce: 0)
        let addResult = await mempool.addTransaction(
            unaffordable,
            confirmedBalance: 2,
            senderDebit: 2
        )
        switch addResult {
        case .added:
            break
        default:
            XCTFail("expected unaffordable fixture to enter before balance drop")
        }
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 7)
        await mempool.dropUnaffordable(updates: [(sender: spendWallet.address, confirmedBalance: 0)])
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 8)
        await mempool.dropUnaffordable(updates: [(sender: spendWallet.address, confirmedBalance: 0)])
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 8)

        let staleWallet = makeWallet()
        let stale = makeTx(wallet: staleWallet, fee: 12, nonce: 0)
        let staleAdded = await mempool.add(transaction: stale)
        XCTAssertTrue(staleAdded)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 9)
        await mempool.resetConfirmedNoncesAfterReorg(updates: [(sender: staleWallet.address, nonce: 1)])
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 10)
        await mempool.resetConfirmedNoncesAfterReorg(updates: [(sender: staleWallet.address, nonce: 1)])
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 10)

        let expiring = makeTx(wallet: makeWallet(), fee: 13, nonce: 0)
        let expiringAdded = await mempool.add(transaction: expiring)
        XCTAssertTrue(expiringAdded)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 11)
        try await Task.sleep(for: .milliseconds(25))
        await mempool.pruneExpired(olderThan: .milliseconds(1))
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 12)
        await mempool.pruneExpired(olderThan: .milliseconds(1))
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 12)

        let futureWallet = makeWallet()
        let futureNonce = makeTx(wallet: futureWallet, fee: 14, nonce: 1)
        let futureAdded = await mempool.add(transaction: futureNonce)
        XCTAssertTrue(futureAdded)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 13)
        await mempool.refreshConfirmedNonce(sender: futureWallet.address, nonce: 1)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 14, "advancing the floor can make a resident nonce selectable")
        await mempool.refreshConfirmedNonce(sender: futureWallet.address, nonce: 1)
        generation = await mempool.currentGeneration
        XCTAssertEqual(generation, 14)

        let seededMempool = NodeMempool(maxSize: 100)
        let seededWallet = makeWallet()
        let seededFuture = makeTx(wallet: seededWallet, fee: 15, nonce: 1)
        let seededAdded = await seededMempool.add(transaction: seededFuture)
        XCTAssertTrue(seededAdded)
        generation = await seededMempool.currentGeneration
        XCTAssertEqual(generation, 1)
        await seededMempool.seedConfirmedNonceIfUnset(sender: seededWallet.address, nonce: 1)
        generation = await seededMempool.currentGeneration
        XCTAssertEqual(generation, 2)
        await seededMempool.seedConfirmedNonceIfUnset(sender: seededWallet.address, nonce: 1)
        generation = await seededMempool.currentGeneration
        XCTAssertEqual(generation, 2)
    }

    func testSelectTransactionsRespectsMaxCount() async {
        let mempool = NodeMempool(maxSize: 100)

        for i: UInt64 in 0..<10 {
            let w = makeWallet()
            let _ = await mempool.add(transaction: makeTx(wallet: w, fee: i + 1, nonce: 0))
        }

        let selected3 = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected3.count, 3)

        let selected20 = await mempool.selectTransactions(maxCount: 20)
        XCTAssertEqual(selected20.count, 10, "Should return all when maxCount exceeds pool size")
    }

    func testFeeHistogram() async {
        let mempool = NodeMempool(maxSize: 100)

        for i: UInt64 in 1...20 {
            let w = makeWallet()
            let _ = await mempool.add(transaction: makeTx(wallet: w, fee: i * 5, nonce: 0))
        }

        let histogram = await mempool.feeHistogram(bucketCount: 5)
        XCTAssertFalse(histogram.isEmpty)

        let totalInBuckets = histogram.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalInBuckets, 20)
    }
}

// ============================================================================
// MARK: - FeeEstimator Tests
// ============================================================================

final class FeeEstimatorTests: XCTestCase {

    func testEstimateWithNoDataReturnsMinimum() async {
        let estimator = FeeEstimator()
        let fee = await estimator.estimate(confirmationTarget: 5)
        XCTAssertEqual(fee, 1, "With no data, estimator should return minimum fee of 1")
    }

    func testEstimateWithKnownDistribution() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [10, 20, 30])
        await estimator.recordBlock(height: 2, transactionFees: [15, 25, 35])
        await estimator.recordBlock(height: 3, transactionFees: [5, 10, 50])

        let highPriority = await estimator.estimate(confirmationTarget: 1)
        let lowPriority = await estimator.estimate(confirmationTarget: 20)
        XCTAssertGreaterThan(highPriority, lowPriority,
            "High priority (target=1) should have higher fee than low priority (target=20)")
    }

    func testEstimateHigherTargetProducesLowerFee() async {
        let estimator = FeeEstimator()
        for h: UInt64 in 1...20 {
            let fees = (1...10).map { _ in UInt64.random(in: 1...1000) }
            await estimator.recordBlock(height: h, transactionFees: fees)
        }

        let target1 = await estimator.estimate(confirmationTarget: 1)
        let target5 = await estimator.estimate(confirmationTarget: 5)
        let target10 = await estimator.estimate(confirmationTarget: 10)
        let target20 = await estimator.estimate(confirmationTarget: 20)

        XCTAssertGreaterThanOrEqual(target1, target5)
        XCTAssertGreaterThanOrEqual(target5, target10)
        XCTAssertGreaterThanOrEqual(target10, target20)
    }

    func testWindowRotation() async {
        let estimator = FeeEstimator(windowSize: 3)
        await estimator.recordBlock(height: 1, transactionFees: [100])
        await estimator.recordBlock(height: 2, transactionFees: [200])
        await estimator.recordBlock(height: 3, transactionFees: [300])
        await estimator.recordBlock(height: 4, transactionFees: [400])

        let count = await estimator.blockCount
        XCTAssertEqual(count, 3, "Window should evict oldest block when exceeding windowSize")
    }

    func testWindowRotationAffectsEstimates() async {
        let estimator = FeeEstimator(windowSize: 2)

        await estimator.recordBlock(height: 1, transactionFees: [1000])
        let estimateBefore = await estimator.estimate(confirmationTarget: 1)

        await estimator.recordBlock(height: 2, transactionFees: [1])
        await estimator.recordBlock(height: 3, transactionFees: [1])

        let estimateAfter = await estimator.estimate(confirmationTarget: 1)
        XCTAssertLessThan(estimateAfter, estimateBefore,
            "After high-fee block is evicted, estimate should drop")
    }

    func testHistogramWithData() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [1, 5, 10, 50, 100, 500])
        let histogram = await estimator.histogram()
        XCTAssertFalse(histogram.isEmpty, "Histogram should have entries when data exists")

        let totalCount = histogram.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalCount, 6, "Histogram should account for all fees")
    }

    func testHistogramWithNoData() async {
        let estimator = FeeEstimator()
        let histogram = await estimator.histogram()
        XCTAssertTrue(histogram.isEmpty, "Histogram should be empty with no data")
    }

    func testHistogramBucketRanges() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [5])
        await estimator.recordBlock(height: 2, transactionFees: [500])
        await estimator.recordBlock(height: 3, transactionFees: [50000])

        let histogram = await estimator.histogram()
        XCTAssertGreaterThanOrEqual(histogram.count, 3,
            "Fees spanning multiple orders of magnitude should produce multiple buckets")
    }

    func testRecordBlockWithEmptyFees() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [])
        await estimator.recordBlock(height: 2, transactionFees: [10])

        let fee = await estimator.estimate(confirmationTarget: 1)
        XCTAssertGreaterThanOrEqual(fee, 1)
    }

    func testBlockCountTracksRecordings() async {
        let estimator = FeeEstimator()
        let count0 = await estimator.blockCount
        XCTAssertEqual(count0, 0)

        await estimator.recordBlock(height: 1, transactionFees: [10])
        let count1 = await estimator.blockCount
        XCTAssertEqual(count1, 1)

        await estimator.recordBlock(height: 2, transactionFees: [20])
        let count2 = await estimator.blockCount
        XCTAssertEqual(count2, 2)
    }
}

// ============================================================================
// ============================================================================
// (BatchAuction removed — cross-chain swaps use DepositAction/WithdrawalAction)
// ============================================================================

// ============================================================================
// MARK: - Consensus Fuzz Tests
// ============================================================================

final class ConsensusFuzzTests: XCTestCase {

    func testRandomTransactionFeeOrdering() async {
        let mempool = NodeMempool(maxSize: 100)

        var wallets: [Wallet] = []
        for _ in 0..<50 {
            wallets.append(makeWallet())
        }

        var expectedFees: [UInt64] = []
        for (_, wallet) in wallets.enumerated() {
            let fee = UInt64.random(in: 1...10000)
            expectedFees.append(fee)
            let tx = makeTx(wallet: wallet, fee: fee, nonce: 0)
            let _ = await mempool.add(transaction: tx)
        }

        let selected = await mempool.selectTransactions(maxCount: 100)

        var previousFee: UInt64 = UInt64.max
        for tx in selected {
            let body = tx.body.node!
            XCTAssertLessThanOrEqual(body.fee, previousFee,
                "Selected transactions must be in descending fee order")
            previousFee = body.fee
        }
    }

    func testRandomMempoolOperationsDoNotCrash() async {
        let mempool = NodeMempool(maxSize: 20)

        var addedCIDs: [String] = []

        for _ in 0..<100 {
            let action = Int.random(in: 0..<4)

            switch action {
            case 0:
                let w = makeWallet()
                let fee = UInt64.random(in: 1...500)
                let tx = makeTx(wallet: w, fee: fee, nonce: 0)
                let _ = await mempool.add(transaction: tx)
                addedCIDs.append(tx.body.rawCID)
            case 1:
                if !addedCIDs.isEmpty {
                    let idx = Int.random(in: 0..<addedCIDs.count)
                    await mempool.remove(txCID: addedCIDs[idx])
                    addedCIDs.remove(at: idx)
                }
            case 2:
                let _ = await mempool.selectTransactions(maxCount: Int.random(in: 1...50))
            case 3:
                let _ = await mempool.totalFees()
            default:
                break
            }
        }

        let count = await mempool.count
        XCTAssertGreaterThanOrEqual(count, 0, "Count should be non-negative after random operations")
    }

    func testRandomFeeEstimatorInputs() async {
        let estimator = FeeEstimator(windowSize: 50)

        for h: UInt64 in 1...100 {
            let feeCount = Int.random(in: 0...20)
            let fees = (0..<feeCount).map { _ in UInt64.random(in: 1...100000) }
            await estimator.recordBlock(height: h, transactionFees: fees)
        }

        let blockCount = await estimator.blockCount
        XCTAssertEqual(blockCount, 50, "Window should cap at windowSize")

        for target in [1, 2, 5, 10, 20, 50] {
            let fee = await estimator.estimate(confirmationTarget: target)
            XCTAssertGreaterThanOrEqual(fee, 1, "Estimated fee should always be >= 1")
        }

        let histogram = await estimator.histogram()
        XCTAssertFalse(histogram.isEmpty, "Histogram should have data after recordings")
    }


}
