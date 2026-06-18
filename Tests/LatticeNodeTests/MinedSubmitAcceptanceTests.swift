import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import UInt256
import cashew
import VolumeBroker

/// A VolumeBroker that fails every local store, to exercise the storage-failure
/// path (`storeBlockData` returning nil so `submitMinedBlock` aborts).
private final class FailingBroker: VolumeBroker, @unchecked Sendable {
    struct StoreFailure: Error {}
    var near: (any VolumeBroker)?
    var far: (any VolumeBroker)?
    func hasVolume(root: String) async -> Bool { false }
    func fetchVolumeLocal(root: String) async -> SerializedVolume? { nil }
    func storeVolumeLocal(_ payload: SerializedVolume) async throws { throw StoreFailure() }
    func storeVolumesLocal(_ payloads: [SerializedVolume]) async throws { throw StoreFailure() }
    func pin(root: String, owner: String, count: Int, ttl: Duration?) async throws {}
    func unpin(root: String, owner: String, count: Int) async throws {}
    func unpinAll(owner: String) async throws {}
    func owners(root: String) async -> Set<String> { [] }
    func evictUnpinned() async throws -> Int { 0 }
}

final class MinedSubmitAcceptanceTests: XCTestCase {
    private func storeTopLevelVolume<NodeType: Node>(
        _ header: VolumeImpl<NodeType>,
        into broker: MemoryBroker
    ) async throws {
        guard let node = header.node, let data = node.toData() else {
            XCTFail("expected materialized volume \(header.rawCID)")
            return
        }
        try await broker.storeVolumeLocal(SerializedVolume(root: header.rawCID, entries: [header.rawCID: data]))
    }

    private func storeTopLevelHeader<HeaderType: Header>(
        _ header: HeaderType,
        into broker: MemoryBroker
    ) async throws {
        guard let node = header.node, let data = node.toData() else {
            XCTFail("expected materialized header \(header.rawCID)")
            return
        }
        try await broker.storeVolumeLocal(SerializedVolume(root: header.rawCID, entries: [header.rawCID: data]))
    }

    func testAcceptedBlockAnnouncementsAreOnlySerializedVolumeRoots() async throws {
        let f = cas()
        let spec = testSpec()
        let timestamp = now() - 10_000

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: f
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        let roots = LatticeNode.acceptedBlockAnnouncementRoots(of: block, blockHash: blockHash)

        XCTAssertTrue(roots.contains(blockHash))
        XCTAssertTrue(roots.contains(block.spec.rawCID))
        XCTAssertTrue(roots.contains(block.postState.rawCID))
        XCTAssertTrue(roots.contains(block.prevState.rawCID))
        XCTAssertTrue(roots.contains(block.parentState.rawCID))
        // Object-grain: transactions/children are in-package HeaderImpls inside the
        // block volume, not their own volume/announce roots. Peers fetch the block
        // volume (announced via blockHash) and get them bundled in-package, so they
        // are deliberately NOT separate announce roots.
        XCTAssertFalse(
            roots.contains(block.transactions.rawCID),
            "transactions dict is in-package in the block volume, not a separate announce root"
        )
        XCTAssertFalse(
            roots.contains(block.children.rawCID),
            "children dict is in-package in the block volume, not a separate announce root"
        )
        XCTAssertEqual(Set(roots).count, roots.count, "provider roots should not be announced twice")
    }

    func testProduceAndSubmitBlockReportsAcceptedProgress() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        let accepted = await node.produceAndSubmitBlock()
        let chainMaybe = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainMaybe)
        let height = await chain.getHighestBlockHeight()

        XCTAssertTrue(accepted, "produceAndSubmitBlock must report true when submit accepts the block")
        XCTAssertEqual(height, 1)

        // The accepted block must be committed to chain storage: pinned under the
        // "<dir>:<height>" owner so it survives eviction and is served to peers.
        let networkMaybe = await node.network(for: "Nexus")
        let network = try XCTUnwrap(networkMaybe)
        let acceptedCID = await chain.getMainChainTip()
        let acceptedOwners = await network.diskBroker.owners(root: acceptedCID)
        XCTAssertTrue(
            acceptedOwners.contains("Nexus:\(height)"),
            "accepted mined block must be pinned as chain storage"
        )
    }

    // testAcceptedCompositePublishesDescendantChildBlocks was removed with the
    // in-process publishDescendantChildBlocks path: a per-process node never
    // owns local descendant child networks, so descendant candidate delivery
    // happens at submit time via the chain/submit-child-block RPC forwarders.
    // Per-process coverage: SmokeTests.

    func testSubmitMinedBlockReportsRejectedBlockAsNoProgress() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: genesis
        )
        try await node.start()
        defer { Task { await node.stop() } }

        let nexusDir = genesis.directory
        let networkMaybe = await node.network(for: nexusDir)
        let network = try XCTUnwrap(networkMaybe)
        let fetcher = await network.ivyFetcher
        let chainMaybe = await node.chain(for: nexusDir)
        let chain = try XCTUnwrap(chainMaybe)
        let tipCID = await chain.getMainChainTip()
        let resolvedTip = try await VolumeImpl<Block>(
            rawCID: tipCID,
            node: nil,
            encryptionInfo: nil
        ).resolve(fetcher: fetcher).node
        let tipBlock = try XCTUnwrap(resolvedTip)
        let heightBefore = await chain.getHighestBlockHeight()

        let backdatedBlock = try await BlockBuilder.buildBlock(
            previous: tipBlock,
            timestamp: tipBlock.timestamp - 5_000,
            target: UInt256.max,
            nonce: 9999,
            fetcher: fetcher
        )

        let accepted = await node.submitMinedBlock(directory: nexusDir, block: backdatedBlock)
        let heightAfter = await chain.getHighestBlockHeight()
        let rejectedCID = try VolumeImpl<Block>(node: backdatedBlock).rawCID
        let rejectedOwners = await network.diskBroker.owners(root: rejectedCID)

        XCTAssertFalse(accepted, "rejected mined blocks must not be reported as accepted progress")
        XCTAssertEqual(
            heightAfter,
            heightBefore,
            "rejected mined blocks must not advance chain height"
        )
        XCTAssertFalse(
            rejectedOwners.contains(nexusDir),
            "rejected mined blocks must not be advertised as the chain tip"
        )
        XCTAssertFalse(
            rejectedOwners.contains("\(nexusDir):\(backdatedBlock.height)"),
            "rejected mined candidates must not be pinned as chain storage"
        )
    }

    /// storeBlockData must report failure (nil) when the broker can't store the
    /// candidate, so submitMinedBlock aborts instead of advancing a block whose
    /// data was never durably stored.
    func testStoreBlockDataReturnsNilWhenStorageFails() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        let nexusDir = "Nexus"
        let networkMaybe = await node.network(for: nexusDir)
        let network = try XCTUnwrap(networkMaybe)
        let fetcher = await network.ivyFetcher
        let chainMaybe = await node.chain(for: nexusDir)
        let chain = try XCTUnwrap(chainMaybe)
        let tipCID = await chain.getMainChainTip()
        let resolvedTip = try await VolumeImpl<Block>(
            rawCID: tipCID, node: nil, encryptionInfo: nil
        ).resolve(fetcher: fetcher).node
        let tipBlock = try XCTUnwrap(resolvedTip)
        let block = try await BlockBuilder.buildBlock(
            previous: tipBlock,
            timestamp: tipBlock.timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )

        // Working broker: the block is stored, so we get a non-empty root set.
        let realBroker = await network.diskBroker
        let okCIDs = await node.storeBlockData(block, broker: realBroker)
        XCTAssertNotNil(okCIDs, "storeBlockData must return the stored CIDs on success")
        XCTAssertFalse(okCIDs?.isEmpty ?? true, "a stored block has at least its own CID")
        // Object-grain: transactions/children are in-package in the block volume,
        // not separate stored volume roots — but remain resolvable by CID, which the
        // resolution below proves via BrokerFetcher (content-by-CID / cas_data).
        XCTAssertFalse(okCIDs?.contains(block.transactions.rawCID) ?? true, "transactions dict is in-package, not a separate volume root")
        XCTAssertFalse(okCIDs?.contains(block.children.rawCID) ?? true, "children dict is in-package, not a separate volume root")

        let localFetcher = BrokerFetcher(broker: realBroker)
        let txVolume = VolumeImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(
            rawCID: block.transactions.rawCID,
            node: nil,
            encryptionInfo: nil
        )
        // Resolves even though transactions is in-package (content-by-CID).
        let txNode = try await txVolume.resolve(paths: [[""]: .list], fetcher: localFetcher).node
        XCTAssertEqual(try txNode?.sortedKeysAndValues().count, block.transactions.node?.count)

        // Failing broker: storage throws, so storeBlockData returns nil (the
        // signal submitMinedBlock uses to abort before validation/publish).
        let failCIDs = await node.storeBlockData(block, broker: FailingBroker())
        XCTAssertNil(failCIDs, "storeBlockData must return nil when candidate storage fails")
    }

    func testTipFrontierReadinessIsShallow() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = addr(kp.publicKey)
        let spec = testSpec()
        let genesis = testGenesis(spec: spec)
        let fetcher = cas()
        let genesisBlock = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: genesis.timestamp,
            target: genesis.target,
            fetcher: fetcher
        )
        try await storeBlockFixture(genesisBlock, to: fetcher)

        let coinbase = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(spec.rewardAtBlock(0)))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 0
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesisBlock,
            transactions: [sign(coinbase, kp)],
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )

        let broker = MemoryBroker()
        try await storeTopLevelVolume(block.postState, into: broker)
        try await storeTopLevelVolume(block.spec, into: broker)
        try await storeTopLevelHeader(block.transactions, into: broker)
        try await storeTopLevelHeader(block.children, into: broker)
        let topOnlyFetcher = BrokerFetcher(broker: broker)

        let shallowBlock = Block(
            version: block.version,
            parent: block.parent.map { Reference<Block>(rawCID: $0.rawCID) },
            transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(rawCID: block.transactions.rawCID),
            target: block.target,
            nextTarget: block.nextTarget,
            spec: VolumeImpl<ChainSpec>(rawCID: block.spec.rawCID),
            parentState: Reference<LatticeState>(rawCID: block.parentState.rawCID),
            prevState: Reference<LatticeState>(rawCID: block.prevState.rawCID),
            postState: LatticeStateHeader(rawCID: block.postState.rawCID),
            children: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>(rawCID: block.children.rawCID),
            height: block.height,
            timestamp: block.timestamp,
            nonce: block.nonce
        )

        let ready = await LatticeNode.isTipFrontierResolvable(shallowBlock, fetcher: topOnlyFetcher)
        XCTAssertTrue(
            ready,
            "startup readiness should require the tip frontier volume, not a full recursive state walk"
        )
        let recursive = try? await shallowBlock.postState.resolveRecursive(fetcher: topOnlyFetcher)
        XCTAssertNil(
            recursive?.node,
            "the fixture intentionally omits nested state volumes; a recursive readiness check would reject it"
        )
    }

    func testDurableStorageFailureDoesNotAdvanceInMemoryTip() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        let nexusDir = "Nexus"
        let networkMaybe = await node.network(for: nexusDir)
        let network = try XCTUnwrap(networkMaybe)
        let fetcher = await network.ivyFetcher
        let chainMaybe = await node.chain(for: nexusDir)
        let chain = try XCTUnwrap(chainMaybe)
        let tipBefore = await chain.getMainChainTip()
        let heightBefore = await chain.getHighestBlockHeight()
        let resolvedTipBlock = try await VolumeImpl<Block>(
            rawCID: tipBefore,
            node: nil,
            encryptionInfo: nil
        ).resolve(fetcher: fetcher).node
        let tipBlock = try XCTUnwrap(resolvedTipBlock)

        let block = try await BlockBuilder.buildBlock(
            previous: tipBlock,
            timestamp: tipBlock.timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )
        let header = try VolumeImpl<Block>(node: block)

        // Make all roots available so this exercises the durable-write gate,
        // not the missing-root fetch path.
        let realBroker = await network.diskBroker
        let storedRoots = await node.storeBlockData(block, broker: realBroker)
        XCTAssertNotNil(storedRoots)

        let isolatedBroker = MemoryBroker()
        let isolatedRoots = await node.storeBlockData(block, broker: isolatedBroker)
        XCTAssertNotNil(isolatedRoots)
        let rootSet = Set(isolatedRoots ?? [])
        for root in isolatedRoots ?? [] {
            guard let volume = await isolatedBroker.fetchVolumeLocal(root: root) else { continue }
            for cid in volume.entries.keys where cid != root && !rootSet.contains(cid) {
                let synthesizedChildVolume = await isolatedBroker.fetchVolumeLocal(root: cid)
                XCTAssertNil(synthesizedChildVolume, "storeBlockData must not synthesize child-entry volumes")
            }
        }

        let outcome = await node.processBlockAndRecoverReorg(
            header: header,
            directory: nexusDir,
            fetcher: fetcher,
            resolvedBlock: block,
            requireDurableResolvedBlock: true,
            storageBrokerOverride: FailingBroker()
        )

        guard case .storageFailed = outcome else {
            XCTFail("expected storageFailed, got \(outcome)")
            return
        }
        let tipAfter = await chain.getMainChainTip()
        let heightAfter = await chain.getHighestBlockHeight()
        let containsFailedBlock = await chain.contains(blockHash: header.rawCID)
        XCTAssertEqual(tipAfter, tipBefore)
        XCTAssertEqual(heightAfter, heightBefore)
        XCTAssertFalse(containsFailedBlock)
    }
}
