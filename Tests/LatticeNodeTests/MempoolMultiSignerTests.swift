import XCTest
@testable import Lattice
@testable import LatticeNode
import Foundation
import cashew

/// (M14) + (M10) regression coverage.
///
/// a bulk prune (`removeAll`) that drains a sender's queue must retain
/// the sender's confirmed-nonce floor in the bounded scalar-floor LRU — exactly
/// like `refreshConfirmedNonce` and per-entry `removeEntry` do — or a
/// below-floor nonce becomes re-admissible.
///
/// consensus validates EVERY signer's nonce sequence (and advances
/// every signer's nonce on block apply — see Lattice
/// `AccountStateHeader.proveAndUpdateState`), and every net-negative owner's
/// balance. Per-sender mempool tracking must therefore index each entry under
/// every signer: same-nonce conflicts, nonce floors/gaps, the RBF slot, and the
/// cumulative-debit bound all apply per signer, not only to `signers.first`.
final class MempoolMultiSignerTests: XCTestCase {

    private func wallet() -> Wallet { Wallet.create() }

    private func tx(_ w: Wallet, nonce: UInt64, fee: UInt64 = 10) -> Transaction {
        w.buildTransfer(to: w.address, amount: 1, fee: fee, nonce: nonce)!
    }

    /// A transaction whose body lists `signers` (in order) and is signed by all
    /// of their keypairs. `NodeMempool.addTransaction` does not verify
    /// signatures (the validator does), but we sign properly anyway.
    private func multiSignerTx(
        signers: [(kp: (privateKey: String, publicKey: String), address: String)],
        nonce: UInt64,
        fee: UInt64
    ) -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: signers.map { $0.address },
            fee: fee,
            nonce: nonce
        )
        // known-valid local node; CID cannot fail
        let h = try! HeaderImpl<TransactionBody>(node: body)
        var signatures: [String: String] = [:]
        for signer in signers {
            signatures[signer.kp.publicKey] = TransactionSigning.sign(
                bodyHeader: h, privateKeyHex: signer.kp.privateKey
            )!
        }
        return Transaction(signatures: signatures, body: h)
    }

    private func keyedWallet() -> (kp: (privateKey: String, publicKey: String), address: String) {
        let kp = CryptoUtils.generateKeyPair()
        return (kp: kp, address: addr(kp.publicKey))
    }

    // MARK: - (M14)

    func testBulkPrunePreservesRefreshedNonceFloor() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()

        // Raise the floor with no resident txs (admission-time refresh path),
        // then admit at exactly the floor.
        await mempool.refreshConfirmedNonce(sender: w.address, nonce: 5)
        let t5 = tx(w, nonce: 5)
        guard case .added = await mempool.addTransaction(t5) else {
            return XCTFail("tx at the confirmed-nonce floor must be admissible")
        }

        // Bulk prune (block-confirmation path) drains the sender's queue.
        await mempool.removeAll(txCIDs: [t5.body.rawCID])
        let count = await mempool.count
        XCTAssertEqual(count, 0, "bulk prune must remove the entry")

        // The floor must survive the drain: a below-floor nonce is NOT re-admissible.
        switch await mempool.addTransaction(tx(w, nonce: 3)) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"),
                          "below-floor nonce must be rejected by the floor, got: \(reason)")
        case .added, .replacedExisting:
            XCTFail("removeAll dropped the confirmed-nonce floor; below-floor nonce 3 was re-admitted")
        }

        // The floor itself (nonce 5) must remain admissible.
        guard case .added = await mempool.addTransaction(tx(w, nonce: 5)) else {
            return XCTFail("nonce at the preserved floor must remain admissible after bulk prune")
        }
    }

    // MARK: - (M10)

    func testSecondarySignerSameNonceConflictIsNotIndependentlyAdmitted() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        // tx1: signed by A alone at nonce 0.
        let tx1 = multiSignerTx(signers: [a], nonce: 0, fee: 100)
        guard case .added = await mempool.addTransaction(tx1) else {
            return XCTFail("tx1 must be admitted")
        }

        // tx2: signed by [B, A] at the SAME nonce 0 but keyed (pre-fix) on B.
        // Consensus can only confirm one of the two (A's nonce advances once),
        // so the mempool must treat tx2 as conflicting with tx1's (A, 0) slot.
        // With a fee far below the RBF package requirement it must be rejected.
        let tx2 = multiSignerTx(signers: [b, a], nonce: 0, fee: 10)
        switch await mempool.addTransaction(tx2) {
        case .added:
            XCTFail("same-nonce conflict via secondary signer must not be admitted as an independent tx")
        case .replacedExisting:
            XCTFail("a below-package-fee replacement must not displace the resident")
        case .rejected:
            break
        }

        let tx1Resident = await mempool.contains(txCID: tx1.body.rawCID)
        let tx2Resident = await mempool.contains(txCID: tx2.body.rawCID)
        XCTAssertTrue(tx1Resident, "the original resident must survive a failed conflict admission")
        XCTAssertFalse(tx2Resident, "the conflicting tx must not be resident")
    }

    func testSecondarySignerSameNonceConflictReplacesViaRBF() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        let tx1 = multiSignerTx(signers: [a], nonce: 0, fee: 100)
        guard case .added = await mempool.addTransaction(tx1) else {
            return XCTFail("tx1 must be admitted")
        }

        // Pays the BIP125-style package fee (existing 100 + bump 100/10 + 1).
        let tx2 = multiSignerTx(signers: [b, a], nonce: 0, fee: 200)
        switch await mempool.addTransaction(tx2) {
        case .replacedExisting(let oldCID):
            XCTAssertEqual(oldCID, tx1.body.rawCID, "RBF must report the replaced resident")
        case .added:
            XCTFail("a same-nonce conflict via secondary signer must go through RBF, not independent admission")
        case .rejected(let reason):
            XCTFail("a package-fee-paying replacement must be accepted, got: \(reason)")
        }

        let tx1Resident = await mempool.contains(txCID: tx1.body.rawCID)
        let tx2Resident = await mempool.contains(txCID: tx2.body.rawCID)
        XCTAssertFalse(tx1Resident, "replaced tx must leave the pool")
        XCTAssertTrue(tx2Resident, "replacement must be resident")
    }

    func testCoSignerConfirmedNonceFloorRejectsStaleMultiSignerTx() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        // B's on-chain nonce is already 5; a multi-signer tx at nonce 0 is
        // consensus-invalid for B (nonceAlreadyUsed) even though A is fresh.
        await mempool.refreshConfirmedNonce(sender: b.address, nonce: 5)

        let stale = multiSignerTx(signers: [a, b], nonce: 0, fee: 10)
        switch await mempool.addTransaction(stale) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"),
                          "co-signer floor must reject the stale nonce, got: \(reason)")
        case .added, .replacedExisting:
            XCTFail("co-signer's confirmed-nonce floor must apply to multi-signer admission")
        }
    }

    func testCumulativeDebitBoundAppliesToCoSigner() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        // Two txs each debiting co-signer B by 8 against B's confirmed balance
        // of 10: individually affordable, cumulatively not.
        let t0 = multiSignerTx(signers: [a, b], nonce: 0, fee: 10)
        let t1 = multiSignerTx(signers: [a, b], nonce: 1, fee: 10)

        guard case .added = await mempool.addTransaction(
            t0, confirmedBalances: [b.address: 10], debits: [b.address: 8]
        ) else {
            return XCTFail("first co-signer debit within balance must be admitted")
        }
        switch await mempool.addTransaction(
            t1, confirmedBalances: [b.address: 10], debits: [b.address: 8]
        ) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Cumulative sender debit exceeds balance"),
                          "cumulative bound must apply to the co-signer, got: \(reason)")
        case .added, .replacedExisting:
            XCTFail("cumulative debit bound must track the co-signer, not only signers.first")
        }
    }

    func testConfirmingOneSignerEvictsEntryFromAllSignerQueues() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        let shared = multiSignerTx(signers: [a, b], nonce: 0, fee: 10)
        guard case .added = await mempool.addTransaction(shared) else {
            return XCTFail("multi-signer tx must be admitted")
        }

        // A block confirms a competing tx that advances A's nonce past 0: the
        // shared entry is stale and must leave EVERY signer's queue.
        await mempool.batchUpdateConfirmedNonces(updates: [(sender: a.address, nonce: 1)])
        let resident = await mempool.contains(txCID: shared.body.rawCID)
        XCTAssertFalse(resident, "stale multi-signer entry must be evicted")
        let count = await mempool.count
        XCTAssertEqual(count, 0)

        // B's nonce-0 slot must be genuinely free again (no ghost entry left in
        // B's queue): a fresh B-only tx at nonce 0 must be plain-admitted, not
        // forced through RBF against a ghost.
        let fresh = multiSignerTx(signers: [b], nonce: 0, fee: 10)
        guard case .added = await mempool.addTransaction(fresh) else {
            return XCTFail("co-signer's slot must be free after the shared entry was evicted")
        }
    }

    func testMultiSignerTxNotSelectedUntilEverySignerNonceMatches() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        // A expects nonce 1 next; B expects nonce 0. A shared tx at nonce 1 is
        // admissible (within B's gap) but NOT buildable: consensus would reject
        // it for B's nonce gap. Selection must skip it.
        await mempool.refreshConfirmedNonce(sender: a.address, nonce: 1)
        let shared = multiSignerTx(signers: [a, b], nonce: 1, fee: 10)
        guard case .added = await mempool.addTransaction(shared) else {
            return XCTFail("gapped multi-signer tx is admissible (gap <= maxNonceGap)")
        }

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertTrue(selected.isEmpty,
                      "multi-signer tx must not be selected while a co-signer's expected nonce does not match")

        // Once B's nonce-0 predecessor is selected the shared tx becomes
        // buildable in the same template.
        let b0 = multiSignerTx(signers: [b], nonce: 0, fee: 10)
        guard case .added = await mempool.addTransaction(b0) else {
            return XCTFail("B's nonce-0 tx must be admissible")
        }
        let selectedAfter = await mempool.selectTransactions(maxCount: 10)
        let cids = selectedAfter.map { $0.body.rawCID }
        XCTAssertEqual(Set(cids), Set([b0.body.rawCID, shared.body.rawCID]),
                       "both txs must be selected once every signer's nonce sequence is contiguous")
        XCTAssertEqual(cids.first, b0.body.rawCID, "B's nonce-0 tx must precede the shared nonce-1 tx")
    }
}
