import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

public typealias ContextualChildCandidateBuilder = @Sendable (
    _ context: ChildCandidateRequestContext,
    _ parentContentSource: any ContentSource
) async throws -> DirectChildCandidate?

public struct NetworkCandidateAdmission: Sendable {
    public let header: BlockHeader
    public let authenticatedChildPackage: AuthenticatedChildPackage?
    public let preparingChildDirectories: [String]
    public let contentSource: any ContentSource

    public init(
        header: BlockHeader,
        authenticatedChildPackage: AuthenticatedChildPackage?,
        preparingChildDirectories: [String],
        contentSource: any ContentSource
    ) {
        self.header = header
        self.authenticatedChildPackage = authenticatedChildPackage
        self.preparingChildDirectories = preparingChildDirectories
        self.contentSource = contentSource
    }
}

public typealias NetworkAdmissionHandler = @Sendable (
    _ admission: NetworkCandidateAdmission
) async throws -> NodeAdmissionOutcome

/// Service-owned reconciliation for a parent work push. The runtime owns
/// authenticated routing; the service owns template and mempool projection.
public typealias NetworkInheritedWorkHandler = @Sendable (
    _ snapshot: InheritedWorkSnapshot,
    _ sourceID: String,
    _ baseRevision: UInt64?,
    _ parentProcessKey: String
) async throws -> ChainCommit?

/// Reports that the current authenticated parent session completed and
/// durably applied a coherent work pass. This is not the parent's canonical
/// tip or fork-choice state.
public typealias NetworkParentWorkReadinessHandler = @Sendable (
    _ ready: Bool
) async -> Void

public typealias NetworkTransactionHandler = @Sendable (
    _ transaction: Transaction
) async throws -> Bool

public typealias TransactionInventoryProvider = @Sendable () async -> [String]
public typealias NetworkCandidateReservationHandler = @Sendable (
    _ candidateCIDs: [String]
) async -> Bool

/// All service callbacks used by one network-runtime generation. Supplying the
/// complete value at startup prevents a live runtime from being partially
/// wired or changing behavior beneath authenticated sessions.
public struct NodeNetworkHandlers: Sendable {
    public let childCandidateBuilder: ContextualChildCandidateBuilder?
    public let candidateReservations: NetworkCandidateReservationHandler?
    public let admission: NetworkAdmissionHandler
    public let inheritedWork: NetworkInheritedWorkHandler?
    public let parentWorkReadiness: NetworkParentWorkReadinessHandler?
    public let transaction: NetworkTransactionHandler?
    public let transactionInventory: TransactionInventoryProvider?

    public init(
        childCandidateBuilder: ContextualChildCandidateBuilder? = nil,
        candidateReservations: NetworkCandidateReservationHandler? = nil,
        admission: @escaping NetworkAdmissionHandler,
        inheritedWork: NetworkInheritedWorkHandler? = nil,
        parentWorkReadiness: NetworkParentWorkReadinessHandler? = nil,
        transaction: NetworkTransactionHandler? = nil,
        transactionInventory: TransactionInventoryProvider? = nil
    ) {
        self.childCandidateBuilder = childCandidateBuilder
        self.candidateReservations = candidateReservations
        self.admission = admission
        self.inheritedWork = inheritedWork
        self.parentWorkReadiness = parentWorkReadiness
        self.transaction = transaction
        self.transactionInventory = transactionInventory
    }
}

private enum ChildCandidateBudget {
    @TaskLocal static var deadline: ContinuousClock.Instant?
}

private final class RuntimeCallbackEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func current() -> UInt64 {
        lock.withLock { value }
    }
}

struct AcceptedLeavesCursor: Sendable, Equatable {
    let afterCID: String?
    let snapshotSequence: Int64?
}

private enum NodePolicyDecline: Error {
    case belowMinimumRootWork
    case chainSpecTooLarge
    case tooManyWasmPolicies
}

/// Pages one parent-owned fact snapshot without retaining encoded frames.
/// Oversized batches split until each canonical frame fits.
private struct InheritedWorkPushPlan: Sendable {
    let sourceID: String
    let baseRevision: UInt64?
    let revision: UInt64
    let facts: [InheritedWorkFact]
    let maximumPayloadBytes: Int

    init?(
        sourceID: String,
        export: ParentSecuringWorkExport,
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes
    ) {
        self.init(
            sourceID: sourceID,
            baseRevision: export.baseRevision,
            snapshot: export.snapshot,
            maximumPayloadBytes: maximumPayloadBytes
        )
    }

    private init?(
        sourceID: String,
        baseRevision: UInt64?,
        snapshot: InheritedWorkSnapshot,
        maximumPayloadBytes: Int
    ) {
        guard maximumPayloadBytes > 0,
              maximumPayloadBytes <= InheritedWorkPushMessage.maximumEncodedBytes,
              UUID(uuidString: sourceID) != nil,
              snapshot.hasUniqueGrindLocations else {
            return nil
        }
        self.sourceID = sourceID
        self.baseRevision = baseRevision
        revision = snapshot.revision
        facts = snapshot.facts
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    init?(
        snapshot: InheritedWorkSnapshot,
        sourceID: String = InheritedWorkPushMessage.legacySourceID,
        baseRevision: UInt64? = nil,
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes
    ) {
        self.init(
            sourceID: sourceID,
            baseRevision: baseRevision,
            snapshot: snapshot,
            maximumPayloadBytes: maximumPayloadBytes
        )
    }
}

private struct InheritedWorkPushPacker {
    enum Next {
        case payload(Data)
        case finished
        case unencodable
    }

    private let sourceID: String
    private let baseRevision: UInt64?
    private let revision: UInt64
    private let facts: [InheritedWorkFact]
    private let maximumPayloadBytes: Int
    private var factIndex = 0
    private var pending: [[InheritedWorkFact]] = []

    init(plan: InheritedWorkPushPlan) {
        sourceID = plan.sourceID
        baseRevision = plan.baseRevision
        revision = plan.revision
        facts = plan.facts
        maximumPayloadBytes = plan.maximumPayloadBytes
    }

    mutating func next() -> Next {
        while true {
            if let fragment = pending.popLast() {
                if let payload = payload(for: fragment) {
                    return .payload(payload)
                }
                guard let split = split(fragment) else { return .unencodable }
                pending.append(split.tail)
                pending.append(split.head)
                continue
            }
            guard beginNextBatch() else { return .finished }
        }
    }

    private mutating func beginNextBatch() -> Bool {
        precondition(pending.isEmpty)
        let end = min(facts.count, factIndex + InheritedWorkPushMessage.maximumFacts)
        guard factIndex < end else { return false }
        let fragment = Array(facts[factIndex..<end])
        factIndex = end
        pending.append(fragment)
        return true
    }

    private func payload(for facts: [InheritedWorkFact]) -> Data? {
        let snapshot = InheritedWorkSnapshot(revision: revision, facts: facts)
        guard let data = try? InheritedWorkPushMessage(
            sourceID: sourceID,
            baseRevision: baseRevision,
            snapshot: snapshot
        ).encoded(),
              data.count <= maximumPayloadBytes else {
            return nil
        }
        return data
    }

    private func split(
        _ facts: [InheritedWorkFact]
    ) -> (head: [InheritedWorkFact], tail: [InheritedWorkFact])? {
        guard facts.count > 1 else { return nil }
        let middle = facts.count / 2
        return (Array(facts[..<middle]), Array(facts[middle...]))
    }
}

/// A frame accepted by Ivy is ordered into that authenticated session. A local
/// admission rejection is transient (for example, Tally's token bucket), so
/// the sender must retry the exact frame rather than discard the rest of a
/// monotone export.
enum InheritedWorkPushSendResult: Sendable {
    case enqueued
    case retry
    case stopped
}

/// Atomic inherited-work state for one exact authenticated parent session.
/// A pass has one revision and becomes actionable only at its matching empty
/// marker. Equal completed revisions are valid because a child-topology change
/// can reroute new facts without mutating the parent's chain generation.
struct ParentWorkAssembler {
    enum IngestResult {
        case pending
        case completed(InheritedWorkSnapshot)
    }

    let sessionID: Data
    private(set) var completedSourceID: String?
    private(set) var completedBaseRevision: UInt64?
    private(set) var completedRevision: UInt64?
    private var pendingSourceID: String?
    private var pendingBaseRevision: UInt64?
    private var pendingRevision: UInt64?
    private var factsByGrind: [String: InheritedWorkFact] = [:]

    init(sessionID: Data) {
        self.sessionID = sessionID
    }

    mutating func ingest(_ snapshot: InheritedWorkSnapshot) -> IngestResult? {
        ingest(InheritedWorkPushMessage(snapshot: snapshot))
    }

    mutating func ingest(_ push: InheritedWorkPushMessage) -> IngestResult? {
        let snapshot = push.snapshot
        if completedSourceID == push.sourceID,
           let completedRevision,
           snapshot.revision < completedRevision {
            return nil
        }
        if let pendingRevision {
            guard pendingSourceID == push.sourceID,
                  pendingBaseRevision == push.baseRevision,
                  pendingRevision == snapshot.revision else { return nil }
        } else {
            pendingSourceID = push.sourceID
            pendingBaseRevision = push.baseRevision
            pendingRevision = snapshot.revision
        }
        if !snapshot.isEmpty {
            for fact in snapshot.facts {
                if let existing = factsByGrind[fact.grindID] {
                    guard existing.blockCID == fact.blockCID else { return nil }
                    if fact.work > existing.work {
                        factsByGrind[fact.grindID] = fact
                    }
                } else {
                    factsByGrind[fact.grindID] = fact
                }
            }
            return .pending
        }

        let completed = InheritedWorkSnapshot(
            revision: snapshot.revision,
            facts: Array(factsByGrind.values)
        )
        let sourceID = pendingSourceID!
        let baseRevision = pendingBaseRevision
        completedSourceID = sourceID
        completedBaseRevision = baseRevision
        completedRevision = snapshot.revision
        pendingSourceID = nil
        pendingBaseRevision = nil
        pendingRevision = nil
        factsByGrind.removeAll(keepingCapacity: false)
        return .completed(completed)
    }
}

public enum NodeNetworkRuntimeError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case invalidChildProof
}

struct NodeNetworkPlaneConfigurations {
    let overlay: IvyConfig
    let hierarchy: IvyConfig

    init(_ configuration: NodeConfiguration) throws {
        let parentAdmissionBypass: Set<PeerKey>
        if let parent = configuration.parentEndpoint {
            parentAdmissionBypass = [try PeerKey(parent.publicKey)]
        } else {
            parentAdmissionBypass = []
        }
        try self.init(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: configuration.listenPort,
                bootstrapPeers: configuration.bootstrapPeers,
                minPeerKeyBits: configuration.minPeerKeyBits,
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: configuration.factListenPort,
                bootstrapPeers: configuration.parentEndpoint.map { [$0.ivy] } ?? [],
                inboundAdmissionBypassPeerKeys: parentAdmissionBypass,
                maxConnections: IvyConfig.defaultMaxConnections,
                reservedOutboundConnectionSlots: configuration.parentEndpoint == nil ? 0 : 1,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                minPeerKeyBits: 0,
                relayEnabled: false,
                privateContentExchangeEnabled: true,
                carriers: [],
                mode: .privateNetwork
            )
        )
    }

    init(overlay: IvyConfig, hierarchy: IvyConfig) throws {
        guard overlay.mode == .overlay,
              hierarchy.mode == .privateNetwork,
              overlay.inboundAdmissionBypassPeerKeys.isEmpty,
            overlay.peerKey == hierarchy.peerKey
        else {
            throw IvyModeError.invalidConfiguration(
                "network runtime requires same-identity overlay and private hierarchy planes"
            )
        }
        try overlay.validate()
        try hierarchy.validate()
        self.overlay = overlay
        self.hierarchy = hierarchy
    }
}

actor ProvisionalVolumeRegistry {
    private struct Key: Hashable {
        let generation: UInt64
        let cid: String
    }

    private let broker: any VolumeBroker
    private var leases: [Key: Int] = [:]
    private var epoch: UInt64 = 0

    init(
        broker: any VolumeBroker = MemoryBroker(evictUnpinnedGrace: .zero)
    ) {
        self.broker = broker
    }

    func retain(_ volume: SerializedVolume, generation: UInt64) async -> Bool {
        let key = Key(generation: generation, cid: volume.root)
        let operationEpoch = epoch
        do {
            try await broker.store(volume: volume)
            guard epoch == operationEpoch else {
                _ = try? await broker.evictUnpinned()
                return false
            }
            try await broker.pin(
                root: volume.root,
                owner: Self.owner(generation)
            )
        } catch {
            return false
        }
        guard epoch == operationEpoch else {
            try? await broker.unpin(
                root: volume.root,
                owner: Self.owner(generation)
            )
            _ = try? await broker.evictUnpinned()
            return false
        }
        leases[key, default: 0] += 1
        return true
    }

    func release(_ cid: String, generation: UInt64) async {
        let key = Key(generation: generation, cid: cid)
        guard let count = leases[key] else { return }
        leases[key] = count == 1 ? nil : count - 1
        try? await broker.unpin(root: cid, owner: Self.owner(generation))
        if count == 1 { _ = try? await broker.evictUnpinned() }
    }

    func volume(_ cid: String, generation: UInt64) async -> SerializedVolume? {
        guard leases[Key(generation: generation, cid: cid)] != nil else {
            return nil
        }
        return await broker.fetchVolumeLocal(root: cid)
    }

    func removeAll() async {
        epoch &+= 1
        let retained = leases
        leases.removeAll()
        for (key, count) in retained {
            try? await broker.unpin(
                root: key.cid,
                owner: Self.owner(key.generation),
                count: count
            )
        }
        _ = try? await broker.evictUnpinned()
    }

    private static func owner(_ generation: UInt64) -> String {
        "runtime-provisional:\(generation)"
    }
}

/// Two deliberately separate Ivy planes for one recovered chain process.
/// The public overlay carries same-chain candidates and CAS content. The
/// private hierarchy plane carries only direct parent/child facts.
public actor NodeNetworkRuntime: IvyDelegate {
    private typealias Candidate = CandidateAcquirer.Candidate
    private typealias CandidateSeed = CandidateAcquirer.Seed
    private typealias CandidateWaitReason = CandidateAcquirer.WaitReason
    private typealias DurableDescendant = CandidateAcquirer.DurableDescendant

    enum HierarchyPeer: Equatable {
        case parent
        case child([String])
    }

    private struct PendingChildEvidenceIndex: Sendable {
        let peer: AuthenticatedPeer
        let request: ChildEvidenceIndexRequestMessage
    }

    private struct PendingPortableAttachmentIndex: Sendable {
        let peer: AuthenticatedPeer
        let request: PortableAttachmentIndexRequestMessage
    }

    private struct EvidenceVolumeLease: Hashable {
        let plane: CandidateSourcePlane
        let sessionID: Data
        let attachmentCID: String
    }

    private struct PendingAcceptedLeaves: Sendable {
        let peer: AuthenticatedPeer
        let request: AcceptedLeavesRequestMessage
        let timeout: Task<Void, Never>
    }

    private struct PendingTransactionInventory: Sendable {
        let peer: AuthenticatedPeer
        let request: TransactionInventoryRequestMessage
        let remainingRoots: Int
        let seenRoots: Set<String>
        let timeout: Task<Void, Never>
    }

    private struct TransactionVolumeLease: Hashable {
        let sessionID: Data
        let rootCID: String
    }

    private struct NextAcceptedLeaves: Sendable {
        let peer: AuthenticatedPeer
        let cursor: AcceptedLeavesCursor
    }

    private struct HelloDeadline {
        let token: UInt64
        let sessionID: Data
        let task: Task<Void, Never>
    }

    private struct PendingChildCandidateRequest {
        let peerKey: PeerKey
        let childPath: [String]
        let parentCID: String
        let continuation: CheckedContinuation<DirectChildCandidate?, Never>
    }

    private struct ChildCandidateBuild {
        let peerKey: PeerKey
        let token: UInt64
        let task: Task<Void, Never>
    }

    private struct ChildEvidenceReadyWaiter {
        let sessionID: Data
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ChildEvidenceSession: Hashable {
        let peerKey: PeerKey
        let sessionID: Data
    }

    private struct PendingCandidateReservation {
        let peer: AuthenticatedPeer
        let childPath: [String]
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct CandidateReservationAttempt: Sendable {
        let peerKey: PeerKey
        let target: Set<String>
        let accepted: Bool
    }

    private struct CandidateReservationRemovalFlush {
        let token: UInt64
        let task: Task<Void, Never>
    }

    private struct PortableEvidenceWork: Sendable {
        let summary: PortableAttachmentSummary
        let peer: AuthenticatedPeer
        let generation: UInt64
        let process: ChainProcess
    }

    private enum CandidateSourcePlane: Hashable {
        case overlay
        case hierarchy
    }

    /// Exactly one export may advance a child's cursor at a time. New parent
    /// facts only mark the current view stale; a reset cancels the task so a
    /// replacement session receives a full resend instead of an old stream's
    /// tail.
    private struct InheritedWorkPushState {
        let token: UInt64
        let generation: UInt64
        let task: Task<Void, Never>
        var needsRefresh: Bool
    }

    private struct ParentEvidenceTail {
        let token: UInt64
        let task: Task<Bool, Never>
    }

    private static let maximumPendingRequests = 1_024
    /// Each suspended hierarchy stage is capped.
    private static let maximumEvidenceCandidates = 64
    private static let maximumCandidateWaitTicks = 64
    private static let futureCandidateRetryInterval: Duration = .seconds(1)
    private static let maximumDirectChildren = 64
    private static let maximumConcurrentChildBuilds = 8
    private static let maximumPeersPerChildPath = 4
    private static let maximumReconnectEvidenceAnnouncements = 64
    private static let maximumReconnectCarrierRoots = 64
    private static let maximumConcurrentTransactionVolumes = 64
    private static let maximumTransactionInventoryRootsPerSync = 1_024
    private static let childCandidateFinalizeReserveMilliseconds: UInt64 = 100

    public nonisolated let remoteContentSource: IvyRootContentSource
    public nonisolated let hierarchyContentSource: IvyRootContentSource

    let planeConfigurations: NodeNetworkPlaneConfigurations
    let hierarchy: Ivy
    private let configuration: NodeConfiguration
    private let overlay: Ivy
    private let hello: ChainHello
    private let parentFactGate: AuthenticatedParentFactGate?

    private var lifecycleTail: Task<Void, Never>?
    /// Nonzero only while a process is the active runtime. Delegate callbacks
    /// take their stamp from `callbackEpoch`; clearing this value before either
    /// plane stops makes callbacks delivered during teardown invalid too.
    private var runtimeGeneration: UInt64 = 0
    private let callbackEpoch = RuntimeCallbackEpoch()
    private var process: ChainProcess?
    private var isRunning = false
    private var overlaySessions: [PeerKey: AuthenticatedPeer] = [:]
    private var overlayPeers: [PeerKey: AuthenticatedPeer] = [:]
    private var hierarchyPeers: [PeerKey: HierarchyPeer] = [:]
    private var hierarchySessions: [PeerKey: AuthenticatedPeer] = [:]
    /// A parent snapshot is authoritative only after its exact live session
    /// sends the ordered empty completion marker. Until then these fragments
    /// are transport state, not fork-choice input.
    private var parentWorkAssembler: ParentWorkAssembler?
    private let provisionalRoots = ProvisionalVolumeRegistry()
    private var childEvidenceReadyPeers: Set<PeerKey> = []
    private var childEvidenceReadyWaiters:
        [PeerKey: [ChildEvidenceReadyWaiter]] = [:]
    /// A final index page permits reservation cleanup only after every live
    /// publication that began before it has been ordered into the same Ivy
    /// session. Counts are session-scoped so reconnect cannot inherit a fence.
    private var childEvidenceIndexCompleteSessions: Set<ChildEvidenceSession> = []
    private var childEvidencePublicationFailedSessions: Set<ChildEvidenceSession> = []
    private var childEvidencePublicationsInFlight:
        [ChildEvidenceSession: Int] = [:]
    /// Last complete export accepted by each ready direct child session. A
    /// reconnect clears this value and receives a full monotone resend.
    private var inheritedWorkSentByChildPeer: [PeerKey: ParentWorkCursor] = [:]
    private var inheritedWorkRequestedByChildPeer: Set<PeerKey> = []
    private var inheritedWorkPushes: [PeerKey: InheritedWorkPushState] = [:]
    private var nextInheritedWorkPushToken: UInt64 = 0
    private var overlayHelloDeadlines: [PeerKey: HelloDeadline] = [:]
    private var hierarchyHelloDeadlines: [PeerKey: HelloDeadline] = [:]
    private var waitingCandidateRetryTask: Task<Void, Never>?
    private var waitingCandidateRetryGeneration: UInt64?
    private var pendingAcceptedLeaves: PendingAcceptedLeaves?
    private var pendingTransactionInventories:
        [UInt64: PendingTransactionInventory] = [:]
    private var activeTransactionVolumes = Set<TransactionVolumeLease>()
    private var nextAcceptedLeaves: NextAcceptedLeaves?
    private var acceptedLeavesQueue: [AuthenticatedPeer] = []
    private var acceptedLeavesRetryTask: Task<Void, Never>?
    private var nextAcceptedLeavesRetryToken: UInt64 = 0
    private var servingAcceptedLeaves: Set<Data> = []
    private var childProofRecoveryTask: Task<Void, Never>?
    private var childProofRecoveryGeneration: UInt64?
    private var childProofRecoveryNeedsRefresh = false
    private var candidateAcquirer = CandidateAcquirer()
    private var candidateWorker: Task<Void, Never>?
    private var candidateWorkerGeneration: UInt64?
    private var pendingEvidenceIndexes: [UInt64: PendingChildEvidenceIndex] = [:]
    private var pendingPortableAttachmentIndexes:
        [UInt64: PendingPortableAttachmentIndex] = [:]
    private var activeEvidenceVolumes = Set<EvidenceVolumeLease>()
    private var portableEvidenceOrder: [EvidenceVolumeLease] = []
    private var portableEvidenceWork:
        [EvidenceVolumeLease: PortableEvidenceWork] = [:]
    private var portableEvidenceRecycle: [PeerKey: AuthenticatedPeer] = [:]
    private var portableEvidenceWorker: Task<Void, Never>?
    /// Evidence from one exact parent session is authenticated in wire order.
    /// A later reservation request awaits the tail it observed, so cleanup can
    /// never overtake the durable handoff established by earlier evidence.
    private var parentEvidenceTails:
        [ChildEvidenceSession: ParentEvidenceTail] = [:]
    private var failedParentEvidenceSessions: Set<ChildEvidenceSession> = []
    private var activeParentCandidateReservations: Set<ChildEvidenceSession> = []
    private var parentEvidenceOperationCount = 0
    private var nextParentEvidenceToken: UInt64 = 0
    private var handlers: NodeNetworkHandlers?
    private var parentWorkReady: Bool
    private var pendingChildCandidates: [UInt64: PendingChildCandidateRequest] = [:]
    private var childCandidateBuilds: [UInt64: ChildCandidateBuild] = [:]
    private var pendingCandidateReservations:
        [UInt64: PendingCandidateReservation] = [:]
    private var desiredCandidateReservations: [PeerKey: Set<String>] = [:]
    private var dirtyCandidateReservationPeers: Set<PeerKey> = []
    private var candidateReservationReconciliationInFlight = false
    private var candidateReservationRemovalFlushes:
        [PeerKey: CandidateReservationRemovalFlush] = [:]
    private var nextCandidateReservationRemovalFlushToken: UInt64 = 0
    private var candidateReservationReconciliationWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var childPeerRotation: [String: Int] = [:]
    private var childPathRotation = 0
    private var childProofPathRotation = 0
    private var nextRequestID: UInt64 = 0
    private var nextHelloDeadlineToken: UInt64 = 0
    private var nextChildCandidateBuildToken: UInt64 = 0

    /// Callback work may outlive a stop/start boundary. Keep its captured
    /// process tied to the generation that began it, rather than letting an
    /// old continuation touch the next runtime.
    private func isCurrentRuntime(
        generation: UInt64,
        process expectedProcess: ChainProcess
    ) -> Bool {
        runtimeGeneration != 0
            && runtimeGeneration == generation
            && process === expectedProcess
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        runtimeGeneration != 0 && runtimeGeneration == generation
    }

    private func resolvedRuntimeFence(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) -> (generation: UInt64, process: ChainProcess)? {
        if let generation, let expectedProcess {
            guard
                isCurrentRuntime(
                    generation: generation,
                    process: expectedProcess
                )
            else { return nil }
            return (generation, expectedProcess)
        }
        guard generation == nil,
            expectedProcess == nil,
            runtimeGeneration != 0,
            let process
        else { return nil }
        return (runtimeGeneration, process)
    }

    public init(configuration: NodeConfiguration) throws {
        try self.init(
            configuration: configuration,
            planeConfigurations: NodeNetworkPlaneConfigurations(configuration)
        )
    }

    init(
        configuration: NodeConfiguration,
        planeConfigurations: NodeNetworkPlaneConfigurations
    ) throws {
        guard planeConfigurations.overlay.peerKey.hex == configuration.processPublicKey else {
            throw IvyModeError.invalidConfiguration(
                "network runtime plane identity must match the process identity"
            )
        }
        let expectedParentAdmissionBypass: Set<PeerKey>
        if let parent = configuration.parentEndpoint {
            expectedParentAdmissionBypass = [try PeerKey(parent.publicKey)]
        } else {
            expectedParentAdmissionBypass = []
        }
        guard planeConfigurations.hierarchy.inboundAdmissionBypassPeerKeys
            == expectedParentAdmissionBypass else {
            throw IvyModeError.invalidConfiguration(
                "hierarchy admission bypass must contain exactly the configured parent"
            )
        }
        let expectedHierarchyBootstrapPeers = configuration.parentEndpoint.map { [$0.ivy] } ?? []
        guard planeConfigurations.hierarchy.bootstrapPeers == expectedHierarchyBootstrapPeers else {
            throw IvyModeError.invalidConfiguration(
                "hierarchy bootstrap peers must contain exactly the configured parent"
            )
        }
        let overlay = Ivy(config: planeConfigurations.overlay)
        let hierarchy = Ivy(config: planeConfigurations.hierarchy)
        self.configuration = configuration
        self.planeConfigurations = planeConfigurations
        self.overlay = overlay
        self.hierarchy = hierarchy
        remoteContentSource = IvyRootContentSource(
            ivy: overlay,
            policy: configuration.resourcePolicy
        )
        hierarchyContentSource = IvyRootContentSource(
            ivy: hierarchy,
            policy: configuration.resourcePolicy
        )
        hello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath
        )
        parentFactGate = try configuration.parentEndpoint.map {
            try AuthenticatedParentFactGate(
                childPath: configuration.chainPath,
                configuredParentIvyPeerKey: $0.publicKey
            )
        }
        parentWorkReady = configuration.address.isNexus
    }

    /// Installs both delegates and the recovered process's local content source
    /// before either listener becomes visible. The private plane starts first.
    public func start(
        process: ChainProcess,
        handlers: NodeNetworkHandlers
    ) async throws {
        try await enqueueStart(process: process, handlers: handlers).value
    }

    func enqueueStart(
        process: ChainProcess,
        handlers: NodeNetworkHandlers
    ) -> Task<Void, any Error> {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.startNow(process: process, handlers: handlers)
        }
        lifecycleTail = Task { _ = try? await operation.value }
        return operation
    }

    private func startNow(
        process: ChainProcess,
        handlers: NodeNetworkHandlers
    ) async throws {
        guard !isRunning else { throw NodeNetworkRuntimeError.alreadyRunning }
        var recoveredDescendants: [String: Set<DurableDescendant>] = [:]
        for requirement in await process.unresolvedSameChainPredecessors() {
            let roots = try await process.recoveredIncomingCarrierRootCIDs(
                for: requirement.descendantCID
            )
            let descendants = roots.isEmpty
                ? [DurableDescendant(
                    blockCID: requirement.descendantCID,
                    rootCID: nil
                )]
                : roots.map {
                    DurableDescendant(
                        blockCID: requirement.descendantCID,
                        rootCID: $0
                    )
                }
            recoveredDescendants[
                requirement.predecessorCID,
                default: []
            ].formUnion(descendants)
        }
        runtimeGeneration = callbackEpoch.advance()
        self.process = process
        self.handlers = handlers
        candidateAcquirer.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks,
            durableDescendants: recoveredDescendants
        )
        if !configuration.address.isNexus {
            parentWorkReady = false
            await handlers.parentWorkReadiness?(false)
        }
        await overlay.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(process: process)
        )
        await hierarchy.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(
                process: process,
                authorizes: { [weak self] peer in
                    await self?.canServeHierarchyContent(to: peer) == true
                },
                transientRootVolume: { [weak self] rootCID in
                    await self?.provisionalVolume(forRoot: rootCID)
                }
            )
        )
        do {
            let recoveredParentCandidates =
                try await prepareParentEvidenceInbox(process: process)
            try await Self.startPlanes(
                startHierarchy: { try await self.hierarchy.start() },
                startOverlay: { try await self.overlay.start() },
                stopOverlay: { await self.overlay.stop() },
                stopHierarchy: { await self.hierarchy.stop() }
            )
            isRunning = true
            for candidate in recoveredParentCandidates {
                guard await enqueueRetainedParentCandidate(
                    candidate,
                    generation: runtimeGeneration,
                    process: process
                ) else {
                    throw NodeStoreError.corrupt(
                        "durable parent evidence could not be replayed"
                    )
                }
            }
            // A peer may complete its hello while the listeners are starting.
            // Replay inventory/index pulls after ingress becomes runnable so
            // an early response cannot be the only copy we ever request.
            restartAcceptedLeavesSync()
            await resumeAcceptedLeavesSync(
                generation: runtimeGeneration,
                process: process
            )
            if !configuration.address.isNexus {
                await requestEvidenceIndex(
                    generation: runtimeGeneration,
                    process: process
                )
            }
            scheduleChildProofRecovery(
                generation: runtimeGeneration,
                process: process
            )
        } catch {
            isRunning = false
            _ = callbackEpoch.advance()
            runtimeGeneration = 0
            await clearRuntimeState()
            throw error
        }
    }

    public func stop() async {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            await self?.stopNow()
        }
        lifecycleTail = operation
        await operation.value
    }

    private func prepareParentEvidenceInbox(
        process: ChainProcess
    ) async throws -> [CandidateSeed] {
        var candidates: [CandidateSeed] = []
        for item in try await process.parentEvidenceInbox() {
            let directHop = await item.package.package.proof.directHop()
            guard let childCID = directHop?.childCID else {
                throw NodeStoreError.corrupt(
                    "durable parent evidence could not be replayed"
                )
            }
            _ = try await process.beginContextualCandidateHandoff(
                candidateCID: childCID
            )
            candidates.append(CandidateSeed(
                blockCID: childCID,
                package: item.package
            ))
        }
        return candidates
    }

    private func enqueueRetainedParentCandidate(
        _ candidate: CandidateSeed,
        peer: AuthenticatedPeer? = nil,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        while isCurrentRuntime(generation: generation, process: process),
              peer.map({
                  hierarchySessions[$0.key]?.sessionID == $0.sessionID
                    && hierarchyPeers[$0.key] == .parent
              }) ?? true {
            if enqueueCandidate(candidate) { return true }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return false
    }

    private func stopNow() async {
        guard isRunning || process != nil else { return }
        _ = callbackEpoch.advance()
        runtimeGeneration = 0
        isRunning = false
        await Self.stopPlanes(
            stopOverlay: { await self.overlay.stop() },
            stopHierarchy: { await self.hierarchy.stop() }
        )
        await clearRuntimeState()
    }

    private func clearRuntimeState() async {
        if !configuration.address.isNexus {
            parentWorkReady = false
            await handlers?.parentWorkReadiness?(false)
        }
        process = nil
        overlaySessions.removeAll()
        overlayPeers.removeAll()
        hierarchyPeers.removeAll()
        hierarchySessions.removeAll()
        parentWorkAssembler = nil
        await provisionalRoots.removeAll()
        childEvidenceReadyPeers.removeAll()
        childEvidenceIndexCompleteSessions.removeAll()
        childEvidencePublicationFailedSessions.removeAll()
        childEvidencePublicationsInFlight.removeAll()
        let evidenceReadyWaiters = childEvidenceReadyWaiters.values.flatMap {
            $0
        }
        childEvidenceReadyWaiters.removeAll()
        for waiter in evidenceReadyWaiters {
            waiter.continuation.resume(returning: false)
        }
        inheritedWorkSentByChildPeer.removeAll()
        inheritedWorkRequestedByChildPeer.removeAll()
        for push in inheritedWorkPushes.values { push.task.cancel() }
        inheritedWorkPushes.removeAll()
        for deadline in overlayHelloDeadlines.values { deadline.task.cancel() }
        overlayHelloDeadlines.removeAll()
        for deadline in hierarchyHelloDeadlines.values { deadline.task.cancel() }
        hierarchyHelloDeadlines.removeAll()
        waitingCandidateRetryTask?.cancel()
        waitingCandidateRetryTask = nil
        waitingCandidateRetryGeneration = nil
        pendingAcceptedLeaves?.timeout.cancel()
        pendingAcceptedLeaves = nil
        for pending in pendingTransactionInventories.values {
            pending.timeout.cancel()
        }
        pendingTransactionInventories.removeAll()
        activeTransactionVolumes.removeAll()
        nextAcceptedLeaves = nil
        acceptedLeavesQueue.removeAll()
        acceptedLeavesRetryTask?.cancel()
        acceptedLeavesRetryTask = nil
        childProofRecoveryTask?.cancel()
        childProofRecoveryTask = nil
        childProofRecoveryGeneration = nil
        childProofRecoveryNeedsRefresh = false
        servingAcceptedLeaves.removeAll()
        candidateWorker?.cancel()
        candidateWorker = nil
        candidateWorkerGeneration = nil
        candidateAcquirer.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks
        )
        pendingEvidenceIndexes.removeAll()
        pendingPortableAttachmentIndexes.removeAll()
        activeEvidenceVolumes.removeAll()
        portableEvidenceWorker?.cancel()
        portableEvidenceWorker = nil
        portableEvidenceOrder.removeAll()
        portableEvidenceWork.removeAll()
        portableEvidenceRecycle.removeAll()
        for tail in parentEvidenceTails.values { tail.task.cancel() }
        parentEvidenceTails.removeAll()
        failedParentEvidenceSessions.removeAll()
        activeParentCandidateReservations.removeAll()
        parentEvidenceOperationCount = 0
        let pendingChildCandidates = Array(self.pendingChildCandidates.values)
        self.pendingChildCandidates.removeAll()
        for pending in pendingChildCandidates {
            pending.continuation.resume(returning: nil)
        }
        for build in childCandidateBuilds.values { build.task.cancel() }
        childCandidateBuilds.removeAll()
        let pendingReservations = Array(pendingCandidateReservations.values)
        pendingCandidateReservations.removeAll()
        for pending in pendingReservations {
            pending.continuation.resume(returning: false)
        }
        for flush in candidateReservationRemovalFlushes.values {
            flush.task.cancel()
        }
        candidateReservationRemovalFlushes.removeAll()
        childPeerRotation.removeAll()
        childPathRotation = 0
        childProofPathRotation = 0
        handlers = nil
    }

    public func announceBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        guard parentWorkReady else { return }
        try await announceBlock(
            blockCID,
            generation: runtimeGeneration,
            process: process
        )
    }

    private func announceBlock(
        _ blockCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async throws {
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let payload = try BlockAnnouncementMessage(blockCID: blockCID).encoded()
        for peer in overlayPeers.values {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
        }
    }

    /// Called after the process canonicalizes a new tip. Overlay peers learn
    /// the CID, and authenticated direct-child routes get a targeted proof
    /// preparation retry against that exact root.
    public func canonicalTipDidChange() async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        guard parentWorkReady else { return }
        try await canonicalTipDidChange(
            generation: runtimeGeneration,
            process: process
        )
    }

    private func canonicalTipDidChange(
        generation: UInt64,
        process: ChainProcess
    ) async throws {
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        if let tip = await process.status().tipCID {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            try await announceBlock(
                tip,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            await retryCurrentTipChildProofs(
                tipCID: tip,
                generation: generation,
                process: process
            )
        }
    }

    public func publishAcceptedBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        guard parentWorkReady else { return }
        // Every accepted branch can add inherited work for a direct child.
        // Canonicity is not a work-export filter.
        await pushInheritedWork(
            generation: generation,
            process: process
        )
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        try await announceBlock(
            blockCID,
            generation: generation,
            process: process
        )
    }

    /// Publishes generic securing work without implying that a same-chain
    /// block was accepted or became canonical.
    public func publishSecuringWork() async {
        guard isRunning, let process, parentWorkReady else { return }
        await pushInheritedWork(
            generation: runtimeGeneration,
            process: process
        )
    }

    /// Announces an already admitted complete transaction Volume to same-chain
    /// overlay peers. The process content source serves the Volume itself.
    public func publishTransaction(_ volumeRootCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        guard let payload = try? TransactionAvailableMessage(
            volumeRootCID: volumeRootCID
        ).encoded() else { return }
        for peer in overlayPeers.values {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: payload
            )
        }
    }

    /// Requests contextual templates from authenticated immediate children for
    /// one exact provisional carrier. Missing or slow children are omitted.
    public func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async -> [DirectChildCandidate] {
        guard isRunning,
            let process,
              parentWorkReady,
              context.rewards.count <= ChildCandidateRequestMessage.maximumRewards,
              let parentData = context.parentCarrier.toData(),
              let parentCID = try? BlockHeader(node: context.parentCarrier).rawCID,
            let deadline = childCandidateRequestDeadline()
        else {
            return []
        }
        let parentBoundary = try? VolumeImpl<Block>(node: context.parentCarrier)
        let provisionalBroker = MemoryBroker()
        try? await parentBoundary?.store(storer: provisionalBroker)
        guard let parentVolume = await provisionalBroker.fetchVolumeLocal(
            root: parentCID
        ), (try? parentVolume.validate()) != nil else { return [] }
        let generation = runtimeGeneration
        guard await provisionalRoots.retain(
            parentVolume,
            generation: generation
        ) else { return [] }
        let children = selectedChildPeers()

        var candidates: [(Int, DirectChildCandidate)] = []
        await withTaskGroup(of: (Int, DirectChildCandidate?).self) { group in
            for (rank, key, path) in children {
                let rewards = context.rewards.filter {
                    $0.chainPath.count >= path.count
                        && Array($0.chainPath.prefix(path.count)) == path
                }
                group.addTask {
                    let candidate = await self.requestChildCandidate(
                        from: key,
                        childPath: path,
                        parentCID: parentCID,
                        parentData: parentData,
                        rewards: rewards,
                        mode: context.mode,
                        deadline: deadline,
                        generation: generation,
                        process: process
                    )
                    return (rank, candidate)
                }
            }
            for await (rank, candidate) in group {
                if let candidate { candidates.append((rank, candidate)) }
            }
        }
        await provisionalRoots.release(parentCID, generation: generation)
        guard isCurrentRuntime(generation: generation, process: process) else {
            return []
        }

        // A path claim is not authority. Query several authenticated claimants
        // and rotate priority so a grindable lexicographic key cannot own a slot.
        var selectedDirectories: Set<String> = []
        let selected = candidates.sorted { $0.0 < $1.0 }.compactMap {
            selectedDirectories.insert($0.1.directory).inserted ? $0.1 : nil
        }
        return selected.sorted { $0.directory < $1.directory }
    }

    /// Replaces the complete bounded candidate reservation set at every exact
    /// direct-child process. Additions require a durable authenticated ack;
    /// disconnected removals are retried on the next session.
    public func reconcileChildCandidateReservations(
        _ references: [ChildCandidateReservationReference]
    ) async -> Bool {
        guard isRunning else { return references.isEmpty }
        var desired: [PeerKey: Set<String>] = [:]
        for reference in Set(references) {
            desired[reference.peerKey, default: []].insert(
                reference.candidateCID
            )
            guard desired[reference.peerKey]!.count
                    <= ChildCandidateReservationRequestMessage.maximumCandidateCIDs
            else { return false }
        }
        let currentPeers = Set(desiredCandidateReservations.keys)
            .union(desired.keys)
        let alreadyTargeted = currentPeers.allSatisfy {
            (desired[$0] ?? []) == (desiredCandidateReservations[$0] ?? [])
        }
        if !candidateReservationReconciliationInFlight,
           alreadyTargeted,
           dirtyCandidateReservationPeers.allSatisfy({
               candidateReservationRemovalFlushes[$0] != nil
           }) {
            return true
        }
        await acquireCandidateReservationReconciliation()
        defer { releaseCandidateReservationReconciliation() }
        guard isRunning, let process else { return references.isEmpty }
        let peers = Set(desiredCandidateReservations.keys)
            .union(desired.keys)
            .sorted()
        let changedPeers = peers.filter { peerKey in
            let next = desired[peerKey] ?? []
            let previous = desiredCandidateReservations[peerKey] ?? []
            return next != previous
                || dirtyCandidateReservationPeers.contains(peerKey)
        }
        let removalTargets = Dictionary(uniqueKeysWithValues:
            changedPeers.compactMap { peerKey in
                let next = desired[peerKey] ?? []
                let previous = desiredCandidateReservations[peerKey] ?? []
                return next.subtracting(previous).isEmpty
                    ? (peerKey, next)
                    : nil
            }
        )
        for (peerKey, target) in removalTargets {
            desiredCandidateReservations[peerKey] = target
            dirtyCandidateReservationPeers.insert(peerKey)
        }
        var requests: [(
            peerKey: PeerKey,
            target: Set<String>,
            childPath: [String],
            peer: AuthenticatedPeer
        )] = []
        var rejected = false
        let generation = runtimeGeneration
        for peerKey in peers {
            guard removalTargets[peerKey] == nil else { continue }
            let next = desired[peerKey] ?? []
            let previous = desiredCandidateReservations[peerKey] ?? []
            let changed = next != previous
                || dirtyCandidateReservationPeers.contains(peerKey)
            guard changed else { continue }
            if let removal = candidateReservationRemovalFlushes[peerKey] {
                await removal.task.value
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else { return references.isEmpty }
            }
            guard case .child(let childPath)? = hierarchyPeers[peerKey],
                  let peer = hierarchySessions[peerKey],
                  childEvidenceReadyPeers.contains(peerKey) else {
                if !next.subtracting(previous).isEmpty {
                    dirtyCandidateReservationPeers.insert(peerKey)
                    rejected = true
                    continue
                }
                desiredCandidateReservations[peerKey] = next
                dirtyCandidateReservationPeers.insert(peerKey)
                continue
            }
            requests.append((peerKey, next, childPath, peer))
        }
        await withTaskGroup(of: CandidateReservationAttempt.self) { group in
            for request in requests {
                group.addTask {
                    CandidateReservationAttempt(
                        peerKey: request.peerKey,
                        target: request.target,
                        accepted: await self.requestCandidateReservation(
                            candidateCIDs: request.target.sorted(),
                            childPath: request.childPath,
                            peer: request.peer,
                            generation: generation,
                            process: process
                        )
                    )
                }
            }
            for await attempt in group {
                if attempt.accepted {
                    desiredCandidateReservations[attempt.peerKey] = attempt.target
                    dirtyCandidateReservationPeers.remove(attempt.peerKey)
                } else {
                    dirtyCandidateReservationPeers.insert(attempt.peerKey)
                    rejected = true
                }
            }
        }
        for (peerKey, target) in removalTargets {
            scheduleCandidateReservationRemoval(
                peerKey: peerKey,
                target: target,
                generation: generation,
                process: process
            )
        }
        return !rejected
    }

    private func scheduleCandidateReservationRemoval(
        peerKey: PeerKey,
        target: Set<String>,
        generation: UInt64,
        process: ChainProcess
    ) {
        let previous = candidateReservationRemovalFlushes[peerKey]?.task
        nextCandidateReservationRemovalFlushToken &+= 1
        let token = nextCandidateReservationRemovalFlushToken
        let task = Task { [weak self] in
            await previous?.value
            await self?.flushCandidateReservationRemoval(
                peerKey: peerKey,
                target: target,
                token: token,
                generation: generation,
                process: process
            )
        }
        candidateReservationRemovalFlushes[peerKey] =
            CandidateReservationRemovalFlush(token: token, task: task)
    }

    private func flushCandidateReservationRemoval(
        peerKey: PeerKey,
        target: Set<String>,
        token: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer {
            if candidateReservationRemovalFlushes[peerKey]?.token == token {
                candidateReservationRemovalFlushes.removeValue(forKey: peerKey)
            }
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard desiredCandidateReservations[peerKey] == target,
              case .child(let childPath)? = hierarchyPeers[peerKey],
              let peer = hierarchySessions[peerKey],
              childEvidenceReadyPeers.contains(peerKey) else { return }
        let accepted = await requestCandidateReservation(
            candidateCIDs: target.sorted(),
            childPath: childPath,
            peer: peer,
            generation: generation,
            process: process
        )
        if accepted, desiredCandidateReservations[peerKey] == target {
            dirtyCandidateReservationPeers.remove(peerKey)
        }
    }

    private func acquireCandidateReservationReconciliation() async {
        guard candidateReservationReconciliationInFlight else {
            candidateReservationReconciliationInFlight = true
            return
        }
        await withCheckedContinuation {
            candidateReservationReconciliationWaiters.append($0)
        }
    }

    private func releaseCandidateReservationReconciliation() {
        guard !candidateReservationReconciliationWaiters.isEmpty else {
            candidateReservationReconciliationInFlight = false
            return
        }
        candidateReservationReconciliationWaiters.removeFirst().resume()
    }

    private func parentEvidenceSession(
        for peer: AuthenticatedPeer
    ) -> ChildEvidenceSession? {
        guard hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else { return nil }
        return ChildEvidenceSession(
            peerKey: peer.key,
            sessionID: peer.sessionID
        )
    }

    private func appendParentEvidence(
        _ summaries: [IssuedChildEvidenceSummary],
        sourceID: String,
        advanceScan: Bool,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> Task<Bool, Never>? {
        guard !summaries.isEmpty else { return nil }
        guard isCurrentRuntime(generation: generation, process: process),
              let session = parentEvidenceSession(for: peer),
              !failedParentEvidenceSessions.contains(session) else {
            return nil
        }
        let activePortable = activeEvidenceVolumes.lazy.filter {
            $0.plane == .overlay
        }.count
        guard parentEvidenceOperationCount + portableEvidenceWork.count
                + activePortable < Self.maximumEvidenceCandidates else {
            failedParentEvidenceSessions.insert(session)
            return nil
        }
        nextParentEvidenceToken &+= 1
        let token = nextParentEvidenceToken
        let predecessor = parentEvidenceTails[session]?.task
        parentEvidenceOperationCount += 1
        let task = Task { [weak self] in
            guard let self else { return false }
            let predecessorHandled = if let predecessor {
                await predecessor.value
            } else {
                true
            }
            var handled = predecessorHandled && !Task.isCancelled
            for summary in summaries where handled {
                handled = await self.recoverParentEvidence(
                    summary,
                    sourceID: sourceID,
                    advanceScan: advanceScan,
                    from: peer,
                    generation: generation,
                    process: process
                )
            }
            await self.finishParentEvidence(
                session: session,
                token: token,
                handled: handled,
                peer: peer,
                generation: generation,
                process: process
            )
            return handled
        }
        parentEvidenceTails[session] = ParentEvidenceTail(
            token: token,
            task: task
        )
        return task
    }

    private func finishParentEvidence(
        session: ChildEvidenceSession,
        token: UInt64,
        handled: Bool,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        parentEvidenceOperationCount -= 1
        if parentEvidenceTails[session]?.token == token {
            parentEvidenceTails.removeValue(forKey: session)
        }
        guard parentEvidenceSession(for: peer) == session else { return }
        if !handled {
            failedParentEvidenceSessions.insert(session)
            await hierarchy.recycleSession(ifCurrent: peer)
        }
    }

    private func respondToCandidateReservation(
        _ request: ChildCandidateReservationRequestMessage,
        from peer: AuthenticatedPeer,
        session: ChildEvidenceSession,
        after evidenceTail: Task<Bool, Never>?,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer { activeParentCandidateReservations.remove(session) }
        let evidenceHandled = await evidenceTail?.value ?? true
        guard evidenceHandled,
              isCurrentRuntime(generation: generation, process: process),
              parentEvidenceSession(for: peer) == session,
              !failedParentEvidenceSessions.contains(session) else {
            await hierarchy.recycleSession(ifCurrent: peer)
            return
        }
        let accepted = await handlers?.candidateReservations?(
            request.candidateCIDs
        ) ?? false
        guard isCurrentRuntime(generation: generation, process: process),
              parentEvidenceSession(for: peer) == session,
              let payload = try? ChildCandidateReservationResponseMessage(
                requestID: request.requestID,
                childPath: request.childPath,
                accepted: accepted
              ).encoded() else { return }
        _ = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childCandidateReservationResponse,
            payload: payload
        )
    }

    private func cancelParentEvidence(for key: PeerKey) {
        let sessions = parentEvidenceTails.keys.filter { $0.peerKey == key }
        for session in sessions {
            parentEvidenceTails.removeValue(forKey: session)?.task.cancel()
        }
        failedParentEvidenceSessions = failedParentEvidenceSessions.filter {
            $0.peerKey != key
        }
        activeParentCandidateReservations =
            activeParentCandidateReservations.filter { $0.peerKey != key }
    }

    private func waitForChildEvidenceReady(
        peer: AuthenticatedPeer
    ) async -> Bool {
        guard !childEvidenceReadyPeers.contains(peer.key) else { return true }
        return await withCheckedContinuation { continuation in
            childEvidenceReadyWaiters[peer.key, default: []].append(
                ChildEvidenceReadyWaiter(
                    sessionID: peer.sessionID,
                    continuation: continuation
                )
            )
        }
    }

    private func markChildEvidenceReady(_ peer: AuthenticatedPeer) {
        guard hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
            return
        }
        childEvidenceReadyPeers.insert(peer.key)
        let waiters = childEvidenceReadyWaiters.removeValue(
            forKey: peer.key
        ) ?? []
        for waiter in waiters {
            waiter.continuation.resume(
                returning: waiter.sessionID == peer.sessionID
            )
        }
    }

    private func cancelChildEvidenceReadyWaiters(for peerKey: PeerKey) {
        childEvidenceIndexCompleteSessions =
            childEvidenceIndexCompleteSessions.filter {
                $0.peerKey != peerKey
            }
        childEvidencePublicationFailedSessions =
            childEvidencePublicationFailedSessions.filter {
                $0.peerKey != peerKey
            }
        childEvidencePublicationsInFlight =
            childEvidencePublicationsInFlight.filter {
                $0.key.peerKey != peerKey
            }
        let waiters = childEvidenceReadyWaiters.removeValue(
            forKey: peerKey
        ) ?? []
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
    }

    private func canServeHierarchyContent(to peer: AuthenticatedPeer) -> Bool {
        runtimeGeneration != 0
            && hierarchyPeers[peer.key] != nil
            && hierarchySessions[peer.key]?.sessionID == peer.sessionID
    }

    private func provisionalVolume(
        forRoot cid: String
    ) async -> SerializedVolume? {
        await provisionalRoots.volume(cid, generation: runtimeGeneration)
    }

    /// Schedule one serialized export per child peer. The task owns its cursor
    /// until every frame is locally queued; newer parent facts mark one
    /// refresh pass and therefore cannot overtake or disappear behind a
    /// throttled frame.
    private func pushInheritedWork(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard parentWorkReady,
              let fence = resolvedRuntimeFence(
            generation: generation,
            process: expectedProcess
        ) else { return }
        var peersByChildPath: [[String]: [AuthenticatedPeer]] = [:]
        for (peerKey, role) in hierarchyPeers {
            guard case .child(let childPath) = role,
                  let peer = hierarchySessions[peerKey],
                  inheritedWorkRequestedByChildPeer.contains(peerKey)
            else { continue }
            peersByChildPath[childPath, default: []].append(peer)
        }

        guard !peersByChildPath.isEmpty else { return }

        var fullPlan: InheritedWorkPushPlan?
        var deltaPlansByRevision: [UInt64: InheritedWorkPushPlan] = [:]
        for childPath in peersByChildPath.keys.sorted(by: {
            $0.lexicographicallyPrecedes($1)
        }) {
            let peers = peersByChildPath[childPath]!.sorted(by: {
                $0.key.hex < $1.key.hex
            }).filter {
                !coalesceInheritedWorkPushIfActive(
                    to: $0,
                    generation: fence.generation
                )
            }
            guard !peers.isEmpty else { continue }
            for peer in peers {
                guard isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                ) else {
                    continue
                }
                let plan: InheritedWorkPushPlan?
                if let cursor = inheritedWorkSentByChildPeer[peer.key] {
                    if let cached = deltaPlansByRevision[cursor.revision] {
                        plan = cached
                    } else {
                        let update = try? await fence.process
                            .parentSecuringWorkExport(since: cursor)
                        plan = update.flatMap {
                            InheritedWorkPushPlan(
                                sourceID: $0.sourceID,
                                export: $0.export
                            )
                        }
                        if let plan {
                            deltaPlansByRevision[cursor.revision] = plan
                        }
                    }
                } else {
                    if fullPlan == nil {
                        let update = try? await fence.process
                            .parentSecuringWorkExport(since: nil)
                        fullPlan = update.flatMap {
                            InheritedWorkPushPlan(
                                sourceID: $0.sourceID,
                                export: $0.export
                            )
                        }
                    }
                    plan = fullPlan
                }
                guard let plan,
                      isCurrentRuntime(
                        generation: fence.generation,
                        process: fence.process
                      ) else { continue }
                scheduleInheritedWorkPush(
                    plan: plan,
                    to: peer,
                    childPath: childPath,
                    generation: fence.generation,
                    process: fence.process
                )
            }
        }
    }

    private func respondToInheritedWorkRequest(
        _ request: InheritedWorkRequestMessage,
        from peer: AuthenticatedPeer,
        childPath: [String],
        generation: UInt64,
        process: ChainProcess
    ) async {
        resetInheritedWorkPush(for: peer.key)
        inheritedWorkRequestedByChildPeer.insert(peer.key)
        guard parentWorkReady,
              isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .child(childPath) else {
            return
        }
        let cursor = request.sourceID.flatMap { sourceID in
            request.revision.map {
                ParentWorkCursor(sourceID: sourceID, revision: $0)
            }
        }
        guard let update = try? await process.parentSecuringWorkExport(
            since: cursor
        ), let plan = InheritedWorkPushPlan(
            sourceID: update.sourceID,
            export: update.export
        ), isCurrentRuntime(
            generation: generation,
            process: process
        ) else {
            return
        }
        scheduleInheritedWorkPush(
            plan: plan,
            to: peer,
            childPath: childPath,
            generation: generation,
            process: process
        )
    }

    private func coalesceInheritedWorkPushIfActive(
        to peer: AuthenticatedPeer,
        generation: UInt64
    ) -> Bool {
        guard var current = inheritedWorkPushes[peer.key] else { return false }
        guard current.generation == generation else {
            current.task.cancel()
            inheritedWorkPushes.removeValue(forKey: peer.key)
            return false
        }
        current.needsRefresh = true
        inheritedWorkPushes[peer.key] = current
        return true
    }

    private func scheduleInheritedWorkPush(
        plan: InheritedWorkPushPlan,
        to peer: AuthenticatedPeer,
        childPath: [String],
        generation: UInt64,
        process: ChainProcess
    ) {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              case .child(let connectedPath)? = hierarchyPeers[peer.key],
              connectedPath == childPath else {
            return
        }
        let peerKey = peer.key
        if var current = inheritedWorkPushes[peerKey] {
            guard current.generation == generation else {
                current.task.cancel()
                inheritedWorkPushes.removeValue(forKey: peerKey)
                return scheduleInheritedWorkPush(
                    plan: plan,
                    to: peer,
                    childPath: childPath,
                    generation: generation,
                    process: process
                )
            }
            current.needsRefresh = true
            inheritedWorkPushes[peerKey] = current
            return
        }

        // An older suspended snapshot may resume after a newer complete pass.
        // It has no facts the child lacks, so do not let it regress the
        // cursor or start a redundant task.
        if let sent = inheritedWorkSentByChildPeer[peerKey],
           sent.sourceID == plan.sourceID,
           sent.revision >= plan.revision {
            return
        }

        nextInheritedWorkPushToken &+= 1
        let token = nextInheritedWorkPushToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainInheritedWorkPush(
                initialPlan: plan,
                to: peer,
                childPath: childPath,
                generation: generation,
                process: process,
                token: token
            )
        }
        inheritedWorkPushes[peerKey] = InheritedWorkPushState(
            token: token,
            generation: generation,
            task: task,
            needsRefresh: false
        )
    }

    private func resetInheritedWorkPush(for peerKey: PeerKey) {
        inheritedWorkSentByChildPeer.removeValue(forKey: peerKey)
        inheritedWorkRequestedByChildPeer.remove(peerKey)
        inheritedWorkPushes.removeValue(forKey: peerKey)?.task.cancel()
    }

    /// End only this drain after a failed local snapshot read. A replacement
    /// session or a later parent change can then schedule a fresh full export.
    private func finishInheritedWorkPush(
        peerKey: PeerKey,
        generation: UInt64,
        token: UInt64
    ) {
        guard let state = inheritedWorkPushes[peerKey],
              state.token == token,
              state.generation == generation else {
            return
        }
        inheritedWorkPushes.removeValue(forKey: peerKey)
    }

    private enum InheritedWorkPushPass {
        case send(InheritedWorkPushPlan)
        case stopped
    }

    private enum InheritedWorkPushCompletion {
        case refresh
        case finished
        case stopped
    }

    private func prepareInheritedWorkPushPass(
        plan: InheritedWorkPushPlan,
        peerKey: PeerKey,
        sessionID: Data,
        childPath: [String],
        generation: UInt64,
        process: ChainProcess,
        token: UInt64
    ) -> InheritedWorkPushPass {
        guard isCurrentInheritedWorkPush(
            peerKey: peerKey,
            sessionID: sessionID,
            childPath: childPath,
            generation: generation,
            process: process,
            token: token
        ) else {
            return .stopped
        }
        // Empty passes still traverse the real streamer: its marker is the
        // receiver's exact-session atomic completion boundary.
        return .send(plan)
    }

    /// Complete one pass atomically with refresh inspection. A caller that
    /// races this method either marks the next pass or observes no task and
    /// starts a new one; neither case can lose its parent facts.
    private func completeInheritedWorkPushPass(
        sourceID: String,
        revision: UInt64,
        queued: Bool,
        peerKey: PeerKey,
        sessionID: Data,
        childPath: [String],
        generation: UInt64,
        process: ChainProcess,
        token: UInt64
    ) -> InheritedWorkPushCompletion {
        guard isCurrentInheritedWorkPush(
            peerKey: peerKey,
            sessionID: sessionID,
            childPath: childPath,
            generation: generation,
            process: process,
            token: token
        ) else {
            return .stopped
        }
        guard queued else {
            inheritedWorkPushes.removeValue(forKey: peerKey)
            return .stopped
        }
        inheritedWorkSentByChildPeer[peerKey] = ParentWorkCursor(
            sourceID: sourceID,
            revision: revision
        )
        guard inheritedWorkPushes[peerKey]?.needsRefresh == true else {
            inheritedWorkPushes.removeValue(forKey: peerKey)
            return .finished
        }
        inheritedWorkPushes[peerKey]?.needsRefresh = false
        return .refresh
    }

    private func isCurrentInheritedWorkPush(
        peerKey: PeerKey,
        sessionID: Data,
        childPath: [String],
        generation: UInt64,
        process: ChainProcess,
        token: UInt64
    ) -> Bool {
        guard !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process),
              let state = inheritedWorkPushes[peerKey],
              state.token == token,
              state.generation == generation,
              hierarchySessions[peerKey]?.sessionID == sessionID,
              case .child(let connectedPath)? = hierarchyPeers[peerKey],
              connectedPath == childPath else {
            return false
        }
        return true
    }

    private var inheritedWorkPushRetryDelay: Duration? {
        let tally = planeConfigurations.hierarchy.tallyConfig
        guard tally.perPeerRequestRefillPerSecond > 0 else {
            return nil
        }
        let seconds = 1 / tally.perPeerRequestRefillPerSecond
        let milliseconds = min(
            max((seconds * 1_000).rounded(.up), 1),
            Double(Int64.max)
        )
        return .milliseconds(Int64(milliseconds))
    }

    private func drainInheritedWorkPush(
        initialPlan: InheritedWorkPushPlan,
        to peer: AuthenticatedPeer,
        childPath: [String],
        generation: UInt64,
        process: ChainProcess,
        token: UInt64
    ) async {
        let peerKey = peer.key
        var plan = initialPlan
        while true {
            let pass = prepareInheritedWorkPushPass(
                plan: plan,
                peerKey: peerKey,
                sessionID: peer.sessionID,
                childPath: childPath,
                generation: generation,
                process: process,
                token: token
            )
            let queued: Bool
            switch pass {
            case .send(let update):
                let retryDelay = inheritedWorkPushRetryDelay
                let retryDelayNanoseconds = retryDelay.map(Self.nanoseconds)
                queued = await Self.streamInheritedWorkPushPayloads(
                    plan: update,
                    send: { [hierarchy] payload in
                        while true {
                            guard await self.isCurrentInheritedWorkPush(
                                peerKey: peerKey,
                                sessionID: peer.sessionID,
                                childPath: childPath,
                                generation: generation,
                                process: process,
                                token: token
                            ) else {
                                return .stopped
                            }
                            switch await hierarchy.sendMessage(
                                to: peer,
                                topic: NodeNetworkTopic.inheritedWorkPush,
                                payload: payload
                            ) {
                            case .enqueued:
                                return .enqueued
                            case .backpressured:
                                guard await hierarchy.waitUntilWritable(to: peer),
                                      await self.isCurrentInheritedWorkPush(
                                        peerKey: peerKey,
                                        sessionID: peer.sessionID,
                                        childPath: childPath,
                                        generation: generation,
                                        process: process,
                                        token: token
                                      ) else {
                                    return .stopped
                                }
                            case .locallyRejected:
                                return retryDelay == nil ? .stopped : .retry
                            case .notConnected:
                                return .stopped
                            }
                        }
                    },
                    waitForRetry: {
                        guard let retryDelayNanoseconds,
                              await self.isCurrentInheritedWorkPush(
                            peerKey: peerKey,
                            sessionID: peer.sessionID,
                            childPath: childPath,
                            generation: generation,
                            process: process,
                            token: token
                        ) else {
                            return false
                        }
                        do {
                            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                        } catch {
                            return false
                        }
                        return await self.isCurrentInheritedWorkPush(
                            peerKey: peerKey,
                            sessionID: peer.sessionID,
                            childPath: childPath,
                            generation: generation,
                            process: process,
                            token: token
                        )
                    }
                )
            case .stopped:
                return
            }
            switch completeInheritedWorkPushPass(
                sourceID: plan.sourceID,
                revision: plan.revision,
                queued: queued,
                peerKey: peerKey,
                sessionID: peer.sessionID,
                childPath: childPath,
                generation: generation,
                process: process,
                token: token
            ) {
            case .refresh:
                guard let refreshed = try? await process.parentSecuringWorkExport(
                    since: inheritedWorkSentByChildPeer[peerKey]
                ), let refreshedPlan = InheritedWorkPushPlan(
                    sourceID: refreshed.sourceID,
                    export: refreshed.export
                ) else {
                    finishInheritedWorkPush(
                        peerKey: peerKey,
                        generation: generation,
                        token: token
                    )
                    return
                }
                plan = refreshedPlan
            case .finished, .stopped:
                return
            }
        }
    }

    /// The caller waits for Ivy transport writability before returning `.retry`
    /// for a local admission rejection. The packer advances after `.enqueued`
    /// only, preserving frame order and the sender cursor's exact meaning
    /// without adding a receiver acknowledgement protocol.
    static func streamInheritedWorkPushPayloads(
        snapshot: InheritedWorkSnapshot,
        sourceID: String = InheritedWorkPushMessage.legacySourceID,
        baseRevision: UInt64? = nil,
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes,
        send: @escaping @Sendable (Data) async -> InheritedWorkPushSendResult,
        waitForRetry: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard let plan = InheritedWorkPushPlan(
            snapshot: snapshot,
            sourceID: sourceID,
            baseRevision: baseRevision,
            maximumPayloadBytes: maximumPayloadBytes
        ) else {
            return false
        }
        return await streamInheritedWorkPushPayloads(
            plan: plan,
            send: send,
            waitForRetry: waitForRetry
        )
    }

    private static func streamInheritedWorkPushPayloads(
        plan: InheritedWorkPushPlan,
        send: @escaping @Sendable (Data) async -> InheritedWorkPushSendResult,
        waitForRetry: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        var packer = InheritedWorkPushPacker(plan: plan)
        while true {
            switch packer.next() {
            case .payload(let payload):
                var delivered = false
                while !delivered {
                    switch await send(payload) {
                    case .enqueued:
                        delivered = true
                    case .retry:
                        guard await waitForRetry() else { return false }
                    case .stopped:
                        return false
                    }
                }
            case .finished:
                guard let marker = try? InheritedWorkPushMessage(
                    sourceID: plan.sourceID,
                    baseRevision: plan.baseRevision,
                    snapshot: InheritedWorkSnapshot(
                        revision: plan.revision,
                        facts: []
                    )
                ).encoded() else { return false }
                while true {
                    switch await send(marker) {
                    case .enqueued:
                        return true
                    case .retry:
                        guard await waitForRetry() else { return false }
                    case .stopped:
                        return false
                    }
                }
            case .unencodable:
                return false
            }
        }
    }

    /// Test-only convenience wrapper. Production streams directly through
    /// `streamInheritedWorkPushPayloads` and never retains every frame.
    static func inheritedWorkPushPayloads(
        snapshot: InheritedWorkSnapshot,
        sourceID: String = InheritedWorkPushMessage.legacySourceID,
        baseRevision: UInt64? = nil,
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes
    ) -> [Data]? {
        guard let plan = InheritedWorkPushPlan(
            snapshot: snapshot,
            sourceID: sourceID,
            baseRevision: baseRevision,
            maximumPayloadBytes: maximumPayloadBytes
        ) else { return nil }
        var packer = InheritedWorkPushPacker(plan: plan)
        var payloads: [Data] = []
        while true {
            switch packer.next() {
            case .payload(let payload):
                payloads.append(payload)
            case .finished:
                guard let marker = try? InheritedWorkPushMessage(
                    sourceID: plan.sourceID,
                    baseRevision: plan.baseRevision,
                    snapshot: InheritedWorkSnapshot(
                        revision: snapshot.revision,
                        facts: []
                    )
                ).encoded() else { return nil }
                payloads.append(marker)
                return payloads
            case .unencodable:
                return nil
            }
        }
    }

    /// Publishes an already-promoted absolute proof prepared durably by the
    /// process admission boundary.
    @discardableResult
    public func publishChildProof(
        _ proof: ChildBlockProof,
        childDirectory: String,
        childCID: String
    ) async throws -> ChildBlockProof {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        let childPath = configuration.chainPath + [childDirectory]
        guard _isBoundedWireAtom(childCID),
              proof.directoryPath == Array(childPath.dropFirst()),
              !childDirectory.isEmpty,
              (try? proof.serialize()) != nil,
              let edge = await DirectChildEdge.derive(from: proof),
              edge.childCID == childCID
        else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        guard (try? await process.issuedChildEvidence(
            childCID: childCID,
            directory: childDirectory,
            rootCID: proof.rootCID
        )) != nil else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        guard
            await announceChildEvidenceAvailability(
                childPath: childPath,
                childCID: childCID,
                rootCID: proof.rootCID,
                generation: generation,
                process: process
            )
        else {
            throw NodeNetworkRuntimeError.notRunning
        }
        return proof
    }

    /// Tell authenticated direct children about evidence that has already been
    /// made durable. This closes the reconnect race where the child asks for
    /// its index just before the parent finishes preparing the proof.
    private func announceChildEvidenceAvailability(
        childPath: [String],
        childCID: String,
        rootCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return false
        }
        let bootstrappingPeers = hierarchyPeers.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path == childPath,
                  !childEvidenceReadyPeers.contains(key) else { return nil }
            return hierarchySessions[key]
        }
        for peer in bootstrappingPeers {
            let session = ChildEvidenceSession(
                peerKey: peer.key,
                sessionID: peer.sessionID
            )
            childEvidencePublicationsInFlight[session, default: 0] += 1
        }
        guard let directory = childPath.last,
            let evidence = try? await process.issuedChildEvidence(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            let indexed = try? await process.issuedChildEvidenceSummary(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            isCurrentRuntime(generation: generation, process: process),
            let payload = try? ChildEvidenceAvailableMessage(
                childPath: childPath,
                sourceID: indexed.sourceID,
                ordinal: indexed.summary.ordinal,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: evidence.attachmentCID
            ).encoded()
        else {
            for peer in bootstrappingPeers {
                finishChildEvidencePublication(
                    to: peer,
                    permitsCleanup: false
                )
                await hierarchy.recycleSession(ifCurrent: peer)
            }
            return false
        }
        let readyPeers = hierarchyPeers.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path == childPath,
                  childEvidenceReadyPeers.contains(key) else { return nil }
            return hierarchySessions[key]
        }
        for peer in bootstrappingPeers + readyPeers {
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
                if !childEvidenceReadyPeers.contains(peer.key) {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                continue
            }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return false
            }
            let bootstrapping = !childEvidenceReadyPeers.contains(peer.key)
            switch result {
            case .enqueued:
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: true
                    )
                }
            case .notConnected, .backpressured, .locallyRejected:
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                await hierarchy.recycleSession(ifCurrent: peer)
            }
        }
        return isCurrentRuntime(generation: generation, process: process)
    }

    private func finishChildEvidencePublication(
        to peer: AuthenticatedPeer,
        permitsCleanup: Bool
    ) {
        let session = ChildEvidenceSession(
            peerKey: peer.key,
            sessionID: peer.sessionID
        )
        guard let count = childEvidencePublicationsInFlight[session] else {
            return
        }
        if !permitsCleanup {
            childEvidencePublicationFailedSessions.insert(session)
        }
        if count == 1 {
            childEvidencePublicationsInFlight.removeValue(forKey: session)
            if permitsCleanup,
               !childEvidencePublicationFailedSessions.contains(session),
               childEvidenceIndexCompleteSessions.contains(session),
               hierarchySessions[peer.key]?.sessionID == peer.sessionID {
                markChildEvidenceReady(peer)
            }
        } else {
            childEvidencePublicationsInFlight[session] = count - 1
        }
    }

    private func completeChildEvidenceIndex(for peer: AuthenticatedPeer) {
        let session = ChildEvidenceSession(
            peerKey: peer.key,
            sessionID: peer.sessionID
        )
        childEvidenceIndexCompleteSessions.insert(session)
        if childEvidencePublicationsInFlight[session] == nil,
           !childEvidencePublicationFailedSessions.contains(session) {
            markChildEvidenceReady(peer)
        }
    }

    /// A direct child pulls its bounded index once on authentication. If that
    /// pull races durable proof preparation, re-advertise only evidence for
    /// this local carrier in its authenticated root context(s).
    private func announceCurrentCarrierChildEvidence(
        directories: [String],
        carrierCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        let directories = Set(directories)
        var afterRootCID: String?
        var announcements = 0
        var rootsExamined = 0
        while announcements < Self.maximumReconnectEvidenceAnnouncements,
            rootsExamined < Self.maximumReconnectCarrierRoots
        {
            let remainingRoots = Self.maximumReconnectCarrierRoots - rootsExamined
            guard
                let roots = try? await process.parentCarrierRootPage(
                    carrierCID: carrierCID,
                    afterRootCID: afterRootCID,
                    limit: remainingRoots
                )
            else {
                return isCurrentRuntime(generation: generation, process: process)
            }
            guard !roots.isEmpty else { break }
            rootsExamined += roots.count
            for rootCID in roots {
                guard
                    let proofs = try? await process.durableDirectChildProofs(
                        carrierCID: carrierCID,
                        rootCID: rootCID,
                        directories: directories
                    )
                else { continue }
                for proof in proofs {
                    guard
                        await announceChildEvidenceAvailability(
                            childPath: configuration.chainPath + [proof.directory],
                            childCID: proof.childCID,
                            rootCID: proof.proof.rootCID,
                            generation: generation,
                            process: process
                        )
                    else { return false }
                    announcements += 1
                    if announcements == Self.maximumReconnectEvidenceAnnouncements {
                        return isCurrentRuntime(
                            generation: generation,
                            process: process
                        )
        }
                }
            }
            afterRootCID = roots.last
            guard roots.count == remainingRoots else { break }
        }
        return isCurrentRuntime(generation: generation, process: process)
    }

    nonisolated public func ivy(
        _ ivy: Ivy,
        didConnect peer: AuthenticatedPeer
    ) async {
        let generation = callbackEpoch.current()
        await didConnect(on: ivy, peer: peer, generation: generation)
    }

    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        let generation = callbackEpoch.current()
        Task { await self.didDisconnect(on: ivy, peer: peer, generation: generation) }
    }

    nonisolated public func ivy(
        _ ivy: Ivy,
        didDiscoverPublicAddress address: ObservedAddress
    ) {}

    nonisolated public func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        let generation = callbackEpoch.current()
        await didReceive(
            on: ivy,
            message: message,
            peer: peer,
            generation: generation
        )
    }

    static func startPlanes(
        startHierarchy: @Sendable () async throws -> Void,
        startOverlay: @Sendable () async throws -> Void,
        stopOverlay: @Sendable () async -> Void,
        stopHierarchy: @Sendable () async -> Void
    ) async throws {
        do {
            try await startHierarchy()
        } catch {
            await stopHierarchy()
            throw error
        }
        do {
            try await startOverlay()
        } catch {
            await stopOverlay()
            await stopHierarchy()
            throw error
        }
    }

    static func stopPlanes(
        stopOverlay: @Sendable () async -> Void,
        stopHierarchy: @Sendable () async -> Void
    ) async {
        await stopOverlay()
        await stopHierarchy()
    }

    private func didConnect(
        on ivy: Ivy,
        peer: AuthenticatedPeer,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation), let process else { return }
        guard peer.role == .endpoint else {
            await ivy.disconnectSession(ifCurrent: peer)
            return
        }
        let topic: String
        if ivy === overlay {
            // Overlay authorization, like hierarchy authorization, belongs to
            // one authenticated connection rather than a long-lived key.
            if let previous = overlayPeers[peer.key] {
                candidateAcquirer.disconnect(candidateProvider(previous))
            }
            overlayPeers.removeValue(forKey: peer.key)
            discardAcceptedLeavesSessions(for: peer.key)
            pendingPortableAttachmentIndexes =
                pendingPortableAttachmentIndexes.filter {
                    $0.value.peer.key != peer.key
                }
            overlaySessions[peer.key] = peer
            scheduleOverlayHelloDeadline(for: peer, generation: generation)
            topic = NodeNetworkTopic.overlayHello
        } else if ivy === hierarchy {
            guard peer.route == .direct else {
                await ivy.disconnectSession(ifCurrent: peer)
                return
            }
            topic = NodeNetworkTopic.hierarchyHello
        } else {
            return
        }
        guard let payload = try? hello.encode() else { return }
        if ivy === hierarchy {
            // A hierarchy role belongs to one authenticated connection. A
            // replacement parent connection must complete its own inherited
            // work sync before this chain can act on fork choice.
            let isConfiguredParent =
                configuration.parentEndpoint.flatMap {
                    try? PeerKey($0.publicKey)
                } == peer.key
            _ = clearHierarchyAuthorization(for: peer.key)
            if isConfiguredParent {
                await setParentWorkReady(false)
            }
            scheduleHierarchyHelloDeadline(for: peer, generation: generation)
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let result = await ivy.sendMessage(
            to: peer,
            topic: topic,
            payload: payload
        )
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        switch result {
        case .enqueued, .notConnected:
            break
        case .backpressured, .locallyRejected:
            await ivy.recycleSession(ifCurrent: peer)
        }
        if ivy === overlay {
            await resumeAcceptedLeavesSync(
                generation: generation,
                process: process
            )
        }
    }

    private func didDisconnect(
        on ivy: Ivy,
        peer: PeerID,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation), let process else { return }
        guard let key = try? PeerKey(peer.publicKey) else { return }
        if ivy === overlay {
            // A replacement may already be current when the old connection's
            // asynchronous disconnect callback arrives.
            guard !(await ivy.connectedPeers).contains(peer) else { return }
            overlayHelloDeadlines.removeValue(forKey: key)?.task.cancel()
            if let disconnected = overlayPeers[key] {
                candidateAcquirer.disconnect(candidateProvider(disconnected))
            }
            discardAcceptedLeavesSessions(for: key)
            overlaySessions.removeValue(forKey: key)
            overlayPeers.removeValue(forKey: key)
            pendingPortableAttachmentIndexes =
                pendingPortableAttachmentIndexes.filter {
                    $0.value.peer.key != key
                }
            let disconnectedInventories = pendingTransactionInventories.filter {
                $0.value.peer.key == key
            }
            for pending in disconnectedInventories.values {
                pending.timeout.cancel()
            }
            pendingTransactionInventories = pendingTransactionInventories.filter {
                $0.value.peer.key != key
            }
            await resumeAcceptedLeavesSync(
                generation: generation,
                process: process
            )
        } else if ivy === hierarchy {
            // Ivy may already have promoted a replacement session for this
            // identity before this asynchronous delegate callback reaches us.
            // In that case this is the old connection ending, not a loss of
            // the authenticated parent/child relationship.
            guard !(await ivy.connectedPeers).contains(peer) else { return }
            let removed = clearHierarchyAuthorization(for: key)
            if case .parent? = removed {
                await setParentWorkReady(false)
            }
        }
    }

    @discardableResult
    private func clearHierarchyAuthorization(for key: PeerKey) -> HierarchyPeer? {
        hierarchyHelloDeadlines.removeValue(forKey: key)?.task.cancel()
        cancelParentEvidence(for: key)
        let removedRole = hierarchyPeers.removeValue(forKey: key)
        hierarchySessions.removeValue(forKey: key)
        childEvidenceReadyPeers.remove(key)
        cancelChildEvidenceReadyWaiters(for: key)
        resetInheritedWorkPush(for: key)
        dirtyCandidateReservationPeers.remove(key)
        if desiredCandidateReservations[key]?.isEmpty == true {
            desiredCandidateReservations.removeValue(forKey: key)
        }
        Self.pruneChildPeerRotations(
            &childPeerRotation,
            activeRoles: Array(hierarchyPeers.values)
        )
        if case .parent? = removedRole {
            pendingEvidenceIndexes.removeAll()
            parentWorkAssembler = nil
        }
        cancelChildCandidateWork(for: key)
        let reservations = pendingCandidateReservations.filter {
            $0.value.peer.key == key
        }
        pendingCandidateReservations = pendingCandidateReservations.filter {
            $0.value.peer.key != key
        }
        for reservation in reservations.values {
            reservation.continuation.resume(returning: false)
        }
        return removedRole
    }

    private func didReceive(
        on ivy: Ivy,
        message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation), let process else { return }
        guard let plane = NodeNetworkTopic.plane(for: message.topic) else { return }
        if ivy === overlay {
            guard plane == .overlay else { return }
            await handleOverlay(
                message,
                peer: peer,
                generation: generation,
                process: process
            )
        } else if ivy === hierarchy {
            guard plane == .hierarchy, peer.route == .direct else { return }
            await handleHierarchy(
                message,
                peer: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func handleOverlay(
        _ message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        if message.topic == NodeNetworkTopic.overlayHello {
            guard expectsOverlayHello(from: peer) else { return }
            guard let remote = try? ChainHello.decode(message.payload),
                  (try? remote.validateCompatibility(
                    expectedNexusGenesisCID: configuration.nexusGenesisCID,
                    expectedChainPath: configuration.chainPath
                )) != nil
            else {
                await overlay.disconnectSession(ifCurrent: peer)
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  expectsOverlayHello(from: peer) else { return }
            overlayHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
            overlaySessions.removeValue(forKey: peer.key)
            overlayPeers[peer.key] = peer
            if let tip = await process.status().tipCID,
                let payload = try? BlockAnnouncementMessage(blockCID: tip).encoded()
            {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                _ = await overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.blockAnnouncement,
                    payload: payload
                )
            }
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            enqueueAcceptedLeavesSession(peer)
            await resumeAcceptedLeavesSync(
                generation: generation,
                process: process
            )
            scheduleChildProofRecovery(
                generation: generation,
                process: process
            )
            await requestPortableAttachmentIndex(
                from: peer,
                after: nil,
                generation: generation,
                process: process
            )
            await requestTransactionInventory(
                from: peer,
                after: nil,
                generation: generation,
                process: process
            )
            return
        }

        guard overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        switch message.topic {
        case NodeNetworkTopic.transactionAvailable:
            guard let available = try? TransactionAvailableMessage.decoded(
                message.payload
            ) else { return }
            scheduleTransactionVolume(
                available.volumeRootCID,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.transactionInventoryRequest:
            guard let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
            ) else { return }
            await serveTransactionInventory(
                request,
                to: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.transactionInventoryResponse:
            guard let response = try? TransactionInventoryResponseMessage.decoded(
                message.payload
            ) else { return }
            scheduleTransactionInventory(
                response,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.portableAttachmentAvailable:
            guard let available = try? PortableAttachmentAvailableMessage
                .decoded(message.payload) else { return }
            let handled = enqueuePortableEvidence(
                PortableAttachmentSummary(
                    edgeCID: available.edgeCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                ),
                from: peer,
                generation: generation,
                process: process
            )
            if !handled { await overlay.recycleSession(ifCurrent: peer) }
        case NodeNetworkTopic.portableAttachmentIndexRequest:
            guard let request = try? PortableAttachmentIndexRequestMessage
                .decoded(message.payload) else { return }
            await servePortableAttachmentIndex(
                request,
                to: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.portableAttachmentIndexResponse:
            guard let response = try? PortableAttachmentIndexResponseMessage
                .decoded(message.payload) else { return }
            schedulePortableAttachmentIndex(
                response,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.blockAnnouncement:
            guard let announcement = try? BlockAnnouncementMessage.decoded(message.payload) else {
                return
            }
            await overlay.rememberProvider(
                rootCID: announcement.blockCID,
                peer: peer.id
            )
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
            let candidate = CandidateSeed(
                blockCID: announcement.blockCID,
                package: nil,
                provider: candidateProvider(peer)
            )
            guard enqueueCandidate(candidate) else {
                restartAcceptedLeavesSync()
                return
            }
        case NodeNetworkTopic.acceptedLeavesRequest:
            guard
                let request = try? AcceptedLeavesRequestMessage.decoded(
                    message.payload
                ), servingAcceptedLeaves.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(
                    generation: generation,
                    process: process
                ) {
                    servingAcceptedLeaves.remove(peer.sessionID)
                }
            }
            guard
                let leaves = try? await process.acceptedLeafPage(
                    afterCID: request.afterCID,
                    snapshotSequence: request.snapshotSequence,
                    limit: AcceptedLeavesResponseMessage.maximumLeaves + 1
                ), isCurrentRuntime(generation: generation, process: process)
            else {
                return
            }
            let page = Array(
                leaves.blockCIDs.prefix(AcceptedLeavesResponseMessage.maximumLeaves)
            )
            guard
                let payload = try? AcceptedLeavesResponseMessage(
                    requestID: request.requestID,
                    afterCID: request.afterCID,
                    snapshotSequence: leaves.snapshotSequence,
                    blockCIDs: page,
                    hasMore: leaves.blockCIDs.count > page.count
                ).encoded()
            else { return }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: payload
            )
        case NodeNetworkTopic.acceptedLeavesResponse:
            guard
                let response = try? AcceptedLeavesResponseMessage.decoded(
                    message.payload
                ), let pending = pendingAcceptedLeaves,
                response.requestID == pending.request.requestID,
                pending.peer.sessionID == peer.sessionID,
                response.afterCID == pending.request.afterCID,
                pending.request.snapshotSequence == nil
                    || pending.request.snapshotSequence
                        == response.snapshotSequence
            else { return }
            guard takeAcceptedLeavesRequest(
                releasingReservation: false
            ) != nil else { return }
            let candidates = response.blockCIDs.map {
                CandidateSeed(
                    blockCID: $0,
                    package: nil,
                    provider: candidateProvider(peer)
                )
            }
            guard candidateAcquirer.consumeAcceptedLeafPage(candidates) else {
                assertionFailure("accepted-leaf page exceeded its reservation")
                restartAcceptedLeavesSync()
                return
            }
            serviceCandidateAcquirer()
            for cid in response.blockCIDs {
                await overlay.rememberProvider(rootCID: cid, peer: peer.id)
            }
            if response.hasMore {
                nextAcceptedLeaves = NextAcceptedLeaves(
                    peer: peer,
                    cursor: AcceptedLeavesCursor(
                        afterCID: response.blockCIDs.last,
                        snapshotSequence: response.snapshotSequence
                    )
                )
            } else {
                nextAcceptedLeaves = nil
            }
            await resumeAcceptedLeavesSync(
                generation: generation,
                process: process
            )
        default:
            break
        }
    }

    private func requestTransactionInventory(
        from peer: AuthenticatedPeer,
        after: String?,
        generation: UInt64,
        process: ChainProcess,
        remainingRoots requestedRemainingRoots: Int? = nil,
        seenRoots: Set<String> = []
    ) async {
        let remainingRoots = requestedRemainingRoots
            ?? Self.maximumTransactionInventoryRootsPerSync
        guard remainingRoots > 0,
              handlers?.transaction != nil,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID,
              !pendingTransactionInventories.values.contains(where: {
                  $0.peer.sessionID == peer.sessionID
              }) else { return }
        let request = TransactionInventoryRequestMessage(
            requestID: makeRequestID(),
            afterRootCID: after
        )
        guard let payload = try? request.encoded() else { return }
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.transactionInventoryTimedOut(
                requestID: request.requestID,
                generation: generation
            )
        }
        pendingTransactionInventories[request.requestID] = .init(
            peer: peer,
            request: request,
            remainingRoots: remainingRoots,
            seenRoots: seenRoots,
            timeout: timeout
        )
        let result = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryRequest,
            payload: payload
        )
        switch result {
        case .enqueued:
            break
        case .backpressured, .locallyRejected, .notConnected:
            pendingTransactionInventories.removeValue(
                forKey: request.requestID
            )?.timeout.cancel()
        }
    }

    private func transactionInventoryTimedOut(
        requestID: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation),
              let pending = pendingTransactionInventories.removeValue(
                forKey: requestID
              ) else { return }
        await overlay.recycleSession(ifCurrent: pending.peer)
    }

    private func serveTransactionInventory(
        _ request: TransactionInventoryRequestMessage,
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let transactionInventoryProvider = handlers?.transactionInventory,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        let roots = Array(Set(await transactionInventoryProvider())).sorted()
            .filter { root in
                request.afterRootCID.map { root > $0 } ?? true
            }
        let page = Array(
            roots.prefix(TransactionInventoryResponseMessage.maximumRoots)
        )
        guard let payload = try? TransactionInventoryResponseMessage(
            requestID: request.requestID,
            afterRootCID: request.afterRootCID,
            volumeRootCIDs: page,
            hasMore: roots.count > page.count
        ).encoded() else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: payload
        )
    }

    private func scheduleTransactionInventory(
        _ response: TransactionInventoryResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let pending = pendingTransactionInventories[response.requestID],
              pending.peer.sessionID == peer.sessionID,
              pending.request.afterRootCID == response.afterRootCID else { return }
        pendingTransactionInventories.removeValue(
            forKey: response.requestID
        )?.timeout.cancel()
        Task { [weak self] in
            await self?.receiveTransactionInventory(
                response,
                pending: pending,
                from: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func receiveTransactionInventory(
        _ response: TransactionInventoryResponseMessage,
        pending: PendingTransactionInventory,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let transactionInventoryProvider = handlers?.transactionInventory,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        let knownRoots = Set(await transactionInventoryProvider())
        let roots = response.volumeRootCIDs.filter {
            !knownRoots.contains($0) && !pending.seenRoots.contains($0)
        }
        let selected = Array(roots.prefix(pending.remainingRoots))
        for rootCID in selected {
            guard let work = reserveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process
            ) else { continue }
            await receiveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process,
                transactionHandler: work.handler,
                lease: work.lease
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
        }
        let remainingRoots = pending.remainingRoots - selected.count
        if response.hasMore,
           remainingRoots > 0,
           let cursor = response.volumeRootCIDs.last {
            await requestTransactionInventory(
                from: peer,
                after: cursor,
                generation: generation,
                process: process,
                remainingRoots: remainingRoots,
                seenRoots: pending.seenRoots.union(response.volumeRootCIDs)
            )
        }
    }

    private func scheduleTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let work = reserveTransactionVolume(
            rootCID,
            from: peer,
            generation: generation,
            process: process
        ) else { return }
        Task { [weak self] in
            await self?.receiveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process,
                transactionHandler: work.handler,
                lease: work.lease
            )
        }
    }

    private func reserveTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> (handler: NetworkTransactionHandler, lease: TransactionVolumeLease)? {
        guard let transactionHandler = handlers?.transaction,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return nil }
        let lease = TransactionVolumeLease(
            sessionID: peer.sessionID,
            rootCID: rootCID
        )
        guard !activeTransactionVolumes.contains(lease),
              activeTransactionVolumes.count
                  < Self.maximumConcurrentTransactionVolumes,
              activeTransactionVolumes.insert(lease).inserted else { return nil }
        return (transactionHandler, lease)
    }

    private func receiveTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess,
        transactionHandler: @escaping NetworkTransactionHandler,
        lease: TransactionVolumeLease
    ) async {
        defer { activeTransactionVolumes.remove(lease) }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        if let transactionInventoryProvider = handlers?.transactionInventory,
           await transactionInventoryProvider().contains(rootCID) {
            return
        }

        let response: AttributedVolumeResponse
        while true {
            let fetched = await overlay.fetchVolume(rootCID: rootCID, from: peer)
            guard fetched.failure == .localCapacityUnavailable else {
                response = fetched
                break
            }
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.overlay.requestTimeout
                    )
                )
            } catch {
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return
            }
        }
        let volume = SerializedVolume(
            root: response.rootCID,
            entries: response.entries
        )
        guard response.servedBy == peer.id,
              response.rootCID == rootCID else {
            await overlay.recycleSession(ifCurrent: peer)
            return
        }
        guard (try? volume.validate()) != nil,
              let resolved = try? await VolumeImpl<Transaction>(
                rawCID: rootCID,
                node: nil,
                encryptionInfo: nil
            ).resolveRecursive(source: InMemoryContentSource(volume.entries)),
              resolved.rawCID == rootCID,
              let transaction = resolved.node else {
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer.id
            )
            return
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        do {
            guard try await transactionHandler(transaction) else { return }
        } catch {
            return
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        guard let payload = try? TransactionAvailableMessage(
            volumeRootCID: rootCID
        ).encoded() else { return }
        for candidate in overlayPeers.values
        where candidate.sessionID != peer.sessionID {
            _ = await overlay.sendMessage(
                to: candidate,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: payload
            )
        }
    }

    private func requestPortableAttachmentIndex(
        from peer: AuthenticatedPeer,
        after: PortableAttachmentSummary?,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID,
              !pendingPortableAttachmentIndexes.values.contains(where: {
                  $0.peer.sessionID == peer.sessionID
              }) else { return }
        let request = PortableAttachmentIndexRequestMessage(
            requestID: makeRequestID(),
            after: after
        )
        guard let payload = try? request.encoded() else { return }
        pendingPortableAttachmentIndexes[request.requestID] = .init(
            peer: peer,
            request: request
        )
        let result = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.portableAttachmentIndexRequest,
            payload: payload
        )
        if result == .notConnected {
            pendingPortableAttachmentIndexes.removeValue(forKey: request.requestID)
        } else {
            scheduleRecoveryTimeout(
                request.requestID,
                generation: generation
            )
        }
    }

    private func announcePortableAttachmentAvailability(
        edgeCID: String,
        rootCID: String,
        attachmentCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let payload = try? PortableAttachmentAvailableMessage(
            edgeCID: edgeCID,
            rootCID: rootCID,
            attachmentCID: attachmentCID
        ).encoded() else { return }
        for peer in overlayPeers.values {
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.portableAttachmentAvailable,
                payload: payload
            )
        }
    }

    private func servePortableAttachmentIndex(
        _ request: PortableAttachmentIndexRequestMessage,
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus else { return }
        let after = request.after.map {
            ChildRootAttachmentSummary(
                edgeCID: $0.edgeCID,
                rootCID: $0.rootCID,
                attachmentCID: $0.attachmentCID
            )
        }
        guard let entries = try? await process.childRootAttachmentSummaries(
            scope: .incomingCarrier,
            directory: configuration.address.directory,
            after: after,
            limit: PortableAttachmentIndexResponseMessage.maximumEntries + 1,
            portableOnly: true
        ), isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let page = entries.prefix(
            PortableAttachmentIndexResponseMessage.maximumEntries
        ).map {
            PortableAttachmentSummary(
                edgeCID: $0.edgeCID,
                rootCID: $0.rootCID,
                attachmentCID: $0.attachmentCID
            )
        }
        guard let payload = try? PortableAttachmentIndexResponseMessage(
            requestID: request.requestID,
            after: request.after,
            entries: Array(page),
            hasMore: entries.count > page.count
        ).encoded() else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.portableAttachmentIndexResponse,
            payload: payload
        )
    }

    private func schedulePortableAttachmentIndex(
        _ response: PortableAttachmentIndexResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let pending = pendingPortableAttachmentIndexes[response.requestID],
              pending.peer.sessionID == peer.sessionID,
              pending.request.after == response.after else { return }
        pendingPortableAttachmentIndexes.removeValue(forKey: response.requestID)
        Task { [weak self] in
            await self?.finishPortableAttachmentIndex(
                response,
                from: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func finishPortableAttachmentIndex(
        _ response: PortableAttachmentIndexResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let entry = response.entries.first else { return }
        let handled = await recoverPortableAttachment(
            entry,
            from: peer,
            generation: generation,
            process: process
        )
        if !handled {
            await overlay.recycleSession(ifCurrent: peer)
        } else if response.hasMore {
            await requestPortableAttachmentIndex(
                from: peer,
                after: entry,
                generation: generation,
                process: process
            )
        }
    }

    private func enqueuePortableEvidence(
        _ summary: PortableAttachmentSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> Bool {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            return false
        }
        let lease = EvidenceVolumeLease(
            plane: .overlay,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        guard !activeEvidenceVolumes.contains(lease),
              portableEvidenceWork[lease] == nil else { return true }
        let work = PortableEvidenceWork(
            summary: summary,
            peer: peer,
            generation: generation,
            process: process
        )
        let activePortable = activeEvidenceVolumes.lazy.filter {
            $0.plane == .overlay
        }.count
        guard portableEvidenceWork.count + parentEvidenceOperationCount
                + activePortable
                < Self.maximumEvidenceCandidates - 1 else {
            portableEvidenceRecycle[peer.key] = peer
            startPortableEvidenceWorker()
            return true
        }
        portableEvidenceWork[lease] = work
        portableEvidenceOrder.append(lease)
        startPortableEvidenceWorker()
        return true
    }

    private func startPortableEvidenceWorker() {
        guard portableEvidenceWorker == nil else { return }
        portableEvidenceWorker = Task { [weak self] in
            await self?.drainPortableEvidence()
        }
    }

    private func drainPortableEvidence() async {
        defer {
            portableEvidenceWorker = nil
            if !portableEvidenceOrder.isEmpty || !portableEvidenceRecycle.isEmpty {
                startPortableEvidenceWorker()
            }
        }
        while !portableEvidenceOrder.isEmpty {
            let lease = portableEvidenceOrder.removeFirst()
            guard let work = portableEvidenceWork.removeValue(forKey: lease)
            else { continue }
            let handled = await recoverPortableAttachment(
                work.summary,
                from: work.peer,
                generation: work.generation,
                process: work.process
            )
            if !handled {
                await overlay.recycleSession(ifCurrent: work.peer)
            }
        }
        let recycle = Array(portableEvidenceRecycle.values)
        portableEvidenceRecycle.removeAll()
        for peer in recycle {
            await overlay.recycleSession(ifCurrent: peer)
        }
    }

    private func recoverPortableAttachment(
        _ summary: PortableAttachmentSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            return false
        }
        let lease = EvidenceVolumeLease(
            plane: .overlay,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if activeEvidenceVolumes.contains(lease) { return true }
        // Keep one slot for the live trusted parent so overlay churn cannot
        // starve consensus-critical hierarchy evidence.
        while activeEvidenceVolumes.count >= Self.maximumEvidenceCandidates - 1 {
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.overlay.requestTimeout
                    )
                )
            } catch {
                return false
            }
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return true
            }
            if activeEvidenceVolumes.contains(lease) { return true }
        }
        activeEvidenceVolumes.insert(lease)
        defer { activeEvidenceVolumes.remove(lease) }
        if let evidence = try? await process.childRootAttachment(
            scope: .incomingCarrier,
            edgeCID: summary.edgeCID,
            rootCID: summary.rootCID
        ) {
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return true
            }
            return enqueueCandidate(CandidateSeed(
                blockCID: evidence.edge.childCID,
                package: AuthenticatedChildPackage(
                    package: ChildValidationPackage(
                        proof: evidence.proof,
                        parentCarrierLink: evidence.parentCarrierLink,
                        parentGenesisLink: evidence.parentGenesisLink
                    ),
                    parentCarrierCertificate:
                        evidence.parentCarrierCertificate,
                    parentGenesisCertificate:
                        evidence.parentGenesisCertificate
                )
            ))
        }
        // The peer advertising an attachment is responsible for serving its
        // immutable CAS graph. Binding resolution to that exact authenticated
        // session prevents a false summary from being blamed on an honest
        // third-party content provider.
        let source = IvyRootContentSource(
            ivy: overlay,
            peer: peer,
            maximumMembers: 1,
            maximumStorageBytes: ChildEvidenceVolume.maximumFramedBytes,
            maximumArchiveBytes: ChildEvidenceVolume.maximumArchiveBytes
        )
        let resolved: (
            value: ChildEvidenceVolume?,
            attribution: IvyRootContentSource.Attribution
        )
        while true {
            let fetched = await source.withRootTracing(
                summary.attachmentCID
            ) { session in
                await Self.resolveEvidenceVolume(
                    summary.attachmentCID,
                    source: session
                )
            }
            guard fetched.attribution.localCapacityUnavailable else {
                resolved = fetched
                break
            }
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.overlay.requestTimeout
                    )
                )
            } catch {
                return true
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return true
            }
        }
        guard let attachment = resolved.value,
              let envelope = try? ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes,
                maximumEncodedSize:
                    configuration.resourcePolicy.maximumParentWitnessBytes
              ),
              envelope.parentCarrierLink != nil,
              envelope.parentCarrierCertificate != nil,
              let gate = parentFactGate,
              let authority = configuration.parentEndpoint.flatMap({
                  ParentProcessKey($0.publicKey)
              }),
              let gated = try? gate.acceptPortable(
                envelope,
                durableParentProcessKey: authority
              ),
              gated.package.proof.rootCID == summary.rootCID,
              let edge = await DirectChildEdge.derive(from: gated.package.proof),
              edge.edgeCID == summary.edgeCID,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            if resolved.attribution.allResponsesComplete,
               let supplier = resolved.attribution.soleRemoteSupplierPublicKey {
                await overlay.reportDeficientContent(
                    rootCID: summary.attachmentCID,
                    servedBy: PeerID(publicKey: supplier)
                )
            }
            return false
        }
        return enqueueCandidate(CandidateSeed(
            blockCID: edge.childCID,
            package: gated
        ))
    }

    private nonisolated static func resolveEvidenceVolume(
        _ cid: String,
        childCID: String? = nil,
        source: IvyRootContentSource.Session
    ) async -> ChildEvidenceVolume? {
        guard let serialized = await source.volume(rootCID: cid) else {
            return nil
        }
        return try? ChildEvidenceVolume(
            serialized: serialized,
            childCID: childCID
        )
    }

    private func scheduleParentEvidencePage(
        _ response: ChildEvidenceIndexResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        let tail: Task<Bool, Never>?
        if response.entries.isEmpty {
            tail = nil
        } else {
            guard let appended = appendParentEvidence(
                response.entries,
                sourceID: response.sourceID,
                advanceScan: true,
                from: peer,
                generation: generation,
                process: process
            ) else {
                Task { [hierarchy] in
                    await hierarchy.recycleSession(ifCurrent: peer)
                }
                return
            }
            tail = appended
        }
        Task { [weak self] in
            guard let self else { return }
            guard await tail?.value ?? true else { return }
            if response.next < response.through {
                await self.requestEvidenceIndex(
                    sourceID: response.sourceID,
                    cursor: response.next,
                    through: response.through,
                    generation: generation,
                    process: process
                )
            } else {
                try? await process.advanceParentEvidenceScan(
                    sourceID: response.sourceID,
                    throughOrdinal: response.through
                )
            }
        }
    }

    private func recoverParentEvidence(
        _ summary: IssuedChildEvidenceSummary,
        sourceID: String,
        advanceScan: Bool,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else {
            return false
        }
        let lease = EvidenceVolumeLease(
            plane: .hierarchy,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if activeEvidenceVolumes.contains(lease) { return true }
        while activeEvidenceVolumes.count >= Self.maximumEvidenceCandidates {
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.hierarchy.requestTimeout
                    )
                )
            } catch {
                return true
            }
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), hierarchySessions[peer.key]?.sessionID == peer.sessionID,
               hierarchyPeers[peer.key] == .parent else {
                return false
            }
            if activeEvidenceVolumes.contains(lease) { return true }
        }
        activeEvidenceVolumes.insert(lease)
        defer { activeEvidenceVolumes.remove(lease) }
        let source = IvyRootContentSource(
            ivy: hierarchy,
            peer: peer,
            maximumMembers: 1,
            maximumStorageBytes: ChildEvidenceVolume.maximumFramedBytes,
            maximumArchiveBytes: ChildEvidenceVolume.maximumArchiveBytes
        )
        let resolved: (
            value: ChildEvidenceVolume?,
            attribution: IvyRootContentSource.Attribution
        )
        while true {
            let fetched = await source.withRootTracing(
                summary.attachmentCID,
                operation: { session in
                    await Self.resolveEvidenceVolume(
                        summary.attachmentCID,
                        childCID: summary.childCID,
                        source: session
                    )
                }
            )
            guard fetched.attribution.localCapacityUnavailable else {
                resolved = fetched
                break
            }
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.hierarchy.requestTimeout
                    )
                )
            } catch {
                return false
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchySessions[peer.key]?.sessionID == peer.sessionID,
                  hierarchyPeers[peer.key] == .parent else {
                return false
            }
        }
        guard let attachment = resolved.value else {
            return false
        }
        guard let envelope = try? ChildValidationPackageEnvelope.decode(
            attachment.envelopeBytes,
            maximumEncodedSize:
                configuration.resourcePolicy.maximumParentWitnessBytes
        ) else {
            return false
        }
        guard let gate = parentFactGate,
              let gated = try? gate.accept(envelope, from: peer) else {
            return false
        }
        guard gated.package.proof.rootCID == summary.rootCID,
              let directHop = await gated.package.proof.directHop(),
              directHop.childCID == summary.childCID else {
            return false
        }
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else {
            return false
        }
        do {
            try await process.retainParentEvidence(
                sourceID: sourceID,
                ordinal: summary.ordinal,
                attachment: attachment,
                package: gated,
                advanceScan: advanceScan
            )
            _ = try await process.beginContextualCandidateHandoff(
                candidateCID: summary.childCID
            )
        } catch {
            return false
        }
        return await enqueueRetainedParentCandidate(
            CandidateSeed(blockCID: summary.childCID, package: gated),
            generation: generation,
            process: process
        )
    }

    private func handleHierarchy(
        _ message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        if message.topic == NodeNetworkTopic.hierarchyHello {
            await handleHierarchyHello(
                message.payload,
                peer: peer,
                generation: generation,
                process: process
            )
            return
        }
        guard hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              let role = hierarchyPeers[peer.key] else { return }

        switch (message.topic, role) {
        case (NodeNetworkTopic.securingWorkRequest, .child(let childPath)):
            guard let request = try? InheritedWorkRequestMessage.decoded(
                message.payload
            ) else { return }
            await respondToInheritedWorkRequest(
                request,
                from: peer,
                childPath: childPath,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.inheritedWorkPush, .parent):
            guard !configuration.address.isNexus else { return }
            guard let push = try? InheritedWorkPushMessage.decoded(message.payload) else {
                await rejectParentWorkStream(
                    from: peer,
                    generation: generation,
                    process: process
                )
                return
            }
            do {
                var assembler = parentWorkAssembler.flatMap {
                    $0.sessionID == peer.sessionID ? $0 : nil
                } ?? ParentWorkAssembler(sessionID: peer.sessionID)
                guard let result = assembler.ingest(push) else {
                    await rejectParentWorkStream(
                        from: peer,
                        generation: generation,
                        process: process
                    )
                    return
                }
                parentWorkAssembler = assembler
                guard case .completed(let completeSnapshot) = result else {
                    return
                }
                guard let sourceID = assembler.completedSourceID else {
                    await rejectParentWorkStream(
                        from: peer,
                        generation: generation,
                        process: process
                    )
                    return
                }
                let commit: ChainCommit?
                if let inheritedWorkHandler = handlers?.inheritedWork {
                    commit = try await inheritedWorkHandler(
                        completeSnapshot,
                        sourceID,
                        assembler.completedBaseRevision,
                        peer.key.hex
                    )
                } else {
                    commit = try await process.applyInheritedWorkExport(
                        completeSnapshot,
                        sourceID: sourceID,
                        baseRevision: assembler.completedBaseRevision,
                        from: peer.key.hex
                    )
                }
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                guard configuredParentPeer()?.sessionID == peer.sessionID else {
                    return
                }
                let becameReady = await setParentWorkReady(true, from: peer)
                guard parentWorkReady,
                      configuredParentPeer()?.sessionID == peer.sessionID else {
                    return
                }
                // A parent's newly inherited work is itself exportable work
                // for this chain's direct children even when this chain's tip
                // remains unchanged.
                await pushInheritedWork(
                    generation: generation,
                    process: process
                )
                if becameReady || commit?.canonicalChanged == true {
                    try? await canonicalTipDidChange(
                        generation: generation,
                        process: process
                    )
                }
            } catch {
                // The parent has already advanced its local export cursor.
                // Reconnecting resets that cursor and gets the whole monotone
                // view again; a direct parent is configured to reconnect.
                await rejectParentWorkStream(
                    from: peer,
                    generation: generation,
                    process: process
                )
            }

        case (NodeNetworkTopic.childEvidenceAvailable, .parent):
            guard
                let available = try? ChildEvidenceAvailableMessage.decoded(
                message.payload
                ), available.childPath == configuration.chainPath
            else { return }
            let handled = appendParentEvidence(
                [IssuedChildEvidenceSummary(
                    ordinal: available.ordinal,
                    childCID: available.childCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                )],
                sourceID: available.sourceID,
                advanceScan: false,
                from: peer,
                generation: generation,
                process: process
            )
            if handled == nil {
                await hierarchy.recycleSession(ifCurrent: peer)
            }

        case (NodeNetworkTopic.childEvidenceIndexRequest, .child(let childPath)):
            guard let directory = childPath.last,
                  let request = try? ChildEvidenceIndexRequestMessage.decoded(
                    message.payload
                ), request.childPath == childPath
            else { return }
            guard let head = try? await process.issuedChildEvidenceScanHead(
                    directory: directory
                  )
            else { return }
            let sameSource = request.sourceID == head.sourceID
            let cursor = sameSource ? request.cursor : 0
            let through = sameSource
                ? (request.through ?? head.throughOrdinal)
                : head.throughOrdinal
            guard through <= head.throughOrdinal,
                  let summaries = try? await process.issuedChildEvidenceSummaries(
                    directory: directory,
                    afterOrdinal: cursor,
                    throughOrdinal: through,
                    limit: ChildEvidenceIndexResponseMessage.maximumEntries + 1
                  ), isCurrentRuntime(
                    generation: generation,
                    process: process
                  )
            else {
                return
            }
            let page = Array(
                summaries.prefix(
                ChildEvidenceIndexResponseMessage.maximumEntries
            ))
            guard
                let payload = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: childPath,
                sourceID: head.sourceID,
                cursor: cursor,
                through: through,
                entries: page,
                next: summaries.count > page.count
                    ? (page.last?.ordinal ?? cursor)
                    : through
                ).encoded()
            else { return }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )
            guard case .enqueued = result else { return }
            if summaries.count <= page.count {
                completeChildEvidenceIndex(for: peer)
            }
        case (NodeNetworkTopic.childEvidenceIndexResponse, .parent):
            guard
                let response = try? ChildEvidenceIndexResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingEvidenceIndexes[response.requestID],
                  pending.peer.sessionID == peer.sessionID,
                  response.childPath == pending.request.childPath,
                  (response.sourceID == pending.request.sourceID
                    ? response.cursor == pending.request.cursor
                        && pending.request.through.map({
                            response.through == $0
                        }) ?? true
                    : response.cursor == 0)
            else { return }
            pendingEvidenceIndexes.removeValue(forKey: response.requestID)
            scheduleParentEvidencePage(
                response,
                from: peer,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.childCandidateRequest, .parent):
            guard
                let request = try? ChildCandidateRequestMessage.decoded(
                    message.payload
                  ), request.childPath == configuration.chainPath,
                  let parent = _contentBoundBlock(
                    cid: request.parentCID,
                    data: request.parentData
                )
            else { return }
            startChildCandidateBuild(
                request,
                parent: parent,
                peer: peer,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.childCandidateResponse, .child(let childPath)):
            guard
                let response = try? ChildCandidateResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingChildCandidates[response.requestID],
                  pending.peerKey == peer.key,
                  pending.childPath == childPath,
                  response.childPath == childPath,
                  pending.parentCID == response.parentCID,
                  let directory = childPath.last,
                  let block = _contentBoundBlock(
                    cid: response.childCID,
                    data: response.blockData
                )
            else { return }
            let candidate = DirectChildCandidate(
                directory: directory,
                block: block,
                searchWitness: response.searchWitness,
                deploymentWitness: response.deploymentWitness,
                parentCreatedGenesis: false,
                advertiserPeerKey: peer.key
            )
            guard await schedulingTargets(for: candidate) != nil else {
                return
            }
            pendingChildCandidates.removeValue(forKey: response.requestID)
            pending.continuation.resume(returning: candidate)

        case (NodeNetworkTopic.childCandidateReservationRequest, .parent):
            guard let request = try?
                    ChildCandidateReservationRequestMessage.decoded(
                        message.payload
                    ),
                  request.childPath == configuration.chainPath else { return }
            guard let session = parentEvidenceSession(for: peer),
                  !failedParentEvidenceSessions.contains(session),
                  activeParentCandidateReservations.insert(session).inserted
            else {
                await hierarchy.recycleSession(ifCurrent: peer)
                return
            }
            let evidenceTail = parentEvidenceTails[session]?.task
            Task { [weak self] in
                await self?.respondToCandidateReservation(
                    request,
                    from: peer,
                    session: session,
                    after: evidenceTail,
                    generation: generation,
                    process: process
                )
            }

        case (NodeNetworkTopic.childCandidateReservationResponse,
              .child(let childPath)):
            guard let response = try?
                    ChildCandidateReservationResponseMessage.decoded(
                        message.payload
                    ),
                  let pending = pendingCandidateReservations[
                    response.requestID
                  ],
                  pending.peer.key == peer.key,
                  pending.peer.sessionID == peer.sessionID,
                  pending.childPath == childPath,
                  response.childPath == childPath else { return }
            finishCandidateReservation(
                response.requestID,
                accepted: response.accepted,
                generation: generation
            )

        default:
            break
        }
    }

    private func handleHierarchyHello(
        _ payload: Data,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard expectsHierarchyHello(from: peer) else { return }
        guard peer.role == .endpoint, peer.route == .direct,
            let remote = try? ChainHello.decode(payload)
        else {
            await hierarchy.disconnectSession(ifCurrent: peer)
            return
        }

        guard
            let role = Self.hierarchyRole(
            for: remote,
            peerKey: peer.key.hex,
            configuration: configuration
        )
        else {
            await hierarchy.disconnectSession(ifCurrent: peer)
            return
        }

        if case .child(let path) = role {
            guard let directory = path.last else {
                await hierarchy.disconnectSession(ifCurrent: peer)
                return
            }
            guard (try? await process.hasIssuedChildDirectory(directory)) == true else {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                // A compatible immediate child may start before its
                // deployment carrier is accepted. Close this session without
                // suppressing its next inbound attempt; the directory gate is
                // checked again on the replacement session.
                await hierarchy.recycleSession(ifCurrent: peer)
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  expectsHierarchyHello(from: peer) else {
                return
            }
        }
        guard isCurrentRuntime(generation: generation, process: process),
              expectsHierarchyHello(from: peer) else {
            return
        }
        hierarchyHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
        if let existing = hierarchyPeers[peer.key] {
            if existing != role {
                await hierarchy.disconnectSession(ifCurrent: peer)
                return
            }
        }
        if hierarchySessions[peer.key]?.sessionID != peer.sessionID {
            childEvidenceReadyPeers.remove(peer.key)
            cancelChildEvidenceReadyWaiters(for: peer.key)
        }
        hierarchyPeers[peer.key] = role
        hierarchySessions[peer.key] = peer
        if case .child = role {
            dirtyCandidateReservationPeers.insert(peer.key)
        }
        scheduleHierarchyHelloFollowup(
            role: role,
            peer: peer,
            generation: generation,
            process: process
        )
    }

    private func scheduleHierarchyHelloFollowup(
        role: HierarchyPeer,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        Task { [weak self] in
            await self?.finishHierarchyHello(
                role: role,
                peer: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func finishHierarchyHello(
        role: HierarchyPeer,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
            return
        }
        if case .parent = role {
            await requestInheritedWork(
                from: peer,
                generation: generation,
                process: process
            )
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
        } else if case .child(let childPath) = role {
            guard await waitForChildEvidenceReady(peer: peer) else {
                _ = clearHierarchyAuthorization(for: peer.key)
                await hierarchy.recycleSession(ifCurrent: peer)
                return
            }
            await acquireCandidateReservationReconciliation()
            defer { releaseCandidateReservationReconciliation() }
            if let removal = candidateReservationRemovalFlushes[peer.key] {
                await removal.task.value
            }
            guard
                  isCurrentRuntime(generation: generation, process: process),
                  hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
                return
            }
            let accepted = await requestCandidateReservation(
                candidateCIDs: (desiredCandidateReservations[peer.key] ?? [])
                    .sorted(),
                childPath: childPath,
                peer: peer,
                generation: generation,
                process: process
            )
            if accepted {
                dirtyCandidateReservationPeers.remove(peer.key)
            } else {
                dirtyCandidateReservationPeers.insert(peer.key)
            }
            scheduleChildProofRecovery(
                generation: generation,
                process: process
            )
        }
    }

    private func scheduleChildProofRecovery(
        generation: UInt64,
        process: ChainProcess
    ) {
        if childProofRecoveryTask != nil {
            if childProofRecoveryGeneration == generation {
                childProofRecoveryNeedsRefresh = true
            }
            return
        }
        childProofRecoveryGeneration = generation
        childProofRecoveryNeedsRefresh = false
        childProofRecoveryTask = Task { [weak self] in
            await self?.recoverChildProofs(
                generation: generation,
                process: process
            )
        }
    }

    private func recoverChildProofs(
        generation: UInt64,
        process: ChainProcess
    ) async {
        repeat {
            childProofRecoveryNeedsRefresh = false
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await retryRecoveredChildProofs(
                generation: generation,
                process: process
            )
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await retryCurrentTipChildProofs(
                generation: generation,
                process: process
            )
        } while childProofRecoveryNeedsRefresh

        guard childProofRecoveryGeneration == generation,
              self.process === process else { return }
        childProofRecoveryTask = nil
        childProofRecoveryGeneration = nil
        childProofRecoveryNeedsRefresh = false
    }

    private func scheduleHierarchyHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        hierarchyHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
        nextHelloDeadlineToken &+= 1
        let token = nextHelloDeadlineToken
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.hierarchyHelloTimedOut(
                peer: peer,
                generation: generation,
                token: token
            )
        }
        hierarchyHelloDeadlines[peer.key] = HelloDeadline(
            token: token,
            sessionID: peer.sessionID,
            task: task
        )
    }

    private func scheduleOverlayHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        overlayHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
        nextHelloDeadlineToken &+= 1
        let token = nextHelloDeadlineToken
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.overlayHelloTimedOut(
                peer: peer,
                generation: generation,
                token: token
            )
        }
        overlayHelloDeadlines[peer.key] = HelloDeadline(
            token: token,
            sessionID: peer.sessionID,
            task: task
        )
    }

    private func expectsOverlayHello(from peer: AuthenticatedPeer) -> Bool {
        overlaySessions[peer.key]?.sessionID == peer.sessionID
            && overlayHelloDeadlines[peer.key]?.sessionID == peer.sessionID
    }

    private func overlayHelloTimedOut(
        peer: AuthenticatedPeer,
        generation: UInt64,
        token: UInt64
    ) async {
        guard isCurrentGeneration(generation), isRunning,
              overlayHelloDeadlines[peer.key]?.token == token,
              overlayHelloDeadlines[peer.key]?.sessionID == peer.sessionID,
              overlayPeers[peer.key]?.sessionID != peer.sessionID else { return }
        overlayHelloDeadlines.removeValue(forKey: peer.key)
        overlaySessions.removeValue(forKey: peer.key)
        await overlay.recycleSession(ifCurrent: peer)
    }

    private func expectsHierarchyHello(from peer: AuthenticatedPeer) -> Bool {
        Self.hierarchyHelloMatches(
            sessionID: peer.sessionID,
            deadlineSessionID: hierarchyHelloDeadlines[peer.key]?.sessionID
        )
    }

    static func hierarchyHelloMatches(
        sessionID: Data,
        deadlineSessionID: Data?
    ) -> Bool {
        deadlineSessionID == sessionID
    }

    private func hierarchyHelloTimedOut(
        peer: AuthenticatedPeer,
        generation: UInt64,
        token: UInt64
    ) async {
        guard isCurrentGeneration(generation),
            isRunning,
            hierarchyHelloDeadlines[peer.key]?.token == token,
            hierarchyHelloDeadlines[peer.key]?.sessionID == peer.sessionID,
            hierarchyPeers[peer.key] == nil
        else { return }
        hierarchyHelloDeadlines.removeValue(forKey: peer.key)
        await hierarchy.recycleSession(ifCurrent: peer)
    }


    @discardableResult
    private func enqueueCandidate(_ seed: CandidateSeed) -> Bool {
        guard isRunning else { return false }
        let result = candidateAcquirer.observe(seed)
        serviceCandidateAcquirer()
        return result.accepted
    }

    private func candidateProvider(
        _ peer: AuthenticatedPeer
    ) -> CandidateProvider {
        CandidateProvider(
            publicKey: peer.id.publicKey,
            sessionID: peer.sessionID
        )
    }

    private func overlayPeer(
        for provider: CandidateProvider
    ) -> AuthenticatedPeer? {
        guard let key = try? PeerKey(provider.publicKey),
              let peer = overlayPeers[key],
              peer.sessionID == provider.sessionID else { return nil }
        return peer
    }

    private func serviceCandidateAcquirer() {
        if candidateAcquirer.takeInventoryRestart() {
            restartAcceptedLeavesSync()
        }
        if candidateAcquirer.hasTimedWait {
            scheduleWaitingCandidateRetry()
        }
        if candidateAcquirer.hasReadyCandidate {
            startCandidateWorker()
        }
    }

    private func startCandidateWorker() {
        guard candidateWorker == nil else { return }
        let generation = runtimeGeneration
        candidateWorkerGeneration = generation
        candidateWorker = Task { [weak self] in
            await self?.drainCandidateAdmissions(generation: generation)
        }
    }

    private func drainCandidateAdmissions(generation: UInt64) async {
        defer { finishCandidateWorker(generation: generation) }
        while isRunning, runtimeGeneration == generation,
              let candidate = candidateAcquirer.next() {
            guard let process,
                  isCurrentRuntime(
                    generation: generation,
                    process: process
                  ) else { return }
            await admitCandidate(
                candidate,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ) else { return }
            serviceCandidateAcquirer()
            await resumeAcceptedLeavesSync(
                generation: generation,
                process: process
            )
        }
    }

    private func finishCandidateWorker(generation: UInt64) {
        guard candidateWorkerGeneration == generation else { return }
        candidateWorker = nil
        candidateWorkerGeneration = nil
        if isRunning, candidateAcquirer.hasReadyCandidate {
            startCandidateWorker()
        }
    }

    private func completeCandidate(
        _ candidate: Candidate,
        resolution: CandidateAcquirer.Resolution,
        deficientProviders: Set<CandidateProvider> = []
    ) {
        _ = candidateAcquirer.complete(
            candidate.ticket,
            resolution: resolution,
            deficientProviders: deficientProviders
        )
        serviceCandidateAcquirer()
    }

    private func admitCandidate(
        _ candidate: Candidate,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard let admissionHandler = handlers?.admission else { return }
        let authenticatedPackage: AuthenticatedChildPackage?
        if let package = candidate.package {
            authenticatedPackage = package
        } else if let rootCID = candidate.recoveryRootCID {
            guard let recovered = try? await process
                .recoveredAuthenticatedChildPackage(
                    for: candidate.blockCID,
                    rootCID: rootCID
                ) else {
                completeCandidate(candidate, resolution: .wait(.evidence))
                return
            }
            authenticatedPackage = recovered
        } else {
            authenticatedPackage = nil
        }
        var failedOverlayProviders = Set<CandidateProvider>()
        let childDirectories = authenticatedChildDirectories()
        var attempt: (
            value: NodeAdmissionOutcome,
            attribution: IvyRootContentSource.Attribution
        )?
        let header = BlockHeader(
                        rawCID: candidate.blockCID,
                        node: nil,
                        encryptionInfo: nil
        )
        var exactSources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource,
            plane: CandidateSourcePlane?
        )]
        let overlaySources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource,
            plane: CandidateSourcePlane?
        )] = candidate.providers.compactMap(overlayPeer(for:)).sorted {
            $0.id.publicKey < $1.id.publicKey
        }.map {
            (
                peer: $0,
                source: candidateContentSource(
                    preferred: overlay,
                    peer: $0
                ),
                plane: .overlay
            )
        }
        exactSources = []
        if authenticatedPackage?.package.parentGenesisLink != nil,
           let parent = configuredParentPeer() {
            exactSources.append((
                parent,
                candidateContentSource(
                    preferred: hierarchy,
                    peer: parent
                ),
                .hierarchy
            ))
        }
        exactSources.append(contentsOf: overlaySources)
        // A verified CID remains discoverable even when its first advertiser
        // fails. Ivy resolves public pins to an exact authenticated supplier.
        exactSources.append((nil, remoteContentSource, .overlay))
        for exact in exactSources {
            let initialResponse: AttributedVolumeResponse?
            if let peer = exact.peer, let plane = exact.plane {
                let response: AttributedVolumeResponse
                switch plane {
                case .overlay:
                    response = await overlay.fetchVolume(
                        rootCID: candidate.blockCID,
                        from: peer
                    )
                case .hierarchy:
                    response = await hierarchy.fetchVolume(
                        rootCID: candidate.blockCID,
                        from: peer
                    )
                }
                if response.failure == .localCapacityUnavailable {
                    continue
                }
                if response == .empty {
                    // Empty has no attributable supplier: Ivy also uses it for
                    // transient session, timeout, and enqueue failures. Keep
                    // the exact advertiser available for a quick retry.
                    continue
                }
                let volume = SerializedVolume(
                    root: response.rootCID,
                    entries: response.entries
                )
                guard response.servedBy == peer.id,
                      response.rootCID == candidate.blockCID else {
                    if plane == .overlay {
                        failedOverlayProviders.insert(
                            candidateProvider(peer)
                        )
                    }
                    await reportDeficientVolume(
                        candidate.blockCID,
                        servedBy: peer.id,
                        on: plane
                    )
                    continue
                }
                guard (try? volume.validate()) != nil else {
                    if plane == .overlay {
                        failedOverlayProviders.insert(
                            candidateProvider(peer)
                        )
                    }
                    await reportDeficientVolume(
                        candidate.blockCID,
                        servedBy: peer.id,
                        on: plane
                    )
                    continue
                }
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else { return }
                switch plane {
                case .overlay:
                    guard overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                        continue
                    }
                case .hierarchy:
                    guard configuredParentPeer()?.sessionID == peer.sessionID else {
                        continue
                    }
                }
                initialResponse = response
            } else {
                initialResponse = nil
            }
            let capture = IvyRootContentSource.AttributionCapture()
            do {
                let resolved = try await exact.source.withRootTracing(
                    candidate.blockCID,
                    initialResponse: initialResponse,
                    capture: capture
                ) { session in
                    try await Self.enforceLocalAdmissionPolicy(
                        candidateCID: candidate.blockCID,
                        childPackage: authenticatedPackage,
                        source: session,
                        configuration: configuration
                    )
                    return try await admissionHandler(NetworkCandidateAdmission(
                        header: header,
                        authenticatedChildPackage: authenticatedPackage,
                        preparingChildDirectories: childDirectories,
                        contentSource: session
                    ))
                }
                await reportDeficientVolumes(resolved.attribution)
                // Admission durably records any unresolved direct-child
                // routes. The runtime's single coalesced worker owns their
                // availability retry and publishes each completed proof.
                scheduleChildProofRecovery(
                    generation: generation,
                    process: process
                )
                attempt = resolved
                break
            } catch {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                if error is NodePolicyDecline {
                    completeCandidate(
                        candidate,
                        resolution: .terminal,
                        deficientProviders: failedOverlayProviders
                    )
                    return
                }
                if let failure = error as? ChainAdmissionFailure {
                    let decision = NodeAdmissionDecision(failure)
                    if decision.shouldRetryWhenEvidenceChanges {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.evidence),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                    if decision.shouldRetryLater {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                }
                if error is CancellationError {
                    completeCandidate(
                        candidate,
                        resolution: .wait(.content),
                        deficientProviders: failedOverlayProviders
                    )
                    return
                }
                if let attribution = capture.snapshot() {
                    await reportDeficientVolumes(attribution)
                    if attribution.allResponsesComplete,
                       !attribution.localCapacityUnavailable,
                       !attribution.contentUnavailable {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
            }
        }
        guard let attempt else {
            completeCandidate(
                candidate,
                resolution: .wait(.content),
                deficientProviders: failedOverlayProviders
            )
            return
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let outcome = attempt.value
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        if outcome.parentCarrierLink != nil {
            _ = await announceCurrentCarrierChildEvidence(
                directories: childDirectories,
                carrierCID: candidate.blockCID,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            if let authenticated = authenticatedPackage,
               let edge = await DirectChildEdge.derive(
                    from: authenticated.package.proof
               ), let edgeCID = edge.edgeCID {
                if authenticated.parentCarrierCertificate != nil,
                   authenticated.package.parentGenesisLink == nil
                        || authenticated.parentGenesisCertificate != nil,
                   let portableAttachmentCID = try? await process
                        .portableEvidenceVolumeCID(
                            scope: .incomingCarrier,
                            edgeCID: edgeCID,
                            rootCID: authenticated.package.proof.rootCID
                        ) {
                    await announcePortableAttachmentAvailability(
                        edgeCID: edgeCID,
                        rootCID: authenticated.package.proof.rootCID,
                        attachmentCID: portableAttachmentCID,
                        generation: generation,
                        process: process
                    )
                }
            }
        }

        if outcome.decision == .invalid {
            if attempt.attribution.allResponsesComplete,
               let supplierKey = attempt.attribution.soleRemoteSupplierPublicKey,
               let supplier = try? PeerKey(supplierKey),
               overlayPeers[supplier] != nil,
               configuration.address.isNexus || outcome.parentCarrierLink != nil {
                await overlay.reportDeficientContent(
                    rootCID: candidate.blockCID,
                    servedBy: PeerID(publicKey: supplierKey)
                )
            }
        }
        let resolution: CandidateAcquirer.Resolution
        if let predecessor = outcome.sameChainPredecessor {
            resolution = .predecessor(predecessor.predecessorCID)
        } else if outcome.decision.isAccepted {
            resolution = .connected
        } else if outcome.decision == .unavailable(nil),
                  (
                    attempt.attribution.contentUnavailable
                        || attempt.attribution.localCapacityUnavailable
                  ) {
            resolution = .wait(.content)
        } else if outcome.decision.shouldRetryWhenEvidenceChanges {
            resolution = .wait(.evidence)
        } else if outcome.decision.shouldRetryLater {
            resolution = .wait(.later)
        } else {
            resolution = .terminal
        }
        completeCandidate(
            candidate,
            resolution: resolution,
            deficientProviders: failedOverlayProviders
        )
    }

    private nonisolated static func enforceLocalAdmissionPolicy(
        candidateCID: String,
        childPackage: AuthenticatedChildPackage?,
        source: any ContentSource,
        configuration: NodeConfiguration
    ) async throws {
        let rootData = await source.fetch(Set([candidateCID]))[candidateCID]
        if let rootData, let block = Block(data: rootData) {
            let specCID = block.spec.rawCID
            if let specData = await source.fetch(Set([specCID]))[specCID] {
                guard specData.count
                        <= configuration.resourcePolicy.maximumChainSpecBytes
                else {
                    throw NodePolicyDecline.chainSpecTooLarge
                }
                if let resolvedSpec = try? await block.spec.resolve(
                    source: source
                ),
                   let spec = resolvedSpec.node,
                   spec.wasmPolicies.count
                    > configuration.resourcePolicy.maximumWasmPolicies {
                    throw NodePolicyDecline.tooManyWasmPolicies
                }
            }
            if configuration.address.isNexus,
               workForHash(block.proofOfWorkHash())
                    < configuration.minimumRootWork {
                throw NodePolicyDecline.belowMinimumRootWork
            }
        }
        if !configuration.address.isNexus,
           let childPackage,
           case .success(let work) =
                childPackage.package.proof.verifiedRootWork(),
           work < configuration.minimumRootWork {
            throw NodePolicyDecline.belowMinimumRootWork
        }
    }

    private func reportDeficientVolume(
        _ rootCID: String,
        servedBy peer: PeerID,
        on plane: CandidateSourcePlane
    ) async {
        switch plane {
        case .overlay:
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer
            )
        case .hierarchy:
            await hierarchy.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer
            )
        }
    }

    private func reportDeficientVolumes(
        _ attribution: IvyRootContentSource.Attribution
    ) async {
        for (rootCID, suppliers) in attribution.deficientVolumeSuppliers {
            for supplier in suppliers {
                await overlay.reportDeficientContent(
                    rootCID: rootCID,
                    servedBy: PeerID(publicKey: supplier)
                )
            }
        }
    }

    private func candidateContentSource(
        preferred ivy: Ivy,
        peer: AuthenticatedPeer
    ) -> IvyRootContentSource {
        let fallback = overlay
        return IvyRootContentSource { rootCID in
            let response = await ivy.fetchVolume(
                rootCID: rootCID,
                from: peer
            )
            if response.failure == .localCapacityUnavailable {
                return response
            }
            guard response != .empty,
                  response.servedBy == peer.id else {
                return await fallback.fetchVolume(rootCID: rootCID)
            }
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            guard response.rootCID == rootCID,
                  (try? volume.validate()) != nil else {
                await ivy.reportDeficientContent(
                    rootCID: rootCID,
                    servedBy: peer.id
                )
                return await fallback.fetchVolume(rootCID: rootCID)
            }
            return response
        }
    }


    private func scheduleWaitingCandidateRetry() {
        guard waitingCandidateRetryTask == nil,
              candidateAcquirer.hasTimedWait else { return }
        let generation = runtimeGeneration
        waitingCandidateRetryGeneration = generation
        let delay = Self.nanoseconds(Self.futureCandidateRetryInterval)
        waitingCandidateRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.retryWaitingCandidates(generation: generation)
        }
    }

    private func retryWaitingCandidates(generation: UInt64) {
        guard waitingCandidateRetryGeneration == generation else { return }
        waitingCandidateRetryTask = nil
        waitingCandidateRetryGeneration = nil
        guard isCurrentGeneration(generation), isRunning else { return }
        candidateAcquirer.retry()
        serviceCandidateAcquirer()
    }

    private func startAcceptedLeavesRequest(
        from peer: AuthenticatedPeer,
        cursor: AcceptedLeavesCursor,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process),
            pendingAcceptedLeaves == nil,
            candidateAcquirer.reserveAcceptedLeafPage(
                AcceptedLeavesResponseMessage.maximumLeaves
            )
        else {
            return false
        }
        let request = AcceptedLeavesRequestMessage(
            requestID: makeRequestID(),
            afterCID: cursor.afterCID,
            snapshotSequence: cursor.snapshotSequence
        )
        guard let payload = try? request.encoded() else {
            candidateAcquirer.releaseAcceptedLeafPage(
                AcceptedLeavesResponseMessage.maximumLeaves
            )
            return false
        }
        let timeout = planeConfigurations.overlay.requestTimeout
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.acceptedLeavesRequestTimedOut(
                requestID: request.requestID,
                generation: generation
            )
        }
        pendingAcceptedLeaves = PendingAcceptedLeaves(
            peer: peer,
            request: request,
            timeout: timeoutTask
        )
        guard
            case .enqueued = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesRequest,
                payload: payload
            )
        else {
            guard
                isCurrentRuntime(
                    generation: generation,
                    process: process
                )
            else {
                _ = takeAcceptedLeavesRequest()
                return false
            }
            _ = takeAcceptedLeavesRequest()
            nextAcceptedLeaves = nil
            enqueueAcceptedLeavesSession(peer)
            return false
        }
        nextAcceptedLeaves = nil
        acceptedLeavesRetryTask?.cancel()
        acceptedLeavesRetryTask = nil
        return true
    }

    private func acceptedLeavesRequestTimedOut(
        requestID: UInt64,
        generation: UInt64
    ) async {
        guard isRunning, isCurrentGeneration(generation),
            let process,
            let pending = pendingAcceptedLeaves,
            pending.request.requestID == requestID,
            takeAcceptedLeavesRequest() != nil
        else { return }
        nextAcceptedLeaves = nil
        enqueueAcceptedLeavesSession(pending.peer)
        await resumeAcceptedLeavesSync(
            generation: generation,
            process: process
        )
    }

    @discardableResult
    private func takeAcceptedLeavesRequest(
        releasingReservation: Bool = true
    ) -> PendingAcceptedLeaves? {
        guard let pending = pendingAcceptedLeaves else {
            return nil
        }
        pendingAcceptedLeaves = nil
        pending.timeout.cancel()
        if releasingReservation {
            candidateAcquirer.releaseAcceptedLeafPage(
                AcceptedLeavesResponseMessage.maximumLeaves
            )
            serviceCandidateAcquirer()
        }
        return pending
    }

    private func resumeAcceptedLeavesSync(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            isRunning,
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), pendingAcceptedLeaves == nil
        else { return }

        while nextAcceptedLeaves == nil, !acceptedLeavesQueue.isEmpty {
            let peer = acceptedLeavesQueue.removeFirst()
            guard overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                continue
            }
            nextAcceptedLeaves = NextAcceptedLeaves(
                peer: peer,
                cursor: AcceptedLeavesCursor(
                    afterCID: nil,
                    snapshotSequence: nil
                )
            )
        }
        guard let next = nextAcceptedLeaves,
              overlayPeers[next.peer.key]?.sessionID == next.peer.sessionID else {
            nextAcceptedLeaves = nil
            return
        }
        guard
            await startAcceptedLeavesRequest(
                from: next.peer,
                cursor: next.cursor,
                generation: fence.generation,
                process: fence.process
            )
        else {
            scheduleAcceptedLeavesRetry(generation: fence.generation)
            return
        }
    }

    private func enqueueAcceptedLeavesSession(_ peer: AuthenticatedPeer) {
        guard overlayPeers[peer.key]?.sessionID == peer.sessionID,
              pendingAcceptedLeaves?.peer.sessionID != peer.sessionID,
              nextAcceptedLeaves?.peer.sessionID != peer.sessionID,
              !acceptedLeavesQueue.contains(where: {
                  $0.sessionID == peer.sessionID
              }) else { return }
        acceptedLeavesQueue.append(peer)
    }

    private func discardAcceptedLeavesSessions(for peerKey: PeerKey) {
        var sessionIDs = Set(
            acceptedLeavesQueue
                .filter { $0.key == peerKey }
                .map(\.sessionID)
        )
        acceptedLeavesQueue.removeAll { $0.key == peerKey }
        if nextAcceptedLeaves?.peer.key == peerKey {
            sessionIDs.insert(nextAcceptedLeaves!.peer.sessionID)
            nextAcceptedLeaves = nil
        }
        if pendingAcceptedLeaves?.peer.key == peerKey,
           let pending = takeAcceptedLeavesRequest() {
            sessionIDs.insert(pending.peer.sessionID)
        }
        if let session = overlaySessions[peerKey] {
            sessionIDs.insert(session.sessionID)
        }
        if let session = overlayPeers[peerKey] {
            sessionIDs.insert(session.sessionID)
        }
        for sessionID in sessionIDs {
            servingAcceptedLeaves.remove(sessionID)
        }
    }

    private func restartAcceptedLeavesSync() {
        for peer in overlayPeers.values.sorted(by: { $0.key < $1.key }) {
            enqueueAcceptedLeavesSession(peer)
        }
        if isRunning {
            scheduleAcceptedLeavesRetry(generation: runtimeGeneration)
        }
    }

    private func scheduleAcceptedLeavesRetry(generation: UInt64) {
        guard acceptedLeavesRetryTask == nil else { return }
        nextAcceptedLeavesRetryToken &+= 1
        let token = nextAcceptedLeavesRetryToken
        acceptedLeavesRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            await self?.acceptedLeavesRetryTimedOut(
                token: token,
                generation: generation
            )
        }
    }

    private func acceptedLeavesRetryTimedOut(
        token: UInt64,
        generation: UInt64
    ) async {
        guard token == nextAcceptedLeavesRetryToken,
            isCurrentGeneration(generation),
            let process
        else { return }
        acceptedLeavesRetryTask = nil
        await resumeAcceptedLeavesSync(
            generation: generation,
            process: process
        )
    }

    private func requestInheritedWork(
        from parent: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              configuredParentPeer()?.sessionID == parent.sessionID else {
            return
        }
        let cursor = try? await process.inheritedWorkCursor()
        guard let payload = try? InheritedWorkRequestMessage(
            sourceID: cursor?.sourceID,
            revision: cursor?.revision
        ).encoded() else {
            return
        }
        let result = await hierarchy.sendMessage(
            to: parent,
            topic: NodeNetworkTopic.securingWorkRequest,
            payload: payload
        )
        guard case .enqueued = result else {
            await hierarchy.recycleSession(ifCurrent: parent)
            return
        }
    }

    private func requestEvidenceIndex(
        sourceID: String? = nil,
        cursor: UInt64? = nil,
        through: UInt64? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            isRunning,
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), !configuration.address.isNexus,
              pendingEvidenceIndexes.isEmpty,
            let parent = configuredParentPeer()
        else { return }
        let durableCursor: ParentEvidenceScanCursor
        if let sourceID, let cursor {
            durableCursor = ParentEvidenceScanCursor(
                sourceID: sourceID,
                ordinal: cursor
            )
        } else {
            guard let persisted = try? await fence.process
                .parentEvidenceScanCursor()
            else { return }
            durableCursor = persisted
        }
        let request = ChildEvidenceIndexRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            sourceID: durableCursor.sourceID,
            cursor: durableCursor.ordinal,
            through: through
        )
        guard let payload = try? request.encoded() else { return }
        pendingEvidenceIndexes[request.requestID] = .init(
            peer: parent,
            request: request
        )
        let result = await hierarchy.sendMessage(
                to: parent,
                topic: NodeNetworkTopic.childEvidenceIndexRequest,
                payload: payload
        )
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else {
            pendingEvidenceIndexes.removeValue(forKey: request.requestID)
            return
        }
        if result != .notConnected {
            if pendingEvidenceIndexes[request.requestID] != nil {
                scheduleEvidenceIndexTimeout(
                    request.requestID,
                    generation: fence.generation
                )
            }
        } else {
            pendingEvidenceIndexes.removeValue(forKey: request.requestID)
        }
    }

    private func scheduleEvidenceIndexTimeout(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.evidenceIndexRequestTimedOut(
                requestID,
                generation: generation
            )
        }
    }

    private func evidenceIndexRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) async {
        guard isRunning,
            isCurrentGeneration(generation),
            let process,
              let request = pendingEvidenceIndexes.removeValue(
                forKey: requestID
            )
        else { return }
        await requestEvidenceIndex(
            sourceID: request.request.sourceID,
            cursor: request.request.cursor,
            through: request.request.through,
            generation: generation,
            process: process
        )
    }

    private func requestChildCandidate(
        from peerKey: PeerKey,
        childPath: [String],
        parentCID: String,
        parentData: Data,
        rewards: [MiningReward],
        mode: MiningMode,
        deadline: ContinuousClock.Instant,
        generation: UInt64,
        process: ChainProcess
    ) async -> DirectChildCandidate? {
        guard isRunning,
            isCurrentRuntime(generation: generation, process: process),
            pendingChildCandidates.count < Self.maximumDirectChildren
        else {
            return nil
        }
        guard
            let rewards = await resolvedMiningRewards(
            rewards,
                process: process,
                generation: generation
            )
        else { return nil }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return nil
        }
        let remaining = Self.milliseconds(
            ContinuousClock.now.duration(to: deadline)
        )
        guard
            let remoteBudget = Self.remoteChildCandidateBudget(
            parentWaitMilliseconds: remaining
            )
        else { return nil }
        // The receiver starts its monotonic deadline after transit. Give it a
        // strictly smaller budget so serialization and the response have room
        // before our local continuation times out.
        let request = ChildCandidateRequestMessage(
            requestID: makeRequestID(),
            budgetMilliseconds: remoteBudget,
            mode: mode,
            childPath: childPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: rewards
        )
        guard let payload = try? request.encoded() else { return nil }
        return await withCheckedContinuation { continuation in
            guard isCurrentRuntime(generation: generation, process: process) else {
                continuation.resume(returning: nil)
                return
            }
            pendingChildCandidates[request.requestID] = PendingChildCandidateRequest(
                peerKey: peerKey,
                childPath: childPath,
                parentCID: parentCID,
                continuation: continuation
            )
            scheduleChildCandidateTimeout(
                request.requestID,
                after: .milliseconds(Int64(remaining)),
                generation: generation
            )
            Task { [weak self] in
                await self?.sendChildCandidateRequest(
                    requestID: request.requestID,
                    peerKey: peerKey,
                    payload: payload,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    private func requestCandidateReservation(
        candidateCIDs: [String],
        childPath: [String],
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              pendingCandidateReservations.count < Self.maximumPendingRequests
        else { return false }
        let request = ChildCandidateReservationRequestMessage(
            requestID: makeRequestID(),
            childPath: childPath,
            candidateCIDs: candidateCIDs
        )
        guard let payload = try? request.encoded() else { return false }
        let accepted = await withCheckedContinuation { continuation in
            pendingCandidateReservations[request.requestID] =
                PendingCandidateReservation(
                    peer: peer,
                    childPath: childPath,
                    continuation: continuation
                )
            scheduleCandidateReservationTimeout(
                request.requestID,
                generation: generation
            )
            Task { [weak self] in
                guard let self else { return }
                let result = await self.hierarchy.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.childCandidateReservationRequest,
                    payload: payload
                )
                guard case .enqueued = result else {
                    await self.finishCandidateReservation(
                        request.requestID,
                        accepted: false,
                        generation: generation
                    )
                    return
                }
            }
        }
        return accepted
            && isCurrentRuntime(generation: generation, process: process)
            && hierarchySessions[peer.key]?.sessionID == peer.sessionID
            && hierarchyPeers[peer.key] == .child(childPath)
    }

    private func scheduleCandidateReservationTimeout(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
            } catch {
                return
            }
            await self?.finishCandidateReservation(
                requestID,
                accepted: false,
                generation: generation
            )
        }
    }

    private func finishCandidateReservation(
        _ requestID: UInt64,
        accepted: Bool,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation),
              let pending = pendingCandidateReservations.removeValue(
                forKey: requestID
              ) else { return }
        pending.continuation.resume(returning: accepted)
    }

    private func resolvedMiningRewards(
        _ rewards: [MiningReward],
        process: ChainProcess,
        generation: UInt64
    ) async -> [MiningReward]? {
        var resolved: [MiningReward] = []
        resolved.reserveCapacity(rewards.count)
        for reward in rewards {
            if reward.transaction.body.node != nil {
                resolved.append(reward)
                continue
            }
            guard
                let data = try? await process.fetch(
                    rawCid: reward.transaction.body.rawCID
                  ), let body = TransactionBody(data: data),
                isCurrentRuntime(generation: generation, process: process),
                  body.toData() == data,
                  let header = try? HeaderImpl<TransactionBody>(node: body),
                header.rawCID == reward.transaction.body.rawCID
            else {
                return nil
            }
            resolved.append(
                MiningReward(
                chainPath: reward.chainPath,
                transaction: Transaction(
                    signatures: reward.transaction.signatures,
                    body: header
                )
            ))
        }
        return resolved
    }

    private func selectedChildPeers() -> [(Int, PeerKey, [String])] {
        var paths: [String: [String]] = [:]
        var peers: [String: [PeerKey]] = [:]
        for (key, role) in hierarchyPeers {
            guard case .child(let path) = role,
                  childEvidenceReadyPeers.contains(key),
                  !dirtyCandidateReservationPeers.contains(key) else {
                continue
            }
            let pathKey = path.joined(separator: "/")
            paths[pathKey] = path
            peers[pathKey, default: []].append(key)
        }

        let pathKeys = peers.keys.sorted()
        let pathRotation = Self.rotatedPeerIndices(
            peerCount: pathKeys.count,
            start: childPathRotation,
            limit: min(pathKeys.count, Self.maximumDirectChildren)
        )
        childPathRotation = pathRotation.next

        var selectedPaths: [(path: [String], peers: [PeerKey])] = []
        for pathIndex in pathRotation.indices {
            let pathKey = pathKeys[pathIndex]
            guard let path = paths[pathKey] else { continue }
            let keys = peers[pathKey]!.sorted { $0.hex < $1.hex }
            let start = (childPeerRotation[pathKey] ?? 0) % keys.count
            let rotation = Self.rotatedPeerIndices(
                peerCount: keys.count,
                start: start,
                limit: min(Self.maximumPeersPerChildPath, keys.count)
            )
            selectedPaths.append((path, rotation.indices.map { keys[$0] }))
            childPeerRotation[pathKey] = rotation.next
        }

        var selected: [(Int, PeerKey, [String])] = []
        for (pathIndex, peerIndex) in Self.interleavedChildPeerIndices(
            peerCounts: selectedPaths.map { $0.peers.count },
            limit: Self.maximumDirectChildren
        ) {
            let path = selectedPaths[pathIndex]
            selected.append((selected.count, path.peers[peerIndex], path.path))
        }
        return selected
    }

    private func authenticatedChildDirectories() -> [String] {
        let directories: [String] = Array(
            Set<String>(
            hierarchyPeers.values.compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.last
            }
            )
        ).sorted()
        let rotation = Self.rotatedPeerIndices(
            peerCount: directories.count,
            start: childProofPathRotation,
            limit: min(directories.count, Self.maximumDirectChildren)
        )
        childProofPathRotation = rotation.next
        return rotation.indices.map { directories[$0] }
    }

    private func retryCurrentTipChildProofs(
        tipCID: String? = nil,
        directories: [String]? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            )
        else { return }
        let resolvedTipCID: String
        if let tipCID {
            resolvedTipCID = tipCID
        } else {
            guard let currentTipCID = await fence.process.status().tipCID,
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            resolvedTipCID = currentTipCID
        }
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        let directories = directories ?? authenticatedChildDirectories()
        guard !directories.isEmpty else { return }
        try? await remoteContentSource.withRoot(resolvedTipCID) { session in
            try await fence.process.prepareChildProofs(
                for: BlockHeader(
                    rawCID: resolvedTipCID,
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: directories,
                remoteSource: session
            )
        }
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        guard
            await announceCurrentCarrierChildEvidence(
                directories: directories,
                carrierCID: resolvedTipCID,
                generation: fence.generation,
                process: fence.process
            )
        else {
            return
        }
    }

    private func retryRecoveredChildProofs(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), let carrierCIDs = try? await fence.process.pendingChildProofCarrierCIDs(),
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        for carrierCID in carrierCIDs {
            guard
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            let directories = try? await remoteContentSource.withRoot(carrierCID) { session in
                try await fence.process.retryPendingChildProofs(
                    carrierCID: carrierCID,
                    remoteSource: session
                )
            }
            guard
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            if let directories, !directories.isEmpty {
                guard
                    await announceCurrentCarrierChildEvidence(
                        directories: directories,
                        carrierCID: carrierCID,
                        generation: fence.generation,
                        process: fence.process
                    )
                else { return }
            }
        }
    }

    private func sendChildCandidateRequest(
        requestID: UInt64,
        peerKey: PeerKey,
        payload: Data,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard pendingChildCandidates[requestID] != nil,
              case .child? = hierarchyPeers[peerKey],
              let peer = hierarchySessions[peerKey]
        else {
            finishChildCandidateRequest(requestID, with: nil)
            return
        }
        let result = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childCandidateRequest,
            payload: payload
        )
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard case .enqueued = result else {
            finishChildCandidateRequest(requestID, with: nil)
            return
        }
    }

    private func startChildCandidateBuild(
        _ request: ChildCandidateRequestMessage,
        parent: Block,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID] == nil,
              childCandidateBuilds.count < Self.maximumConcurrentChildBuilds,
            let builder = handlers?.childCandidateBuilder
        else { return }
        let budget = min(
            UInt64(request.budgetMilliseconds),
            Self.milliseconds(planeConfigurations.hierarchy.requestTimeout)
        )
        guard budget > 0 else { return }
        let deadline = ContinuousClock.now + .milliseconds(Int64(budget))
        nextChildCandidateBuildToken &+= 1
        let token = nextChildCandidateBuildToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.buildChildCandidate(
                request,
                parent: parent,
                peer: peer,
                deadline: deadline,
                builder: builder,
                token: token,
                generation: generation,
                process: process
            )
        }
        childCandidateBuilds[request.requestID] = ChildCandidateBuild(
            peerKey: peer.key,
            token: token,
            task: task
        )
        scheduleChildCandidateBuildTimeout(
            request.requestID,
            after: .milliseconds(Int64(budget)),
            token: token,
            generation: generation
        )
    }

    private func buildChildCandidate(
        _ request: ChildCandidateRequestMessage,
        parent: Block,
        peer: AuthenticatedPeer,
        deadline: ContinuousClock.Instant,
        builder: ContextualChildCandidateBuilder,
        token: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token
        else {
            return
        }
        defer {
            if isCurrentRuntime(generation: generation, process: process),
                childCandidateBuilds[request.requestID]?.token == token
            {
                childCandidateBuilds.removeValue(forKey: request.requestID)
            }
        }
        let parentSource = IvyRootContentSource(
            ivy: hierarchy,
            peer: peer,
            policy: configuration.resourcePolicy
        )
        guard let candidate = try? await parentSource.withRoot(
            request.parentCID,
            operation: { session in
                try await ChildCandidateBudget.$deadline.withValue(deadline) {
                    try await builder(
                        ChildCandidateRequestContext(
                            parentCarrier: parent,
                            rewards: request.rewards,
                            mode: request.mode
                        ),
                        session
                    )
                }
            }
        ) else { return }
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token,
              !Task.isCancelled,
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent,
              candidate.directory == configuration.address.directory,
              let blockData = candidate.block.toData(),
              let childCID = try? BlockHeader(node: candidate.block).rawCID
        else { return }
        guard let payload = try? ChildCandidateResponseMessage(
                requestID: request.requestID,
                childPath: configuration.chainPath,
                parentCID: request.parentCID,
                childCID: childCID,
                blockData: blockData,
                searchWitness: candidate.searchWitness,
                deploymentWitness: candidate.deploymentWitness
            ).encoded() else { return }
        _ = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childCandidateResponse,
            payload: payload
        )
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token
        else {
            return
        }
    }

    private func scheduleChildCandidateTimeout(
        _ requestID: UInt64,
        after timeout: Duration,
        generation: UInt64
    ) {
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.childCandidateRequestTimedOut(
                requestID,
                generation: generation
            )
        }
    }

    private func scheduleChildCandidateBuildTimeout(
        _ requestID: UInt64,
        after timeout: Duration,
        token: UInt64,
        generation: UInt64
    ) {
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.cancelChildCandidateBuild(
                requestID,
                token: token,
                generation: generation
            )
        }
    }

    private func childCandidateRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation) else { return }
        finishChildCandidateRequest(requestID, with: nil)
    }

    private func cancelChildCandidateBuild(
        _ requestID: UInt64,
        token: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation),
            childCandidateBuilds[requestID]?.token == token
        else { return }
        childCandidateBuilds.removeValue(forKey: requestID)?.task.cancel()
    }

    private func finishChildCandidateRequest(
        _ requestID: UInt64,
        with candidate: DirectChildCandidate?
    ) {
        pendingChildCandidates.removeValue(
            forKey: requestID
        )?.continuation.resume(returning: candidate)
    }

    private func cancelChildCandidateWork(for peerKey: PeerKey) {
        let pendingIDs = pendingChildCandidates.compactMap { requestID, pending in
            pending.peerKey == peerKey ? requestID : nil
        }
        for requestID in pendingIDs {
            finishChildCandidateRequest(requestID, with: nil)
        }
        let buildIDs = childCandidateBuilds.compactMap { requestID, build in
            build.peerKey == peerKey ? requestID : nil
        }
        for requestID in buildIDs {
            childCandidateBuilds.removeValue(forKey: requestID)?.task.cancel()
        }
    }

    private func scheduleRecoveryTimeout(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.recoveryRequestTimedOut(
                requestID,
                generation: generation
            )
        }
    }

    private func recoveryRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation) else { return }
        let peer = pendingPortableAttachmentIndexes.removeValue(
            forKey: requestID
        )?.peer
        guard let peer else { return }
        await overlay.recycleSession(ifCurrent: peer)
    }

    private func childCandidateRequestDeadline() -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        let overallDeadline =
            ChildCandidateBudget.deadline
            ?? now + planeConfigurations.hierarchy.requestTimeout
        let remaining = Self.milliseconds(now.duration(to: overallDeadline))
        guard remaining > Self.childCandidateFinalizeReserveMilliseconds else {
            return nil
        }
        return now
            + .milliseconds(
                Int64(
            remaining - Self.childCandidateFinalizeReserveMilliseconds
        ))
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let milliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(milliseconds)
        return additionOverflow ? UInt64.max : total
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        // Keep Duration out of optimized async task frames: the generic Clock
        // sleep overload can trip Swift's task allocator during teardown.
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return additionOverflow ? UInt64.max : total
    }

    static func remoteChildCandidateBudget(
        parentWaitMilliseconds: UInt64
    ) -> UInt32? {
        guard parentWaitMilliseconds > 1 else { return nil }
        let budget =
            parentWaitMilliseconds
            - max(1, parentWaitMilliseconds / 4)
        return UInt32(
            min(
            budget,
            UInt64(ChildCandidateRequestMessage.maximumBudgetMilliseconds)
        ))
    }

    static func rotatedPeerIndices(
        peerCount: Int,
        start: Int,
        limit: Int
    ) -> (indices: [Int], next: Int) {
        guard peerCount > 0, limit > 0 else { return ([], 0) }
        let normalizedStart = start % peerCount
        let count = min(peerCount, limit)
        let indices = (0..<count).map {
            (normalizedStart + $0) % peerCount
        }
        return (indices, (normalizedStart + 1) % peerCount)
    }

    static func interleavedChildPeerIndices(
        peerCounts: [Int],
        limit: Int
    ) -> [(path: Int, peer: Int)] {
        guard limit > 0, peerCounts.allSatisfy({ $0 >= 0 }) else { return [] }
        var result: [(Int, Int)] = []
        for peerIndex in 0..<(peerCounts.max() ?? 0) {
            for pathIndex in peerCounts.indices where peerIndex < peerCounts[pathIndex] {
                result.append((pathIndex, peerIndex))
                if result.count == limit { return result }
            }
        }
        return result
    }

    static func pruneChildPeerRotations(
        _ rotations: inout [String: Int],
        activeRoles: [HierarchyPeer]
    ) {
        let activePaths: Set<String> = Set(
            activeRoles.compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.joined(separator: "/")
        })
        rotations = rotations.filter { activePaths.contains($0.key) }
    }

    private func configuredParentPeer() -> AuthenticatedPeer? {
        guard let parentKey = configuration.parentEndpoint?.publicKey,
              let key = try? PeerKey(parentKey),
              case .parent? = hierarchyPeers[key]
        else { return nil }
        return hierarchySessions[key]
    }

    private func rejectParentWorkStream(
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              configuredParentPeer()?.sessionID == peer.sessionID else {
            return
        }
        parentWorkAssembler = nil
        await setParentWorkReady(false)
        guard isCurrentRuntime(generation: generation, process: process),
              configuredParentPeer()?.sessionID == peer.sessionID else {
            return
        }
        await hierarchy.recycleSession(ifCurrent: peer)
    }

    @discardableResult
    private func setParentWorkReady(
        _ ready: Bool,
        from parent: AuthenticatedPeer? = nil
    ) async -> Bool {
        guard !configuration.address.isNexus else { return false }
        guard let process else { return false }
        let generation = runtimeGeneration
        guard isCurrentRuntime(generation: generation, process: process) else {
            return false
        }
        let readinessHandler = handlers?.parentWorkReadiness
        if ready {
            guard !parentWorkReady else { return false }
            guard let parent,
                  configuredParentPeer()?.sessionID == parent.sessionID else {
                return false
            }
            parentWorkReady = true
            await readinessHandler?(true)
            guard isCurrentRuntime(generation: generation, process: process),
                  parentWorkReady,
                  configuredParentPeer()?.sessionID == parent.sessionID else {
                return false
            }
            return true
        } else {
            guard parentWorkReady else { return false }
            parentWorkReady = false
            parentWorkAssembler = nil
            let childPeers: [AuthenticatedPeer] = hierarchySessions.compactMap {
                key, peer in
                guard case .child? = hierarchyPeers[key] else { return nil }
                return peer
            }
            for child in childPeers {
                _ = clearHierarchyAuthorization(for: child.key)
            }
            for child in childPeers {
                await hierarchy.recycleSession(ifCurrent: child)
            }
            await readinessHandler?(false)
            return false
        }
    }

    private func makeRequestID() -> UInt64 {
        repeat { nextRequestID &+= 1 } while nextRequestID == 0
        return nextRequestID
    }

    static func hierarchyRole(
        for remote: ChainHello,
        peerKey: String,
        configuration: NodeConfiguration
    ) -> HierarchyPeer? {
        if let parent = configuration.parentEndpoint,
            peerKey == parent.publicKey
        {
            let expectedPath = Array(configuration.chainPath.dropLast())
            return
                (try? remote.validateCompatibility(
                expectedNexusGenesisCID: configuration.nexusGenesisCID,
                expectedChainPath: expectedPath
            )).map { .parent }
        }
        guard remote.chainPath.count == configuration.chainPath.count + 1,
            Array(remote.chainPath.dropLast()) == configuration.chainPath
        else {
            return nil
        }
        return
            (try? remote.validateCompatibility(
            expectedNexusGenesisCID: configuration.nexusGenesisCID,
            expectedChainPath: remote.chainPath
        )).map { .child(remote.chainPath) }
    }

    static func merging(
        _ current: AuthenticatedChildPackage?,
        with received: AuthenticatedChildPackage
    ) -> AuthenticatedChildPackage? {
        CandidateAcquirer.mergePackages(current, received)
    }

}

extension Ivy {
    fileprivate func install(
        delegate: IvyDelegate,
        contentSource: (any IvyContentSource)?
    ) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
