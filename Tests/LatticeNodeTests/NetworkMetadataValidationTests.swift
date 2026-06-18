import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import Ivy
import Tally
import cashew
import UInt256
import VolumeBroker

final class NetworkMetadataValidationTests: XCTestCase {

    func testChainAnnounceRequiresMatchingDirectoryAndProtocol() {
        let valid = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: "bafy-spec"
        )
        XCTAssertTrue(ChainNetwork.acceptsChainAnnounce(valid, for: "Nexus"))

        let wrongDirectory = ChainAnnounceData(
            chainDirectory: "Other",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: "bafy-spec"
        )
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounce(wrongDirectory, for: "Nexus"))

        let futureProtocol = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: "bafy-spec",
            protocolVersion: LatticeProtocol.version + 1
        )
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounce(futureProtocol, for: "Nexus"))

        let emptyTip = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "",
            specCID: "bafy-spec"
        )
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounce(emptyTip, for: "Nexus"))
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounceMetadata(emptyTip))
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounceMetadata(futureProtocol))

        let emptySpec = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: ""
        )
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounce(emptySpec, for: "Nexus"))
        XCTAssertFalse(ChainNetwork.acceptsChainAnnounceMetadata(emptySpec))
    }

    func testParentExtractorValidatesParentChainAnnounce() {
        let valid = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: "bafy-spec"
        )
        XCTAssertTrue(ParentChainBlockExtractor.acceptsParentChainAnnounce(valid, parentDirectory: "Nexus"))
        XCTAssertTrue(ParentChainBlockExtractor.acceptsParentChainAnnounce(valid, parentDirectory: nil))

        let wrongParent = ChainAnnounceData(
            chainDirectory: "Other",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: "bafy-spec"
        )
        XCTAssertFalse(ParentChainBlockExtractor.acceptsParentChainAnnounce(wrongParent, parentDirectory: "Nexus"))

        let emptyTip = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "",
            specCID: "bafy-spec"
        )
        XCTAssertFalse(ParentChainBlockExtractor.acceptsParentChainAnnounce(emptyTip, parentDirectory: nil))

        let futureProtocol = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: "bafy-spec",
            protocolVersion: LatticeProtocol.version + 1
        )
        XCTAssertFalse(ParentChainBlockExtractor.acceptsParentChainAnnounce(futureProtocol, parentDirectory: nil))

        let emptySpec = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "bafy-tip",
            specCID: ""
        )
        XCTAssertFalse(ParentChainBlockExtractor.acceptsParentChainAnnounce(emptySpec, parentDirectory: nil))
    }

    func testBlockCIDMustMatchSerializedBlockData() async throws {
        let fetcher = cas()
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: now() - 10_000,
            target: .max,
            fetcher: fetcher
        )
        let data = try XCTUnwrap(block.toData())
        let cid = try VolumeImpl<Block>(node: block).rawCID

        XCTAssertTrue(ChainNetwork.blockCIDMatches(cid, block: block))
        XCTAssertTrue(ChainNetwork.blockCIDMatches(cid, data: data))
        XCTAssertFalse(ChainNetwork.blockCIDMatches("bafy-wrong-cid", data: data))
        XCTAssertFalse(ChainNetwork.blockCIDMatches(cid, data: Data("not a block".utf8)))
    }

    func testMismatchedGossipCIDIsNotStoredUnderAdvertisedRoot() async throws {
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
        let networkMaybe = await node.network(for: genesis.directory)
        let network = try XCTUnwrap(networkMaybe)
        let genesisResult = await node.genesisResult
        let data = try XCTUnwrap(genesisResult.block.toData())
        let advertisedCID = "\(genesisResult.blockHash)-wrong"

        await node.chainNetwork(
            network,
            didReceiveBlock: advertisedCID,
            data: data,
            from: PeerID(publicKey: "peer")
        )

        let storedUnderAdvertisedCID = await network.diskBroker.hasVolume(root: advertisedCID)
        XCTAssertFalse(
            storedUnderAdvertisedCID,
            "gossip data must not be stored or processed under a CID that does not match its content"
        )
    }

    func testBlockAnnouncementDoesNotRecordPeerTipBeforeValidation() async throws {
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
        let networkMaybe = await node.network(for: genesis.directory)
        let network = try XCTUnwrap(networkMaybe)
        let peer = PeerID(publicKey: "forged-announcer")

        await node.chainNetwork(
            network,
            didReceiveBlockAnnouncement: "bafyreiforgedannouncement",
            height: 10_000,
            from: peer
        )

        let chainKey = await node.chainKey(forDirectory: genesis.directory)
        let recorded = await node.knownPeerTips[chainKey]?[peer.publicKey]
        XCTAssertNil(recorded, "unresolved/unvalidated block announcements must not mutate knownPeerTips")
    }

    func testRepeatedUnvalidatedAnnouncementDoesNotRecordPeerTip() async throws {
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
        let networkMaybe = await node.network(for: genesis.directory)
        let network = try XCTUnwrap(networkMaybe)
        let peer = PeerID(publicKey: "dedup-forged-announcer")
        let forgedCID = "bafyreidedupforgedannouncement"

        await node.chainNetwork(network, didReceiveBlockAnnouncement: forgedCID, height: 10_000, from: peer)
        await node.chainNetwork(network, didReceiveBlockAnnouncement: forgedCID, height: UInt64.max, from: peer)

        let chainKey = await node.chainKey(forDirectory: genesis.directory)
        let recorded = await node.knownPeerTips[chainKey]?[peer.publicKey]
        XCTAssertNil(recorded, "deduped unvalidated block announcements must not mutate knownPeerTips")
    }

    func testAcceptedBlockAnnouncementRecordsCanonicalHeight() async throws {
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
        let networkMaybe = await node.network(for: genesis.directory)
        let network = try XCTUnwrap(networkMaybe)
        let peer = PeerID(publicKey: "inflated-height-peer")
        let genesisHash = await node.genesisResult.blockHash

        await node.chainNetwork(
            network,
            didReceiveBlockAnnouncement: genesisHash,
            height: UInt64.max,
            from: peer
        )

        let chainKey = await node.chainKey(forDirectory: genesis.directory)
        let recorded = await node.knownPeerTips[chainKey]?[peer.publicKey]
        XCTAssertEqual(recorded?.height, 0)
        XCTAssertEqual(recorded?.tipCID, genesisHash)
    }

    func testMismatchedChildGossipCIDIsNotStoredUnderAdvertisedRoot() async throws {
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
        let networkMaybe = await node.network(for: genesis.directory)
        let network = try XCTUnwrap(networkMaybe)
        let genesisResult = await node.genesisResult
        let data = try XCTUnwrap(genesisResult.block.toData())
        let advertisedCID = "\(genesisResult.blockHash)-wrong"

        await node.chainNetwork(
            network,
            didReceiveChildBlock: advertisedCID,
            data: data,
            proofs: [],
            from: PeerID(publicKey: "peer")
        )

        let storedUnderAdvertisedCID = await network.diskBroker.hasVolume(root: advertisedCID)
        XCTAssertFalse(
            storedUnderAdvertisedCID,
            "child gossip data must not be stored or processed under a CID that does not match its content"
        )
    }

    func testChildBlockDoesNotRecordPeerTipBeforePoWValidation() async throws {
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
        let networkMaybe = await node.network(for: genesis.directory)
        let network = try XCTUnwrap(networkMaybe)
        let validGenesis = await node.genesisResult.block
        let forged = Block(
            version: validGenesis.version,
            parent: validGenesis.parent,
            transactions: validGenesis.transactions,
            target: UInt256(1),
            nextTarget: validGenesis.nextTarget,
            spec: validGenesis.spec,
            parentState: validGenesis.parentState,
            prevState: validGenesis.prevState,
            postState: validGenesis.postState,
            children: validGenesis.children,
            height: validGenesis.height,
            timestamp: validGenesis.timestamp,
            nonce: validGenesis.nonce
        )
        XCTAssertFalse(forged.validateProofOfWork(nexusHash: .max))

        let cid = try VolumeImpl<Block>(node: forged).rawCID
        let data = try XCTUnwrap(forged.toData())
        let peer = PeerID(publicKey: "forged-child-peer")

        await node.chainNetwork(
            network,
            didReceiveChildBlock: cid,
            data: data,
            proofs: [],
            from: peer
        )

        let chainKey = await node.chainKey(forDirectory: genesis.directory)
        let recorded = await node.knownPeerTips[chainKey]?[peer.publicKey]
        XCTAssertNil(recorded, "child blocks must pass PoW before mutating knownPeerTips")
    }

    // `securingParentAnchors` is the live helper that records, per accepted child
    // block, the full set of distinct parent blocks that commit it (one anchor per
    // securing parent, deduped by hash). It feeds the inherited-weight anchor map,
    // so a child secured by two distinct parents must yield two anchors even when a
    // duplicate proof path is present. This is independent of the (removed) parent
    // weight projection.
    func testParentExtractorSecuringAnchorsUnionAllVerifiedParentsByHash() async throws {
        let f = cas()
        let ts = now() - 100_000
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Stable"), timestamp: ts, target: UInt256.max, fetcher: f
        )
        let child = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: ts + 1_000, target: UInt256.max, nonce: 0, fetcher: f
        )
        let parentGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Mid"), timestamp: ts, target: UInt256.max, fetcher: f
        )
        let parentA = try await BlockBuilder.buildBlock(
            previous: parentGenesis, children: ["Stable": child],
            timestamp: ts + 2_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        let parentB = try await BlockBuilder.buildBlock(
            previous: parentGenesis, children: ["Stable": child],
            timestamp: ts + 3_000, target: UInt256.max, nonce: 2, fetcher: f
        )
        try await storeBlockFixture(parentA, to: f)
        try await storeBlockFixture(parentB, to: f)

        let proofA = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: parentA), childDirectory: "Stable", fetcher: f
        )
        let proofB = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: parentB), childDirectory: "Stable", fetcher: f
        )
        let parentAHash = try VolumeImpl<Block>(node: parentA).rawCID
        let parentBHash = try VolumeImpl<Block>(node: parentB).rawCID
        let primaryMaybe = await proofA.committingParentAnchor()
        let primary = try XCTUnwrap(primaryMaybe)

        let anchors = await ParentChainBlockExtractor.securingParentAnchors(
            primary: primary,
            proofs: [proofB, proofA, proofB]
        )

        XCTAssertEqual(Set(anchors.map(\.blockHash)), Set([parentAHash, parentBHash]))
        XCTAssertEqual(anchors.count, 2, "duplicate proof paths for one parent must not hide a distinct securing parent")
    }
}
