import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Lattice
@testable import LatticeNode
import Ivy
import UInt256
import cashew
import VolumeBroker

/// M11 on every template path: the trial-rebuild fallback retains temporarily-
/// unbuildable WITHDRAWAL transactions only up to
/// `TemplateAssembly.maxRetainedUnbuildableWithdrawals` and evicts the overflow.
/// BlockProducer.buildNexusTemplate enforced this; the four RPC template/candidate
/// copies in RPCServer+TemplateRoutes retained unbuildable withdrawals UNBOUNDED.
/// All five sites now share `TemplateAssembly.buildWithFallback` — tested here
/// directly (the dialect + the bound) and through the REAL /chain/template route.
final class TemplateAssemblyBoundTests: XCTestCase {

    // MARK: - Fixtures

    /// A withdrawal tx whose backing deposit does not exist: conservation-shaped
    /// (debits + withdrawn == credits + fee) so it is mempool-admissible, but
    /// `DepositState.proveAndDeleteForWithdrawals` throws (non-nonceGap) when a
    /// block including it is built.
    private func unbuildableWithdrawalTx(chainPath: [String] = ["Nexus"]) throws -> Transaction {
        let wallet = Wallet.create()
        let withdrawn: UInt64 = 50
        let fee: UInt64 = 10
        let body = TransactionBody(
            accountActions: [AccountAction(owner: wallet.address, delta: Int64(withdrawn - fee))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: wallet.address,
                nonce: 0,
                demander: wallet.address,
                amountDemanded: withdrawn,
                amountWithdrawn: withdrawn
            )],
            signers: [wallet.address], fee: fee, nonce: 0, chainPath: chainPath
        )
        let header = try HeaderImpl<TransactionBody>(node: body)
        let sig = try XCTUnwrap(wallet.sign(body: body, bodyCID: header.rawCID))
        return Transaction(signatures: [wallet.publicKeyHex: sig], body: header)
    }

    private func genesisBlock() async throws -> Block {
        try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: now() - 10_000, target: UInt256.max, fetcher: cas()
        )
    }

    // MARK: - Helper dialect (unit)

    /// Generic (non-nonceGap) failure where NO transaction builds: withdrawals are
    /// retained only up to the M11 bound; the overflow is evicted from the mempool.
    func testTrialRebuildBoundsRetainedUnbuildableWithdrawals() async throws {
        let bound = TemplateAssembly.maxRetainedUnbuildableWithdrawals
        let txs = try (0..<(bound + 6)).map { _ in try unbuildableWithdrawalTx() }
        let emptyBlock = try await genesisBlock()

        var evicted: [String] = []
        let result = try await TemplateAssembly.buildWithFallback(
            directory: "Nexus",
            context: "test template",
            transactions: txs,
            hasCoinbase: false,
            build: { candidate in
                if candidate.isEmpty { return emptyBlock }
                throw StateErrors.conflictingActions
            },
            removeFromMempool: { evicted.append($0) }
        )
        XCTAssertTrue(result.transactions.isEmpty,
            "with every trial build failing, the fallback is an empty block")
        XCTAssertEqual(evicted.count, 6,
            "exactly the overflow beyond maxRetainedUnbuildableWithdrawals must be evicted")
        // The evicted CIDs are real overflow members, not duplicates.
        XCTAssertEqual(Set(evicted).count, 6)
    }

    /// nonceGap on the full build falls straight to an empty block — no per-tx
    /// trial rebuild, no evictions (the BlockProducer dialect, now unified).
    func testNonceGapFallsStraightToEmptyWithoutEviction() async throws {
        let txs = try (0..<3).map { _ in try unbuildableWithdrawalTx() }
        let emptyBlock = try await genesisBlock()

        var evicted: [String] = []
        var attempts = 0
        let result = try await TemplateAssembly.buildWithFallback(
            directory: "Nexus",
            context: "test template",
            transactions: txs,
            hasCoinbase: false,
            build: { candidate in
                attempts += 1
                if candidate.isEmpty { return emptyBlock }
                throw StateErrors.nonceGap
            },
            removeFromMempool: { evicted.append($0) }
        )
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertTrue(evicted.isEmpty, "nonceGap fallback must not evict — it never enters the trial loop")
        XCTAssertEqual(attempts, 2, "exactly one full build + one empty build")
    }

    /// The coinbase (transactions.last when hasCoinbase) survives a successful
    /// trial rebuild and is re-appended after the kept user txs.
    func testTrialRebuildKeepsCoinbaseLast() async throws {
        let goodTx = try unbuildableWithdrawalTx()   // "good" by stub: see build closure
        let badTx = try unbuildableWithdrawalTx()
        let coinbase = try unbuildableWithdrawalTx() // stands in for the coinbase slot
        let block = try await genesisBlock()

        var evicted: [String] = []
        let result = try await TemplateAssembly.buildWithFallback(
            directory: "Nexus",
            context: "test template",
            transactions: [goodTx, badTx, coinbase],
            hasCoinbase: true,
            build: { candidate in
                // Full build (3 txs) fails; any candidate containing badTx fails;
                // [goodTx, coinbase] builds.
                if candidate.count == 3 { throw StateErrors.conflictingActions }
                if candidate.contains(where: { $0.body.rawCID == badTx.body.rawCID }) {
                    throw StateErrors.conflictingActions
                }
                return block
            },
            removeFromMempool: { evicted.append($0) }
        )
        XCTAssertEqual(result.transactions.map(\.body.rawCID),
                       [goodTx.body.rawCID, coinbase.body.rawCID],
                       "kept user txs first, coinbase re-appended last")
        XCTAssertTrue(evicted.isEmpty,
            "badTx is a withdrawal within the M11 bound: retained, not evicted")
    }

    // MARK: - /chain/template route (integration)

    /// M11 through the REAL production template route: flood the mempool with
    /// more unbuildable withdrawals than the bound, request a template, and the
    /// route's trial-rebuild fallback must evict the overflow. RED before the
    /// fix: the route's inline fallback copy retained ALL unbuildable
    /// withdrawals unbounded (only BlockProducer's internal path was capped).
    func testTemplateRouteBoundsRetainedUnbuildableWithdrawals() async throws {
        let bound = TemplateAssembly.maxRetainedUnbuildableWithdrawals
        let overflow = 6

        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let nodeConfig = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false,
            minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: nodeConfig, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)

        // Flood: bound + overflow withdrawal txs whose deposits don't exist.
        // Bare mempool insert (validation is not under test; the route's
        // build-fallback eviction is).
        for _ in 0..<(bound + overflow) {
            let tx = try unbuildableWithdrawalTx()
            let added = await network.nodeMempool.add(transaction: tx)
            XCTAssertTrue(added, "fixture: withdrawal tx must be mempool-admissible")
        }
        let resident = await network.nodeMempool.allTransactions().count
        XCTAssertEqual(resident, bound + overflow, "fixture: all withdrawals resident before the template request")

        // Drive the REAL route.
        let port = nextTestPort()
        let (server, token) = try makeAdminRPCServer(node: node, port: port)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: port)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/chain/template")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chainPath": ["Nexus"]])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200,
            "the unbuildable-withdrawal flood degrades to an empty template, not an error: \(String(data: data, encoding: .utf8) ?? "")")

        let retained = await network.nodeMempool.allTransactions().count
        XCTAssertEqual(retained, bound,
            "the template route must retain at most maxRetainedUnbuildableWithdrawals (M11) and evict the overflow")
    }
}
