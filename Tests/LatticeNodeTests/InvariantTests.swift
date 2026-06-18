import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew

/// Property-based invariant tests derived from the blockchain research literature.
/// Each test verifies a correctness invariant that must hold under adversarial conditions.
final class InvariantTests: XCTestCase {

    // MARK: - I1: Conservation

    /// For any block B: sum(totalCredits) ≤ sum(totalDebits) + reward(B.height).
    /// Transaction fees are already included in sender debits.
    /// Verified directly via validateBalanceChanges over 50 synthetic transaction batches.
    func testConservationHoldsOverManyBlocks() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)

        // I1 is a mathematical invariant of validateBalanceChanges — verify it
        // directly for 50 different block heights and transaction configurations.
        for blockIdx in 1...50 {
            let reward = spec.rewardAtBlock(UInt64(blockIdx))
            let fee: UInt64 = 1
            let send = max(reward / 3, 1)

            // Valid transfer: debit covers send+fee, credit is just send
            let validActions: [AccountAction] = [
                AccountAction(owner: "alice", delta: -Int64(send + fee)),
                AccountAction(owner: "bob", delta: Int64(send))
            ]
            // validateBalanceChanges is the authoritative conservation check
            let genesis = try await BlockBuilder.buildGenesis(
                spec: spec, timestamp: now() - 500_000,
                target: UInt256(1000), fetcher: f
            )
            let isValid = try genesis.validateBalanceChanges(
                spec: spec,
                allDepositActions: [],
                allWithdrawalActions: [],
                allAccountActions: validActions
            )
            XCTAssertTrue(isValid,
                "I1: valid transfer (debit \(send+fee), credit \(send), fee \(fee), reward \(reward)) must pass conservation at block \(blockIdx)")

            // Invalid case: credits exceed available
            let invalidActions: [AccountAction] = [
                AccountAction(owner: "alice", delta: -Int64(send)),  // too small debit
                AccountAction(owner: "bob", delta: Int64(send + reward + fee + 1))  // exceeds available
            ]
            let isInvalid = try genesis.validateBalanceChanges(
                spec: spec,
                allDepositActions: [],
                allWithdrawalActions: [],
                allAccountActions: invalidActions
            )
            XCTAssertFalse(isInvalid,
                "I1: over-credit transaction must fail conservation at block \(blockIdx)")
        }
    }

    // MARK: - I2: Nonce Monotonicity After Reorg

    /// After a reorg, the AccountState's nonce tracking reflects the NEW chain's
    /// history. The Lattice library's proveAndUpdateState enforces contiguous
    /// nonce sequences per signer — nonceGap is thrown for any gap or reuse.
    /// This test verifies the invariant directly via AccountState.
    func testNonceMonotonicityAfterReorg() async throws {
        let f = cas()
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = CryptoUtils.createAddress(from: alice.publicKey)

        func makeTxBody(nonce: UInt64) -> TransactionBody {
            TransactionBody(
                accountActions: [AccountAction(owner: aliceAddr, delta: 1)],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [aliceAddr], fee: 0, nonce: nonce, chainPath: ["Nexus"]
            )
        }

        // Build AccountState after applying nonce 0 (simulates chain A tip state)
        let emptyAccount = try AccountStateHeader(node: AccountState())
        let (stateAfterNonce0, _) = try await emptyAccount.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: aliceAddr, delta: 1)],
            transactionBodies: [makeTxBody(nonce: 0)],
            fetcher: f
        )

        // I2a: nonce 1 must be accepted after nonce 0 is confirmed
        let (_, _) = try await stateAfterNonce0.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: aliceAddr, delta: 1)],
            transactionBodies: [makeTxBody(nonce: 1)],
            fetcher: f
        )
        // If we reach here without throwing, nonce 1 was valid ✓

        // I2b: nonce 0 CANNOT be reused after it's confirmed — nonceGap must be thrown
        do {
            let _ = try await stateAfterNonce0.proveAndUpdateState(
                allAccountActions: [AccountAction(owner: aliceAddr, delta: 1)],
                transactionBodies: [makeTxBody(nonce: 0)],  // replay nonce 0
                fetcher: f
            )
            XCTFail("I2: replayed nonce 0 must throw nonceGap, not succeed")
        } catch StateErrors.nonceGap {
            // Expected — nonce 0 already used, nonce 0 again is a gap (not next=1)
        } catch {
            XCTFail("I2: unexpected error type \(error) — expected StateErrors.nonceGap")
        }

        // I2c: future nonce gap (nonce 5 after nonce 0) must throw nonceGap
        do {
            let _ = try await stateAfterNonce0.proveAndUpdateState(
                allAccountActions: [AccountAction(owner: aliceAddr, delta: 1)],
                transactionBodies: [makeTxBody(nonce: 5)],  // gap: skip nonces 1-4
                fetcher: f
            )
            XCTFail("I2: nonce gap (0→5) must throw nonceGap")
        } catch StateErrors.nonceGap {
            // Expected ✓
        } catch {
            XCTFail("I2: unexpected error \(error) — expected StateErrors.nonceGap")
        }
    }

    // MARK: - I3: Fork Choice Safety

    /// Two nodes observing the same set of blocks in different arrival orders
    /// must converge to the same chain tip.
    func testForkChoiceSafety() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 100_000,
            target: UInt256(1000), fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Fork A: two blocks at standard target
        let a1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: now() - 90_000,
            target: UInt256(1000), nonce: 1, fetcher: f
        )
        let a2 = try await BlockBuilder.buildBlock(
            previous: a1, timestamp: now() - 80_000,
            target: UInt256(1000), nonce: 2, fetcher: f
        )
        // Fork B: single block with more work (lower target target = harder)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: now() - 90_000,
            target: UInt256(400), nonce: 3, fetcher: f
        )
        for b in [a1, a2, b1] {
            try VolumeImpl<Block>(node: b).storeRecursively(storer: storer)
            await storer.flush(to: f)
        }

        // Node 1: sees A1, A2, then B1
        let node1 = ChainState.fromGenesis(block: genesis, retentionDepth: 100)
        _ = await node1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl(node: a1), block: a1)
        _ = await node1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl(node: a2), block: a2)
        _ = await node1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl(node: b1), block: b1)

        // Node 2: sees B1, then A1, then A2 (different arrival order)
        let node2 = ChainState.fromGenesis(block: genesis, retentionDepth: 100)
        _ = await node2.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl(node: b1), block: b1)
        _ = await node2.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl(node: a1), block: a1)
        _ = await node2.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl(node: a2), block: a2)

        let tip1 = await node1.getMainChainTip()
        let tip2 = await node2.getMainChainTip()

        XCTAssertEqual(tip1, tip2,
            "I3 violation: node1 tip \(String(tip1.prefix(12))) ≠ node2 tip \(String(tip2.prefix(12)))")
    }

    // MARK: - I4: Deposit/Withdrawal Atomicity

    /// A deposit consumed by a withdrawal must be deleted exactly once.
    /// The same withdrawal must not be processable a second time.
    func testDepositWithdrawalAtomicity() async throws {
        let f = cas()
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = CryptoUtils.createAddress(from: alice.publicKey)

        let depositNonce = UInt128(42)
        let depositAction = DepositAction(
            nonce: depositNonce, demander: aliceAddr,
            amountDemanded: 100, amountDeposited: 100
        )
        let withdrawalAction = WithdrawalAction(
            withdrawer: aliceAddr, nonce: depositNonce, demander: aliceAddr,
            amountDemanded: 100, amountWithdrawn: 100
        )
        let depositKey = DepositKey(depositAction: depositAction).description

        // Step 1: Create deposit
        let emptyDeposit = try DepositStateHeader(node: DepositState())
        let (withDeposit, _) = try await emptyDeposit.proveAndUpdateState(
            allDepositActions: [depositAction], fetcher: f
        )

        // Verify deposit exists with correct amount
        let resolved = try await withDeposit.resolve(
            paths: [[depositKey]: .targeted], fetcher: f
        )
        let storedAmount: UInt64? = try? resolved.node?.get(key: depositKey)
        XCTAssertEqual(storedAmount, 100, "I4: deposit must exist after creation")

        // Step 2: Withdraw (consumes deposit)
        let (afterWithdrawal, diff) = try await withDeposit.proveAndDeleteForWithdrawals(
            allWithdrawalActions: [withdrawalAction], fetcher: f
        )
        XCTAssertFalse(diff.replaced.isEmpty, "I4: withdrawal must produce a state diff (something deleted)")

        // I4 assertion: deposit is gone
        let resolved2 = try await afterWithdrawal.resolve(
            paths: [[depositKey]: .targeted], fetcher: f
        )
        let storedAfter: UInt64? = try? resolved2.node?.get(key: depositKey)
        XCTAssertNil(storedAfter, "I4: deposit must be deleted after withdrawal — no double-spend")

        // Step 3: Attempt second withdrawal on same (now-deleted) deposit.
        // The deposit-state primitive must fail closed when the corresponding
        // deposit is absent, rather than returning an ambiguous no-op diff.
        do {
            _ = try await afterWithdrawal.proveAndDeleteForWithdrawals(
                allWithdrawalActions: [withdrawalAction], fetcher: f
            )
            XCTFail("I4: second withdrawal on same deposit must throw conflictingActions")
        } catch StateErrors.conflictingActions {
            // Expected: the deposit was already consumed.
        } catch {
            XCTFail("I4: unexpected error \(error) — expected StateErrors.conflictingActions")
        }
    }

    // MARK: - I5: Receipt Consistency After Reorg (SEC-004)

    /// After a reorg, no receipt in the SQLite index may reference an orphaned block.
    /// The SEC-004 fix (deleteReceiptsForOrphanedTxCIDs) must clean all stale entries.
    func testReceiptConsistencyAfterReorg() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try StateStore(storagePath: tmp, chain: "Nexus")

        let txCID = "abc123txcid"
        let orphanedBlock = "dead-orphaned-block-hash"
        let canonicalBlock = "live-canonical-block-hash"
        let address = "aa00bb11cc22dd33"

        // Phase 1: receipt written for a block that is about to be orphaned
        try await store.batchIndexReceipts(
            generalEntries: [
                (key: "receipt:\(txCID)",
                 value: Data("{\"txCID\":\"\(txCID)\",\"blockHash\":\"\(orphanedBlock)\"}".utf8),
                 height: 10),
                (key: "receipt-idx:\(txCID)",
                 value: Data("{\"blockHash\":\"\(orphanedBlock)\",\"blockHeight\":10}".utf8),
                 height: 10)
            ],
            txHistory: [(address: address, txCID: txCID, blockHash: orphanedBlock, height: 10)]
        )

        // Verify it's there before reorg
        let historyBefore = store.getTransactionHistory(address: address)
        XCTAssertEqual(historyBefore.count, 1, "I5 pre-condition: receipt must exist before reorg")
        XCTAssertEqual(historyBefore.first?.blockHash, orphanedBlock)

        // Phase 2: reorg — SEC-004 fix deletes orphaned receipts
        try await store.deleteReceiptsForOrphanedTxCIDs([txCID])

        // I5 assertion: orphaned block reference is gone
        let historyAfterReorg = store.getTransactionHistory(address: address)
        XCTAssertEqual(historyAfterReorg.count, 0,
            "I5: tx_history must be empty after reorg cleanup — no stale orphaned-block references")
        let orphanRefs = historyAfterReorg.filter { $0.blockHash == orphanedBlock }
        XCTAssertTrue(orphanRefs.isEmpty,
            "I5: no receipt may reference orphaned block after SEC-004 cleanup")

        // Phase 3: re-confirm in canonical block
        try await store.batchIndexReceipts(
            generalEntries: [],
            txHistory: [(address: address, txCID: txCID, blockHash: canonicalBlock, height: 11)]
        )

        let historyFinal = store.getTransactionHistory(address: address)
        XCTAssertEqual(historyFinal.count, 1,
            "I5: exactly one receipt must exist after re-confirmation")
        XCTAssertEqual(historyFinal.first?.blockHash, canonicalBlock,
            "I5: re-confirmed receipt must reference canonical block, not orphaned block")
        let finalOrphanRefs = historyFinal.filter { $0.blockHash == orphanedBlock }
        XCTAssertTrue(finalOrphanRefs.isEmpty,
            "I5: canonical re-confirmation must not resurrect orphaned block reference")
    }

    // MARK: - Additional: A5 MEV ordering (fee+time sort)

    /// Transactions with equal fee must be ordered by arrival time (earlier first).
    /// This reduces the MEV front-running window for same-fee transactions.
    func testMEVOrderingWithinFeeTier() async throws {
        let mempool = NodeMempool(maxSize: 100)
        let w1 = Wallet.create()
        let w2 = Wallet.create()

        let earlyTx = w1.buildTransfer(to: w2.address, amount: 10, fee: 5, nonce: 0,
                                        chainPath: ["Nexus"])!
        let lateTx = w2.buildTransfer(to: w1.address, amount: 10, fee: 5, nonce: 0,
                                       chainPath: ["Nexus"])!

        // Submit early tx first
        _ = await mempool.addTransaction(earlyTx)
        try await Task.sleep(for: .milliseconds(5))  // ensure different addedAt
        _ = await mempool.addTransaction(lateTx)

        let selected = await mempool.selectTransactions(maxCount: 10)
        let cids = selected.map { $0.body.rawCID }

        XCTAssertEqual(cids.first, earlyTx.body.rawCID,
            "A5: earlier-arriving same-fee tx must be selected first (time-priority within fee tier)")
    }

    // MARK: - Additional: P5c Bloom filter correctness (via StateStore general store)

    /// The negative bloom in the storage layer must not cause false misses for
    /// data written after a confirmed-miss is recorded. Verified via StateStore
    /// (which uses DiskBroker internally) — write-then-read-back must always succeed.
    func testNegativeBloomDoesNotMissRecentlyStoredData() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try StateStore(storagePath: tmp, chain: "Nexus")

        let key = "test-key-p5c"
        let value = Data("test-value".utf8)
        let height: UInt64 = 1

        // Read before write — confirmed miss
        let beforeWrite = store.getGeneral(key: key)
        XCTAssertNil(beforeWrite, "P5c pre-condition: key must not exist before write")

        // Write (adds to recentStores so bloom fast-path is bypassed)
        try await store.setGeneral(key: key, value: value, atHeight: height)

        // Read after write — must find it despite prior negative bloom entry
        let afterWrite = store.getGeneral(key: key)
        XCTAssertNotNil(afterWrite, "P5c: write-then-read must succeed despite prior confirmed miss")
        XCTAssertEqual(afterWrite, value, "P5c: read-back value must equal written value")
    }
}
