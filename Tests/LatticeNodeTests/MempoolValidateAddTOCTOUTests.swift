import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import Foundation

/// MEM-A3 : the validate -> add window is a TOCTOU race.
///
/// `admitToMempool` validates a transaction (resolving on-chain balance OUTSIDE
/// the mempool actor) and then calls `addTransaction` (INSIDE the actor). Two
/// concurrent submits from one sender, each draining the sender's full balance
/// at DISTINCT nonces, BOTH pass the independent per-tx balance validation —
/// each sees the full on-chain balance. If the mempool merely trusted that
/// validation, both would be admitted and the node would hold (and could pack)
/// a doubly-spending pair.
///
/// The fix is an atomic locked-view re-check INSIDE the actor: admission seeds
/// the sender's confirmed balance and `addTransaction` enforces the cumulative
/// per-sender debit bound under the actor's serialized execution. Concurrent
/// `admitToMempool` calls therefore serialize through the actor and at most one
/// of the two balance-exhausting txs is admitted.
///
/// Entry point: concurrent `admitToMempool` through the real node + actor.
final class MempoolValidateAddTOCTOUTests: XCTestCase {

    private func makeNode(_ port: UInt16, dir: URL, genesis: GenesisConfig, kp: (privateKey: String, publicKey: String)) async throws -> LatticeNode {
        try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: port, storagePath: dir,
                enableLocalDiscovery: false, persistInterval: 1, minPeerKeyBits: 0
            ),
            genesisConfig: genesis
        )
    }

    func testConcurrentBalanceExhaustingSubmitsAdmitAtMostOne() async throws {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = CryptoUtils.createAddress(from: receiver.publicKey)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let genesis = testGenesis()
        let node = try await makeNode(port, dir: tmpDir, genesis: genesis, kp: kp)
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(2, on: node)

        let balance = (try? await node.getBalance(address: minerAddr)) ?? 0
        guard balance > 4 else { await node.stop(); return }

        // Two txs at consecutive nonces, EACH draining (nearly) the full balance.
        // Individually each is valid against the on-chain balance; together they
        // demand ~2x the balance. fee=1 each; amount chosen so amount+fee per tx
        // is close to the whole balance.
        let nonce0 = (try? await node.getNonce(address: minerAddr)) ?? 0
        let perTxAmount = balance - 1            // amount + fee(1) == balance
        func drainTx(nonce: UInt64) -> Transaction {
            let body = TransactionBody(
                accountActions: [
                    AccountAction(owner: minerAddr, delta: -(Int64(perTxAmount) + 1)),
                    AccountAction(owner: receiverAddr, delta: Int64(perTxAmount))
                ],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 1, nonce: nonce, chainPath: ["Nexus"]
            )
            // known-valid local node; CID cannot fail
            let h = try! HeaderImpl<TransactionBody>(node: body)
            let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
            return Transaction(signatures: [kp.publicKey: sig], body: h)
        }
        let txA = drainTx(nonce: nonce0)
        let txB = drainTx(nonce: nonce0 + 1)

        // Fire both admissions concurrently through the real entry point.
        async let rA = node.admitToMempool(transaction: txA, directory: "Nexus")
        async let rB = node.admitToMempool(transaction: txB, directory: "Nexus")
        let results = [await rA, await rB]

        let admittedCount = results.filter {
            switch $0 { case .added, .replacedExisting: return true; case .rejected: return false }
        }.count

        XCTAssertLessThanOrEqual(admittedCount, 1, "at most one balance-exhausting tx may be admitted; the cumulative bound must close the validate->add race")

        // The resident mempool must likewise hold at most one tx from this sender.
        let resident = await node.network(for: "Nexus")?.nodeMempool.count ?? 0
        XCTAssertLessThanOrEqual(resident, 1, "mempool must not retain a doubly-spending pair")

        await node.stop()
    }
}
