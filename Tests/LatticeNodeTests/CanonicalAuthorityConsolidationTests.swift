import XCTest
@testable import LatticeNode
@testable import Lattice
import cashew
import VolumeBroker
import UInt256

/// Module 2: Canonical Authority Consolidation.
///
/// Pins the SHIPPED restart-authority model (option-b): the StateStore
/// (`state.db`, per-block, crash-safe) is the durable canonical authority that
/// recovery rolls FORWARD to. The DiskBroker `chain_tip` meta (`volumes.sqlite`,
/// written on the `persistInterval` cadence) and `chain_state.json` are coarse
/// BOOTSTRAP CACHES: init bootstraps ChainState from the (possibly lagging or
/// absent) DiskBroker meta, then `start()`→`recoverFromCAS` overrides it by
/// rolling forward to the StateStore tip.
///
/// These are CHARACTERIZATION tests: they assert CURRENT behavior so a later
/// change to the authority model breaks them loudly. They spin up REAL nodes
/// (full `start()` + mining), so they are skipped in CI and only run locally.
final class CanonicalAuthorityConsolidationTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true",
                      "CanonicalAuthorityConsolidationTests skipped in CI (real nodes)")
    }

    // MARK: - Fixtures

    /// A HIGH `persistInterval` keeps the cadence-driven DiskBroker `chain_tip`
    /// meta write from ever firing during the run, so the meta stays at its boot
    /// value (genesis/absent) while the StateStore tip advances per-block.
    private func makeConfig(
        storagePath: URL,
        retentionDepth: UInt64 = 100,
        storageMode: StorageMode = .stateful,
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
            blockRetention: .retention, minPeerKeyBits: 0
        )
    }

    /// A restart config on the SAME storage with a fresh listen port + key.
    /// Recovery keys off storagePath + genesis, not the port.
    private func restartConfig(of config: LatticeNodeConfig) -> LatticeNodeConfig {
        makeConfig(storagePath: config.storagePath,
                   retentionDepth: config.retentionDepth,
                   storageMode: config.storageMode,
                   persistInterval: config.persistInterval)
    }

    private func nexusStore(_ node: LatticeNode) async throws -> StateStore {
        let key = await node.chainKey(forDirectory: "Nexus")
        let store = await node.stateStores[key]
        return try XCTUnwrap(store, "Nexus state store")
    }

    /// The DiskBroker `chain_tip` meta for a plain Nexus node (bootKey == "Nexus").
    private func diskBrokerMetaTip(_ node: LatticeNode) async -> String? {
        await node.sharedDiskBroker.getChainMeta(key: "chain_tip:Nexus")
    }

    // MARK: - a. roll-forward past a lagging/absent DiskBroker meta

    /// With a HIGH persistInterval the cadence DiskBroker meta write never fires,
    /// so the meta LAGS (or is absent) while the StateStore tip advances per-block.
    /// On an ungraceful restart, recovery must roll FORWARD to the StateStore tip
    /// (the LEAD), NOT fall back to the lagging/absent meta — proving StateStore is
    /// the restart authority.
    func test_recoveryRollsForwardToStateStoreTip_pastLaggingDiskBrokerMeta() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, persistInterval: 10_000)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(12, on: node1)

        let store1 = try await nexusStore(node1)
        let stateStoreTip = try XCTUnwrap(store1.getChainTip(), "StateStore tip captured")
        let stateStoreHeight = try XCTUnwrap(store1.getHeight(), "StateStore height captured")
        XCTAssertEqual(stateStoreHeight, 12, "StateStore tip advanced per-block to height 12")

        // The cadence meta write (persistInterval=10_000) never fired: the meta
        // must LAG the StateStore tip (it is nil/genesis, never the H=12 tip).
        let metaTip = await diskBrokerMetaTip(node1)
        let genesisHash = await node1.genesisResult.blockHash
        XCTAssertNotEqual(metaTip, stateStoreTip,
            "DiskBroker meta must lag the per-block StateStore tip (cadence never fired)")
        XCTAssertTrue(metaTip == nil || metaTip == genesisHash,
            "DiskBroker meta must be absent or still at genesis (no cadence write)")

        // "Crash" = drop node1 WITHOUT stop().

        // Restart on the SAME storage through the real start() recovery path.
        let node2 = try await LatticeNode(config: restartConfig(of: config), genesisConfig: genesis)
        try await node2.start()
        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)
        let recoveredTip = await chain2.getMainChainTip()

        // Recovery rolled FORWARD to the StateStore tip — the LEAD, not the meta.
        XCTAssertEqual(recoveredTip, stateStoreTip,
            "recovered in-memory tip must equal the pre-crash StateStore tip (roll-forward authority)")
        XCTAssertNotEqual(recoveredTip, metaTip ?? genesisHash,
            "recovered tip must NOT be the lagging/absent DiskBroker meta")
        let store2 = try await nexusStore(node2)
        XCTAssertEqual(store2.getChainTip(), stateStoreTip,
            "restarted StateStore tip must equal the pre-crash StateStore tip")
        XCTAssertEqual(store2.getHeight(), stateStoreHeight,
            "restarted height must equal the pre-crash StateStore height")

        await node2.stop()
    }

    // MARK: - b. disagreeing stores → StateStore tip wins

    /// When the StateStore tip is ahead of the DiskBroker meta (built as in (a)),
    /// the StateStore tip wins on restart AND the StateStore index is consistent
    /// (mirrors InvariantHarness `assertCanonicalConsistency`).
    func test_bootWithDisagreeingStores_stateStoreTipWins() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, persistInterval: 10_000)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(12, on: node1)

        let store1 = try await nexusStore(node1)
        let stateStoreTip = try XCTUnwrap(store1.getChainTip(), "StateStore tip captured")
        let stateStoreHeight = try XCTUnwrap(store1.getHeight(), "StateStore height captured")
        let metaTip = await diskBrokerMetaTip(node1)
        XCTAssertNotEqual(metaTip, stateStoreTip,
            "precondition: stores DISAGREE (meta lags the StateStore tip)")

        // "Crash" = drop node1 WITHOUT stop().

        let node2 = try await LatticeNode(config: restartConfig(of: config), genesisConfig: genesis)
        try await node2.start()
        let store2 = try await nexusStore(node2)
        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)

        // StateStore tip wins.
        let recoveredTip = await chain2.getMainChainTip()
        XCTAssertEqual(recoveredTip, stateStoreTip,
            "StateStore tip must win when the stores disagree")
        XCTAssertEqual(store2.getChainTip(), stateStoreTip, "restarted StateStore tip wins")
        XCTAssertEqual(store2.getHeight(), stateStoreHeight, "restarted height matches the StateStore lead")

        // StateStore index is consistent (assertCanonicalConsistency style).
        let storeTip = store2.getChainTip()
        XCTAssertEqual(storeTip, Optional(recoveredTip),
            "StateStore tip and in-memory ChainState tip must agree")
        let h = try XCTUnwrap(store2.getHeight(), "recovered height")
        XCTAssertEqual(store2.getBlockHash(atHeight: h), storeTip,
            "tip-height block-index entry must equal the chain tip")
        // After a RESTART, recovery's backfillBlockIndex seeds the full canonical
        // chain INCLUDING genesis (height 0), so the count is H+1.
        XCTAssertEqual(store2.getBlockIndexCount(), Int(h) + 1,
            "post-restart block index count must equal height+1 (genesis..tip)")

        await node2.stop()
    }

    // MARK: - c. absent meta → recover to StateStore tip, no rollback

    /// The persistInterval-high + ungraceful-drop case where the DiskBroker meta
    /// is absent. Recovery must NOT fall back to genesis and must NOT roll back —
    /// it recovers to the StateStore tip. (Mirrors StorageStartRecoveryTests; made
    /// explicit for the option-b authority model.)
    func test_absentDiskBrokerMeta_recoversToStateStoreTip_noRollback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storagePath = tmpDir.appendingPathComponent("node")
        let genesis = testGenesis()
        let config = makeConfig(storagePath: storagePath, persistInterval: 10_000)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(12, on: node1)

        let store1 = try await nexusStore(node1)
        let stateStoreTip = try XCTUnwrap(store1.getChainTip(), "StateStore tip captured")
        let stateStoreHeight = try XCTUnwrap(store1.getHeight(), "StateStore height captured")
        let genesisHash = await node1.genesisResult.blockHash

        // "Crash" = drop node1 WITHOUT stop().

        let node2 = try await LatticeNode(config: restartConfig(of: config), genesisConfig: genesis)
        try await node2.start()
        let store2 = try await nexusStore(node2)
        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)
        let recoveredTip = await chain2.getMainChainTip()
        let recoveredHeight = try XCTUnwrap(store2.getHeight(), "recovered height")

        // Did NOT fall back to genesis.
        XCTAssertNotEqual(recoveredTip, genesisHash,
            "recovery must NOT fall back to genesis when the DiskBroker meta is absent")
        XCTAssertGreaterThan(recoveredHeight, 0,
            "recovered height must be above genesis")
        // Did NOT roll back — recovered exactly to the StateStore tip.
        XCTAssertEqual(recoveredTip, stateStoreTip,
            "recovery must reach the StateStore tip (no rollback)")
        XCTAssertEqual(recoveredHeight, stateStoreHeight,
            "recovered height must equal the StateStore height (no rollback)")

        await node2.stop()
    }
}
