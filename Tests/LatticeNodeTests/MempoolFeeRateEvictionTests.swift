import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import Foundation

/// capacity eviction ranks residents by fee-RATE (fee per
/// serialized-body byte), NOT absolute fee. A large, fee-padded tx must not
/// evict a small, dense-fee one. This is mempool ADMISSION policy, not
/// consensus — Block+Validate is untouched. Every case drives the REAL
/// `NodeMempool.addTransaction` entry point.
final class MempoolFeeRateEvictionTests: XCTestCase {

    private func wallet() -> Wallet { Wallet.create() }

    private func smallTx(fee: UInt64) -> Transaction {
        let w = wallet()
        return w.buildTransfer(to: w.address, amount: 1, fee: fee, nonce: 0)!
    }

    /// A tx with a ~100 KB body via many recipient actions. Its absolute fee can
    /// be large while its per-byte rate is tiny (~0.0098/byte for fee=1000 over
    /// ~100 KB). Exercises the sub-1-per-byte regime FEE_RATE_SCALE exists for.
    private func bulkyTx(fee: UInt64, approxBytes: Int) -> Transaction {
        let w = wallet()
        // Each recipient action serializes to ~90-100 bytes; size to the target.
        let recipientCount = max(approxBytes / 95, 1)
        let recipients = (0..<recipientCount).map { _ in
            AccountAction(owner: wallet().address, delta: 1)
        }
        let body = TransactionBody(
            accountActions: [AccountAction(owner: w.address, delta: -Int64(recipientCount) - Int64(fee))] + recipients,
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: fee, nonce: 0
        )
        // known-valid local node; CID cannot fail
        let header = try! HeaderImpl<TransactionBody>(node: body)
        return Transaction(
            signatures: [w.publicKeyHex: w.sign(body: body, bodyCID: header.rawCID)!],
            body: header
        )
    }

    private func bytes(_ tx: Transaction) -> UInt64 { UInt64(tx.body.node!.toData()!.count) }

    /// A ~100 KB fee=1000 tx (~0.0098/byte) must FAIL to evict a 250-byte fee=500
    /// (2.0/byte) tx — a >200x rate ratio that exercises the FEE_RATE_SCALE
    /// integer-precision path. Absolute-fee ranking would (wrongly) admit it.
    func testLargeLowRateTxDoesNotEvictSmallHighRateTx() async {
        let mempool = NodeMempool(maxSize: 2, maxPerAccount: 64)

        let tx1 = smallTx(fee: 500)   // ~250 bytes → high rate
        let tx2 = smallTx(fee: 600)   // ~250 bytes → high rate
        guard case .added = await mempool.addTransaction(tx1) else { return XCTFail("tx1 admit") }
        guard case .added = await mempool.addTransaction(tx2) else { return XCTFail("tx2 admit") }

        let tx3 = bulkyTx(fee: 1000, approxBytes: 100_000)   // huge body → ~0.0098/byte

        // Premise: tx3 pays a far HIGHER absolute fee but a far LOWER rate, and
        // FEE_RATE_SCALE keeps the two distinguishable (rate ratio > 200x).
        let b1 = bytes(tx1), b3 = bytes(tx3)
        XCTAssertGreaterThan(b3, 50_000, "test premise: bulky body must be large (~100KB)")
        let rate1 = 500 * 1_000_000 / b1
        let rate3 = 1000 * 1_000_000 / b3
        XCTAssertGreaterThan(rate3, 0, "FEE_RATE_SCALE must keep the sub-1/byte rate non-zero")
        XCTAssertGreaterThan(rate1, rate3 * 100, "test premise: >100x rate gap (small tx denser)")

        switch await mempool.addTransaction(tx3) {
        case .rejected: break
        default: XCTFail("large low-rate tx must NOT evict small high-rate residents")
        }

        let count = await mempool.count
        XCTAssertEqual(count, 2, "no eviction occurred")
        let has1 = await mempool.contains(txCID: tx1.body.rawCID)
        let has2 = await mempool.contains(txCID: tx2.body.rawCID)
        XCTAssertTrue(has1 && has2, "both high-rate residents survive")
    }

    /// Inverse: a small, higher-RATE newcomer evicts the lowest-rate resident.
    func testHigherRateTxEvictsLowestRate() async {
        let mempool = NodeMempool(maxSize: 2, maxPerAccount: 64)

        let tx1 = smallTx(fee: 500)   // 2.0/byte (the lowest rate of the two)
        let tx2 = smallTx(fee: 600)   // 2.4/byte
        guard case .added = await mempool.addTransaction(tx1) else { return XCTFail("tx1 admit") }
        guard case .added = await mempool.addTransaction(tx2) else { return XCTFail("tx2 admit") }

        let tx3 = smallTx(fee: 700)   // 2.8/byte → outranks both
        switch await mempool.addTransaction(tx3) {
        case .added: break
        default: XCTFail("higher-rate newcomer must be admitted")
        }

        let count = await mempool.count
        XCTAssertEqual(count, 2, "capacity preserved")
        let has1 = await mempool.contains(txCID: tx1.body.rawCID)
        XCTAssertFalse(has1, "the lowest-rate resident (tx1) is evicted")
        let has3 = await mempool.contains(txCID: tx3.body.rawCID)
        XCTAssertTrue(has3, "the higher-rate newcomer is resident")
    }

    /// A rejected admission must be NON-DESTRUCTIVE. When the newcomer is large
    /// enough to require evicting more than one resident, the victim set must be
    /// proven affordable BEFORE any removal: if the newcomer can outbid the
    /// cheapest resident but not the next one, it must reject having removed
    /// NOTHING. The pre-fix loop evicted as it went, so it could churn lower-fee
    /// residents out for a tx that never enters — a free DoS lever for a peer.
    func testRejectedMultiEvictionAdmissionIsNonDestructive() async {
        let low = smallTx(fee: 300)     // cheapest rate (evicted first)
        let high = smallTx(fee: 4000)   // dense, high rate — newcomer can't outbid
        // Newcomer large enough that fitting it requires freeing BOTH residents.
        let incoming = bulkyTx(fee: 1500, approxBytes: 600)
        let lowB = bytes(low), highB = bytes(high), inB = bytes(incoming)

        // Premise: incoming alone is bigger than both residents combined, so with
        // maxBytes == inB the pool holds both residents, yet admitting incoming
        // would need to evict BOTH — forcing the loop to reach `high`.
        XCTAssertGreaterThanOrEqual(inB, lowB + highB, "premise: incoming bigger than both residents combined")
        let maxBytes = inB

        // Rate ordering low < incoming < high: incoming outbids the cheapest but
        // not the dense resident it reaches second.
        let rateLow = 300 * 1_000_000 / lowB
        let rateHigh = 4000 * 1_000_000 / highB
        let rateIn = 1500 * 1_000_000 / inB
        XCTAssertGreaterThan(rateIn, rateLow, "premise: incoming outbids the cheapest resident")
        XCTAssertLessThan(rateIn, rateHigh, "premise: incoming cannot outbid the dense resident")

        let mempool = NodeMempool(maxSize: 100, maxBytes: maxBytes, maxPerAccount: 64)
        guard case .added = await mempool.addTransaction(low) else { return XCTFail("low admit") }
        guard case .added = await mempool.addTransaction(high) else { return XCTFail("high admit") }

        switch await mempool.addTransaction(incoming) {
        case .rejected: break
        default: XCTFail("incoming cannot outbid the dense resident it must evict → reject")
        }

        // The crux: rejection removed NOTHING. Pre-fix, `low` was evicted before
        // the rejection was returned.
        let count = await mempool.count
        XCTAssertEqual(count, 2, "a rejected admission must not evict any resident")
        let hasLow = await mempool.contains(txCID: low.body.rawCID)
        let hasHigh = await mempool.contains(txCID: high.body.rawCID)
        XCTAssertTrue(hasLow, "the cheapest resident must survive a rejected admission")
        XCTAssertTrue(hasHigh, "the dense resident must survive")
    }

    /// Selection (block-template order) is fee-RATE-ordered too: a dense small tx
    /// is selected before a fee-padded bulky one even when the bulky one pays a
    /// larger ABSOLUTE fee. Confirms Child A switched selection, not just eviction.
    func testSelectionPrefersHigherRate() async {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 64)

        let dense = smallTx(fee: 500)
        let bulky = bulkyTx(fee: 1000, approxBytes: 100_000)
        guard case .added = await mempool.addTransaction(bulky) else { return XCTFail("bulky admit") }
        guard case .added = await mempool.addTransaction(dense) else { return XCTFail("dense admit") }

        let selected = await mempool.selectTransactions(maxCount: 2)
        XCTAssertEqual(selected.first?.body.rawCID, dense.body.rawCID,
                       "dense high-rate tx must be selected before the fee-padded bulky one")
    }
}
