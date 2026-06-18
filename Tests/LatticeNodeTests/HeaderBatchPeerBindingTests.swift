import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import Tally
import VolumeBroker

final class HeaderBatchPeerBindingTests: XCTestCase {
    func testHeaderBatchRejectsWrongPeerPenalizesAndKeepsRequestForTarget() async throws {
        let network = try await makeNetwork()
        let requestID = Data(repeating: 0x11, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let attacker = PeerID(publicKey: "attacker-peer")
        let box = HeaderBatchBox()

        let inserted = await network.registerPendingHeaderRequest(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }
        XCTAssertTrue(inserted)

        let tally = await network.ivy.tally
        for _ in 0..<10 { tally.recordSuccess(peer: attacker) }
        let reputationBefore = tally.reputation(for: attacker)

        let wrongOutcome = await network.handleHeaderBatchResponse(
            payload: headerBatchPayload(requestID: requestID, entries: [("poison", Data("bad".utf8))]),
            from: attacker
        )

        XCTAssertEqual(wrongOutcome, ChainNetwork.HeaderBatchResponseOutcome.wrongPeer)
        XCTAssertNil(box.value, "wrong-peer response must not resume the pending request")
        XCTAssertLessThan(tally.reputation(for: attacker), reputationBefore)

        let targetOutcome = await network.handleHeaderBatchResponse(
            payload: headerBatchPayload(requestID: requestID, entries: [("honest", Data("good".utf8))]),
            from: target
        )

        XCTAssertEqual(targetOutcome, ChainNetwork.HeaderBatchResponseOutcome.accepted)
        XCTAssertEqual(box.value?.count, 1)
        XCTAssertEqual(box.value?.first?.cid, "honest")
        XCTAssertEqual(box.value?.first?.data, Data("good".utf8))
    }

    func testHeaderBatchWithProofsRejectsWrongPeerPenalizesAndKeepsRequestForTarget() async throws {
        let network = try await makeNetwork()
        let requestID = Data(repeating: 0x22, count: 16)
        let target = PeerID(publicKey: "proof-target-peer")
        let attacker = PeerID(publicKey: "proof-attacker-peer")
        let box = HeaderBatchProofBox()

        let inserted = await network.registerPendingHeaderProofRequest(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }
        XCTAssertTrue(inserted)

        let tally = await network.ivy.tally
        for _ in 0..<10 { tally.recordSuccess(peer: attacker) }
        let reputationBefore = tally.reputation(for: attacker)

        let wrongOutcome = await network.handleHeaderBatchWithProofsResponse(
            payload: headerBatchWithProofsPayload(
                requestID: requestID,
                entries: [("poison", Data("bad".utf8), Data("bad-proof".utf8))]
            ),
            from: attacker
        )

        XCTAssertEqual(wrongOutcome, ChainNetwork.HeaderBatchResponseOutcome.wrongPeer)
        XCTAssertNil(box.value, "wrong-peer proof response must not resume the pending request")
        XCTAssertLessThan(tally.reputation(for: attacker), reputationBefore)

        let targetOutcome = await network.handleHeaderBatchWithProofsResponse(
            payload: headerBatchWithProofsPayload(
                requestID: requestID,
                entries: [("honest", Data("good".utf8), Data("proof".utf8))]
            ),
            from: target
        )

        XCTAssertEqual(targetOutcome, ChainNetwork.HeaderBatchResponseOutcome.accepted)
        XCTAssertEqual(box.value?.count, 1)
        XCTAssertEqual(box.value?.first?.cid, "honest")
        XCTAssertEqual(box.value?.first?.data, Data("good".utf8))
        XCTAssertEqual(box.value?.first?.proof, Data("proof".utf8))
    }

    func testDuplicateRequestIDIsNotReplacedAndUnsolicitedResponsesArePenalized() async throws {
        let network = try await makeNetwork()
        let requestID = Data(repeating: 0x33, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let duplicateTarget = PeerID(publicKey: "duplicate-peer")
        let unsolicited = PeerID(publicKey: "unsolicited-peer")
        let box = HeaderBatchBox()

        let inserted = await network.registerPendingHeaderRequest(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }
        let duplicateInserted = await network.registerPendingHeaderRequest(
            requestID: requestID,
            targetPeer: duplicateTarget
        ) { _ in XCTFail("duplicate request ID must not replace original continuation") }
        XCTAssertTrue(inserted)
        XCTAssertFalse(duplicateInserted)

        let tally = await network.ivy.tally
        for _ in 0..<10 { tally.recordSuccess(peer: unsolicited) }
        let reputationBefore = tally.reputation(for: unsolicited)

        let unsolicitedOutcome = await network.handleHeaderBatchResponse(
            payload: headerBatchPayload(requestID: Data(repeating: 0x44, count: 16)),
            from: unsolicited
        )
        XCTAssertEqual(unsolicitedOutcome, ChainNetwork.HeaderBatchResponseOutcome.unsolicited)
        XCTAssertLessThan(tally.reputation(for: unsolicited), reputationBefore)

        let targetOutcome = await network.handleHeaderBatchResponse(
            payload: headerBatchPayload(requestID: requestID, entries: [("target", Data("ok".utf8))]),
            from: target
        )
        XCTAssertEqual(targetOutcome, ChainNetwork.HeaderBatchResponseOutcome.accepted)
        XCTAssertEqual(box.value?.first?.cid, "target")
    }

    func testRequestIDCollisionRedrawsWithoutReplacingPendingContinuation() async throws {
        let network = try await makeNetwork()
        let collidingID = Data(repeating: 0x55, count: 16)
        let redrawnID = Data(repeating: 0x66, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let box = HeaderBatchBox()

        let inserted = await network.registerPendingHeaderRequest(
            requestID: collidingID,
            targetPeer: target
        ) { box.set($0) }
        XCTAssertTrue(inserted)

        let generated = await network.makeUniqueHeaderRequestID { _ in
            let draw = box.incrementRandomDraws()
            return draw == 1 ? collidingID : redrawnID
        }

        XCTAssertEqual(generated, redrawnID)
        XCTAssertEqual(box.randomDraws, 2)

        let targetOutcome = await network.handleHeaderBatchResponse(
            payload: headerBatchPayload(requestID: collidingID, entries: [("target", Data("ok".utf8))]),
            from: target
        )
        XCTAssertEqual(targetOutcome, ChainNetwork.HeaderBatchResponseOutcome.accepted)
        XCTAssertEqual(box.value?.first?.cid, "target")
    }

    private func makeNetwork() async throws -> ChainNetwork {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

    private func headerBatchPayload(
        requestID: Data,
        entries: [(cid: String, data: Data)] = []
    ) -> Data {
        var payload = requestID
        var count = UInt32(entries.count).littleEndian
        payload.append(Data(bytes: &count, count: 4))
        for entry in entries {
            let cidBytes = Data(entry.cid.utf8)
            var cidLength = UInt16(cidBytes.count).littleEndian
            payload.append(Data(bytes: &cidLength, count: 2))
            payload.append(cidBytes)
            var dataLength = UInt32(entry.data.count).littleEndian
            payload.append(Data(bytes: &dataLength, count: 4))
            payload.append(entry.data)
        }
        return payload
    }

    private func headerBatchWithProofsPayload(
        requestID: Data,
        entries: [(cid: String, data: Data, proof: Data?)] = []
    ) -> Data {
        var payload = requestID
        var count = UInt32(entries.count).littleEndian
        payload.append(Data(bytes: &count, count: 4))
        for entry in entries {
            let cidBytes = Data(entry.cid.utf8)
            var cidLength = UInt16(cidBytes.count).littleEndian
            payload.append(Data(bytes: &cidLength, count: 2))
            payload.append(cidBytes)
            var dataLength = UInt32(entry.data.count).littleEndian
            payload.append(Data(bytes: &dataLength, count: 4))
            payload.append(entry.data)
            let proof = entry.proof ?? Data()
            var proofLength = UInt32(proof.count).littleEndian
            payload.append(Data(bytes: &proofLength, count: 4))
            payload.append(proof)
        }
        return payload
    }
}

private final class HeaderBatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [(cid: String, data: Data)]?
    private var _randomDraws = 0

    var value: [(cid: String, data: Data)]? {
        lock.withLock { _value }
    }

    var randomDraws: Int {
        lock.withLock { _randomDraws }
    }

    func set(_ value: [(cid: String, data: Data)]) {
        lock.withLock { _value = value }
    }

    @discardableResult
    func incrementRandomDraws() -> Int {
        lock.withLock {
            _randomDraws += 1
            return _randomDraws
        }
    }
}

private final class HeaderBatchProofBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [(cid: String, data: Data, proof: Data?)]?

    var value: [(cid: String, data: Data, proof: Data?)]? {
        lock.withLock { _value }
    }

    func set(_ value: [(cid: String, data: Data, proof: Data?)]) {
        lock.withLock { _value = value }
    }
}
