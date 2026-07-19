import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import cashew

public typealias ContextualChildCandidateBuilder = @Sendable (
    _ context: ChildCandidateRequestContext
) async throws -> DirectChildCandidate?
public typealias NetworkAdmissionHandler = @Sendable (
    _ block: Block,
    _ outcome: NodeAdmissionOutcome
) async throws -> Void

private enum ChildCandidateBudget {
    @TaskLocal static var deadline: ContinuousClock.Instant?
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
        overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: configuration.listenPort,
            bootstrapPeers: configuration.bootstrapPeers,
            minPeerKeyBits: configuration.minPeerKeyBits,
            mode: .overlay
        )
        hierarchy = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: configuration.factListenPort,
            bootstrapPeers: configuration.parentEndpoint.map { [$0.ivy] } ?? [],
            maxConnections: IvyConfig.defaultMaxConnections,
            maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
            minPeerKeyBits: 0,
            relayEnabled: false,
            carriers: [],
            mode: .privateNetwork
        )
        try overlay.validate()
        try hierarchy.validate()
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

    private struct Candidate: Sendable {
        let childCID: String
        var package: AuthenticatedChildPackage?
        var attemptedRequirements: Set<String> = []
        var nextProofRootCursor: String? = nil
    }

    private struct WaitingEvidence: Sendable {
        let peer: AuthenticatedPeer
        let request: ChildEvidenceRequestMessage
    }

    private struct PendingEvidence: Sendable {
        let candidate: Candidate
        let requirement: CrossChainEvidenceRequirement
        let proofRootCID: String?
    }

    private struct DeferredEvidence: Sendable {
        let candidate: Candidate
        let requirement: CrossChainEvidenceRequirement
        let proofRootCID: String?
    }

    private struct PendingProofRoots: Sendable {
        let candidate: Candidate
        let request: ChildProofRootsRequestMessage
    }

    private struct PendingChildCandidateRequest {
        let peerKey: PeerKey
        let childPath: [String]
        let parentCID: String
        let continuation: CheckedContinuation<DirectChildCandidate?, Never>
    }

    private struct ChildCandidateBuild {
        let peerKey: PeerKey
        let task: Task<Void, Never>
    }

    private static let maximumPendingRequests = 1_024
    private static let maximumDirectChildren = 64
    private static let maximumDirectChildBytes = 16 * 1024 * 1024
    private static let maximumConcurrentChildBuilds = 8
    private static let maximumPeersPerChildPath = 4
    private static let childCandidateFinalizeReserveMilliseconds: UInt64 = 100

    public nonisolated let remoteContentSource: IvyRootContentSource

    let planeConfigurations: NodeNetworkPlaneConfigurations
    private let configuration: NodeConfiguration
    private let overlay: Ivy
    private let hierarchy: Ivy
    private let hello: ChainHello
    private let parentFactGate: AuthenticatedParentFactGate?

    private var process: ChainProcess?
    private var isRunning = false
    private var overlayPeers: [PeerKey: AuthenticatedPeer] = [:]
    private var hierarchyPeers: [PeerKey: HierarchyPeer] = [:]
    private var pendingEvidence: [UInt64: PendingEvidence] = [:]
    private var waitingForParent: [String: DeferredEvidence] = [:]
    private var waitingEvidenceResponses: [String: WaitingEvidence] = [:]
    private var waitingDescendants: [String: [Candidate]] = [:]
    private var pendingProofRoots: [UInt64: PendingProofRoots] = [:]
    private var waitingProofRoots: [String: Candidate] = [:]
    private var pendingEvidenceIndexes: [
        UInt64: ChildEvidenceIndexRequestMessage
    ] = [:]
    private var childCandidateBuilder: ContextualChildCandidateBuilder?
    private var admissionHandler: NetworkAdmissionHandler?
    private var pendingChildCandidates: [UInt64: PendingChildCandidateRequest] = [:]
    private var childCandidateBuilds: [UInt64: ChildCandidateBuild] = [:]
    private var childPeerRotation: [String: Int] = [:]
    private var childPathRotation = 0
    private var childProofPathRotation = 0
    private var pendingCoverage: Set<UInt64> = []
    private var nextRequestID: UInt64 = 0

    public init(configuration: NodeConfiguration) throws {
        let planeConfigurations = try NodeNetworkPlaneConfigurations(configuration)
        let overlay = Ivy(config: planeConfigurations.overlay)
        let hierarchy = Ivy(config: planeConfigurations.hierarchy)
        self.configuration = configuration
        self.planeConfigurations = planeConfigurations
        self.overlay = overlay
        self.hierarchy = hierarchy
        remoteContentSource = IvyRootContentSource(ivy: overlay)
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
    }

    /// Installs both delegates and the recovered process's local content source
    /// before either listener becomes visible. The private plane starts first.
    public func start(process: ChainProcess) async throws {
        guard !isRunning else { throw NodeNetworkRuntimeError.alreadyRunning }
        self.process = process
        await overlay.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(process: process)
        )
        await hierarchy.install(delegate: self, contentSource: nil)
        do {
            try await Self.startPlanes(
                startHierarchy: { try await self.hierarchy.start() },
                startOverlay: { try await self.overlay.start() },
                stopOverlay: { await self.overlay.stop() },
                stopHierarchy: { await self.hierarchy.stop() }
            )
            isRunning = true
            await retryRecoveredChildProofs()
            await flushWaitingForParent()
            try? await refreshInheritedWork()
        } catch {
            self.process = nil
            throw error
        }
    }

    public func stop() async {
        guard isRunning || process != nil else { return }
        await Self.stopPlanes(
            stopOverlay: { await self.overlay.stop() },
            stopHierarchy: { await self.hierarchy.stop() }
        )
        isRunning = false
        process = nil
        overlayPeers.removeAll()
        hierarchyPeers.removeAll()
        pendingEvidence.removeAll()
        waitingForParent.removeAll()
        waitingEvidenceResponses.removeAll()
        waitingDescendants.removeAll()
        pendingProofRoots.removeAll()
        waitingProofRoots.removeAll()
        pendingEvidenceIndexes.removeAll()
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
        pendingCoverage.removeAll()
    }

    public func announceBlock(_ blockCID: String) async throws {
        guard isRunning else { throw NodeNetworkRuntimeError.notRunning }
        let payload = try BlockAnnouncementMessage(blockCID: blockCID).encoded()
        for peer in overlayPeers.values {
            _ = await overlay.sendMessage(
                to: peer.id,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        }
    }

    /// Called after the process canonicalizes a new tip. Overlay peers learn
    /// the CID, and authenticated direct-child routes get a targeted proof
    /// preparation retry against that exact root.
    public func canonicalTipDidChange() async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        if let tip = await process.status().tipCID {
            try await announceBlock(tip)
            await retryCurrentTipChildProofs(tipCID: tip)
        }
    }

    public func publishAcceptedBlock(
        _ blockCID: String,
        canonicalized: Bool
    ) async throws {
        try await announceBlock(blockCID)
        if canonicalized, !configuration.address.isNexus {
            try? await refreshInheritedWork()
        }
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

    /// Requests contextual templates from authenticated immediate children for
    /// one exact provisional carrier. Missing or slow children are omitted.
    public func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async -> [DirectChildCandidate] {
        guard isRunning,
              context.rewards.count <= ChildCandidateRequestMessage.maximumRewards,
              let parentData = context.parentCarrier.toData(),
              let parentCID = try? BlockHeader(node: context.parentCarrier).rawCID,
              let deadline = childCandidateRequestDeadline() else {
            return []
        }
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
                        deadline: deadline
                    )
                    return (rank, candidate)
                }
            }
            for await (rank, candidate) in group {
                if let candidate { candidates.append((rank, candidate)) }
            }
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
                  ) else {
                return false
            }
            let next = totalBytes.addingReportingOverflow(
                package.framedByteCount
            )
            guard !next.overflow,
                  next.partialValue <= Self.maximumDirectChildBytes else {
                return false
            }
            totalBytes = next.partialValue
            return true
        }
    }

    /// Child processes call this after local coverage changes or a parent
    /// reconnects. The parent computes the snapshot; the child only persists it.
    public func refreshInheritedWork() async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        guard !configuration.address.isNexus,
              pendingCoverage.isEmpty,
              let parent = configuredParentPeer() else { return }
        let requestID = makeRequestID()
        let message = CoverageRequestMessage(
            requestID: requestID,
            childPath: configuration.chainPath,
            coverage: try await process.parentCoverage()
        )
        let result = await hierarchy.sendMessage(
            to: parent.id,
            topic: NodeNetworkTopic.coverageRequest,
            payload: try message.encoded()
        )
        if case .enqueued = result {
            pendingCoverage.insert(requestID)
            scheduleCoverageTimeout(requestID)
        }
    }

    /// Retries direct child requests that arrived before their proof or a
    /// durable locally-issued parent fact was available.
    public func parentFactsDidChange() async {
        await flushWaitingEvidenceResponses()
    }

    /// Publishes an already-promoted absolute proof prepared durably by the
    /// process admission boundary.
    @discardableResult
    public func publishChildProof(
        _ proof: ChildBlockProof,
        childDirectory: String,
        child: Block
    ) async throws -> ChildBlockProof {
        guard isRunning, process != nil else {
            throw NodeNetworkRuntimeError.notRunning
        }
        guard let childCID = try? BlockHeader(node: child).rawCID,
              child.toData().flatMap({
                  _contentBoundBlock(cid: childCID, data: $0)
              }) != nil else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        let childPath = configuration.chainPath + [childDirectory]
        guard proof.directoryPath == Array(childPath.dropFirst()),
              !childDirectory.isEmpty,
              _isBoundedWireAtom(childCID),
              (try? proof.serialize()) != nil else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        await flushWaitingEvidenceResponses()
        if let payload = try? ChildEvidenceAvailableMessage(
            childPath: childPath,
            childCID: childCID,
            rootCID: proof.rootCID
        ).encoded() {
            for (key, role) in hierarchyPeers {
                guard case .child(let path) = role, path == childPath else { continue }
                _ = await hierarchy.sendMessage(
                    to: PeerID(publicKey: key.hex),
                    topic: NodeNetworkTopic.childEvidenceAvailable,
                    payload: payload
                )
            }
        }
        return proof
    }

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) {
        Task { await self.didConnect(on: ivy, peer: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        Task { await self.didDisconnect(on: ivy, peer: peer) }
    }

    nonisolated public func ivy(
        _ ivy: Ivy,
        didDiscoverPublicAddress address: ObservedAddress
    ) {}

    nonisolated public func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) {
        Task { await self.didReceive(on: ivy, message: message, peer: peer) }
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

    private func didConnect(on ivy: Ivy, peer: AuthenticatedPeer) async {
        guard peer.role == .endpoint else {
            await ivy.disconnect(peer.id)
            return
        }
        let topic: String
        if ivy === overlay {
            topic = NodeNetworkTopic.overlayHello
        } else if ivy === hierarchy {
            guard peer.route == .direct else {
                await ivy.disconnect(peer.id)
                return
            }
            topic = NodeNetworkTopic.hierarchyHello
        } else {
            return
        }
        guard let payload = try? hello.encode() else { return }
        _ = await ivy.sendMessage(to: peer.id, topic: topic, payload: payload)
    }

    private func didDisconnect(on ivy: Ivy, peer: PeerID) async {
        guard let key = try? PeerKey(peer.publicKey) else { return }
        if ivy === overlay {
            overlayPeers.removeValue(forKey: key)
        } else if ivy === hierarchy {
            let removedRole = hierarchyPeers.removeValue(forKey: key)
            Self.pruneChildPeerRotations(
                &childPeerRotation,
                activeRoles: Array(hierarchyPeers.values)
            )
            if case .parent? = removedRole {
                pendingCoverage.removeAll()
                for pending in pendingEvidence.values {
                    rememberForParent(
                        pending.candidate,
                        requirement: pending.requirement,
                        proofRootCID: pending.proofRootCID
                    )
                }
                pendingEvidence.removeAll()
                for pending in pendingProofRoots.values {
                    rememberProofRoots(pending.candidate)
                }
                pendingProofRoots.removeAll()
                pendingEvidenceIndexes.removeAll()
            }
            cancelChildCandidateWork(for: key)
            waitingEvidenceResponses = waitingEvidenceResponses.filter {
                $0.value.peer.key != key
            }
        }
    }

    private func didReceive(
        on ivy: Ivy,
        message: PeerMessage,
        peer: AuthenticatedPeer
    ) async {
        guard let plane = NodeNetworkTopic.plane(for: message.topic) else { return }
        if ivy === overlay {
            guard plane == .overlay else { return }
            await handleOverlay(message, peer: peer)
        } else if ivy === hierarchy {
            guard plane == .hierarchy, peer.route == .direct else { return }
            await handleHierarchy(message, peer: peer)
        }
    }

    private func handleOverlay(_ message: PeerMessage, peer: AuthenticatedPeer) async {
        if message.topic == NodeNetworkTopic.overlayHello {
            guard let remote = try? ChainHello.decode(message.payload),
                  (try? remote.validateCompatibility(
                    expectedNexusGenesisCID: configuration.nexusGenesisCID,
                    expectedChainPath: configuration.chainPath,
                    expectedMinimumRootWorkHex: configuration.minimumRootWork.toHexString()
                  )) != nil else {
                await overlay.disconnect(peer.id)
                return
            }
            overlayPeers[peer.key] = peer
            await retryRecoveredChildProofs()
            await retryCurrentTipChildProofs()
            if let tip = await process?.status().tipCID,
               let payload = try? BlockAnnouncementMessage(blockCID: tip).encoded() {
                _ = await overlay.sendMessage(
                    to: peer.id,
                    topic: NodeNetworkTopic.blockAnnouncement,
                    payload: payload
                )
            }
            return
        }

        guard overlayPeers[peer.key] != nil else { return }
        switch message.topic {
        case NodeNetworkTopic.blockAnnouncement:
            guard let announcement = try? BlockAnnouncementMessage.decoded(message.payload) else {
                return
            }
            let candidate = Candidate(
                childCID: announcement.blockCID,
                package: nil
            )
            await requestProofRoots(for: candidate)
            await admitCandidate(candidate)
        case NodeNetworkTopic.predecessorRequest:
            guard let request = try? PredecessorRequestMessage.decoded(message.payload),
                  let payload = try? BlockAnnouncementMessage(
                    blockCID: request.predecessorCID
                  ).encoded() else { return }
            _ = await overlay.sendMessage(
                to: peer.id,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        default:
            break
        }
    }

    private func handleHierarchy(_ message: PeerMessage, peer: AuthenticatedPeer) async {
        if message.topic == NodeNetworkTopic.hierarchyHello {
            await handleHierarchyHello(message.payload, peer: peer)
            return
        }
        guard let role = hierarchyPeers[peer.key] else { return }

        switch (message.topic, role) {
        case (NodeNetworkTopic.childEvidenceRequest, .child(let childPath)):
            guard let request = try? ChildEvidenceRequestMessage.decoded(message.payload),
                  request.childPath == childPath else { return }
            await serveEvidenceRequest(request, to: peer, rememberOnMiss: true)

        case (NodeNetworkTopic.childEvidenceResponse, .parent):
            guard let response = try? ChildEvidenceResponseMessage.decoded(message.payload),
                  let pending = pendingEvidence[response.requestID],
                  pending.candidate.childCID == response.childCID,
                  let gate = parentFactGate,
                  let gated = try? gate.accept(response.envelope, from: peer),
                  let received = Self.attachingEvidenceContent(
                    response.candidateData,
                    acquisitionEntries: response.acquisitionEntries,
                    childCID: response.childCID,
                    to: gated
                  ),
                  Self.satisfies(
                    received,
                    requirement: pending.requirement,
                    proofRootCID: pending.proofRootCID
                  ),
                  let package = Self.merging(
                    pending.candidate.package,
                    with: received
                  ) else { return }
            pendingEvidence.removeValue(forKey: response.requestID)
            var candidate = pending.candidate
            candidate.attemptedRequirements.remove(requirementKey(
                pending.requirement,
                proofRootCID: pending.proofRootCID
            ))
            candidate.package = package
            await admitCandidate(candidate)
            await flushWaitingForParent()

        case (NodeNetworkTopic.childEvidenceAvailable, .parent):
            guard let available = try? ChildEvidenceAvailableMessage.decoded(
                message.payload
            ), available.childPath == configuration.chainPath else { return }
            await requestEvidence(
                .childProof(
                    chainPath: configuration.chainPath,
                    childCID: available.childCID
                ),
                for: Candidate(
                    childCID: available.childCID,
                    package: nil
                ),
                proofRootCID: available.rootCID
            )

        case (NodeNetworkTopic.childEvidenceIndexRequest, .child(let childPath)):
            guard let process,
                  let directory = childPath.last,
                  let request = try? ChildEvidenceIndexRequestMessage.decoded(
                    message.payload
                  ), request.childPath == childPath,
                  let summaries = try? await process.issuedChildEvidenceSummaries(
                    directory: directory,
                    after: request.after,
                    limit: ChildEvidenceIndexResponseMessage.maximumEntries + 1
                  ) else { return }
            let page = Array(summaries.prefix(
                ChildEvidenceIndexResponseMessage.maximumEntries
            ))
            guard let payload = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: childPath,
                after: request.after,
                entries: page,
                hasMore: summaries.count > page.count
            ).encoded() else { return }
            _ = await hierarchy.sendMessage(
                to: peer.id,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )

        case (NodeNetworkTopic.childEvidenceIndexResponse, .parent):
            guard let response = try? ChildEvidenceIndexResponseMessage.decoded(
                    message.payload
                  ), let request = pendingEvidenceIndexes[response.requestID],
                  response.childPath == request.childPath,
                  response.after == request.after else { return }
            pendingEvidenceIndexes.removeValue(forKey: response.requestID)
            for entry in response.entries {
                await requestEvidence(
                    .childProof(
                        chainPath: configuration.chainPath,
                        childCID: entry.childCID
                    ),
                    for: Candidate(childCID: entry.childCID, package: nil),
                    proofRootCID: entry.rootCID
                )
            }
            if response.hasMore, let cursor = response.entries.last {
                await requestEvidenceIndex(after: cursor)
            }

        case (NodeNetworkTopic.childProofRootsRequest, .child(let childPath)):
            guard let process,
                  let request = try? ChildProofRootsRequestMessage.decoded(
                    message.payload
                  ), request.childPath == childPath,
                  let roots = try? await process.issuedChildProofRoots(
                    childCID: request.childCID,
                    afterRootCID: request.afterRootCID,
                    limit: 2
                  ) else { return }
            let page = Array(roots.prefix(1))
            guard let payload = try? ChildProofRootsResponseMessage(
                requestID: request.requestID,
                childPath: childPath,
                childCID: request.childCID,
                afterRootCID: request.afterRootCID,
                rootCIDs: page,
                hasMore: roots.count > page.count
            ).encoded() else { return }
            _ = await hierarchy.sendMessage(
                to: peer.id,
                topic: NodeNetworkTopic.childProofRootsResponse,
                payload: payload
            )

        case (NodeNetworkTopic.childProofRootsResponse, .parent):
            guard let response = try? ChildProofRootsResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingProofRoots[response.requestID],
                  response.rootCIDs.count <= 1,
                  Self.matches(response, request: pending.request) else { return }
            pendingProofRoots.removeValue(forKey: response.requestID)
            guard let rootCID = response.rootCIDs.first else {
                waitingProofRoots.removeValue(forKey: response.childCID)
                return
            }
            var candidate = pending.candidate
            candidate.nextProofRootCursor = response.hasMore ? rootCID : nil
            await requestEvidence(
                .childProof(
                    chainPath: configuration.chainPath,
                    childCID: response.childCID
                ),
                for: candidate,
                proofRootCID: rootCID
            )

        case (NodeNetworkTopic.childCandidateRequest, .parent):
            guard let request = try? ChildCandidateRequestMessage.decoded(
                    message.payload
                  ), request.childPath == configuration.chainPath,
                  let parent = _contentBoundBlock(
                    cid: request.parentCID,
                    data: request.parentData
                  ) else { return }
            startChildCandidateBuild(request, parent: parent, peer: peer)

        case (NodeNetworkTopic.childCandidateResponse, .child(let childPath)):
            guard let response = try? ChildCandidateResponseMessage.decoded(
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
                  ) else { return }
            pendingChildCandidates.removeValue(forKey: response.requestID)
            pending.continuation.resume(returning: DirectChildCandidate(
                directory: directory,
                block: block,
                searchTarget: response.searchTarget,
                acquisitionEntries: response.acquisitionEntries
            ))

        case (NodeNetworkTopic.coverageRequest, .child(let childPath)):
            guard let process,
                  let request = try? CoverageRequestMessage.decoded(message.payload),
                  request.childPath == childPath,
                  let snapshot = try? await process.inheritedWorkSnapshot(
                    forChildCoverage: request.coverage
                  ),
                  let payload = try? InheritedWorkResponseMessage(
                    requestID: request.requestID,
                    childPath: childPath,
                    snapshot: snapshot
                  ).encoded() else { return }
            _ = await hierarchy.sendMessage(
                to: peer.id,
                topic: NodeNetworkTopic.inheritedWorkResponse,
                payload: payload
            )

        case (NodeNetworkTopic.inheritedWorkResponse, .parent):
            guard let process,
                  let response = try? InheritedWorkResponseMessage.decoded(message.payload),
                  response.childPath == configuration.chainPath,
                  pendingCoverage.remove(response.requestID) != nil else { return }
            do {
                if try await process.applyInheritedWorkSnapshot(response.snapshot) != nil,
                   await process.status().tipCID != nil {
                    try? await canonicalTipDidChange()
                }
            } catch {}

        default:
            break
        }
    }

    private func handleHierarchyHello(
        _ payload: Data,
        peer: AuthenticatedPeer
    ) async {
        guard peer.role == .endpoint, peer.route == .direct,
              let remote = try? ChainHello.decode(payload) else {
            await hierarchy.disconnect(peer.id)
            return
        }

        guard let role = Self.hierarchyRole(
            for: remote,
            peerKey: peer.key.hex,
            configuration: configuration
        ) else {
            await hierarchy.disconnect(peer.id)
            return
        }

        if case .child(let path) = role {
            guard let process,
                  let directory = path.last,
                  (try? await process.hasIssuedChildDirectory(directory)) == true else {
                await hierarchy.disconnect(peer.id)
                return
            }
        }
        if let existing = hierarchyPeers[peer.key] {
            if existing != role {
                await hierarchy.disconnect(peer.id)
            }
            return
        }
        hierarchyPeers[peer.key] = role
        if case .parent = role {
            await flushWaitingForParent()
            await flushWaitingProofRoots()
            await requestEvidenceIndex(after: nil)
            try? await refreshInheritedWork()
        } else if case .child(let path) = role,
                  let directory = path.last {
            await retryCurrentTipChildProofs(directories: [directory])
        }
    }

    private func admitCandidate(_ candidate: Candidate) async {
        guard let process else { return }
        let childDirectories = authenticatedChildDirectories()
        let attempt: (
            value: NodeAdmissionOutcome,
            attribution: IvyRootContentSource.Attribution
        )
        do {
            attempt = try await remoteContentSource.withRootTracing(candidate.childCID) {
                try await process.admit(
                    BlockHeader(
                        rawCID: candidate.childCID,
                        node: nil,
                        encryptionInfo: nil
                    ),
                    authenticatedChildPackage: candidate.package,
                    preparingChildDirectories: childDirectories
                )
            }
        } catch {
            await continueProofRootScan(after: candidate)
            return
        }
        let outcome = attempt.value
        let effectsHandled = await applyAdmissionEffects(
            for: candidate,
            outcome: outcome,
            process: process
        )

        // This is a required acquisition retry even when the current attempt
        // staged useful work; it is never interpreted as terminal success.
        if let predecessor = outcome.sameChainPredecessor,
           let payload = try? PredecessorRequestMessage(
            predecessorCID: predecessor.predecessorCID
           ).encoded() {
            remember(candidate, waitingFor: predecessor.predecessorCID)
            for peer in overlayPeers.values {
                _ = await overlay.sendMessage(
                    to: peer.id,
                    topic: NodeNetworkTopic.predecessorRequest,
                    payload: payload
                )
            }
        }

        if outcome.parentCarrierLink != nil {
            await flushWaitingEvidenceResponses()
            let descendants = waitingDescendants.removeValue(
                forKey: candidate.childCID
            ) ?? []
            for descendant in descendants {
                await admitCandidate(descendant)
            }
        }

        var awaitingEvidence = false
        switch outcome.decision {
        case .canonicalized:
            if !effectsHandled { try? await canonicalTipDidChange() }
        case .acceptedSide:
            if !effectsHandled { try? await announceBlock(candidate.childCID) }
        case .unavailable(let requirement?):
            awaitingEvidence = true
            await requestEvidence(requirement, for: candidate)
        default:
            break
        }

        if candidate.package != nil, !configuration.address.isNexus {
            try? await refreshInheritedWork()
        }
        if outcome.decision == .invalid,
           attempt.attribution.allResponsesComplete,
           let supplierKey = attempt.attribution.soleRemoteSupplierPublicKey,
           let supplier = try? PeerKey(supplierKey),
           overlayPeers[supplier] != nil,
           (configuration.address.isNexus || outcome.parentCarrierLink != nil) {
            await overlay.reportDeficientContent(
                rootCID: candidate.childCID,
                servedBy: PeerID(publicKey: supplierKey)
            )
        }
        // Parent evidence is never penalized: this feedback only suppresses the
        // exact same-chain content server for this root.
        if !awaitingEvidence, outcome.sameChainPredecessor == nil {
            await continueProofRootScan(after: candidate)
        }
    }

    private func applyAdmissionEffects(
        for candidate: Candidate,
        outcome: NodeAdmissionOutcome,
        process: ChainProcess
    ) async -> Bool {
        guard let admissionHandler else { return false }
        let localData: Data?
        if let packageData = candidate.package?.acquisitionEntries[
            candidate.childCID
        ] {
            localData = packageData
        } else {
            localData = try? await process.fetch(rawCid: candidate.childCID)
        }
        guard let localData,
              let block = _contentBoundBlock(
                cid: candidate.childCID,
                data: localData
              ) else { return false }
        do {
            try await admissionHandler(block, outcome)
            return true
        } catch {
            return false
        }
    }

    private func continueProofRootScan(after candidate: Candidate) async {
        guard let cursor = candidate.nextProofRootCursor else { return }
        await requestProofRoots(
            for: Candidate(
                childCID: candidate.childCID,
                package: nil
            ),
            afterRootCID: cursor
        )
    }

    private func requestEvidenceIndex(
        after: IssuedChildEvidenceSummary?
    ) async {
        guard !configuration.address.isNexus,
              pendingEvidenceIndexes.isEmpty,
              let parent = configuredParentPeer() else { return }
        let request = ChildEvidenceIndexRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            after: after
        )
        guard let payload = try? request.encoded(),
              case .enqueued = await hierarchy.sendMessage(
                to: parent.id,
                topic: NodeNetworkTopic.childEvidenceIndexRequest,
                payload: payload
              ) else { return }
        pendingEvidenceIndexes[request.requestID] = request
        scheduleEvidenceIndexTimeout(request.requestID)
    }

    private func scheduleEvidenceIndexTimeout(_ requestID: UInt64) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.evidenceIndexRequestTimedOut(requestID)
        }
    }

    private func evidenceIndexRequestTimedOut(_ requestID: UInt64) async {
        guard isRunning,
              let request = pendingEvidenceIndexes.removeValue(
                forKey: requestID
              ) else { return }
        await requestEvidenceIndex(after: request.after)
    }

    private func requestProofRoots(
        for candidate: Candidate,
        afterRootCID: String? = nil
    ) async {
        guard !configuration.address.isNexus else { return }
        if afterRootCID == nil,
           pendingProofRoots.values.contains(where: {
               $0.candidate.childCID == candidate.childCID
           }) {
            return
        }
        guard pendingProofRoots.count < Self.maximumPendingRequests,
              let parent = configuredParentPeer() else {
            rememberProofRoots(candidate)
            return
        }
        let request = ChildProofRootsRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            childCID: candidate.childCID,
            afterRootCID: afterRootCID
        )
        guard let payload = try? request.encoded() else { return }
        let result = await hierarchy.sendMessage(
            to: parent.id,
            topic: NodeNetworkTopic.childProofRootsRequest,
            payload: payload
        )
        if case .enqueued = result {
            pendingProofRoots[request.requestID] = PendingProofRoots(
                candidate: candidate,
                request: request
            )
            waitingProofRoots.removeValue(forKey: candidate.childCID)
            scheduleProofRootsTimeout(request.requestID)
        } else {
            rememberProofRoots(candidate)
        }
    }

    private func rememberProofRoots(_ candidate: Candidate) {
        if waitingProofRoots[candidate.childCID] == nil,
           waitingProofRoots.count >= Self.maximumPendingRequests,
           let evicted = waitingProofRoots.keys.first {
            waitingProofRoots.removeValue(forKey: evicted)
        }
        waitingProofRoots[candidate.childCID] = candidate
    }

    private func flushWaitingProofRoots() async {
        let waiting = Array(waitingProofRoots.values)
        waitingProofRoots.removeAll()
        for candidate in waiting {
            await requestProofRoots(for: candidate)
        }
    }

    private func scheduleProofRootsTimeout(_ requestID: UInt64) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.proofRootsRequestTimedOut(requestID)
        }
    }

    private func proofRootsRequestTimedOut(_ requestID: UInt64) async {
        guard isRunning,
              let pending = pendingProofRoots.removeValue(
                forKey: requestID
              ) else { return }
        await requestProofRoots(
            for: pending.candidate,
            afterRootCID: pending.request.afterRootCID
        )
    }

    private func requestEvidence(
        _ requirement: CrossChainEvidenceRequirement,
        for candidate: Candidate,
        proofRootCID requestedProofRootCID: String? = nil
    ) async {
        var candidate = candidate
        let proofRootCID = candidate.package?.package.proof.rootCID
            ?? requestedProofRootCID
        let key = requirementKey(requirement, proofRootCID: proofRootCID)
        guard candidate.attemptedRequirements.insert(key).inserted else {
            rememberForParent(
                candidate,
                requirement: requirement,
                proofRootCID: proofRootCID
            )
            return
        }
        guard pendingEvidence.count < Self.maximumPendingRequests,
              let parent = configuredParentPeer() else {
            rememberForParent(
                candidate,
                requirement: requirement,
                proofRootCID: proofRootCID
            )
            return
        }
        let requestID = makeRequestID()
        guard let request = ChildEvidenceRequestMessage(
            requestID: requestID,
            requirement: requirement,
            expectedChildPath: configuration.chainPath,
            expectedChildCID: candidate.childCID,
            proofRootCID: proofRootCID
        ), let payload = try? request.encoded() else { return }
        let result = await hierarchy.sendMessage(
            to: parent.id,
            topic: NodeNetworkTopic.childEvidenceRequest,
            payload: payload
        )
        if case .enqueued = result {
            pendingEvidence[requestID] = PendingEvidence(
                candidate: candidate,
                requirement: requirement,
                proofRootCID: proofRootCID
            )
            scheduleEvidenceTimeout(requestID)
        } else {
            rememberForParent(
                candidate,
                requirement: requirement,
                proofRootCID: proofRootCID
            )
        }
    }

    private func serveEvidenceRequest(
        _ request: ChildEvidenceRequestMessage,
        to peer: AuthenticatedPeer,
        rememberOnMiss: Bool
    ) async {
        guard let process,
              let evidence = try? await process.issuedChildEvidence(
                childCID: request.childCID,
                rootCID: request.proofRootCID
              ) else {
            if rememberOnMiss { remember(request, from: peer) }
            return
        }
        let proof = evidence.proof

        let carrierLink: ParentCarrierLink?
        let genesisLink: ParentGenesisLink?
        switch request.kind {
        case .proof:
            carrierLink = nil
            genesisLink = nil
        case .parentCarrier:
            carrierLink = try? await process.issuedParentCarrierLink(
                carrierCID: request.carrierCID!,
                rootCID: request.rootCID!
            )
            genesisLink = nil
            guard carrierLink != nil else {
                if rememberOnMiss { remember(request, from: peer) }
                return
            }
        case .parentGenesis:
            carrierLink = nil
            genesisLink = try? await process.issuedParentGenesisLink(
                directory: request.directory!,
                childGenesisCID: request.childGenesisCID!
            )
            guard genesisLink != nil else {
                if rememberOnMiss { remember(request, from: peer) }
                return
            }
        }

        guard let envelope = try? ChildValidationPackageEnvelope(
            ChildValidationPackage(
                proof: proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: genesisLink
            )
        ) else { return }
        let contentPayload: Data?
        if case .proof = request.kind {
            contentPayload = try? ChildEvidenceResponseMessage(
                requestID: request.requestID,
                childCID: request.childCID,
                acquisitionEntries: evidence.acquisitionEntries,
                envelope: envelope
            ).encoded()
        } else {
            contentPayload = nil
        }
        guard let payload = contentPayload
            ?? (try? ChildEvidenceResponseMessage(
                requestID: request.requestID,
                childCID: request.childCID,
                envelope: envelope
            ).encoded()) else { return }

        let result = await hierarchy.sendMessage(
            to: peer.id,
            topic: NodeNetworkTopic.childEvidenceResponse,
            payload: payload
        )
        if case .enqueued = result {
            waitingEvidenceResponses.removeValue(
                forKey: waitingEvidenceKey(peer: peer, requestID: request.requestID)
            )
        } else if rememberOnMiss {
            remember(request, from: peer)
        }
    }

    private func remember(
        _ request: ChildEvidenceRequestMessage,
        from peer: AuthenticatedPeer
    ) {
        guard waitingEvidenceResponses.count < Self.maximumPendingRequests else { return }
        waitingEvidenceResponses[
            waitingEvidenceKey(peer: peer, requestID: request.requestID)
        ] = WaitingEvidence(peer: peer, request: request)
    }

    private func flushWaitingEvidenceResponses() async {
        let waiting = Array(waitingEvidenceResponses.values)
        for item in waiting {
            await serveEvidenceRequest(item.request, to: item.peer, rememberOnMiss: false)
        }
    }

    private func flushWaitingForParent() async {
        let waiting = Array(waitingForParent.values)
        waitingForParent.removeAll()
        for item in waiting {
            var retriable = item.candidate
            retriable.attemptedRequirements.remove(requirementKey(
                item.requirement,
                proofRootCID: item.proofRootCID
            ))
            await requestEvidence(
                item.requirement,
                for: retriable,
                proofRootCID: item.proofRootCID
            )
        }
    }

    private func requestChildCandidate(
        from peerKey: PeerKey,
        childPath: [String],
        parentCID: String,
        parentData: Data,
        rewards: [MiningReward],
        deadline: ContinuousClock.Instant
    ) async -> DirectChildCandidate? {
        guard isRunning,
              let process,
              pendingChildCandidates.count < Self.maximumDirectChildren else {
            return nil
        }
        guard let rewards = await resolvedMiningRewards(
            rewards,
            process: process
        ) else { return nil }
        let remaining = Self.milliseconds(
            ContinuousClock.now.duration(to: deadline)
        )
        guard let remoteBudget = Self.remoteChildCandidateBudget(
            parentWaitMilliseconds: remaining
        ) else { return nil }
        // The receiver starts its monotonic deadline after transit. Give it a
        // strictly smaller budget so serialization and the response have room
        // before our local continuation times out.
        let request = ChildCandidateRequestMessage(
            requestID: makeRequestID(),
            budgetMilliseconds: remoteBudget,
            childPath: childPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: rewards
        )
        guard let payload = try? request.encoded() else { return nil }
        return await withCheckedContinuation { continuation in
            pendingChildCandidates[request.requestID] = PendingChildCandidateRequest(
                peerKey: peerKey,
                childPath: childPath,
                parentCID: parentCID,
                continuation: continuation
            )
            scheduleChildCandidateTimeout(
                request.requestID,
                after: .milliseconds(Int64(remaining))
            )
            Task { [weak self] in
                await self?.sendChildCandidateRequest(
                    requestID: request.requestID,
                    peerKey: peerKey,
                    payload: payload
                )
            }
        }
    }

    private func resolvedMiningRewards(
        _ rewards: [MiningReward],
        process: ChainProcess
    ) async -> [MiningReward]? {
        var resolved: [MiningReward] = []
        resolved.reserveCapacity(rewards.count)
        for reward in rewards {
            if reward.transaction.body.node != nil {
                resolved.append(reward)
                continue
            }
            guard let data = try? await process.fetch(
                    rawCid: reward.transaction.body.rawCID
                  ), let body = TransactionBody(data: data),
                  body.toData() == data,
                  let header = try? HeaderImpl<TransactionBody>(node: body),
                  header.rawCID == reward.transaction.body.rawCID else {
                return nil
            }
            resolved.append(MiningReward(
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
        let directories: [String] = Array(Set<String>(
            hierarchyPeers.values.compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.last
            }
        )).sorted()
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
        directories: [String]? = nil
    ) async {
        guard let process else { return }
        let resolvedTipCID: String
        if let tipCID {
            resolvedTipCID = tipCID
        } else {
            guard let currentTipCID = await process.status().tipCID else { return }
            resolvedTipCID = currentTipCID
        }
        let directories = directories ?? authenticatedChildDirectories()
        guard !directories.isEmpty else { return }
        try? await remoteContentSource.withRoot(resolvedTipCID) {
            try await process.prepareChildProofs(
                for: BlockHeader(
                    rawCID: resolvedTipCID,
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: directories
            )
        }
        await flushWaitingEvidenceResponses()
    }

    private func retryRecoveredChildProofs() async {
        guard let process,
              let carrierCIDs = try? await process.pendingChildProofCarrierCIDs()
        else { return }
        for carrierCID in carrierCIDs {
            try? await remoteContentSource.withRoot(carrierCID) {
                try await process.retryPendingChildProofs(
                    carrierCID: carrierCID
                )
            }
        }
        await flushWaitingEvidenceResponses()
    }

    private func sendChildCandidateRequest(
        requestID: UInt64,
        peerKey: PeerKey,
        payload: Data
    ) async {
        guard pendingChildCandidates[requestID] != nil,
              case .child? = hierarchyPeers[peerKey] else {
            finishChildCandidateRequest(requestID, with: nil)
            return
        }
        let result = await hierarchy.sendMessage(
            to: PeerID(publicKey: peerKey.hex),
            topic: NodeNetworkTopic.childCandidateRequest,
            payload: payload
        )
        guard case .enqueued = result else {
            finishChildCandidateRequest(requestID, with: nil)
            return
        }
    }

    private func startChildCandidateBuild(
        _ request: ChildCandidateRequestMessage,
        parent: Block,
        peer: AuthenticatedPeer
    ) {
        guard childCandidateBuilds[request.requestID] == nil,
              childCandidateBuilds.count < Self.maximumConcurrentChildBuilds,
              let builder = childCandidateBuilder else { return }
        let budget = min(
            UInt64(request.budgetMilliseconds),
            Self.milliseconds(planeConfigurations.hierarchy.requestTimeout)
        )
        guard budget > 0 else { return }
        let deadline = ContinuousClock.now + .milliseconds(Int64(budget))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.buildChildCandidate(
                request,
                parent: parent,
                peer: peer,
                deadline: deadline,
                builder: builder
            )
        }
        childCandidateBuilds[request.requestID] = ChildCandidateBuild(
            peerKey: peer.key,
            task: task
        )
        scheduleChildCandidateBuildTimeout(
            request.requestID,
            after: .milliseconds(Int64(budget))
        )
    }

    private func buildChildCandidate(
        _ request: ChildCandidateRequestMessage,
        parent: Block,
        peer: AuthenticatedPeer,
        deadline: ContinuousClock.Instant,
        builder: ContextualChildCandidateBuilder
    ) async {
        defer { childCandidateBuilds.removeValue(forKey: request.requestID) }
        let candidate = try? await ChildCandidateBudget.$deadline.withValue(
            deadline
        ) {
            try await builder(ChildCandidateRequestContext(
                parentCarrier: parent,
                rewards: request.rewards
            ))
        }
        guard let candidate,
              !Task.isCancelled,
              candidate.directory == configuration.address.directory,
              let blockData = candidate.block.toData(),
              let childCID = try? BlockHeader(node: candidate.block).rawCID,
              let payload = try? ChildCandidateResponseMessage(
                requestID: request.requestID,
                childPath: configuration.chainPath,
                parentCID: request.parentCID,
                childCID: childCID,
                searchTarget: candidate.searchTarget,
                blockData: blockData,
                acquisitionEntries: candidate.acquisitionEntries
              ).encoded(),
              case .parent? = hierarchyPeers[peer.key] else { return }
        _ = await hierarchy.sendMessage(
            to: peer.id,
            topic: NodeNetworkTopic.childCandidateResponse,
            payload: payload
        )
    }

    private func scheduleChildCandidateTimeout(
        _ requestID: UInt64,
        after timeout: Duration
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.childCandidateRequestTimedOut(requestID)
        }
    }

    private func scheduleChildCandidateBuildTimeout(
        _ requestID: UInt64,
        after timeout: Duration
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.cancelChildCandidateBuild(requestID)
        }
    }

    private func childCandidateRequestTimedOut(_ requestID: UInt64) {
        finishChildCandidateRequest(requestID, with: nil)
    }

    private func cancelChildCandidateBuild(_ requestID: UInt64) {
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

    private func rememberForParent(
        _ candidate: Candidate,
        requirement: CrossChainEvidenceRequirement,
        proofRootCID: String?
    ) {
        let key = candidate.childCID + ":" + requirementKey(
            requirement,
            proofRootCID: proofRootCID
        )
        guard waitingForParent[key] != nil
                || waitingForParent.count < Self.maximumPendingRequests else { return }
        waitingForParent[key] = DeferredEvidence(
            candidate: candidate,
            requirement: requirement,
            proofRootCID: proofRootCID
        )
    }

    private func scheduleEvidenceTimeout(_ requestID: UInt64) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.evidenceRequestTimedOut(requestID)
        }
    }

    private func evidenceRequestTimedOut(_ requestID: UInt64) async {
        guard isRunning,
              let pending = pendingEvidence.removeValue(forKey: requestID) else { return }
        var candidate = pending.candidate
        candidate.attemptedRequirements.remove(requirementKey(
            pending.requirement,
            proofRootCID: pending.proofRootCID
        ))
        await requestEvidence(
            pending.requirement,
            for: candidate,
            proofRootCID: pending.proofRootCID
        )
    }

    private func scheduleCoverageTimeout(_ requestID: UInt64) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.coverageRequestTimedOut(requestID)
        }
    }

    private func coverageRequestTimedOut(_ requestID: UInt64) async {
        guard isRunning, pendingCoverage.remove(requestID) != nil else { return }
        try? await refreshInheritedWork()
    }

    private func childCandidateRequestDeadline() -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        let overallDeadline = ChildCandidateBudget.deadline
            ?? now + planeConfigurations.hierarchy.requestTimeout
        let remaining = Self.milliseconds(now.duration(to: overallDeadline))
        guard remaining > Self.childCandidateFinalizeReserveMilliseconds else {
            return nil
        }
        return now + .milliseconds(Int64(
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

    static func remoteChildCandidateBudget(
        parentWaitMilliseconds: UInt64
    ) -> UInt32? {
        guard parentWaitMilliseconds > 1 else { return nil }
        let budget = parentWaitMilliseconds
            - max(1, parentWaitMilliseconds / 4)
        return UInt32(min(
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
        let activePaths: Set<String> = Set(activeRoles.compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.joined(separator: "/")
        })
        rotations = rotations.filter { activePaths.contains($0.key) }
    }

    private func configuredParentPeer() -> AuthenticatedPeer? {
        guard let parentKey = configuration.parentEndpoint?.publicKey,
              let key = try? PeerKey(parentKey),
              case .parent? = hierarchyPeers[key] else { return nil }
        return AuthenticatedPeer(
            key: key,
            role: .endpoint,
            route: .direct,
            metadata: PeerMetadata()
        )
    }

    private func makeRequestID() -> UInt64 {
        repeat { nextRequestID &+= 1 } while nextRequestID == 0
        return nextRequestID
    }

    private func requirementKey(
        _ requirement: CrossChainEvidenceRequirement,
        proofRootCID: String?
    ) -> String {
        let requirementKey = switch requirement {
        case .childProof(let path, let cid):
            "proof:\(path.joined(separator: "/")):\(cid)"
        case .parentCarrier(let path, let carrier, let root):
            "carrier:\(path.joined(separator: "/")):\(carrier):\(root)"
        case .parentGenesis(let path, let directory, let cid):
            "genesis:\(path.joined(separator: "/")):\(directory):\(cid)"
        }
        return requirementKey + ":" + (proofRootCID ?? "*")
    }

    private func waitingEvidenceKey(
        peer: AuthenticatedPeer,
        requestID: UInt64
    ) -> String {
        "\(peer.key.hex):\(requestID)"
    }

    static func hierarchyRole(
        for remote: ChainHello,
        peerKey: String,
        configuration: NodeConfiguration
    ) -> HierarchyPeer? {
        if let parent = configuration.parentEndpoint,
           peerKey == parent.publicKey {
            let expectedPath = Array(configuration.chainPath.dropLast())
            return (try? remote.validateCompatibility(
                expectedNexusGenesisCID: configuration.nexusGenesisCID,
                expectedChainPath: expectedPath,
                expectedMinimumRootWorkHex: configuration.minimumRootWork.toHexString()
            )).map { .parent }
        }
        guard remote.chainPath.count == configuration.chainPath.count + 1,
              Array(remote.chainPath.dropLast()) == configuration.chainPath else {
            return nil
        }
        return (try? remote.validateCompatibility(
            expectedNexusGenesisCID: configuration.nexusGenesisCID,
            expectedChainPath: remote.chainPath,
            expectedMinimumRootWorkHex: configuration.minimumRootWork.toHexString()
        )).map { .child(remote.chainPath) }
    }

    private func remember(_ candidate: Candidate, waitingFor predecessorCID: String) {
        var descendants = waitingDescendants[predecessorCID] ?? []
        if let index = descendants.firstIndex(where: {
            $0.childCID == candidate.childCID
        }) {
            descendants[index] = candidate
        } else {
            let count = waitingDescendants.values.reduce(0) { $0 + $1.count }
            guard count < Self.maximumPendingRequests else { return }
            descendants.append(candidate)
        }
        waitingDescendants[predecessorCID] = descendants
    }

    static func matches(
        _ response: ChildProofRootsResponseMessage,
        request: ChildProofRootsRequestMessage
    ) -> Bool {
        response.requestID == request.requestID
            && response.childPath == request.childPath
            && response.childCID == request.childCID
            && response.afterRootCID == request.afterRootCID
    }

    static func attachingEvidenceContent(
        _ data: Data?,
        acquisitionEntries receivedEntries: [String: Data],
        childCID: String,
        to package: AuthenticatedChildPackage
    ) -> AuthenticatedChildPackage? {
        var entries = package.acquisitionEntries
        for (cid, entry) in receivedEntries {
            guard entries[cid].map({ $0 == entry }) ?? true else { return nil }
            entries[cid] = entry
        }
        if let data {
            guard !data.isEmpty,
                  entries[childCID].map({ $0 == data }) ?? true else { return nil }
            entries[childCID] = data
        }
        return AuthenticatedChildPackage(
            package: package.package,
            acquisitionEntries: entries
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
                || left.parentGenesisLink == right.parentGenesisLink else {
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
            acquisitionEntries: acquisitionEntries
        )
    }

    static func satisfies(
        _ received: AuthenticatedChildPackage,
        requirement: CrossChainEvidenceRequirement,
        proofRootCID: String?
    ) -> Bool {
        let package = received.package
        guard proofRootCID.map({ package.proof.rootCID == $0 }) ?? true else {
            return false
        }
        switch requirement {
        case .childProof(let path, let childCID):
            return package.proof.directoryPath == Array(path.dropFirst())
                && !childCID.isEmpty
        case .parentCarrier(let path, let carrierCID, let rootCID):
            guard let link = package.parentCarrierLink else { return false }
            return link.parentPath == path
                && link.carrierCID == carrierCID
                && link.rootCID == rootCID
        case .parentGenesis(let path, let directory, let childGenesisCID):
            guard let link = package.parentGenesisLink else { return false }
            return link.parentPath == path
                && link.directory == directory
                && link.childGenesisCID == childGenesisCID
        }
    }
}

private extension Ivy {
    func install(
        delegate: IvyDelegate,
        contentSource: (any IvyContentSource)?
    ) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
