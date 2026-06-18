import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy
import Tally
import UInt256
import cashew
import VolumeBroker

// Helpers in TestHelpers.swift: cas(), testSpec(), sign(), addr(), now()

// ============================================================================
// MARK: - 1. State Root Verification
// Verify that frontier state root is independently derivable from homestead + transactions
// ============================================================================

final class StateRootVerificationTests: XCTestCase {

    /// Build a block with a coinbase transaction, then independently verify
    /// that the frontier matches applying the transaction to homestead.
    func testFrontierMatchesHomesteadPlusTransactions() async throws {
        let f = cas()
        let t = now() - 20_000
        let s = testSpec()
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = addr(kp.publicKey)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: UInt256.max, fetcher: f
        )
        let genesisHeader = try VolumeImpl<Block>(node: genesis)
        let storer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build a block with a coinbase tx
        let reward = s.rewardAtBlock(1)
        let coinbaseBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [minerAddr], fee: 0, nonce: 0
        )
        let coinbaseTx = sign(coinbaseBody, kp)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [coinbaseTx],
            timestamp: t + 1000, target: UInt256.max, nonce: 1, fetcher: f
        )
        let blockHeader = try VolumeImpl<Block>(node: block)
        let storer2 = BufferedStorer()
        try blockHeader.storeRecursively(storer: storer2)
        await storer2.flush(to: f)

        // Verify: frontier state should contain miner's balance
        let frontier = try await block.postState.resolve(fetcher: f)
        XCTAssertNotNil(frontier.node, "Frontier should be resolvable")

        let accounts = try await frontier.node!.accountState.resolve(fetcher: f)
        XCTAssertNotNil(accounts.node, "Account state should be resolvable")

        let minerBalance = try? accounts.node!.get(key: minerAddr)
        XCTAssertNotNil(minerBalance, "Miner should have a balance")
        XCTAssertEqual(UInt64(minerBalance!), reward, "Miner balance should equal block reward")

        // Verify: homestead should NOT contain miner's balance (pre-state)
        let homestead = try await block.prevState.resolve(fetcher: f)
        let oldAccounts = try await homestead.accountState.resolve(fetcher: f)
        let oldMinerBalance = try? oldAccounts.node?.get(key: minerAddr)
        XCTAssertNil(oldMinerBalance, "Homestead should not have miner balance")

        // Verify: block validates its own frontier
        let (valid, _, _) = try await block.validatePostState(
            transactionBodies: [coinbaseBody], fetcher: f
        )
        XCTAssertTrue(valid, "Block should validate its own frontier state root")
    }

    /// Multiple transactions in one block: verify state conservation
    func testMultiTransactionBlockStateConservation() async throws {
        let f = cas()
        let t = now() - 30_000
        let s = testSpec("Nexus", premine: 1_000_000)
        let sender = CryptoUtils.generateKeyPair()
        let senderAddr = addr(sender.publicKey)
        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = addr(receiver.publicKey)

        let premineAmount = s.premineAmount()
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: senderAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [sign(premineBody, sender)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        let gs = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: gs)
        await gs.flush(to: f)

        // Build block with transfer + fee
        let fee: UInt64 = 10
        let transfer: UInt64 = 500
        let reward = s.rewardAtBlock(1)
        let txBody = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: Int64(premineAmount - transfer - fee) - Int64(premineAmount)),
                AccountAction(owner: receiverAddr, delta: Int64(transfer + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: fee, nonce: 1
        )
        let tx = sign(txBody, sender)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: t + 1000, target: UInt256.max, nonce: 1, fetcher: f
        )
        let bs = BufferedStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: bs)
        await bs.flush(to: f)

        // Verify state
        let frontier = try await block.postState.resolve(fetcher: f)
        let accts = try await frontier.node!.accountState.resolveRecursive(fetcher: f)
        let entries = try accts.node!.allKeysAndValues()

        var totalBalance: UInt64 = 0
        for (key, balance) in entries {
            if key.hasPrefix("_nonce_") { continue }
            totalBalance += balance
        }

        // Total should be premine + reward - fee (fee is burned in this block, no coinbase absorbs it)
        XCTAssertEqual(totalBalance, premineAmount + reward - fee, "Total balance should be premine + reward - fee")
    }

}

// ============================================================================
// MARK: - 2. Message Deserialization Fuzz Tests
// ============================================================================

final class MessageFuzzTests: XCTestCase {

    /// Feed random bytes to Message.deserialize — must never crash
    func testRandomBytesNeverCrash() {
        for _ in 0..<10_000 {
            let length = Int.random(in: 0...512)
            var bytes = Data(count: length)
            for i in 0..<length {
                bytes[i] = UInt8.random(in: 0...255)
            }
            // Must not crash — nil is fine
            let _ = Message.deserialize( bytes)
        }
    }

    /// Truncated valid messages should not crash
    func testTruncatedMessagesNeverCrash() {
        let validMessages: [Message] = [
            .ping(nonce: 42),
            .pong(nonce: 99),
            .block(cid: "testcid", data: Data("hello".utf8)),
            .dontHave(cid: "testcid"),
            .findNode(target: Data(repeating: 0xAB, count: 32), fee: 100),
            .announceBlock(cid: "blockcid"),
            .peerMessage(topic: "test", payload: Data("payload".utf8)),
            .pinAnnounce(rootCID: "root", publicKey: "pk", expiry: 1000, signature: Data(), fee: 5),
        ]

        for msg in validMessages {
            let full = msg.serialize()
            // Try every truncation point
            for len in 0..<full.count {
                let truncated = full.prefix(len)
                let _ = Message.deserialize( Data(truncated))
                // Must not crash
            }
        }
    }

    /// Valid messages round-trip correctly
    func testValidMessagesRoundTrip() {
        let messages: [Message] = [
            .ping(nonce: 12345),
            .pong(nonce: 67890),
            .block(cid: "bafyrei123", data: Data("blockdata".utf8)),
            .dontHave(cid: "missing"),
            .announceBlock(cid: "newblock"),
            .peerMessage(topic: "gossip", payload: Data("hello".utf8)),
        ]

        for original in messages {
            let serialized = original.serialize()
            let deserialized = Message.deserialize( serialized)
            XCTAssertNotNil(deserialized, "Message should deserialize: \(original)")
        }
    }

    /// Oversized payloads should be handled gracefully
    func testOversizedPayload() {
        // 1MB of random data with a valid tag byte
        var data = Data(count: 1_048_576)
        data[0] = 0 // ping tag
        let _ = Message.deserialize( data) // Must not crash or OOM
    }
}

// ============================================================================
// MARK: - 3. Mempool Load Test
// ============================================================================

final class MempoolLoadTests: XCTestCase {

    /// Submit many transactions from many senders and verify mempool handles it
    func testHighVolumeTransactions() async throws {
        let ci = ProcessInfo.processInfo.environment["CI"] == "true"
        let senderCount = ci ? 50 : 100
        let noncesPerSender = ci ? 50 : 100
        let totalTransactions = senderCount * noncesPerSender

        // maxNonceGap lets each sender submit the full nonce window without
        // tripping the anti-DoS gap limiter (S1 #72); this test is measuring
        // raw capacity, not realistic nonce discipline.
        let mempool = NodeMempool(
            maxSize: totalTransactions,
            maxPerAccount: UInt64(noncesPerSender),
            maxNonceGap: UInt64(noncesPerSender)
        )

        var added = 0
        var senders: [(privateKey: String, publicKey: String)] = []
        for _ in 0..<senderCount { senders.append(CryptoUtils.generateKeyPair()) }

        for (senderIdx, kp) in senders.enumerated() {
            let senderAddr = addr(kp.publicKey)
            for nonce in 0..<noncesPerSender {
                let body = TransactionBody(
                    accountActions: [AccountAction(owner: senderAddr, delta: -1)],
                    actions: [], depositActions: [], genesisActions: [],
                    receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: UInt64(senderIdx * noncesPerSender + nonce + 1), nonce: UInt64(nonce)
                )
                let tx = sign(body, kp)
                if await mempool.add(transaction: tx) { added += 1 }
            }
        }

        XCTAssertEqual(added, totalTransactions, "All generated transactions should be accepted")
        let count = await mempool.count
        XCTAssertEqual(count, totalTransactions)

        // Selection: each sender starts at nonce 0, so we get one tx per sender (highest fee first)
        let selected = await mempool.selectTransactions(maxCount: senderCount)
        XCTAssertGreaterThan(selected.count, 0, "Should select from pool")

        // Fee histogram should work
        let histogram = await mempool.feeHistogram()
        XCTAssertFalse(histogram.isEmpty, "Histogram should have entries")

        // Prune should work — sleep briefly so txs are "old"
        try await Task.sleep(for: .milliseconds(10))
        await mempool.pruneExpired(olderThan: Duration.milliseconds(1))
        let afterPrune = await mempool.count
        XCTAssertEqual(afterPrune, 0, "All should be pruned")
    }

    /// RBF under pressure: replace low-fee txs with high-fee ones
    func testRBFUnderPressure() async throws {
        // 100 nonces from a single sender; needs maxNonceGap ≥ 99 to not
        // hit S1's anti-DoS gap limiter on nonce submission.
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 100, maxNonceGap: 100)
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = addr(kp.publicKey)

        // Fill mempool with low-fee txs
        for i in 0..<100 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(999) - Int64(1000))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: 1, nonce: UInt64(i)
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }
        let fullCount = await mempool.count
        XCTAssertEqual(fullCount, 100)

        // High-fee tx should evict lowest
        let kp2 = CryptoUtils.generateKeyPair()
        let addr2 = addr(kp2.publicKey)
        let highFeeBody = TransactionBody(
            accountActions: [AccountAction(owner: addr2, delta: Int64(999) - Int64(1000))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [addr2], fee: 100, nonce: 0
        )
        let added = await mempool.add(transaction: sign(highFeeBody, kp2))
        XCTAssertTrue(added, "High-fee tx should be accepted")
        let afterCount = await mempool.count
        XCTAssertEqual(afterCount, 100, "Size should stay at limit")
    }

    /// Nonce update correctly purges stale entries from all structures
    func testNonceUpdateCleansAllStructures() async throws {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 100)
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = addr(kp.publicKey)

        // Add 10 txs with nonces 0-9
        for i in 0..<10 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(999) - Int64(1000))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: UInt64(i + 1), nonce: UInt64(i)
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }
        let initialCount = await mempool.count
        XCTAssertEqual(initialCount, 10)

        // Confirm nonce 5 — nonces 0-4 should be purged
        await mempool.updateConfirmedNonce(sender: senderAddr, nonce: 5)
        let afterNonceUpdate = await mempool.count
        XCTAssertLessThan(afterNonceUpdate, initialCount, "Some stale entries should be removed")

        // Stale CIDs (nonces 0-4) should not be findable
        // Selection starting at confirmed nonce 5 should still work
        let selected = await mempool.selectTransactions(maxCount: 100)
        for tx in selected {
            let nonce = tx.body.node?.nonce ?? 0
            XCTAssertGreaterThanOrEqual(nonce, 5, "Selected tx should have nonce >= confirmed")
        }
    }
}

// ============================================================================
// MARK: - 4. Sync with 1000-Block Gap
// ============================================================================

final class LongChainSyncTests: XCTestCase {

    /// Build a chain and snapshot sync the recent window
    func testSnapshotSyncWithRecentWindow() async throws {
        let blockCount = ProcessInfo.processInfo.environment["CI"] == "true" ? 30 : 50
        let f = cas()
        let t = now() - 2_000_000
        let s = testSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: UInt256.max, fetcher: f
        )
        let genesisHeader = try VolumeImpl<Block>(node: genesis)
        let genesisStorer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let genesisHash = genesisHeader.rawCID

        // Build enough history to exercise snapshot retention without making
        // every CI run pay for the local/nightly depth.
        var prev = genesis
        for i in 1...blockCount {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: f
            )
            let header = try VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)
            prev = block
        }

        let tipCID = try VolumeImpl<Block>(node: prev).rawCID

        // Snapshot sync from tip
        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash,
            retentionDepth: 20
        )

        let result = try await syncer.syncSnapshot(peerTipCID: tipCID, depth: 20)

        XCTAssertEqual(result.tipBlockHash, tipCID)
        XCTAssertEqual(result.tipBlockHeight, UInt64(blockCount))
        XCTAssertEqual(result.persisted.blocks.count, 20, "Snapshot should retain 20 blocks")
        XCTAssertEqual(result.persisted.mainChainHashes.count, 20)

        // Verify chain continuity in persisted result
        let hashes = result.persisted.mainChainHashes
        for i in 1..<hashes.count {
            let block = result.persisted.blocks[i]
            let prev = result.persisted.blocks[i - 1]
            XCTAssertEqual(block.parentBlockHash, prev.blockHash,
                "Block \(i) should point to previous block")
        }
    }

    /// Snapshot sync must succeed even when state trie data is unavailable.
    /// Regression test for the snap-sync model: syncSnapshot trusts the state
    /// root committed in the PoW chain and does not require state trie nodes.
    /// Previously, syncSnapshot called validatePostState which fetched the state
    /// trie — if unavailable, it stalled for minutes (45s per fetch timeout).
    func testSnapshotSyncSucceedsWithoutStateTrie() async throws {
        let f = cas()
        let t = now() - 500_000
        let s = testSpec()
        let target = UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: target, fetcher: f
        )
        let genesisHash = try VolumeImpl<Block>(node: genesis).rawCID
        // Store only the block root bytes — NOT the state trie sub-volumes.
        try await storeBlockFixture(genesis, to: f, includeState: false)

        var prev = genesis
        for i in 1...10 {
            let block = try await buildRetargetedTestBlock(
                previous: prev, timestamp: t + Int64(i) * 1_000,
                nonce: UInt64(i), fetcher: f
            )
            // Store consensus dependencies — no state trie.
            try await storeBlockFixture(block, to: f, includeState: false)
            prev = block
        }

        let tipCID = try VolumeImpl<Block>(node: prev).rawCID
        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash,
            retentionDepth: 5
        )

        // Must complete without hanging on missing state trie data.
        let result = try await syncer.syncSnapshot(peerTipCID: tipCID, depth: 5)
        XCTAssertEqual(result.tipBlockHash, tipCID)
        XCTAssertEqual(result.tipBlockHeight, 10)
    }

    /// syncSnapshot must produce a PersistedChainState with ALL block hashes,
    /// not just the tip.
    /// Without this, the reorg walker can't find a common ancestor and emits
    /// "Reorg refused: no common ancestor within retentionDepth=N blocks".
    func testSnapSyncPreservesFullParentChain() async throws {
        let f = cas()
        let t = now() - 100_000
        let s = testSpec()
        let target = UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: target, fetcher: f
        )
        let genesisHash = try VolumeImpl<Block>(node: genesis).rawCID
        try await storeBlockFixture(genesis, to: f)

        var prev = genesis
        var allHashes = [genesisHash]
        for i in 1...5 {
            let block = try await buildRetargetedTestBlock(
                previous: prev, timestamp: t + Int64(i) * 1_000,
                nonce: UInt64(i), fetcher: f
            )
            let cid = try VolumeImpl<Block>(node: block).rawCID
            try await storeBlockFixture(block, to: f)
            allHashes.append(cid)
            prev = block
        }

        let tipCID = allHashes.last!
        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash
        )

        let result = try await syncer.syncSnapshot(peerTipCID: tipCID)
        XCTAssertEqual(result.tipBlockHash, tipCID)
        XCTAssertEqual(result.tipBlockHeight, 5)

        // All 6 blocks (genesis + 5) must be in mainChainHashes so the reorg
        // walker can traverse parent pointers all the way back to genesis.
        XCTAssertEqual(result.persisted.mainChainHashes.count, 6,
            "snap sync must include all blocks — not just tip — so reorgs can find common ancestor")
        XCTAssertTrue(result.persisted.mainChainHashes.contains(genesisHash),
            "genesis must be in the chain so reorg walker reaches it")
        XCTAssertTrue(result.persisted.mainChainHashes.contains(tipCID),
            "tip must be in the chain")
    }

    /// syncFromHeaders must produce the same SyncResult as syncSnapshot without
    /// re-fetching blocks through IvyFetcher. This covers the Fix 2 path where
    /// performHeadersFirstSync skips the redundant re-walk pass.
    func testSyncFromHeadersMatchesSyncSnapshot() async throws {
        let f = cas()
        let t = now() - 100_000
        let s = testSpec()
        let target = UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: target, fetcher: f
        )
        let genesisHash = try VolumeImpl<Block>(node: genesis).rawCID
        try await storeBlockFixture(genesis, to: f)

        var prev = genesis
        for i in 1...5 {
            let block = try await buildRetargetedTestBlock(
                previous: prev, timestamp: t + Int64(i) * 1_000,
                nonce: UInt64(i), fetcher: f
            )
            try await storeBlockFixture(block, to: f)
            prev = block
        }
        let tipCID = try VolumeImpl<Block>(node: prev).rawCID

        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash
        )

        // Download headers manually (simulating downloadHeaders)
        let headerChain = HeaderChain()
        let headers = try await headerChain.downloadHeaders(
            peerTipCID: tipCID, fetcher: f,
            genesisBlockHash: genesisHash, localWork: .zero
        )

        let fromHeaders = try await syncer.syncFromHeaders(
            headers, cumulativeWork: headerChain.totalWork
        )
        let fromSnapshot = try await syncer.syncSnapshot(peerTipCID: tipCID)

        XCTAssertEqual(fromHeaders.tipBlockHash, fromSnapshot.tipBlockHash)
        XCTAssertEqual(fromHeaders.tipBlockHeight, fromSnapshot.tipBlockHeight)
        // downloadHeaders stops at block 1 (genesis already local), so
        // fromHeaders has 5 blocks vs syncSnapshot's 6 (genesis included).
        // Both are valid: reorg walker follows parent pointers and finds
        // genesis from local storage when it reaches block 1's parent.
        XCTAssertEqual(fromHeaders.persisted.mainChainHashes.count,
                       fromSnapshot.persisted.mainChainHashes.count - 1,
            "syncFromHeaders excludes genesis (assumed local); syncSnapshot includes it")
    }

    /// Full sync with a long-enough chain to exercise complete validation
    func testFullSyncWithLongChain() async throws {
        let blockCount = ProcessInfo.processInfo.environment["CI"] == "true" ? 30 : 100
        let f = cas()
        let t = now() - 200_000
        let s = testSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: UInt256.max, fetcher: f
        )
        let genesisHeader = try VolumeImpl<Block>(node: genesis)
        let genesisStorer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let genesisHash = genesisHeader.rawCID

        var prev = genesis
        for i in 1...blockCount {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let header = try VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)
            prev = block
        }

        let tipCID = try VolumeImpl<Block>(node: prev).rawCID

        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash,
            retentionDepth: 1000
        )

        let result = try await syncer.syncFull(peerTipCID: tipCID)

        XCTAssertEqual(result.tipBlockHeight, UInt64(blockCount))
        XCTAssertEqual(result.persisted.blocks.count, blockCount + 1, "Should include genesis + synced blocks")
        XCTAssertTrue(result.cumulativeWork > UInt256.zero)

        // Restore chain from sync result and verify it accepts new blocks
        let chain = try ChainState.restore(from: result.persisted)
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, UInt64(blockCount))

        let nextHeight = blockCount + 1
        let nextBlock = try await BlockBuilder.buildBlock(
            previous: prev, timestamp: t + Int64(nextHeight) * 1000,
            target: UInt256.max, nonce: UInt64(nextHeight), fetcher: f
        )
        let submitResult = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: nextBlock), block: nextBlock
        )
        XCTAssertTrue(submitResult.extendsMainChain, "Restored chain should accept new blocks")
    }
}

// ============================================================================
// MARK: - 5. Persistence Across Restart
// ============================================================================

final class RestartResilienceTests: XCTestCase {

    /// Simulate node restart: persist mid-chain, restore, continue mining
    func testPersistRestoreContinueMining() async throws {
        let f = cas()
        let t = now() - 50_000
        let s = testSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, target: UInt256.max, fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // Mine 50 blocks
        var prev = genesis
        for i in 1...50 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block), block: block
            )
            prev = block
        }
        let height50 = await chain.getHighestBlockHeight()
        XCTAssertEqual(height50, 50)

        // Persist (simulate shutdown)
        let persisted = await chain.persist()
        let data = try JSONEncoder().encode(persisted)

        // Restore (simulate startup)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = try ChainState.restore(from: decoded)
        let restoredHeight = await restored.getHighestBlockHeight()
        XCTAssertEqual(restoredHeight, 50)
        let restoredTip = await restored.getMainChainTip()
        let originalTip = await chain.getMainChainTip()
        XCTAssertEqual(restoredTip, originalTip)

        // Continue mining from restored state
        for i in 51...60 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let result = await restored.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block), block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend restored chain")
            prev = block
        }
        let finalHeight = await restored.getHighestBlockHeight()
        XCTAssertEqual(finalHeight, 60)
    }

    /// Mempool persistence roundtrip
    func testMempoolPersistenceRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mempool = NodeMempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = addr(kp.publicKey)

        // Add some txs
        for i in 0..<5 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(999) - Int64(1000))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: UInt64(i + 1), nonce: UInt64(i)
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }
        let mempoolCount = await mempool.count
        XCTAssertEqual(mempoolCount, 5)

        // Save
        let persistence = MempoolPersistence(dataDir: tmpDir)
        let txs = await mempool.allTransactions()
        try persistence.save(transactions: txs)

        // Load
        let loaded = persistence.load()
        XCTAssertEqual(loaded.count, 5, "Should load 5 serialized transactions")

        // Verify CIDs are preserved
        let originalCIDs = Set(txs.map { $0.body.rawCID })
        let loadedCIDs = Set(loaded.map { $0.bodyCID })
        XCTAssertEqual(originalCIDs, loadedCIDs, "Body CIDs should survive roundtrip")
    }
}

// ============================================================================
// MARK: - 7. Ivy Credit Line Economics
// ============================================================================

final class IvyCreditLineEconomicsTests: XCTestCase {

    /// Verify credit lines grow with successful settlements
    func testSettlementGrowsThreshold() async throws {
        let ledger = CreditLineLedger(
            localID: PeerID(publicKey: "local"),
            baseThresholdMultiplier: 100
        )
        let peer = PeerID(publicKey: "peer1")
        await ledger.establish(with: peer)

        let line1 = await ledger.creditLine(for: peer)
        XCTAssertNotNil(line1)
        let threshold1 = line1!.threshold

        // Record a successful settlement
        await ledger.recordSettlement(peer: peer)

        let line2 = await ledger.creditLine(for: peer)
        let threshold2 = line2!.threshold
        XCTAssertGreaterThan(threshold2, threshold1, "Settlement should grow trust threshold")
    }

    /// Verify relay fees are properly tracked
    func testRelayFeeAccounting() async throws {
        let ledger = CreditLineLedger(
            localID: PeerID(publicKey: "local"),
            baseThresholdMultiplier: 100
        )
        let peer = PeerID(publicKey: "peer1")
        await ledger.establish(with: peer)

        // Earn from relaying
        await ledger.earnFromRelay(peer: peer, amount: 10)
        let line1 = await ledger.creditLine(for: peer)
        XCTAssertEqual(line1!.balance, 10, "Balance should reflect earned relay fee")

        // Charge for relay
        let charged = await ledger.chargeForRelay(peer: peer, amount: 3)
        XCTAssertTrue(charged, "Charge should apply to the established credit line")
        let line2 = await ledger.creditLine(for: peer)
        XCTAssertEqual(line2!.balance, 7, "Balance should reflect charge")
    }
}
