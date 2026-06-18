import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import Tally
import UInt256
import cashew
import VolumeBroker

/// Wave-4 canonical-publish choke points: accepted-block publish/announce and
/// the post-promotion tip re-point.
final class CanonicalPublishTests: XCTestCase {

    private func makeNode() async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false,
            minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        addTeardownBlock { [node] in await node.stop() }
        return node
    }

    private func storeBlock(_ block: Block, in network: ChainNetwork) async throws {
        try await storeBlockFixtureVolumes(block, in: network)
    }

    /// W4 bug fix (announcement-resolve path): a block that arrives as an
    /// ANNOUNCEMENT (didReceiveBlockAnnouncement), resolves, and is accepted as
    /// the new canonical tip must broadcastChainAnnounce the promoted tip —
    /// exactly like the full-data gossip path (didReceiveBlock) does. Before the
    /// publishAcceptedBlock choke point this path never announced the tip, so
    /// peers that only know us had to wait for the periodic heartbeat.
    func testAnnouncementResolvePathBroadcastsPromotedTip() async throws {
        let node = try await makeNode()
        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)
        await network.resetTipPublishCountsForTesting()

        let genesis = await node.genesisResult.block
        let fetcher = await network.ivyFetcher
        let block = try await buildRetargetedTestBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            nonce: 1,
            fetcher: fetcher
        )
        let cid = try VolumeImpl<Block>(node: block).rawCID
        try await storeBlock(block, in: network)

        // height: 0 keeps the unvalidated-announcement sync gate out of the way
        // (the height is a peer hint, not part of the resolved block) so the
        // announcement proceeds to resolve + processBlockAndRecoverReorg.
        await node.chainNetwork(
            network,
            didReceiveBlockAnnouncement: cid,
            height: 0,
            from: PeerID(publicKey: "announce-peer")
        )

        let chainMaybe = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainMaybe)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, cid, "the announced block must have been accepted and promoted")

        let broadcasts = await network.broadcastChainAnnounceCountForTesting()
        XCTAssertEqual(
            broadcasts, 1,
            "announcement-resolve acceptance that promotes the tip must broadcastChainAnnounce it"
        )
    }

    /// The announcement-resolve path must NOT announce a tip when the accepted
    /// block landed as a non-canonical side fork (same promoted-only contract as
    /// the full-data gossip path).
    func testAnnouncementResolvePathDoesNotAnnounceSideFork() async throws {
        let node = try await makeNode()
        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)

        let genesis = await node.genesisResult.block
        let fetcher = await network.ivyFetcher
        let canonical = try await buildRetargetedTestBlock(
            previous: genesis, timestamp: genesis.timestamp + 1_000, nonce: 1, fetcher: fetcher
        )
        let canonicalCID = try VolumeImpl<Block>(node: canonical).rawCID
        try await storeBlock(canonical, in: network)
        await node.chainNetwork(
            network,
            didReceiveBlock: canonicalCID,
            data: try XCTUnwrap(canonical.toData()),
            from: PeerID(publicKey: "canonical-peer")
        )
        let chainMaybe = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainMaybe)
        let tipAfterCanonical = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterCanonical, canonicalCID)
        await network.resetTipPublishCountsForTesting()

        let sideFork = try await buildRetargetedTestBlock(
            previous: genesis, timestamp: genesis.timestamp + 2_000, nonce: 2, fetcher: fetcher
        )
        let sideForkCID = try VolumeImpl<Block>(node: sideFork).rawCID
        XCTAssertNotEqual(sideForkCID, canonicalCID)
        try await storeBlock(sideFork, in: network)

        await node.chainNetwork(
            network,
            didReceiveBlockAnnouncement: sideForkCID,
            height: 0,
            from: PeerID(publicKey: "side-announce-peer")
        )

        let tipAfterSideFork = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterSideFork, canonicalCID, "equal-height sibling must not displace the incumbent")
        let broadcasts = await network.broadcastChainAnnounceCountForTesting()
        XCTAssertEqual(broadcasts, 0, "a side-fork acceptance must not announce any tip")
    }

    /// W4 bug fix (tip re-point): an inherited-weight promotion flips the
    /// canonical tip through publishCanonicalTransition, bypassing the ordinary
    /// per-block apply path in processBlockAndRecoverReorg — the only place that
    /// updated the lock-free miner TipCache. The cache must re-point to the
    /// promoted tip, otherwise the block producer keeps building on the orphaned
    /// branch until the next ordinary accept.
    func testTipCacheRepointsAfterInheritedWeightPromotion() async throws {
        let node = try await makeNode()
        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)
        let chainMaybe = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainMaybe)

        let genesis = await node.genesisResult.block
        let fetcher = await network.ivyFetcher

        // Canonical block A at height 1.
        let a = try await buildRetargetedTestBlock(
            previous: genesis, timestamp: genesis.timestamp + 1_000, nonce: 1, fetcher: fetcher
        )
        let aCID = try VolumeImpl<Block>(node: a).rawCID
        try await storeBlock(a, in: network)
        await node.chainNetwork(
            network, didReceiveBlock: aCID,
            data: try XCTUnwrap(a.toData()), from: PeerID(publicKey: "peer-a")
        )
        let tipAfterA = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterA, aCID)

        // Equal-height sibling B — the tie holds the incumbent A.
        let b = try await buildRetargetedTestBlock(
            previous: genesis, timestamp: genesis.timestamp + 2_000, nonce: 2, fetcher: fetcher
        )
        let bCID = try VolumeImpl<Block>(node: b).rawCID
        XCTAssertNotEqual(bCID, aCID)
        try await storeBlock(b, in: network)
        await node.chainNetwork(
            network, didReceiveBlock: bCID,
            data: try XCTUnwrap(b.toData()), from: PeerID(publicKey: "peer-b")
        )
        let tipAfterB = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB, aCID, "equal-height sibling must not displace the incumbent")
        let bMeta = await chain.getConsensusBlock(hash: bCID)
        XCTAssertNotNil(bMeta, "sibling must be retained as a side fork")

        let key = await node.chainKey(forDirectory: "Nexus")
        let tipCacheMaybe = await node.tipCaches[key]
        let tipCache = try XCTUnwrap(tipCacheMaybe)
        XCTAssertEqual(tipCache.tip, aCID)

        // Fold verified inherited (securing) work onto B — the same path the
        // parent-chain extractor drives — so fork choice promotes it.
        let securing = workForTarget(UInt256.max) &* UInt256(100)
        let applied = await node.applyInheritedWorkContributions(
            directory: "Nexus",
            blockHash: bCID,
            contributions: [(id: "securing-parent", work: securing)],
            source: IvyContentSource(fetcher)
        )
        XCTAssertTrue(applied, "inherited-weight fold + publish must succeed")
        let tipAfterPromotion = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterPromotion, bCID, "inherited weight must promote B")

        // Durable canonical commitment re-pointed…
        let storeMaybe = await node.stateStore(for: "Nexus")
        let store = try XCTUnwrap(storeMaybe)
        XCTAssertEqual(store.getChainTip(), bCID, "durable tip must follow the promotion")
        XCTAssertEqual(store.getBlockHash(atHeight: 1), bCID, "block_index must follow the promotion")

        // …and the lock-free miner tip cache re-pointed too (the bug: it lagged
        // on the orphaned tip because only the ordinary apply path updated it).
        XCTAssertEqual(
            tipCache.tip, bCID,
            "TipCache must re-point to the inherited-weight-promoted tip"
        )
    }

    /// W4 equivalence: the Reorganization fork choice returns, converted via
    /// LatticeNode.canonicalTransition, must describe exactly the same
    /// promoted/orphaned transition the boundedReorgWalk fallback derives by
    /// re-walking the graph — the precondition for consuming the Reorganization
    /// on the common publish path instead of re-walking.
    func testReorganizationFedTransitionMatchesBoundedWalk() async throws {
        let f = cas()
        let ts = now() - 500_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(premine: 0), timestamp: ts, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let genesisCID = try VolumeImpl<Block>(node: genesis).rawCID
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: 100)

        // Build `count` blocks on top of `start`, submitting each.
        func extend(from start: Block, count: Int, baseTimestamp: Int64, nonceBase: UInt64) async throws -> [String] {
            var cids: [String] = []
            var prev = start
            for i in 1...count {
                let b = try await buildRetargetedTestBlock(
                    previous: prev,
                    timestamp: baseTimestamp + Int64(i) * 1_000,
                    nonce: nonceBase + UInt64(i),
                    fetcher: f
                )
                try await storeBlockFixture(b, to: f)
                _ = await chain.submitBlock(
                    parentBlockHeaderAndIndex: nil,
                    blockHeader: try VolumeImpl(node: b), block: b
                )
                cids.append(try VolumeImpl<Block>(node: b).rawCID)
                prev = b
            }
            return cids
        }

        // Main chain A1..A3 and an equal-length, equal-work fork B1..B3 —
        // the tie holds the incumbent A-branch.
        let aCIDs = try await extend(from: genesis, count: 3, baseTimestamp: ts, nonceBase: 0)
        let bCIDs = try await extend(from: genesis, count: 3, baseTimestamp: ts + 100, nonceBase: 10_000)
        let oldTip = await chain.getMainChainTip()
        XCTAssertEqual(oldTip, aCIDs.last, "equal-work fork must not displace the incumbent")

        // Credit the fork base verified inherited (securing) work and re-run
        // fork choice — a real multi-block reorg driven by inherited weight.
        let store = InheritedWeightStore()
        await chain.setInheritedWeightProvider(store.makeProvider())
        store.recordVerifiedWorkContributions(
            [(id: "securing-parent", work: workForTarget(UInt256.max) &* UInt256(100))],
            committingChild: bCIDs[0]
        )
        let reorgMaybe = await chain.reevaluateForkChoice(blockHash: bCIDs[0])
        let reorganization = try XCTUnwrap(reorgMaybe, "inherited weight must reorganize onto the secured fork")
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, bCIDs.last, "the whole secured fork must be promoted")

        // Walk-derived transition (the fallback path)…
        let walk = await LatticeNode.boundedReorgWalk(
            oldTip: oldTip, newTip: newTip, retentionDepth: 100
        ) { hash in
            guard let meta = await chain.getConsensusBlock(hash: hash) else { return nil }
            return LatticeNode.ReorgWalkMeta(parentBlockHash: meta.parentBlockHash, blockHeight: meta.blockHeight)
        }
        XCTAssertTrue(walk.foundCommonAncestor)

        // …vs the Reorganization-fed transition (the common path).
        let fedMaybe = await LatticeNode.canonicalTransition(from: reorganization, newTip: newTip) { hash in
            await chain.getConsensusBlock(hash: hash)?.blockHeight
        }
        let fed = try XCTUnwrap(fedMaybe, "a fresh Reorganization for the published tip must convert")

        XCTAssertTrue(fed.foundCommonAncestor)
        XCTAssertEqual(fed.promoted.map(\.hash), walk.promoted.map(\.hash))
        XCTAssertEqual(fed.promoted.map(\.height), walk.promoted.map(\.height))
        XCTAssertEqual(fed.orphaned, walk.orphaned)
        // The walk's set additionally contains the common ancestor (the fork
        // point it stopped at); the Reorganization contains exactly the blocks
        // that changed chains.
        XCTAssertEqual(fed.newChainHashes.union([genesisCID]), walk.newChainHashes)
        // Sanity on the absolute content, not just cross-agreement:
        XCTAssertEqual(fed.promoted.map(\.hash), bCIDs.reversed())
        XCTAssertEqual(fed.orphaned, aCIDs.reversed())
    }

    /// A Reorganization that does not describe the tip being published (e.g. the
    /// tip moved again under actor reentrancy) must refuse conversion so the
    /// caller falls back to the graph walk.
    func testStaleReorganizationRefusesConversion() async throws {
        let reorganization = Reorganization(
            mainChainBlocksAdded: ["b1": 1, "b2": 2],
            mainChainBlocksRemoved: ["a1", "a2"]
        )
        let fed = await LatticeNode.canonicalTransition(from: reorganization, newTip: "some-other-tip") { _ in 1 }
        XCTAssertNil(fed, "a Reorganization whose heaviest added block is not the published tip must not be consumed")

        let unresolvable = await LatticeNode.canonicalTransition(from: reorganization, newTip: "b2") { hash in
            hash.hasPrefix("a") ? nil : 1
        }
        XCTAssertNil(unresolvable, "unresolvable removed-block heights must force the walk fallback")
    }

    /// A promoted (added) block that is not hashToBlock-resolvable here — e.g. a
    /// body-pruned fork interior that Lattice's weight index still knows but the
    /// walk would refuse — must force the walk fallback, so the Reorganization
    /// path and the walk produce the identical transition (both fail closed).
    func testUnresolvablePromotedBlockForcesWalkFallback() async throws {
        let reorganization = Reorganization(
            mainChainBlocksAdded: ["b1": 1, "b2": 2],
            mainChainBlocksRemoved: ["a1"]
        )
        // b2 is the published tip and resolves; b1 (interior) does not.
        let fed = await LatticeNode.canonicalTransition(from: reorganization, newTip: "b2") { hash in
            hash == "b1" ? nil : 1
        }
        XCTAssertNil(fed, "an unresolvable promoted interior block must force the walk fallback, not publish a partial set")
    }
}
