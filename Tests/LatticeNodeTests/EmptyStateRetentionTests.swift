import XCTest
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
import UInt256
import cashew
import VolumeBroker

final class EmptyStateRetentionTests: XCTestCase {
    func testNodeInitPinsProtocolEmptyStateRoot() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let kp = CryptoUtils.generateKeyPair()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false,
            persistInterval: 10_000,
            retentionDepth: 2,
            storageMode: .stateful,
            blockRetention: .retention,
            minPeerKeyBits: 0
        )

        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        let maybeNetwork = await node.primaryNetwork
        let network = try XCTUnwrap(maybeNetwork)
        let diskBroker = await network.diskBroker
        let ownerNamespace = network.ownerNamespace
        let emptyRoot = LatticeState.emptyHeader.rawCID
        let emptyOwner = "\(ownerNamespace):empty-state"
        let hasEmptyVolume = await network.hasDurableVolume(rootCID: emptyRoot)
        let emptyReachable = await diskBroker.isPinReachable(cid: emptyRoot)
        let emptyOwners = await diskBroker.owners(root: emptyRoot)

        XCTAssertTrue(
            hasEmptyVolume,
            "empty-state seed must write the protocol root as a durable volume"
        )
        XCTAssertTrue(
            emptyReachable,
            "empty-state seed must retain the long-lived genesis/reference root"
        )
        XCTAssertTrue(
            emptyOwners.contains(emptyOwner),
            "empty-state root must be pinned under its non-height bootstrap owner"
        )

        await node.stop()
    }

    func testNodeInitDoesNotIncrementEmptyStatePinOnRestart() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let kp = CryptoUtils.generateKeyPair()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false,
            persistInterval: 10_000,
            retentionDepth: 2,
            storageMode: .stateful,
            blockRetention: .retention,
            minPeerKeyBits: 0
        )

        let first = try await LatticeNode(config: config, genesisConfig: testGenesis())
        await first.stop()

        let second = try await LatticeNode(config: config, genesisConfig: testGenesis())
        let maybeNetwork = await second.primaryNetwork
        let network = try XCTUnwrap(maybeNetwork)
        let emptyRoot = LatticeState.emptyHeader.rawCID
        let emptyOwner = "\(network.ownerNamespace):empty-state"

        try await network.unpinDurably(root: emptyRoot, owner: emptyOwner)
        let diskBroker = await network.diskBroker
        let ownersAfterSingleUnpin = await diskBroker.owners(root: emptyRoot)

        XCTAssertFalse(
            ownersAfterSingleUnpin.contains(emptyOwner),
            "empty-state seed must be idempotent; one unpin should clear the dedicated owner after a restart"
        )

        await second.stop()
    }

    func testMissingDurableRootsAllowsCreatedInternalCASEntry() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let kp = CryptoUtils.generateKeyPair()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false,
            persistInterval: 10_000,
            retentionDepth: 2,
            storageMode: .stateful,
            blockRetention: .retention,
            minPeerKeyBits: 0
        )

        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        let maybeNetwork = await node.primaryNetwork
        let network = try XCTUnwrap(maybeNetwork)
        let genesis = await node.genesisResult.block
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: now() - 9_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: await network.fetcher
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        guard await node.storeBlockData(block, network: network) != nil else {
            return XCTFail("test block must be staged durably before checking canonical roots")
        }

        let createdRoot = "bafy-created-volume-root"
        let internalCreatedCID = "bafy-created-internal-entry"
        try await network.storeVolumesDurably([
            SerializedVolume(root: createdRoot, entries: [
                createdRoot: Data("created root bytes".utf8),
                internalCreatedCID: Data("created internal bytes".utf8),
            ])
        ])

        let internalHasVolume = await network.hasDurableVolume(rootCID: internalCreatedCID)
        let internalHasCID = await network.hasCID(internalCreatedCID)

        XCTAssertFalse(
            internalHasVolume,
            "test setup requires the created CID to be an internal CAS entry, not a volume root"
        )
        XCTAssertTrue(
            internalHasCID,
            "test setup requires durable CAS bytes for the created CID"
        )

        let missing = await node.missingDurableRoots(
            block: block,
            blockHash: blockHash,
            network: network,
            stateDiff: StateDiff(replaced: [:], created: [internalCreatedCID: 1])
        )

        XCTAssertFalse(
            missing.contains(internalCreatedCID),
            "stateDiff.created CIDs are allowed to be internal CAS entries"
        )
        XCTAssertTrue(missing.isEmpty, "all canonical roots should be available; missing \(missing)")

        await node.stop()
    }
}
