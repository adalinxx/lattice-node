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

    func testFinalizeSyncResultRefusesEqualAndLowerPeerWorkAtEntryPoint() async throws {
        try await withSyncNode { node in
            let originalTip = await node.lattice.nexus.chain.getMainChainTip()
            let localWork = await node.localCumulativeWork(chainPath: ["Nexus"])
            let fixture = try await Self.makePeerSyncFixture(on: node, cumulativeWork: localWork)

            await node.finalizeSyncResult(
                fixture.result,
                localWork: localWork,
                network: fixture.network,
                fetcher: fixture.fetcher
            )

            let equalWorkTip = await node.lattice.nexus.chain.getMainChainTip()
            let equalWorkCommitted = await Self.committedBlockHash(on: node, height: fixture.result.tipBlockHeight)
            XCTAssertEqual(equalWorkTip, originalTip)
            XCTAssertNil(equalWorkCommitted)

            let lowerWorkResult = Self.resultLike(fixture.result, cumulativeWork: .zero)
            await node.finalizeSyncResult(
                lowerWorkResult,
                localWork: localWork,
                network: fixture.network,
                fetcher: fixture.fetcher
            )

            let lowerWorkTip = await node.lattice.nexus.chain.getMainChainTip()
            let lowerWorkCommitted = await Self.committedBlockHash(on: node, height: fixture.result.tipBlockHeight)
            XCTAssertEqual(lowerWorkTip, originalTip)
            XCTAssertNil(lowerWorkCommitted)
        }
    }

    func testFinalizeSyncResultAdmitsStrictlyHeavierPeerWorkAtEntryPoint() async throws {
        try await withSyncNode { node in
            let originalTip = await node.lattice.nexus.chain.getMainChainTip()
            let localWork = await node.localCumulativeWork(chainPath: ["Nexus"])
            let fixture = try await Self.makePeerSyncFixture(on: node, cumulativeWork: localWork + UInt256(1))

            await node.finalizeSyncResult(
                fixture.result,
                localWork: localWork,
                network: fixture.network,
                fetcher: fixture.fetcher
            )

            let finalTip = await node.lattice.nexus.chain.getMainChainTip()
            let committed = await Self.committedBlockHash(on: node, height: fixture.result.tipBlockHeight)
            XCTAssertNotEqual(finalTip, originalTip)
            XCTAssertEqual(finalTip, fixture.result.tipBlockHash)
            XCTAssertEqual(committed, fixture.result.tipBlockHash)
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

    private static func resultLike(_ result: SyncResult, cumulativeWork: UInt256) -> SyncResult {
        SyncResult(
            persisted: result.persisted,
            tipBlockHash: result.tipBlockHash,
            tipBlockHeight: result.tipBlockHeight,
            cumulativeWork: cumulativeWork
        )
    }

    private static func committedBlockHash(on node: LatticeNode, height: UInt64) async -> String? {
        await node.stateStore(forPath: ["Nexus"])?.getBlockHash(atHeight: height)
    }

    private enum SyncFixtureError: Error {
        case storeFailed
    }
}
