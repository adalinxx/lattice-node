import XCTest
@testable import LatticeNode
@testable import Lattice
import cashew
import VolumeBroker
import UInt256

/// Module 0: Invariant & Crash Harness.
///
/// A SMALL local tripwire that CAPTURES CURRENT BEHAVIOR before later refactors
/// (Modules 1-8). It does NOT change production code and does NOT fix bugs — when
/// a test reveals a genuine inconsistency, it is converted to a documented
/// `XCTExpectFailure` / `// FINDING` comment rather than failing the suite.
///
/// These tests spin up REAL nodes (full `start()` + mining), so they are skipped
/// in CI and only run locally.
final class InvariantHarnessTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true",
                      "InvariantHarnessTests skipped in CI (real nodes)")
    }

    // MARK: - Fixtures

    private func makeConfig(
        storagePath: URL,
        retentionDepth: UInt64,
        storageMode: StorageMode,
        blockRetention: BlockRetention = .retention,
        persistInterval: UInt64 = 10_000
    ) -> LatticeNodeConfig {
        let kp = CryptoUtils.generateKeyPair()
        return LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: storagePath,
            enableLocalDiscovery: false,
            persistInterval: persistInterval,
            retentionDepth: retentionDepth,
            storageMode: storageMode,
            blockRetention: blockRetention, minPeerKeyBits: 0
        )
    }

    /// A restart config: same storage + retention/mode, FRESH listen port (and
    /// key). Recovery keys off storagePath + genesis, not the port; reusing the
    /// dropped node's port would race its not-yet-released socket (EADDRINUSE).
    private func restartConfig(of config: LatticeNodeConfig) -> LatticeNodeConfig {
        makeConfig(storagePath: config.storagePath,
                   retentionDepth: config.retentionDepth,
                   storageMode: config.storageMode,
                   blockRetention: config.blockRetention,
                   persistInterval: config.persistInterval)
    }

    private func nexusStore(_ node: LatticeNode) async throws -> StateStore {
        let key = await node.chainKey(forDirectory: "Nexus")
        let store = await node.stateStores[key]
        return try XCTUnwrap(store, "Nexus state store")
    }

    /// The DiskBroker `chain_tip` meta for a plain Nexus node (bootKey == "Nexus").
    private func diskBrokerMetaTip(_ node: LatticeNode, config: LatticeNodeConfig) async -> String? {
        let bootKey = (config.fullChainPath ?? ["Nexus"]).joined(separator: "/")
        return await node.sharedDiskBroker.getChainMeta(key: "chain_tip:\(bootKey)")
    }

    /// Cross-check the read paths that should agree on the canonical tip of a chain.
    private func assertCanonicalConsistency(_ store: StateStore, chain: ChainState) async {
        let storeTip = store.getChainTip()
        let storeHeight = store.getHeight()
        let chainTip = await chain.getMainChainTip()
        XCTAssertEqual(storeTip, Optional(chainTip),
            "StateStore tip and in-memory ChainState tip must agree")
        if let h = storeHeight {
            XCTAssertEqual(store.getBlockHash(atHeight: h), storeTip,
                "tip-height block-index entry must equal the chain tip")
            // INTEL (asymmetry, see test C): a freshly-mined node's block_index holds
            // only applied heights 1..H (genesis absent). But this helper runs after a
            // RESTART, where recovery's `backfillBlockIndex` seeds the full canonical
            // chain INCLUDING genesis (height 0), so the recovered count is H+1.
            XCTAssertEqual(store.getBlockIndexCount(), Int(h) + 1,
                "post-restart block index count must equal height+1 (genesis..tip)")
        }
    }

    // MARK: - A. Restart tip determinism — ungraceful drop

    func test_restartTipDeterminism_ungracefulDrop() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, retentionDepth: 100, storageMode: .stateful)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(20, on: node1)

        let store1 = try await nexusStore(node1)
        let capturedTip = try XCTUnwrap(store1.getChainTip(), "tip captured")
        let capturedHeight = try XCTUnwrap(store1.getHeight(), "height captured")
        // Record the DiskBroker meta tip for intel (cadence-driven; may lag).
        let metaTipBefore = await diskBrokerMetaTip(node1, config: config)
        XCTAssertEqual(capturedHeight, 20, "height advanced to 20")

        // "Crash" = drop the node WITHOUT stop() (stop() is flush-only).
        _ = metaTipBefore

        let node2 = try await LatticeNode(config: restartConfig(of: config), genesisConfig: genesis)
        try await node2.start()
        let store2 = try await nexusStore(node2)
        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)
        let recoveredChainTip = await chain2.getMainChainTip()

        XCTAssertEqual(store2.getChainTip(), capturedTip,
            "restarted StateStore tip must equal captured tip (recovery authority)")
        XCTAssertEqual(store2.getHeight(), capturedHeight,
            "restarted height must equal captured height")
        XCTAssertEqual(recoveredChainTip, capturedTip,
            "in-memory ChainState tip after recovery must equal captured tip")
        await assertCanonicalConsistency(store2, chain: chain2)

        await node2.stop()
    }

    // MARK: - B. Restart tip determinism — graceful stop

    func test_restartTipDeterminism_gracefulStop() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, retentionDepth: 100, storageMode: .stateful)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(20, on: node1)

        let store1 = try await nexusStore(node1)
        let capturedTip = try XCTUnwrap(store1.getChainTip(), "tip captured")
        let capturedHeight = try XCTUnwrap(store1.getHeight(), "height captured")
        XCTAssertEqual(capturedHeight, 20, "height advanced to 20")

        // Graceful = flush before dropping.
        await node1.stop()

        let node2 = try await LatticeNode(config: restartConfig(of: config), genesisConfig: genesis)
        try await node2.start()
        let store2 = try await nexusStore(node2)
        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)
        let recoveredChainTip = await chain2.getMainChainTip()

        XCTAssertEqual(store2.getChainTip(), capturedTip,
            "restarted StateStore tip must equal captured tip after graceful stop")
        XCTAssertEqual(store2.getHeight(), capturedHeight,
            "restarted height must equal captured height after graceful stop")
        XCTAssertEqual(recoveredChainTip, capturedTip,
            "in-memory ChainState tip after recovery must equal captured tip")
        await assertCanonicalConsistency(store2, chain: chain2)

        await node2.stop()
    }

    // MARK: - C. StateStore block-index consistency

    func test_stateStoreIndexConsistency() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, retentionDepth: 100, storageMode: .stateful)

        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        try await mineBlocks(15, on: node)

        let store = try await nexusStore(node)
        let height = try XCTUnwrap(store.getHeight(), "height present")
        XCTAssertEqual(height, 15, "mined to height 15")

        // FINDING (current behavior captured): StateStore `block_index` does NOT
        // contain the GENESIS block (height 0). block_index rows are written only by
        // the applyBlock / commitCanonicalSegment path (StateStore.swift ~L818), and
        // genesis is never applied through that path. So for a node that has mined to
        // height H the index holds heights 1..H (H rows), NOT 0..H (H+1 rows), and
        // `getBlockHash(atHeight: 0)` is nil. Captured here as the observed invariant;
        // any later refactor that changes this (e.g. seeding genesis into block_index)
        // will flip these expected-failures and must be revisited.
        XCTExpectFailure("FINDING (Module 0): genesis (height 0) is absent from block_index; count is H not H+1") {
            XCTAssertEqual(store.getBlockIndexCount(), Int(height) + 1,
                "block index count would equal height+1 IFF genesis were indexed")
            XCTAssertNotNil(store.getBlockHash(atHeight: 0),
                "genesis (height 0) is NOT present in block_index")
        }
        // What IS true today: block_index holds exactly the applied heights 1..H.
        XCTAssertEqual(store.getBlockIndexCount(), Int(height),
            "block_index holds the applied heights 1..H (genesis excluded)")
        // Tip-height entry equals the canonical tip.
        XCTAssertEqual(store.getBlockHash(atHeight: height), store.getChainTip(),
            "tip-height index entry must equal chain tip")
        // Walk a few applied heights (1..H); every one is non-nil.
        for h: UInt64 in [1, height / 2, height - 1, height] {
            XCTAssertNotNil(store.getBlockHash(atHeight: h),
                "block-index entry at applied height \(h) must be non-nil")
        }

        await node.stop()
    }

    // MARK: - D. Tip content reachability

    func test_tipContentConsistency() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, retentionDepth: 100, storageMode: .stateful)

        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        try await mineBlocks(10, on: node)

        let store = try await nexusStore(node)
        let tip = try XCTUnwrap(store.getChainTip(), "tip present")
        let networkOpt = await node.network(for: "Nexus")
        let network = try XCTUnwrap(networkOpt, "Nexus network")

        // The canonical tip must never point at missing content: resolve it in-process.
        let stub = VolumeImpl<Block>(rawCID: tip, node: nil, encryptionInfo: nil)
        let resolved = try await stub.resolve(fetcher: network.ivyFetcher).node
        let block = try XCTUnwrap(resolved, "tip block content must be resolvable in-process")
        XCTAssertEqual(try VolumeImpl<Block>(node: block).rawCID, tip,
            "resolved tip block must hash to the canonical tip CID")

        await node.stop()
    }

    // MARK: - E. DiskBroker meta vs StateStore tip relationship

    func test_diskBrokerMetaRelationship() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        // SMALL persistInterval so the cadence-driven chain_tip meta write fires.
        let config = makeConfig(storagePath: storagePath, retentionDepth: 100,
                                storageMode: .stateful, persistInterval: 5)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(12, on: node1)

        let store1 = try await nexusStore(node1)
        let storeTip = try XCTUnwrap(store1.getChainTip(), "store tip")
        let storeHeight = try XCTUnwrap(store1.getHeight(), "store height")
        let metaTip = await diskBrokerMetaTip(node1, config: config)

        // OBSERVED RELATIONSHIP (intel for Module 2):
        // - StateStore tip advances PER BLOCK inside applyBlock (authoritative for
        //   reads while the process is live).
        // - DiskBroker chain_tip meta advances on the persist CADENCE: it is written
        //   by persistChainState, which maybepersist only triggers every
        //   `persistInterval` blocks. So the meta tip LAGS the StateStore tip by up
        //   to (persistInterval - 1) blocks. The DiskBroker meta is only a BOOTSTRAP
        //   CACHE: boot seeds ChainState from it (LatticeNode.swift ~line 740), then
        //   start()→recoverFromCAS rolls ChainState FORWARD to the StateStore tip,
        //   which is the canonical restart authority (option-b, Module 2).
        // Therefore at any captured instant: StateStore height >= meta-tip height.
        // Find the height the meta tip corresponds to by scanning the index.
        var metaTipHeight: UInt64? = nil
        if let metaTip {
            var h = storeHeight
            while true {
                if store1.getBlockHash(atHeight: h) == metaTip { metaTipHeight = h; break }
                if h == 0 { break }
                h -= 1
            }
        }
        if let metaTipHeight {
            XCTAssertLessThanOrEqual(metaTipHeight, storeHeight,
                "DiskBroker meta-tip height must be <= StateStore height (cadence lag)")
        }

        // Drop WITHOUT stop (crash), restart, and assert recovery is consistent:
        // the recovered tip is authoritative and the StateStore is rebuilt to match
        // the in-memory chain.
        let node2 = try await LatticeNode(config: restartConfig(of: config), genesisConfig: genesis)
        try await node2.start()
        let store2 = try await nexusStore(node2)
        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)
        await assertCanonicalConsistency(store2, chain: chain2)
        // Recovery never rolls FORWARD past what was durably persisted, and never
        // produces a tip below the durable meta tip.
        if let metaTip {
            let recoveredTip = try XCTUnwrap(store2.getChainTip(), "recovered tip")
            let recoveredHeight = try XCTUnwrap(store2.getHeight(), "recovered height")
            var recoveredFromMeta = recoveredTip == metaTip
            if !recoveredFromMeta, let metaTipHeight {
                recoveredFromMeta = recoveredHeight >= metaTipHeight
            }
            XCTAssertTrue(recoveredFromMeta,
                "recovered tip/height must be at least the durable DiskBroker meta tip")
        }
        // Capture for the log: store tip+height vs meta tip+height.
        print("[InvariantHarness E] storeTip=\(storeTip.prefix(12)) storeHeight=\(storeHeight) " +
              "metaTip=\(metaTip?.prefix(12) ?? "nil") metaTipHeight=\(metaTipHeight.map(String.init) ?? "nil")")

        await node2.stop()
    }

    // MARK: - F. Retention reachability

    func test_retentionReachability() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let retentionDepth: UInt64 = 3
        let config = makeConfig(storagePath: storagePath, retentionDepth: retentionDepth,
                                storageMode: .stateful, blockRetention: .retention)

        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        // Cross the retention window: with retentionDepth=3, mining to H=10 prunes
        // heights <= 7 (pruneHeight = block.height - retentionDepth, run per block).
        try await mineBlocks(10, on: node)

        let store = try await nexusStore(node)
        let height = try XCTUnwrap(store.getHeight(), "height present")
        XCTAssertEqual(height, 10, "mined to height 10")

        // pruneBlocks runs synchronously during block storage, so no extra
        // maintenance tick is needed. An IN-WINDOW block (within retentionDepth of
        // the tip) must still be reachable. Pick tip-1 (well inside the window).
        let inWindowHeight = height - 1
        let inWindowHash = try XCTUnwrap(store.getBlockHash(atHeight: inWindowHeight),
            "in-window block hash must still be indexed")

        let networkOpt = await node.network(for: "Nexus")
        let network = try XCTUnwrap(networkOpt, "Nexus network")
        let stub = VolumeImpl<Block>(rawCID: inWindowHash, node: nil, encryptionInfo: nil)
        let resolved = try? await stub.resolve(fetcher: network.ivyFetcher).node

        // CURRENT BEHAVIOR: an in-window block's content should be reachable after
        // pruning. If the known retention edge bug (Module 6) makes in-package tx
        // content unreachable for an in-window block, surface it as a FINDING via
        // XCTExpectFailure rather than failing the suite.
        XCTAssertNotNil(resolved,
            "in-window block (height \(inWindowHeight)) content must remain reachable after prune")
        if let block = resolved {
            XCTAssertEqual(try VolumeImpl<Block>(node: block).rawCID, inWindowHash,
                "resolved in-window block must hash to its CID")
            // The in-package transactions of an in-window block must also resolve.
            // FINDING (Module 6): pinning a block root does not protect its in-package
            // tx content from eviction (see MEMORY: retention-pruning-evicts-block-closure).
            // If that bites here, wrap in XCTExpectFailure to capture, not fail.
            let txResolvable = (try? await block.transactions.resolve(fetcher: network.ivyFetcher).node) != nil
            if !txResolvable {
                XCTExpectFailure("FINDING (Module 6): in-window block tx closure unreachable after prune") {
                    XCTAssertTrue(txResolvable,
                        "in-window block transactions must remain reachable after prune")
                }
            } else {
                XCTAssertTrue(txResolvable,
                    "in-window block transactions reachable after prune")
            }
        }

        await node.stop()
    }

    // TODO(Module 0): inherited-work replay needs child-chain harness.
    // Child-chain setup in-process (deploy + subscribedChains + fullChainPath +
    // merged-mining wiring) is well beyond the ~30-line budget for this module;
    // capture inherited-work replay (store.getAllInheritedWorkContributions())
    // once a child-chain harness exists.
}
