import XCTest
@testable import LatticeNode
@testable import Lattice
import Ivy
import Tally
import cashew
import VolumeBroker
import UInt256

/// Module 3: Canonical Transition Audit Record.
///
/// A MINIMAL, AUDIT-ONLY log of canonical transitions published through
/// `publishCanonicalTransition`. It is pure observability: NOT a replay queue,
/// NOT a second authority, and NOTHING in recovery/reconcile/startup reads it.
///
/// AUDIT COVERAGE FINDING: a plain single-block extend does NOT route through
/// `publishCanonicalTransition` — `processBlockAndRecoverReorg` applies the
/// immediate tip via `applyAcceptedBlock` and only calls
/// `publishCanonicalTransition` when `parentOfNewTip != tipBefore` (a reorg or a
/// multi-block inherited-weight promotion). So the audit log records exactly the
/// non-trivial canonical transitions (reorgs / promotions), not every per-block
/// extend. The append-with-empty-orphaned shape is exercised directly against
/// StateStore; the reorg shape is exercised end-to-end through a real node.
final class CanonicalTransitionRecordTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true",
                      "CanonicalTransitionRecordTests skipped in CI (real nodes / disk)")
    }

    // MARK: - Fixtures

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeNode(storagePath: URL) async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: storagePath,
            enableLocalDiscovery: false,
            minPeerKeyBits: 0
        )
        return try await LatticeNode(config: config, genesisConfig: testGenesis())
    }

    private func nexusStore(_ node: LatticeNode) async throws -> StateStore {
        let key = await node.chainKey(forDirectory: "Nexus")
        let store = await node.stateStores[key]
        return try XCTUnwrap(store, "Nexus state store")
    }

    // MARK: - a. plain append records a transition with empty orphaned

    /// The audit row written by a non-reorg promotion has an empty `orphaned`
    /// set and records the advancing tip. Driven directly against StateStore
    /// because a plain per-block extend does NOT route through
    /// `publishCanonicalTransition` (see the type doc above) — this exercises the
    /// exact append shape that publish writes for a no-orphan promotion.
    func test_plainAppend_recordsTransition_withEmptyOrphaned() async throws {
        let store = try StateStore(storagePath: tempDir(), chain: "Nexus")

        try await store.appendCanonicalTransition(
            oldTip: "tip-old",
            newTip: "tip-new",
            height: 7,
            reason: "block-processing",
            promoted: [(hash: "tip-new", height: 7)],
            orphaned: []
        )

        let latest = try XCTUnwrap(store.getLatestCanonicalTransition(),
                                   "an append must produce a recorded transition")
        XCTAssertEqual(latest.newTip, "tip-new")
        XCTAssertEqual(latest.oldTip, "tip-old")
        XCTAssertEqual(latest.height, 7)
        XCTAssertEqual(latest.reason, "block-processing")
        XCTAssertEqual(latest.orphaned, [], "a non-reorg promotion records no orphaned blocks")
        XCTAssertEqual(latest.promoted.map(\.hash), ["tip-new"])
        XCTAssertEqual(latest.promoted.map(\.height), [7])
    }

    // MARK: - b. reorg records the promoted + orphaned sets through the real publish path

    /// An inherited-weight promotion flips the canonical tip through
    /// `publishCanonicalTransition` (bypassing the per-block apply path), so it
    /// must produce one audit row with the orphaned incumbent and the promoted
    /// new tip. Reuses the CanonicalPublishTests inherited-weight pattern.
    func test_reorg_recordsPromotedAndOrphaned() async throws {
        let node = try await makeNode(storagePath: tempDir())
        addTeardownBlock { [node] in await node.stop() }
        let networkOpt = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkOpt)
        let chainOpt = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainOpt)

        let genesis = await node.genesisResult.block
        let fetcher = await network.ivyFetcher

        // Canonical block A at height 1.
        let a = try await buildRetargetedTestBlock(
            previous: genesis, timestamp: genesis.timestamp + 1_000, nonce: 1, fetcher: fetcher)
        let aCID = try VolumeImpl<Block>(node: a).rawCID
        try await storeBlockFixtureVolumes(a, in: network)
        let aData = try XCTUnwrap(a.toData())
        await node.chainNetwork(
            network, didReceiveBlock: aCID,
            data: aData, from: PeerID(publicKey: "peer-a"))
        let tipAfterA = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterA, aCID)

        // Equal-height sibling B — the tie holds the incumbent A.
        let b = try await buildRetargetedTestBlock(
            previous: genesis, timestamp: genesis.timestamp + 2_000, nonce: 2, fetcher: fetcher)
        let bCID = try VolumeImpl<Block>(node: b).rawCID
        XCTAssertNotEqual(bCID, aCID)
        try await storeBlockFixtureVolumes(b, in: network)
        let bData = try XCTUnwrap(b.toData())
        await node.chainNetwork(
            network, didReceiveBlock: bCID,
            data: bData, from: PeerID(publicKey: "peer-b"))
        let tipAfterB = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB, aCID, "tie holds the incumbent")

        // Fold verified inherited (securing) work onto B so fork choice promotes
        // it — a real reorg routed through publishCanonicalTransition.
        let securing = workForTarget(UInt256.max) &* UInt256(100)
        let applied = await node.applyInheritedWorkContributions(
            directory: "Nexus",
            blockHash: bCID,
            contributions: [(id: "securing-parent", work: securing)],
            source: IvyContentSource(fetcher))
        XCTAssertTrue(applied, "inherited-weight fold + publish must succeed")
        let tipAfterPromotion = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterPromotion, bCID, "inherited weight must promote B")

        let store = try await nexusStore(node)
        let record = try XCTUnwrap(store.getLatestCanonicalTransition(),
                                   "the reorg publish must have recorded an audit row")
        XCTAssertEqual(record.newTip, bCID, "audited new tip is the promoted block")
        XCTAssertEqual(record.height, 1)
        XCTAssertEqual(record.orphaned, [aCID], "the displaced incumbent A is orphaned")
        XCTAssertEqual(record.promoted.map(\.hash), [bCID], "B is the promoted block")
        XCTAssertEqual(record.newTip, store.getChainTip(), "audited tip matches durable tip")
    }

    // MARK: - c. the audit record is not consulted by recovery

    /// Mine blocks, "crash" (drop without stop), and restart on the same
    /// storage. Recovery must roll forward to the correct StateStore tip WITHOUT
    /// reading canonical_transitions — the log is purely additive. (Plain
    /// extends don't write the log, so it may even be empty; recovery is
    /// unaffected either way, which is the point.)
    func test_auditRecord_isNotConsultedByRecovery() async throws {
        let storagePath = tempDir().appendingPathComponent("node")
        let genesis = testGenesis()
        let kp = CryptoUtils.generateKeyPair()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000,
            retentionDepth: 100, minPeerKeyBits: 0)

        let node1 = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(8, on: node1)
        let store1 = try await nexusStore(node1)
        let preCrashTip = try XCTUnwrap(store1.getChainTip())
        let preCrashHeight = try XCTUnwrap(store1.getHeight())
        XCTAssertEqual(preCrashHeight, 8)
        // "Crash": drop node1 without stop().

        // Restart on the SAME storage (fresh port + key) through real recovery.
        let kp2 = CryptoUtils.generateKeyPair()
        let restartConfig = LatticeNodeConfig(
            publicKey: kp2.publicKey, privateKey: kp2.privateKey,
            listenPort: nextTestPort(), storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000,
            retentionDepth: 100, minPeerKeyBits: 0)
        let node2 = try await LatticeNode(config: restartConfig, genesisConfig: genesis)
        addTeardownBlock { [node2] in await node2.stop() }
        try await node2.start()

        let chain2Opt = await node2.chain(for: "Nexus")
        let chain2 = try XCTUnwrap(chain2Opt)
        let recoveredTip = await chain2.getMainChainTip()
        XCTAssertEqual(recoveredTip, preCrashTip,
                       "recovery must roll forward to the StateStore tip without the audit log")
        let store2 = try await nexusStore(node2)
        XCTAssertEqual(store2.getChainTip(), preCrashTip)
        XCTAssertEqual(store2.getHeight(), preCrashHeight)
        // The audit log is observability only — recovery never read it.
        _ = store2.getRecentCanonicalTransitions(limit: 16)
    }

    // MARK: - d. bounded retention prunes to keepLast

    /// Appending more than `keepLast` rows prunes the table to the most recent
    /// `keepLast`. Driven directly against StateStore with a tiny keepLast.
    func test_boundedRetention() async throws {
        let store = try StateStore(storagePath: tempDir(), chain: "Nexus")
        let keepLast = 5
        let total = 17

        for i in 0..<total {
            try await store.appendCanonicalTransition(
                oldTip: "old-\(i)",
                newTip: "new-\(i)",
                height: UInt64(i),
                reason: "test",
                promoted: [(hash: "new-\(i)", height: UInt64(i))],
                orphaned: [],
                keepLast: keepLast)
        }

        let kept = store.getRecentCanonicalTransitions(limit: total)
        XCTAssertEqual(kept.count, keepLast, "table must be pruned to keepLast rows")
        // Newest-first: the surviving rows are the last keepLast appended.
        XCTAssertEqual(kept.map(\.newTip), (total - keepLast..<total).reversed().map { "new-\($0)" })
        XCTAssertEqual(store.getLatestCanonicalTransition()?.newTip, "new-\(total - 1)")
    }
}
