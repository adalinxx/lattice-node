import XCTest
@testable import Lattice
@testable import LatticeNode
import Foundation

/// MEM-A2 : cumulative per-sender double-spend bound at admission.
///
/// Each tx is independently affordable against the sender's confirmed balance,
/// but they all draw from the SAME balance. The per-tx consensus balance check
/// runs INDEPENDENTLY per transaction, so it cannot see that k txs at distinct
/// nonces, each <= balance, cumulatively exceed it. Only the mempool — which
/// holds the sender's entire queue — can enforce the cumulative bound.
///
/// The bound lives at the admission seam: the confirmed balance is resolved
/// once from the locked frontier view and threaded into `addTransaction`, so
/// the cumulative check and the insert are one actor-atomic step. The mempool
/// holds NO balance oracle. These unit tests exercise that API directly; the
/// full validate->insert path (and the concurrency TOCTOU) is covered at the
/// node level in `SecurityTests` (testCumulativeCrossNonceDebitRejected /
/// testConcurrentCrossNonceSubmitsCannotOverspend).
final class MempoolCumulativeDoubleSpendTests: XCTestCase {

    private func transfer(_ w: Wallet, amount: UInt64, fee: UInt64, nonce: UInt64) -> Transaction {
        w.buildTransfer(to: Wallet.create().address, amount: amount, fee: fee, nonce: nonce)!
    }

    /// The per-tx sender net-debit the admission seam threads into addTransaction,
    /// computed by the SHARED validator helper (no duplicated semantics in the test).
    private func senderDebit(of tx: Transaction, sender: String, isNexus: Bool = false) -> UInt64 {
        let validator = TransactionValidator(
            fetcher: cas(),
            chainState: try! ChainState(
                chainTip: "", mainChainHashes: [], indexToBlockHash: [:],
                hashToBlock: [:], parentChainBlockHashToBlockHash: [:]
            ),
            isNexus: isNexus
        )
        return validator.senderNetDebit(tx.body.node!, sender: sender)
    }

    /// Balance = 100. Three txs each debiting 60 (amount 50 + fee 10): each is
    /// individually affordable, but two already exceed 100. The bound admits the
    /// first, rejects the second once cumulative (120) > balance.
    func testCumulativeOverBudgetTxIsRejected() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64)
        let w = Wallet.create()

        // nonce 0: cumulative 60 <= 100 -> admitted
        let tx0 = transfer(w, amount: 50, fee: 10, nonce: 0)
        switch await mempool.addTransaction(tx0, confirmedBalance: 100, senderDebit: senderDebit(of: tx0, sender: w.address)) {
        case .added: break
        default: XCTFail("first affordable tx must be admitted")
        }

        // nonce 1: cumulative 120 > 100 -> rejected by the cumulative bound,
        // even though THIS tx (debit 60) is individually < balance.
        let tx1 = transfer(w, amount: 50, fee: 10, nonce: 1)
        let second = await mempool.addTransaction(tx1, confirmedBalance: 100, senderDebit: senderDebit(of: tx1, sender: w.address))
        switch second {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Cumulative sender debit"), "expected cumulative-bound rejection, got: \(reason)")
        default:
            XCTFail("cumulatively-overspending tx must be rejected, got \(second)")
        }
    }

    /// The bound is inert when no balance is supplied (legacy behavior): a caller
    /// that admits without a resolved balance keeps the prior semantics.
    func testNoBoundWhenBalanceUnknown() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64)
        let w = Wallet.create()
        // No confirmedBalance argument — both admitted (no cumulative gate).
        switch await mempool.addTransaction(transfer(w, amount: 50, fee: 10, nonce: 0)) {
        case .added: break
        default: XCTFail("first tx must be admitted")
        }
        switch await mempool.addTransaction(transfer(w, amount: 50, fee: 10, nonce: 1)) {
        case .added: break
        default: XCTFail("with no supplied balance the bound is inert; second must be admitted too")
        }
    }

    /// The cumulative bound's per-tx debit is computed by `TransactionValidator`
    /// (the shared `senderNetDebit`, which reuses the same `computeNetDebit` the
    /// per-tx `validateBalances` uses — no duplicated semantics). It mirrors
    /// `validateBalances`: account-action deltas plus the implicit receipt
    /// withdrawer-debit, counted on EVERY chain — Lattice's proveAndUpdateState
    /// applies receipt transfers wherever receiptActions appear, so the mempool
    /// must too (W2 interim for R6; see ReceiptDebitConsensusAlignmentTests).
    func testSenderDebitMatchesValidateBalancesReceiptSemantics() {
        let sender = Wallet.create().address
        let other = Wallet.create().address
        let body = TransactionBody(
            accountActions: [AccountAction(owner: sender, delta: -30)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: sender, nonce: 0, demander: other, amountDemanded: 70, directory: "Child")],
            withdrawalActions: [],
            signers: [sender], fee: 0, nonce: 0
        )
        // senderNetDebit is a pure computation over the body — it never touches the
        // fetcher or chain state — so a minimal ChainState/fetcher suffices.
        let fetcher = cas()
        let chainState = try! ChainState(
            chainTip: "",
            mainChainHashes: [],
            indexToBlockHash: [:],
            hashToBlock: [:],
            parentChainBlockHashToBlockHash: [:]
        )
        // Intermediate chain (isNexus: false): the implicit receipt debit(70)
        // counts on every chain (consensus alignment) -> 30 + 70 = 100.
        let childValidator = TransactionValidator(fetcher: fetcher, chainState: chainState, isNexus: false)
        XCTAssertEqual(childValidator.senderNetDebit(body, sender: sender), 100)
        // Nexus (isNexus: true): identical — net-debit semantics don't fork on chain kind.
        let nexusValidator = TransactionValidator(fetcher: fetcher, chainState: chainState, isNexus: true)
        XCTAssertEqual(nexusValidator.senderNetDebit(body, sender: sender), 100)
    }
}
