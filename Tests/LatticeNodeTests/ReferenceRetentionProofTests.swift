import XCTest
import Foundation
import Ivy
import VolumeBroker
import cashew
import UInt256
@testable import Lattice
@testable import LatticeNode

/// PREMISE #2 proof for the content-store cutover.
///
/// The cutover wants the node to pin ONLY whole block ROOTS and STOP pinning
/// state-reference roots, so retention can reclaim old state. Premise #1 (already
/// proven in `ProvenClosureRetentionTests`) established that pinning a block root
/// transitively protects its OWNED closure (spec, transactions, postState trie,
/// children) across volume boundaries.
///
/// This file proves premise #2 — the one that GATES dropping the reference pins:
/// a block's `prevState`/`parentState` REFERENCE is pin-reachable via its
/// PRODUCER's pin; the CONSUMER block does not need to pin anything for it.
///
/// Why this holds (Lattice 12.0.0+ Reference model): `buildBlock` sets
/// `prevState = Reference(previous.postState)` (BlockBuilder.swift), so
/// `block_{N+1}.prevState` is the SAME CID as `block_N.postState`, which block N
/// OWNS (it is walked by block N's `storeRecursively`). Therefore pinning block
/// N's root must make block N+1's prevState reference pin-reachable WITHOUT block
/// N+1 pinning anything for it.
///
/// If either proof FAILS, dropping reference pins would strand a live consumer's
/// prevState and the cutover's pin model is UNSAFE — reported LOUDLY.
final class ReferenceRetentionProofTests: XCTestCase {

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
    ///
    /// NONCE GOTCHA: each distinct signer's first genesis tx must be nonce 0.
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

    /// Build the CONSUMER block B1 on top of producer G, applying `>= 2` transfers
    /// so postState_{B1} != postState_G. Each transfer mints to a fresh owner
    /// (nonce 0 per distinct signer) so the accounts trie genuinely changes.
    private func buildConsumerBlock(on producer: Block, transferCount: Int, fetcher: Fetcher) async throws -> Block {
        var transactions: [Transaction] = []
        for i in 0..<transferCount {
            let owner = "consumer-credit-\(i)-\(UUID().uuidString)"
            let action = AccountAction(owner: owner, delta: Int64(5000 + i))
            let body = TransactionBody(
                accountActions: [action], actions: [], depositActions: [],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 0, nonce: 0
            )
            let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
            transactions.append(Transaction(signatures: [owner: "consumer"], body: bodyHeader))
        }
        return try await BlockBuilder.buildBlock(
            previous: producer,
            transactions: transactions,
            timestamp: producer.timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
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

    // MARK: - Test 1: consumer's prevState reference is protected by producer pin

    func testConsumerPrevStateReferenceIsProtectedByProducerPin() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()

        // 1. Producer genesis G (multi-owner premine → real multi-node trie) and
        //    consumer block B1 applying >= 2 transfers (so postState_{B1} != postState_G).
        let genesis = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: fetcher)
        let block1 = try await buildConsumerBlock(on: genesis, transferCount: 3, fetcher: fetcher)

        let genesisHash = try VolumeImpl<Block>(node: genesis).rawCID
        let block1Hash = try VolumeImpl<Block>(node: block1).rawCID

        // 2. Store BOTH via the real path into ONE DiskBroker.
        let (genesisVolumes, genesisRoots) = try collectBlockVolumes(genesis, blockHash: genesisHash, broker: disk)
        let (block1Volumes, block1Roots) = try collectBlockVolumes(block1, blockHash: block1Hash, broker: disk)
        try await network.storeVolumesDurably(genesisVolumes)
        try await network.storeVolumesDurably(block1Volumes)

        // 3. THE REFERENCE IDENTITY the cutover relies on:
        //    block1.prevState IS genesis.postState (same CID).
        print("[ReferenceRetention] genesis.postState.rawCID = \(genesis.postState.rawCID)")
        print("[ReferenceRetention] block1.prevState.rawCID  = \(block1.prevState.rawCID)")
        print("[ReferenceRetention] block1.postState.rawCID  = \(block1.postState.rawCID)")
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID,
            "Reference identity: block1.prevState must be the SAME CID as genesis.postState (the producer's owned postState)")
        XCTAssertNotEqual(block1.postState.rawCID, genesis.postState.rawCID,
            "consumer must mutate state: postState_{B1} must differ from postState_G (transfers were applied)")

        // 4. genesis.postState is OWNED by G (in G's storedRoots) and is NOT in
        //    B1's storedRoots (it is a reference, not walked by B1's storeRecursively).
        let genesisRootSet = Set(genesisRoots)
        let block1RootSet = Set(block1Roots)
        XCTAssertTrue(genesisRootSet.contains(genesis.postState.rawCID),
            "genesis.postState must be OWNED by G (present in G's storedRoots)")
        XCTAssertFalse(block1RootSet.contains(block1.prevState.rawCID),
            "block1.prevState (a Reference) must NOT be in B1's storedRoots — B1 does not own/walk it")

        // 5. Pin ONLY the block roots. NOTHING pinned for prevState/state references.
        try await network.pinBatchDurably(roots: [genesisHash], owner: "Nexus:0")
        try await network.pinBatchDurably(roots: [block1Hash], owner: "Nexus:1")

        // 6. THE PROOF: B1's prevState reference is protected purely via G's pin,
        //    because it IS G's owned postState — with NO direct pin on it.
        let reachable = await disk.isPinReachable(cid: block1.prevState.rawCID)
        let directOwners = await disk.owners(root: block1.prevState.rawCID)
        print("[ReferenceRetention] isPinReachable(block1.prevState) = \(reachable)")
        print("[ReferenceRetention] owners(block1.prevState) = \(directOwners)")

        if !reachable {
            XCTFail("""
            CRITICAL FOUNDATIONAL FINDING: PREMISE #2 IS INVALID.
            block1.prevState (== genesis.postState, CID \(block1.prevState.rawCID)) is NOT
            pin-reachable after pinning ONLY the block roots. Dropping reference pins would
            STRAND a live consumer's prevState — the content-store cutover's pin model is
            UNSAFE and must be rethought. The consumer CANNOT rely on the producer's pin to
            keep its prevState alive.
            """)
        }
        XCTAssertTrue(directOwners.isEmpty, """
        block1.prevState carries a DIRECT pin owner (\(directOwners)); the proof cannot
        conclude it is protected PURELY by transitive reachability from G's root pin.
        """)

        // 7. Sanity: the only direct pin reaching it is via G's root.
        let genesisOwners = await disk.owners(root: genesisHash)
        XCTAssertEqual(genesisOwners, ["Nexus:0"], "G's root must carry exactly the producer pin")
    }

    // MARK: - Test 2: pruning the producer does NOT strand the consumer

    func testProducerPruneReclaimsStateNodesUniqueToOldPostStateButKeepsSharedNodes() async throws {
        let disk = try tempDiskBroker()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()

        let genesis = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: fetcher)
        let block1 = try await buildConsumerBlock(on: genesis, transferCount: 3, fetcher: fetcher)

        let genesisHash = try VolumeImpl<Block>(node: genesis).rawCID
        let block1Hash = try VolumeImpl<Block>(node: block1).rawCID

        let (genesisVolumes, genesisRoots) = try collectBlockVolumes(genesis, blockHash: genesisHash, broker: disk)
        let (block1Volumes, block1Roots) = try collectBlockVolumes(block1, blockHash: block1Hash, broker: disk)
        try await network.storeVolumesDurably(genesisVolumes)
        try await network.storeVolumesDurably(block1Volumes)

        // Pin both block roots (producer = Nexus:0, consumer = Nexus:1).
        try await network.pinBatchDurably(roots: [genesisHash], owner: "Nexus:0")
        try await network.pinBatchDurably(roots: [block1Hash], owner: "Nexus:1")

        // Reachability of the shared prevState BEFORE pruning the producer.
        let prevStateCID = block1.prevState.rawCID
        let reachableBefore = await disk.isPinReachable(cid: prevStateCID)
        print("[ReferenceRetention] before prune: isPinReachable(prevState) = \(reachableBefore)")
        XCTAssertTrue(reachableBefore, "precondition: prevState must be reachable while G is pinned")

        // Identify nodes SHARED between postState_G and postState_{B1} (structural
        // sharing — e.g. recurring empty-collection CIDs, untouched trie subtrees).
        let block1RootSet = Set(block1Roots)
        let shared = Set(genesisRoots).intersection(block1RootSet)
        print("[ReferenceRetention] shared(genesisRoots, block1Roots).count = \(shared.count)")

        // SIMULATE PRUNING THE PRODUCER: release G.
        try await network.unpinAllDurably(owner: "Nexus:0")

        // (a) B1's OWN closure must STILL be fully pin-reachable via B1's pin.
        var strandedOwned: [String] = []
        for root in block1Roots {
            if !(await disk.isPinReachable(cid: root)) { strandedOwned.append(root) }
        }
        if !strandedOwned.isEmpty {
            XCTFail("""
            CRITICAL FOUNDATIONAL FINDING: pruning the PRODUCER stranded part of the
            CONSUMER's OWNED closure (\(strandedOwned.count) root(s)):
            \(strandedOwned.prefix(10).joined(separator: "\n"))
            The consumer is no longer fully validatable from its own pinned closure —
            the cutover's per-block pin model is UNSAFE.
            """)
        }
        let block1RootReachable = await disk.isPinReachable(cid: block1Hash)
        XCTAssertTrue(block1RootReachable, "B1's own root must remain reachable via B1's own pin after pruning G")

        // (b) Any node SHARED between postState_G and postState_{B1} must STILL be
        //     reachable — protected via B1's owned postState closure (structural
        //     sharing). At minimum the recurring empty-collection CIDs are shared.
        var strandedShared: [String] = []
        for cid in shared {
            if !(await disk.isPinReachable(cid: cid)) { strandedShared.append(cid) }
        }
        XCTAssertTrue(strandedShared.isEmpty, """
        Shared trie node(s) that B1 also owns became unreachable after pruning G: \(strandedShared.prefix(10))
        Structural sharing means B1's pin must keep any node it co-owns alive.
        """)

        // (c) The producer-UNIQUE postState reference is no longer directly pinned
        //     and is now eligible for lazy reclamation: it was protected ONLY by G's
        //     pin (it is a Reference for B1, not owned), so once G is unpinned it is
        //     no longer pin-reachable — UNLESS it happens to be shared with B1.
        //     (We assert protection facts, not physical deletion — eviction is lazy.)
        let prevStateReachableAfter = await disk.isPinReachable(cid: prevStateCID)
        let prevStateIsSharedWithConsumer = shared.contains(prevStateCID) || block1RootSet.contains(prevStateCID)
        print("[ReferenceRetention] after prune: isPinReachable(prevState) = \(prevStateReachableAfter)")
        print("[ReferenceRetention] prevState shared-with-consumer = \(prevStateIsSharedWithConsumer)")
        print("[ReferenceRetention] postState_{B1} == postState_G ? \(block1.postState.rawCID == genesis.postState.rawCID)")
        if !prevStateIsSharedWithConsumer {
            // postState_G root is unique to G (consumer mutated state) → reclaimable.
            XCTAssertFalse(prevStateReachableAfter, """
            postState_G (B1's prevState) is NOT shared with B1's owned closure, yet remained
            pin-reachable after pruning G. Then it is over-retained — retention cannot reclaim
            old producer state. (This is the cutover's whole reason for dropping reference pins.)
            """)
        }

        // THE POINT: pruning the producer does NOT strand the consumer — B1 stays
        // fully validatable from its own pinned closure.
        XCTAssertTrue(strandedOwned.isEmpty && block1RootReachable,
            "consumer B1 must remain fully pin-reachable from its own pin after the producer is pruned")
    }
}
