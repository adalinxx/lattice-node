import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

public typealias ContextualChildCandidateBuilder = @Sendable (
    _ context: ChildCandidateRequestContext
) async throws -> DirectChildCandidate?

public typealias NetworkAdmissionHandler = @Sendable (
    _ header: BlockHeader,
    _ authenticatedChildPackage: AuthenticatedChildPackage?,
    _ preparingChildDirectories: [String]
) async throws -> NodeAdmissionOutcome

/// Service-owned reconciliation for a parent work push. The runtime owns
/// authenticated routing; the service owns template and mempool projection.
public typealias NetworkInheritedWorkHandler = @Sendable (
    _ snapshot: InheritedWorkSnapshot,
    _ parentAuthorityKey: String
) async throws -> ChainCommit?

public typealias NetworkParentReadinessHandler = @Sendable (
    _ ready: Bool
) async -> Void

public typealias NetworkTransactionHandler = @Sendable (
    _ transaction: Transaction
) async throws -> Bool

public typealias TransactionInventoryProvider = @Sendable () async -> [String]

private enum ChildCandidateBudget {
    @TaskLocal static var deadline: ContinuousClock.Instant?
}

private struct TransactionVolumeContentSource: ContentSource {
    let entries: [String: Data]

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }
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

/// One bounded FIFO is enough: gossip is lossy, while an accepted-leaf page
/// reserves its full capacity before it is requested.
struct CandidateInbox {
    static let capacity = 1_024

    private var pending: Set<String> = []
    private var order: [String] = []
    private var reservedLeafSlots = 0

    var isEmpty: Bool { pending.isEmpty }

    mutating func reserveAcceptedLeafPage() -> Bool {
        guard reservedLeafSlots == 0,
              pending.count <= Self.capacity - AcceptedLeavesResponseMessage.maximumLeaves
        else { return false }
        reservedLeafSlots = AcceptedLeavesResponseMessage.maximumLeaves
        return true
    }

    mutating func releaseAcceptedLeafPage() {
        precondition(reservedLeafSlots == AcceptedLeavesResponseMessage.maximumLeaves)
        reservedLeafSlots = 0
    }

    @discardableResult
    mutating func enqueue(_ cid: String) -> Bool {
        guard pending.insert(cid).inserted else { return true }
        guard pending.count + reservedLeafSlots <= Self.capacity else {
            pending.remove(cid)
            return false
        }
        order.append(cid)
        return true
    }

    mutating func dequeue() -> String? {
        guard !order.isEmpty else { return nil }
        let cid = order.removeFirst()
        pending.remove(cid)
        return cid
    }

    mutating func remove(_ cids: Set<String>) {
        guard !cids.isEmpty else { return }
        pending.subtract(cids)
        order.removeAll { cids.contains($0) }
    }
}

/// Pages one parent-owned fact snapshot without retaining encoded frames.
/// Oversized batches split until each canonical frame fits.
private struct InheritedWorkPushPlan: Sendable {
    let revision: UInt64
    let facts: [InheritedWorkFact]
    let maximumPayloadBytes: Int

    init?(
        snapshot: InheritedWorkSnapshot,
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes
    ) {
        guard maximumPayloadBytes > 0,
              maximumPayloadBytes <= InheritedWorkPushMessage.maximumEncodedBytes,
              snapshot.hasUniqueGrindLocations else {
            return nil
        }
        revision = snapshot.revision
        facts = snapshot.blockCIDs.flatMap { blockCID in
            let measure = snapshot.sourceWork(forBlock: blockCID)
            return measure.grindIDs.sorted().compactMap { grindID in
                measure.work(forGrind: grindID).flatMap {
                    InheritedWorkFact(
                        blockCID: blockCID,
                        grindID: grindID,
                        work: $0
                    )
                }
            }
        }
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

private struct InheritedWorkPushPacker {
    enum Next {
        case payload(Data)
        case finished
        case unencodable
    }

    private let revision: UInt64
    private let facts: [InheritedWorkFact]
    private let maximumPayloadBytes: Int
    private var factIndex = 0
    private var pending: [[InheritedWorkFact]] = []

    init(plan: InheritedWorkPushPlan) {
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
    private(set) var completedRevision: UInt64?
    private var pendingRevision: UInt64?
    private var fragments: [InheritedWorkSnapshot] = []

    init(sessionID: Data) {
        self.sessionID = sessionID
    }

    mutating func ingest(_ snapshot: InheritedWorkSnapshot) -> IngestResult? {
        guard snapshot.revision >= (completedRevision ?? 0) else { return nil }
        if !snapshot.isEmpty {
            if let pendingRevision {
                guard pendingRevision == snapshot.revision else { return nil }
            } else {
                pendingRevision = snapshot.revision
            }
            fragments.append(snapshot)
            return .pending
        }

        if let pendingRevision {
            guard pendingRevision == snapshot.revision else { return nil }
        }
        let completed = Self.merge(fragments + [snapshot])
        completedRevision = snapshot.revision
        pendingRevision = nil
        fragments.removeAll(keepingCapacity: true)
        return .completed(completed)
    }

    private static func merge(
        _ fragments: [InheritedWorkSnapshot]
    ) -> InheritedWorkSnapshot {
        var level = fragments
        while level.count > 1 {
            var next: [InheritedWorkSnapshot] = []
            next.reserveCapacity((level.count + 1) / 2)
            var index = 0
            while index < level.count {
                next.append(index + 1 < level.count
                    ? level[index].union(level[index + 1])
                    : level[index])
                index += 2
            }
            level = next
        }
        return level.first ?? .zero
    }
}

public enum NodeNetworkRuntimeError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case missingIngressHandler
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

/// Two deliberately separate Ivy planes for one recovered chain process.
/// The public overlay carries same-chain candidates and CAS content. The
/// private hierarchy plane carries only direct parent/child facts.
public actor NodeNetworkRuntime: IvyDelegate {
    enum HierarchyPeer: Equatable {
        case parent
        case child([String])
    }

    private struct ProvisionalRoot {
        let volume: SerializedVolume
        var leases: Int
    }

    private struct ProvisionalRootKey: Hashable {
        let generation: UInt64
        let cid: String
    }

    private struct Candidate: Sendable {
        /// A block body is unique by CID, but its authenticated root
        /// attachments are set-valued. Evidence-bearing admissions therefore
        /// get their own queue identity and can never overwrite one another.
        let queueID: String
        let childCID: String
        let recoveryRootCID: String?
        var package: AuthenticatedChildPackage?
        var announcers: [PeerKey: AuthenticatedPeer]
        var isLocallySourced: Bool

        init(
            childCID: String,
            package: AuthenticatedChildPackage?,
            recoveryRootCID: String? = nil,
            queueID: String? = nil,
            announcer: AuthenticatedPeer? = nil
        ) {
            self.recoveryRootCID = package?.package.proof.rootCID
                ?? recoveryRootCID
            self.queueID = queueID
                ?? self.recoveryRootCID.map {
                    childCID + "\0" + $0
                }
                ?? childCID
            self.childCID = childCID
            self.package = package
            announcers = announcer.map { [$0.key: $0] } ?? [:]
            isLocallySourced = announcer == nil
        }
    }

    private struct DurableDescendant: Hashable, Sendable {
        let childCID: String
        let rootCID: String?
    }

    private struct PendingChildEvidenceIndex: Sendable {
        let peer: AuthenticatedPeer
        let request: ChildEvidenceIndexRequestMessage
    }

    private struct PendingPortableAttachmentIndex: Sendable {
        let peer: AuthenticatedPeer
        let request: PortableAttachmentIndexRequestMessage
    }

    private struct RecoveryAttachmentLease: Hashable {
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

    private static let maximumPendingRequests = 1_024
    /// Parent evidence may carry up to one MiB of acquisition bytes. Each
    /// suspended hierarchy stage is capped.
    private static let maximumEvidenceCandidates = 64
    private static let maximumDirectChildren = 64
    private static let maximumDirectChildBytes = 16 * 1024 * 1024
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
    private var provisionalRoots: [ProvisionalRootKey: ProvisionalRoot] = [:]
    private var childEvidenceReadyPeers: Set<PeerKey> = []
    /// Last complete export accepted by each ready direct child session. A
    /// reconnect clears this value and receives a full monotone resend.
    private var inheritedWorkSentByChildPeer: [PeerKey: UInt64] = [:]
    private var inheritedWorkPushes: [PeerKey: InheritedWorkPushState] = [:]
    private var nextInheritedWorkPushToken: UInt64 = 0
    private var overlayHelloDeadlines: [PeerKey: HelloDeadline] = [:]
    private var hierarchyHelloDeadlines: [PeerKey: HelloDeadline] = [:]
    private var waitingDescendants: [String: [Candidate]] = [:]
    /// Restart recovery retains only durable graph obligations. Candidate
    /// packages are intentionally not reconstructed here: once a predecessor
    /// becomes connected, its descendants re-acquire their own evidence.
    private var durableDescendantsByPredecessor:
        [String: Set<DurableDescendant>] = [:]
    /// Connected predecessors release these durable retries gradually so the
    /// ordinary bounded candidate inbox never drops an accepted orphan.
    private var readyDurableDescendants: Set<DurableDescendant> = []
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
    private var queuedCandidates: [String: Candidate] = [:]
    private var candidateInbox = CandidateInbox()
    private var activeCandidate: Candidate?
    private var activeCandidateUpdate: Candidate?
    private var candidateWorker: Task<Void, Never>?
    private var candidateWorkerGeneration: UInt64?
    private var pendingEvidenceIndexes: [UInt64: PendingChildEvidenceIndex] = [:]
    private var pendingPortableAttachmentIndexes:
        [UInt64: PendingPortableAttachmentIndex] = [:]
    private var activeRecoveryAttachments = Set<RecoveryAttachmentLease>()
    private var childCandidateBuilder: ContextualChildCandidateBuilder?
    private var admissionHandler: NetworkAdmissionHandler?
    private var inheritedWorkHandler: NetworkInheritedWorkHandler?
    private var parentReadinessHandler: NetworkParentReadinessHandler?
    private var parentConsensusReady: Bool
    private var transactionHandler: NetworkTransactionHandler?
    private var transactionInventoryProvider: TransactionInventoryProvider?
    private var pendingChildCandidates: [UInt64: PendingChildCandidateRequest] = [:]
    private var childCandidateBuilds: [UInt64: ChildCandidateBuild] = [:]
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
        remoteContentSource = IvyRootContentSource(ivy: overlay)
        hierarchyContentSource = IvyRootContentSource(ivy: hierarchy)
        hello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWorkHex: configuration.minimumRootWork.toHexString()
        )
        parentFactGate = try configuration.parentEndpoint.map {
            try AuthenticatedParentFactGate(
                childPath: configuration.chainPath,
                configuredParentIvyPeerKey: $0.publicKey
            )
        }
        parentConsensusReady = configuration.address.isNexus
    }

    /// Installs both delegates and the recovered process's local content source
    /// before either listener becomes visible. The private plane starts first.
    public func start(process: ChainProcess) async throws {
        try await enqueueStart(process: process).value
    }

    func enqueueStart(process: ChainProcess) -> Task<Void, any Error> {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.startNow(process: process)
        }
        lifecycleTail = Task { _ = try? await operation.value }
        return operation
    }

    private func startNow(process: ChainProcess) async throws {
        guard !isRunning else { throw NodeNetworkRuntimeError.alreadyRunning }
        guard admissionHandler != nil else {
            throw NodeNetworkRuntimeError.missingIngressHandler
        }
        runtimeGeneration = callbackEpoch.advance()
        self.process = process
        for requirement in await process.unresolvedSameChainPredecessors() {
            let roots = try await process.recoveredIncomingCarrierRootCIDs(
                for: requirement.descendantCID
            )
            let descendants = roots.isEmpty
                ? [DurableDescendant(
                    childCID: requirement.descendantCID,
                    rootCID: nil
                )]
                : roots.map {
                    DurableDescendant(
                        childCID: requirement.descendantCID,
                        rootCID: $0
                    )
                }
            durableDescendantsByPredecessor[
                requirement.predecessorCID,
                default: []
            ].formUnion(descendants)
        }
        if !configuration.address.isNexus {
            parentConsensusReady = false
            await parentReadinessHandler?(false)
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
            try await Self.startPlanes(
                startHierarchy: { try await self.hierarchy.start() },
                startOverlay: { try await self.overlay.start() },
                stopOverlay: { await self.overlay.stop() },
                stopHierarchy: { await self.hierarchy.stop() }
            )
            isRunning = true
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
                    after: nil,
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
            parentConsensusReady = false
            await parentReadinessHandler?(false)
        }
        process = nil
        overlaySessions.removeAll()
        overlayPeers.removeAll()
        hierarchyPeers.removeAll()
        hierarchySessions.removeAll()
        parentWorkAssembler = nil
        provisionalRoots.removeAll()
        childEvidenceReadyPeers.removeAll()
        inheritedWorkSentByChildPeer.removeAll()
        for push in inheritedWorkPushes.values { push.task.cancel() }
        inheritedWorkPushes.removeAll()
        for deadline in overlayHelloDeadlines.values { deadline.task.cancel() }
        overlayHelloDeadlines.removeAll()
        for deadline in hierarchyHelloDeadlines.values { deadline.task.cancel() }
        hierarchyHelloDeadlines.removeAll()
        waitingDescendants.removeAll()
        durableDescendantsByPredecessor.removeAll()
        readyDurableDescendants.removeAll()
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
        queuedCandidates.removeAll()
        candidateInbox = CandidateInbox()
        activeCandidate = nil
        activeCandidateUpdate = nil
        pendingEvidenceIndexes.removeAll()
        pendingPortableAttachmentIndexes.removeAll()
        activeRecoveryAttachments.removeAll()
        let pendingChildCandidates = Array(self.pendingChildCandidates.values)
        self.pendingChildCandidates.removeAll()
        for pending in pendingChildCandidates {
            pending.continuation.resume(returning: nil)
        }
        for build in childCandidateBuilds.values { build.task.cancel() }
        childCandidateBuilds.removeAll()
        childPeerRotation.removeAll()
        childPathRotation = 0
        childProofPathRotation = 0
    }

    public func announceBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        guard parentConsensusReady else { return }
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
        guard parentConsensusReady else { return }
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
        guard parentConsensusReady else { return }
        try await announceBlock(
            blockCID,
            generation: generation,
            process: process
        )
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        // Every accepted branch can add inherited work for a direct child.
        // Canonicity is not a work-export filter.
        await pushInheritedWork(
            generation: generation,
            process: process
        )
    }

    /// Installs the local service callback that builds this chain's next
    /// template against an authenticated provisional immediate-parent carrier.
    public func installChildCandidateBuilder(
        _ builder: @escaping ContextualChildCandidateBuilder
    ) {
        childCandidateBuilder = builder
    }

    public func installAdmissionHandler(
        _ handler: @escaping NetworkAdmissionHandler
    ) {
        admissionHandler = handler
    }

    public func installInheritedWorkHandler(
        _ handler: @escaping NetworkInheritedWorkHandler
    ) {
        inheritedWorkHandler = handler
    }

    public func installParentReadinessHandler(
        _ handler: @escaping NetworkParentReadinessHandler
    ) {
        parentReadinessHandler = handler
    }

    public func installTransactionHandler(
        _ handler: @escaping NetworkTransactionHandler
    ) {
        transactionHandler = handler
    }

    public func installTransactionInventoryProvider(
        _ provider: @escaping TransactionInventoryProvider
    ) {
        transactionInventoryProvider = provider
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
              parentConsensusReady,
              context.rewards.count <= ChildCandidateRequestMessage.maximumRewards,
              let parentData = context.parentCarrier.toData(),
              let parentCID = try? BlockHeader(node: context.parentCarrier).rawCID,
            let deadline = childCandidateRequestDeadline()
        else {
            return []
        }
        let parentBoundary = try? VolumeImpl<Block>(node: context.parentCarrier)
        let provisionalBroker = MemoryBroker()
        try? await parentBoundary?.store(
            storer: BrokerStorer(broker: provisionalBroker)
        )
        guard let parentVolume = await provisionalBroker.fetchVolumeLocal(
            root: parentCID
        ) else {
            return []
        }
        guard (try? parentVolume.validate()) != nil else { return [] }
        let generation = runtimeGeneration
        guard retainProvisionalRoot(
            parentVolume,
            generation: generation
        ) else { return [] }
        defer { releaseProvisionalRoot(parentCID, generation: generation) }
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
        guard isCurrentRuntime(generation: generation, process: process) else {
            return []
        }

        // A path claim is not authority. Query several authenticated claimants
        // and rotate priority so a grindable lexicographic key cannot own a slot.
        var selectedDirectories: Set<String> = []
        let selected = candidates.sorted { $0.0 < $1.0 }.compactMap {
            selectedDirectories.insert($0.1.directory).inserted ? $0.1 : nil
        }
        var totalBytes = 0
        return selected.sorted { $0.directory < $1.directory }.filter {
            guard let childData = $0.block.toData(),
                  let childCID = try? BlockHeader(node: $0.block).rawCID,
                  let package = try? ChildAcquisitionPackage(
                    entries: $0.acquisitionEntries,
                    childCID: childCID,
                    childData: childData,
                    maximumBytes: ChildAcquisitionPackage.maximumBytes
                )
            else {
                return false
            }
            let next = totalBytes.addingReportingOverflow(
                package.framedByteCount
            )
            guard !next.overflow,
                next.partialValue <= Self.maximumDirectChildBytes
            else {
                return false
            }
            totalBytes = next.partialValue
            return true
        }
    }

    private func canServeHierarchyContent(to peer: AuthenticatedPeer) -> Bool {
        runtimeGeneration != 0
            && hierarchyPeers[peer.key] != nil
            && hierarchySessions[peer.key]?.sessionID == peer.sessionID
    }

    private func retainProvisionalRoot(
        _ volume: SerializedVolume,
        generation: UInt64
    ) -> Bool {
        let key = ProvisionalRootKey(generation: generation, cid: volume.root)
        if var existing = provisionalRoots[key] {
            guard existing.volume.entries == volume.entries else { return false }
            existing.leases += 1
            provisionalRoots[key] = existing
        } else {
            provisionalRoots[key] = ProvisionalRoot(volume: volume, leases: 1)
        }
        return true
    }

    private func releaseProvisionalRoot(_ cid: String, generation: UInt64) {
        let key = ProvisionalRootKey(generation: generation, cid: cid)
        guard var existing = provisionalRoots[key] else { return }
        existing.leases -= 1
        if existing.leases == 0 {
            provisionalRoots.removeValue(forKey: key)
        } else {
            provisionalRoots[key] = existing
        }
    }

    private func provisionalVolume(forRoot cid: String) -> SerializedVolume? {
        provisionalRoots[
            ProvisionalRootKey(generation: runtimeGeneration, cid: cid)
        ]?.volume
    }

    /// Schedule one serialized export per child peer. The task owns its cursor
    /// until every frame is locally queued; newer parent facts mark one
    /// refresh pass and therefore cannot overtake or disappear behind a
    /// throttled frame.
    private func pushInheritedWork(
        directories: Set<String>? = nil,
        peerKeys: Set<PeerKey>? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard parentConsensusReady,
              let fence = resolvedRuntimeFence(
            generation: generation,
            process: expectedProcess
        ) else { return }
        var peersByChildPath: [[String]: [AuthenticatedPeer]] = [:]
        for (peerKey, role) in hierarchyPeers {
            guard case .child(let childPath) = role,
                  let peer = hierarchySessions[peerKey],
                  peerKeys.map({ $0.contains(peerKey) }) ?? true,
                  directories.map({ childPath.last.map($0.contains) ?? false }) ?? true
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
                if let revision = inheritedWorkSentByChildPeer[peer.key] {
                    if let cached = deltaPlansByRevision[revision] {
                        plan = cached
                    } else {
                        let snapshot = await fence.process
                            .parentSecuringWorkSnapshot(since: revision)
                        plan = snapshot.flatMap {
                            InheritedWorkPushPlan(snapshot: $0)
                        }
                        if let plan { deltaPlansByRevision[revision] = plan }
                    }
                } else {
                    if fullPlan == nil {
                        let snapshot = await fence.process
                            .parentSecuringWorkSnapshot()
                        fullPlan = snapshot.flatMap {
                            InheritedWorkPushPlan(snapshot: $0)
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
        if let sentRevision = inheritedWorkSentByChildPeer[peerKey],
           sentRevision >= plan.revision {
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
        inheritedWorkSentByChildPeer[peerKey] = max(
            inheritedWorkSentByChildPeer[peerKey] ?? 0,
            revision
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
                guard let refreshed = await process.parentSecuringWorkSnapshot(
                    since: inheritedWorkSentByChildPeer[peerKey]
                ), let refreshedPlan = InheritedWorkPushPlan(
                    snapshot: refreshed
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
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes,
        send: @escaping @Sendable (Data) async -> InheritedWorkPushSendResult,
        waitForRetry: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard let plan = InheritedWorkPushPlan(
            snapshot: snapshot,
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
        maximumPayloadBytes: Int = InheritedWorkPushMessage.maximumEncodedBytes
    ) -> [Data]? {
        guard let plan = InheritedWorkPushPlan(
            snapshot: snapshot,
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
        child: Block
    ) async throws -> ChildBlockProof {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        guard let childCID = try? BlockHeader(node: child).rawCID,
              child.toData().flatMap({
                  _contentBoundBlock(cid: childCID, data: $0)
            }) != nil
        else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        let childPath = configuration.chainPath + [childDirectory]
        guard proof.directoryPath == Array(childPath.dropFirst()),
              !childDirectory.isEmpty,
              _isBoundedWireAtom(childCID),
            (try? proof.serialize()) != nil
        else {
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
        guard let directory = childPath.last,
            let evidence = try? await process.issuedChildEvidence(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            isCurrentRuntime(generation: generation, process: process),
            let payload = try? ChildEvidenceAvailableMessage(
                childPath: childPath,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: evidence.attachmentCID
            ).encoded()
        else {
            return isCurrentRuntime(generation: generation, process: process)
        }
        for (key, role) in hierarchyPeers {
            guard case .child(let path) = role,
                path == childPath,
                childEvidenceReadyPeers.contains(key),
                let peer = hierarchySessions[key]
            else { continue }
            guard isCurrentRuntime(generation: generation, process: process) else {
                return false
            }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return false
            }
            switch result {
            case .enqueued, .notConnected:
                break
            case .backpressured, .locallyRejected:
                await hierarchy.recycleSession(ifCurrent: peer)
            }
        }
        return isCurrentRuntime(generation: generation, process: process)
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
                purgeQueuedAnnouncements(from: previous)
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
            // replacement connection must complete its own chain hello.
            let removed = clearHierarchyAuthorization(for: peer.key)
            if case .parent? = removed {
                await setParentConsensusReady(false)
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
                purgeQueuedAnnouncements(from: disconnected)
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
                await setParentConsensusReady(false)
            }
        }
    }

    @discardableResult
    private func clearHierarchyAuthorization(for key: PeerKey) -> HierarchyPeer? {
        hierarchyHelloDeadlines.removeValue(forKey: key)?.task.cancel()
        let removedRole = hierarchyPeers.removeValue(forKey: key)
        hierarchySessions.removeValue(forKey: key)
        childEvidenceReadyPeers.remove(key)
        resetInheritedWorkPush(for: key)
        Self.pruneChildPeerRotations(
            &childPeerRotation,
            activeRoles: Array(hierarchyPeers.values)
        )
        if case .parent? = removedRole {
            pendingEvidenceIndexes.removeAll()
            parentWorkAssembler = nil
        }
        cancelChildCandidateWork(for: key)
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
                    expectedChainPath: configuration.chainPath,
                    expectedMinimumRootWorkHex: configuration.minimumRootWork.toHexString()
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
            schedulePortableAttachmentRecovery(
                PortableAttachmentSummary(
                    edgeCID: available.edgeCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                ),
                from: peer,
                generation: generation,
                process: process
            )
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
            let candidate = Candidate(
                childCID: announcement.blockCID,
                package: nil,
                announcer: peer
            )
            guard enqueueCandidate(candidate) else {
                restartAcceptedLeavesSync()
                return
            }
        case NodeNetworkTopic.predecessorRequest:
            guard let request = try? PredecessorRequestMessage.decoded(message.payload),
                  let payload = try? BlockAnnouncementMessage(
                    blockCID: request.predecessorCID
                ).encoded()
            else { return }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
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
            guard takeAcceptedLeavesRequest() != nil else { return }
            for cid in response.blockCIDs {
                guard enqueueCandidate(Candidate(
                    childCID: cid,
                    package: nil,
                    announcer: peer
                )) else {
                    assertionFailure("accepted-leaf page exceeded its reservation")
                    restartAcceptedLeavesSync()
                    return
                }
            }
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
              transactionHandler != nil,
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
        guard let transactionInventoryProvider,
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
        guard let transactionInventoryProvider,
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
        guard let transactionHandler,
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
        if let transactionInventoryProvider,
           await transactionInventoryProvider().contains(rootCID) {
            return
        }

        let response = await overlay.fetchVolume(rootCID: rootCID, from: peer)
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
            ).resolveRecursive(source: TransactionVolumeContentSource(
                entries: volume.entries
            )),
              resolved.rawCID == rootCID,
              let transaction = resolved.node else {
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer.id
            )
            return
        }
        do {
            guard try await transactionHandler(transaction) else { return }
        } catch {
            return
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
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

    private func schedulePortableAttachmentRecovery(
        _ summary: PortableAttachmentSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard !configuration.address.isNexus,
              let lease = reserveRecoveryAttachment(
            summary.attachmentCID,
            from: peer
        ) else { return }
        Task { [weak self] in
            guard let self else { return }
            let handled = await self.recoverPortableAttachment(
                summary,
                from: peer,
                generation: generation,
                process: process,
                reservedLease: lease
            )
            if !handled { await self.overlay.recycleSession(ifCurrent: peer) }
        }
    }

    private func reserveRecoveryAttachment(
        _ attachmentCID: String,
        from peer: AuthenticatedPeer
    ) -> RecoveryAttachmentLease? {
        let lease = RecoveryAttachmentLease(
            sessionID: peer.sessionID,
            attachmentCID: attachmentCID
        )
        guard !activeRecoveryAttachments.contains(lease),
              activeRecoveryAttachments.count < Self.maximumEvidenceCandidates else {
            return nil
        }
        activeRecoveryAttachments.insert(lease)
        return lease
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

    private func recoverPortableAttachment(
        _ summary: PortableAttachmentSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess,
        reservedLease: RecoveryAttachmentLease? = nil
    ) async -> Bool {
        guard !configuration.address.isNexus else { return false }
        let lease = RecoveryAttachmentLease(
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if let reservedLease {
            guard lease == reservedLease,
                  activeRecoveryAttachments.contains(lease) else { return false }
        } else {
            if activeRecoveryAttachments.contains(lease) { return true }
            guard activeRecoveryAttachments.count < Self.maximumEvidenceCandidates else {
                return false
            }
            activeRecoveryAttachments.insert(lease)
        }
        defer { activeRecoveryAttachments.remove(lease) }
        if (try? await process.childRootAttachment(
            scope: .incomingCarrier,
            edgeCID: summary.edgeCID,
            rootCID: summary.rootCID
        )) != nil {
            return true
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            return false
        }
        // The peer advertising an attachment is responsible for serving its
        // immutable CAS graph. Binding resolution to that exact authenticated
        // session prevents a false summary from being blamed on an honest
        // third-party content provider.
        let source = IvyRootContentSource(ivy: overlay, peer: peer)
        let resolved = await source.withRootTracing(
            summary.attachmentCID
        ) {
            await Self.resolveRecoveryAttachment(
                summary.attachmentCID,
                source: source
            )
        }
        guard let attachment = resolved.value,
              let envelope = try? ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
              ),
              envelope.parentCarrierLink != nil,
              envelope.parentCarrierCertificate != nil,
              let gate = parentFactGate,
              let authority = configuration.parentEndpoint.flatMap({
                  ParentWorkAuthorityKey($0.publicKey)
              }),
              let gated = try? gate.acceptPortable(
                envelope,
                durableParentWorkAuthorityKey: authority
              ),
              gated.package.proof.rootCID == summary.rootCID,
              let edge = await DirectChildEdge.derive(from: gated.package.proof),
              edge.edgeCID == summary.edgeCID,
              let received = Self.attachingEvidenceContent(
                acquisitionEntries: attachment.acquisitionEntries,
                to: gated
              ),
              let childData = attachment.acquisitionEntries[edge.childCID],
              let child = _contentBoundBlock(cid: edge.childCID, data: childData),
              child.parent != nil
                || (envelope.parentGenesisLink != nil
                    && envelope.parentGenesisCertificate != nil),
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
        return enqueueCandidate(Candidate(
            childCID: edge.childCID,
            package: received,
            announcer: peer
        ))
    }

    private nonisolated static func resolveRecoveryAttachment(
        _ cid: String,
        childCID: String? = nil,
        source: IvyRootContentSource
    ) async -> ChildEvidenceVolume? {
        guard let serialized = await source.volume(rootCID: cid) else {
            return nil
        }
        return try? ChildEvidenceVolume(
            serialized: serialized,
            childCID: childCID
        )
    }

    private func scheduleParentEvidenceRecovery(
        _ summary: IssuedChildEvidenceSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let lease = reserveRecoveryAttachment(
            summary.attachmentCID,
            from: peer
        ) else { return }
        Task { [weak self] in
            guard let self else { return }
            let handled = await self.recoverParentEvidence(
                summary,
                from: peer,
                generation: generation,
                process: process,
                reservedLease: lease
            )
            if !handled { await self.hierarchy.recycleSession(ifCurrent: peer) }
        }
    }

    private func scheduleParentEvidencePage(
        _ response: ChildEvidenceIndexResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        Task { [weak self] in
            guard let self else { return }
            for summary in response.entries {
                guard await self.recoverParentEvidence(
                    summary,
                    from: peer,
                    generation: generation,
                    process: process
                ) else {
                    await self.hierarchy.recycleSession(ifCurrent: peer)
                    return
                }
            }
            if response.hasMore, let cursor = response.entries.last {
                await self.requestEvidenceIndex(
                    after: cursor,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    private func recoverParentEvidence(
        _ summary: IssuedChildEvidenceSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess,
        reservedLease: RecoveryAttachmentLease? = nil
    ) async -> Bool {
        let lease = RecoveryAttachmentLease(
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if let reservedLease {
            guard lease == reservedLease,
                  activeRecoveryAttachments.contains(lease) else { return false }
        } else {
            if activeRecoveryAttachments.contains(lease) { return true }
            guard activeRecoveryAttachments.count < Self.maximumEvidenceCandidates else {
                return false
            }
            activeRecoveryAttachments.insert(lease)
        }
        defer { activeRecoveryAttachments.remove(lease) }
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else { return false }
        let source = IvyRootContentSource(ivy: hierarchy, peer: peer)
        guard let attachment = await source.withRoot(
            summary.attachmentCID,
            operation: {
                await Self.resolveRecoveryAttachment(
                    summary.attachmentCID,
                    childCID: summary.childCID,
                    source: source
                )
            }
        ),
              let envelope = try? ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
              ),
              let gate = parentFactGate,
              let gated = try? gate.accept(envelope, from: peer),
              gated.package.proof.rootCID == summary.rootCID,
              let directHop = await gated.package.proof.directHop(),
              directHop.childCID == summary.childCID,
              let received = Self.attachingEvidenceContent(
                acquisitionEntries: attachment.acquisitionEntries,
                to: gated
              ),
              isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else { return false }
        return enqueueCandidate(Candidate(
            childCID: summary.childCID,
            package: received
        ))
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
                guard let result = assembler.ingest(push.snapshot) else {
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
                let commit: ChainCommit?
                if let inheritedWorkHandler {
                    commit = try await inheritedWorkHandler(
                        completeSnapshot,
                        peer.key.hex
                    )
                } else {
                    commit = try await process.applyInheritedWorkSnapshot(
                        completeSnapshot,
                        from: peer.key.hex
                    )
                }
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                guard configuredParentPeer()?.sessionID == peer.sessionID else {
                    return
                }
                await setParentConsensusReady(true, from: peer)
                guard parentConsensusReady,
                      configuredParentPeer()?.sessionID == peer.sessionID else {
                    return
                }
                if let commit, commit.canonicalChanged {
                    try? await canonicalTipDidChange(
                        generation: generation,
                        process: process
                    )
                }
                // A parent's newly inherited work is itself exportable work
                // for this chain's direct children even when this chain's tip
                // remains unchanged.
                await pushInheritedWork(
                    generation: generation,
                    process: process
                )
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
            scheduleParentEvidenceRecovery(
                IssuedChildEvidenceSummary(
                    childCID: available.childCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                ),
                from: peer,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.childEvidenceIndexRequest, .child(let childPath)):
            guard let directory = childPath.last,
                  let request = try? ChildEvidenceIndexRequestMessage.decoded(
                    message.payload
                ), request.childPath == childPath
            else { return }
            childEvidenceReadyPeers.insert(peer.key)
            guard
                  let summaries = try? await process.issuedChildEvidenceSummaries(
                    directory: directory,
                    after: request.after,
                    limit: ChildEvidenceIndexResponseMessage.maximumEntries + 1
                ), isCurrentRuntime(generation: generation, process: process)
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
                after: request.after,
                entries: page,
                hasMore: summaries.count > page.count
                ).encoded()
            else { return }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )
            // A child asks for this index only after it has accepted us as its
            // parent. That makes it the reliable full-resend point if our
            // first push raced its hierarchy hello.
            resetInheritedWorkPush(for: peer.key)
            await pushInheritedWork(
                directories: [directory],
                generation: generation,
                process: process
            )
        case (NodeNetworkTopic.childEvidenceIndexResponse, .parent):
            guard
                let response = try? ChildEvidenceIndexResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingEvidenceIndexes[response.requestID],
                  pending.peer.sessionID == peer.sessionID,
                  response.childPath == pending.request.childPath,
                  response.after == pending.request.after
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
            pendingChildCandidates.removeValue(forKey: response.requestID)
            pending.continuation.resume(
                returning: DirectChildCandidate(
                directory: directory,
                block: block,
                searchTarget: response.searchTarget,
                deploymentTarget: response.deploymentTarget,
                acquisitionEntries: response.acquisitionEntries
            ))

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
                await hierarchy.disconnectSession(ifCurrent: peer)
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
        hierarchyPeers[peer.key] = role
        hierarchySessions[peer.key] = peer
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
            await requestEvidenceIndex(
                after: nil,
                generation: generation,
                process: process
            )
        } else if case .child = role {
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
    private func enqueueCandidate(_ candidate: Candidate) -> Bool {
        guard isRunning else { return false }
        if let activeCandidate,
            activeCandidate.queueID == candidate.queueID
        {
            guard
                candidate.package != nil
                    || !candidate.announcers.isEmpty
            else { return true }
            activeCandidateUpdate = Self.mergedCandidate(
                activeCandidateUpdate ?? activeCandidate,
                with: candidate
            )
            return true
        }
        if let queued = queuedCandidates[candidate.queueID] {
            queuedCandidates[candidate.queueID] = Self.mergedCandidate(
                queued,
                with: candidate
            )
            return true
        }
        guard candidateInbox.enqueue(candidate.queueID) else { return false }
        queuedCandidates[candidate.queueID] = candidate
        startCandidateWorker()
        return true
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
            let candidate = dequeueCandidate()
        {
            guard let process,
                isCurrentRuntime(generation: generation, process: process)
            else {
                return
            }
            activeCandidate = candidate
            await admitCandidate(
                candidate,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            activeCandidate = nil
            if let update = activeCandidateUpdate {
                activeCandidateUpdate = nil
                enqueueCandidate(update)
            }
            await resumeAcceptedLeavesSync(
                generation: generation,
                process: process
            )
        }
    }

    private func dequeueCandidate() -> Candidate? {
        while let queueID = candidateInbox.dequeue() {
            guard let candidate = queuedCandidates.removeValue(forKey: queueID) else {
                continue
            }
            guard candidate.isLocallySourced || candidate.announcers.values.contains(
                where: {
                    overlayPeers[$0.key]?.sessionID == $0.sessionID
                }
            ) else { continue }
            return candidate
        }
        return nil
    }

    private func purgeQueuedAnnouncements(from peer: AuthenticatedPeer) {
        var removedQueueIDs = Set<String>()
        for queueID in Array(queuedCandidates.keys) {
            guard var candidate = queuedCandidates[queueID],
                  candidate.announcers[peer.key]?.sessionID == peer.sessionID else {
                continue
            }
            candidate.announcers.removeValue(forKey: peer.key)
            if candidate.isLocallySourced || !candidate.announcers.isEmpty {
                queuedCandidates[queueID] = candidate
            } else {
                queuedCandidates.removeValue(forKey: queueID)
                removedQueueIDs.insert(queueID)
            }
        }
        candidateInbox.remove(removedQueueIDs)
        if var update = activeCandidateUpdate,
           update.announcers[peer.key]?.sessionID == peer.sessionID {
            update.announcers.removeValue(forKey: peer.key)
            activeCandidateUpdate =
                update.isLocallySourced || !update.announcers.isEmpty
                ? update
                : nil
        }
    }

    private func finishCandidateWorker(generation: UInt64) {
        guard candidateWorkerGeneration == generation else { return }
        candidateWorker = nil
        candidateWorkerGeneration = nil
        if isRunning {
            drainReadyDurableDescendants()
            if !candidateInbox.isEmpty {
                startCandidateWorker()
            }
        }
    }

    private func drainReadyDurableDescendants() {
        while let descendant = readyDurableDescendants.popFirst() {
            guard enqueueCandidate(Candidate(
                childCID: descendant.childCID,
                package: nil,
                recoveryRootCID: descendant.rootCID
            )) else {
                readyDurableDescendants.insert(descendant)
                return
            }
        }
    }

    private static func mergedCandidate(
        _ existing: Candidate,
        with update: Candidate
    ) -> Candidate {
        var merged = existing
        if let package = update.package,
            let combined = merging(existing.package, with: package)
        {
            merged.package = combined
        }
        merged.announcers.merge(update.announcers) { _, newer in newer }
        merged.isLocallySourced =
            existing.isLocallySourced || update.isLocallySourced
        return merged
    }

    private func admitCandidate(
        _ candidate: Candidate,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard let admissionHandler else { return }
        let authenticatedPackage: AuthenticatedChildPackage?
        if let package = candidate.package {
            authenticatedPackage = package
        } else if let rootCID = candidate.recoveryRootCID {
            guard let recovered = try? await process
                .recoveredAuthenticatedChildPackage(
                    for: candidate.childCID,
                    rootCID: rootCID
                ) else { return }
            authenticatedPackage = recovered
        } else {
            authenticatedPackage = nil
        }
        let childDirectories = authenticatedChildDirectories()
        var attempt: (
            value: NodeAdmissionOutcome,
            attribution: IvyRootContentSource.Attribution
        )?
        let header = BlockHeader(
                        rawCID: candidate.childCID,
                        node: nil,
                        encryptionInfo: nil
        )
        let exactSources: [(peer: AuthenticatedPeer?, source: IvyRootContentSource)]
        if authenticatedPackage != nil || candidate.isLocallySourced {
            exactSources = [(nil, IvyRootContentSource(fetch: { _ in .empty }))]
        } else {
            exactSources = candidate.announcers.values.filter {
                overlayPeers[$0.key]?.sessionID == $0.sessionID
            }.sorted {
                $0.id.publicKey < $1.id.publicKey
            }.map { ($0, IvyRootContentSource(ivy: overlay, peer: $0)) }
        }
        for exact in exactSources {
            let initialResponse: AttributedVolumeResponse?
            if let peer = exact.peer {
                let response = await overlay.fetchVolume(
                    rootCID: candidate.childCID,
                    from: peer
                )
                let volume = SerializedVolume(
                    root: response.rootCID,
                    entries: response.entries
                )
                guard response.servedBy == peer.id,
                      response.rootCID == candidate.childCID else {
                    await overlay.recycleSession(ifCurrent: peer)
                    continue
                }
                guard (try? volume.validate()) != nil else {
                    await overlay.reportDeficientContent(
                        rootCID: candidate.childCID,
                        servedBy: peer.id
                    )
                    continue
                }
                initialResponse = response
            } else {
                initialResponse = nil
            }
            let capture = IvyRootContentSource.AttributionCapture()
            do {
                attempt = try await exact.source.withRootTracing(
                    candidate.childCID,
                    initialResponse: initialResponse,
                    capture: capture
                ) {
                    try await AdmissionAcquisitionScope.$exactSource.withValue(
                        exact.source
                    ) {
                        try await admissionHandler(
                            header,
                            authenticatedPackage,
                            childDirectories
                        )
                    }
                }
                break
            } catch {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                if let failure = error as? ChainAdmissionFailure,
                   case .crossChainEvidenceRequired(let requirement) = failure {
                    _ = requirement
                    return
                }
                if let peer = exact.peer,
                   capture.snapshot()?.allResponsesComplete == false {
                    await overlay.reportDeficientContent(
                        rootCID: candidate.childCID,
                        servedBy: peer.id
                    )
                }
                guard !Task.isCancelled else { return }
            }
        }
        guard let attempt else {
            return
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let outcome = attempt.value
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        // This is a required acquisition retry even when the current attempt
        // staged useful work; it is never interpreted as terminal success.
        if let predecessor = outcome.sameChainPredecessor,
           let payload = try? PredecessorRequestMessage(
            predecessorCID: predecessor.predecessorCID
            ).encoded()
        {
            if outcome.decision.isAccepted {
                durableDescendantsByPredecessor[
                    predecessor.predecessorCID,
                    default: []
                ].insert(DurableDescendant(
                    childCID: candidate.childCID,
                    rootCID: candidate.recoveryRootCID
                        ?? authenticatedPackage?.package.proof.rootCID
                ))
            } else {
                remember(candidate, waitingFor: predecessor.predecessorCID)
            }
            for peer in overlayPeers.values {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                _ = await overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.predecessorRequest,
                    payload: payload
                )
            }
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        if outcome.parentCarrierLink != nil {
            _ = await announceCurrentCarrierChildEvidence(
                directories: childDirectories,
                carrierCID: candidate.childCID,
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
                        .portableRecoveryAttachmentCID(
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

        // A parent carrier link is vertical evidence only. A target-miss or
        // rejected candidate may carry one without connecting its same-chain
        // graph edge, so descendants wake only after local acceptance has
        // revalidated the complete ancestry.
        if outcome.decision.isAccepted, outcome.sameChainPredecessor == nil {
            let descendants =
                waitingDescendants.removeValue(
                forKey: candidate.childCID
            ) ?? []
            for descendant in descendants {
                enqueueCandidate(descendant)
            }
            let durableDescendants =
                durableDescendantsByPredecessor.removeValue(
                forKey: candidate.childCID
            ) ?? []
            readyDurableDescendants.formUnion(durableDescendants)
            drainReadyDurableDescendants()
        }

        if outcome.decision == .invalid {
            if attempt.attribution.allResponsesComplete,
               let supplierKey = attempt.attribution.soleRemoteSupplierPublicKey,
               let supplier = try? PeerKey(supplierKey),
               overlayPeers[supplier] != nil,
               configuration.address.isNexus || outcome.parentCarrierLink != nil {
                await overlay.reportDeficientContent(
                    rootCID: candidate.childCID,
                    servedBy: PeerID(publicKey: supplierKey)
                )
            }
        }
        // Parent evidence is never penalized: this feedback only suppresses the
        // exact same-chain content server for this root.
    }

    private func startAcceptedLeavesRequest(
        from peer: AuthenticatedPeer,
        cursor: AcceptedLeavesCursor,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process),
            pendingAcceptedLeaves == nil,
            candidateInbox.reserveAcceptedLeafPage()
        else {
            return false
        }
        let request = AcceptedLeavesRequestMessage(
            requestID: makeRequestID(),
            afterCID: cursor.afterCID,
            snapshotSequence: cursor.snapshotSequence
        )
        guard let payload = try? request.encoded() else {
            candidateInbox.releaseAcceptedLeafPage()
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
    private func takeAcceptedLeavesRequest() -> PendingAcceptedLeaves? {
        guard let pending = pendingAcceptedLeaves else {
            return nil
        }
        pendingAcceptedLeaves = nil
        pending.timeout.cancel()
        candidateInbox.releaseAcceptedLeafPage()
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

    private func requestEvidenceIndex(
        after: IssuedChildEvidenceSummary?,
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
        let request = ChildEvidenceIndexRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            after: after
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
            after: request.request.after,
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
            guard case .child(let path) = role else { continue }
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
        try? await remoteContentSource.withRoot(resolvedTipCID) {
            try await fence.process.prepareChildProofs(
                for: BlockHeader(
                    rawCID: resolvedTipCID,
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: directories
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
            let directories = try? await remoteContentSource.withRoot(carrierCID) {
                try await fence.process.retryPendingChildProofs(
                    carrierCID: carrierCID
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
            let builder = childCandidateBuilder
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
        guard let candidate = try? await hierarchyContentSource.withRoot(
            request.parentCID,
            operation: {
                try await ChildCandidateBudget.$deadline.withValue(deadline) {
                    try await builder(
                        ChildCandidateRequestContext(
                            parentCarrier: parent,
                            rewards: request.rewards,
                            mode: request.mode
                        ))
                }
            }
        ) else { return }
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token,
              !Task.isCancelled,
              candidate.directory == configuration.address.directory,
              let blockData = candidate.block.toData(),
              let childCID = try? BlockHeader(node: candidate.block).rawCID,
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              case .parent? = hierarchyPeers[peer.key]
        else { return }
        guard let payload = try? ChildCandidateResponseMessage(
                requestID: request.requestID,
                childPath: configuration.chainPath,
                parentCID: request.parentCID,
                childCID: childCID,
                searchTarget: candidate.searchTarget,
                deploymentTarget: candidate.deploymentTarget,
                blockData: blockData,
                acquisitionEntries: candidate.acquisitionEntries
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
        await setParentConsensusReady(false)
        guard isCurrentRuntime(generation: generation, process: process),
              configuredParentPeer()?.sessionID == peer.sessionID else {
            return
        }
        await hierarchy.recycleSession(ifCurrent: peer)
    }

    private func setParentConsensusReady(
        _ ready: Bool,
        from parent: AuthenticatedPeer? = nil
    ) async {
        guard !configuration.address.isNexus,
              parentConsensusReady != ready else { return }
        if ready {
            guard let parent,
                  configuredParentPeer()?.sessionID == parent.sessionID else {
                return
            }
        }
        parentConsensusReady = ready
        guard isRunning, let process else { return }
        if ready {
            try? await canonicalTipDidChange(
                generation: runtimeGeneration,
                process: process
            )
            guard parentConsensusReady,
                  configuredParentPeer()?.sessionID == parent?.sessionID else {
                return
            }
            await parentReadinessHandler?(true)
            guard parentConsensusReady,
                  configuredParentPeer()?.sessionID == parent?.sessionID else {
                return
            }
            await pushInheritedWork(
                generation: runtimeGeneration,
                process: process
            )
        } else {
            await parentReadinessHandler?(false)
            guard !parentConsensusReady else { return }
            let childSessions: [AuthenticatedPeer] = hierarchySessions.compactMap {
                key, peer -> AuthenticatedPeer? in
                guard case .child? = hierarchyPeers[key] else { return nil }
                return peer
            }
            for child in childSessions {
                await hierarchy.recycleSession(ifCurrent: child)
            }
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
                expectedChainPath: expectedPath,
                expectedMinimumRootWorkHex: configuration.minimumRootWork.toHexString()
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
            expectedChainPath: remote.chainPath,
            expectedMinimumRootWorkHex: configuration.minimumRootWork.toHexString()
        )).map { .child(remote.chainPath) }
    }

    private func remember(_ candidate: Candidate, waitingFor predecessorCID: String) {
        var descendants = waitingDescendants[predecessorCID] ?? []
        if let index = descendants.firstIndex(where: {
            $0.queueID == candidate.queueID
        }) {
            descendants[index] = candidate
        } else {
            let count = waitingDescendants.values.reduce(0) { $0 + $1.count }
            guard count < Self.maximumEvidenceCandidates else {
                restartAcceptedLeavesSync()
                return
            }
            descendants.append(candidate)
        }
        waitingDescendants[predecessorCID] = descendants
    }

    static func attachingEvidenceContent(
        acquisitionEntries receivedEntries: [String: Data],
        to package: AuthenticatedChildPackage
    ) -> AuthenticatedChildPackage? {
        var entries = package.acquisitionEntries
        for (cid, entry) in receivedEntries {
            guard entries[cid].map({ $0 == entry }) ?? true else { return nil }
            entries[cid] = entry
        }
        return AuthenticatedChildPackage(
            package: package.package,
            acquisitionEntries: entries,
            parentCarrierCertificate: package.parentCarrierCertificate,
            parentGenesisCertificate: package.parentGenesisCertificate
        )
    }

    static func merging(
        _ current: AuthenticatedChildPackage?,
        with received: AuthenticatedChildPackage
    ) -> AuthenticatedChildPackage? {
        guard let current else { return received }
        let left = current.package
        let right = received.package
        guard let leftProof = try? left.proof.serialize(),
              let rightProof = try? right.proof.serialize(),
              leftProof == rightProof,
              left.parentCarrierLink == nil
                || right.parentCarrierLink == nil
                || left.parentCarrierLink == right.parentCarrierLink,
              left.parentGenesisLink == nil
                || right.parentGenesisLink == nil
                || left.parentGenesisLink == right.parentGenesisLink,
              current.parentCarrierCertificate == nil
                || received.parentCarrierCertificate == nil
                || current.parentCarrierCertificate
                    == received.parentCarrierCertificate,
              current.parentGenesisCertificate == nil
                || received.parentGenesisCertificate == nil
                || current.parentGenesisCertificate
                    == received.parentGenesisCertificate
        else {
            return nil
        }
        var acquisitionEntries = current.acquisitionEntries
        for (cid, data) in received.acquisitionEntries {
            if let existing = acquisitionEntries[cid], existing != data {
                return nil
            }
            acquisitionEntries[cid] = data
        }
        return AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: left.proof,
                parentCarrierLink: left.parentCarrierLink ?? right.parentCarrierLink,
                parentGenesisLink: left.parentGenesisLink ?? right.parentGenesisLink
            ),
            acquisitionEntries: acquisitionEntries,
            parentCarrierCertificate: current.parentCarrierCertificate
                ?? received.parentCarrierCertificate,
            parentGenesisCertificate: current.parentGenesisCertificate
                ?? received.parentGenesisCertificate
        )
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
