import Crypto
import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private enum NetworkTestError: Error {
    case failedStart
    case failedSend
    case failedPhase(String)
}

private func inheritedWorkCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

private enum NetworkRuntimeStartOutcome: Equatable, Sendable {
    case started
    case failed(NodeNetworkRuntimeError)
    case unexpected(String)
}

private actor NetworkEventRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor NetworkPayloadRecorder {
    private var values: [Data] = []

    func append(_ value: Data) -> Int {
        values.append(value)
        return values.count
    }

    func snapshot() -> [Data] { values }
}

private actor RetryingNetworkPayloadRecorder {
    private var attempted: [Data] = []
    private var accepted: [Data] = []
    private var shouldRejectNext = true
    private var retryCount = 0

    func send(_ payload: Data) -> InheritedWorkPushSendResult {
        attempted.append(payload)
        guard shouldRejectNext else {
            accepted.append(payload)
            return .enqueued
        }
        shouldRejectNext = false
        return .retry
    }

    func waitForRetry() -> Bool {
        retryCount += 1
        return true
    }

    func snapshot() -> (attempted: [Data], accepted: [Data], retryCount: Int) {
        (attempted, accepted, retryCount)
    }
}

private actor InheritedSnapshotRecorder {
    private var merged = InheritedWorkSnapshot.zero
    private var count = 0

    func append(_ snapshot: InheritedWorkSnapshot) {
        merged = merged.union(snapshot)
        count += 1
    }

    func snapshot() -> (merged: InheritedWorkSnapshot, count: Int) {
        (merged, count)
    }
}

private actor ContentRequestRecorder {
    private var values: [String] = []
    func append(root: String) { values.append(root) }
    func snapshot() -> [String] { values }
}

private actor RecoveryRequestRecorder {
    private var predecessorCIDs: Set<String> = []

    func append(_ predecessorCID: String) {
        predecessorCIDs.insert(predecessorCID)
    }

    func contains(_ expected: Set<String>) -> Bool {
        predecessorCIDs.isSuperset(of: expected)
    }
}

private actor RecoveryAdmissionPlan {
    private let predecessorCID: String
    private let orphanCID: String
    private let descendantCID: String
    private var orphanAttempts = 0
    private var descendantAttempts = 0
    private var events: [String] = []

    init(
        predecessorCID: String,
        orphanCID: String,
        descendantCID: String
    ) {
        self.predecessorCID = predecessorCID
        self.orphanCID = orphanCID
        self.descendantCID = descendantCID
    }

    func admit(_ cid: String) -> NodeAdmissionOutcome {
        events.append(cid)
        let requirement: SameChainPredecessorRequirement?
        if cid == descendantCID, descendantAttempts == 0 {
            descendantAttempts += 1
            requirement = SameChainPredecessorRequirement(
                descendantCID: cid,
                predecessorCID: orphanCID
            )
        } else if cid == orphanCID, orphanAttempts == 0 {
            orphanAttempts += 1
            requirement = SameChainPredecessorRequirement(
                descendantCID: cid,
                predecessorCID: predecessorCID
            )
        } else {
            requirement = nil
        }
        let accepted = requirement == nil
        return NodeAdmissionOutcome(
            decision: accepted
                ? .acceptedSide(ChainCommit(tipHash: cid))
                : .duplicate,
            parentCarrierLink: nil,
            sameChainPredecessor: requirement
        )
    }

    func snapshot() -> [String] { events }
}

private final class RecoveryRequestPeer: IvyDelegate, Sendable {
    private let recorder: RecoveryRequestRecorder
    private let acceptedLeafCID: String

    init(recorder: RecoveryRequestRecorder, acceptedLeafCID: String) {
        self.recorder = recorder
        self.acceptedLeafCID = acceptedLeafCID
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.acceptedLeavesRequest:
            guard let request = try? AcceptedLeavesRequestMessage.decoded(
                message.payload
            ), let response = try? AcceptedLeavesResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                snapshotSequence: request.snapshotSequence ?? 1,
                blockCIDs: [acceptedLeafCID],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: response
            )
        case NodeNetworkTopic.predecessorRequest:
            guard let request = try? PredecessorRequestMessage.decoded(
                message.payload
            ), let announcement = try? BlockAnnouncementMessage(
                blockCID: request.predecessorCID
            ).encoded() else { return }
            await recorder.append(request.predecessorCID)
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: announcement
            )
        default:
            break
        }
    }
}

private actor TopicRecorder {
    private var topics: [String] = []
    func append(_ topic: String) { topics.append(topic) }
    func contains(_ topic: String) -> Bool { topics.contains(topic) }
}

private actor AuthenticatedPeerRecorder: IvyDelegate {
    private var peer: AuthenticatedPeer?

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) {
        self.peer = peer
    }

    func connectedPeer() -> AuthenticatedPeer? { peer }
}

private final class TopicRecordingPeer: IvyDelegate, Sendable {
    private let recorder: TopicRecorder

    init(recorder: TopicRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(message.topic)
    }
}

private final class TransactionTopicRecordingPeer: IvyDelegate, Sendable {
    private let recorder: TopicRecorder

    init(recorder: TopicRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(message.topic)
        guard message.topic == NodeNetworkTopic.transactionInventoryRequest,
              let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
              ), let response = try? TransactionInventoryResponseMessage(
                requestID: request.requestID,
                afterRootCID: request.afterRootCID,
                volumeRootCIDs: [],
                hasMore: false
              ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: response
        )
    }
}

private actor OverlayInventoryPeer: IvyDelegate {
    private let leaves: [String]?
    private var requestSessions: [Data] = []

    init(leaves: [String]?) {
        self.leaves = leaves
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        guard message.topic == NodeNetworkTopic.acceptedLeavesRequest,
              let request = try? AcceptedLeavesRequestMessage.decoded(
                message.payload
              ) else { return }
        requestSessions.append(peer.sessionID)
        guard let leaves,
              let payload = try? AcceptedLeavesResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                snapshotSequence: request.snapshotSequence ?? 1,
                blockCIDs: leaves,
                hasMore: false
              ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.acceptedLeavesResponse,
            payload: payload
        )
    }

    func requestCount() -> Int { requestSessions.count }
}

private struct PortableAttachmentTestPayload: Sendable {
    let summary: PortableAttachmentSummary
    let content: [String: Data]
}

private actor PortableAttachmentQueuePeer: IvyDelegate, IvyContentSource {
    private let attachments: [PortableAttachmentTestPayload]
    private let firstAdmissionGate: CandidateBuildGate
    private var servedAttachments = Set<String>()

    init(
        attachments: [PortableAttachmentTestPayload],
        firstAdmissionGate: CandidateBuildGate
    ) {
        self.attachments = attachments.sorted {
            ($0.summary.edgeCID, $0.summary.rootCID)
                < ($1.summary.edgeCID, $1.summary.rootCID)
        }
        self.firstAdmissionGate = firstAdmissionGate
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.acceptedLeavesRequest:
            guard let request = try? AcceptedLeavesRequestMessage.decoded(
                message.payload
            ), let payload = try? AcceptedLeavesResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                snapshotSequence: request.snapshotSequence ?? 1,
                blockCIDs: [],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: payload
            )
        case NodeNetworkTopic.portableAttachmentIndexRequest:
            guard let request = try? PortableAttachmentIndexRequestMessage
                .decoded(message.payload) else { return }
            let remaining = attachments.filter { attachment in
                guard let cursor = request.after else { return true }
                return (attachment.summary.edgeCID, attachment.summary.rootCID)
                    > (cursor.edgeCID, cursor.rootCID)
            }
            let page = Array(remaining.prefix(1))
            guard let payload = try? PortableAttachmentIndexResponseMessage(
                requestID: request.requestID,
                after: request.after,
                entries: page.map(\.summary),
                hasMore: remaining.count > page.count
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.portableAttachmentIndexResponse,
                payload: payload
            )
        default:
            break
        }
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard let attachment = attachments.first(where: {
            $0.summary.attachmentCID == rootCID
        }) else { return [] }
        if !servedAttachments.contains(rootCID) {
            if servedAttachments.count == 1 {
                while await firstAdmissionGate.enteredCount() == 0 {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            servedAttachments.insert(rootCID)
            if servedAttachments.count == 2 {
                await firstAdmissionGate.release(1)
            }
        }
        var remaining = maxDataBytes
        var entries: [ContentEntry] = []
        for (cid, data) in attachment.content.sorted(by: { $0.key < $1.key }) {
            guard data.count <= remaining else { return [] }
            remaining -= data.count
            entries.append(ContentEntry(cid: cid, data: data))
        }
        return entries
    }

    func servedRoots() -> Set<String> { servedAttachments }
}

private actor HierarchyRetryRecorder {
    private let withholdFirstHello: Bool
    private var evidenceIndexRequests = 0
    private var helloSessions: [Data] = []
    private var indexSessions: [Data] = []

    init(withholdFirstHello: Bool = false) {
        self.withholdFirstHello = withholdFirstHello
    }

    func record(_ topic: String, sessionID: Data) -> Bool {
        switch topic {
        case NodeNetworkTopic.hierarchyHello:
            if !helloSessions.contains(sessionID) {
                helloSessions.append(sessionID)
            }
            return withholdFirstHello && helloSessions.count == 1
        case NodeNetworkTopic.childEvidenceIndexRequest:
            evidenceIndexRequests += 1
            indexSessions.append(sessionID)
        default:
            break
        }
        return false
    }

    func sessionTrace() -> (hellos: [Data], indexes: [Data]) {
        (helloSessions, indexSessions)
    }
}

private final class HierarchyRetryPeer: IvyDelegate, Sendable {
    private let recorder: HierarchyRetryRecorder
    private let parentHello: Data
    private let summary: IssuedChildEvidenceSummary?

    init(
        recorder: HierarchyRetryRecorder,
        parentHello: Data,
        summary: IssuedChildEvidenceSummary?
    ) {
        self.recorder = recorder
        self.parentHello = parentHello
        self.summary = summary
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        let withholdHello = await recorder.record(
            message.topic,
            sessionID: peer.sessionID
        )
        switch message.topic {
        case NodeNetworkTopic.hierarchyHello:
            guard !withholdHello else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: parentHello
            )
        case NodeNetworkTopic.childEvidenceIndexRequest:
            guard let request = try? ChildEvidenceIndexRequestMessage.decoded(
                message.payload
            ), let payload = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: request.childPath,
                after: request.after,
                entries: summary.map { [$0] } ?? [],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )
        default:
            break
        }
    }
}

private struct HierarchyRetryFixture {
    let storage: URL
    let configuration: NodeConfiguration
    let runtime: NodeNetworkRuntime
    let process: ChainProcess
    let parent: Ivy
    let recorder: HierarchyRetryRecorder
    let delegate: HierarchyRetryPeer
}

private actor ChildEvidenceRecorder {
    struct Snapshot: Sendable {
        let helloSessions: [Data]
        let indexEntries: [[IssuedChildEvidenceSummary]]
        let available: [ChildEvidenceAvailableMessage]
    }

    private var nextRequestID: UInt64 = 1
    private var helloSessions: [Data] = []
    private var indexEntries: [[IssuedChildEvidenceSummary]] = []
    private var available: [ChildEvidenceAvailableMessage] = []

    func beginSession(_ sessionID: Data) -> UInt64? {
        guard !helloSessions.contains(sessionID) else { return nil }
        helloSessions.append(sessionID)
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    func record(_ response: ChildEvidenceIndexResponseMessage) {
        indexEntries.append(response.entries)
    }

    func record(_ message: ChildEvidenceAvailableMessage) {
        available.append(message)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            helloSessions: helloSessions,
            indexEntries: indexEntries,
            available: available
        )
    }
}

private final class ChildEvidencePeer: IvyDelegate, Sendable {
    private let recorder: ChildEvidenceRecorder
    private let hello: Data
    private let childPath: [String]

    init(
        recorder: ChildEvidenceRecorder,
        hello: Data,
        childPath: [String]
    ) {
        self.recorder = recorder
        self.hello = hello
        self.childPath = childPath
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.hierarchyHello:
            guard let requestID = await recorder.beginSession(peer.sessionID),
                  case .enqueued = await ivy.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.hierarchyHello,
                    payload: hello
                  ),
                  let payload = try? ChildEvidenceIndexRequestMessage(
                    requestID: requestID,
                    childPath: childPath,
                    after: nil
                  ).encoded()
            else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexRequest,
                payload: payload
            )
        case NodeNetworkTopic.childEvidenceIndexResponse:
            guard let response = try? ChildEvidenceIndexResponseMessage.decoded(
                message.payload
            ) else { return }
            await recorder.record(response)
        case NodeNetworkTopic.childEvidenceAvailable:
            guard let available = try? ChildEvidenceAvailableMessage.decoded(
                message.payload
            ) else { return }
            await recorder.record(available)
        default:
            break
        }
    }
}

private struct PendingSideCarrierFixture {
    let storage: URL
    let configuration: NodeConfiguration
    let runtime: NodeNetworkRuntime
    let process: ChainProcess
    let child: Ivy
    let childDelegate: ChildEvidencePeer
    let recorder: ChildEvidenceRecorder
    let remoteContent: NetworkTestContentStore
    let canonicalTipCID: String
    let carrierCID: String
    let childCID: String
    let childPath: [String]
}

private extension Ivy {
    func installTestDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}

private actor NetworkTestContentStore: Fetcher, Storer, VolumeStorer, IvyContentSource {
    private var values: [String: Data] = [:]
    private var volumes: [String: SerializedVolume] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = values[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func store(entries: [String: Data]) {
        values.merge(entries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        values.merge(volume.entries) { existing, _ in existing }
        volumes[volume.root] = volume
    }

    func allEntries() -> [String: Data] { values }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        var total = 0
        var entries: [ContentEntry] = []
        for cid in cids {
            guard let data = values[cid] else { return [] }
            total += data.count
            guard total <= maxDataBytes else { return [] }
            entries.append(ContentEntry(cid: cid, data: data))
        }
        return entries
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard let volume = volumes[rootCID],
              volume.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

private struct NetworkTestVolumeSource: IvyContentSource, Sendable {
    let value: SerializedVolume

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        guard rootCID == value.root,
              cids.allSatisfy({ value.entries[$0] != nil }),
              cids.reduce(0, { $0 + value.entries[$1]!.count }) <= maxDataBytes
        else { return [] }
        return cids.map { cid in
            ContentEntry(cid: cid, data: value.entries[cid]!)
        }
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard rootCID == value.root,
              value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

private struct NetworkTestVolumesSource: IvyContentSource, Sendable {
    let values: [String: SerializedVolume]

    init(_ values: [SerializedVolume]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.root, $0) })
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard let value = values[rootCID],
              value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

private actor BlockingNetworkTestVolumeSource: IvyContentSource {
    let value: SerializedVolume
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: SerializedVolume) {
        self.value = value
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard rootCID == value.root else { return [] }
        started = true
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes else {
            return []
        }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }

    func didStart() -> Bool { started }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor CandidateBuildGate {
    private var next = 0
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func enter() async -> Int {
        next += 1
        let index = next
        guard !released.contains(index) else { return index }
        await withCheckedContinuation { waiters[index] = $0 }
        return index
    }

    func enteredCount() -> Int { next }

    func release(_ index: Int) {
        released.insert(index)
        waiters.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        for index in Array(waiters.keys) { release(index) }
    }
}

private struct NetworkChildGenesisCandidate {
    let header: BlockHeader
    let package: AuthenticatedChildPackage
}

private struct NetworkHierarchyBranch {
    let rootHeader: BlockHeader
    let middle: Block
    let middleHeader: BlockHeader
    let leaf: Block
    let leafHeader: BlockHeader
}

private struct ProvisionalRootFixture {
    let parentRuntime: NodeNetworkRuntime
    let childRuntime: NodeNetworkRuntime
    let parentProcess: ChainProcess
    let childProcess: ChainProcess
    let context: ChildCandidateRequestContext
    let candidate: DirectChildCandidate
    let rootCID: String
    let nestedCID: String
    let nestedData: Data
}

private enum NetworkTransportTestPorts {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var next = UInt16(
        30_000 + ProcessInfo.processInfo.processIdentifier % 10_000
    )

    static func allocate() -> UInt16 {
        lock.withLock {
            next += 1
            return next
        }
    }
}

final class NetworkTrustTests: XCTestCase {
    private let nexusCID = "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let minimumRootWork = String(repeating: "0", count: 63) + "1"
    private static let fixtureParentWorkAuthorityKey = ParentWorkAuthorityKey(
        String(repeating: "a", count: ParentWorkAuthorityKey.encodedByteCount)
    )!

    private func overlayRuntime(
        keyByte: UInt8,
        requestTimeout: Duration,
        bootstrapPeers: [PeerEndpoint] = []
    ) async throws -> (
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-overlay-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    bootstrapPeers: bootstrapPeers,
                    requestTimeout: requestTimeout,
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let peerID = PeerID(publicKey: configuration.processPublicKey)
        return (
            runtime,
            process,
            peerID,
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ),
            try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath,
                minimumRootWorkHex: configuration.minimumRootWork.toHexString()
            ).encode()
        )
    }

    private func connectAndHello(
        _ peer: Ivy,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) async throws {
        try await peer.start()
        try await peer.connect(to: endpoint)
        for _ in 0..<100 {
            if (await peer.connectedPeers).contains(peerID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (await peer.connectedPeers).contains(peerID),
              case .enqueued = await peer.sendMessage(
                to: peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: hello
              ) else {
            throw NetworkTestError.failedStart
        }
    }

    func testChainHelloPinsNexusPathAndWorkFloor() throws {
        let hello = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"],
            minimumRootWorkHex: minimumRootWork
        )
        let decoded = try ChainHello.decode(hello.encode())
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"],
            expectedMinimumRootWorkHex: minimumRootWork
        ))

        XCTAssertThrowsError(try decoded.validateCompatibility(
            expectedNexusGenesisCID: "different-nexus",
            expectedChainPath: ["Nexus"],
            expectedMinimumRootWorkHex: minimumRootWork
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .wrongNexusGenesis)
        }

        let legacy = try JSONDecoder().decode(
            ChainHello.self,
            from: try JSONSerialization.data(withJSONObject: [
                "version": ChainHello.protocolVersion - 1,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
                "minimumRootWorkHex": minimumRootWork,
            ])
        )
        XCTAssertThrowsError(try legacy.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"],
            expectedMinimumRootWorkHex: minimumRootWork
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .incompatibleProtocol)
        }

    }

    func testChildValidationPackageEnvelopeRoundTripsAndRejectsTrailingBytes() throws {
        let package = ChildValidationPackage(
            proof: proof(),
            parentCarrierLink: try carrierLink(
                parentPath: ["Nexus"], carrierCID: "carrier", rootCID: "root"
            ),
            parentGenesisLink: try genesisLink(
                parentPath: ["Nexus"], directory: "Payments", cid: "child-genesis"
            )
        )
        let encoded = try ChildValidationPackageEnvelope(package).encode()
        let decoded = try ChildValidationPackageEnvelope.decode(encoded)
            .makeValidationPackage()

        XCTAssertEqual(try decoded.proof.serialize(), try package.proof.serialize())
        XCTAssertEqual(decoded.parentCarrierLink, package.parentCarrierLink)
        XCTAssertEqual(decoded.parentGenesisLink, package.parentGenesisLink)

        var trailing = encoded
        trailing.append(0)
        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(trailing))

        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(
            Data(repeating: 0, count: ChildValidationPackageEnvelope.maximumEncodedSize + 1)
        )) { error in
            XCTAssertEqual(error as? ChildValidationPackageEnvelopeError, .oversized)
        }
    }

    func testParentFactGateRequiresConfiguredImmediateParentAndExactEmbeddedPath() throws {
        let nexus = signingKey(31)
        let other = signingKey(32)
        let gate = try AuthenticatedParentFactGate(
            childPath: ["Nexus", "Payments"],
            configuredParentIvyPeerKey: peerKey(nexus).hex
        )
        let validEnvelope = try envelope(parentPath: ["Nexus"])

        XCTAssertNoThrow(try gate.accept(
            validEnvelope,
            from: authenticatedPeer(nexus, role: .endpoint)
        ))

        XCTAssertThrowsError(try gate.accept(
            validEnvelope,
            from: authenticatedPeer(other, role: .endpoint)
        )) { error in
            XCTAssertEqual(error as? AuthenticatedParentFactGateError, .unauthenticatedParent)
        }

        XCTAssertThrowsError(try gate.accept(
            try envelope(parentPath: ["Nexus", "Other"]),
            from: authenticatedPeer(nexus, role: .endpoint)
        )) { error in
            XCTAssertEqual(error as? AuthenticatedParentFactGateError, .wrongParentPath)
        }

        XCTAssertThrowsError(try gate.accept(
            validEnvelope,
            from: AuthenticatedPeer(
                key: peerKey(nexus),
                role: .carrier,
                route: .direct,
                metadata: PeerMetadata()
            )
        )) { error in
            XCTAssertEqual(
                error as? AuthenticatedParentFactGateError,
                .unauthenticatedParent
            )
        }
    }

    func testTwoPlanesHaveDisjointTopologyAndSharedIdentity() throws {
        let parent = signingKey(41)
        let bootstrap = signingKey(46)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-plane-test"),
            privateKeyHex: String(repeating: "2a", count: 32),
            listenPort: 4101,
            factListenPort: 4102,
            rpcPort: 8100,
            bootstrapPeers: [PeerEndpoint(
                publicKey: peerKey(bootstrap).hex,
                host: "overlay.example",
                port: 4101
            )],
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4102
            ),
            minPeerKeyBits: 17
        )
        let planes = try NodeNetworkPlaneConfigurations(configuration)

        XCTAssertEqual(planes.overlay.mode, .overlay)
        XCTAssertEqual(planes.overlay.listenPort, 4101)
        XCTAssertEqual(planes.overlay.minPeerKeyBits, 17)
        XCTAssertEqual(planes.overlay.bootstrapPeers.count, 1)
        XCTAssertTrue(planes.overlay.inboundAdmissionBypassPeerKeys.isEmpty)

        XCTAssertEqual(planes.hierarchy.mode, .privateNetwork)
        XCTAssertEqual(planes.hierarchy.listenPort, 4102)
        XCTAssertEqual(planes.hierarchy.minPeerKeyBits, 0)
        XCTAssertEqual(planes.hierarchy.bootstrapPeers, [configuration.parentEndpoint!.ivy])
        XCTAssertEqual(
            planes.hierarchy.inboundAdmissionBypassPeerKeys,
            [peerKey(parent)]
        )
        XCTAssertTrue(planes.hierarchy.stunServers.isEmpty)
        XCTAssertTrue(planes.hierarchy.carriers.isEmpty)
        XCTAssertFalse(planes.hierarchy.relayEnabled)
        XCTAssertTrue(planes.hierarchy.privateContentExchangeEnabled)
        XCTAssertEqual(planes.hierarchy.reservedOutboundConnectionSlots, 1)
        XCTAssertEqual(
            planes.hierarchy.maxConnectionsPerNetgroup,
            IvyConfig.defaultMaxConnections
        )
        XCTAssertEqual(planes.overlay.publicKey, planes.hierarchy.publicKey)
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.inheritedWorkPush),
            .hierarchy
        )

        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.blockAnnouncement),
            .overlay
        )
        XCTAssertNil(NodeNetworkTopic.plane(for: "lattice.hierarchy.coverage.v1"))
        XCTAssertNil(NodeNetworkTopic.plane(for: "lattice.hierarchy.inherited-work.v1"))
        XCTAssertNil(NodeNetworkTopic.plane(for: "unknown"))
    }

    func testRuntimeRejectsAdditionalHierarchyBootstrapPeer() throws {
        let parent = signingKey(47)
        let extra = signingKey(48)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-bootstrap-parent"),
            privateKeyHex: String(repeating: "2b", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4102
            )
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                bootstrapPeers: [
                    configuration.parentEndpoint!.ivy,
                    PeerEndpoint(
                        publicKey: peerKey(extra).hex,
                        host: "127.0.0.2",
                        port: 4102
                    ),
                ],
                inboundAdmissionBypassPeerKeys: [peerKey(parent)],
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )

        XCTAssertThrowsError(try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )) { error in
            XCTAssertEqual(
                error as? IvyModeError,
                .invalidConfiguration(
                    "hierarchy bootstrap peers must contain exactly the configured parent"
                )
            )
        }
    }

    func testNexusRuntimeRejectsHierarchyBootstrapPeer() throws {
        let extra = signingKey(49)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-bootstrap-nexus"),
            privateKeyHex: String(repeating: "2c", count: 32)
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                bootstrapPeers: [PeerEndpoint(
                    publicKey: peerKey(extra).hex,
                    host: "127.0.0.2",
                    port: 4102
                )],
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )

        XCTAssertThrowsError(try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )) { error in
            XCTAssertEqual(
                error as? IvyModeError,
                .invalidConfiguration(
                    "hierarchy bootstrap peers must contain exactly the configured parent"
                )
            )
        }
    }

    func testHierarchyHelloGrantsOnlyExactParentOrImmediateChildRole() throws {
        let parent = signingKey(43)
        let other = signingKey(44)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-hierarchy-hello-test"),
            privateKeyHex: String(repeating: "2d", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4002
            )
        )
        let work = configuration.minimumRootWork.toHexString()
        let parentHello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: ["Nexus"],
            minimumRootWorkHex: work
        )
        XCTAssertEqual(
            NodeNetworkRuntime.hierarchyRole(
                for: parentHello,
                peerKey: peerKey(parent).hex,
                configuration: configuration
            ),
            .parent
        )
        XCTAssertNil(NodeNetworkRuntime.hierarchyRole(
            for: parentHello,
            peerKey: peerKey(other).hex,
            configuration: configuration
        ))

        let childPath = ["Nexus", "Payments", "Receipts"]
        let childHello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: childPath,
            minimumRootWorkHex: work
        )
        XCTAssertEqual(
            NodeNetworkRuntime.hierarchyRole(
                for: childHello,
                peerKey: peerKey(other).hex,
                configuration: configuration
            ),
            .child(childPath)
        )
        XCTAssertNil(NodeNetworkRuntime.hierarchyRole(
            for: ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: ["Nexus", "Other", "Receipts"],
                minimumRootWorkHex: work
            ),
            peerKey: peerKey(other).hex,
            configuration: configuration
        ))
    }

    func testHierarchyHelloIsExactSessionAndOneShot() {
        let first = Data([1])
        let replacement = Data([2])

        XCTAssertFalse(NodeNetworkRuntime.hierarchyHelloMatches(
            sessionID: first,
            deadlineSessionID: replacement
        ))
        XCTAssertTrue(NodeNetworkRuntime.hierarchyHelloMatches(
            sessionID: replacement,
            deadlineSessionID: replacement
        ))
        XCTAssertFalse(NodeNetworkRuntime.hierarchyHelloMatches(
            sessionID: replacement,
            deadlineSessionID: nil
        ))
    }

    func testRootScopedContentFetchesCompleteVolumesAndKeepsAttribution() async {
        let recorder = ContentRequestRecorder()
        let servingKey = peerKey(signingKey(45)).hex
        let rootHeader = try! HeaderImpl<PublicKey>(
            node: PublicKey(key: "root-volume")
        )
        let leftHeader = try! HeaderImpl<PublicKey>(
            node: PublicKey(key: "left-volume")
        )
        let rightHeader = try! HeaderImpl<PublicKey>(
            node: PublicKey(key: "right-volume")
        )
        let rootCID = rootHeader.rawCID
        let leftCID = leftHeader.rawCID
        let rightCID = rightHeader.rawCID
        let entries = [
            rootCID: try! rootHeader.mapToData(),
            leftCID: try! leftHeader.mapToData(),
            rightCID: try! rightHeader.mapToData(),
        ]
        let source = IvyRootContentSource { root in
            await recorder.append(root: root)
            return AttributedVolumeResponse(
                rootCID: root,
                entries: entries,
                servedBy: PeerID(publicKey: servingKey)
            )
        }

        let unscoped = await source.fetch([rootCID])
        XCTAssertTrue(unscoped.isEmpty)
        let result = await source.withRootTracing(rootCID) {
            let root = await source.fetch([rootCID])
            let descendants = await source.fetch([leftCID, rightCID])
            return (root, descendants)
        }

        XCTAssertEqual(result.value.0, [rootCID: entries[rootCID]!])
        XCTAssertEqual(result.value.1, [
            leftCID: entries[leftCID]!,
            rightCID: entries[rightCID]!,
        ])
        XCTAssertEqual(result.attribution.servedByPublicKeys, [servingKey])
        XCTAssertTrue(result.attribution.allResponsesComplete)
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests, [rootCID])
    }

    func testEvidenceMergeAccumulatesCarrierAndGenesisWithoutAlternating() throws {
        let proof = proof()
        let carrier = try carrierLink(
            parentPath: ["Nexus"], carrierCID: "carrier", rootCID: "root"
        )
        let genesis = try genesisLink(
            parentPath: ["Nexus"], directory: "Payments", cid: "child-genesis"
        )
        let proofOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof
        ))
        let carrierOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof,
            parentCarrierLink: carrier
        ))
        let genesisOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof,
            parentGenesisLink: genesis
        ))

        let withCarrier = NodeNetworkRuntime.merging(proofOnly, with: carrierOnly)
        let complete = withCarrier.flatMap {
            NodeNetworkRuntime.merging($0, with: genesisOnly)
        }
        XCTAssertEqual(complete?.package.parentCarrierLink, carrier)
        XCTAssertEqual(complete?.package.parentGenesisLink, genesis)
    }

    func testEvidenceIndexPagesAreCanonicalAndCursorBound() throws {
        let summaries = [
            IssuedChildEvidenceSummary(
                childCID: inheritedWorkCID("child-a"),
                rootCID: inheritedWorkCID("root-a"),
                attachmentCID: inheritedWorkCID("attachment-a")
            ),
            IssuedChildEvidenceSummary(
                childCID: inheritedWorkCID("child-b"),
                rootCID: inheritedWorkCID("root-a"),
                attachmentCID: inheritedWorkCID("attachment-b")
            ),
            IssuedChildEvidenceSummary(
                childCID: inheritedWorkCID("child-b"),
                rootCID: inheritedWorkCID("root-b"),
                attachmentCID: inheritedWorkCID("attachment-c")
            ),
        ].sorted { ($0.childCID, $0.rootCID) < ($1.childCID, $1.rootCID) }
        let cursor = summaries[0]
        let request = ChildEvidenceIndexRequestMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor
        )
        XCTAssertEqual(
            try ChildEvidenceIndexRequestMessage.decoded(request.encoded()),
            request
        )
        let entries = Array(summaries.dropFirst())
        let response = ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor,
            entries: entries,
            hasMore: true
        )
        XCTAssertEqual(
            try ChildEvidenceIndexResponseMessage.decoded(response.encoded()),
            response
        )
        XCTAssertThrowsError(try ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor,
            entries: Array(response.entries.reversed()),
            hasMore: false
        ).encoded())
        XCTAssertThrowsError(try ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor,
            entries: [],
            hasMore: true
        ).encoded())
    }

    func testAcceptedLeafPagesAreCanonicalAndCursorBound() throws {
        let request = AcceptedLeavesRequestMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9
        )
        XCTAssertEqual(
            try AcceptedLeavesRequestMessage.decoded(request.encoded()),
            request
        )
        let fullPage = (0..<AcceptedLeavesResponseMessage.maximumLeaves).map {
            String(format: "block-b%03d", $0)
        }
        let response = AcceptedLeavesResponseMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9,
            blockCIDs: fullPage,
            hasMore: true
        )
        XCTAssertEqual(
            try AcceptedLeavesResponseMessage.decoded(response.encoded()),
            response
        )
        XCTAssertThrowsError(try AcceptedLeavesResponseMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9,
            blockCIDs: fullPage.reversed(),
            hasMore: false
        ).encoded())
        XCTAssertThrowsError(try AcceptedLeavesResponseMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9,
            blockCIDs: [],
            hasMore: true
        ).encoded())
    }

    func testContextualCandidateWireBindsCarrierRewardSubtreeAndSearchTarget() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let childReward = MiningReward(
            chainPath: ["Nexus", "Payments"],
            transaction: try unsignedTransaction(path: ["Nexus", "Payments"])
        )
        let descendantReward = MiningReward(
            chainPath: ["Nexus", "Payments", "Receipts"],
            transaction: try unsignedTransaction(
                path: ["Nexus", "Payments", "Receipts"]
            )
        )
        let request = ChildCandidateRequestMessage(
            requestID: 11,
            budgetMilliseconds: 750,
            mode: .deployment,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            parentData: parentData,
            rewards: [childReward, descendantReward]
        )
        let decodedRequest = try ChildCandidateRequestMessage.decoded(
            request.encoded()
        )
        XCTAssertEqual(decodedRequest.budgetMilliseconds, 750)
        XCTAssertEqual(decodedRequest.mode, .deployment)
        XCTAssertEqual(decodedRequest.rewards.map(\.chainPath), [
            ["Nexus", "Payments"],
            ["Nexus", "Payments", "Receipts"],
        ])
        XCTAssertNotNil(decodedRequest.rewards[0].transaction.body.node)

        let response = ChildCandidateResponseMessage(
            requestID: 11,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            childCID: parentCID,
            searchTarget: parent.target,
            deploymentTarget: parent.target,
            blockData: parentData,
            acquisitionEntries: [parentCID: parentData]
        )
        let decodedResponse = try ChildCandidateResponseMessage.decoded(
            response.encoded()
        )
        XCTAssertEqual(decodedResponse.parentCID, parentCID)
        XCTAssertEqual(decodedResponse.searchTarget, parent.target)
        XCTAssertEqual(decodedResponse.deploymentTarget, parent.target)
        XCTAssertEqual(decodedResponse.acquisitionEntries[parentCID], parentData)

        let clamped = ChildCandidateResponseMessage(
            requestID: 12,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            childCID: parentCID,
            searchTarget: parent.target / UInt256(8),
            deploymentTarget: parent.target / UInt256(4),
            blockData: parentData,
            acquisitionEntries: [parentCID: parentData]
        )
        let decodedClamped = try ChildCandidateResponseMessage.decoded(
            clamped.encoded()
        )
        XCTAssertLessThan(decodedClamped.searchTarget, parent.target)
        XCTAssertEqual(
            decodedClamped.deploymentTarget,
            parent.target / UInt256(4)
        )

        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: parent.postState,
            timestamp: 3_600_000,
            target: parent.target / UInt256(4),
            fetcher: try await canonicalNetworkProcess()
        )
        let childCID = try BlockHeader(node: child).rawCID
        let childData = try XCTUnwrap(child.toData())
        let inheritedBarrier = ChildCandidateResponseMessage(
            requestID: 13,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            childCID: childCID,
            searchTarget: parent.target / UInt256(2),
            deploymentTarget: parent.target / UInt256(2),
            blockData: childData,
            acquisitionEntries: [childCID: childData]
        )
        let decodedInherited = try ChildCandidateResponseMessage.decoded(
            inheritedBarrier.encoded()
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(decodedInherited.deploymentTarget),
            child.target
        )

        XCTAssertThrowsError(try ChildCandidateResponseMessage(
            requestID: 14,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            childCID: parentCID,
            searchTarget: parent.target,
            deploymentTarget: .zero,
            blockData: parentData,
            acquisitionEntries: [parentCID: parentData]
        ).encoded())

        XCTAssertThrowsError(try ChildCandidateRequestMessage(
            requestID: 12,
            budgetMilliseconds: 750,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            parentData: parentData,
            rewards: [MiningReward(
                chainPath: ["Nexus", "Other"],
                transaction: try unsignedTransaction(path: ["Nexus", "Other"])
            )]
        ).encoded())
    }

    func testCandidateAndEvidencePackagesRejectMissingMismatchedAndOversizedContent() async throws {
        let block = try await canonicalNetworkBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let blockData = try XCTUnwrap(block.toData())
        func candidate(_ entries: [String: Data]) -> ChildCandidateResponseMessage {
            ChildCandidateResponseMessage(
                requestID: 19,
                childPath: ["Nexus", "Payments"],
                parentCID: childCID,
                childCID: childCID,
                searchTarget: block.target,
                blockData: blockData,
                acquisitionEntries: entries
            )
        }

        XCTAssertThrowsError(try candidate([:]).encoded())
        XCTAssertThrowsError(try candidate([
            childCID: blockData + Data([0]),
        ]).encoded())
        let oversizedEntries = [
            childCID: blockData,
            "extra": Data(
                repeating: 0,
                count: ChildAcquisitionPackage.maximumBytes
            ),
        ]
        XCTAssertThrowsError(try candidate(oversizedEntries).encoded())

        XCTAssertThrowsError(try ChildEvidenceAvailableMessage(
            childPath: ["Nexus", "Payments"],
            childCID: childCID,
            rootCID: childCID,
            attachmentCID: "not-a-cid"
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
        }
    }

    func testCandidateRequestEnforcesRewardAndActualFrameBounds() async throws {
        XCTAssertEqual(
            ChildCandidateRequestMessage.maximumRewardBytes,
            ChainServiceLimits.maximumPayloadBytes
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let rewardData = try _canonicalJSONEncode([MiningReward]())
        let fixedBytes = 13 + 2
            + 2 + parentCID.utf8.count
            + 4 + rewardData.count
            + 4 + parentData.count
        let exactPath = wirePath(
            encodedContribution: ChildCandidateRequestMessage.maximumEncodedBytes
                - fixedBytes
        )
        let exact = try ChildCandidateRequestMessage(
            requestID: 15,
            budgetMilliseconds: 750,
            childPath: exactPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: []
        ).encoded()
        XCTAssertEqual(
            exact.count,
            ChildCandidateRequestMessage.maximumEncodedBytes
        )

        let oversizedPath = wirePath(
            encodedContribution: ChildCandidateRequestMessage.maximumEncodedBytes
                - fixedBytes + 1
        )
        XCTAssertThrowsError(try ChildCandidateRequestMessage(
            requestID: 16,
            budgetMilliseconds: 750,
            childPath: oversizedPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: []
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .oversized)
        }
    }

    func testCandidateSlotsGiveEveryPathOnePeerBeforeDuplicateClaims() {
        let slots = NodeNetworkRuntime.interleavedChildPeerIndices(
            peerCounts: [4] + Array(repeating: 1, count: 63),
            limit: 64
        )
        XCTAssertEqual(slots.count, 64)
        XCTAssertEqual(Set(slots.map(\.path)).count, 64)
        XCTAssertTrue(slots.allSatisfy { $0.peer == 0 })
    }

    func testCandidateInboxIsBoundedFIFOAndDeduplicated() throws {
        var inbox = CandidateInbox()
        XCTAssertTrue(inbox.enqueue("first"))
        XCTAssertTrue(inbox.enqueue("second"))
        XCTAssertTrue(inbox.enqueue("first"))
        XCTAssertEqual(try XCTUnwrap(inbox.dequeue()), "first")
        XCTAssertEqual(try XCTUnwrap(inbox.dequeue()), "second")
        XCTAssertNil(inbox.dequeue())

        for index in 0..<CandidateInbox.capacity {
            XCTAssertTrue(inbox.enqueue("cid-\(index)"))
        }
        XCTAssertFalse(inbox.enqueue("overflow"))
    }

    func testCandidateInboxReservesOneAcceptedLeafPage() {
        var inbox = CandidateInbox()
        let pageSize = AcceptedLeavesResponseMessage.maximumLeaves
        for index in 0..<(CandidateInbox.capacity - pageSize) {
            XCTAssertTrue(inbox.enqueue("cid-\(index)"))
        }
        XCTAssertTrue(inbox.reserveAcceptedLeafPage())
        XCTAssertFalse(inbox.reserveAcceptedLeafPage())
        XCTAssertFalse(inbox.enqueue("gossip-overflow"))
        inbox.releaseAcceptedLeafPage()
        XCTAssertTrue(inbox.enqueue("next"))
    }

    func testInheritedWorkFragmentsFitTheirWireBudgetAndMergeOutOfOrder() throws {
        let childA = inheritedWorkCID("child-a")
        let childB = inheritedWorkCID("child-b")
        let firstBranch = WorkMeasure(
            (0..<25).map {
                    contribution(
                        id: inheritedWorkCID("first-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }
        )
        let secondBranch = WorkMeasure(
            (0..<25).map {
                    contribution(
                        id: inheritedWorkCID("second-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }
        )
        let snapshot = InheritedWorkSnapshot(
            revision: 7,
            workByBlock: [
                childA: firstBranch,
                childB: secondBranch,
            ]
        )
        let payloads = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot,
                maximumPayloadBytes: 350
            )
        )

        XCTAssertGreaterThan(payloads.count, 1)
        var merged = InheritedWorkSnapshot.zero
        let reorderedWithDuplicate = Array(payloads.reversed()) + [
            try XCTUnwrap(payloads.first),
        ]
        for payload in reorderedWithDuplicate {
            XCTAssertLessThanOrEqual(payload.count, 350)
            let message = try InheritedWorkPushMessage.decoded(payload)
            merged = merged.union(message.snapshot)
        }
        XCTAssertEqual(merged, snapshot)
    }

    func testInheritedWorkPushRejectsEmptyOrMalformedFacts() throws {
        let child = inheritedWorkCID("child")
        let grind = inheritedWorkCID("grind")
        let alternateCID =
            "f01711220e9eb6c60800df90fc8e237ed53246f396e87579aba406aaa7976a056859ee22d"
        let canonicalCID = try XCTUnwrap(CIDIdentity.canonicalString(alternateCID))
        let emptyMeasure = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [child: .zero]
        )
        let emptyGrind = try JSONDecoder().decode(
            InheritedWorkSnapshot.self,
            from: Data(
                "{\"revision\":1,\"workByBlock\":{\"\(child)\":{\"workByGrind\":{\"\":\"0x1\"}}}}".utf8
            )
        )
        let zeroWork = try JSONDecoder().decode(
            InheritedWorkSnapshot.self,
            from: Data(
                "{\"revision\":1,\"workByBlock\":{\"\(child)\":{\"workByGrind\":{\"\(grind)\":\"0x0\"}}}}".utf8
            )
        )
        let alternateCIDSpelling = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                canonicalCID: WorkMeasure(contribution(id: alternateCID, work: 1)),
            ]
        )
        let alternateBlockCIDSpelling = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                alternateCID: WorkMeasure(contribution(id: grind, work: 1)),
            ]
        )

        for snapshot in [
            emptyMeasure,
            emptyGrind,
            zeroWork,
            alternateCIDSpelling,
            alternateBlockCIDSpelling,
        ] {
            let message = InheritedWorkPushMessage(
                snapshot: snapshot
            )
            XCTAssertThrowsError(try message.encoded()) { error in
                XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
            }
        }
        for snapshot in [alternateCIDSpelling, alternateBlockCIDSpelling] {
            let inboundPayload = try _canonicalJSONEncode(InheritedWorkPushMessage(
                snapshot: snapshot
            ))
            XCTAssertThrowsError(try InheritedWorkPushMessage.decoded(inboundPayload)) { error in
                XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
            }
        }
    }

    func testInheritedWorkStreamEndsWithAnEmptySessionCompletionMarker() throws {
        let snapshot = InheritedWorkSnapshot(
            revision: 12,
            workByBlock: [
                inheritedWorkCID("marker-child"): WorkMeasure(
                    contribution(id: inheritedWorkCID("marker-grind"), work: 7)
                ),
            ]
        )
        let payloads = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot
            )
        )
        let messages = try payloads.map(InheritedWorkPushMessage.decoded)

        XCTAssertGreaterThan(messages.count, 1)
        XCTAssertTrue(try XCTUnwrap(messages.last).snapshot.isEmpty)
        XCTAssertEqual(try XCTUnwrap(messages.last).snapshot.revision, 12)
        XCTAssertTrue(messages.dropLast().allSatisfy { !$0.snapshot.isEmpty })

        let empty = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: InheritedWorkSnapshot(revision: 13, facts: [])
            )
        )
        XCTAssertEqual(empty.count, 1)
        XCTAssertTrue(
            try InheritedWorkPushMessage.decoded(empty[0]).snapshot.isEmpty
        )
    }

    func testInheritedWorkPushRejectsMoreThanOneFactBatch() throws {
        let child = inheritedWorkCID("child")
        let snapshot = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                child: WorkMeasure((0...InheritedWorkPushMessage.maximumFacts).map {
                    contribution(
                        id: inheritedWorkCID("too-many-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }),
            ]
        )

        XCTAssertThrowsError(try InheritedWorkPushMessage(
            snapshot: snapshot
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
        }
    }

    func testParentWorkAssemblerRejectsMixedMarkerAndRollbackRevisions() {
        func fact(_ revision: UInt64, _ seed: String) -> InheritedWorkSnapshot {
            InheritedWorkSnapshot(
                revision: revision,
                workByBlock: [
                    inheritedWorkCID("work-block-\(seed)"): WorkMeasure(
                        contribution(
                            id: inheritedWorkCID("work-grind-\(seed)"),
                            work: 1
                        )
                    ),
                ]
            )
        }
        func marker(_ revision: UInt64) -> InheritedWorkSnapshot {
            InheritedWorkSnapshot(revision: revision, facts: [])
        }

        var mixed = ParentWorkAssembler(sessionID: Data([1]))
        guard case .pending? = mixed.ingest(fact(5, "first")) else {
            return XCTFail("first fragment did not start a pass")
        }
        XCTAssertNil(mixed.ingest(fact(6, "mixed")))

        var mismatchedMarker = ParentWorkAssembler(sessionID: Data([2]))
        guard case .pending? = mismatchedMarker.ingest(fact(5, "marker")) else {
            return XCTFail("fragment did not start a pass")
        }
        XCTAssertNil(mismatchedMarker.ingest(marker(4)))

        var rollback = ParentWorkAssembler(sessionID: Data([3]))
        guard case .completed? = rollback.ingest(marker(5)) else {
            return XCTFail("initial marker did not complete")
        }
        XCTAssertNil(rollback.ingest(marker(4)))
        XCTAssertNil(rollback.ingest(fact(4, "rollback")))
    }

    func testParentWorkAssemblerAllowsEqualRevisionFactDelta() {
        let revision: UInt64 = 7
        let firstBlock = inheritedWorkCID("equal-first-block")
        let firstGrind = inheritedWorkCID("equal-first-grind")
        let secondBlock = inheritedWorkCID("equal-second-block")
        let secondGrind = inheritedWorkCID("equal-second-grind")
        var assembler = ParentWorkAssembler(sessionID: Data([4]))

        let first = InheritedWorkSnapshot(
            revision: revision,
            workByBlock: [
                firstBlock: WorkMeasure(contribution(id: firstGrind, work: 1)),
            ]
        )
        guard case .pending? = assembler.ingest(first),
              case .completed(let completedFirst)? = assembler.ingest(
                InheritedWorkSnapshot(revision: revision, facts: [])
              ) else {
            return XCTFail("initial equal-revision pass did not complete")
        }
        XCTAssertEqual(completedFirst, first)

        let second = InheritedWorkSnapshot(
            revision: revision,
            workByBlock: [
                secondBlock: WorkMeasure(contribution(id: secondGrind, work: 2)),
            ]
        )
        guard case .pending? = assembler.ingest(second),
              case .completed(let completedSecond)? = assembler.ingest(
                InheritedWorkSnapshot(revision: revision, facts: [])
              ) else {
            return XCTFail("fact delta at the same revision was rejected")
        }
        XCTAssertEqual(completedSecond, second)
        XCTAssertEqual(assembler.completedRevision, revision)
    }

    func testAwaitingParentPublicBoundarySuppressesConsensusTrafficButKeepsProofs()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-stale-public-boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentKey = signingKey(0x8c)
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "8d", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parentKey).hex,
                host: "127.0.0.1",
                port: NetworkTransportTestPorts.allocate()
            )
        )
        let runtime = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        await runtime.installAdmissionHandler { _, _, _ in
            throw CancellationError()
        }

        let overlayTopics = TopicRecorder()
        let overlayPeer = Ivy(config: IvyConfig(
            signingKey: signingKey(0x8e),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await overlayPeer.installTestDelegate(TopicRecordingPeer(
            recorder: overlayTopics
        ))

        do {
            try await runtime.start(process: process)
            try await connectAndHello(
                overlayPeer,
                peerID: PeerID(publicKey: configuration.processPublicKey),
                endpoint: PeerEndpoint(
                    publicKey: configuration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: configuration.chainPath,
                    minimumRootWorkHex:
                        configuration.minimumRootWork.toHexString()
                ).encode()
            )
            for _ in 0..<100 {
                if await overlayTopics.contains(
                    NodeNetworkTopic.acceptedLeavesRequest
                ) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let tip = try await canonicalNetworkBlock()
            let tipCID = try BlockHeader(node: tip).rawCID
            try await runtime.announceBlock(tipCID)
            let candidates = await runtime.directChildCandidates(
                ChildCandidateRequestContext(parentCarrier: tip, rewards: [])
            )
            XCTAssertTrue(candidates.isEmpty)

            let proof = ChildBlockProof(
                rootCID: "historical-proof-root",
                directoryPath: ["Payments", "Leaf"],
                entries: []
            )
            let published = try await runtime.publishChildProof(
                proof,
                childDirectory: "Leaf",
                child: tip
            )
            XCTAssertEqual(try published.serialize(), try proof.serialize())

            try await Task.sleep(for: .milliseconds(100))
            let announcedStaleBlock = await overlayTopics.contains(
                NodeNetworkTopic.blockAnnouncement
            )
            XCTAssertFalse(announcedStaleBlock)
        } catch {
            await overlayPeer.stop()
            await runtime.stop()
            throw error
        }
        await overlayPeer.stop()
        await runtime.stop()
    }

    func testInheritedWorkStreamerStopsAtTheFirstRejectedFrame() async throws {
        let child = inheritedWorkCID("child")
        let snapshot = InheritedWorkSnapshot(
            revision: 9,
            workByBlock: [
                child: WorkMeasure((0..<48).map {
                    contribution(
                        id: inheritedWorkCID("stream-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }),
            ]
        )
        let recorder = NetworkPayloadRecorder()
        let completed = await NodeNetworkRuntime.streamInheritedWorkPushPayloads(
            snapshot: snapshot,
            maximumPayloadBytes: 350
        ) { payload in
            let count = await recorder.append(payload)
            return count < 2 ? .enqueued : .stopped
        } waitForRetry: {
            false
        }

        XCTAssertFalse(completed)
        let attempted = await recorder.snapshot()
        XCTAssertEqual(attempted.count, 2)
        XCTAssertTrue(attempted.allSatisfy { $0.count <= 350 })
        let allFrames = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot,
                maximumPayloadBytes: 350
            )
        )
        XCTAssertGreaterThan(allFrames.count, attempted.count)
        XCTAssertEqual(attempted, Array(allFrames.prefix(attempted.count)))
    }

    func testInheritedWorkStreamerRetriesTheRejectedFrameInOrder() async throws {
        let child = inheritedWorkCID("child")
        let snapshot = InheritedWorkSnapshot(
            revision: 10,
            workByBlock: [
                child: WorkMeasure((0..<48).map {
                    contribution(
                        id: inheritedWorkCID("retry-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }),
            ]
        )
        let recorder = RetryingNetworkPayloadRecorder()
        let completed = await NodeNetworkRuntime.streamInheritedWorkPushPayloads(
            snapshot: snapshot,
            maximumPayloadBytes: 350,
            send: { payload in
                await recorder.send(payload)
            },
            waitForRetry: {
                await recorder.waitForRetry()
            }
        )

        XCTAssertTrue(completed)
        let recorded = await recorder.snapshot()
        let allFrames = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot,
                maximumPayloadBytes: 350
            )
        )
        XCTAssertGreaterThan(allFrames.count, 1)
        XCTAssertEqual(recorded.retryCount, 1)
        XCTAssertEqual(recorded.attempted.count, allFrames.count + 1)
        XCTAssertEqual(recorded.attempted[0], recorded.attempted[1])
        XCTAssertEqual(recorded.accepted, allFrames)
    }

    func testInheritedWorkSplitsAtTheFactBatchBoundary() throws {
        let child = inheritedWorkCID("child")
        let snapshot = InheritedWorkSnapshot(
            revision: 3,
            workByBlock: [
                child: WorkMeasure((0...256).map {
                    contribution(
                        id: inheritedWorkCID("batch-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }),
            ]
        )
        let payloads = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot
            )
        )

        XCTAssertGreaterThanOrEqual(payloads.count, 2)
        var merged = InheritedWorkSnapshot.zero
        for payload in payloads {
            merged = merged.union(
                try InheritedWorkPushMessage.decoded(payload).snapshot
            )
        }
        XCTAssertEqual(merged, snapshot)
    }

    func testInheritedWorkPackerStreamsHighCardinalityBlockExactly() throws {
        // One block with many grinds is the hostile shape for a packer that
        // rebuilds a measure once per fact.
        let child = inheritedWorkCID("child")
        let snapshot = InheritedWorkSnapshot(
            revision: 4,
            workByBlock: [
                child: WorkMeasure((0..<1_024).map {
                    contribution(
                        id: inheritedWorkCID("wide-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }),
            ]
        )

        let first = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot
            )
        )
        let second = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: snapshot
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 4)
        let merged = try first.reduce(into: InheritedWorkSnapshot.zero) {
            $0 = $0.union(try InheritedWorkPushMessage.decoded($1).snapshot)
        }
        XCTAssertEqual(merged, snapshot)
    }

    func testProofPreparationRotatesAcrossMoreThanSixtyFourChildPaths() {
        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: 0,
            limit: 64
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: first.next,
            limit: 64
        )
        XCTAssertEqual(first.indices.count, 64)
        XCTAssertFalse(first.indices.contains(64))
        XCTAssertTrue(second.indices.contains(64))
        XCTAssertFalse(second.indices.contains(0))
    }

    func testDisconnectedChildPathsCannotAccumulatePeerRotationState() {
        var rotations = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("Nexus/stale-\($0)", $0)
        })
        rotations["Nexus/active"] = 3
        NodeNetworkRuntime.pruneChildPeerRotations(
            &rotations,
            activeRoles: [.child(["Nexus", "active"])]
        )
        XCTAssertEqual(rotations, ["Nexus/active": 3])
    }

    func testCandidateBudgetsShrinkAndPeerPriorityRotates() {
        let childBudget = NodeNetworkRuntime.remoteChildCandidateBudget(
            parentWaitMilliseconds: 1_000
        )
        let grandchildBudget = childBudget.flatMap {
            NodeNetworkRuntime.remoteChildCandidateBudget(
                parentWaitMilliseconds: UInt64($0)
            )
        }
        XCTAssertEqual(childBudget, 750)
        XCTAssertEqual(grandchildBudget, 563)

        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 3,
            start: 0,
            limit: 2
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 3,
            start: first.next,
            limit: 2
        )
        XCTAssertEqual(first.indices, [0, 1])
        XCTAssertEqual(second.indices, [1, 2])
    }

    func testEvidenceAvailabilityCarriesOneCompleteVolumeRoot() async throws {
        let process = try await canonicalNetworkProcess()
        let block = try await process.canonicalTipBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let entries = try await process.durableCandidateEntries(for: block)
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof())
        )
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope.encode(),
            acquisitionEntries: entries,
            childCID: childCID
        )
        let response = ChildEvidenceAvailableMessage(
            childPath: ["Nexus", "Payments"],
            childCID: childCID,
            rootCID: childCID,
            attachmentCID: attachment.rawCID
        )
        let decoded = try ChildEvidenceAvailableMessage.decoded(response.encoded())
        XCTAssertEqual(decoded.attachmentCID, attachment.rawCID)
        let attached = NodeNetworkRuntime.attachingEvidenceContent(
            acquisitionEntries: entries,
            to: AuthenticatedChildPackage(
                package: try envelope.makeValidationPackage()
            )
        )
        XCTAssertEqual(attached?.acquisitionEntries, entries)

        let extraTransaction = try unsignedTransaction(path: ["Nexus"])
        let extraBody = try XCTUnwrap(extraTransaction.body.node)
        let extraCID = extraTransaction.body.rawCID
        var expanded = entries
        expanded[extraCID] = try XCTUnwrap(extraBody.toData())
        let expandedAttachment = NodeNetworkRuntime.attachingEvidenceContent(
            acquisitionEntries: expanded,
            to: AuthenticatedChildPackage(
                package: try envelope.makeValidationPackage()
            )
        )
        XCTAssertEqual(expandedAttachment?.acquisitionEntries, expanded)

        var mismatched = entries
        mismatched[childCID]?.append(0)
        do {
            _ = try await BlockHeader(
                rawCID: childCID,
                node: nil,
                encryptionInfo: nil
            ).resolveBlockContent(source: InMemoryContentSource(mismatched))
            XCTFail("accessed mismatched content must fail CID verification")
        } catch {}
    }

    func testPolicyChildBootstrapsFromRestartedParentPackageWithoutOverlay() async throws {
        let source = NetworkTestContentStore()
        let parentAuthority = try XCTUnwrap(ParentWorkAuthorityKey(
            peerKey(signingKey(0x6a)).hex
        ))
        try await LatticeState.emptyHeader.storeRecursively(
            storer: source as any Storer
        )
        let module = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0, 0, 0]))
        )
        try await module.storeRecursively(storer: source as any Storer)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .transaction
        )
        let base = NexusGenesis.spec
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock:
                base.maxNumberOfTransactionsPerBlock,
            maxStateGrowth: base.maxStateGrowth,
            maxBlockSize: base.maxBlockSize,
            premine: 0,
            targetBlockTime: base.targetBlockTime,
            initialReward: base.initialReward,
            halvingInterval: base.halvingInterval,
            retargetWindow: base.retargetWindow,
            wasmPolicies: [policy],
            parentWorkAuthorityKey: parentAuthority
        )
        let child = try await BlockBuilder.buildChildGenesis(
            spec: spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let childHeader = try BlockHeader(node: child)
        let childData: Data = try XCTUnwrap(child.toData())
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source as any Storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        let collector = NetworkTestContentStore()
        try await childHeader.storeBlock(fetcher: source, storer: collector)
        let authoredEntries = await collector.allEntries()
        XCTAssertNotNil(authoredEntries[policy.moduleCID])

        let candidateWire = try ChildCandidateResponseMessage(
            requestID: 91,
            childPath: ["Nexus", "Payments"],
            parentCID: carrierHeader.rawCID,
            childCID: childHeader.rawCID,
            searchTarget: child.target,
            blockData: childData,
            acquisitionEntries: authoredEntries
        ).encoded()
        let candidate = try ChildCandidateResponseMessage.decoded(candidateWire)
        XCTAssertEqual(candidate.acquisitionEntries[policy.moduleCID],
                       authoredEntries[policy.moduleCID])

        let parentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-parent-package-\(UUID().uuidString)")
        let childDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-package-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: parentDirectory)
            try? FileManager.default.removeItem(at: childDirectory)
        }
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        let parentConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: parentDirectory,
            privateKeyHex: String(repeating: "6a", count: 32)
        )
        var parentStore: NodeStore? = try testNodeStore(
            databasePath: parentDirectory.appendingPathComponent("state.db"),
            nexusGenesisCID: parentConfiguration.nexusGenesisCID,
            chainPath: parentConfiguration.chainPath,
            minimumRootWork: parentConfiguration.minimumRootWork,
            issuingAuthorityKey: parentConfiguration.processPublicKey
        )
        let carrierLink = try carrierLink(
            parentPath: ["Nexus"],
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let genesisLink = try genesisLink(
            parentPath: ["Nexus"],
            directory: "Payments",
            cid: childHeader.rawCID,
            parentWorkAuthorityKey: parentAuthority
        )
        try await parentStore!.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Payments",
                child: child,
                proof: proof,
                acquisitionEntries: candidate.acquisitionEntries
            )],
            capacity: 16
        )
        try await parentStore!.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: carrierLink,
                carrierEvidence: nil,
                parentGenesisLinks: [genesisLink]
            )
        )
        parentStore = nil

        let parent = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let recoveredEvidence = try await parent.issuedChildEvidence(
            childCID: childHeader.rawCID,
            directory: "Payments",
            rootCID: carrierHeader.rawCID
        )
        let recovered = try XCTUnwrap(recoveredEvidence)
        XCTAssertEqual(recovered.acquisitionEntries[policy.moduleCID],
                       authoredEntries[policy.moduleCID])
        let summaries = try await parent.issuedChildEvidenceSummaries(
            directory: "Payments",
            after: nil,
            limit: 2
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.childCID, childHeader.rawCID)
        XCTAssertEqual(summaries.first?.rootCID, carrierHeader.rawCID)
        XCTAssertTrue(summaries.first.map {
            CIDIdentity.isCanonical($0.attachmentCID)
        } ?? false)
        XCTAssertEqual(recovered.parentCarrierLink, carrierLink)
        XCTAssertEqual(recovered.parentGenesisLink, genesisLink)
        XCTAssertNotNil(recovered.parentCarrierCertificate)
        XCTAssertNotNil(recovered.parentGenesisCertificate)
        let childProcess = try await ChainProcess.open(configuration:
            NodeConfiguration(
                chainPath: ["Nexus", "Payments"],
                minimumRootWork: UInt256(1),
                storagePath: childDirectory,
                privateKeyHex: String(repeating: "6b", count: 32),
                parentEndpoint: ParentEndpoint(
                    publicKey: parentConfiguration.processPublicKey,
                    host: "127.0.0.1",
                    port: 4002
                )
            )
        )
        let outcome = try await childProcess.admit(
            BlockHeader(
                rawCID: childHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            authenticatedChildPackage: AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: recovered.proof,
                    parentCarrierLink: recovered.parentCarrierLink,
                    parentGenesisLink: recovered.parentGenesisLink
                ),
                acquisitionEntries: recovered.acquisitionEntries,
                parentCarrierCertificate: recovered.parentCarrierCertificate,
                parentGenesisCertificate: recovered.parentGenesisCertificate
            )
        )
        XCTAssertTrue(outcome.decision.isAccepted)
        let childStatus = await childProcess.status()
        XCTAssertEqual(childStatus.phase, .active)
    }

    func testPortableAttachmentsKeepDistinctRootsForTheSameChildWhileAdmissionIsBlocked()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-portable-root-queue-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let rootKey = signingKey(0x73)
        let rootAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(peerKey(rootKey).hex)
        )
        let middleConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Middle"],
            minimumRootWork: UInt256(1),
            storagePath: storage.appendingPathComponent("middle"),
            privateKeyHex: String(repeating: "74", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: rootAuthority.value,
                host: "127.0.0.1",
                port: NetworkTransportTestPorts.allocate()
            )
        )
        let middleAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(middleConfiguration.processPublicKey)
        )
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let parentPort = NetworkTransportTestPorts.allocate()
        let targetConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Middle", "Leaf"],
            minimumRootWork: UInt256(1),
            storagePath: storage.appendingPathComponent("target"),
            privateKeyHex: String(repeating: "75", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: middleAuthority.value,
                host: "127.0.0.1",
                port: parentPort
            )
        )

        let content = NetworkTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: content as any Storer
        )
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(middleAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let leafHeader = try BlockHeader(node: leaf)
        let middle = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(rootAuthority),
            parentState: LatticeState.emptyHeader,
            children: ["Leaf": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let middleHeader = try BlockHeader(node: middle)
        let leafHop = try await ChildBlockProof.generate(
            rootHeader: middleHeader,
            childDirectory: "Leaf",
            fetcher: content
        )
        var proofs: [ChildBlockProof] = []
        for timestamp in [Int64(3), Int64(4)] {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Middle": middle],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content as any Storer)
            proofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "Middle",
                fetcher: content
            ).composing(hop: leafHop))
        }
        var edges: [DirectChildEdge] = []
        for proof in proofs {
            let edge = await DirectChildEdge.derive(from: proof)
            edges.append(try XCTUnwrap(edge))
        }
        XCTAssertEqual(Set(edges.compactMap(\.edgeCID)).count, 1)
        XCTAssertEqual(Set(proofs.map(\.rootCID)).count, 2)

        let leafContent = NetworkTestContentStore()
        try await leafHeader.storeBlock(fetcher: content, storer: leafContent)
        let acquisitionEntries = await leafContent.allEntries()
        let genesisLink = try genesisLink(
            parentPath: ["Nexus", "Middle"],
            directory: "Leaf",
            cid: leafHeader.rawCID,
            parentWorkAuthorityKey: middleAuthority
        )
        var attachments: [PortableAttachmentTestPayload] = []
        for (proof, edge) in zip(proofs, edges) {
            let carrierLink = try carrierLink(
                parentPath: ["Nexus", "Middle"],
                carrierCID: middleHeader.rawCID,
                rootCID: proof.rootCID
            )
            let package = ChildValidationPackage(
                proof: proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: genesisLink
            )
            let envelope = try ChildValidationPackageEnvelope(
                package,
                certificatesSignedBy: middleConfiguration
            )
            let attachment = try ChildEvidenceVolume(
                envelopeBytes: try envelope.encode(),
                acquisitionEntries: acquisitionEntries,
                childCID: leafHeader.rawCID
            )
            let attachmentBroker = MemoryBroker()
            try await attachment.store(
                storer: BrokerStorer(broker: attachmentBroker)
            )
            let fetchedAttachment = await attachmentBroker.fetchVolumeLocal(
                root: attachment.rawCID
            )
            let attachmentVolume = try XCTUnwrap(fetchedAttachment)
            XCTAssertEqual(attachmentVolume.root, attachment.serialized.root)
            XCTAssertEqual(attachmentVolume.entries, attachment.serialized.entries)
            attachments.append(PortableAttachmentTestPayload(
                summary: PortableAttachmentSummary(
                    edgeCID: try XCTUnwrap(edge.edgeCID),
                    rootCID: proof.rootCID,
                    attachmentCID: attachment.rawCID
                ),
                content: attachment.serialized.entries
            ))
        }
        let parentPeerKey = try PeerKey(middleAuthority.value)
        let runtime = try NodeNetworkRuntime(
            configuration: targetConfiguration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: targetConfiguration.signingKey,
                    listenPort: overlayPort,
                    requestTimeout: .seconds(1),
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: targetConfiguration.signingKey,
                    listenPort: hierarchyPort,
                    bootstrapPeers: [PeerEndpoint(
                        publicKey: middleAuthority.value,
                        host: "127.0.0.1",
                        port: targetConfiguration.parentEndpoint!.port
                    )],
                    inboundAdmissionBypassPeerKeys: [parentPeerKey],
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    maxConnections: IvyConfig.defaultMaxConnections,
                    reservedOutboundConnectionSlots: 1,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    privateContentExchangeEnabled: true,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: targetConfiguration,
            remoteSource: runtime.remoteContentSource
        )
        let roots = NetworkEventRecorder()
        let firstAdmissionGate = CandidateBuildGate()
        await runtime.installAdmissionHandler { header, package, _ in
            guard let rootCID = package?.package.proof.rootCID else {
                throw NetworkTestError.failedPhase("missing portable root")
            }
            await roots.append(rootCID)
            if (await roots.snapshot()).count == 1 {
                _ = await firstAdmissionGate.enter()
            }
            return NodeAdmissionOutcome(
                decision: .acceptedSide(ChainCommit(tipHash: header.rawCID)),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }

        let peer = Ivy(config: IvyConfig(
            signingKey: signingKey(0x76),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let delegate = PortableAttachmentQueuePeer(
            attachments: attachments,
            firstAdmissionGate: firstAdmissionGate
        )
        await peer.installTestDelegate(delegate)
        await peer.setContentSource(delegate)
        let parent = Ivy(config: IvyConfig(
            signingKey: middleConfiguration.signingKey,
            listenPort: parentPort,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .privateNetwork
        ))
        let readiness = NetworkEventRecorder()
        await runtime.installParentReadinessHandler { ready in
            await readiness.append(ready ? "ready" : "not-ready")
        }
        do {
            try await parent.start()
            try await runtime.start(process: process)
            let childPeer = PeerID(publicKey: targetConfiguration.processPublicKey)
            for _ in 0..<100 {
                if (await parent.connectedPeers).contains(childPeer) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let hierarchyHello = try ChainHello(
                nexusGenesisCID: targetConfiguration.nexusGenesisCID,
                chainPath: middleConfiguration.chainPath,
                minimumRootWorkHex:
                    targetConfiguration.minimumRootWork.toHexString()
            ).encode()
            guard (await parent.connectedPeers).contains(childPeer),
                  case .enqueued = await parent.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.hierarchyHello,
                    payload: hierarchyHello
                  ) else {
                throw NetworkTestError.failedStart
            }
            guard
                  case .enqueued = await parent.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.inheritedWorkPush,
                    payload: try InheritedWorkPushMessage(
                        snapshot: InheritedWorkSnapshot(revision: 1, facts: [])
                    ).encoded()
                  )
            else {
                throw NetworkTestError.failedStart
            }
            for _ in 0..<100 {
                if (await readiness.snapshot()).contains("ready") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard (await readiness.snapshot()).contains("ready") else {
                throw NetworkTestError.failedPhase("parent readiness")
            }
            try await connectAndHello(
                peer,
                peerID: PeerID(publicKey: targetConfiguration.processPublicKey),
                endpoint: PeerEndpoint(
                    publicKey: targetConfiguration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: targetConfiguration.nexusGenesisCID,
                    chainPath: targetConfiguration.chainPath,
                    minimumRootWorkHex:
                        targetConfiguration.minimumRootWork.toHexString()
                ).encode()
            )
            for _ in 0..<300 {
                if (await roots.snapshot()).count == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let admittedRoots = await roots.snapshot()
            let servedRoots = await delegate.servedRoots()
            XCTAssertEqual(
                servedRoots,
                Set(attachments.map(\.summary.attachmentCID))
            )
            XCTAssertEqual(admittedRoots.count, 2)
            XCTAssertEqual(Set(admittedRoots), Set(proofs.map(\.rootCID)))
        } catch {
            await firstAdmissionGate.releaseAll()
            await peer.stop()
            await parent.stop()
            await runtime.stop()
            throw error
        }
        await firstAdmissionGate.releaseAll()
        await peer.stop()
        await parent.stop()
        await runtime.stop()
    }

    func testCanonicalNetworkMessagesRejectAlternateEncodings() throws {
        let message = BlockAnnouncementMessage(blockCID: "candidate")
        let encoded = try message.encoded()
        XCTAssertEqual(try BlockAnnouncementMessage.decoded(encoded), message)

        var padded = encoded
        padded.append(0x20)
        XCTAssertThrowsError(try BlockAnnouncementMessage.decoded(padded)) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testTransactionInventoryWireIsCanonicalAndCursorBound() throws {
        let available = TransactionAvailableMessage(volumeRootCID: "volume")
        XCTAssertEqual(
            try TransactionAvailableMessage.decoded(available.encoded()),
            available
        )

        let request = TransactionInventoryRequestMessage(
            requestID: 1,
            afterRootCID: "b"
        )
        XCTAssertEqual(
            try TransactionInventoryRequestMessage.decoded(request.encoded()),
            request
        )
        XCTAssertThrowsError(try TransactionInventoryRequestMessage(
            requestID: 0,
            afterRootCID: nil
        ).encoded())

        let valid = TransactionInventoryResponseMessage(
            requestID: 1,
            afterRootCID: "b",
            volumeRootCIDs: ["c", "d"],
            hasMore: false
        )
        XCTAssertEqual(
            try TransactionInventoryResponseMessage.decoded(valid.encoded()),
            valid
        )
        let fullPage = (0..<TransactionInventoryResponseMessage.maximumRoots)
            .map { String(format: "r%02d", $0) }
        XCTAssertNoThrow(try TransactionInventoryResponseMessage(
            requestID: 1,
            afterRootCID: nil,
            volumeRootCIDs: fullPage,
            hasMore: true
        ).encoded())
        for invalid in [
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: "b",
                volumeRootCIDs: ["d", "c"],
                hasMore: false
            ),
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: "b",
                volumeRootCIDs: ["b"],
                hasMore: false
            ),
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: nil,
                volumeRootCIDs: ["c"],
                hasMore: true
            ),
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: nil,
                volumeRootCIDs: fullPage + ["z"],
                hasMore: false
            ),
        ] {
            XCTAssertThrowsError(try invalid.encoded())
        }

        var padded = try valid.encoded()
        padded.append(0x20)
        XCTAssertThrowsError(
            try TransactionInventoryResponseMessage.decoded(padded)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testRealIvyFetchesCompleteVolumeFromExactAuthenticatedSession()
        async throws
    {
        let transaction = try signedNetworkTransaction(chainPath: ["Nexus"])
        let volume = try await transactionVolume(transaction)
        let serverKey = signingKey(0x9e)
        let serverPort = NetworkTransportTestPorts.allocate()
        let server = Ivy(config: IvyConfig(
            signingKey: serverKey,
            listenPort: serverPort,
            stunServers: [],
            mode: .overlay
        ))
        await server.setContentSource(NetworkTestVolumeSource(value: volume))
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0x9f),
            listenPort: 0,
            requestTimeout: .seconds(1),
            stunServers: [],
            mode: .overlay
        ))
        let recorder = AuthenticatedPeerRecorder()
        await client.installTestDelegate(recorder)

        do {
            try await server.start()
            try await client.start()
            try await client.connect(to: PeerEndpoint(
                publicKey: peerKey(serverKey).hex,
                host: "127.0.0.1",
                port: serverPort
            ))
            let peer: AuthenticatedPeer
            for _ in 0..<200 {
                if let connected = await recorder.connectedPeer() {
                    peer = connected
                    let response = await client.fetchVolume(
                        rootCID: volume.root,
                        from: peer
                    )
                    XCTAssertEqual(response.rootCID, volume.root)
                    XCTAssertEqual(response.entries, volume.entries)
                    XCTAssertEqual(response.servedBy, peer.id)
                    await client.stop()
                    await server.stop()
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NetworkTestError.failedStart
        } catch {
            await client.stop()
            await server.stop()
            throw error
        }
    }

    func testTransactionAnnouncementUsesExactAdvertiserAndRejectsInvalidVolume()
        async throws
    {
        let target = try await overlayRuntime(
            keyByte: 0xa1,
            requestTimeout: .milliseconds(150)
        )
        let service = networkService(
            process: target.process,
            runtime: target.runtime
        )
        let transactionAttempts = NetworkEventRecorder()
        await installTransactionService(
            service,
            on: target.runtime,
            transactions: transactionAttempts
        )

        let valid = try signedNetworkTransaction(chainPath: ["Nexus"])
        let validVolume = try await transactionVolume(valid)
        let invalid = try signedNetworkTransaction(
            chainPath: ["Nexus", "Other"]
        )
        let invalidVolume = try await transactionVolume(invalid)
        let observerTopics = TopicRecorder()
        let observer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa2),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let observerDelegate = TransactionTopicRecordingPeer(
            recorder: observerTopics
        )
        await observer.installTestDelegate(observerDelegate)
        await observer.setContentSource(NetworkTestVolumeSource(
            value: validVolume
        ))

        let advertiserTopics = TopicRecorder()
        let advertiser = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa3),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let advertiserDelegate = TransactionTopicRecordingPeer(
            recorder: advertiserTopics
        )
        await advertiser.installTestDelegate(advertiserDelegate)
        await advertiser.setContentSource(NetworkTestVolumeSource(
            value: invalidVolume
        ))
        let unavailableTopics = TopicRecorder()
        let unavailable = Ivy(config: IvyConfig(
            signingKey: signingKey(0xaa),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let unavailableDelegate = TransactionTopicRecordingPeer(
            recorder: unavailableTopics
        )
        await unavailable.installTestDelegate(unavailableDelegate)

        do {
            try await target.runtime.start(process: target.process)
            try await connectAndHello(
                observer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: observerTopics
            )
            try await connectAndHello(
                advertiser,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: advertiserTopics
            )
            guard case .enqueued = await advertiser.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: invalidVolume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await Task.sleep(for: .milliseconds(300))

            let invalidStatus = await service.status()
            let relayedInvalid = await observerTopics.contains(
                NodeNetworkTopic.transactionAvailable
            )
            XCTAssertEqual(invalidStatus.mempoolCount, 0)
            XCTAssertFalse(relayedInvalid)

            await advertiser.stop()
            try await connectAndHello(
                unavailable,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: unavailableTopics
            )

            guard case .enqueued = await unavailable.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: validVolume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await Task.sleep(for: .milliseconds(300))

            let unavailableStatus = await service.status()
            let relayedUnavailable = await observerTopics.contains(
                NodeNetworkTopic.transactionAvailable
            )
            XCTAssertEqual(unavailableStatus.mempoolCount, 0)
            XCTAssertFalse(relayedUnavailable)

            let extra = try HeaderImpl<PublicKey>(
                node: PublicKey(key: "unrelated-volume-member")
            )
            var bloatedEntries = validVolume.entries
            bloatedEntries[extra.rawCID] = try extra.mapToData()
            let bloated = SerializedVolume(
                root: validVolume.root,
                entries: bloatedEntries
            )
            try bloated.validate()
            await observer.setContentSource(NetworkTestVolumeSource(
                value: bloated
            ))
            let attemptsBefore = await transactionAttempts.snapshot().count
            guard case .enqueued = await observer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: validVolume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await waitForEventCount(
                attemptsBefore + 1,
                in: transactionAttempts
            )
            try await waitForMempoolCount(1, service: service)

            let normalized = await target.process.volume(validVolume.root)
            XCTAssertNotNil(normalized)
            XCTAssertNil(normalized?.entries[extra.rawCID])
        } catch {
            await unavailable.stop()
            await advertiser.stop()
            await observer.stop()
            await target.runtime.stop()
            throw error
        }
        await unavailable.stop()
        await advertiser.stop()
        await observer.stop()
        await target.runtime.stop()
    }

    func testSameChainTransactionRelaysAndLateJoinerRecoversFromPeerInventory()
        async throws
    {
        let first = try await overlayRuntime(
            keyByte: 0xa4,
            requestTimeout: .seconds(15)
        )
        let second = try await overlayRuntime(
            keyByte: 0xa5,
            requestTimeout: .seconds(15),
            bootstrapPeers: [first.endpoint]
        )
        let firstService = networkService(
            process: first.process,
            runtime: first.runtime
        )
        let secondService = networkService(
            process: second.process,
            runtime: second.runtime
        )
        let firstInventoryRequests = NetworkEventRecorder()
        let secondInventoryRequests = NetworkEventRecorder()
        let secondTransactions = NetworkEventRecorder()
        await installTransactionService(
            firstService,
            on: first.runtime,
            inventoryRequests: firstInventoryRequests
        )
        await installTransactionService(
            secondService,
            on: second.runtime,
            inventoryRequests: secondInventoryRequests,
            transactions: secondTransactions
        )
        let publicationTopics = TopicRecorder()
        let publicationDelegate = TopicRecordingPeer(recorder: publicationTopics)
        let publicationObserver = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa7),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await publicationObserver.installTestDelegate(publicationDelegate)

        var late: (
            runtime: NodeNetworkRuntime,
            process: ChainProcess,
            peerID: PeerID,
            endpoint: PeerEndpoint,
            hello: Data
        )?
        do {
            try await first.runtime.start(process: first.process)
            try await connectAndHello(
                publicationObserver,
                peerID: first.peerID,
                endpoint: first.endpoint,
                hello: first.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: publicationTopics
            )

            let transaction = try signedNetworkTransaction(
                chainPath: ["Nexus"]
            )
            let submitted = try await firstService.submitTransaction(
                SubmitTransactionRequest(transaction: transaction)
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionAvailable,
                in: publicationTopics
            )
            try await second.runtime.start(process: second.process)
            try await waitForEvent(
                in: secondInventoryRequests,
                phase: "second inventory handshake"
            )
            try await waitForEvent(
                in: firstInventoryRequests,
                phase: "first inventory response"
            )
            try await waitForEvent(
                in: secondTransactions,
                phase: "second transaction handler",
                attempts: 2_000
            )
            try await waitForMempoolCount(
                1,
                service: secondService,
                phase: "second peer direct relay"
            )
            let secondInventory = await secondService.transactionInventoryRoots()
            XCTAssertEqual(
                secondInventory,
                [submitted.transactionCID]
            )

            // The original submitter disappears, and the receiving runtime
            // restarts. A late joiner must recover the complete Volume from
            // that peer's ordinary inventory, not from the original source.
            await first.runtime.stop()
            await second.runtime.stop()
            try await second.runtime.start(process: second.process)

            let joined = try await overlayRuntime(
                keyByte: 0xa6,
                requestTimeout: .seconds(15),
                bootstrapPeers: [second.endpoint]
            )
            late = joined
            let lateService = networkService(
                process: joined.process,
                runtime: joined.runtime
            )
            await installTransactionService(lateService, on: joined.runtime)
            try await joined.runtime.start(process: joined.process)
            try await waitForMempoolCount(
                1,
                service: lateService,
                phase: "late join inventory"
            )

            let lateInventory = await lateService.transactionInventoryRoots()
            let retainedVolume = await joined.process.volume(
                submitted.transactionCID
            )
            XCTAssertEqual(lateInventory, [submitted.transactionCID])
            XCTAssertNotNil(retainedVolume)
        } catch {
            if let late { await late.runtime.stop() }
            await publicationObserver.stop()
            await second.runtime.stop()
            await first.runtime.stop()
            throw error
        }
        if let late { await late.runtime.stop() }
        await publicationObserver.stop()
        await second.runtime.stop()
        await first.runtime.stop()
    }

    func testTransactionFetchDoesNotBlockSameSessionIngress() async throws {
        let target = try await overlayRuntime(
            keyByte: 0xa8,
            requestTimeout: .seconds(2)
        )
        let service = networkService(process: target.process, runtime: target.runtime)
        let transactions = NetworkEventRecorder()
        let inventoryRequests = NetworkEventRecorder()
        await installTransactionService(
            service,
            on: target.runtime,
            inventoryRequests: inventoryRequests,
            transactions: transactions
        )
        let transaction = try signedNetworkTransaction(chainPath: ["Nexus"])
        let volume = try await transactionVolume(transaction)
        let source = BlockingNetworkTestVolumeSource(value: volume)
        let topics = TopicRecorder()
        let advertiser = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa9),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let advertiserDelegate = TransactionTopicRecordingPeer(recorder: topics)
        await advertiser.installTestDelegate(advertiserDelegate)
        await advertiser.setContentSource(source)

        do {
            try await target.runtime.start(process: target.process)
            try await connectAndHello(
                advertiser,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            guard case .enqueued = await advertiser.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: volume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            for _ in 0..<200 {
                if await source.didStart() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let didStart = await source.didStart()
            XCTAssertTrue(didStart)

            guard case .enqueued = await advertiser.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionInventoryRequest,
                payload: try TransactionInventoryRequestMessage(
                    requestID: 99,
                    afterRootCID: nil
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await waitForEventCount(
                1,
                in: inventoryRequests,
                phase: "concurrent transaction inventory request"
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryResponse,
                in: topics
            )
            let attempts = await transactions.snapshot()
            XCTAssertTrue(attempts.isEmpty)

            await source.release()
            try await waitForMempoolCount(1, service: service)
        } catch {
            await source.release()
            await advertiser.stop()
            await target.runtime.stop()
            throw error
        }
        await advertiser.stop()
        await target.runtime.stop()
    }

    func testPlaneLifecycleStartsPrivateFirstAndStopsInReverse() async throws {
        let success = NetworkEventRecorder()
        try await NodeNetworkRuntime.startPlanes(
            startHierarchy: { await success.append("start-hierarchy") },
            startOverlay: { await success.append("start-overlay") },
            stopOverlay: { await success.append("stop-overlay") },
            stopHierarchy: { await success.append("stop-hierarchy") }
        )
        await NodeNetworkRuntime.stopPlanes(
            stopOverlay: { await success.append("stop-overlay") },
            stopHierarchy: { await success.append("stop-hierarchy") }
        )
        let successEvents = await success.snapshot()
        XCTAssertEqual(successEvents, [
            "start-hierarchy", "start-overlay", "stop-overlay", "stop-hierarchy",
        ])

        let failure = NetworkEventRecorder()
        do {
            try await NodeNetworkRuntime.startPlanes(
                startHierarchy: { await failure.append("start-hierarchy") },
                startOverlay: {
                    await failure.append("start-overlay")
                    throw NetworkTestError.failedStart
                },
                stopOverlay: { await failure.append("stop-overlay") },
                stopHierarchy: { await failure.append("stop-hierarchy") }
            )
            XCTFail("expected overlay start failure")
        } catch NetworkTestError.failedStart {}
        let failureEvents = await failure.snapshot()
        XCTAssertEqual(failureEvents, [
            "start-hierarchy", "start-overlay", "stop-overlay", "stop-hierarchy",
        ])
    }

    func testRealIvyApplicationMessageReachesAsyncRuntimeDelegate() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-delegate-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5d", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: rpcPort
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: hierarchyPort,
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let candidateVolume = try await canonicalNetworkBlockVolumes(count: 1)[0]
        let candidateCID = candidateVolume.root
        let admissions = NetworkEventRecorder()
        let delivered = expectation(
            description: "real Ivy application message reaches runtime delegate"
        )
        await runtime.installAdmissionHandler { header, _, _ in
            await admissions.append(header.rawCID)
            delivered.fulfill()
            return NodeAdmissionOutcome(
                decision: .duplicate,
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(94),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.setContentSource(NetworkTestVolumeSource(
            value: candidateVolume
        ))
        do {
            try await runtime.start(process: process)
            try await client.start()
            let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
            try await client.connect(to: PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ))
            let hello = try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath,
                minimumRootWorkHex: configuration.minimumRootWork.toHexString()
            ).encode()
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.overlayHello,
                payload: hello
            ) else {
                throw NetworkTestError.failedSend
            }
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(blockCID: candidateCID).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }

            await fulfillment(of: [delivered], timeout: 2)
            let recordedAdmissions = await admissions.snapshot()
            XCTAssertEqual(recordedAdmissions, [candidateCID])
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    func testAcceptedLeafSyncRotatesPastSilentOverlayPeer() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x75,
            requestTimeout: .milliseconds(150)
        )
        let admitted = NetworkEventRecorder()
        await fixture.runtime.installAdmissionHandler { header, _, _ in
            await admitted.append(header.rawCID)
            return NodeAdmissionOutcome(
                decision: .acceptedSide(ChainCommit(tipHash: header.rawCID)),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }

        let silentDelegate = OverlayInventoryPeer(leaves: nil)
        let silent = Ivy(config: IvyConfig(
            signingKey: signingKey(0x76),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await silent.installTestDelegate(silentDelegate)
        let honestVolume = try await canonicalNetworkBlockVolumes(count: 1)[0]
        let honestCID = honestVolume.root
        let honestDelegate = OverlayInventoryPeer(leaves: [honestCID])
        let honest = Ivy(config: IvyConfig(
            signingKey: signingKey(0x77),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honest.installTestDelegate(honestDelegate)
        await honest.setContentSource(NetworkTestVolumeSource(
            value: honestVolume
        ))

        do {
            try await fixture.runtime.start(process: fixture.process)
            try await connectAndHello(
                silent,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await silentDelegate.requestCount() >= 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentRequests = await silentDelegate.requestCount()
            XCTAssertGreaterThanOrEqual(silentRequests, 1)

            try await connectAndHello(
                honest,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<200 {
                if (await admitted.snapshot()).contains(honestCID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let honestRequests = await honestDelegate.requestCount()
            let admittedCIDs = await admitted.snapshot()
            XCTAssertGreaterThanOrEqual(honestRequests, 1)
            XCTAssertEqual(admittedCIDs, [honestCID])
        } catch {
            await honest.stop()
            await silent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await honest.stop()
        await silent.stop()
        await fixture.runtime.stop()
    }

    func testLocalAdmissionFailureDoesNotPunishReplacementSession()
        async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x78,
            requestTimeout: .milliseconds(300)
        )
        let volumes = try await canonicalNetworkBlockVolumes(count: 3)
        let stalledCID = volumes[0].root
        let replacementCID = volumes[1].root
        let honestCID = volumes[2].root
        let gate = CandidateBuildGate()
        let admitted = NetworkEventRecorder()
        await fixture.runtime.installAdmissionHandler { header, _, _ in
            await admitted.append(header.rawCID)
            if header.rawCID == stalledCID {
                _ = await gate.enter()
                throw NetworkTestError.failedPhase("stalled acquisition")
            }
            return NodeAdmissionOutcome(
                decision: .acceptedSide(ChainCommit(tipHash: header.rawCID)),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }

        let attackerKey = signingKey(0x79)
        let firstDelegate = OverlayInventoryPeer(leaves: [])
        let first = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await first.installTestDelegate(firstDelegate)
        await first.setContentSource(NetworkTestVolumeSource(value: volumes[0]))
        let replacementDelegate = OverlayInventoryPeer(leaves: [replacementCID])
        let replacement = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await replacement.installTestDelegate(replacementDelegate)
        await replacement.setContentSource(NetworkTestVolumeSource(value: volumes[1]))
        let honestDelegate = OverlayInventoryPeer(leaves: [honestCID])
        let honest = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7a),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honest.installTestDelegate(honestDelegate)
        await honest.setContentSource(NetworkTestVolumeSource(value: volumes[2]))

        do {
            try await fixture.runtime.start(process: fixture.process)
            try await connectAndHello(
                first,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await firstDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let firstRequests = await firstDelegate.requestCount()
            XCTAssertEqual(firstRequests, 1)
            guard case .enqueued = await first.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: stalledCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<100 {
                if await gate.enteredCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let stalledAdmissions = await gate.enteredCount()
            XCTAssertEqual(stalledAdmissions, 1)

            await first.stop()
            try await connectAndHello(
                replacement,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await replacementDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let replacementRequests = await replacementDelegate.requestCount()
            XCTAssertEqual(replacementRequests, 1)
            try await connectAndHello(
                honest,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await honestDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let honestRequests = await honestDelegate.requestCount()
            XCTAssertEqual(honestRequests, 1)

            await gate.release(1)
            for _ in 0..<200 {
                let admittedCIDs = await admitted.snapshot()
                if admittedCIDs.contains(replacementCID),
                   admittedCIDs.contains(honestCID) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let replacementConnected = await replacement.connectedPeers
                .contains(fixture.peerID)
            let admittedCIDs = await admitted.snapshot()
            XCTAssertTrue(replacementConnected)
            XCTAssertEqual(admittedCIDs.first, stalledCID)
            XCTAssertTrue(admittedCIDs.contains(honestCID))
            XCTAssertTrue(admittedCIDs.contains(replacementCID))
        } catch {
            await gate.releaseAll()
            await honest.stop()
            await replacement.stop()
            await first.stop()
            await fixture.runtime.stop()
            throw error
        }
        await gate.releaseAll()
        await honest.stop()
        await replacement.stop()
        await first.stop()
        await fixture.runtime.stop()
    }

    func testOverlayHelloDeadlineAndOneShotAuthorization() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x7b,
            requestTimeout: .milliseconds(150)
        )
        await fixture.runtime.installAdmissionHandler { _, _, _ in
            throw CancellationError()
        }
        let silent = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let authorizedDelegate = OverlayInventoryPeer(leaves: [])
        let authorized = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7d),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await authorized.installTestDelegate(authorizedDelegate)

        do {
            try await fixture.runtime.start(process: fixture.process)
            try await silent.start()
            try await silent.connect(to: fixture.endpoint)
            for _ in 0..<100 {
                if (await silent.connectedPeers).contains(fixture.peerID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentConnected = await silent.connectedPeers
                .contains(fixture.peerID)
            XCTAssertTrue(silentConnected)
            for _ in 0..<100 {
                if !(await silent.connectedPeers).contains(fixture.peerID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentStillConnected = await silent.connectedPeers
                .contains(fixture.peerID)
            XCTAssertFalse(silentStillConnected)
            await silent.stop()

            try await connectAndHello(
                authorized,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await authorizedDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let initialRequests = await authorizedDelegate.requestCount()
            XCTAssertEqual(initialRequests, 1)

            guard case .enqueued = await authorized.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: fixture.hello
            ) else {
                throw NetworkTestError.failedSend
            }
            try await Task.sleep(for: .milliseconds(300))
            let finalRequests = await authorizedDelegate.requestCount()
            let authorizedConnected = await authorized.connectedPeers
                .contains(fixture.peerID)
            XCTAssertEqual(finalRequests, 1)
            XCTAssertTrue(authorizedConnected)
        } catch {
            await authorized.stop()
            await silent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await authorized.stop()
        await silent.stop()
        await fixture.runtime.stop()
    }

    func testHierarchyContentRequiresHelloOnEveryRealConnection() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-hierarchy-content-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentKey = signingKey(0x71)
        let parentPeer = peerKey(parentKey)
        let parentPort = NetworkTransportTestPorts.allocate()
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "72", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeer.hex,
                host: "127.0.0.1",
                port: parentPort
            )
        )
        let runtime = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let boundary = try VolumeImpl<PublicKey>(
            node: PublicKey(key: "hierarchy-content")
        )
        try await boundary.store(storer: process)
        let rootCID = boundary.rawCID
        let storedVolume = await process.volume(rootCID)
        let expectedVolume = try XCTUnwrap(storedVolume)
        await runtime.installAdmissionHandler { _, _, _ in
            throw CancellationError()
        }
        let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
        let parentHello = try ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: ["Nexus"],
            minimumRootWorkHex: configuration.minimumRootWork.toHexString()
        ).encode()

        func makeParent(
            _ recorder: TopicRecorder
        ) async -> (Ivy, TopicRecordingPeer) {
            let parent = Ivy(config: IvyConfig(
                signingKey: parentKey,
                listenPort: parentPort,
                requestTimeout: .milliseconds(500),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                privateContentExchangeEnabled: true,
                mode: .privateNetwork
            ))
            let delegate = TopicRecordingPeer(recorder: recorder)
            await parent.installTestDelegate(delegate)
            return (parent, delegate)
        }

        func waitForRuntimeHello(_ recorder: TopicRecorder) async throws {
            for _ in 0..<150 {
                if await recorder.contains(NodeNetworkTopic.hierarchyHello) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("runtime hierarchy hello")
        }

        func authorize(_ parent: Ivy) async throws {
            guard case .enqueued = await parent.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: parentHello
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<100 {
                let response = await parent.fetchVolume(rootCID: rootCID)
                if response.rootCID == rootCID,
                   response.entries == expectedVolume.entries { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("authorized hierarchy content")
        }

        let firstRecorder = TopicRecorder()
        var parentPair: (Ivy, TopicRecordingPeer)? = await makeParent(firstRecorder)
        do {
            try await parentPair!.0.start()
            try await runtime.start(process: process)
            try await waitForRuntimeHello(firstRecorder)
            let beforeFirstHello = await parentPair!.0.fetchVolume(rootCID: rootCID)
            XCTAssertEqual(beforeFirstHello, .empty)
            try await authorize(parentPair!.0)

            await parentPair!.0.stop()
            let replacementRecorder = TopicRecorder()
            parentPair = await makeParent(replacementRecorder)
            try await parentPair!.0.start()
            try await waitForRuntimeHello(replacementRecorder)
            let beforeReplacementHello = await parentPair!.0.fetchVolume(rootCID: rootCID)
            XCTAssertEqual(beforeReplacementHello, .empty)
            try await authorize(parentPair!.0)
        } catch {
            await parentPair?.0.stop()
            await runtime.stop()
            throw error
        }
        await parentPair?.0.stop()
        await runtime.stop()
    }

    func testRestartRecoversAcceptedOrphanSuffixOnlyAfterLocalAttachment()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recovery-suffix-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "6d", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: rpcPort
        )

        // Persist P (not admitted) -> O (accepted orphan) -> D (accepted
        // orphan), then reopen. Replaying the remote accepted leaf D must walk
        // the missing predecessor suffix and wake it in connection order.
        var stagingProcess: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let genesis = try await stagingProcess!.canonicalTipBlock()
        let predecessorCandidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 1,
            fetcher: stagingProcess!
        )
        let predecessor = try XCTUnwrap(BlockBuilder.mine(
            block: predecessorCandidate,
            target: predecessorCandidate.target,
            maxAttempts: 4_096
        ))
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let orphanCandidate = try await BlockBuilder.buildBlock(
            previous: predecessor,
            timestamp: 2,
            nonce: 2,
            fetcher: stagingProcess!
        )
        let orphan = try XCTUnwrap(BlockBuilder.mine(
            block: orphanCandidate,
            target: orphanCandidate.target,
            maxAttempts: 4_096
        ))
        let orphanHeader = try BlockHeader(node: orphan)
        try await orphanHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let descendantCandidate = try await BlockBuilder.buildBlock(
            previous: orphan,
            timestamp: 3,
            nonce: 3,
            fetcher: stagingProcess!
        )
        let descendant = try XCTUnwrap(BlockBuilder.mine(
            block: descendantCandidate,
            target: descendantCandidate.target,
            maxAttempts: 4_096
        ))
        let descendantHeader = try BlockHeader(node: descendant)
        try await descendantHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let remoteContent = NetworkTestContentStore()
        for header in [predecessorHeader, orphanHeader, descendantHeader] {
            try await header.storeBlock(
                fetcher: stagingProcess!,
                storer: remoteContent
            )
        }
        let orphanAdmission = try await stagingProcess!.admit(orphanHeader)
        let descendantAdmission = try await stagingProcess!.admit(descendantHeader)
        guard case .acceptedSide = orphanAdmission.decision,
              case .acceptedSide = descendantAdmission.decision
        else {
            return XCTFail("expected accepted orphan suffix")
        }
        XCTAssertEqual(
            orphanAdmission.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: orphanHeader.rawCID,
                predecessorCID: predecessorHeader.rawCID
            )
        )
        XCTAssertEqual(
            descendantAdmission.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: descendantHeader.rawCID,
                predecessorCID: orphanHeader.rawCID
            )
        )
        stagingProcess = nil

        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: hierarchyPort,
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let recoveredProcess = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let recoveredRequirements = await recoveredProcess
            .unresolvedSameChainPredecessors()
        XCTAssertEqual(
            recoveredRequirements,
            [
                SameChainPredecessorRequirement(
                    descendantCID: descendantHeader.rawCID,
                    predecessorCID: orphanHeader.rawCID
                ),
                SameChainPredecessorRequirement(
                    descendantCID: orphanHeader.rawCID,
                    predecessorCID: predecessorHeader.rawCID
                ),
            ].sorted {
                $0.descendantCID < $1.descendantCID
            }
        )

        let plan = RecoveryAdmissionPlan(
            predecessorCID: predecessorHeader.rawCID,
            orphanCID: orphanHeader.rawCID,
            descendantCID: descendantHeader.rawCID
        )
        await runtime.installAdmissionHandler { header, _, _ in
            await plan.admit(header.rawCID)
        }
        let requestRecorder = RecoveryRequestRecorder()
        let clientDelegate = RecoveryRequestPeer(
            recorder: requestRecorder,
            acceptedLeafCID: descendantHeader.rawCID
        )
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(96),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.installTestDelegate(clientDelegate)
        await client.setContentSource(remoteContent)

        do {
            try await runtime.start(process: recoveredProcess)
            try await client.start()
            let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
            try await client.connect(to: PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ))
            for _ in 0..<100 {
                if (await client.connectedPeers).contains(runtimePeer) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (await client.connectedPeers).contains(runtimePeer) else {
                throw NetworkTestError.failedStart
            }
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.overlayHello,
                payload: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: configuration.chainPath,
                    minimumRootWorkHex: configuration.minimumRootWork.toHexString()
                ).encode()
            ) else {
                throw NetworkTestError.failedSend
            }
            let expected = [
                descendantHeader.rawCID,
                orphanHeader.rawCID,
                predecessorHeader.rawCID,
                orphanHeader.rawCID,
                descendantHeader.rawCID,
            ]
            for _ in 0..<200 {
                if await plan.snapshot() == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let requiredRequests: Set<String> = [
                predecessorHeader.rawCID,
                orphanHeader.rawCID,
            ]
            let receivedRequiredRequests = await requestRecorder.contains(
                requiredRequests
            )
            XCTAssertTrue(receivedRequiredRequests)
            let recoveredAdmissions = await plan.snapshot()
            XCTAssertEqual(recoveredAdmissions, expected)
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    func testRestartedRuntimeRetriesDurableChildOrphanWhenOnlyPredecessorArrives()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-child-orphan-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentPeer = peerKey(signingKey(0x97))
        let parentAuthority = try XCTUnwrap(ParentWorkAuthorityKey(parentPeer.hex))
        let overlayPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "98", count: 32),
            listenPort: overlayPort,
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeer.hex,
                host: "127.0.0.1",
                port: NetworkTransportTestPorts.allocate()
            )
        )
        let source = NetworkTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let genesisCandidate = try await networkChildGenesisCandidate(
            parentAuthority: parentAuthority,
            timestamp: 1,
            source: source
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let bootstrap = try await process!.admit(
            genesisCandidate.header,
            authenticatedChildPackage: genesisCandidate.package
        )
        XCTAssertTrue(bootstrap.decision.isAccepted)
        let genesis = try await process!.canonicalTipBlock()
        let predecessor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 2,
            nonce: 1,
            fetcher: process!
        )
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(fetcher: process!, storer: process!)
        try await predecessorHeader.storeBlock(fetcher: process!, storer: source)
        let orphan = try await BlockBuilder.buildBlock(
            previous: predecessor,
            timestamp: 3,
            nonce: 2,
            fetcher: process!
        )
        let orphanHeader = try BlockHeader(node: orphan)
        try await orphanHeader.storeBlock(fetcher: process!, storer: process!)
        try await orphanHeader.storeBlock(fetcher: process!, storer: source)

        func package(
            for block: Block,
            header: BlockHeader,
            timestamp: Int64
        ) async throws -> (AuthenticatedChildPackage, String) {
            let carrierCandidate = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Payments": block],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: source
            )
            let carrier = try XCTUnwrap(BlockBuilder.mine(
                block: carrierCandidate,
                target: block.target,
                maxAttempts: 1_024
            ))
            let carrierHeader = try BlockHeader(node: carrier)
            await source.store(entries: [
                carrierHeader.rawCID: try XCTUnwrap(carrier.toData()),
            ])
            let proof = try await ChildBlockProof.generate(
                rootHeader: carrierHeader,
                childDirectory: "Payments",
                fetcher: source
            )
            let collector = NetworkTestContentStore()
            try await header.storeBlock(fetcher: source, storer: collector)
            var entries = await collector.allEntries()
            entries[carrierHeader.rawCID] = try XCTUnwrap(carrier.toData())
            return (
                AuthenticatedChildPackage(
                    package: ChildValidationPackage(
                        proof: proof,
                        parentCarrierLink: try carrierLink(
                            parentPath: ["Nexus"],
                            carrierCID: carrierHeader.rawCID,
                            rootCID: carrierHeader.rawCID
                        ),
                        parentGenesisLink: nil
                    ),
                    acquisitionEntries: entries
                ),
                carrierHeader.rawCID
            )
        }

        let (predecessorPackage, _) = try await package(
            for: predecessor,
            header: predecessorHeader,
            timestamp: 10
        )
        let (orphanPackageA, orphanCarrierA) = try await package(
            for: orphan,
            header: orphanHeader,
            timestamp: 11
        )
        let (orphanPackageB, orphanCarrierB) = try await package(
            for: orphan,
            header: orphanHeader,
            timestamp: 12
        )
        XCTAssertNotEqual(orphanCarrierA, orphanCarrierB)
        let storedParentWork = try await process!.applyInheritedWorkSnapshot(
            InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    orphanCarrierA: WorkMeasure(contribution(
                        id: orphanCarrierA,
                        work: 64
                    )),
                    orphanCarrierB: WorkMeasure(contribution(
                        id: orphanCarrierB,
                        work: 32
                    )),
                ]
            ),
            from: parentAuthority.value
        )
        XCTAssertNil(storedParentWork)
        let detached = try await process!.admit(
            orphanHeader,
            authenticatedChildPackage: orphanPackageA
        )
        guard case .acceptedSide = detached.decision else {
            return XCTFail("expected accepted child orphan, got \(detached.decision)")
        }
        XCTAssertEqual(detached.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: orphanHeader.rawCID,
            predecessorCID: predecessorHeader.rawCID
        ))
        XCTAssertNil(detached.parentCarrierLink)
        let secondRoot = try await process!.admit(
            orphanHeader,
            authenticatedChildPackage: orphanPackageB
        )
        XCTAssertEqual(secondRoot.sameChainPredecessor, detached.sameChainPredecessor)
        XCTAssertNil(secondRoot.parentCarrierLink)

        let remoteContent = NetworkTestContentStore()
        try await predecessorHeader.storeBlock(
            fetcher: process!,
            storer: remoteContent
        )
        process = nil

        let runtime = try NodeNetworkRuntime(configuration: configuration)
        let recovered = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let admissions = NetworkEventRecorder()
        await runtime.installAdmissionHandler { [weak recovered] header, package, _ in
            guard let recovered else { throw CancellationError() }
            let outcome = try await recovered.admit(
                header,
                authenticatedChildPackage: header.rawCID == predecessorHeader.rawCID
                    ? predecessorPackage
                    : package,
                allowsRemoteAcquisition: true
            )
            await admissions.append(header.rawCID)
            return outcome
        }
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0x99),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.setContentSource(remoteContent)
        let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
        do {
            try await runtime.start(process: recovered)
            try await connectAndHello(
                client,
                peerID: runtimePeer,
                endpoint: PeerEndpoint(
                    publicKey: configuration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: configuration.chainPath,
                    minimumRootWorkHex: configuration.minimumRootWork.toHexString()
                ).encode()
            )
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: predecessorHeader.rawCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForEventCount(
                3,
                in: admissions,
                phase: "durable child orphan retry"
            )

            let admittedCIDs = await admissions.snapshot()
            XCTAssertEqual(admittedCIDs, [
                predecessorHeader.rawCID,
                orphanHeader.rawCID,
                orphanHeader.rawCID,
            ])
            let status = await recovered.status()
            XCTAssertEqual(status.tipCID, orphanHeader.rawCID)
            let liveSnapshot = await recovered.parentSecuringWorkSnapshot()
            let live = try XCTUnwrap(liveSnapshot)
            XCTAssertEqual(
                live.sourceWork(forBlock: orphanHeader.rawCID)
                    .work(forGrind: orphanCarrierA),
                UInt256(64)
            )
            XCTAssertEqual(
                live.sourceWork(forBlock: orphanHeader.rawCID)
                    .work(forGrind: orphanCarrierB),
                UInt256(32)
            )
            let promotedA = try await recovered.issuedParentCarrierLink(
                carrierCID: orphanHeader.rawCID,
                rootCID: orphanCarrierA
            )
            let promotedB = try await recovered.issuedParentCarrierLink(
                carrierCID: orphanHeader.rawCID,
                rootCID: orphanCarrierB
            )
            XCTAssertNotNil(promotedA)
            XCTAssertNotNil(promotedB)
            let unresolved = await recovered.unresolvedSameChainPredecessors()
            XCTAssertTrue(unresolved.isEmpty)
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    func testConfiguredParentAssemblesEveryFragmentDespiteChildTallyPressure()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-parent-admission-bypass-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentKey = signingKey(95)
        let parentPeerKey = peerKey(parentKey)
        let parentFactPort = NetworkTransportTestPorts.allocate()
        let childOverlayPort = NetworkTransportTestPorts.allocate()
        let childFactPort = NetworkTransportTestPorts.allocate()
        let childRPCPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5e", count: 32),
            listenPort: childOverlayPort,
            factListenPort: childFactPort,
            rpcPort: childRPCPort,
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeerKey.hex,
                host: "127.0.0.1",
                port: parentFactPort
            )
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: childOverlayPort,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: childFactPort,
                bootstrapPeers: [configuration.parentEndpoint!.ivy],
                inboundAdmissionBypassPeerKeys: [parentPeerKey],
                tallyConfig: TallyConfig(
                    perPeerRequestCapacity: 1,
                    perPeerRequestRefillPerSecond: 0
                ),
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let parent = Ivy(config: IvyConfig(
            signingKey: parentKey,
            listenPort: parentFactPort,
            stunServers: [],
            mode: .privateNetwork
        ))
        let received = InheritedSnapshotRecorder()
        await runtime.installAdmissionHandler { _, _, _ in
            NodeAdmissionOutcome(
                decision: .duplicate,
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        await runtime.installInheritedWorkHandler { snapshot, _ in
            await received.append(snapshot)
            return nil
        }

        let child = inheritedWorkCID("child")
        let exported = InheritedWorkSnapshot(
            revision: 17,
            workByBlock: [
                child: WorkMeasure((0..<96).map {
                    contribution(
                        id: inheritedWorkCID("admission-bypass-\($0)"),
                        work: UInt64($0 + 1)
                    )
                }),
            ]
        )
        let payloads = try XCTUnwrap(NodeNetworkRuntime.inheritedWorkPushPayloads(
            snapshot: exported,
            maximumPayloadBytes: 350
        ))
        XCTAssertGreaterThan(payloads.count, 1)

        do {
            try await parent.start()
            try await runtime.start(process: process)
            let childPeer = PeerID(publicKey: configuration.processPublicKey)
            for _ in 0..<100 {
                if (await parent.connectedPeers).contains(childPeer) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (await parent.connectedPeers).contains(childPeer) else {
                XCTFail("configured child did not connect to its parent")
                throw NetworkTestError.failedStart
            }
            let helloSend = await parent.sendMessage(
                to: childPeer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: ["Nexus"],
                    minimumRootWorkHex: configuration.minimumRootWork.toHexString()
                ).encode()
            )
            guard case .enqueued = helloSend else {
                XCTFail("parent hierarchy hello was not queued: \(helloSend)")
                throw NetworkTestError.failedSend
            }
            let streamed = await NodeNetworkRuntime.streamInheritedWorkPushPayloads(
                snapshot: exported,
                maximumPayloadBytes: 350,
                send: { payload in
                    while true {
                        switch await parent.sendMessage(
                            to: childPeer,
                            topic: NodeNetworkTopic.inheritedWorkPush,
                            payload: payload
                        ) {
                        case .enqueued:
                            return .enqueued
                        case .backpressured:
                            guard await parent.waitUntilWritable(to: childPeer) else {
                                return .stopped
                            }
                        case .locallyRejected, .notConnected:
                            return .stopped
                        }
                    }
                },
                waitForRetry: { false }
            )
            XCTAssertTrue(streamed)

            for _ in 0..<100 {
                if await received.snapshot().count == 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let recorded = await received.snapshot()
            XCTAssertEqual(recorded.count, 1)
            XCTAssertEqual(recorded.merged, exported)
        } catch {
            await parent.stop()
            await runtime.stop()
            throw error
        }
        await parent.stop()
        await runtime.stop()
    }

    func testConfiguredParentReconnectsWhenFirstHierarchyHelloIsWithheld()
        async throws {
        let fixture = try await hierarchyRetryFixture(
            keyByte: 0x61,
            summary: nil,
            withholdFirstHello: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }

        do {
            try await fixture.parent.start()
            try await fixture.runtime.start(process: fixture.process)
            for _ in 0..<400 {
                let trace = await fixture.recorder.sessionTrace()
                if trace.hellos.count >= 2, !trace.indexes.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let trace = await fixture.recorder.sessionTrace()
            XCTAssertGreaterThanOrEqual(trace.hellos.count, 2)
            let firstHello = try XCTUnwrap(trace.hellos.first)
            let secondHello = try XCTUnwrap(trace.hellos.dropFirst().first)
            let firstIndex = try XCTUnwrap(trace.indexes.first)
            XCTAssertNotEqual(firstHello, secondHello)
            XCTAssertFalse(trace.indexes.contains(firstHello))
            XCTAssertTrue(Set(trace.hellos.dropFirst()).contains(firstIndex))
        } catch {
            await fixture.parent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await fixture.parent.stop()
        await fixture.runtime.stop()
    }

    func testRecoveredNoncanonicalCarrierAnnouncesEvidenceAfterEmptyIndex()
        async throws {
        let fixture = try await pendingSideCarrierFixture(
            keyByte: 0x68,
            rejectAvailability: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        var provider: Ivy?

        do {
            try await fixture.runtime.start(process: fixture.process)
            try await fixture.child.start()
            try await waitForEvidenceIndexes(fixture, count: 1)
            let initial = await fixture.recorder.snapshot()
            XCTAssertEqual(
                initial.indexEntries,
                [[]]
            )

            provider = try await exposePendingCarrierContent(
                fixture,
                keyByte: 0x6a
            )
            for _ in 0..<300 {
                if !(await fixture.recorder.snapshot()).available.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let recorded = await fixture.recorder.snapshot()
            XCTAssertEqual(recorded.indexEntries, [[]])
            XCTAssertEqual(recorded.available.count, 1)
            XCTAssertEqual(recorded.available.first?.childPath, fixture.childPath)
            XCTAssertEqual(recorded.available.first?.childCID, fixture.childCID)
            XCTAssertEqual(recorded.available.first?.rootCID, fixture.carrierCID)
            XCTAssertTrue(recorded.available.first.map {
                CIDIdentity.isCanonical($0.attachmentCID)
            } ?? false)
            let pending = try await fixture.process.pendingChildProofCarrierCIDs()
            let status = await fixture.process.status()
            // A concurrent current-tip retry may retain its own route. This
            // recovery is responsible only for the side carrier it completed.
            XCTAssertFalse(pending.contains(fixture.carrierCID))
            XCTAssertEqual(status.tipCID, fixture.canonicalTipCID)
        } catch {
            await provider?.stop()
            await fixture.child.stop()
            await fixture.runtime.stop()
            throw error
        }
        await provider?.stop()
        await fixture.child.stop()
        await fixture.runtime.stop()
    }

    func testRejectedEvidenceHintRecyclesSessionAndReconnectIndexRepairs()
        async throws {
        let fixture = try await pendingSideCarrierFixture(
            keyByte: 0x6b,
            rejectAvailability: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        var provider: Ivy?
        let parentID = PeerID(publicKey: fixture.configuration.processPublicKey)

        do {
            try await fixture.runtime.start(process: fixture.process)
            try await fixture.child.start()
            try await waitForEvidenceIndexes(fixture, count: 1)
            let hierarchyTally = await fixture.runtime.hierarchy.tally
            let childID = await fixture.child.localID
            var exhausted = false
            for _ in 0..<16 where !exhausted {
                exhausted = !hierarchyTally.shouldAllow(
                    peer: childID
                )
            }
            XCTAssertTrue(exhausted)

            provider = try await exposePendingCarrierContent(
                fixture,
                keyByte: 0x6d
            )
            for _ in 0..<300 {
                if !(await fixture.child.connectedPeers).contains(parentID) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let connectedAfterRejection = await fixture.child.connectedPeers
            XCTAssertFalse(connectedAfterRejection.contains(parentID))
            let rejected = await fixture.recorder.snapshot()
            XCTAssertEqual(rejected.helloSessions.count, 1)
            XCTAssertEqual(rejected.indexEntries, [[]])
            XCTAssertTrue(rejected.available.isEmpty)

            hierarchyTally.resetPeer(childID)
            try await waitForEvidenceIndexes(fixture, count: 2)

            let repaired = await fixture.recorder.snapshot()
            XCTAssertEqual(repaired.helloSessions.count, 2)
            XCTAssertNotEqual(
                repaired.helloSessions[0],
                repaired.helloSessions[1]
            )
            XCTAssertEqual(repaired.indexEntries.count, 2)
            XCTAssertTrue(repaired.indexEntries.first?.isEmpty == true)
            XCTAssertEqual(repaired.indexEntries.last?.count, 1)
            XCTAssertEqual(repaired.indexEntries.last?.first?.childCID, fixture.childCID)
            XCTAssertEqual(repaired.indexEntries.last?.first?.rootCID, fixture.carrierCID)
            XCTAssertTrue(repaired.indexEntries.last?.first.map {
                CIDIdentity.isCanonical($0.attachmentCID)
            } ?? false)
            XCTAssertTrue(repaired.available.isEmpty)
            let pending = try await fixture.process.pendingChildProofCarrierCIDs()
            let status = await fixture.process.status()
            XCTAssertTrue(pending.isEmpty)
            XCTAssertEqual(status.tipCID, fixture.canonicalTipCID)
        } catch {
            await provider?.stop()
            await fixture.child.stop()
            await fixture.runtime.stop()
            throw error
        }
        await provider?.stop()
        await fixture.child.stop()
        await fixture.runtime.stop()
    }

    func testRealParentIvyWorkPushReorgsChildAndSurvivesOldReplay()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-parent-work-reorg-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }

        let parentKey = signingKey(96)
        let parentPeerKey = peerKey(parentKey)
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parentPeerKey.hex)
        )
        let parentFactPort = NetworkTransportTestPorts.allocate()
        let childOverlayPort = NetworkTransportTestPorts.allocate()
        let childFactPort = NetworkTransportTestPorts.allocate()
        let childRPCPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "61", count: 32),
            listenPort: childOverlayPort,
            factListenPort: childFactPort,
            rpcPort: childRPCPort,
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeerKey.hex,
                host: "127.0.0.1",
                port: parentFactPort
            )
        )
        let source = NetworkTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: source as any Storer
        )
        let first = try await networkChildGenesisCandidate(
            parentAuthority: parentAuthority,
            timestamp: 1,
            source: source
        )
        let second = try await networkChildGenesisCandidate(
            parentAuthority: parentAuthority,
            timestamp: 3,
            source: source
        )

        let firstGrind = inheritedWorkCID("real-ivy-first")
        let secondGrind = inheritedWorkCID("real-ivy-second")
        let newSecondGrind = inheritedWorkCID("real-ivy-new-second")
        let firstCarrierCID = try XCTUnwrap(
            first.package.package.parentCarrierLink?.carrierCID
        )
        let secondCarrierCID = try XCTUnwrap(
            second.package.package.parentCarrierLink?.carrierCID
        )
        let initial = InheritedWorkSnapshot(
            revision: 17,
            workByBlock: [
                firstCarrierCID: WorkMeasure(contribution(
                    id: firstGrind,
                    work: 1_000
                )),
                secondCarrierCID: WorkMeasure(
                    [contribution(id: secondGrind, work: 600)]
                    + (0..<257).map {
                        contribution(
                            id: inheritedWorkCID("real-ivy-filler-\($0)"),
                            work: 1
                        )
                    }
                ),
            ]
        )
        let initialFrames = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: initial,
                maximumPayloadBytes: 350
            )
        )
        XCTAssertGreaterThan(initialFrames.count, 1)
        let strengthening = InheritedWorkSnapshot(
            revision: 18,
            workByBlock: [
                secondCarrierCID: WorkMeasure(contribution(
                    id: newSecondGrind,
                    work: 200
                )),
            ]
        )
        let strengtheningPayload = try InheritedWorkPushMessage(
            snapshot: strengthening
        ).encoded()
        let strengtheningCompletion = try InheritedWorkPushMessage(
            snapshot: InheritedWorkSnapshot(revision: strengthening.revision, facts: [])
        ).encoded()

        func childPlanes() throws -> NodeNetworkPlaneConfigurations {
            try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: childOverlayPort,
                    stunServers: [],
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: childFactPort,
                    bootstrapPeers: [configuration.parentEndpoint!.ivy],
                    inboundAdmissionBypassPeerKeys: [parentPeerKey],
                    tallyConfig: TallyConfig(
                        perPeerRequestCapacity: 1,
                        perPeerRequestRefillPerSecond: 0
                    ),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        }

        func makeRuntime(
            _ process: ChainProcess
        ) async throws -> (
            runtime: NodeNetworkRuntime,
            deliveries: InheritedSnapshotRecorder,
            service: ChainService
        ) {
            let runtime = try NodeNetworkRuntime(
                configuration: configuration,
                planeConfigurations: try childPlanes()
            )
            let service = ChainService(
                process: process,
                childCandidateProvider: { _ in [] },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in }
            )
            let deliveries = InheritedSnapshotRecorder()
            await runtime.installAdmissionHandler { _, _, _ in
                NodeAdmissionOutcome(
                    decision: .duplicate,
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            }
            await runtime.installInheritedWorkHandler { [weak service] snapshot, key in
                guard let service else { throw CancellationError() }
                await deliveries.append(snapshot)
                return try await service.applyInheritedWorkSnapshot(
                    snapshot,
                    from: key
                )
            }
            return (runtime, deliveries, service)
        }

        func makeParent() -> Ivy {
            Ivy(config: IvyConfig(
                signingKey: parentKey,
                listenPort: parentFactPort,
                stunServers: [],
                mode: .privateNetwork
            ))
        }

        func connect(
            parent: Ivy,
            runtime: NodeNetworkRuntime,
            process: ChainProcess
        ) async throws -> PeerID {
            try await parent.start()
            try await runtime.start(process: process)
            let childPeer = PeerID(publicKey: configuration.processPublicKey)
            for _ in 0..<100 {
                if (await parent.connectedPeers).contains(childPeer) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (await parent.connectedPeers).contains(childPeer) else {
                throw NetworkTestError.failedStart
            }
            guard case .enqueued = await parent.sendMessage(
                to: childPeer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: ["Nexus"],
                    minimumRootWorkHex: configuration.minimumRootWork.toHexString()
                ).encode()
            ) else {
                throw NetworkTestError.failedSend
            }
            return childPeer
        }

        func send(
            _ payload: Data,
            parent: Ivy,
            to childPeer: PeerID
        ) async throws {
            while true {
                switch await parent.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.inheritedWorkPush,
                    payload: payload
                ) {
                case .enqueued:
                    return
                case .backpressured:
                    guard await parent.waitUntilWritable(to: childPeer) else {
                        throw NetworkTestError.failedSend
                    }
                case .locallyRejected, .notConnected:
                    throw NetworkTestError.failedSend
                }
            }
        }

        func waitForDeliveries(
            _ deliveries: InheritedSnapshotRecorder,
            count: Int
        ) async throws {
            for _ in 0..<200 {
                if await deliveries.snapshot().count >= count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedStart
        }

        func waitForTip(
            _ process: ChainProcess,
            _ expected: String
        ) async throws {
            for _ in 0..<200 {
                if await process.status().tipCID == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("tip \(expected)")
        }

        func reopenAfterRuntimeTeardown() async throws -> ChainProcess {
            for _ in 0..<200 {
                do {
                    return try await ChainProcess.open(configuration: configuration)
                } catch ChainProcessError.storageInUse {
                    // Stopped Ivy callback tasks can retain their fenced
                    // process argument until cancellation reaches them.
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            throw ChainProcessError.storageInUse
        }

        var process: ChainProcess? = nil
        var runtime: NodeNetworkRuntime? = nil
        var deliveries: InheritedSnapshotRecorder? = nil
        var service: ChainService? = nil
        var parent: Ivy? = nil
        do {
            process = try await ChainProcess.open(
                configuration: configuration
            )
            let firstAdmission = try await process!.admit(
                first.header,
                authenticatedChildPackage: first.package
            )
            XCTAssertTrue(firstAdmission.decision.isAccepted)
            let secondAdmission = try await process!.admit(
                second.header,
                authenticatedChildPackage: second.package
            )
            XCTAssertTrue(secondAdmission.decision.isAccepted)

            do {
                let firstRuntime = try await makeRuntime(process!)
                runtime = firstRuntime.runtime
                deliveries = firstRuntime.deliveries
                service = firstRuntime.service
            }
            parent = makeParent()
            let firstPeer = try await connect(
                parent: parent!,
                runtime: runtime!,
                process: process!
            )

            let completion = try XCTUnwrap(initialFrames.last)
            let factFrames = initialFrames.dropLast()
            let reorderedFacts = Array(factFrames.reversed()) + [
                try XCTUnwrap(factFrames.first),
            ]
            for payload in reorderedFacts {
                try await send(payload, parent: parent!, to: firstPeer)
            }
            try await Task.sleep(for: .milliseconds(100))
            let preMarkerDeliveryCount = await deliveries!.snapshot().count
            XCTAssertEqual(preMarkerDeliveryCount, 0)
            try await send(completion, parent: parent!, to: firstPeer)
            try await waitForDeliveries(
                deliveries!,
                count: 1
            )
            try await waitForTip(process!, first.header.rawCID)

            try await send(
                strengtheningPayload,
                parent: parent!,
                to: firstPeer
            )
            try await Task.sleep(for: .milliseconds(100))
            let preStrengtheningMarkerCount = await deliveries!.snapshot().count
            XCTAssertEqual(preStrengtheningMarkerCount, 1)
            try await waitForTip(process!, first.header.rawCID)
            try await send(
                strengtheningCompletion,
                parent: parent!,
                to: firstPeer
            )
            try await waitForDeliveries(
                deliveries!,
                count: 2
            )
            try await waitForTip(process!, second.header.rawCID)

            // The live Ivy delivery above made the change. Restart only proves
            // raw facts survive and an older full replay cannot add work again.
            await parent!.stop()
            await runtime!.stop()
            parent = nil
            runtime = nil
            deliveries = nil
            _ = service
            service = nil
            process = nil

            process = try await reopenAfterRuntimeTeardown()
            try await waitForTip(process!, second.header.rawCID)
            do {
                let replayRuntime = try await makeRuntime(process!)
                runtime = replayRuntime.runtime
                deliveries = replayRuntime.deliveries
                service = replayRuntime.service
            }
            parent = makeParent()
            let replayPeer = try await connect(
                parent: parent!,
                runtime: runtime!,
                process: process!
            )
            for payload in Array(initialFrames.dropLast().reversed())
                + [try XCTUnwrap(initialFrames.last)] {
                try await send(payload, parent: parent!, to: replayPeer)
            }
            try await waitForDeliveries(
                deliveries!,
                count: 1
            )
            try await waitForTip(process!, second.header.rawCID)

            await parent!.stop()
            await runtime!.stop()
            parent = nil
            runtime = nil
            deliveries = nil
            _ = service
            service = nil
            process = nil

            var store: NodeStore? = try testNodeStore(
                databasePath: configuration.storagePath.appendingPathComponent("state.db"),
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath,
                minimumRootWork: configuration.minimumRootWork,
                spawningParentKey: parentAuthority.value,
                issuingAuthorityKey: configuration.processPublicKey
            )
            let persistedSnapshot = try await store!.inheritedWorkSnapshot()
            let persisted = try XCTUnwrap(persistedSnapshot)
            XCTAssertEqual(
                persisted.sourceWork(forBlock: firstCarrierCID)
                    .work(forGrind: firstGrind),
                UInt256(1_000)
            )
            XCTAssertEqual(
                persisted.sourceWork(forBlock: secondCarrierCID)
                    .work(forGrind: newSecondGrind),
                UInt256(200)
            )
            store = nil
        } catch {
            if let parent { await parent.stop() }
            if let runtime { await runtime.stop() }
            throw error
        }
    }

    func testAcceptedNoncanonicalParentDescendantsDoNotReweightChild()
        async throws {
        let parentStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-side-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let childStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-side-child-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: parentStorage) }
        addTeardownBlock { try? FileManager.default.removeItem(at: childStorage) }

        let parentOverlayPort = NetworkTransportTestPorts.allocate()
        let parentFactPort = NetworkTransportTestPorts.allocate()
        let parentRPCPort = NetworkTransportTestPorts.allocate()
        let childOverlayPort = NetworkTransportTestPorts.allocate()
        let childFactPort = NetworkTransportTestPorts.allocate()
        let childRPCPort = NetworkTransportTestPorts.allocate()
        let parentConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: parentStorage,
            privateKeyHex: String(repeating: "62", count: 32),
            listenPort: parentOverlayPort,
            factListenPort: parentFactPort,
            rpcPort: parentRPCPort
        )
        let childConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: childStorage,
            privateKeyHex: String(repeating: "63", count: 32),
            listenPort: childOverlayPort,
            factListenPort: childFactPort,
            rpcPort: childRPCPort,
            parentEndpoint: ParentEndpoint(
                publicKey: parentConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: parentFactPort
            )
        )
        let parentRuntime = try NodeNetworkRuntime(configuration: parentConfiguration)
        let childRuntime = try NodeNetworkRuntime(configuration: childConfiguration)
        let parent = try await ChainProcess.open(
            configuration: parentConfiguration,
            remoteSource: parentRuntime.remoteContentSource
        )
        let child = try await ChainProcess.open(
            configuration: childConfiguration,
            remoteSource: childRuntime.remoteContentSource
        )
        let published = NetworkEventRecorder()
        let deliveries = InheritedSnapshotRecorder()
        let parentService = ChainService(
            process: parent,
            childCandidateProvider: { [weak parentRuntime] context in
                guard let parentRuntime else { return [] }
                return await parentRuntime.directChildCandidates(context)
            },
            childProofPublisher: { [weak parentRuntime] publication in
                guard let parentRuntime else { throw CancellationError() }
                _ = try await parentRuntime.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    child: publication.childBlock
                )
            },
            acceptedBlockPublisher: { [weak parentRuntime] blockCID in
                await published.append(blockCID)
                guard let parentRuntime else { throw CancellationError() }
                try await parentRuntime.publishAcceptedBlock(blockCID)
            }
        )
        let childService = networkService(process: child, runtime: childRuntime)
        await parentRuntime.installAdmissionHandler { [weak parentService] header, package, directories in
            guard let parentService else { throw CancellationError() }
            return try await parentService.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        await parentRuntime.installInheritedWorkHandler { [weak parentService] snapshot, key in
            guard let parentService else { throw CancellationError() }
            return try await parentService.applyInheritedWorkSnapshot(
                snapshot,
                from: key
            )
        }
        await childRuntime.installAdmissionHandler { [weak childService] header, package, directories in
            guard let childService else { throw CancellationError() }
            return try await childService.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        await childRuntime.installInheritedWorkHandler { [weak childService] snapshot, key in
            await deliveries.append(snapshot)
            guard let childService else { throw CancellationError() }
            return try await childService.applyInheritedWorkSnapshot(
                snapshot,
                from: key
            )
        }

        func waitForTip(_ expected: String) async throws {
            for _ in 0..<200 {
                if await child.status().tipCID == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedStart
        }

        func waitForReceivedWork(
            blockCID: String,
            grinds: Set<String>
        ) async throws {
            for _ in 0..<200 {
                let received = await deliveries.snapshot().merged
                if Set(received.sourceWork(forBlock: blockCID).grindIDs) == grinds {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedStart
        }

        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parentConfiguration.processPublicKey)
        )
        let parentGenesis = try await parent.canonicalTipBlock()
        var canonical = parentGenesis
        for step in 1...5 {
            canonical = try await BlockBuilder.buildBlock(
                previous: canonical,
                timestamp: Int64(step * 3_600_000),
                nonce: UInt64(step),
                fetcher: parent
            )
            let outcome = try await parent.admit(BlockHeader(node: canonical))
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        let canonicalChild = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: canonical.postState,
            timestamp: 21_600_000,
            target: UInt256.max,
            fetcher: parent
        )
        let canonicalChildHeader = try BlockHeader(node: canonicalChild)
        let canonicalAuthorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: canonicalChildHeader.rawCID,
            parentWorkAuthorityKey: parentAuthority,
            chainPath: parentConfiguration.chainPath
        )
        try await VolumeImpl<Transaction>(node: canonicalAuthorization).storeRecursively(
            storer: parent
        )
        let canonicalCarrier = try await BlockBuilder.buildBlock(
            previous: canonical,
            transactions: [canonicalAuthorization],
            children: ["Payments": canonicalChild],
            timestamp: 21_600_000,
            nonce: 6,
            fetcher: parent
        )
        let canonicalCarrierHeader = try BlockHeader(node: canonicalCarrier)
        _ = try await parent.prepareChildProofs(
            for: canonicalCarrier,
            capacity: 16
        )
        let canonicalCarrierAdmission = try await parent.admit(canonicalCarrierHeader)
        XCTAssertTrue(canonicalCarrierAdmission.decision.isAccepted)
        let canonicalOne = try await BlockBuilder.buildBlock(
            previous: canonicalCarrier,
            timestamp: 25_200_000,
            nonce: 7,
            fetcher: parent
        )
        let canonicalOneHeader = try BlockHeader(node: canonicalOne)
        let canonicalOneAdmission = try await parent.admit(canonicalOneHeader)
        XCTAssertTrue(canonicalOneAdmission.decision.isAccepted)
        let canonicalTwo = try await BlockBuilder.buildBlock(
            previous: canonicalOne,
            timestamp: 28_800_000,
            nonce: 8,
            fetcher: parent
        )
        let canonicalTwoHeader = try BlockHeader(node: canonicalTwo)
        let canonicalTwoAdmission = try await parent.admit(canonicalTwoHeader)
        XCTAssertTrue(canonicalTwoAdmission.decision.isAccepted)
        let canonicalThree = try await BlockBuilder.buildBlock(
            previous: canonicalTwo,
            timestamp: 32_400_000,
            nonce: 9,
            fetcher: parent
        )
        let canonicalThreeHeader = try BlockHeader(node: canonicalThree)
        let canonicalThreeAdmission = try await parent.admit(canonicalThreeHeader)
        XCTAssertTrue(canonicalThreeAdmission.decision.isAccepted)
        let canonicalTip = canonicalThreeHeader.rawCID

        let predecessor = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            timestamp: 3_600_000,
            nonce: 100,
            fetcher: parent
        )
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(fetcher: parent, storer: parent)
        let sideChild = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: predecessor.postState,
            timestamp: 7_200_000,
            target: UInt256.max,
            fetcher: parent
        )
        let sideChildHeader = try BlockHeader(node: sideChild)
        let sideAuthorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: sideChildHeader.rawCID,
            parentWorkAuthorityKey: parentAuthority,
            chainPath: parentConfiguration.chainPath
        )
        try await VolumeImpl<Transaction>(node: sideAuthorization).storeRecursively(
            storer: parent
        )
        let sideCarrier = try await BlockBuilder.buildBlock(
            previous: predecessor,
            transactions: [sideAuthorization],
            children: ["Payments": sideChild],
            timestamp: 7_200_000,
            nonce: 101,
            fetcher: parent
        )
        let sideCarrierHeader = try BlockHeader(node: sideCarrier)
        _ = try await parent.prepareChildProofs(for: sideCarrier, capacity: 16)
        let sideOrphan = try await parent.admit(sideCarrierHeader)
        guard case .acceptedSide = sideOrphan.decision else {
            return XCTFail("expected accepted side carrier, got \(sideOrphan.decision)")
        }
        XCTAssertEqual(sideOrphan.sameChainPredecessor?.predecessorCID, predecessorHeader.rawCID)
        let predecessorAdmission = try await parent.admit(predecessorHeader)
        XCTAssertTrue(predecessorAdmission.decision.isAccepted)
        let sideRetry = try await parent.admit(sideCarrierHeader)
        XCTAssertEqual(sideRetry.decision, .duplicate)
        XCTAssertEqual(
            sideRetry.parentCarrierLink?.carrierCID,
            sideCarrierHeader.rawCID
        )

        let sideOne = try await BlockBuilder.buildBlock(
            previous: sideCarrier,
            timestamp: 10_800_000,
            nonce: 102,
            fetcher: parent
        )
        let sideOneHeader = try BlockHeader(node: sideOne)
        let sideTwo = try await BlockBuilder.buildBlock(
            previous: sideOne,
            timestamp: 14_400_000,
            nonce: 103,
            fetcher: parent
        )
        let sideTwoHeader = try BlockHeader(node: sideTwo)
        let sideThree = try await BlockBuilder.buildBlock(
            previous: sideTwo,
            timestamp: 18_000_000,
            nonce: 104,
            fetcher: parent
        )
        let sideThreeHeader = try BlockHeader(node: sideThree)
        let sideFour = try await BlockBuilder.buildBlock(
            previous: sideThree,
            timestamp: 21_600_000,
            nonce: 105,
            fetcher: parent
        )
        let sideFourHeader = try BlockHeader(node: sideFour)

        let canonicalPackage = try await networkChildPackage(
            parent: parent,
            carrierCID: canonicalCarrierHeader.rawCID,
            rootCID: canonicalCarrierHeader.rawCID,
            directory: "Payments",
            childCID: canonicalChildHeader.rawCID
        )
        let sidePackage = try await networkChildPackage(
            parent: parent,
            carrierCID: sideCarrierHeader.rawCID,
            rootCID: sideCarrierHeader.rawCID,
            directory: "Payments",
            childCID: sideChildHeader.rawCID
        )

        let canonicalChildAdmission = try await child.admit(
            canonicalChildHeader,
            authenticatedChildPackage: canonicalPackage
        )
        guard case .canonicalized = canonicalChildAdmission.decision else {
            return XCTFail(
                "expected canonical child bootstrap, got \(canonicalChildAdmission.decision)"
            )
        }
        let sideChildAdmission = try await child.admit(
            sideChildHeader,
            authenticatedChildPackage: sidePackage
        )
        XCTAssertTrue(sideChildAdmission.decision.isAccepted)
        let directStatus = await child.status()
        let directWinner = try XCTUnwrap(directStatus.tipCID)

        do {
            try await parentRuntime.start(process: parent)
            try await childRuntime.start(process: child)
            try await waitForTip(directWinner)

            for header in [sideOneHeader, sideTwoHeader, sideThreeHeader, sideFourHeader] {
                let admitted = try await parentService.admitNetworkCandidate(
                    header,
                    authenticatedChildPackage: nil,
                    preparingChildDirectories: []
                )
                guard case .acceptedSide = admitted.decision else {
                    await childRuntime.stop()
                    await parentRuntime.stop()
                    return XCTFail("expected accepted side block, got \(admitted.decision)")
                }
            }

            try await waitForTip(directWinner)
            let parentStatus = await parent.status()
            XCTAssertEqual(parentStatus.tipCID, canonicalTip)
            let publishedEvents = await published.snapshot()
            XCTAssertEqual(
                publishedEvents,
                [
                    sideOneHeader.rawCID,
                    sideTwoHeader.rawCID,
                    sideThreeHeader.rawCID,
                    sideFourHeader.rawCID,
                ]
            )
            let expectedGrinds: Set<String> = [sideCarrierHeader.rawCID]
            let parentSnapshot = await parent.parentSecuringWorkSnapshot()
            let exported = try XCTUnwrap(parentSnapshot)
            XCTAssertEqual(
                Set(exported.sourceWork(forBlock: sideCarrierHeader.rawCID).grindIDs),
                expectedGrinds
            )
            try await waitForReceivedWork(
                blockCID: sideCarrierHeader.rawCID,
                grinds: expectedGrinds
            )
            let received = await deliveries.snapshot().merged
            XCTAssertEqual(
                Set(received.sourceWork(forBlock: sideCarrierHeader.rawCID).grindIDs),
                expectedGrinds
            )
        } catch {
            await childRuntime.stop()
            await parentRuntime.stop()
            throw error
        }
        await childRuntime.stop()
        await parentRuntime.stop()
    }

    func testInheritedParentSideWorkRelaysToGrandchildWithoutMiddleReorg()
        async throws {
        let upstreamStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recursive-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let middleStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recursive-middle-\(UUID().uuidString)",
            isDirectory: true
        )
        let leafStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recursive-leaf-\(UUID().uuidString)",
            isDirectory: true
        )
        for storage in [upstreamStorage, middleStorage, leafStorage] {
            addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        }

        let upstreamOverlayPort = NetworkTransportTestPorts.allocate()
        let upstreamFactPort = NetworkTransportTestPorts.allocate()
        let upstreamRPCPort = NetworkTransportTestPorts.allocate()
        let middleOverlayPort = NetworkTransportTestPorts.allocate()
        let middleFactPort = NetworkTransportTestPorts.allocate()
        let middleRPCPort = NetworkTransportTestPorts.allocate()
        let leafOverlayPort = NetworkTransportTestPorts.allocate()
        let leafFactPort = NetworkTransportTestPorts.allocate()
        let leafRPCPort = NetworkTransportTestPorts.allocate()
        let upstreamConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: upstreamStorage,
            privateKeyHex: String(repeating: "71", count: 32),
            listenPort: upstreamOverlayPort,
            factListenPort: upstreamFactPort,
            rpcPort: upstreamRPCPort
        )
        let middleConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: middleStorage,
            privateKeyHex: String(repeating: "72", count: 32),
            listenPort: middleOverlayPort,
            factListenPort: middleFactPort,
            rpcPort: middleRPCPort,
            parentEndpoint: ParentEndpoint(
                publicKey: upstreamConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: upstreamFactPort
            )
        )
        let leafConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments", "Receipts"],
            minimumRootWork: UInt256(1),
            storagePath: leafStorage,
            privateKeyHex: String(repeating: "73", count: 32),
            listenPort: leafOverlayPort,
            factListenPort: leafFactPort,
            rpcPort: leafRPCPort,
            parentEndpoint: ParentEndpoint(
                publicKey: middleConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: middleFactPort
            )
        )
        let upstream = try await ChainProcess.open(configuration: upstreamConfiguration)
        let middleRuntime = try NodeNetworkRuntime(configuration: middleConfiguration)
        let leafRuntime = try NodeNetworkRuntime(configuration: leafConfiguration)
        let middle = try await ChainProcess.open(
            configuration: middleConfiguration,
            remoteSource: middleRuntime.remoteContentSource
        )
        let leaf = try await ChainProcess.open(
            configuration: leafConfiguration,
            remoteSource: leafRuntime.remoteContentSource
        )

        let middleService = networkService(
            process: middle,
            runtime: middleRuntime
        )
        let leafService = networkService(process: leaf, runtime: leafRuntime)
        let middleCommits = NetworkEventRecorder()
        let middleReadiness = NetworkEventRecorder()
        let leafReadiness = NetworkEventRecorder()
        let leafDeliveries = InheritedSnapshotRecorder()
        await middleRuntime.installParentReadinessHandler { ready in
            await middleReadiness.append(ready ? "ready" : "not-ready")
        }
        await leafRuntime.installParentReadinessHandler { ready in
            await leafReadiness.append(ready ? "ready" : "not-ready")
        }
        await middleRuntime.installAdmissionHandler { [weak middleService] header, package, directories in
            guard let middleService else { throw CancellationError() }
            return try await middleService.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        await middleRuntime.installInheritedWorkHandler { [weak middleService] snapshot, key in
            guard let middleService else { throw CancellationError() }
            let commit = try await middleService.applyInheritedWorkSnapshot(
                snapshot,
                from: key
            )
            if let commit {
                await middleCommits.append(commit.canonicalChanged ? "true" : "false")
            }
            return commit
        }
        await leafRuntime.installAdmissionHandler { [weak leafService] header, package, directories in
            guard let leafService else { throw CancellationError() }
            return try await leafService.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        await leafRuntime.installInheritedWorkHandler { [weak leafService] snapshot, key in
            await leafDeliveries.append(snapshot)
            guard let leafService else { throw CancellationError() }
            return try await leafService.applyInheritedWorkSnapshot(
                snapshot,
                from: key
            )
        }

        let upstreamAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(upstreamConfiguration.processPublicKey)
        )
        let middleAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(middleConfiguration.processPublicKey)
        )
        let upstreamGenesis = try await upstream.canonicalTipBlock()

        func makeBranch(
            timestamp: Int64,
            middleTarget: UInt256,
            leafTarget: UInt256
        ) async throws -> NetworkHierarchyBranch {
            let leafBlock = try await BlockBuilder.buildChildGenesis(
                spec: NexusGenesis.spec.withParentWorkAuthorityKey(middleAuthority),
                parentState: LatticeState.emptyHeader,
                timestamp: timestamp,
                target: leafTarget,
                fetcher: upstream
            )
            let leafHeader = try BlockHeader(node: leafBlock)
            try await leafHeader.storeBlock(fetcher: upstream, storer: upstream)

            let leafAuthorization = try signedGenesisAuthorization(
                directory: "Receipts",
                childGenesisCID: leafHeader.rawCID,
                parentWorkAuthorityKey: middleAuthority,
                chainPath: middleConfiguration.chainPath
            )
            try await VolumeImpl<Transaction>(node: leafAuthorization).storeRecursively(
                storer: upstream
            )
            let middleBlock = try await BlockBuilder.buildChildGenesis(
                spec: NexusGenesis.spec.withParentWorkAuthorityKey(upstreamAuthority),
                parentState: upstreamGenesis.postState,
                transactions: [leafAuthorization],
                children: ["Receipts": leafBlock],
                timestamp: timestamp + 1,
                target: middleTarget,
                fetcher: upstream
            )
            let middleHeader = try BlockHeader(node: middleBlock)
            try await middleHeader.storeBlock(fetcher: upstream, storer: upstream)

            let middleAuthorization = try signedGenesisAuthorization(
                directory: "Payments",
                childGenesisCID: middleHeader.rawCID,
                parentWorkAuthorityKey: upstreamAuthority,
                chainPath: upstreamConfiguration.chainPath
            )
            try await VolumeImpl<Transaction>(node: middleAuthorization).storeRecursively(
                storer: upstream
            )
            let rootCandidate = try await BlockBuilder.buildBlock(
                previous: upstreamGenesis,
                transactions: [middleAuthorization],
                children: ["Payments": middleBlock],
                timestamp: timestamp + 2,
                nonce: 0,
                fetcher: upstream
            )
            guard let root = BlockBuilder.mine(
                block: rootCandidate,
                target: leafTarget,
                maxAttempts: 10_000
            ) else {
                throw NetworkTestError.failedStart
            }
            _ = try await upstream.prepareChildProofs(for: root, capacity: 16)
            return NetworkHierarchyBranch(
                rootHeader: try BlockHeader(node: root),
                middle: middleBlock,
                middleHeader: middleHeader,
                leaf: leafBlock,
                leafHeader: leafHeader
            )
        }

        // The same physical root is normalized by max at every level. M sees
        // A=5/B=1; L sees A=6/B=4 before live parent facts arrive.
        let branchA = try await makeBranch(
            timestamp: 3_600_000,
            middleTarget: UInt256.max / UInt256(5),
            leafTarget: UInt256.max / UInt256(6)
        )
        let branchB = try await makeBranch(
            timestamp: 7_200_000,
            middleTarget: UInt256.max,
            leafTarget: UInt256.max / UInt256(4)
        )

        for branch in [branchA, branchB] {
            let outcome = try await upstream.admit(branch.rootHeader)
            XCTAssertTrue(outcome.decision.isAccepted)

            let leafEntries = try await upstream.durableCandidateEntries(
                for: branch.leaf
            )
            try await branch.middleHeader.store(
                paths: [["children", "Receipts"]: .targeted],
                storer: middle
            )
            _ = try await middle.prepareChildProofs(
                for: branch.middle,
                children: [DirectChildCandidate(
                    directory: "Receipts",
                    block: branch.leaf,
                    searchTarget: branch.leaf.target,
                    acquisitionEntries: leafEntries
                )],
                capacity: 16
            )
        }

        // A second accepted parent carrier commits to the already-known middle
        // A block, but its grind misses that child's own target. Its exact edge
        // therefore arrives later as carrier evidence rather than a new block.
        let lateAuthorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: branchA.middleHeader.rawCID,
            parentWorkAuthorityKey: upstreamAuthority,
            chainPath: upstreamConfiguration.chainPath
        )
        try await VolumeImpl<Transaction>(node: lateAuthorization).storeRecursively(
            storer: upstream
        )
        var lateRoot: Block?
        for nonce in UInt64(1)...UInt64(64) {
            let candidate = try await BlockBuilder.buildBlock(
                previous: upstreamGenesis,
                transactions: [lateAuthorization],
                children: ["Payments": branchA.middle],
                timestamp: 10_800_000,
                nonce: nonce,
                fetcher: upstream
            )
            if candidate.proofOfWorkHash() > branchA.middle.target {
                lateRoot = candidate
                break
            }
        }
        let lateRootBlock = try XCTUnwrap(lateRoot)
        let lateRootHeader = try BlockHeader(node: lateRootBlock)
        _ = try await upstream.prepareChildProofs(for: lateRootBlock, capacity: 16)
        let lateRootAdmission = try await upstream.admit(lateRootHeader)
        XCTAssertTrue(lateRootAdmission.decision.isAccepted)

        let middlePackageA = try await networkChildPackage(
            parent: upstream,
            carrierCID: branchA.rootHeader.rawCID,
            rootCID: branchA.rootHeader.rawCID,
            directory: "Payments",
            childCID: branchA.middleHeader.rawCID
        )
        let middlePackageB = try await networkChildPackage(
            parent: upstream,
            carrierCID: branchB.rootHeader.rawCID,
            rootCID: branchB.rootHeader.rawCID,
            directory: "Payments",
            childCID: branchB.middleHeader.rawCID
        )
        let lateMiddlePackage = try await networkChildPackage(
            parent: upstream,
            carrierCID: lateRootHeader.rawCID,
            rootCID: lateRootHeader.rawCID,
            directory: "Payments",
            childCID: branchA.middleHeader.rawCID
        )
        let middleAAdmission = try await middle.admit(
            branchA.middleHeader,
            authenticatedChildPackage: middlePackageA
        )
        guard case .canonicalized = middleAAdmission.decision else {
            XCTFail("expected canonical middle A, got \(middleAAdmission.decision)")
            throw NetworkTestError.failedStart
        }
        let middleBAdmission = try await middle.admit(
            branchB.middleHeader,
            authenticatedChildPackage: middlePackageB
        )
        guard case .acceptedSide = middleBAdmission.decision else {
            XCTFail("expected side middle B, got \(middleBAdmission.decision)")
            throw NetworkTestError.failedStart
        }

        let leafPackageA = try await networkChildPackage(
            parent: middle,
            carrierCID: branchA.middleHeader.rawCID,
            rootCID: branchA.rootHeader.rawCID,
            directory: "Receipts",
            childCID: branchA.leafHeader.rawCID
        )
        let leafPackageB = try await networkChildPackage(
            parent: middle,
            carrierCID: branchB.middleHeader.rawCID,
            rootCID: branchB.rootHeader.rawCID,
            directory: "Receipts",
            childCID: branchB.leafHeader.rawCID
        )
        let leafAAdmission = try await leaf.admit(
            branchA.leafHeader,
            authenticatedChildPackage: leafPackageA
        )
        guard case .canonicalized = leafAAdmission.decision else {
            XCTFail("expected canonical leaf A, got \(leafAAdmission.decision)")
            throw NetworkTestError.failedStart
        }
        let leafBAdmission = try await leaf.admit(
            branchB.leafHeader,
            authenticatedChildPackage: leafPackageB
        )
        guard case .acceptedSide = leafBAdmission.decision else {
            XCTFail("expected side leaf B, got \(leafBAdmission.decision)")
            throw NetworkTestError.failedStart
        }

        let initialExportOptional = await middle.parentSecuringWorkSnapshot()
        let initialExport = try XCTUnwrap(initialExportOptional)
        XCTAssertEqual(
            initialExport.sourceWork(forBlock: branchA.middleHeader.rawCID)
                .work(forGrind: branchA.rootHeader.rawCID),
            UInt256(5)
        )
        XCTAssertEqual(
            initialExport.sourceWork(forBlock: branchB.middleHeader.rawCID)
                .work(forGrind: branchB.rootHeader.rawCID),
            UInt256(1)
        )
        let initialMiddleStatus = await middle.status()
        let initialLeafStatus = await leaf.status()
        XCTAssertEqual(initialMiddleStatus.tipCID, branchA.middleHeader.rawCID)
        XCTAssertEqual(initialLeafStatus.tipCID, branchA.leafHeader.rawCID)

        func waitForTip(
            _ process: ChainProcess,
            _ expected: String
        ) async throws {
            for _ in 0..<200 {
                if await process.status().tipCID == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedStart
        }

        func waitForLeafDeliveries(_ count: Int) async throws {
            for _ in 0..<200 {
                if await leafDeliveries.snapshot().count >= count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("leaf deliveries \(count)")
        }

        func waitForQuietLeafDeliveries() async throws -> Int {
            var count = await leafDeliveries.snapshot().count
            var quietSamples = 0
            for _ in 0..<200 where quietSamples < 15 {
                try await Task.sleep(for: .milliseconds(20))
                let next = await leafDeliveries.snapshot().count
                if next == count {
                    quietSamples += 1
                } else {
                    count = next
                    quietSamples = 0
                }
            }
            guard quietSamples == 15 else {
                throw NetworkTestError.failedPhase("quiet leaf deliveries")
            }
            return count
        }

        func waitForMiddleCommits(_ count: Int) async throws {
            for _ in 0..<200 {
                if await middleCommits.snapshot().count >= count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("middle commits \(count)")
        }

        func send(
            _ payload: Data,
            from parent: Ivy,
            to child: PeerID
        ) async throws {
            while true {
                switch await parent.sendMessage(
                    to: child,
                    topic: NodeNetworkTopic.inheritedWorkPush,
                    payload: payload
                ) {
                case .enqueued:
                    return
                case .backpressured:
                    guard await parent.waitUntilWritable(to: child) else {
                        throw NetworkTestError.failedSend
                    }
                case .locallyRejected, .notConnected:
                    throw NetworkTestError.failedSend
                }
            }
        }

        let upstreamIvy = Ivy(config: IvyConfig(
            signingKey: upstreamConfiguration.signingKey,
            listenPort: upstreamFactPort,
            stunServers: [],
            mode: .privateNetwork
        ))
        do {
            try await upstreamIvy.start()
            try await middleRuntime.start(process: middle)
            let middlePeer = PeerID(publicKey: middleConfiguration.processPublicKey)
            for _ in 0..<200 {
                if (await upstreamIvy.connectedPeers).contains(middlePeer) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (await upstreamIvy.connectedPeers).contains(middlePeer) else {
                throw NetworkTestError.failedStart
            }
            guard case .enqueued = await upstreamIvy.sendMessage(
                to: middlePeer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: try ChainHello(
                    nexusGenesisCID: middleConfiguration.nexusGenesisCID,
                    chainPath: upstreamConfiguration.chainPath,
                    minimumRootWorkHex: upstreamConfiguration.minimumRootWork.toHexString()
                ).encode()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await send(
                InheritedWorkPushMessage(
                    snapshot: InheritedWorkSnapshot(revision: 1, facts: [])
                ).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )

            try await leafRuntime.start(process: leaf)
            try await waitForLeafDeliveries(1)
            try await waitForTip(leaf, branchA.leafHeader.rawCID)
            // Hierarchy hello and evidence-index replay may each send the
            // baseline snapshot. Drain them before asserting the next frame
            // was caused by this live parent fact.
            let deliveriesBefore = try await waitForQuietLeafDeliveries()
            let readinessBeforeDelta = await middleReadiness.snapshot()
            XCTAssertEqual(readinessBeforeDelta.last, "ready")
            try await waitForTip(leaf, branchA.leafHeader.rawCID)

            let warmupGrind = inheritedWorkCID("recursive-live-parent-warmup")
            let warmup = InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    branchB.rootHeader.rawCID: WorkMeasure(contribution(
                        id: warmupGrind,
                        work: 1
                    )),
                ]
            )
            try await send(
                InheritedWorkPushMessage(
                    snapshot: warmup
                ).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )
            try await send(
                InheritedWorkPushMessage(
                    snapshot: InheritedWorkSnapshot(revision: warmup.revision, facts: [])
                ).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )
            try await waitForMiddleCommits(1)
            var recordedMiddleCommits = await middleCommits.snapshot()
            XCTAssertEqual(recordedMiddleCommits, ["false"])
            try await waitForTip(middle, branchA.middleHeader.rawCID)
            try await waitForLeafDeliveries(deliveriesBefore + 1)
            try await waitForTip(leaf, branchA.leafHeader.rawCID)
            let deliveriesAfterWarmup = try await waitForQuietLeafDeliveries()
            try await waitForTip(leaf, branchA.leafHeader.rawCID)
            let warmupReceived = await leafDeliveries.snapshot().merged
            XCTAssertEqual(
                warmupReceived.sourceWork(forBlock: branchB.middleHeader.rawCID)
                    .work(forGrind: warmupGrind),
                UInt256(1)
            )

            let reorgGrind = inheritedWorkCID("recursive-live-parent-reorg")
            let strengthening = InheritedWorkSnapshot(
                revision: 2,
                workByBlock: [
                    branchB.rootHeader.rawCID: WorkMeasure(contribution(
                        id: reorgGrind,
                        work: 2
                    )),
                ]
            )
            try await send(
                InheritedWorkPushMessage(
                    snapshot: strengthening
                ).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )
            try await send(
                InheritedWorkPushMessage(
                    snapshot: InheritedWorkSnapshot(
                        revision: strengthening.revision,
                        facts: []
                    )
                ).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )
            try await waitForMiddleCommits(2)
            recordedMiddleCommits = await middleCommits.snapshot()
            XCTAssertEqual(recordedMiddleCommits, ["false", "false"])
            try await waitForTip(middle, branchA.middleHeader.rawCID)
            try await waitForLeafDeliveries(deliveriesAfterWarmup + 1)
            try await waitForTip(leaf, branchB.leafHeader.rawCID)
            let readinessAfterDelta = await middleReadiness.snapshot()
            XCTAssertEqual(readinessAfterDelta, readinessBeforeDelta)

            let relayedOptional = await middle.parentSecuringWorkSnapshot()
            let relayed = try XCTUnwrap(relayedOptional)
            XCTAssertNil(
                relayed.sourceWork(forBlock: branchA.middleHeader.rawCID)
                    .work(forGrind: warmupGrind)
            )
            XCTAssertNil(
                relayed.sourceWork(forBlock: branchA.middleHeader.rawCID)
                    .work(forGrind: reorgGrind)
            )
            XCTAssertEqual(
                relayed.sourceWork(forBlock: branchB.middleHeader.rawCID)
                    .work(forGrind: warmupGrind),
                UInt256(1)
            )
            XCTAssertEqual(
                relayed.sourceWork(forBlock: branchB.middleHeader.rawCID)
                    .work(forGrind: reorgGrind),
                UInt256(2)
            )
            let received = await leafDeliveries.snapshot().merged
            XCTAssertNil(
                received.sourceWork(forBlock: branchA.middleHeader.rawCID)
                    .work(forGrind: warmupGrind)
            )
            XCTAssertNil(
                received.sourceWork(forBlock: branchA.middleHeader.rawCID)
                    .work(forGrind: reorgGrind)
            )
            XCTAssertEqual(
                received.sourceWork(forBlock: branchB.middleHeader.rawCID)
                    .work(forGrind: warmupGrind),
                UInt256(1)
            )
            XCTAssertEqual(
                received.sourceWork(forBlock: branchB.middleHeader.rawCID)
                    .work(forGrind: reorgGrind),
                UInt256(2)
            )

            let deliveriesBeforeLateEdge = try await waitForQuietLeafDeliveries()
            let lateWork = InheritedWorkSnapshot(
                revision: 3,
                workByBlock: [
                    lateRootHeader.rawCID: WorkMeasure(contribution(
                        id: lateRootHeader.rawCID,
                        work: 4
                    )),
                ]
            )
            try await send(
                InheritedWorkPushMessage(snapshot: lateWork).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )
            try await send(
                InheritedWorkPushMessage(snapshot: InheritedWorkSnapshot(
                    revision: lateWork.revision,
                    facts: []
                )).encoded(),
                from: upstreamIvy,
                to: middlePeer
            )
            for _ in 0..<200 {
                if await middle.status().parentWorkRevision == lateWork.revision {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let lateMiddleStatus = await middle.status()
            XCTAssertEqual(lateMiddleStatus.parentWorkRevision, lateWork.revision)
            let beforeLateEdgeExport = await middle.parentSecuringWorkSnapshot()
            XCTAssertNil(
                beforeLateEdgeExport?
                    .sourceWork(forBlock: branchA.middleHeader.rawCID)
                    .work(forGrind: lateRootHeader.rawCID)
            )

            let lateEdge = try await middleService.admitNetworkCandidate(
                branchA.middleHeader,
                authenticatedChildPackage: lateMiddlePackage,
                preparingChildDirectories: []
            )
            XCTAssertEqual(lateEdge.decision, .carrier)
            XCTAssertTrue(lateEdge.inheritedWorkChanged)
            try await waitForLeafDeliveries(deliveriesBeforeLateEdge + 1)
            let lateReceived = await leafDeliveries.snapshot().merged
            XCTAssertEqual(
                lateReceived.sourceWork(forBlock: branchA.middleHeader.rawCID)
                    .work(forGrind: lateRootHeader.rawCID),
                UInt256(4)
            )
            try await waitForTip(middle, branchA.middleHeader.rawCID)
            try await waitForTip(leaf, branchA.leafHeader.rawCID)

            await upstreamIvy.stop()
            for _ in 0..<200 {
                let middleEvents = await middleReadiness.snapshot()
                let leafEvents = await leafReadiness.snapshot()
                if middleEvents.last == "not-ready",
                   leafEvents.last == "not-ready" {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let revokedMiddle = await middleReadiness.snapshot()
            let revokedLeaf = await leafReadiness.snapshot()
            XCTAssertEqual(revokedMiddle.last, "not-ready")
            XCTAssertEqual(revokedLeaf.last, "not-ready")
        } catch {
            await leafRuntime.stop()
            await middleRuntime.stop()
            await upstreamIvy.stop()
            throw error
        }
        await leafRuntime.stop()
        await middleRuntime.stop()
        await upstreamIvy.stop()
    }

    func testConcurrentSameCarrierRequestsRetainProvisionalRootUntilBothFinish()
        async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x81)
        let gate = CandidateBuildGate()

        do {
            try await fixture.parentRuntime.start(process: fixture.parentProcess)
            try await fixture.childRuntime.start(process: fixture.childProcess)
            try await waitForChildCandidate(fixture)
            let parentContent = await fixture.parentProcess.content([fixture.rootCID])
            let childContent = await fixture.childProcess.content([fixture.rootCID])
            XCTAssertNil(parentContent[fixture.rootCID])
            XCTAssertNil(childContent[fixture.rootCID])
            await fixture.childRuntime.installChildCandidateBuilder { context in
                _ = await gate.enter()
                let entries = await fixture.childRuntime.hierarchyContentSource.fetch(
                    [fixture.nestedCID]
                )
                guard entries[fixture.nestedCID] == fixture.nestedData,
                      context.parentCarrier.toData() == fixture.context.parentCarrier.toData()
                else { return nil }
                return fixture.candidate
            }

            let first = Task {
                await fixture.parentRuntime.directChildCandidates(fixture.context)
            }
            try await waitForBuilds(gate, count: 1)
            let second = Task {
                await fixture.parentRuntime.directChildCandidates(fixture.context)
            }
            try await waitForBuilds(gate, count: 2)

            await gate.release(1)
            let firstCandidates = await first.value
            XCTAssertEqual(firstCandidates.count, 1)
            await gate.release(2)
            let secondCandidates = await second.value
            XCTAssertEqual(secondCandidates.count, 1)
        } catch {
            await gate.releaseAll()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testRealNetworkRuntimeStartsStopsAndRestartsBothPlanes() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5b", count: 32)
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )

        do {
            do {
                try await runtime.start(process: process)
                XCTFail("a runtime without service ingress must not start")
            } catch {
                XCTAssertEqual(
                    error as? NodeNetworkRuntimeError,
                    .missingIngressHandler
                )
            }
            await runtime.installAdmissionHandler { _, _, _ in
                throw CancellationError()
            }

            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }

            var startOutcomes: [NetworkRuntimeStartOutcome] = []
            await withTaskGroup(of: NetworkRuntimeStartOutcome.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await runtime.start(process: process)
                            return .started
                        } catch let error as NodeNetworkRuntimeError {
                            return .failed(error)
                        } catch {
                            return .unexpected(String(describing: error))
                        }
                    }
                }
                for await outcome in group { startOutcomes.append(outcome) }
            }
            XCTAssertEqual(startOutcomes.filter { $0 == .started }.count, 1)
            XCTAssertEqual(
                startOutcomes.filter { $0 == .failed(.alreadyRunning) }.count,
                1
            )
            try await runtime.canonicalTipDidChange()

            await runtime.stop()
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
            await runtime.stop()

            try await runtime.start(process: process)
            try await runtime.canonicalTipDidChange()
            await runtime.stop()

            let starting = await runtime.enqueueStart(process: process)
            await runtime.stop()
            try await starting.value
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("stop queued during start must leave the runtime stopped")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func provisionalRootFixture(
        keyByte: UInt8
    ) async throws -> ProvisionalRootFixture {
        let parentStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-provisional-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let childStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-provisional-child-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: parentStorage)
            try? FileManager.default.removeItem(at: childStorage)
        }
        let parentConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: parentStorage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let childConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: childStorage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte &+ 1),
                count: 32
            ),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: parentConfiguration.factListenPort
            )
        )
        let parentRuntime = try NodeNetworkRuntime(configuration: parentConfiguration)
        let childRuntime = try NodeNetworkRuntime(configuration: childConfiguration)
        let parentProcess = try await ChainProcess.open(
            configuration: parentConfiguration,
            remoteSource: parentRuntime.remoteContentSource
        )
        let childProcess = try await ChainProcess.open(
            configuration: childConfiguration,
            remoteSource: childRuntime.remoteContentSource
        )
        await parentRuntime.installAdmissionHandler { _, _, _ in
            throw CancellationError()
        }
        await childRuntime.installAdmissionHandler { _, _, _ in
            throw CancellationError()
        }

        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parentConfiguration.processPublicKey)
        )
        let parentGenesis = try await parentProcess.canonicalTipBlock()
        let timestamp = parentGenesis.timestamp + 3_600_000
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: parentGenesis.postState,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: parentProcess
        )
        let childHeader = try BlockHeader(node: childGenesis)
        let authorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID,
            parentWorkAuthorityKey: parentAuthority,
            chainPath: parentConfiguration.chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parentProcess
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            children: ["Payments": childGenesis],
            timestamp: timestamp,
            nonce: 1,
            fetcher: parentProcess
        )
        _ = try await parentProcess.prepareChildProofs(for: carrier, capacity: 16)
        let carrierHeader = try BlockHeader(node: carrier)
        let carrierAdmission = try await parentProcess.admit(carrierHeader)
        XCTAssertTrue(carrierAdmission.decision.isAccepted)

        let provisional = try await BlockBuilder.buildBlock(
            previous: carrier,
            timestamp: timestamp + 3_600_000,
            nonce: 2,
            fetcher: parentProcess
        )
        let provisionalCID = try BlockHeader(node: provisional).rawCID
        let carrierContent = await parentProcess.content([carrierHeader.rawCID])
        let nestedData = try XCTUnwrap(carrierContent[carrierHeader.rawCID])
        let childData = try XCTUnwrap(childGenesis.toData())
        return ProvisionalRootFixture(
            parentRuntime: parentRuntime,
            childRuntime: childRuntime,
            parentProcess: parentProcess,
            childProcess: childProcess,
            context: ChildCandidateRequestContext(
                parentCarrier: provisional,
                rewards: []
            ),
            candidate: DirectChildCandidate(
                directory: "Payments",
                block: childGenesis,
                searchTarget: childGenesis.target,
                acquisitionEntries: [childHeader.rawCID: childData]
            ),
            rootCID: provisionalCID,
            nestedCID: carrierHeader.rawCID,
            nestedData: nestedData
        )
    }

    private func waitForChildCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws {
        await fixture.childRuntime.installChildCandidateBuilder { _ in
            fixture.candidate
        }
        for _ in 0..<250 {
            if await fixture.parentRuntime.directChildCandidates(fixture.context).count == 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkTestError.failedPhase("direct child candidate session")
    }

    private func waitForBuilds(
        _ gate: CandidateBuildGate,
        count: Int
    ) async throws {
        for _ in 0..<250 {
            if await gate.enteredCount() >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkTestError.failedPhase("provisional child candidate build")
    }

    private func networkChildGenesisCandidate(
        parentAuthority: ParentWorkAuthorityKey,
        timestamp: Int64,
        source: NetworkTestContentStore
    ) async throws -> NetworkChildGenesisCandidate {
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: source
        )
        let header = try BlockHeader(node: child)
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: timestamp + 1,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source as any Storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        let collector = NetworkTestContentStore()
        try await header.storeBlock(fetcher: source, storer: collector)
        var entries = await collector.allEntries()
        entries[carrierHeader.rawCID] = try XCTUnwrap(carrier.toData())
        return NetworkChildGenesisCandidate(
            header: header,
            package: AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentCarrierLink: try carrierLink(
                        parentPath: ["Nexus"],
                        carrierCID: carrierHeader.rawCID,
                        rootCID: carrierHeader.rawCID
                    ),
                    parentGenesisLink: try genesisLink(
                        parentPath: ["Nexus"],
                        directory: "Payments",
                        cid: header.rawCID,
                        parentWorkAuthorityKey: parentAuthority
                    )
                ),
                acquisitionEntries: entries
            )
        )
    }

    private func envelope(parentPath: [String]) throws -> ChildValidationPackageEnvelope {
        try ChildValidationPackageEnvelope(ChildValidationPackage(
            proof: proof(),
            parentCarrierLink: try carrierLink(
                parentPath: parentPath, carrierCID: "carrier", rootCID: "root"
            ),
            parentGenesisLink: try genesisLink(
                parentPath: parentPath, directory: "Payments", cid: "child-genesis"
            )
        ))
    }

    private func proof() -> ChildBlockProof {
        ChildBlockProof(
            rootCID: "proof-root",
            directoryPath: ["Payments"],
            entries: []
        )
    }

    private func canonicalNetworkBlock() async throws -> Block {
        let process = try await canonicalNetworkProcess()
        return try await process.canonicalTipBlock()
    }

    private func canonicalNetworkBlockVolumes(
        count: Int
    ) async throws -> [SerializedVolume] {
        let process = try await canonicalNetworkProcess()
        var previous = try await process.canonicalTipBlock()
        var volumes: [SerializedVolume] = []
        for step in 1...count {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: Int64(step),
                nonce: UInt64(step),
                fetcher: process
            )
            let header = try BlockHeader(node: block)
            try await header.storeBlock(fetcher: process, storer: process)
            let volume = await process.volume(header.rawCID)
            volumes.append(try XCTUnwrap(volume))
            previous = block
        }
        return volumes
    }

    private func canonicalNetworkProcess() async throws -> ChainProcess {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-block-\(UUID().uuidString)",
            isDirectory: true
        )
        return try await ChainProcess.open(configuration: try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5a", count: 32)
        ))
    }

    private func unsignedTransaction(path: [String]) throws -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: path
        )
        return Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )
    }

    private func wirePath(encodedContribution: Int) -> [String] {
        // Every component contributes a two-byte length and its UTF-8 bytes.
        // "Nexus" is fixed, and an absolute path needs at least one child.
        var remaining = encodedContribution - 7
        var contributions: [Int] = []
        while remaining > Int(UInt16.max) + 2 {
            contributions.append(Int(UInt16.max) + 2)
            remaining -= Int(UInt16.max) + 2
        }
        if remaining >= 3 {
            contributions.append(remaining)
        } else {
            precondition(!contributions.isEmpty)
            contributions[contributions.count - 1] -= 3 - remaining
            contributions.append(3)
        }
        return ["Nexus"] + contributions.map {
            String(repeating: "x", count: $0 - 2)
        }
    }

    private func networkService(
        process: ChainProcess,
        runtime: NodeNetworkRuntime
    ) -> ChainService {
        ChainService(
            process: process,
            childCandidateProvider: { [weak runtime] context in
                guard let runtime else { return [] }
                return await runtime.directChildCandidates(context)
            },
            childProofPublisher: { [weak runtime] publication in
                guard let runtime else { throw CancellationError() }
                _ = try await runtime.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    child: publication.childBlock
                )
            },
            acceptedBlockPublisher: { [weak runtime] blockCID in
                guard let runtime else { throw CancellationError() }
                try await runtime.publishAcceptedBlock(blockCID)
            },
            acceptedTransactionPublisher: { [weak runtime] rootCID in
                guard let runtime else { throw CancellationError() }
                try await runtime.publishTransaction(rootCID)
            }
        )
    }

    private func installTransactionService(
        _ service: ChainService,
        on runtime: NodeNetworkRuntime,
        inventoryRequests: NetworkEventRecorder? = nil,
        transactions: NetworkEventRecorder? = nil
    ) async {
        await runtime.installAdmissionHandler {
            [weak service] header,
            package,
            directories in
            guard let service else { throw CancellationError() }
            return try await service.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        await runtime.installInheritedWorkHandler { [weak service] snapshot, key in
            guard let service else { throw CancellationError() }
            return try await service.applyInheritedWorkSnapshot(
                snapshot,
                from: key
            )
        }
        await runtime.installTransactionHandler { [weak service] transaction in
            guard let service else { throw CancellationError() }
            await transactions?.append("attempt")
            let inserted = try await service.submitNetworkTransaction(transaction)
            await transactions?.append("accepted")
            return inserted
        }
        await runtime.installTransactionInventoryProvider { [weak service] in
            guard let service else { return [] }
            await inventoryRequests?.append("request")
            return await service.transactionInventoryRoots()
        }
    }

    private func waitForTopic(
        _ topic: String,
        in recorder: TopicRecorder
    ) async throws {
        for _ in 0..<200 {
            if await recorder.contains(topic) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase("topic \(topic)")
    }

    private func waitForEvent(
        in recorder: NetworkEventRecorder,
        phase: String = "transaction inventory request",
        attempts: Int = 200
    ) async throws {
        try await waitForEventCount(
            1,
            in: recorder,
            phase: phase,
            attempts: attempts
        )
    }

    private func waitForEventCount(
        _ count: Int,
        in recorder: NetworkEventRecorder,
        phase: String = "transaction inventory request",
        attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if (await recorder.snapshot()).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase(phase)
    }

    private func waitForMempoolCount(
        _ count: Int,
        service: ChainService,
        phase: String = "transaction mempool"
    ) async throws {
        for _ in 0..<2_000 {
            if await service.status().mempoolCount == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase(phase)
    }

    private func signedNetworkTransaction(chainPath: [String]) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        let header = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(
            bodyHeader: header,
            privateKeyHex: key.privateKey
        ) else { throw NetworkTestError.failedStart }
        return Transaction(
            signatures: [key.publicKey: signature],
            body: header
        )
    }

    private func transactionVolume(
        _ transaction: Transaction
    ) async throws -> SerializedVolume {
        let store = NetworkTestContentStore()
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.storeRecursively(storer: store)
        let serialized = SerializedVolume(
            root: volume.rawCID,
            entries: await store.allEntries()
        )
        try serialized.validate()
        return serialized
    }

    private func signedGenesisAuthorization(
        directory: String,
        childGenesisCID: String,
        parentWorkAuthorityKey: ParentWorkAuthorityKey,
        chainPath: [String]
    ) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: directory,
                blockCID: childGenesisCID,
                parentWorkAuthorityKey: parentWorkAuthorityKey
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(
            bodyHeader: bodyHeader,
            privateKeyHex: key.privateKey
        ) else {
            throw NetworkTestError.failedStart
        }
        return Transaction(
            signatures: [key.publicKey: signature],
            body: bodyHeader
        )
    }

    private func networkChildPackage(
        parent: ChainProcess,
        carrierCID: String,
        rootCID: String,
        directory: String,
        childCID: String
    ) async throws -> AuthenticatedChildPackage {
        guard let carrierLink = try await parent.issuedParentCarrierLink(
            carrierCID: carrierCID,
            rootCID: rootCID
        ), let genesisLink = try await parent.issuedParentGenesisLink(
            directory: directory,
            childGenesisCID: childCID
        ) else {
            throw NetworkTestError.failedStart
        }
        let proofs = try await parent.durableDirectChildProofs(
            carrierCID: carrierCID,
            rootCID: rootCID
        )
        guard let proof = proofs.first(where: {
            $0.directory == directory && $0.childCID == childCID
        }) else {
            throw NetworkTestError.failedStart
        }
        return AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof.proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: genesisLink
            ),
            acquisitionEntries: proof.acquisitionEntries
        )
    }

    private func pendingSideCarrierFixture(
        keyByte: UInt8,
        rejectAvailability: Bool
    ) async throws -> PendingSideCarrierFixture {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-pending-side-proof-\(UUID().uuidString)",
            isDirectory: true
        )
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let childKey = signingKey(keyByte &+ 1)
        let hierarchyTally = rejectAvailability
            ? TallyConfig(
                perPeerRequestCapacity: 8,
                perPeerRequestRefillPerSecond: 0
            )
            : .default
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    stunServers: [],
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    tallyConfig: hierarchyTally,
                    requestTimeout: .milliseconds(200),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    privateContentExchangeEnabled: true,
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        await runtime.installAdmissionHandler { _, _, _ in
            NodeAdmissionOutcome(
                decision: .duplicate,
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }

        let genesis = try await process.canonicalTipBlock()
        var canonical = genesis
        for step in 1...3 {
            canonical = try await BlockBuilder.buildBlock(
                previous: canonical,
                timestamp: Int64(step * 3_600_000),
                nonce: UInt64(step),
                fetcher: process
            )
            let outcome = try await process.admit(BlockHeader(node: canonical))
            guard outcome.decision.isAccepted else {
                throw NetworkTestError.failedPhase("canonical fixture branch")
            }
        }
        let canonicalTipCID = try BlockHeader(node: canonical).rawCID

        let sidePredecessor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 3_600_000,
            nonce: 100,
            fetcher: process
        )
        let sidePredecessorHeader = try BlockHeader(node: sidePredecessor)
        let sidePredecessorOutcome = try await process.admit(sidePredecessorHeader)
        guard case .acceptedSide = sidePredecessorOutcome.decision else {
            throw NetworkTestError.failedPhase("side fixture predecessor")
        }

        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(configuration.processPublicKey)
        )
        let childBlock = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: sidePredecessor.postState,
            timestamp: 7_200_000,
            target: UInt256.max,
            fetcher: process
        )
        let childHeader = try BlockHeader(node: childBlock)
        let authorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID,
            parentWorkAuthorityKey: parentAuthority,
            chainPath: configuration.chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: sidePredecessor,
            transactions: [authorization],
            children: ["Payments": childBlock],
            timestamp: 7_200_000,
            nonce: 101,
            fetcher: process
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let remoteContent = NetworkTestContentStore()
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: process
        )
        var remoteEntries = Dictionary(
            proof.entries.map { ($0.cid, $0.data) },
            uniquingKeysWith: { first, _ in first }
        )
        remoteEntries.merge(
            try await process.durableCandidateEntries(for: childBlock)
        ) { existing, _ in existing }
        await remoteContent.store(entries: remoteEntries)
        try await childHeader.storeBlock(
            fetcher: process,
            storer: remoteContent
        )
        try await carrierHeader.storeBlock(
            fetcher: process,
            storer: remoteContent
        )
        try await carrierHeader.storeBlock(
            fetcher: process,
            storer: process
        )
        let carrierOutcome = try await process.admit(
            BlockHeader(
                rawCID: carrierHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            // The child cannot authenticate until this carrier authorizes it;
            // the admission boundary must retain that new route itself.
            preparingChildDirectories: []
        )
        guard case .acceptedSide = carrierOutcome.decision,
              carrierOutcome.parentCarrierLink?.carrierCID == carrierHeader.rawCID
        else {
            throw NetworkTestError.failedPhase("pending side carrier")
        }
        guard try await process.pendingChildProofCarrierCIDs()
            == [carrierHeader.rawCID],
              try await process.issuedChildEvidenceSummaries(
                directory: "Payments",
                after: nil,
                limit: 1
              ).isEmpty,
              await process.status().tipCID == canonicalTipCID
        else {
            throw NetworkTestError.failedPhase("pending side carrier state")
        }

        let childPath = ["Nexus", "Payments"]
        let recorder = ChildEvidenceRecorder()
        let childDelegate = ChildEvidencePeer(
            recorder: recorder,
            hello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: childPath,
                minimumRootWorkHex: configuration.minimumRootWork.toHexString()
            ).encode(),
            childPath: childPath
        )
        let child = Ivy(config: IvyConfig(
            signingKey: childKey,
            listenPort: 0,
            bootstrapPeers: [PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: hierarchyPort
            )],
            requestTimeout: .milliseconds(200),
            stunServers: [],
            mode: .privateNetwork
        ))
        await child.installTestDelegate(childDelegate)
        return PendingSideCarrierFixture(
            storage: storage,
            configuration: configuration,
            runtime: runtime,
            process: process,
            child: child,
            childDelegate: childDelegate,
            recorder: recorder,
            remoteContent: remoteContent,
            canonicalTipCID: canonicalTipCID,
            carrierCID: carrierHeader.rawCID,
            childCID: childHeader.rawCID,
            childPath: childPath
        )
    }

    private func waitForEvidenceIndexes(
        _ fixture: PendingSideCarrierFixture,
        count: Int
    ) async throws {
        for _ in 0..<500 {
            if (await fixture.recorder.snapshot()).indexEntries.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase("child evidence index")
    }

    private func exposePendingCarrierContent(
        _ fixture: PendingSideCarrierFixture,
        keyByte: UInt8
    ) async throws -> Ivy {
        let provider = Ivy(config: IvyConfig(
            signingKey: signingKey(keyByte),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await provider.setContentSource(fixture.remoteContent)
        do {
            try await provider.start()
            let parentID = PeerID(
                publicKey: fixture.configuration.processPublicKey
            )
            try await provider.connect(to: PeerEndpoint(
                publicKey: fixture.configuration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.configuration.listenPort
            ))
            for _ in 0..<200 {
                if (await provider.connectedPeers).contains(parentID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard (await provider.connectedPeers).contains(parentID),
                  case .enqueued = await provider.sendMessage(
                    to: parentID,
                    topic: NodeNetworkTopic.overlayHello,
                    payload: try ChainHello(
                        nexusGenesisCID: fixture.configuration.nexusGenesisCID,
                        chainPath: fixture.configuration.chainPath,
                        minimumRootWorkHex:
                            fixture.configuration.minimumRootWork.toHexString()
                    ).encode()
                  )
            else {
                throw NetworkTestError.failedStart
            }
            return provider
        } catch {
            await provider.stop()
            throw error
        }
    }

    private func hierarchyRetryFixture(
        keyByte: UInt8,
        summary: IssuedChildEvidenceSummary?,
        withholdFirstHello: Bool = false
    ) async throws -> HierarchyRetryFixture {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-hierarchy-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        let parentKey = signingKey(keyByte)
        let parentPeerKey = peerKey(parentKey)
        let parentPort = NetworkTransportTestPorts.allocate()
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Retry"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte &+ 1),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeerKey.hex,
                host: "127.0.0.1",
                port: parentPort
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    stunServers: [],
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    bootstrapPeers: [configuration.parentEndpoint!.ivy],
                    inboundAdmissionBypassPeerKeys: [parentPeerKey],
                    tallyConfig: TallyConfig(
                        perPeerRequestCapacity: 1,
                        perPeerRequestRefillPerSecond: 5
                    ),
                    requestTimeout: .milliseconds(100),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        await runtime.installAdmissionHandler { _, _, _ in
            NodeAdmissionOutcome(
                decision: .duplicate,
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        let recorder = HierarchyRetryRecorder(
            withholdFirstHello: withholdFirstHello
        )
        let parent = Ivy(config: IvyConfig(
            signingKey: parentKey,
            listenPort: parentPort,
            stunServers: [],
            mode: .privateNetwork
        ))
        let delegate = HierarchyRetryPeer(
            recorder: recorder,
            parentHello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: ["Nexus"],
                minimumRootWorkHex: configuration.minimumRootWork.toHexString()
            ).encode(),
            summary: summary
        )
        await parent.installTestDelegate(delegate)
        return HierarchyRetryFixture(
            storage: storage,
            configuration: configuration,
            runtime: runtime,
            process: process,
            parent: parent,
            recorder: recorder,
            delegate: delegate
        )
    }

    private func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func peerKey(_ key: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    private func authenticatedPeer(
        _ key: Curve25519.Signing.PrivateKey,
        role: AuthenticatedPeerRole
    ) -> AuthenticatedPeer {
        AuthenticatedPeer(
            key: peerKey(key),
            role: role,
            route: .direct,
            metadata: PeerMetadata()
        )
    }

    private func carrierLink(
        parentPath: [String],
        carrierCID: String,
        rootCID: String
    ) throws -> ParentCarrierLink {
        struct Wire: Encodable {
            let parentPath: [String]
            let carrierCID: String
            let rootCID: String
        }
        return try JSONDecoder().decode(
            ParentCarrierLink.self,
            from: JSONEncoder().encode(Wire(
                parentPath: parentPath,
                carrierCID: carrierCID,
                rootCID: rootCID
            ))
        )
    }

    private func genesisLink(
        parentPath: [String],
        directory: String,
        cid: String,
        parentWorkAuthorityKey: ParentWorkAuthorityKey? = nil
    ) throws -> ParentGenesisLink {
        struct Wire: Encodable {
            let parentPath: [String]
            let directory: String
            let childGenesisCID: String
            let parentWorkAuthorityKey: ParentWorkAuthorityKey
        }
        return try JSONDecoder().decode(
            ParentGenesisLink.self,
            from: JSONEncoder().encode(Wire(
                parentPath: parentPath,
                directory: directory,
                childGenesisCID: cid,
                parentWorkAuthorityKey: parentWorkAuthorityKey
                    ?? Self.fixtureParentWorkAuthorityKey
            ))
        )
    }

    private func contribution(
        id: String,
        work: UInt64
    ) -> VerifiedWorkContribution {
        try! JSONDecoder().decode(
            VerifiedWorkContribution.self,
            from: Data(
                "{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8
            )
        )
    }
}
