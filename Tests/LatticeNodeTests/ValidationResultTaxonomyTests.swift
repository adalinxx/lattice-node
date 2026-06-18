import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import Ivy
import Tally
import VolumeBroker
import UInt256
import cashew

final class ValidationResultTaxonomyTests: XCTestCase {

    func testTransactionValidationErrorConsensusClass() {
        XCTAssertEqual(TransactionValidationError.invalidSignatures.consensusClass, .consensusInvalid)
        XCTAssertEqual(TransactionValidationError.feeTooLow(actual: 0, minimum: 1).consensusClass, .policy)
        XCTAssertEqual(TransactionValidationError.noStateAvailable.consensusClass, .transient)
        XCTAssertEqual(TransactionValidationError.stateResolutionFailed.consensusClass, .transient)
        XCTAssertEqual(TransactionValidationError.nonceFromFuture(nonce: 10_000).consensusClass, .missingInput)
    }

    func testMempoolAdmissionThreadsValidatorConsensusClass() async throws {
        let node = try await makeNode()

        let invalid = invalidSignatureTransaction()
        let invalidAdmission = await node.admitToMempoolAdmission(transaction: invalid, chainPath: ["Nexus"])
        XCTAssertEqual(invalidAdmission.consensusClass, .consensusInvalid)

        let lowFee = transferTransaction(fee: 0)
        let lowFeeAdmission = await node.admitToMempoolAdmission(transaction: lowFee, chainPath: ["Nexus"])
        XCTAssertEqual(lowFeeAdmission.consensusClass, .policy)

        let unfunded = transferTransaction(fee: 1)
        let unfundedAdmission = await node.admitToMempoolAdmission(transaction: unfunded, chainPath: ["Nexus"])
        XCTAssertEqual(unfundedAdmission.consensusClass, .missingInput)
    }

    func testPeerPenaltyIsOnlyRecordedForConsensusInvalidTransactionAdmission() async throws {
        let node = try await makeNode()
        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)
        await network.setDelegate(node)
        let tally = await network.ivy.tally

        let consensusPeer = PeerID(publicKey: "tx-consensus-invalid-peer")
        let consensusBefore = primeReputation(tally, peer: consensusPeer)
        await network.ingestForTesting(
            topic: "mempool-full",
            payload: try mempoolPayload(invalidSignatureTransaction()),
            from: consensusPeer
        )
        XCTAssertLessThan(tally.reputation(for: consensusPeer), consensusBefore)

        let policyPeer = PeerID(publicKey: "tx-policy-peer")
        let policyBefore = primeReputation(tally, peer: policyPeer)
        await network.ingestForTesting(
            topic: "mempool-full",
            payload: try mempoolPayload(transferTransaction(fee: 0)),
            from: policyPeer
        )
        XCTAssertEqual(tally.reputation(for: policyPeer), policyBefore, accuracy: 1e-12)

        let missingInputPeer = PeerID(publicKey: "tx-missing-input-peer")
        let missingBefore = primeReputation(tally, peer: missingInputPeer)
        await network.ingestForTesting(
            topic: "mempool-full",
            payload: try mempoolPayload(transferTransaction(fee: 1)),
            from: missingInputPeer
        )
        XCTAssertEqual(tally.reputation(for: missingInputPeer), missingBefore, accuracy: 1e-12)

        let fullNetwork = try await makeChainNetwork()
        await fullNetwork.setDelegate(FixedAdmissionDelegate(.rejectedMempoolFull))
        let fullTally = await fullNetwork.ivy.tally
        let fullPeer = PeerID(publicKey: "tx-pool-full-peer")
        let fullBefore = primeReputation(fullTally, peer: fullPeer)
        await fullNetwork.ingestForTesting(
            topic: "mempool-full",
            payload: try mempoolPayload(transferTransaction(fee: 1)),
            from: fullPeer
        )
        XCTAssertEqual(fullTally.reputation(for: fullPeer), fullBefore, accuracy: 1e-12)
    }

    func testMismatchedCIDDoesNotPrimeBlockDedupWindow() async throws {
        let node = try await makeNode()
        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)
        let genesisResult = await node.genesisResult
        let realCID = genesisResult.blockHash
        let realBlock = genesisResult.block
        let realData = try XCTUnwrap(realBlock.toData())

        let wrongBlock = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: realBlock.timestamp + 1,
            target: UInt256.max,
            fetcher: cas()
        )
        let wrongData = try XCTUnwrap(wrongBlock.toData())
        XCTAssertFalse(ChainNetwork.blockCIDMatches(realCID, block: wrongBlock))

        await node.chainNetwork(
            network,
            didReceiveBlock: realCID,
            data: wrongData,
            from: PeerID(publicKey: "cid-forger")
        )
        let recentAfterMismatch = await node.recentBlockTime(for: realCID)
        XCTAssertNil(recentAfterMismatch)

        let tally = await network.ivy.tally
        let honest = PeerID(publicKey: "valid-after-forged-cid")
        let before = primeReputation(tally, peer: honest)
        await node.chainNetwork(
            network,
            didReceiveBlock: realCID,
            data: realData,
            from: honest
        )
        XCTAssertGreaterThan(tally.reputation(for: honest), before)
    }

    func testTipAnnouncementOnlyForCanonicalPromotion() async throws {
        let node = try await makeNode()
        let networkMaybe = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkMaybe)
        await network.setDelegate(node)
        await network.resetTipPublishCountsForTesting()

        let genesis = await node.genesisResult.block
        let fetcher = await network.ivyFetcher
        let canonical = try await buildRetargetedTestBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            nonce: 1,
            fetcher: fetcher
        )
        let canonicalCID = try VolumeImpl<Block>(node: canonical).rawCID
        let canonicalData = try XCTUnwrap(canonical.toData())
        try await storeBlock(canonical, in: network)

        await node.chainNetwork(
            network,
            didReceiveBlock: canonicalCID,
            data: canonicalData,
            from: PeerID(publicKey: "canonical-block-peer")
        )

        let canonicalBroadcasts = await network.broadcastChainAnnounceCountForTesting()
        XCTAssertEqual(canonicalBroadcasts, 1)

        let chainMaybe = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainMaybe)
        let tipAfterCanonical = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterCanonical, canonicalCID)

        let sideFork = try await buildRetargetedTestBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            nonce: 2,
            fetcher: fetcher
        )
        let sideForkCID = try VolumeImpl<Block>(node: sideFork).rawCID
        let sideForkData = try XCTUnwrap(sideFork.toData())
        XCTAssertNotEqual(sideForkCID, canonicalCID)
        try await storeBlock(sideFork, in: network)

        await node.chainNetwork(
            network,
            didReceiveBlock: sideForkCID,
            data: sideForkData,
            from: PeerID(publicKey: "side-fork-peer")
        )

        let tipAfterSideFork = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterSideFork, canonicalCID)
        let sideForkBroadcasts = await network.broadcastChainAnnounceCountForTesting()
        XCTAssertEqual(sideForkBroadcasts, canonicalBroadcasts)
    }

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

    private func makeChainNetwork() async throws -> ChainNetwork {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = try DiskBroker(path: directory.appendingPathComponent("volumes.sqlite").path)
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

    private func transferTransaction(fee: UInt64) -> Transaction {
        let wallet = Wallet.create()
        return wallet.buildTransfer(
            to: Wallet.create().address,
            amount: 1,
            fee: fee,
            nonce: 0,
            chainPath: ["Nexus"]
        )!
    }

    private func invalidSignatureTransaction() -> Transaction {
        let tx = transferTransaction(fee: 1)
        return Transaction(
            signatures: [Wallet.create().publicKeyHex: "00"],
            body: tx.body
        )
    }

    private func mempoolPayload(_ tx: Transaction) throws -> Data {
        let bodyData = try XCTUnwrap(tx.body.node?.toData())
        let txData = try XCTUnwrap(tx.toData())
        return ChainNetwork.encodeMempoolFullPayload(
            cid: tx.body.rawCID,
            bodyData: bodyData,
            transactionData: txData
        )
    }

    private func storeBlock(_ block: Block, in network: ChainNetwork) async throws {
        try await storeBlockFixtureVolumes(block, in: network)
    }

    private func primeReputation(_ tally: Tally, peer: PeerID) -> Double {
        for _ in 0..<10 { tally.recordSuccess(peer: peer) }
        return tally.reputation(for: peer)
    }

}

private final class FixedAdmissionDelegate: ChainNetworkDelegate, @unchecked Sendable {
    private let admission: GossipAdmission

    init(_ admission: GossipAdmission) {
        self.admission = admission
    }

    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, height: UInt64, from peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, didReceiveChildBlock cid: String, data: Data, proofs: [ChildBlockProof], from peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> GossipAdmission {
        admission
    }
    func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, banPeer peer: PeerID) async {}
}
