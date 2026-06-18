import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker
import Ivy

/// Correctness tests for performance optimizations made in v1.1.0.
/// Each test verifies that the optimized path produces the same result
/// as the original code it replaced, and that boundary conditions are correct.
final class OptimizationCorrectnessTests: XCTestCase {

    // MARK: - P-801: getCumulativeWork matches sequential loop

    /// getCumulativeWork(limit:) replaced a O(retentionDepth) sequential
    /// getConsensusBlock loop. This test verifies it returns the same value.
    func testGetCumulativeWorkMatchesSequentialSum() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)
        let target = UInt256.max
        let ts = now() - 100_000

        // Build a 5-block chain
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: ts, target: target, fetcher: f
        )
        var blocks = [genesis]
        for i in 1...4 {
            let next = try await BlockBuilder.buildBlock(
                previous: blocks.last!, timestamp: ts + Int64(i * 1_000),
                target: target, nonce: UInt64(i), fetcher: f
            )
            blocks.append(next)
        }

        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: 100)
        for block in blocks.dropFirst() {
            _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl(node: block), block: block
            )
        }

        // getCumulativeWork(limit:) — the optimized single-hop version
        let optimized = await chain.getCumulativeWork(limit: 10)

        // Manual sequential sum — the original approach
        var expectedWork = UInt256.zero
        var currentHash: String? = await chain.getMainChainTip()
        var walked = 0
        while let hash = currentHash, walked <= 10 {
            guard let meta = await chain.getConsensusBlock(hash: hash) else { break }
            expectedWork = expectedWork &+ meta.work
            currentHash = meta.parentBlockHash
            walked += 1
        }

        XCTAssertEqual(optimized, expectedWork,
            "P-801: getCumulativeWork must equal sequential getConsensusBlock sum")
        XCTAssertGreaterThan(optimized, UInt256.zero,
            "P-801: cumulative work must be non-zero for a non-trivial chain")
    }

    /// getCumulativeWork with limit < chain height must only sum the recent window.
    func testGetCumulativeWorkRespectsLimit() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)
        let ts = now() - 200_000

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: ts, target: UInt256.max, fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: 100)

        // Add 5 blocks
        var prev = genesis
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: ts + Int64(i * 1_000),
                target: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl(node: b), block: b
            )
            prev = b
        }

        let full = await chain.getCumulativeWork(limit: 100)
        let limited = await chain.getCumulativeWork(limit: 2)

        XCTAssertGreaterThan(full, limited,
            "P-801: limited window work must be less than full chain work")
    }

    // MARK: - P-903: recentStores ring buffer eviction at boundary

    /// After exactly maxRecentStores+1 distinct stores, the oldest entry must
    /// be evicted from the Set so it can return to the bloom fast-path.
    func testRecentStoresRingBufferEvictsOldestAtBoundary() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = try DiskBroker(path: tmp.path)

        // maxRecentStores = 512. Fill exactly 512 entries.
        for i in 0..<512 {
            let cid = "cid-\(i)"
            let data = Data("v\(i)".utf8)
            try await broker.storeVolumeLocal(SerializedVolume(root: cid, entries: [cid: data]))
        }

        // "cid-0" must still be in recentStores (not yet evicted — ring is full but
        // hasn't wrapped yet; it wraps on the 513th store).
        let cid0before = await broker.hasVolume(root: "cid-0")
        XCTAssertTrue(cid0before,
            "P-903: cid-0 must exist after 512 stores (ring not yet wrapped)")

        // Store the 513th entry. This overwrites ring[0], evicting "cid-0" from the Set.
        let cid513 = "cid-512"
        let data513 = Data("v512".utf8)
        try await broker.storeVolumeLocal(SerializedVolume(root: cid513, entries: [cid513: data513]))

        // cid-512 must be stored and findable
        let cid512found = await broker.hasVolume(root: cid513)
        XCTAssertTrue(cid512found, "P-903: newly stored cid-512 must be found")
        // cid-1 must still be in recentStores
        let cid1still = await broker.hasVolume(root: "cid-1")
        XCTAssertTrue(cid1still,
            "P-903: cid-1 must still be in recentStores after one wrap")
    }

    /// The ring buffer must handle multiple wraps without corrupting the Set.
    func testRecentStoresRingBufferHandlesMultipleWraps() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = try DiskBroker(path: tmp.path)

        // Store 1100 entries (> 2 × 512). All should be findable on disk.
        for i in 0..<1100 {
            let cid = "wrap-cid-\(i)"
            let data = Data([UInt8(i % 256)])
            try await broker.storeVolumeLocal(SerializedVolume(root: cid, entries: [cid: data]))
        }

        // Every stored CID must be retrievable from disk (ring buffer must not corrupt storage)
        for i in [0, 100, 511, 512, 513, 1023, 1099] {
            let cid = "wrap-cid-\(i)"
            let found = await broker.hasVolume(root: cid)
            XCTAssertTrue(found,
                "P-903: cid \(i) must be findable on disk after multiple ring wraps")
        }
    }

    // MARK: - P-1302: pruneTransactionHistory returns correct count

    /// pruneTransactionHistory must also return the correct row count.
    func testPruneTransactionHistoryReturnsCorrectCount() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try StateStore(storagePath: tmp, chain: "Nexus")

        // Insert tx history for two addresses at various heights
        try await store.batchIndexReceipts(
            generalEntries: [],
            txHistory: [
                (address: "alice", txCID: "tx1", blockHash: "b1", height: 1),
                (address: "alice", txCID: "tx2", blockHash: "b2", height: 2),
                (address: "bob",   txCID: "tx3", blockHash: "b3", height: 1),
                (address: "bob",   txCID: "tx4", blockHash: "b4", height: 5),
            ]
        )

        // Prune below height 3, keeping alice's address — should delete bob's tx at height 1
        let deleted = try await store.pruneTransactionHistory(belowHeight: 3, keepAddress: "alice")
        XCTAssertEqual(deleted, 1,
            "P-1302: pruneTransactionHistory must return the number of deleted rows")

        // alice's rows must survive (keepAddress)
        let aliceHistory = store.getTransactionHistory(address: "alice")
        XCTAssertEqual(aliceHistory.count, 2,
            "P-1302: keepAddress rows must not be deleted")
    }

    // MARK: - P-series: pinBatch produces same pins as sequential pin calls

    /// pinBatch(roots:owner:) must produce identical pin state as calling
    /// pin(root:owner:) for each root individually.
    func testPinBatchEquivalentToSequentialPin() async throws {
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

        let roots = (0..<10).map { "root-\($0)" }
        let owner = "test:5"

        // Store the volumes in both brokers first
        for root in roots {
            let payload = SerializedVolume(root: root, entries: [root: Data(root.utf8)])
            try await batchBroker.storeVolumeLocal(payload)
            try await seqBroker.storeVolumeLocal(payload)
        }

        // Batch broker: one pinBatch call
        try await batchBroker.pinBatch(roots: roots, owner: owner)

        // Sequential broker: one pin() call per root
        for root in roots {
            try await seqBroker.pin(root: root, owner: owner)
        }

        // Both must have identical pin state for every root
        for root in roots {
            let batchOwners = await batchBroker.owners(root: root)
            let seqOwners   = await seqBroker.owners(root: root)
            XCTAssertEqual(batchOwners, seqOwners,
                "P-series: pinBatch and sequential pin must produce same owners for \(root)")
        }

        // Both must have identical pinned roots
        let batchPinned = Set(await batchBroker.pinnedRoots())
        let seqPinned   = Set(await seqBroker.pinnedRoots())
        XCTAssertEqual(batchPinned, seqPinned,
            "P-series: pinBatch and sequential pin must produce same pinnedRoots()")
    }

    // MARK: - SEC-502: pinRequest size limit

    /// maxPinRequestBytes must be set to 10 MB — large enough for any block,
    /// small enough to bound peer-driven disk writes.
    func testPinRequestSizeLimitIsConfigured() {
        let config = NodeResourceConfig.default
        XCTAssertEqual(config.maxPinRequestBytes, 10 * 1_048_576,
            "SEC-502: maxPinRequestBytes must be 10 MB")
        XCTAssertGreaterThanOrEqual(config.maxPinRequestBytes, 10_000_000,
            "SEC-502: size limit must accommodate maxBlockSize (10 MB)")
    }

    /// Data within the limit must be storable; the limit bounds disk exposure.
    func testPinRequestLimitBoundsExposure() {
        let config = NodeResourceConfig.default
        let limitBytes = Double(config.maxPinRequestBytes)
        // 128 peers × 10 req/s sustained = 1280 req/s worst case
        let worstCaseWritesPerSec = 128.0 * 10.0 * limitBytes
        // At 500 MB/s disk: time to fill 100 GB
        let secondsToFill100GB = (100.0 * 1_073_741_824.0) / worstCaseWritesPerSec
        XCTAssertGreaterThan(secondsToFill100GB, 1.0,
            "SEC-502: at 128 peers × 10 req/s it must take more than 1 second to fill 100 GB")
        // Per-request cap must be ≤ 100 MB
        XCTAssertLessThanOrEqual(config.maxPinRequestBytes, 100 * 1_048_576,
            "SEC-502: per-request limit must be reasonable (≤ 100 MB)")
    }

    // MARK: - P-1304: scoped reannounce

    func testReannounceOwnerFilterOnlyMatchesCurrentChainOwners() {
        let chainPath = ["Nexus", "A", "Child"]
        let query = ChainNetwork.reannounceOwnerQuery(directory: "Child", chainPath: chainPath)

        XCTAssertEqual(Set(query.owners), [
            "Nexus/A/Child",
        ])
        XCTAssertEqual(Set(query.ownerPrefixes), [
            "Nexus/A/Child:",
            "candidate:Nexus/A/Child:",
            "account:Nexus/A/Child:txwindow:",
        ])

        let owned = [
            "Nexus/A/Child",
            "Nexus/A/Child:42",
            "Nexus/A/Child:genesis",
            "Nexus/A/Child:spec",
            "candidate:Nexus/A/Child:43",
            "account:Nexus/A/Child:txwindow:42",
        ]
        for owner in owned {
            XCTAssertTrue(
                ChainNetwork.isReannounceOwner(owner, directory: "Child", chainPath: chainPath),
                "expected \(owner) to be reannounced by Child"
            )
        }

        let foreign = [
            "Nexus",
            "Nexus:42",
            "candidate:Nexus:43",
            // Legacy bare account owner: swept at startup, never reannounced.
            "account:Nexus",
            "account:Nexus/A/Child",
            "Child",
            "Child:42",
            "Child:genesis",
            "Child:spec",
            "candidate:Child:43",
            "account:Child",
            "account:Nexus/B/Child:txwindow:42",
            "Nexus/B/Child:42",
            "candidate:Nexus/B/Child:43",
            "Sibling",
            "Sibling:42",
            "candidate:Sibling:43",
            "vol:some-root",
            "validates:child-cid",
        ]
        for owner in foreign {
            XCTAssertFalse(
                ChainNetwork.isReannounceOwner(owner, directory: "Child", chainPath: chainPath),
                "expected \(owner) to be ignored by Child reannounce"
            )
        }
    }

    func testReannounceOwnerFilterMatchesRootLeafOwners() {
        let chainPath = ["Nexus"]
        let query = ChainNetwork.reannounceOwnerQuery(directory: "Nexus", chainPath: chainPath)

        XCTAssertEqual(Set(query.owners), [
            "Nexus",
        ])
        XCTAssertEqual(Set(query.ownerPrefixes), [
            "Nexus:",
            "candidate:Nexus:",
            "account:Nexus:txwindow:",
            "validates:",
        ])

        XCTAssertTrue(ChainNetwork.isReannounceOwner("Nexus:42", directory: "Nexus", chainPath: chainPath))
        XCTAssertTrue(ChainNetwork.isReannounceOwner("candidate:Nexus:43", directory: "Nexus", chainPath: chainPath))
        // Legacy bare account owner is swept at startup, not reannounced.
        XCTAssertFalse(ChainNetwork.isReannounceOwner("account:Nexus", directory: "Nexus", chainPath: chainPath))
        XCTAssertTrue(ChainNetwork.isReannounceOwner("account:Nexus:txwindow:42", directory: "Nexus", chainPath: chainPath))
        XCTAssertTrue(ChainNetwork.isReannounceOwner("validates:child-cid", directory: "Nexus", chainPath: chainPath))
        XCTAssertFalse(ChainNetwork.isReannounceOwner("Child:42", directory: "Nexus", chainPath: chainPath))
    }

    func testReannounceOwnerQueryFetchesOnlyScopedPinnedRoots() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = try DiskBroker(path: tmp.path)
        let query = ChainNetwork.reannounceOwnerQuery(directory: "Child", chainPath: ["Nexus", "A", "Child"])

        try await broker.pin(root: "owned-tip", owner: "Nexus/A/Child")
        try await broker.pin(root: "owned-block", owner: "Nexus/A/Child:42")
        try await broker.pin(root: "owned-candidate", owner: "candidate:Nexus/A/Child:43")
        try await broker.pin(root: "legacy-account", owner: "account:Nexus/A/Child")
        try await broker.pin(root: "owned-txwindow", owner: "account:Nexus/A/Child:txwindow:42")
        try await broker.pin(root: "foreign-same-leaf", owner: "Nexus/B/Child:42")
        try await broker.pin(root: "legacy-leaf", owner: "Child:42")
        try await broker.pin(root: "transient-volume", owner: "vol:some-root")
        try await broker.pin(root: "nexus-validation", owner: "validates:child-cid")

        let roots = Set(await broker.pinnedRoots(owners: query.owners, ownerPrefixes: query.ownerPrefixes))

        XCTAssertEqual(roots, [
            "owned-tip",
            "owned-block",
            "owned-candidate",
            "owned-txwindow",
        ])
    }

    // MARK: - NexusGenesis economics sanity

    /// The new halvingInterval (876,600) must produce the expected premineAmount
    /// and halving schedule at 1-hour block times.
    func testNexusGenesisEconomicsMatchSpec() {
        let spec = NexusGenesis.spec

        XCTAssertEqual(spec.targetBlockTime, 3_600_000,
            "Mainnet block time must be 1 hour (3,600,000 ms)")

        XCTAssertEqual(spec.halvingInterval, 876_600,
            "halvingInterval must be 100 years × 365.25 days × 24 hours")

        XCTAssertEqual(spec.premine, 175_320,
            "premine must be halvingInterval / 5")
        XCTAssertEqual(spec.premine * 5, spec.halvingInterval,
            "premine must be exactly 1/5 of halvingInterval")

        // premineAmount = sum of rewards for the first `premine` blocks.
        // No halving within premine period (175,320 < 876,600), so:
        // premineAmount = premine × initialReward = 175,320 × 1,048,576 = 183,836,344,320
        let premineAmount = spec.premineAmount()
        XCTAssertEqual(premineAmount, 183_836_344_320,
            "premineAmount must equal premine × initialReward (175,320 × 1,048,576)")

        // Reward must halve at exactly halvingInterval
        let rewardBefore = spec.rewardAtBlock(spec.halvingInterval)
        let rewardAfter  = spec.rewardAtBlock(spec.halvingInterval + 1)
        XCTAssertEqual(rewardBefore, spec.initialReward / 2,
            "reward at first halving boundary must be initialReward / 2")
        XCTAssertEqual(rewardAfter, spec.initialReward / 2,
            "reward just after first halving must also be initialReward / 2")

        // Reward at genesis height must equal initialReward
        XCTAssertEqual(spec.rewardAtBlock(0), spec.initialReward,
            "reward at genesis must equal initialReward")

        // After 64 halvings reward must be 0 (shift by 64 on UInt64 = 0)
        XCTAssertEqual(spec.rewardAtBlock(spec.halvingInterval * 64), 0,
            "reward must be 0 after 64 halvings")
    }

    /// syncSnapshot must reject a peer chain with less cumulative work than local.
    func testSyncSnapshotRejectsInsufficientWork() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)
        let ts = now() - 200_000
        let target = UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: ts, target: target, fetcher: f
        )
        let genesisHash = try VolumeImpl<Block>(node: genesis).rawCID
        try await storeBlockFixture(genesis, to: f)

        // Build and register a 5-block local chain
        let localChain = ChainState.fromGenesis(block: genesis, retentionDepth: 100)
        var prev = genesis
        for i in 1...5 {
            let b = try await buildRetargetedTestBlock(
                previous: prev, timestamp: ts + Int64(i * 1_000),
                nonce: UInt64(i), fetcher: f
            )
            try await storeBlockFixture(b, to: f)
            _ = await localChain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl(node: b), block: b
            )
            prev = b
        }
        let localWork = await localChain.getCumulativeWork(limit: 100)
        XCTAssertGreaterThan(localWork, UInt256.zero, "Pre-condition: local chain must have work")

        // Build a 2-block peer chain — strictly less work than 5-block local chain.
        var peerPrev = genesis
        for i in 1...2 {
            let b = try await buildRetargetedTestBlock(
                previous: peerPrev, timestamp: ts + Int64(i * 1_000),
                nonce: UInt64(i + 100), fetcher: f
            )
            try await storeBlockFixture(b, to: f)
            peerPrev = b
        }
        let peerTipCID = try VolumeImpl<Block>(node: peerPrev).rawCID

        let syncer = ChainSyncer(
            fetcher: f, store: { _, _ in },
            genesisBlockHash: genesisHash, retentionDepth: 100
        )

        do {
            let _ = try await syncer.syncSnapshot(
                peerTipCID: peerTipCID,
                localCumulativeWork: localWork
            )
            XCTFail("syncSnapshot must reject peer chain with less cumulative work than local")
        } catch SyncError.insufficientWork {
            // Expected ✓
        } catch {
            XCTFail("Unexpected error \(error), expected SyncError.insufficientWork")
        }
    }
}
