import Foundation
import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import UInt256

final class LatticeNodeSyncWorkGateTests: XCTestCase {
    func testRefusesNonHeavierPeerChain() {
        let localWork = UInt256(100)

        XCTAssertFalse(LatticeNode.shouldAdmitSyncedChain(peerWork: localWork, localWork: localWork))
        XCTAssertFalse(LatticeNode.shouldAdmitSyncedChain(peerWork: UInt256(99), localWork: localWork))
    }

    func testAdmitsStrictlyHeavierPeerChain() {
        XCTAssertTrue(LatticeNode.shouldAdmitSyncedChain(peerWork: UInt256(101), localWork: UInt256(100)))
    }

    func testFreshNodeAdmitsAnyPositiveWork() {
        XCTAssertTrue(LatticeNode.shouldAdmitSyncedChain(peerWork: UInt256(1), localWork: .zero))
        XCTAssertFalse(LatticeNode.shouldAdmitSyncedChain(peerWork: .zero, localWork: .zero))
    }

    func testBridgeRefusesEqualOrLowerExactWorkWhenAvailable() {
        let exactLocalWork = UInt256(500)

        XCTAssertFalse(LatticeNode.shouldAdmitSyncedChain(peerWork: exactLocalWork, localWork: exactLocalWork))
        XCTAssertFalse(LatticeNode.shouldAdmitSyncedChain(peerWork: UInt256(499), localWork: exactLocalWork))
        XCTAssertTrue(LatticeNode.shouldAdmitSyncedChain(peerWork: UInt256(501), localWork: exactLocalWork))
    }

    func testGateComparesProvidedWorkInHandWithoutQueryingChainTip() {
        let windowedLocalWork = UInt256(75)
        let peerWorkInHand = UInt256(75)

        XCTAssertFalse(LatticeNode.shouldAdmitSyncedChain(peerWork: peerWorkInHand, localWork: windowedLocalWork))
        XCTAssertTrue(LatticeNode.shouldAdmitSyncedChain(peerWork: UInt256(76), localWork: windowedLocalWork))
    }

    /// P2/P3: the new SELF-SIMILAR per-block adopt (`adoptSyncedSegmentViaForkChoice`)
    /// must fast-forward a strictly-heavier ROOT segment through the shared
    /// `processBlockAndRecoverReorg` ingest — no bespoke admission, fork choice per
    /// block, root = the inherited-0 case. Proves the loop + fork-choice + tip
    /// adoption end-to-end on the root path.
    func testForkChoiceAdoptRootFastForwardAdopts() async throws {
        try await withSyncNode { node in
            let originalTip = await node.lattice.nexus.chain.getMainChainTip()
            let localWork = await node.localCumulativeWork(chainPath: ["Nexus"])
            let fixture = try await Self.makePeerSyncFixture(on: node, cumulativeWork: localWork + UInt256(1))
            let genesisBlock = await node.genesisResult.block
            let ivyFetcher = await fixture.network.ivyFetcher
            let resolvedTip = try await VolumeImpl<Block>(rawCID: fixture.result.tipBlockHash).resolve(fetcher: fixture.fetcher).node
            let tipBlock = try XCTUnwrap(resolvedTip, "peer tip block must resolve")
            let seg = LatticeNode.GatheredSyncSegment(
                result: fixture.result, headers: [], acceptedProofs: [:],
                parentAnchors: [:], processingRootHashes: [:], preSyncTip: nil, expectedChildPath: nil,
                localWork: localWork, sourcePeer: nil,
                materialized: LatticeNode.MaterializedSyncContent(
                    tipBlock: tipBlock, rootsByHeight: [:],
                    blocksByHeight: [genesisBlock.height: genesisBlock, tipBlock.height: tipBlock]))

            let outcome = await node.adoptSyncedSegmentViaForkChoice(seg, network: fixture.network, fetcher: ivyFetcher)

            XCTAssertEqual(outcome, .adopted(tipCID: fixture.result.tipBlockHash),
                           "a strictly-heavier root fast-forward must adopt through the per-block fork-choice loop")
            let finalTip = await node.lattice.nexus.chain.getMainChainTip()
            XCTAssertEqual(finalTip, fixture.result.tipBlockHash)
            XCTAssertNotEqual(finalTip, originalTip)
        }
    }

    private func withSyncNode(_ body: (LatticeNode) async throws -> Void) async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: keyPair.publicKey,
            privateKey: keyPair.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        do {
            try await body(node)
        } catch {
            await node.stop()
            throw error
        }
        await node.stop()
    }

    private static func makePeerSyncFixture(
        on node: LatticeNode,
        cumulativeWork: UInt256
    ) async throws -> (network: ChainNetwork, fetcher: Fetcher, result: SyncResult) {
        let maybeNetwork = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(maybeNetwork)
        let fetcher = await network.ivyFetcher
        let genesis = await node.genesisResult
        let peerBlock = try await BlockBuilder.buildBlock(
            previous: genesis.block,
            timestamp: genesis.block.timestamp + 1_000,
            target: genesis.block.nextTarget,
            fetcher: fetcher
        )
        guard await node.storeBlockData(peerBlock, network: network) != nil else {
            XCTFail("expected peer block to store recursively")
            throw SyncFixtureError.storeFailed
        }

        let peerChain = ChainState.fromGenesis(block: genesis.block)
        let peerHeader = try VolumeImpl<Block>(node: peerBlock)
        _ = await peerChain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: peerHeader, block: peerBlock)
        await peerChain.updateTipSnapshot(block: peerBlock)
        let persisted = await peerChain.persist()
        let result = SyncResult(
            persisted: persisted,
            tipBlockHash: peerHeader.rawCID,
            tipBlockHeight: peerBlock.height,
            cumulativeWork: cumulativeWork
        )
        return (network, fetcher, result)
    }

    private enum SyncFixtureError: Error {
        case storeFailed
    }
}
