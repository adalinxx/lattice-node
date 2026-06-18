import XCTest
import Foundation
import Ivy
import VolumeBroker
import cashew
import UInt256
@testable import Lattice
@testable import LatticeNode

/// LINCHPIN proof for the content-store cutover.
///
/// The cutover's premise: pinning ONLY a block's root CID transitively protects
/// the block's ENTIRE owned closure (spec, transactions + per-tx bodies,
/// postState trie nodes, children) across VOLUME BOUNDARIES, via the
/// `volume_entries` owned-child edges that `storeRecursively` writes. If this
/// holds, the node can stop hand-enumerating sub-roots when it pins a block.
///
/// Why this is NOT covered by the existing `isPinReachable` tests
/// (VerifyBeforePinTests / AdversarialAvailabilityTests): those hand-build a
/// SINGLE `SerializedVolume` with multiple entries and only prove INTRA-volume
/// reachability — a pin owner on the volume root reaches its co-resident
/// entries. That says nothing about CROSS-volume owned edges. Here we drive the
/// REAL node store path (`BrokerStorer` + `VolumeImpl<Block>.storeRecursively`
/// + `collectVolumes(root:)` + `storedRoots`) so a genuine MULTI-VOLUME closure
/// is produced and the cross-volume `volume_entries` edges are exercised against
/// the actual pinned VolumeBroker (DiskBroker, sqlite-backed).
final class ProvenClosureRetentionTests: XCTestCase {

    // MARK: - Fixtures (mirror VerifyBeforePinTests)

    private func tempDiskBroker() throws -> DiskBroker {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)
    }

    /// Standalone ChainNetwork in LOCAL mode (durableBroker === sharedDiskBroker,
    /// so the pin-reachability serve gate is active). Never started — no TCP.
    private func makeNetwork(disk: DiskBroker) async throws -> ChainNetwork {
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    /// Build a genesis whose owned closure is non-trivially MULTI-VOLUME:
    /// `accountCount` distinct premine owners produce `accountCount` transactions
    /// (+ per-tx bodies, each its own boundary) and a multi-node accounts trie in
    /// postState. This is the real `BlockBuilder.buildGenesis` path — postState is
    /// computed by applying the transactions, not hand-built.
    private func buildMultiVolumeGenesis(accountCount: Int, fetcher: Fetcher) async throws -> Block {
        var transactions: [Transaction] = []
        for i in 0..<accountCount {
            // Distinct owner per tx → distinct accounts-trie leaves → a branching
            // trie (multiple internal nodes) rather than a single leaf.
            let owner = "premine-owner-\(i)-\(UUID().uuidString)"
            let action = AccountAction(owner: owner, delta: Int64(1000 + i))
            let body = TransactionBody(
                accountActions: [action], actions: [], depositActions: [],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 0, nonce: 0
            )
            let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
            transactions.append(Transaction(signatures: [owner: "genesis"], body: bodyHeader))
        }
        return try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            transactions: transactions,
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: fetcher
        )
    }

    /// The REAL node store path, replicating the 3 lines of the private
    /// `LatticeNode+BlockStorage.collectBlockVolumes`.
    private func collectBlockVolumes(
        _ block: Block,
        blockHash: String,
        broker: any VolumeBroker
    ) throws -> (volumes: [SerializedVolume], roots: [String]) {
        let storer = BrokerStorer(broker: broker)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: blockHash)
        return (volumes, storer.storedRoots)
    }

    // MARK: - Test 1: the linchpin proof

    func testPinningBlockRootTransitivelyProtectsEntireOwnedClosureAcrossVolumes() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()

        // 1. A real multi-volume block. 8 premine owners → 8 txs (+ bodies) + a
        //    branching accounts trie.
        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: fetcher)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        // 2. Store it via the REAL path.
        let (volumes, roots) = try collectBlockVolumes(block, blockHash: blockHash, broker: disk)
        try await network.storeVolumesDurably(volumes)

        // 3. The closure must be genuinely multi-volume.
        print("[ProvenClosureRetention] storedRoots.count = \(roots.count)")
        print("[ProvenClosureRetention] storedRoots = \(roots)")
        print("[ProvenClosureRetention] volumes.count = \(volumes.count)")
        XCTAssertGreaterThanOrEqual(
            roots.count, 4,
            "owned closure must span multiple volumes (blockHash + spec + transactions + postState at least); got \(roots.count): \(roots)"
        )
        // Cross-volume is the whole point: more than one SerializedVolume must be
        // produced, otherwise this degenerates to the intra-volume case the
        // existing tests already (insufficiently) cover.
        XCTAssertGreaterThan(
            volumes.count, 1,
            "closure must be split across MORE THAN ONE volume to exercise cross-volume volume_entries edges; got \(volumes.count) volume(s)"
        )

        // 4. Pin ONLY the block root.
        try await network.pinBatchDurably(roots: [blockHash], owner: "Nexus:0")

        // 5. THE PROOF: every non-root owned root must be transitively
        //    pin-reachable (protected across volume boundaries) AND have NO direct
        //    owner (proving the edges — not a direct pin — protect it).
        var notReachable: [String] = []
        var directlyOwned: [String] = []
        for root in roots where root != blockHash {
            let reachable = await disk.isPinReachable(cid: root)
            if !reachable { notReachable.append(root) }
            let owners = await disk.owners(root: root)
            if !owners.isEmpty { directlyOwned.append("\(root) owners=\(owners)") }
        }

        if !notReachable.isEmpty {
            XCTFail("""
            CRITICAL FOUNDATIONAL FINDING: cross-volume owned-edge protection is BROKEN.
            Pinning ONLY the block root did NOT transitively protect \(notReachable.count) owned closure root(s):
            \(notReachable.joined(separator: "\n"))
            The content-store cutover premise is INVALID at the node store path — the node
            CANNOT stop hand-enumerating sub-roots for pinning.
            """)
        }
        if !directlyOwned.isEmpty {
            XCTFail("""
            Owned closure root(s) carry a DIRECT pin owner — the test cannot conclude the
            volume_entries edges (rather than a direct pin) are what protects them:
            \(directlyOwned.joined(separator: "\n"))
            """)
        }

        // 6. Sanity: the one direct pin is on the block root.
        let rootOwners = await disk.owners(root: blockHash)
        XCTAssertFalse(rootOwners.isEmpty, "the block root must carry the single direct pin owner")
    }

    // MARK: - Test 2: references are not owned / not dragged into the closure

    func testReferencesAreNotOwnedAndNotDraggedIntoClosure() async throws {
        let disk = try tempDiskBroker()
        let fetcher = cas()

        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: fetcher)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        let (_, roots) = try collectBlockVolumes(block, blockHash: blockHash, broker: disk)
        let rootSet = Set(roots)

        // Reference fields must NOT be walked by storeRecursively (no backward
        // over-retention). For a genesis: prevState == parentState == the empty
        // state, and parent is nil.
        XCTAssertFalse(rootSet.contains(block.prevState.rawCID),
            "block.prevState (a reference) must NOT be in the owned closure; got it in \(roots)")
        XCTAssertFalse(rootSet.contains(block.parentState.rawCID),
            "block.parentState (a reference) must NOT be in the owned closure")
        if let parent = block.parent {
            XCTAssertFalse(rootSet.contains(parent.rawCID),
                "block.parent (a reference) must NOT be in the owned closure")
        }
    }

    // MARK: - Test 3: negative control — an unpinned sibling is NOT reachable

    func testUnpinnedSiblingRootIsNotPinReachable() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()

        // Pinned block.
        let pinned = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: fetcher)
        let pinnedHash = try VolumeImpl<Block>(node: pinned).rawCID
        let (pinnedVolumes, _) = try collectBlockVolumes(pinned, blockHash: pinnedHash, broker: disk)
        try await network.storeVolumesDurably(pinnedVolumes)
        try await network.pinBatchDurably(roots: [pinnedHash], owner: "Nexus:0")

        // A second, UNRELATED block stored durably but NEVER pinned.
        let sibling = try await buildMultiVolumeGenesis(accountCount: 6, fetcher: fetcher)
        let siblingHash = try VolumeImpl<Block>(node: sibling).rawCID
        XCTAssertNotEqual(siblingHash, pinnedHash, "sibling must be a distinct block")
        let (siblingVolumes, _) = try collectBlockVolumes(sibling, blockHash: siblingHash, broker: disk)
        try await network.storeVolumesDurably(siblingVolumes)

        let reachable = await disk.isPinReachable(cid: siblingHash)
        XCTAssertFalse(reachable,
            "an unpinned sibling block root must NOT be pin-reachable — the gate is real, not 'everything on disk is reachable'")
        let owners = await disk.owners(root: siblingHash)
        XCTAssertTrue(owners.isEmpty, "the unpinned sibling must have no owner; got \(owners)")
    }
}
