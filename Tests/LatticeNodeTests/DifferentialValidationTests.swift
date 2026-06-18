import XCTest
@testable import Lattice
@testable import LatticeNode

/// — mempool ⊇ block differential.
///
/// Property under test: there is no transaction the mempool accepts that block
/// validation rejects (mempool-accept ⊆ block-accept). The test drives the REAL
/// entry points — `submitTransactionWithReason` (mempool admission),
/// `selectTransactions` (block assembly), and `produceAndSubmitBlock` (full
/// block validation + apply) — over representative transfer and action
/// transactions, then asserts the produced block was accepted and left a pinned
/// deterministic post-state root.
///
/// (The macOS↔Linux host-determinism golden vectors + the Linux CI lane for
/// live in the Lattice repo, where the WasmPolicy evaluator / canonical
/// encoder / `executionFeatureSet` profile pin live.)
final class DifferentialValidationTests: XCTestCase {
    private let senderPrivateKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let receiverPrivateKey = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
    private let coinbaseAuthorityPrivateKey = "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"

    func testTRE127MempoolAcceptedTransactionsAreBlockAcceptedWithDeterministicStateRoot() async throws {
        let sender = try XCTUnwrap(Wallet.fromPrivateKey(senderPrivateKey))
        let receiver = try XCTUnwrap(Wallet.fromPrivateKey(receiverPrivateKey))
        let coinbaseAuthority = try XCTUnwrap(Wallet.fromPrivateKey(coinbaseAuthorityPrivateKey))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let authorityFile = [
            "publicKey": coinbaseAuthority.publicKeyHex,
            "privateKey": coinbaseAuthority.privateKeyHex,
        ]
        try JSONEncoder().encode(authorityFile).write(
            to: tmp.appendingPathComponent("coinbase-authority.json"),
            options: [.atomic]
        )

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: sender.publicKeyHex,
                privateKey: sender.privateKeyHex,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        try await mineBlocks(2, on: node)
        let startNonce = try await node.getNonce(address: sender.address)
        guard let preChain = await node.chain(for: "Nexus") else {
            XCTFail("missing Nexus chain before differential block")
            return
        }
        guard let preSnapshot = await preChain.tipSnapshot else {
            XCTFail("missing Nexus tip snapshot before differential block")
            return
        }
        let preRoot = preSnapshot.postStateCID

        let transfer = try XCTUnwrap(sender.buildTransfer(
            to: receiver.address,
            amount: 7,
            fee: 1,
            nonce: startNonce,
            chainPath: ["Nexus"]
        ))
        let action = try XCTUnwrap(sender.buildActionTransaction(
            actions: [Action(key: "tre127/differential", oldValue: nil, newValue: "deterministic-value")],
            fee: 1,
            nonce: startNonce + 1,
            chainPath: ["Nexus"]
        ))

        // Mempool admission — the LHS of the differential.
        guard case .success = await node.submitTransactionWithReason(directory: "Nexus", transaction: transfer) else {
            XCTFail("valid transfer must enter mempool")
            return
        }
        guard case .success = await node.submitTransactionWithReason(directory: "Nexus", transaction: action) else {
            XCTFail("valid action tx must enter mempool")
            return
        }

        guard let mempool = await node.network(for: "Nexus")?.nodeMempool else {
            XCTFail("missing Nexus mempool")
            return
        }
        let acceptedMempoolCount = await mempool.count
        XCTAssertEqual(acceptedMempoolCount, 2)
        let selected = await mempool.selectTransactions(maxCount: 10)
        let selectedCIDs = Set(selected.map(\.body.rawCID))
        XCTAssertEqual(selectedCIDs, Set([transfer.body.rawCID, action.body.rawCID]))

        // Block validation — the RHS. Every selected mempool tx must survive it.
        let blockAccepted = await node.produceAndSubmitBlock()
        XCTAssertTrue(blockAccepted, "every selected mempool tx must survive block validation")
        try await Task.sleep(for: .milliseconds(100))

        let remainingMempoolCount = await mempool.count
        XCTAssertEqual(remainingMempoolCount, 0)
        let receiverBalance = try await node.getBalance(address: receiver.address)
        XCTAssertEqual(receiverBalance, 7)
        guard let postChain = await node.chain(for: "Nexus") else {
            XCTFail("missing Nexus chain after differential block")
            return
        }
        guard let postSnapshot = await postChain.tipSnapshot else {
            XCTFail("missing Nexus tip snapshot after differential block")
            return
        }
        let postRoot = postSnapshot.postStateCID
        XCTAssertNotEqual(preRoot, postRoot)
        XCTAssertEqual(postRoot, Self.goldenPostStateRoot)
    }

    private static let goldenPostStateRoot = "bafyreiggm6qlutjrqmqu2jqewsxqiwqvnwno5p6quztw3ayrchu2vxveha"
}
