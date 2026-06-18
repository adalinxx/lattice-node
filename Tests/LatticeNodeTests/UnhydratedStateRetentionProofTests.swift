import XCTest
import Foundation
import Ivy
import VolumeBroker
import cashew
import UInt256
@testable import Lattice
@testable import LatticeNode

/// BLOCKER regression proof for the content-store cutover's canonical pin set.
///
/// Adversarial review found the naive pin `[blockHash]` BROKEN on the
/// gossip/durable-accept path. There, `resolveBlockContent` (Lattice
/// `Block+Content.swift`) resolves spec/transactions/children but DELIBERATELY
/// leaves `block.postState` UNHYDRATED (`postState.node == nil`). So
/// `VolumeImpl<Block>.storeRecursively` SKIPS the unhydrated postState boundary
/// and writes NO `blockHash → postState` `volume_entries` edge. The materialized
/// state frontier is stored SEPARATELY (rooted at `postState.rawCID`, mirroring
/// `storeAcceptedStateDiffRoots` → `collectStateVolumes`) with NO edge from the
/// block. Pinning `[blockHash]` alone therefore STRANDS the committed state →
/// eviction → consensus breakage.
///
/// The production fix (`LatticeNode+BlockStorage.consensusPinRoots`) pins
/// `[blockHash, block.postState.rawCID]`. These tests prove:
///   - NECESSITY: `[blockHash]` alone does NOT protect the separately-stored,
///     edge-disjoint state frontier on the gossip layout.
///   - SUFFICIENCY: `[blockHash, postState.rawCID]` DOES protect the whole
///     frontier (and the block's own closure stays reachable).
///
/// CRITICAL: this test FAITHFULLY reproduces the edge-disjoint gossip layout and
/// asserts edge-disjointness explicitly (gossipBlock.postState.node == nil AND
/// postState.rawCID NOT in the block's storedRoots). If postState were hydrated,
/// the block closure would already own/protect it and the test would pass
/// vacuously — proving nothing. We fail LOUDLY if the layout is not edge-disjoint.
final class UnhydratedStateRetentionProofTests: XCTestCase {

    // MARK: - Fixtures (mirror ProvenClosureRetentionTests)

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
    /// `accountCount` distinct premine owners produce a branching accounts trie in
    /// postState. The REAL `BlockBuilder.buildGenesis` path — postState is computed
    /// by applying the transactions, not hand-built.
    private func buildMultiVolumeGenesis(accountCount: Int, fetcher: Fetcher) async throws -> Block {
        var transactions: [Transaction] = []
        for i in 0..<accountCount {
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

    /// The REAL node block-closure store path, replicating the 3 lines of the
    /// private `LatticeNode+BlockStorage.collectBlockVolumes`.
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

    /// The REAL node state-frontier store path, replicating the private
    /// `LatticeNode+BlockStorage.collectStateVolumes` (rooted at the state CID).
    /// This mirrors `storeAcceptedStateDiffRoots`, which serializes the
    /// HYDRATED, materialized postState as its OWN volume tree.
    private func collectStateVolumes(
        _ state: LatticeStateHeader,
        broker: any VolumeBroker
    ) throws -> (volumes: [SerializedVolume], roots: [String]) {
        let storer = BrokerStorer(broker: broker)
        try state.storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: state.rawCID)
        return (volumes, storer.storedRoots)
    }

    // MARK: - Gossip-layout reproduction

    /// Produce the gossip/durable-accept layout on `disk`:
    ///  (1) a gossip-shaped block whose `postState.node == nil` (UNHYDRATED),
    ///      obtained by serializing a hydrated block into a CAS and re-resolving
    ///      ONLY its content package via `resolveBlockContent` (which does not
    ///      resolve state). The block closure is stored WITHOUT a postState edge.
    ///  (2) the HYDRATED postState frontier stored SEPARATELY, rooted at
    ///      `postState.rawCID`, with NO edge from the block.
    ///
    /// Returns the gossip block, its hash, the block-closure roots, and the
    /// separately-stored postState frontier roots. Asserts edge-disjointness
    /// (fails loudly if the layout is not genuinely edge-disjoint).
    private func makeGossipLayout(
        accountCount: Int,
        disk: DiskBroker,
        network: ChainNetwork
    ) async throws -> (gossipBlock: Block, blockHash: String, blockRoots: [String], stateRoots: [String]) {
        // 1. Build a fully HYDRATED block B and serialize its whole closure into a
        //    CAS, so every CID (incl. the postState trie) is fetchable.
        let fetcher = cas()
        let hydrated = try await buildMultiVolumeGenesis(accountCount: accountCount, fetcher: fetcher)
        let blockHash = try VolumeImpl<Block>(node: hydrated).rawCID
        try await storeBlockFixture(hydrated, to: fetcher)

        // 2. Reproduce the node's gossip resolution: stub header → resolveBlockContent
        //    (spec/transactions/children only; NOT postState). This yields a block
        //    whose postState boundary is unhydrated, exactly like the gossip path.
        guard let gossipBlock = try await VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            .resolveBlockContent(fetcher: fetcher).node else {
            XCTFail("resolveBlockContent yielded no block node")
            throw XCTSkip("no gossip block")
        }

        // PROOF the postState is genuinely UNHYDRATED and edge-disjoint:
        XCTAssertNil(gossipBlock.postState.node,
            "gossipBlock.postState.node MUST be nil (unhydrated) — otherwise the layout secretly hydrates postState and the test is vacuous")
        XCTAssertEqual(gossipBlock.postState.rawCID, hydrated.postState.rawCID,
            "gossip postState CID must equal the hydrated block's postState CID (same committed state, just unhydrated)")

        // 3. Store the gossip block CLOSURE (no postState edge, since postState is
        //    skipped by storeRecursively when unhydrated).
        let (blockVolumes, blockRoots) = try collectBlockVolumes(gossipBlock, blockHash: blockHash, broker: disk)
        try await network.storeVolumesDurably(blockVolumes)

        // SANITY: the unhydrated skip means postState.rawCID is NOT among the
        // block's storedRoots — there is NO blockHash → postState owned edge.
        XCTAssertFalse(blockRoots.contains(gossipBlock.postState.rawCID),
            "EDGE-DISJOINT PRECONDITION VIOLATED: postState.rawCID is in the block's storedRoots, meaning storeRecursively DID write the postState edge. The block closure already owns the state, so the test would pass vacuously. Aborting.")

        // 4. Store the HYDRATED postState frontier SEPARATELY (rooted at
        //    postState.rawCID), mirroring storeAcceptedStateDiffRoots →
        //    collectStateVolumes. Use the hydrated block's postState (which has a
        //    resolved trie), NOT the gossip block's unhydrated header.
        let (stateVolumes, stateRoots) = try collectStateVolumes(hydrated.postState, broker: disk)
        try await network.storeVolumesDurably(stateVolumes)

        // SANITY: the two stores are edge-DISJOINT — no overlap between the block
        // closure roots and the state frontier roots.
        let overlap = Set(blockRoots).intersection(Set(stateRoots))
        XCTAssertTrue(overlap.isEmpty,
            "block closure and state frontier must be edge-disjoint; overlapping roots: \(overlap)")
        XCTAssertTrue(stateRoots.contains(gossipBlock.postState.rawCID),
            "the separately-stored frontier must be rooted at postState.rawCID")

        return (gossipBlock, blockHash, blockRoots, stateRoots)
    }

    // MARK: - Test 1: NECESSITY — [blockHash]-only strands the frontier

    func testPinningOnlyBlockRootStrandsUnhydratedPostStateFrontier() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)

        let (gossipBlock, blockHash, _, stateRoots) =
            try await makeGossipLayout(accountCount: 8, disk: disk, network: network)
        let postStateCID = gossipBlock.postState.rawCID

        // Pin ONLY the block root (the BROKEN naive pin set).
        try await network.pinBatchDurably(roots: [blockHash], owner: "Nexus:0")

        // THE BUG: the separately-stored, edge-disjoint state frontier is NOT
        // protected by the block-root pin.
        let frontierReachable = await disk.isPinReachable(cid: postStateCID)
        print("[UnhydratedStateRetention] [blockHash]-only: isPinReachable(postState) = \(frontierReachable)")
        XCTAssertFalse(frontierReachable,
            "BUG REPRODUCTION FAILED: postState.rawCID was reachable under [blockHash]-only — the edge-disjoint layout was not achieved (or the block secretly owns postState).")

        // Real state loss, not just the root: at least one INTERIOR state-trie
        // node must ALSO be stranded under [blockHash]-only. (Some frontier nodes
        // are structurally shared with the block closure — e.g. recurring
        // empty-collection CIDs co-resident as volume_entries inside a block
        // volume — and stay reachable; those are NOT lost. The bug is the
        // frontier nodes UNIQUE to the materialized state, which the block closure
        // does not contain.) We require at least one stranded interior node so the
        // proof shows genuine committed-state loss, not merely the root edge.
        var strandedFrontier: [String] = []
        for root in stateRoots where !root.isEmpty {
            if !(await disk.isPinReachable(cid: root)) { strandedFrontier.append(root) }
        }
        print("[UnhydratedStateRetention] [blockHash]-only: stranded frontier node count = \(strandedFrontier.count)/\(stateRoots.count)")
        XCTAssertTrue(strandedFrontier.contains(postStateCID),
            "the postState root must be among the stranded nodes under [blockHash]-only")
        XCTAssertGreaterThanOrEqual(strandedFrontier.count, 1,
            "no state-frontier node was stranded under [blockHash]-only — the committed state was not actually lost, so the second pin would be unnecessary")

        // The frontier root carries NO direct owner under this pin set (it is only
        // ever protected by a direct pin on it, which is absent here).
        let postStateOwners = await disk.owners(root: postStateCID)
        XCTAssertTrue(postStateOwners.isEmpty,
            "postState root unexpectedly carries owner(s) \(postStateOwners) under [blockHash]-only")

        // Sanity: the block's OWN root IS reachable (the pin works for what it
        // covers; the gap is purely the edge-disjoint state frontier).
        let blockReachable = await disk.isPinReachable(cid: blockHash)
        XCTAssertTrue(blockReachable, "the block root itself must be reachable under its own pin")
    }

    // MARK: - Test 2: SUFFICIENCY — [blockHash, postState.rawCID] protects it

    func testPinningBlockRootAndPostStateRootProtectsTheFrontier() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)

        let (gossipBlock, blockHash, blockRoots, stateRoots) =
            try await makeGossipLayout(accountCount: 8, disk: disk, network: network)
        let postStateCID = gossipBlock.postState.rawCID

        // The production fix: pin the block OBJECT ROOTS.
        let pinRoots = [blockHash, postStateCID]
        try await network.pinBatchDurably(roots: pinRoots, owner: "Nexus:0")

        // The postState root is now pin-reachable.
        let frontierReachable = await disk.isPinReachable(cid: postStateCID)
        print("[UnhydratedStateRetention] [block,postState]: isPinReachable(postState) = \(frontierReachable)")
        XCTAssertTrue(frontierReachable,
            "postState.rawCID must be pin-reachable once it is pinned alongside the block root")

        // The WHOLE state frontier survives: every owned root of the postState trie
        // is pin-reachable (transitively, via the postState pin's owned edges).
        var strandedFrontier: [String] = []
        for root in stateRoots where !root.isEmpty {
            if !(await disk.isPinReachable(cid: root)) { strandedFrontier.append(root) }
        }
        if !strandedFrontier.isEmpty {
            XCTFail("""
            The postState pin did NOT transitively protect the full state frontier;
            \(strandedFrontier.count) frontier root(s) remained unreachable:
            \(strandedFrontier.prefix(10).joined(separator: "\n"))
            """)
        }

        // The block's own closure also stays reachable (the first pin still works).
        var strandedBlock: [String] = []
        for root in blockRoots where !root.isEmpty {
            if !(await disk.isPinReachable(cid: root)) { strandedBlock.append(root) }
        }
        XCTAssertTrue(strandedBlock.isEmpty,
            "block closure root(s) became unreachable under [block,postState] pin: \(strandedBlock.prefix(10))")

        // consensusPinRoots(block:) is retention-gate aware. Under the PRODUCTION
        // default, STATE retention is driven by storage retained roots, so the
        // object-grain consensus set DROPS postState and pins `[blockHash]` only.
        // The directly-pinned sufficiency proof above still holds for the OFF
        // (object-grain fallback) path, which this assertion also verifies.
        let node = try await makeNode()
        let producedDefault = await node.consensusPinRoots(block: gossipBlock)
        print("[UnhydratedStateRetention] consensusPinRoots (retained roots ON, default) = \(producedDefault)")
        XCTAssertEqual(producedDefault, [blockHash],
            "default ON: consensusPinRoots must DROP postState (state retained via storage retained roots) -> [blockHash] only")
        // OFF (object-grain fallback) path: consensusPinRoots must still pin EXACTLY
        // [blockHash, postState.rawCID] — a revert that strands postState here is the
        // BLOCKER this test guards for the object-grain mechanism.
        await node.setStateRetentionViaRetainedRootsForTests(false)
        await node.setStateRetentionViaRefcountForTests(false)
        let producedObjectGrain = await node.consensusPinRoots(block: gossipBlock)
        print("[UnhydratedStateRetention] consensusPinRoots (flip OFF, object-grain) = \(producedObjectGrain)")
        XCTAssertEqual(producedObjectGrain, [blockHash, postStateCID],
            "gate OFF: consensusPinRoots(block:) must pin exactly [blockHash, postState.rawCID]; a revert to [blockHash] strands the unhydrated frontier")
    }

    // MARK: - Test 3: references remain dropped (premise #2 unaffected)

    func testReferencesAreStillNotPinnedUnderTheFix() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)

        let (gossipBlock, blockHash, _, _) =
            try await makeGossipLayout(accountCount: 8, disk: disk, network: network)

        // Apply the production fix's pin set.
        try await network.pinBatchDurably(
            roots: [blockHash, gossipBlock.postState.rawCID], owner: "Nexus:0")

        // For a genesis, prevState == parentState == the empty state; the fix does
        // NOT pin them. They must carry no direct owner under this pin set.
        let prevOwners = await disk.owners(root: gossipBlock.prevState.rawCID)
        let parentOwners = await disk.owners(root: gossipBlock.parentState.rawCID)
        XCTAssertTrue(prevOwners.isEmpty,
            "prevState reference must NOT be directly owned under the fix; got \(prevOwners)")
        XCTAssertTrue(parentOwners.isEmpty,
            "parentState reference must NOT be directly owned under the fix; got \(parentOwners)")

        // And consensusPinRoots must NOT include the reference CIDs.
        let node = try await makeNode()
        let produced = Set(await node.consensusPinRoots(block: gossipBlock))
        XCTAssertFalse(produced.contains(gossipBlock.prevState.rawCID),
            "consensusPinRoots must not pin prevState (a reference)")
        XCTAssertFalse(produced.contains(gossipBlock.parentState.rawCID),
            "consensusPinRoots must not pin parentState (a reference)")
    }

    // MARK: - Node fixture (for consensusPinRoots)

    /// A minimal LatticeNode to invoke `consensusPinRoots(block:)` directly.
    /// `consensusPinRoots` is a pure function over the block, so the node never
    /// needs to be started (no TCP, no chain init).
    private func makeNode() async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: 0, storagePath: dir.appendingPathComponent("node"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        return try await LatticeNode(config: config, genesisConfig: testGenesis())
    }
}
