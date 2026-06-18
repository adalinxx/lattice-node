import XCTest
@testable import Lattice
@testable import LatticeNode

/// R5: typed mempool rejection classification.
///
/// Peer-penalty decisions (GossipAdmission via ConsensusClass) used to
/// string-prefix-match the human rejection message produced ~500 lines away in
/// `NodeMempool.addTransaction` — a reworded message silently reclassified
/// them. Classification now reads `MempoolRejection.kind` and NEVER the
/// message. These tests pin (a) the kind→class table, (b) that classification
/// is invariant under arbitrary message rewording, and (c) that the actual
/// `NodeMempool` rejection sites produce the expected kinds.
final class MempoolRejectionClassificationTests: XCTestCase {

    private func tx(_ wallet: Wallet, amount: UInt64 = 1, fee: UInt64 = 10, nonce: UInt64) -> Transaction {
        wallet.buildTransfer(to: wallet.address, amount: amount, fee: fee, nonce: nonce)!
    }

    private func rejectionKind(_ result: AddResult, _ context: String) -> MempoolRejectionKind? {
        guard case .rejected(let reason) = result else {
            XCTFail("\(context): expected a rejection, got \(result)")
            return nil
        }
        return reason.kind
    }

    // MARK: - (a) kind → ConsensusClass table

    func testKindClassificationTable() {
        // Capacity: nil — gossip penalizes the flooding source, not the tx.
        XCTAssertNil(MempoolRejectionKind.full.mempoolAddConsensusClass)

        // Missing-input rejections (retryable once inputs confirm).
        XCTAssertEqual(MempoolRejectionKind.nonceConfirmed.mempoolAddConsensusClass, .missingInput)
        XCTAssertEqual(MempoolRejectionKind.nonceGap.mempoolAddConsensusClass, .missingInput)
        XCTAssertEqual(MempoolRejectionKind.cumulativeDebit.mempoolAddConsensusClass, .missingInput)

        // Everything else NodeMempool produces is policy.
        for kind: MempoolRejectionKind in [
            .missingBody, .duplicate, .feeFloor, .feeRateFloor,
            .multiSignerNonceConflict, .accountLimit, .oversizedBody,
            .feeRateOutbid, .rbfUnderpay, .rbfStateKeyConflict, .rbfByteBudget,
        ] {
            XCTAssertEqual(kind.mempoolAddConsensusClass, .policy, "\(kind) must classify as policy")
        }
    }

    // MARK: - (b) classification stable under message rewording

    func testClassificationIgnoresMessageWording() {
        // The same kind with deliberately reworded / nonsense messages must
        // classify identically — including wordings that previously matched a
        // DIFFERENT string prefix.
        let rewordings = [
            "Cumulative sender debit exceeds balance: 120 > 100",   // legacy wording
            "sender over budget across queued nonces",               // reworded
            "Mempool full",                                          // a wording that used to mean capacity
            "",                                                      // empty
        ]
        for message in rewordings {
            let rejection = MempoolRejection(kind: .cumulativeDebit, message: message)
            XCTAssertEqual(
                rejection.kind.mempoolAddConsensusClass, .missingInput,
                "cumulativeDebit must classify as missingInput regardless of message: \(message)"
            )
        }
        for message in ["Mempool full", "mempool is at capacity right now", ""] {
            let rejection = MempoolRejection(kind: .full, message: message)
            XCTAssertNil(
                rejection.kind.mempoolAddConsensusClass,
                "full must classify as capacity (nil) regardless of message: \(message)"
            )
        }
        // Conversely a policy kind whose message HAPPENS to look like a
        // missing-input prefix must stay policy.
        let trap = MempoolRejection(kind: .duplicate, message: "Nonce already confirmed: 0 < 1")
        XCTAssertEqual(trap.kind.mempoolAddConsensusClass, .policy)
    }

    /// Interpolating a rejection prints exactly the human message, so existing
    /// log call sites (`"\(reason)"`) emit unchanged output.
    func testRejectionDescriptionIsTheMessage() {
        let rejection = MempoolRejection(kind: .full, message: "Mempool full")
        XCTAssertEqual("\(rejection)", "Mempool full")
        XCTAssertEqual(rejection.description, "Mempool full")
    }

    // MARK: - (c) producers emit the expected kinds

    func testDuplicateProducesDuplicateKind() async {
        let mempool = NodeMempool(maxSize: 10)
        let w = Wallet.create()
        let t = tx(w, nonce: 0)
        _ = await mempool.addTransaction(t)
        let result = await mempool.addTransaction(t)
        XCTAssertEqual(rejectionKind(result, "duplicate"), .duplicate)
    }

    func testFeeFloorProducesFeeFloorKind() async {
        let mempool = NodeMempool(maxSize: 10, minFeeFloor: 100)
        let w = Wallet.create()
        let result = await mempool.addTransaction(tx(w, fee: 99, nonce: 0))
        XCTAssertEqual(rejectionKind(result, "fee floor"), .feeFloor)
    }

    func testFeeRateFloorProducesFeeRateFloorKind() async {
        let mempool = NodeMempool(maxSize: 10, minFeeRate: 1_000_000)
        let w = Wallet.create()
        let result = await mempool.addTransaction(tx(w, fee: 1, nonce: 0))
        XCTAssertEqual(rejectionKind(result, "fee rate floor"), .feeRateFloor)
    }

    func testNonceBelowFloorProducesNonceConfirmedKind() async {
        let mempool = NodeMempool(maxSize: 10)
        let w = Wallet.create()
        await mempool.updateConfirmedNonce(sender: w.address, nonce: 5)
        let result = await mempool.addTransaction(tx(w, nonce: 4))
        XCTAssertEqual(rejectionKind(result, "nonce confirmed"), .nonceConfirmed)
    }

    func testNonceGapProducesNonceGapKind() async {
        let mempool = NodeMempool(maxSize: 10, maxNonceGap: 8)
        let w = Wallet.create()
        let result = await mempool.addTransaction(tx(w, nonce: 9))
        XCTAssertEqual(rejectionKind(result, "nonce gap"), .nonceGap)
    }

    func testAccountLimitProducesAccountLimitKind() async {
        let mempool = NodeMempool(maxSize: 10, maxPerAccount: 1)
        let w = Wallet.create()
        _ = await mempool.addTransaction(tx(w, nonce: 0))
        let result = await mempool.addTransaction(tx(w, nonce: 1))
        XCTAssertEqual(rejectionKind(result, "account limit"), .accountLimit)
    }

    func testCumulativeDebitProducesCumulativeDebitKind() async {
        let mempool = NodeMempool(maxSize: 10, maxPerAccount: 8)
        let w = Wallet.create()
        // Each tx debits 60 (amount 50 + fee 10) against a balance of 100.
        _ = await mempool.addTransaction(tx(w, amount: 50, fee: 10, nonce: 0), confirmedBalance: 100, senderDebit: 60)
        let second = await mempool.addTransaction(tx(w, amount: 50, fee: 10, nonce: 1), confirmedBalance: 100, senderDebit: 60)
        XCTAssertEqual(rejectionKind(second, "cumulative debit"), .cumulativeDebit)
    }

    func testMempoolFullProducesFullKind() async {
        let mempool = NodeMempool(maxSize: 1)
        let a = Wallet.create()
        let b = Wallet.create()
        _ = await mempool.addTransaction(tx(a, fee: 10, nonce: 0))
        // Same fee rate (identical body shape) — cannot outbid the resident, and
        // the pool is at count capacity, so the eviction loop rejects.
        let result = await mempool.addTransaction(tx(b, fee: 10, nonce: 0))
        guard case .rejected(let reason) = result else {
            return XCTFail("full mempool must reject, got \(result)")
        }
        XCTAssertTrue(
            reason.kind == .full || reason.kind == .feeRateOutbid,
            "capacity rejection must be typed, got \(reason.kind)"
        )
        // Whichever capacity path fired, its class must not be missingInput.
        XCTAssertNotEqual(reason.kind.mempoolAddConsensusClass, .missingInput)
    }

    func testRBFUnderpayProducesRBFUnderpayKind() async {
        let mempool = NodeMempool(maxSize: 10)
        let w = Wallet.create()
        _ = await mempool.addTransaction(tx(w, fee: 100, nonce: 0))
        // Same (sender, nonce) with a non-covering fee → RBF underpay.
        let result = await mempool.addTransaction(tx(w, amount: 2, fee: 100, nonce: 0))
        XCTAssertEqual(rejectionKind(result, "rbf underpay"), .rbfUnderpay)
    }
}
