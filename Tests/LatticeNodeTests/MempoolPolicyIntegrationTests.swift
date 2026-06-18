import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import Foundation

/// integration gate: a single mixed workload exercises all four mempool
/// policy children at once — fee-rate selection (A), BIP125 package RBF (B),
/// cheap-before-signature ordering is covered separately (C), and sub-quadratic
/// prune (D) — and confirms they compose. Drives the REAL
/// `NodeMempool.addTransaction` / `selectTransactions` / `pruneExpired`.
final class MempoolPolicyIntegrationTests: XCTestCase {

    private func small(_ w: Wallet, fee: UInt64, nonce: UInt64 = 0) -> Transaction {
        w.buildTransfer(to: w.address, amount: 1, fee: fee, nonce: nonce)!
    }

    private func bulky(_ w: Wallet, fee: UInt64, recipients: Int) -> Transaction {
        let actions = (0..<recipients).map { _ in AccountAction(owner: Wallet.create().address, delta: 1) }
        let body = TransactionBody(
            accountActions: [AccountAction(owner: w.address, delta: -Int64(recipients) - Int64(fee))] + actions,
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: fee, nonce: 0
        )
        // known-valid local node; CID cannot fail
        let header = try! HeaderImpl<TransactionBody>(node: body)
        return Transaction(signatures: [w.publicKeyHex: w.sign(body: body, bodyCID: header.rawCID)!], body: header)
    }

    func testEndToEndAdmitSelectPrune() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64)

        // 1) Varied byte sizes + fee-rates. A dense small tx and a fee-padded
        //    bulky tx (higher absolute fee, lower rate).
        let denseW = Wallet.create()
        let dense = small(denseW, fee: 500)
        let bulkyW = Wallet.create()
        let bulkyTx = bulky(bulkyW, fee: 1000, recipients: 400)
        guard case .added = await mempool.addTransaction(bulkyTx) else { return XCTFail("bulky admit") }
        guard case .added = await mempool.addTransaction(dense) else { return XCTFail("dense admit") }

        // Sanity: bulky pays more absolute fee but a lower per-byte rate.
        let denseBytes = UInt64(dense.body.node!.toData()!.count)
        let bulkyBytes = UInt64(bulkyTx.body.node!.toData()!.count)
        XCTAssertGreaterThan(500 * 1_000_000 / denseBytes, 1000 * 1_000_000 / bulkyBytes,
                             "premise: dense tx is the higher fee-rate")

        // 2) One RBF bump on a packaged sender: S has nonce0 fee=100 + nonce1
        //    fee=100 (package 200); bump nonce0 to 250 → package-correct replace.
        let s = Wallet.create()
        guard case .added = await mempool.addTransaction(small(s, fee: 100, nonce: 0)) else { return XCTFail() }
        guard case .added = await mempool.addTransaction(small(s, fee: 100, nonce: 1)) else { return XCTFail() }
        // Underpaying the package is rejected; covering it replaces.
        switch await mempool.addTransaction(small(s, fee: 150, nonce: 0)) {
        case .rejected: break
        default: XCTFail("under-package RBF must be rejected")
        }
        let bump = small(s, fee: 250, nonce: 0)
        switch await mempool.addTransaction(bump) {
        case .replacedExisting: break
        default: XCTFail("package-covering RBF must replace")
        }

        // 3) selectTransactions stays fee-rate-ordered: the dense tx (highest
        //    rate among the residents) is selected before the fee-padded bulky one.
        let selected = await mempool.selectTransactions(maxCount: 10)
        let denseIdx = selected.firstIndex { $0.body.rawCID == dense.body.rawCID }
        let bulkyIdx = selected.firstIndex { $0.body.rawCID == bulkyTx.body.rawCID }
        if let d = denseIdx, let b = bulkyIdx {
            XCTAssertLessThan(d, b, "dense high-rate tx must be selected before the fee-padded bulky one")
        } else {
            XCTFail("both dense and bulky txs must be selectable")
        }

        // 4) One expiry sweep, sub-quadratic: age everything past the cutoff and
        //    prune. The equal-tier scan-step counter must stay sub-quadratic.
        try? await Task.sleep(nanoseconds: 5_000_000)
        await mempool.resetRemovalScanSteps()
        let beforePrune = await mempool.count
        await mempool.pruneExpired(olderThan: .zero)
        let afterPrune = await mempool.count
        XCTAssertEqual(afterPrune, 0, "all aged entries pruned")
        let steps = await mempool.removalScanSteps()
        XCTAssertLessThan(steps, beforePrune * beforePrune,
                          "prune equal-tier scan must stay well below O(n²)")
    }
}
