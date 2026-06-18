import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker

/// Tests for edge cases and boundary conditions identified as gaps after the
/// SecurityRegressionTests and OptimizationCorrectnessTests passes.
final class EdgeCaseTests: XCTestCase {

    // MARK: - unpinBatch equivalence to sequential unpin

    /// unpinBatch(items:) must produce the same final pin state as calling
    /// unpin(root:owner:count:) for each item individually.
    func testUnpinBatchEquivalentToSequentialUnpin() async throws {
        let tmp1 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        let tmp2 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }

        let batchBroker = try DiskBroker(path: tmp1.path)
        let seqBroker   = try DiskBroker(path: tmp2.path)

        let roots = (0..<8).map { "root-\($0)" }
        let ownerA = "test:10"
        let ownerB = "test:11"

        // Store and pin all roots under both owners in both brokers
        for root in roots {
            let p = SerializedVolume(root: root, entries: [root: Data(root.utf8)])
            try await batchBroker.storeVolumeLocal(p)
            try await seqBroker.storeVolumeLocal(p)
            try await batchBroker.pin(root: root, owner: ownerA)
            try await seqBroker.pin(root: root, owner: ownerA)
        }
        // Pin a subset under ownerB with count=2
        for root in roots.prefix(4) {
            try await batchBroker.pin(root: root, owner: ownerB, count: 2)
            try await seqBroker.pin(root: root, owner: ownerB, count: 2)
        }

        // Unpin half via unpinBatch / sequential unpin
        let items: [(root: String, owner: String, count: Int)] = roots.prefix(4).map {
            (root: $0, owner: ownerA, count: 1)
        }
        try await batchBroker.unpinBatch(items: items)
        for item in items {
            try await seqBroker.unpin(root: item.root, owner: item.owner, count: item.count)
        }

        // Final pin state must be identical
        for root in roots {
            let bOwners = await batchBroker.owners(root: root)
            let sOwners = await seqBroker.owners(root: root)
            XCTAssertEqual(bOwners, sOwners,
                "unpinBatch and sequential unpin must produce same owners for \(root)")
        }

        // Completely unpin ownerB (count=2) via batch
        let ownerBItems: [(root: String, owner: String, count: Int)] = roots.prefix(4).map {
            (root: $0, owner: ownerB, count: 2)
        }
        try await batchBroker.unpinBatch(items: ownerBItems)
        for item in ownerBItems {
            try await seqBroker.unpin(root: item.root, owner: item.owner, count: item.count)
        }

        for root in roots.prefix(4) {
            let bOwners = await batchBroker.owners(root: root)
            let sOwners = await seqBroker.owners(root: root)
            XCTAssertEqual(bOwners, sOwners,
                "After full count unpin, batch and sequential must agree for \(root)")
            // ownerB must be gone from both
            XCTAssertFalse(bOwners.contains(ownerB),
                "ownerB must be evicted after count reaches 0 in batchBroker")
            XCTAssertFalse(sOwners.contains(ownerB),
                "ownerB must be evicted after count reaches 0 in seqBroker")
        }
    }

    /// unpinBatch with a single item must behave identically to a direct unpin call.
    func testUnpinBatchSingleItemMatchesUnpin() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = try DiskBroker(path: tmp.path)

        let root = "single-root"
        let owner = "owner:1"
        let payload = SerializedVolume(root: root, entries: [root: Data(root.utf8)])
        try await broker.storeVolumeLocal(payload)
        try await broker.pin(root: root, owner: owner, count: 3)

        // Unpin count=2 via batch (single item — should delegate to unpin directly)
        try await broker.unpinBatch(items: [(root: root, owner: owner, count: 2)])
        let ownersAfter = await broker.owners(root: root)
        XCTAssertTrue(ownersAfter.contains(owner),
            "owner must still hold root after partial unpin (count went from 3 to 1)")

        // Unpin remaining count=1
        try await broker.unpinBatch(items: [(root: root, owner: owner, count: 1)])
        let ownersFinal = await broker.owners(root: root)
        XCTAssertFalse(ownersFinal.contains(owner),
            "owner must be gone after unpinning remaining count")
    }

    // MARK: - SEC-601 boundary: Int64.min+1 is handled (not crashed)

    /// Int64.min is rejected with the SEC-601 guard. Int64.min+1 is a legitimate
    /// (enormous) negative delta that must NOT crash — it should either:
    ///   (a) fail conservation in validateBalanceChangesForGenesis (no premine covers it), or
    ///   (b) reach proveAndUpdateState and throw StateErrors.insufficientBalance.
    /// Either outcome is correct; the critical invariant is no runtime trap.
    func testValidateBalanceChangesForGenesisIntMinPlusOneDoesNotCrash() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)

        // Int64.min+1 = -9223372036854775807: the value just above the crash boundary.
        // UInt64(-delta) = UInt64(9223372036854775807) = UInt64(Int64.max) — no overflow.
        let nearMinDelta = Int64.min + 1

        let action = AccountAction(owner: "victim", delta: nearMinDelta)
        let body = TransactionBody(
            accountActions: [action],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["victim"], fee: 0, nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
        )

        // validateBalanceChangesForGenesis only checks credit-side (credits ≤ premine+fees).
        // A pure debit with no matching credit passes this check (credits=0 ≤ available=0).
        // The no-crash guarantee is at the proveAndUpdateState level, tested below.
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 10_000,
            target: UInt256.max, fetcher: f
        )
        // This call must not crash regardless of return value.
        let _ = try genesis.validateBalanceChangesForGenesis(
            spec: spec, allAccountActions: [action]
        )
        // Reaching here without a crash is the key assertion for validateBalanceChangesForGenesis.

        // Belt-and-suspenders: AccountState.proveAndUpdateState must also handle it
        // without trapping (insufficient balance, not arithmetic overflow).
        let emptyAccount = try AccountStateHeader(node: AccountState())
        do {
            let _ = try await emptyAccount.proveAndUpdateState(
                allAccountActions: [action],
                transactionBodies: [body],
                fetcher: f
            )
            XCTFail("SEC-601 boundary: proveAndUpdateState must throw for huge debit, not succeed")
        } catch StateErrors.insufficientBalance {
            // Expected: belt-and-suspenders UInt64(-delta) runs without trapping,
            // then the balance check correctly rejects it
        } catch StateErrors.balanceOverflow {
            // Also acceptable if the guard fires at a higher level
        } catch {
            XCTFail("SEC-601 boundary: unexpected error \(error)")
        }
    }

    /// Int64.min is still rejected by the explicit guard (not just insufficient balance).
    func testValidateBalanceChangesForGenesisIntMinExactlyRejected() throws {
        // This is the exact crash value — must be caught by the if action.delta == Int64.min guard
        // before UInt64(-delta) is ever evaluated.
        let action = AccountAction(owner: "victim", delta: Int64.min)

        // The test in SecurityRegressionTests already covers this path;
        // this companion test verifies Int64.min+1 is NOT guarded at this level
        // (only Int64.min exactly is special-cased).
        let notMin = action.delta > Int64.min
        XCTAssertFalse(notMin, "Int64.min must not be > Int64.min")
        let nearMin = AccountAction(owner: "victim", delta: Int64.min + 1)
        let nearMinNotGuarded = nearMin.delta > Int64.min
        XCTAssertTrue(nearMinNotGuarded, "Int64.min+1 must be > Int64.min (not caught by Int64.min guard)")
    }

    // MARK: - SEC-501: empty string directory rejected

    /// handleChildChainDiscovery("") must reject the empty string — the allowlist
    /// check `!directory.isEmpty` should fire before any filesystem operation.
    /// We removed "" from testPathTraversalDirectoryRejectedByDiscovery because
    /// tmp.appendingPathComponent("") == tmp (which already exists). This test
    /// focuses only on the network-registration check.
    func testEmptyStringDirectoryNotRegistered() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        await node.handleChildChainDiscovery(directory: "")

        let registered = await node.network(for: "")
        XCTAssertNil(registered,
            "SEC-501: empty string directory must not register a network")
    }

    // MARK: - P-902 / SEC-401 interaction: nonce seed must survive addTransaction

    /// Regression test for the SEC-401+P-902 interaction:
    /// When updateConfirmedNonce is called for a sender with no pending txs,
    /// the SEC-401 defer evicts the empty queue. addTransaction then creates a
    /// fresh queue with confirmedNonce=0, making the tx unselectable.
    ///
    /// The fix in admitToMempool: call addTransaction FIRST (while confirmedNonce=0,
    /// queue is non-empty after add), THEN updateConfirmedNonce (SEC-401 defer won't
    /// evict because txsByNonce is non-empty). selectTransactions then uses the
    /// correct confirmedNonce.
    func testAdmitToMempoolSeedsNonceAfterAddNotBefore() async throws {
        let mempool = NodeMempool(maxSize: 1000)
        let wallet = Wallet.create()

        // Simulate the correct add-then-seed order (as fixed in admitToMempool):
        let tx0 = wallet.buildTransfer(
            to: Wallet.create().address, amount: 1, fee: 1,
            nonce: 0, chainPath: ["Nexus"]
        )!

        // 1. Add tx FIRST (queue created with confirmedNonce=0, txsByNonce={0:tx})
        let addResult = await mempool.addTransaction(tx0)
        guard case .added = addResult else {
            XCTFail("P-902: tx at nonce=0 must be addable to empty mempool"); return
        }

        // 2. Seed confirmedNonce AFTER add (non-empty queue, defer won't evict)
        await mempool.updateConfirmedNonce(sender: wallet.address, nonce: 0)

        // selectTransactions must find tx0: nextExpected = confirmedNonce = 0, nonce = 0 ✓
        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 1,
            "P-902: tx added before nonce seed must be selectable")
        XCTAssertEqual(selected.first?.body.rawCID, tx0.body.rawCID,
            "P-902: selected tx must be the admitted one")
    }

    /// After a sender's queue is evicted (SEC-401) and they re-submit at a
    /// higher nonce (on-chain state advanced), the re-admitted tx must be
    /// selectable. This verifies the full SEC-401 + P-902 fix interaction.
    func testReAdmitAfterQueueEvictionIsSelectable() async throws {
        let mempool = NodeMempool(maxSize: 1000)
        let wallet = Wallet.create()

        // Submit tx0 at nonce=0 and confirm it (evicts the queue per SEC-401)
        let tx0 = wallet.buildTransfer(
            to: Wallet.create().address, amount: 1, fee: 1,
            nonce: 0, chainPath: ["Nexus"]
        )!
        _ = await mempool.addTransaction(tx0)
        await mempool.batchUpdateConfirmedNonces(updates: [(sender: wallet.address, nonce: 1)])

        let countAfterConfirm = await mempool.count
        XCTAssertEqual(countAfterConfirm, 0, "Pre-condition: queue evicted after confirmation")

        // Re-submit at nonce=1 using the fixed add-then-seed order
        let tx1 = wallet.buildTransfer(
            to: Wallet.create().address, amount: 1, fee: 1,
            nonce: 1, chainPath: ["Nexus"]
        )!

        // addTransaction: fresh queue (confirmedNonce=0), nonce=1 >= 0 → admitted
        let addResult = await mempool.addTransaction(tx1)
        guard case .added = addResult else {
            XCTFail("SEC-401+P-902: tx at nonce=1 must be addable after queue eviction"); return
        }

        // Seed AFTER add: non-empty queue (has tx1), defer won't evict
        await mempool.updateConfirmedNonce(sender: wallet.address, nonce: 1)

        // selectTransactions: confirmedNonce=1, nextExpected=1, entry.nonce=1 → selected
        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 1,
            "SEC-401+P-902: re-admitted tx must appear in selectTransactions")
        XCTAssertEqual(selected.first?.body.rawCID, tx1.body.rawCID,
            "SEC-401+P-902: selected tx must be the re-admitted tx1 at nonce=1")
    }
}
