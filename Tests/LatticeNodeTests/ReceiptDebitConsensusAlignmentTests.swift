import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Foundation

/// W2 interim for R6: receipt implicit-transfer accounting must match
/// consensus on EVERY chain.
///
/// Lattice's `LatticeState.proveAndUpdateState` applies the implicit receipt
/// transfer — debit(withdrawer, amountDemanded) / credit(demander,
/// amountDemanded) — for every block containing receiptActions, on ANY chain
/// (nexus or intermediate). The node's `TransactionValidator.computeNetDebit`
/// used to count those transfers only `if isNexus`, so on an intermediate
/// chain the mempool under-counted the withdrawer's outflow: a tx whose
/// receipt transfer exceeds the sender's balance was ADMITTED but can never
/// build (consensus rejects it at state application) — the M11
/// admitted-but-unbuildable churn class.
final class ReceiptDebitConsensusAlignmentTests: XCTestCase {

    private func signWith(_ body: TransactionBody, _ w: Wallet) -> Transaction {
        let h = try! HeaderImpl<TransactionBody>(node: body)
        let sig = w.sign(body: body, bodyCID: h.rawCID)!
        return Transaction(signatures: [w.publicKeyHex: sig], body: h)
    }

    /// An INTERMEDIATE-chain (isNexus: false) tx whose receipt transfer makes
    /// the sender over-budget must be rejected with `.insufficientBalance` —
    /// exactly what consensus does when the block applies the implicit
    /// transfer. (RED before the computeNetDebit alignment: the receipt debit
    /// was not counted off-nexus, so this validated `.success`.)
    func testIntermediateChainReceiptTransferCountsAgainstSenderBalance() async throws {
        let f = cas()
        let sender = Wallet.create()
        // `premine` is a BLOCK COUNT; the sender's credited balance is
        // spec.premineAmount() (the summed rewards over those blocks).
        let spec = testSpec("Mid", premine: 100)
        let balance = spec.premineAmount()
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: sender.address, delta: Int64(spec.premineAmount()))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [sender.address], fee: 0, nonce: 0, chainPath: ["Nexus", "Mid"]
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [signWith(premineBody, sender)],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // Receipt demanding MORE than the sender's whole balance. Conservation
        // holds via an explicit 1-unit debit covering the fee (receipt
        // transfers are implicit and outside the conservation equation).
        let body = TransactionBody(
            accountActions: [AccountAction(owner: sender.address, delta: -1)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(
                withdrawer: sender.address,
                nonce: 0,
                demander: Wallet.create().address,
                amountDemanded: balance * 2,
                directory: "Leaf"
            )],
            withdrawalActions: [],
            signers: [sender.address], fee: 1, nonce: 1, chainPath: ["Nexus", "Mid"]
        )
        let tx = signWith(body, sender)

        let validator = TransactionValidator(
            fetcher: f,
            chainState: chain,
            expectedChainPath: ["Nexus", "Mid"],
            isNexus: false
        )
        let result = await validator.validate(tx).result
        switch result {
        case .failure(.insufficientBalance):
            break // aligned with consensus: the implicit transfer is unaffordable
        case .success:
            XCTFail("M11: over-budget receipt transfer admitted on an intermediate chain — consensus will reject the block it lands in")
        default:
            XCTFail("expected .insufficientBalance, got \(result)")
        }
    }

    /// The per-signer debit the mempool's cumulative bound tracks must be the
    /// SAME on every chain — `netDebits` may not depend on `isNexus`.
    func testNetDebitsAgreeAcrossChainKinds() throws {
        let sender = Wallet.create().address
        let other = Wallet.create().address
        let body = TransactionBody(
            accountActions: [AccountAction(owner: sender, delta: -30)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: sender, nonce: 0, demander: other, amountDemanded: 70, directory: "Leaf")],
            withdrawalActions: [],
            signers: [sender], fee: 0, nonce: 0
        )
        let fetcher = cas()
        let chainState = try ChainState(
            chainTip: "", mainChainHashes: [], indexToBlockHash: [:],
            hashToBlock: [:], parentChainBlockHashToBlockHash: [:]
        )
        let childValidator = TransactionValidator(fetcher: fetcher, chainState: chainState, isNexus: false)
        let nexusValidator = TransactionValidator(fetcher: fetcher, chainState: chainState, isNexus: true)
        // Consensus applies the implicit receipt transfer on EVERY chain:
        // explicit 30 + implicit 70 = 100, regardless of chain kind.
        XCTAssertEqual(childValidator.senderNetDebit(body, sender: sender), 100)
        XCTAssertEqual(
            childValidator.senderNetDebit(body, sender: sender),
            nexusValidator.senderNetDebit(body, sender: sender),
            "net-debit semantics must not fork on isNexus"
        )
    }
}
