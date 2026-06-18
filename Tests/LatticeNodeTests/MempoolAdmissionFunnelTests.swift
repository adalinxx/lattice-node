import XCTest
@testable import Lattice
@testable import LatticeNode
import Foundation
import cashew

/// R4: characterization of the twin admission funnels
/// (`admitToMempoolAdmission(directory:)` vs `(chainPath:)`) BEFORE collapsing
/// them into one. These pin the externally observable behavior of the bits the
/// two hand-maintained copies had diverged on:
///
///   1. `isNexus` — computed by two different formulas (directory: genesis-dir
///      + fullChainPath shape; chainPath: `count == 1`). Both must agree for a
///      standard nexus node AND for a per-process child node.
///   2. `allowWithdrawalWithoutDeposit` (M9) — only the directory variant
///      tolerates the typed `.withdrawalWithoutDeposit` failure on the reorg
///      recovery path, and only it runs the balance-resolve fallback so the
///      cumulative bound still applies to the re-admit.
///   3. P-902 — an admitted tx is immediately selectable (post-add confirmed
///      nonce seeding works through the funnel).
///
/// The tests must pass IDENTICALLY before and after the collapse.
final class MempoolAdmissionFunnelTests: XCTestCase {

    private func makeNode(
        spec: ChainSpec? = nil,
        fullChainPath: [String]? = nil
    ) async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false,
            fullChainPath: fullChainPath,
            minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis(spec: spec))
        addTeardownBlock { [node] in await node.stop() }
        return node
    }

    private func signWith(_ body: TransactionBody, _ w: Wallet) -> Transaction {
        let h = try! HeaderImpl<TransactionBody>(node: body)
        let sig = w.sign(body: body, bodyCID: h.rawCID)!
        return Transaction(signatures: [w.publicKeyHex: sig], body: h)
    }

    private func outcome(_ admission: MempoolAdmission) -> (message: String?, consensusClass: ConsensusClass?) {
        switch admission.result {
        case .added, .replacedExisting:
            return (nil, admission.consensusClass)
        case .rejected(let reason):
            return (reason.message, admission.consensusClass)
        }
    }

    /// A conservation-valid withdrawal whose backing deposit does not exist in
    /// the current state: debits + withdrawn == credits + fee
    /// (0 + 50 == 40 + 10). Fails validation with the typed
    /// `.withdrawalWithoutDeposit` on a non-nexus chain.
    private func withdrawalWithoutDepositTx(_ w: Wallet, chainPath: [String], nonce: UInt64 = 0) -> Transaction {
        let withdrawn: UInt64 = 50
        let fee: UInt64 = 10
        let body = TransactionBody(
            accountActions: [AccountAction(owner: w.address, delta: Int64(withdrawn - fee))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: w.address,
                nonce: 0,
                demander: w.address,
                amountDemanded: withdrawn,
                amountWithdrawn: withdrawn
            )],
            signers: [w.address], fee: fee, nonce: nonce, chainPath: chainPath
        )
        return signWith(body, w)
    }

    // MARK: - 1. directory vs chainPath equivalence on a nexus node

    /// The genesis chain of a standard node (fullChainPath == nil) is the
    /// nexus under BOTH variants' isNexus formulas: a deposit action must be
    /// rejected with the same nexus-only error, same consensus class, through
    /// either entry point. Also pins two validator-failure categories
    /// (insufficient balance, chainPath mismatch) to identical outcomes.
    func testDirectoryAndChainPathVariantsAgreeOnNexusNode() async throws {
        let node = try await makeNode()
        let w = Wallet.create()

        // (a) isNexus: deposit actions are nexus-forbidden. The shape gate
        // fires before signature/state checks, so an unfunded wallet suffices.
        let depositBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [
                DepositAction(nonce: 0, demander: w.address, amountDemanded: 10, amountDeposited: 10)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let depositTx = signWith(depositBody, w)
        let viaDirectory = outcome(await node.admitToMempoolAdmission(transaction: depositTx, directory: "Nexus"))
        let viaChainPath = outcome(await node.admitToMempoolAdmission(transaction: depositTx, chainPath: ["Nexus"]))
        XCTAssertEqual(viaDirectory.message, "Deposit and withdrawal actions are not allowed on the nexus chain")
        XCTAssertEqual(viaDirectory.message, viaChainPath.message, "isNexus must agree between funnel variants")
        XCTAssertEqual(viaDirectory.consensusClass, .consensusInvalid)
        XCTAssertEqual(viaChainPath.consensusClass, .consensusInvalid)

        // (b) validator failure (insufficient balance) — identical outcome.
        let unfunded = w.buildTransfer(to: Wallet.create().address, amount: 5, fee: 1, nonce: 0, chainPath: ["Nexus"])!
        let dirUnfunded = outcome(await node.admitToMempoolAdmission(transaction: unfunded, directory: "Nexus"))
        let pathUnfunded = outcome(await node.admitToMempoolAdmission(transaction: unfunded, chainPath: ["Nexus"]))
        XCTAssertEqual(dirUnfunded.message, "Insufficient balance")
        XCTAssertEqual(dirUnfunded.message, pathUnfunded.message)
        XCTAssertEqual(dirUnfunded.consensusClass, .missingInput)
        XCTAssertEqual(pathUnfunded.consensusClass, .missingInput)

        // (c) chainPath mismatch — identical outcome.
        let wrongPath = w.buildTransfer(to: Wallet.create().address, amount: 5, fee: 1, nonce: 0, chainPath: ["Other"])!
        let dirWrong = outcome(await node.admitToMempoolAdmission(transaction: wrongPath, directory: "Nexus"))
        let pathWrong = outcome(await node.admitToMempoolAdmission(transaction: wrongPath, chainPath: ["Nexus"]))
        XCTAssertEqual(dirWrong.message, "Transaction chainPath does not match this chain")
        XCTAssertEqual(dirWrong.message, pathWrong.message)
        XCTAssertEqual(dirWrong.consensusClass, .consensusInvalid)
        XCTAssertEqual(pathWrong.consensusClass, .consensusInvalid)
    }

    // MARK: - 2. per-process child node: isNexus=false + M9 toleration

    /// On a per-process child node (fullChainPath = [Nexus, Mid], genesis dir
    /// "Mid"), BOTH variants must treat the chain as non-nexus, and a
    /// withdrawal whose backing deposit is absent must be rejected with the
    /// typed withdrawal-without-deposit failure — through either entry point.
    func testWithdrawalWithoutDepositRejectedOnChildNodeViaBothVariants() async throws {
        let node = try await makeNode(spec: testSpec("Mid"), fullChainPath: ["Nexus", "Mid"])
        let w = Wallet.create()
        let tx = withdrawalWithoutDepositTx(w, chainPath: ["Nexus", "Mid"])

        let viaDirectory = outcome(await node.admitToMempoolAdmission(transaction: tx, directory: "Mid"))
        let viaChainPath = outcome(await node.admitToMempoolAdmission(transaction: tx, chainPath: ["Nexus", "Mid"]))
        // isNexus=false under both formulas: the failure is the deposit
        // pre-filter, NOT the nexus shape gate.
        XCTAssertEqual(viaDirectory.message, "Withdrawal rejected: no corresponding deposit found in current state")
        XCTAssertEqual(viaDirectory.message, viaChainPath.message, "non-nexus classification must agree between variants")
        XCTAssertEqual(viaDirectory.consensusClass, .missingInput)
        XCTAssertEqual(viaChainPath.consensusClass, .missingInput)
    }

    /// M9: with `allowWithdrawalWithoutDeposit: true` (the reorg orphan
    /// recovery flag) the SAME transaction is tolerated and admitted through
    /// the cumulative-bound seam — including the balance-resolve fallback
    /// (the validator short-circuited before resolving balances) — and is
    /// immediately selectable (P-902 post-add nonce seeding).
    func testRecoveryFlagToleratesWithdrawalWithoutDepositAndAdmits() async throws {
        let node = try await makeNode(spec: testSpec("Mid"), fullChainPath: ["Nexus", "Mid"])
        let w = Wallet.create()
        let tx = withdrawalWithoutDepositTx(w, chainPath: ["Nexus", "Mid"])

        let admission = await node.admitToMempoolAdmission(
            transaction: tx,
            directory: "Mid",
            allowWithdrawalWithoutDeposit: true
        )
        guard case .added = admission.result else {
            return XCTFail("M9: recovery flag must tolerate withdrawal-without-deposit, got \(admission.result)")
        }

        let networkMaybe = await node.network(for: "Mid")
        let network = try XCTUnwrap(networkMaybe)
        let contained = await network.nodeMempool.contains(txCID: tx.body.rawCID)
        XCTAssertTrue(contained, "tolerated withdrawal must be resident in the chain's mempool")

        // P-902: post-add confirmed-nonce seeding makes the tx selectable.
        let selected = await network.nodeMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.map { $0.body.rawCID }, [tx.body.rawCID],
            "P-902: tx admitted through the funnel must be immediately selectable")

        // A resubmission WITHOUT the recovery flag re-runs the validator and
        // is rejected on withdrawal-without-deposit BEFORE the mempool's
        // duplicate check — the toleration never leaks outside the flag.
        let dup = await node.admitToMempoolAdmission(transaction: tx, chainPath: ["Nexus", "Mid"])
        guard case .rejected(let reason) = dup.result else {
            return XCTFail("unflagged resubmission must be rejected, got \(dup.result)")
        }
        XCTAssertEqual(reason.message, "Withdrawal rejected: no corresponding deposit found in current state")
    }

    /// Without the recovery flag, the chainPath variant rejects the same tx —
    /// the flag is an explicit opt-in for the recovery path only.
    func testChainPathVariantWithoutFlagStillRejects() async throws {
        let node = try await makeNode(spec: testSpec("Mid"), fullChainPath: ["Nexus", "Mid"])
        let w = Wallet.create()
        let tx = withdrawalWithoutDepositTx(w, chainPath: ["Nexus", "Mid"])

        let admission = await node.admitToMempoolAdmission(transaction: tx, chainPath: ["Nexus", "Mid"])
        guard case .rejected(let reason) = admission.result else {
            return XCTFail("without the flag the withdrawal must be rejected, got \(admission.result)")
        }
        XCTAssertEqual(reason.message, "Withdrawal rejected: no corresponding deposit found in current state")
        XCTAssertEqual(admission.consensusClass, .missingInput)
    }
}
