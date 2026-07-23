import Foundation
import Lattice
import VolumeBroker
import cashew

enum AdmissionAcquisitionScope {
    @TaskLocal static var exactSource: (any ContentSource)?
}

public enum ChainProcessError: Error, Equatable, Sendable {
    case invalidStoragePath
    case storageInUse
    case storageUnavailable
    case invalidNexusGenesis
    case missingMaterializedVolume(String)
    case nexusHasNoInheritedWork
    case parentWorkAuthorityMismatch
    case chainNotBootstrapped
    case unresolvedCanonicalTip(String)
    case malformedAuthenticatedChildProof
    case acquisitionPackageTooLarge
}

public enum ChainProcessPhase: String, Sendable {
    case awaitingGenesis
    case active
}

public struct ChainProcessStatus: Sendable, Equatable {
    public let phase: ChainProcessPhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    public let height: UInt64?
    public let revision: UInt64?
    public let parentWorkRevision: UInt64?
}

/// The result must be routed immediately when `parentCarrierLink` is present;
/// the link is authenticated evidence, not local consensus state.
public struct NodeAdmissionOutcome: Sendable {
    public let decision: NodeAdmissionDecision
    public let parentCarrierLink: ParentCarrierLink?
    public let sameChainPredecessor: SameChainPredecessorRequirement?
    let inheritedWorkChanged: Bool
    let canonicalCommitReceipt: CanonicalCommitReceipt?

    init(
        decision: NodeAdmissionDecision,
        parentCarrierLink: ParentCarrierLink?,
        sameChainPredecessor: SameChainPredecessorRequirement?,
        inheritedWorkChanged: Bool = false,
        canonicalCommitReceipt: CanonicalCommitReceipt? = nil
    ) {
        self.decision = decision
        self.parentCarrierLink = parentCarrierLink
        self.sameChainPredecessor = sameChainPredecessor
        self.inheritedWorkChanged = inheritedWorkChanged
        self.canonicalCommitReceipt = canonicalCommitReceipt
    }
}

/// A one-shot completion token for source-ordered canonical reconciliation.
/// It is intentionally independent of actor lifetime so callers can release
/// their own operation gate before waiting for the queued reconciliation.
actor CanonicalCommitReceipt {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    func wait() async {
        await withCheckedContinuation { continuation in
            if finished {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// The process owns the order in which consensus mutations become durable;
/// the service owns the projections that follow those mutations. Keeping the
/// receipt with the commit lets the process reserve the service FIFO before a
/// later process mutation can overtake it.
struct InheritedWorkUpdate: Sendable {
    let commit: ChainCommit?
    let canonicalCommitReceipt: CanonicalCommitReceipt?
}

/// Receives each mutation commit while `ChainProcess` still owns its operation
/// order. Implementations must enqueue and return; reconciliation belongs to a
/// separate worker so it cannot re-enter the process operation.
typealias CanonicalCommitPublisher = @Sendable (ChainCommit) async
    -> CanonicalCommitReceipt

struct DurableDirectChildProof: Sendable {
    let directory: String
    let childCID: String
    let childBlock: Block
    let proof: ChildBlockProof
    let acquisitionEntries: [String: Data]
}

private actor BoundedContentCollector: VolumeStorer {
    private let maximumBytes: Int
    private var byteCount = 0
    private var values: [String: Data] = [:]

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func store(volume: SerializedVolume) throws {
        try store(entries: volume.entries)
    }

    private func store(entries: [String: Data]) throws {
        for (cid, data) in entries {
            if let existing = values[cid] {
                guard existing == data else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                continue
            }
            let framedBytes = 6 + cid.utf8.count + data.count
            let next = byteCount.addingReportingOverflow(framedBytes)
            guard !next.overflow, next.partialValue <= maximumBytes else {
                throw ChainProcessError.acquisitionPackageTooLarge
            }
            values[cid] = data
            byteCount = next.partialValue
        }
    }

    func entries() -> [String: Data] {
        values
    }
}

/// Stores a complete Volume before making its root live in this process's
/// retention set. Live retention is merge-only; startup is the sole exact
/// reconciliation point.
private final class RetainingVolumeStorer: VolumeStorer {
    private let volumes: any VolumeStorer
    private let broker: DiskBroker
    private let scope: String

    init(volumes: any VolumeStorer, broker: DiskBroker, scope: String) {
        self.volumes = volumes
        self.broker = broker
        self.scope = scope
    }

    func store(volume: SerializedVolume) async throws {
        try await volumes.store(volume: volume)
        try await broker.mergeRetainedRoots(scope: scope, roots: [volume.root])
    }
}

struct DurableLocalTransaction: Sendable {
    let transactionCID: String
    let addedAt: Int64
    let transaction: Transaction
}

/// One process owns one absolute chain path. Child processes have an explicit
/// pre-genesis phase so target-miss carriers can relay deeper accepted work
/// without inventing local chain state.
public actor ChainProcess: Fetcher, VolumeStorer {
    private enum RuntimePhase: Sendable {
        case awaitingGenesis
        case active(ChainLevel)
    }

    private enum TargetedChildProofResolution: Sendable {
        case absent
        case prepared(PreparedChildProof)
        case unavailable
    }

    private static let maximumDirectChildRoutes = 64
    private static let preparedChildProofCapacity = 16

    public nonisolated let configuration: NodeConfiguration

    private let store: NodeStore
    private let broker: DiskBroker
    private let brokerStorer: BrokerStorer
    private let localSource: any ContentSource
    private let localFetcher: CoalescingFetcher
    /// Immutable local-plus-remote source. Every network acquisition wraps it
    /// in a fresh coalescer so Ivy's root trace cannot cross candidates.
    private let acquisitionSource: any ContentSource
    private let retentionScope: String
    private let durableMempoolOwner: String
    private let liveMempoolOwner: String
    private let directoryLock: StorageDirectoryLock
    private var runtimePhase: RuntimePhase
    private var livePinnedMempoolRoots = Set<String>()

    // Actors are reentrant. This queue keeps admission, inherited-work updates,
    // and eviction in one durability order across their suspension points.
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var operationInFlight = false
    private var operationWaiters: [OperationWaiter] = []
#if DEBUG
    private var operationWaiterChangeWaiters: [CheckedContinuation<Void, Never>] = []
#endif

    private init(
        configuration: NodeConfiguration,
        store: NodeStore,
        broker: DiskBroker,
        brokerStorer: BrokerStorer,
        localSource: any ContentSource,
        localFetcher: CoalescingFetcher,
        acquisitionSource: any ContentSource,
        retentionScope: String,
        durableMempoolOwner: String,
        liveMempoolOwner: String,
        directoryLock: StorageDirectoryLock,
        runtimePhase: RuntimePhase
    ) {
        self.configuration = configuration
        self.store = store
        self.broker = broker
        self.brokerStorer = brokerStorer
        self.localSource = localSource
        self.localFetcher = localFetcher
        self.acquisitionSource = acquisitionSource
        self.retentionScope = retentionScope
        self.durableMempoolOwner = durableMempoolOwner
        self.liveMempoolOwner = liveMempoolOwner
        self.directoryLock = directoryLock
        self.runtimePhase = runtimePhase
    }

    /// Completes store validation, retained-root reconciliation, and recovery
    /// before returning a process that networking may expose.
    public static func open(
        configuration: NodeConfiguration,
        remoteSource: (any ContentSource)? = nil
    ) async throws -> ChainProcess {
        guard configuration.storagePath.isFileURL else {
            throw ChainProcessError.invalidStoragePath
        }
        try FileManager.default.createDirectory(
            at: configuration.storagePath,
            withIntermediateDirectories: true
        )
        let directoryLock: StorageDirectoryLock
        do {
            directoryLock = try StorageDirectoryLock(directory: configuration.storagePath)
        } catch StorageDirectoryLockError.alreadyLocked {
            throw ChainProcessError.storageInUse
        } catch {
            throw ChainProcessError.storageUnavailable
        }

        let broker = try DiskBroker(
            path: configuration.storagePath.appendingPathComponent("volumes.db").path
        )
        let brokerStorer = BrokerStorer(broker: broker)
        let brokerFetcher = BrokerFetcher(broker: broker)
        let localSource: any ContentSource = brokerFetcher
        let localFetcher = CoalescingFetcher(localSource)
        var sources: [any ContentSource] = [brokerFetcher]
        if let remoteSource { sources.append(remoteSource) }
        let acquisitionSource = CompositeContentSource(sources)
        let retentionScope = [
            configuration.nexusGenesisCID,
            configuration.address.key,
        ].joined(separator: ":")
        let legacyMempoolRetentionScope = retentionScope + ":mempool"
        let durableMempoolOwner = retentionScope + ":durable-mempool"
        let liveMempoolOwner = retentionScope + ":live-mempool"
        let recoveryVolumeStorer = RetainingVolumeStorer(
            volumes: brokerStorer,
            broker: broker,
            scope: retentionScope
        )
        let store = try NodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWork: configuration.minimumRootWork,
            spawningParentKey: configuration.parentEndpoint?.publicKey ?? "",
            issuingAuthorityKey: configuration.processPublicKey,
            recoveryVolumeStorer: recoveryVolumeStorer,
            recoveryVolumeBroker: broker
        )

        // Protocol constants are ordinary Volumes and therefore ordinary GC
        // roots. Materialize them before the one exact startup reconciliation.
        let constantStorage = NodeAdmissionStorage(storage: brokerStorer)
        try await LatticeState.emptyHeader.storeRecursively(
            storer: constantStorage as any VolumeStorer
        )
        let constantRoots = await constantStorage.takeStoredVolumeRoots()

        let staged = try await store.stagedAdmissions()
        try await store.auditNormalizedIndexes()
        let retainedRoots = try await durableRetainedRoots(
            staged: staged,
            store: store,
            additionalRoots: constantRoots
        )
        for root in retainedRoots {
            guard await broker.fetchVolumeLocal(root: root) != nil else {
                throw ChainProcessError.missingMaterializedVolume(root)
            }
        }
        try await broker.advanceRetainedRoots(
            scope: retentionScope,
            roots: retainedRoots
        )
        let localMempoolRoots = try await store.localMempoolTransactions()
            .map(\.transactionCID)
        for root in localMempoolRoots {
            guard await broker.fetchVolumeLocal(root: root) != nil,
                  let resolved = try? await VolumeImpl<Transaction>(
                    rawCID: root
                  ).resolveRecursive(source: localSource),
                  resolved.node != nil else {
                throw ChainProcessError.missingMaterializedVolume(root)
            }
        }
        try await broker.unpinAll(owner: durableMempoolOwner)
        try await broker.pinBatch(
            roots: localMempoolRoots,
            owner: durableMempoolOwner
        )
        try await broker.advanceRetainedRoots(
            scope: legacyMempoolRetentionScope,
            roots: []
        )
        // The live pool is operational cache, not restart authority. Owner
        // pins support O(changes) updates and are cleared for each process.
        try await broker.unpinAll(owner: liveMempoolOwner)

        // This is the one recovery-time materialization of the parent's durable
        // fact set. Live fragments merge directly into Core below; keeping a
        // provider installed would make every later local admission revisit
        // this complete snapshot.
        let initialParentWork = try await store.inheritedWorkSnapshot()

        let context = try configuration.runtimeContext
        let runtimePhase: RuntimePhase
        if staged.isEmpty {
            if configuration.address.isNexus {
                let genesis = try await NexusGenesis.create(fetcher: localFetcher)
                guard try NexusGenesis.verifyGenesis(genesis) else {
                    throw ChainProcessError.invalidNexusGenesis
                }
                let admissionStorage = NodeAdmissionStorage(
                    storage: brokerStorer
                )
                let bootstrapped = try await ChainLevel.bootstrap(
                    context: context,
                    genesisHeader: try BlockHeader(node: genesis.block),
                    fetcher: localFetcher,
                    validationContentStorer: admissionStorage,
                    materializedVolumeStorer: admissionStorage,
                    staging: { context in
                        let hierarchyArtifacts = context.issuedCarrierLink.map {
                            AdmissionHierarchyArtifacts(
                                carrierLink: $0,
                                carrierEvidence: nil,
                                parentGenesisLinks: context.parentGenesisLinks
                            )
                        }
                        try await persist(
                            context.batch,
                            admissionStorage: admissionStorage,
                            store: store,
                            broker: broker,
                            retentionScope: retentionScope,
                            pendingChildProofRoutes: [],
                            pendingChildProofCapacity: Self.preparedChildProofCapacity,
                            hierarchyArtifacts: hierarchyArtifacts
                        )
                    }
                )
                runtimePhase = .active(bootstrapped.level)
            } else {
                runtimePhase = .awaitingGenesis
            }
        } else {
            if configuration.address.isNexus {
                let genesisRoots = Set(staged.flatMap { admission in
                    admission.batch.facts.compactMap { fact -> String? in
                        guard case .block(let block) = fact,
                              block.parentBlockHash == nil,
                              block.blockHeight == 0 else { return nil }
                        return block.blockHash
                    }
                })
                guard genesisRoots == [NexusGenesis.expectedBlockHash] else {
                    throw ChainProcessError.invalidNexusGenesis
                }
            }
            let batches = staged.map(\.batch)
            // Admission batches are the only recovery authority. The
            // projection is a derived cache and must not be able to add facts
            // or prevent a valid history from reopening.
            let chain = try await ChainState.restore(
                replaying: batches
            )
            if !configuration.address.isNexus,
               let initialParentWork {
                let bindings = try await store
                    .incomingParentCarrierBlocksByChildBlock()
                guard let inherited = await chain.inheritedWorkSnapshot(
                    from: initialParentWork,
                    parentCarrierBlocksByChildBlock: bindings
                ), await chain.acceptsInheritedWork(inherited) else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                if !inherited.isEmpty,
                   await chain.mergeInheritedWork(inherited) == nil {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            }
            let level = ChainLevel(chain: chain, context: context)
            runtimePhase = .active(level)
        }

        try await recoverPreparedChildProofs(
            store: store,
            configuration: configuration
        )

        return ChainProcess(
            configuration: configuration,
            store: store,
            broker: broker,
            brokerStorer: brokerStorer,
            localSource: localSource,
            localFetcher: localFetcher,
            acquisitionSource: acquisitionSource,
            retentionScope: retentionScope,
            durableMempoolOwner: durableMempoolOwner,
            liveMempoolOwner: liveMempoolOwner,
            directoryLock: directoryLock,
            runtimePhase: runtimePhase
        )
    }

    func admit(
        _ blockHeader: BlockHeader,
        authenticatedChildPackage suppliedAuthenticatedChildPackage:
            AuthenticatedChildPackage? = nil,
        preparingChildDirectories: [String] = [],
        allowsRemoteAcquisition: Bool = false,
        canonicalCommitPublisher: CanonicalCommitPublisher? = nil
    ) async throws -> NodeAdmissionOutcome {
        let authenticatedChildPackage: AuthenticatedChildPackage?
        if let supplied = suppliedAuthenticatedChildPackage {
            authenticatedChildPackage = supplied
        } else {
            authenticatedChildPackage = try await recoveredAuthenticatedChildPackage(
                for: blockHeader.rawCID
            )
        }
        let directChildDirectories = try validatedDirectChildDirectories(
            preparingChildDirectories
        )
        let pendingChildProofRoutes = Self.pendingChildProofRoutes(
            carrierCID: blockHeader.rawCID,
            directories: directChildDirectories
        )

        let package = authenticatedChildPackage?.package
        let acquisitionEntries = authenticatedChildPackage?.acquisitionEntries ?? [:]
        let attemptFetcher = try Self.attemptFetcher(
            package: package,
            acquisitionEntries: acquisitionEntries,
            fallback: allowsRemoteAcquisition
                ? AdmissionAcquisitionScope.exactSource.map {
                    CompositeContentSource([localSource, $0])
                } ?? acquisitionSource
                : localSource
        )
        // The child genesis CID commits its parent-work authority through the
        // ChainSpec. It must name the same parent this process is configured to
        // trust; the parent link deliberately carries no duplicate key.
        if package?.parentGenesisLink != nil {
            try await validateParentWorkAuthority(
                blockHeader,
                fetcher: attemptFetcher
            )
        }
        if case .active(let level) = runtimePhase {
            return try await admitActive(
                blockHeader,
                level: level,
                authenticatedPackage: authenticatedChildPackage,
                attemptFetcher: attemptFetcher,
                directChildDirectories: directChildDirectories,
                pendingChildProofRoutes: pendingChildProofRoutes,
                canonicalCommitPublisher: canonicalCommitPublisher
            )
        }

        // Bootstrap changes the phase, so it remains one sequential operation.
        // Once active, the Lattice preflight path above releases this lease
        // during remote acquisition and takes it only for durability/commit.
        try await acquireMutationOperation()
        var operationHeld = true
        if case .active(let level) = runtimePhase {
            releaseOperation()
            operationHeld = false
            return try await admitActive(
                blockHeader,
                level: level,
                authenticatedPackage: authenticatedChildPackage,
                attemptFetcher: attemptFetcher,
                directChildDirectories: directChildDirectories,
                pendingChildProofRoutes: pendingChildProofRoutes,
                canonicalCommitPublisher: canonicalCommitPublisher
            )
        }
        defer {
            if operationHeld {
                releaseOperation()
            }
        }

        guard case .awaitingGenesis = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        guard let package else {
            return NodeAdmissionOutcome(
                decision: .unavailable(.childProof(
                    chainPath: configuration.chainPath,
                    childCID: blockHeader.rawCID
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        // A child process can receive a valid successor attachment before its
        // genesis attachment. That is an ordering dependency, not malformed
        // genesis. Keep the authenticated candidate parked behind its direct
        // predecessor so ordinary same-chain wake-up admits it after bootstrap.
        let bootstrapCandidate = try await Self.resolvedCandidate(
            blockHeader,
            fetcher: attemptFetcher
        )
        if let predecessorCID = bootstrapCandidate.parent?.rawCID {
            return NodeAdmissionOutcome(
                decision: .unavailable(nil),
                parentCarrierLink: nil,
                sameChainPredecessor: SameChainPredecessorRequirement(
                    descendantCID: blockHeader.rawCID,
                    predecessorCID: predecessorCID
                )
            )
        }
        let admissionStorage = NodeAdmissionStorage(storage: brokerStorer)
        let carrierEvidence = try await Self.canonicalCarrierEvidence(
            blockHeader,
            authenticatedPackage: authenticatedChildPackage,
            fetcher: attemptFetcher
        )
        let stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void = {
            context in
            let hierarchyArtifacts: AdmissionHierarchyArtifacts?
            if let link = context.issuedCarrierLink {
                hierarchyArtifacts = AdmissionHierarchyArtifacts(
                    carrierLink: link,
                    carrierEvidence: carrierEvidence,
                    parentGenesisLinks: context.parentGenesisLinks
                )
            } else {
                hierarchyArtifacts = nil
            }
            try Task.checkCancellation()
            try await Self.persist(
                context.batch,
                admissionStorage: admissionStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                pendingChildProofRoutes: hierarchyArtifacts == nil
                    ? []
                    : Self.pendingChildProofRoutes(
                        carrierCID: blockHeader.rawCID,
                        directories: directChildDirectories,
                        parentGenesisLinks: context.parentGenesisLinks
                    ),
                pendingChildProofCapacity: Self.preparedChildProofCapacity,
                hierarchyArtifacts: hierarchyArtifacts,
                incomingCarrierEvidence: hierarchyArtifacts == nil
                    ? carrierEvidence
                    : nil
            )
        }
        let result = try await ChainLevel.bootstrap(
            context: configuration.runtimeContext,
            genesisHeader: blockHeader,
            fetcher: attemptFetcher,
            childPackage: package,
            validationContentStorer: admissionStorage,
            materializedVolumeStorer: admissionStorage,
            staging: stage
        )
        let decision: NodeAdmissionDecision
        let link: ParentCarrierLink
        switch result {
        case .accepted(let acceptance):
            // The exact admission batch is already durable. Hierarchy-proof
            // promotion is recoverable post-commit work;
            // neither may turn an accepted block into a reported failure.
            // Pre-genesis parent pushes are already durable. Merge the one
            // recovered source view once before exposing the new level; later
            // fragments use Core's bounded incremental path.
            if let parentWork = try await store.inheritedWorkSnapshot() {
                let bindings = try await store
                    .incomingParentCarrierBlocksByChildBlock()
                guard let inherited = await acceptance.level.chain
                    .inheritedWorkSnapshot(
                        from: parentWork,
                        parentCarrierBlocksByChildBlock: bindings
                    ), await acceptance.level.chain.acceptsInheritedWork(inherited)
                else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                if !inherited.isEmpty,
                   await acceptance.level.chain.mergeInheritedWork(inherited) == nil {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            }
            runtimePhase = .active(acceptance.level)
            let commit = acceptance.commit
            let receipt: CanonicalCommitReceipt?
            if let canonicalCommitPublisher {
                receipt = await canonicalCommitPublisher(commit)
            } else {
                receipt = nil
            }
            releaseOperation()
            operationHeld = false
            _ = try? await promotePreparedChildProofs(
                carrierCID: blockHeader.rawCID,
                upstreamProof: package.proof
            )
            _ = try? await acquirePendingChildProofs(
                carrier: blockHeader,
                directories: directChildDirectories,
                fetcher: attemptFetcher
            )
            return NodeAdmissionOutcome(
                decision: .canonicalized(commit),
                parentCarrierLink: acceptance.parentCarrierLink,
                sameChainPredecessor: nil,
                canonicalCommitReceipt: receipt
            )
        case .carrier(let resultLink):
            decision = .carrier
            link = resultLink
        case .rejected(let failure, let resultLink):
            decision = NodeAdmissionDecision(failure)
            link = resultLink
        }
        let evidence = try await Self.canonicalCarrierEvidence(
            blockHeader,
            authenticatedPackage: authenticatedChildPackage,
            fetcher: attemptFetcher
        )
        try await persistHierarchyArtifacts(
            link,
            carrierEvidence: evidence,
            pendingChildProofRoutes: pendingChildProofRoutes
        )
        releaseOperation()
        operationHeld = false
        _ = try? await acquirePendingChildProofs(
            carrier: blockHeader,
            directories: directChildDirectories,
            fetcher: attemptFetcher
        )
        return NodeAdmissionOutcome(
            decision: decision,
            parentCarrierLink: link,
            sameChainPredecessor: nil
        )
    }

    func recoveredAuthenticatedChildPackage(
        for childCID: String,
        rootCID: String? = nil
    ) async throws -> AuthenticatedChildPackage? {
        guard !configuration.address.isNexus,
              let evidence = try await store.incomingCarrierEvidence(
                childCID: childCID,
                directory: configuration.address.directory,
                rootCID: rootCID
              ) else {
            return nil
        }
        return AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: evidence.proof,
                parentCarrierLink: evidence.parentCarrierLink,
                parentGenesisLink: evidence.parentGenesisLink
            ),
            acquisitionEntries: evidence.acquisitionEntries,
            parentCarrierCertificate: evidence.parentCarrierCertificate,
            parentGenesisCertificate: evidence.parentGenesisCertificate
        )
    }

    func recoveredIncomingCarrierRootCIDs(
        for childCID: String
    ) async throws -> [String] {
        guard !configuration.address.isNexus else { return [] }
        var result: [String] = []
        var afterRootCID: String?
        while true {
            let roots = try await store.incomingCarrierProofRoots(
                childCID: childCID,
                directory: configuration.address.directory,
                afterRootCID: afterRootCID,
                limit: 257
            )
            result.append(contentsOf: roots)
            guard roots.count == 257, let last = roots.last else { return result }
            afterRootCID = last
        }
    }

    private func admitActive(
        _ blockHeader: BlockHeader,
        level: ChainLevel,
        authenticatedPackage: AuthenticatedChildPackage?,
        attemptFetcher: any Fetcher,
        directChildDirectories: [String],
        pendingChildProofRoutes: [PendingChildProofRoute],
        canonicalCommitPublisher: CanonicalCommitPublisher?
    ) async throws -> NodeAdmissionOutcome {
        let package = authenticatedPackage?.package
        let admissionStorage = NodeAdmissionStorage(storage: brokerStorer)
        let preflight = try await level.preflightBlockHeaderChainLocal(
            blockHeader,
            fetcher: attemptFetcher,
            childPackage: package,
            validationContentStorer: admissionStorage
        )
        // Keep all remote acquisition before the one serial durability lane.
        // A ready token may gain a carrier link when its predecessor commits.
        let mayIssueCarrierLink: Bool
        switch preflight {
        case .ready:
            mayIssueCarrierLink = true
        case .duplicate:
            mayIssueCarrierLink = true
        case .terminal(let result, _):
            mayIssueCarrierLink = result.parentCarrierLink != nil
        }
        let carrierEvidence: AdmissionCarrierEvidence?
        if mayIssueCarrierLink, authenticatedPackage != nil {
            carrierEvidence = try await Self.canonicalCarrierEvidence(
                blockHeader,
                authenticatedPackage: authenticatedPackage,
                fetcher: attemptFetcher
            )
        } else {
            carrierEvidence = nil
        }
        var directParentGenesisLinks: [ParentGenesisLink] = []
        if case .terminal(_, let parentGenesisLinks) = preflight {
            directParentGenesisLinks = parentGenesisLinks
        }
        let stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void = {
            context in
            let hierarchyArtifacts = context.issuedCarrierLink.map {
                AdmissionHierarchyArtifacts(
                    carrierLink: $0,
                    carrierEvidence: carrierEvidence,
                    parentGenesisLinks: context.parentGenesisLinks
                )
            }
            try Task.checkCancellation()
            try await Self.persist(
                context.batch,
                admissionStorage: admissionStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                pendingChildProofRoutes: hierarchyArtifacts == nil
                    ? []
                    : Self.pendingChildProofRoutes(
                        carrierCID: blockHeader.rawCID,
                        directories: directChildDirectories,
                        parentGenesisLinks: context.parentGenesisLinks
                ),
                pendingChildProofCapacity: Self.preparedChildProofCapacity,
                hierarchyArtifacts: hierarchyArtifacts,
                incomingCarrierEvidence: hierarchyArtifacts == nil
                    ? carrierEvidence
                    : nil
            )
        }

        try await acquireMutationOperation()
        var operationHeld = true
        defer {
            if operationHeld {
                releaseOperation()
            }
        }
        let prospectiveParentWork: InheritedWorkSnapshot?
        if mayIssueCarrierLink,
           !configuration.address.isNexus {
            prospectiveParentWork = try await prospectiveInheritedWork(
                forChildBlockCID: blockHeader.rawCID,
                adding: carrierEvidence
            )
            if let prospectiveParentWork,
               !(await level.chain.acceptsInheritedWork(prospectiveParentWork)) {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
        } else {
            prospectiveParentWork = nil
        }
        let result: ChainLocalBlockResult
        switch preflight {
        case .terminal(let terminal, _):
            result = terminal
        case .duplicate(let token):
            let resolved = try await level.resolveDuplicatePreflight(token)
            result = resolved.result
            directParentGenesisLinks = resolved.parentGenesisLinks
        case .ready(let token):
            result = try await level.commitPreflight(
                token,
                materializedVolumeStorer: admissionStorage,
                staging: stage
            )
        }

        let admissionStaged = result.commit != nil
        if !admissionStaged,
           let link = result.parentCarrierLink {
            try await store.persistIssuedHierarchyArtifacts(
                AdmissionHierarchyArtifacts(
                    carrierLink: link,
                    carrierEvidence: carrierEvidence,
                    parentGenesisLinks: directParentGenesisLinks
                ),
                pendingChildProofRoutes: Self.pendingChildProofRoutes(
                    carrierCID: blockHeader.rawCID,
                    directories: directChildDirectories,
                    parentGenesisLinks: directParentGenesisLinks
                ),
                pendingChildProofCapacity: Self.preparedChildProofCapacity
            )
        }
        let inheritedCommit: ChainCommit?
        if (admissionStaged || result.parentCarrierLink != nil),
           let prospectiveParentWork,
           !prospectiveParentWork.isEmpty {
            inheritedCommit = await level.chain.mergeInheritedWork(
                prospectiveParentWork
            )
        } else {
            inheritedCommit = nil
        }
        var receipt: CanonicalCommitReceipt?
        if let canonicalCommitPublisher {
            if let commit = result.commit {
                receipt = await canonicalCommitPublisher(commit)
            }
            if let inheritedCommit, inheritedCommit.canonicalChanged {
                receipt = await canonicalCommitPublisher(inheritedCommit)
            }
        }

        // The canonical decision is now durable and ordered for publication.
        // Everything below is replayable availability work.
        releaseOperation()
        operationHeld = false

        if let link = result.parentCarrierLink {
            if admissionStaged {
                _ = try? await promotePreparedChildProofs(
                    carrierCID: blockHeader.rawCID,
                    upstreamProof: package?.proof
                )
            } else {
                try await promotePreparedChildProofs(
                    carrierCID: link.carrierCID,
                    upstreamProof: carrierEvidence?.proof
                )
            }
            _ = try? await acquirePendingChildProofs(
                carrier: blockHeader,
                directories: directChildDirectories,
                fetcher: attemptFetcher
            )
        }
        return NodeAdmissionOutcome(
            decision: NodeAdmissionDecision(result),
            parentCarrierLink: result.parentCarrierLink,
            sameChainPredecessor: result.sameChainPredecessor,
            inheritedWorkChanged: inheritedCommit != nil,
            canonicalCommitReceipt: receipt
        )
    }

    func acceptedLeafPage(
        afterCID: String?,
        snapshotSequence: Int64?,
        limit: Int
    ) async throws -> AcceptedLeafPage {
        return try await store.acceptedLeafPage(
            afterCID: afterCID,
            snapshotSequence: snapshotSequence,
            limit: limit
        )
    }

    func portableRecoveryAttachmentCID(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> String? {
        try await store.portableRecoveryAttachmentCID(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
        )
    }

    /// Same-chain content serving reads only this process's durable local tiers.
    public func content(_ cids: Set<String>) async -> [String: Data] {
        var entries: [String: Data] = [:]
        for cid in cids where entries[cid] == nil {
            if let data = await broker.fetchDataLocal(cid: cid) {
                entries[cid] = data
            }
        }
        return entries
    }

    /// Peer content exchange serves complete local Volumes. Membership is a
    /// storage fact and cannot be reconstructed from an arbitrary CID list.
    func volume(_ rootCID: String) async -> SerializedVolume? {
        await broker.fetchVolumeLocal(root: rootCID)
    }

    /// Collects exactly the durable inputs Lattice will read while validating
    /// this block: block content, policy modules, and targeted state paths. It
    /// never traverses children or ancestors.
    /// Candidate availability contains only this chain's exact validation
    /// inputs. Descendant packages remain owned by their immediate parent.
    func durableCandidateEntries(
        for block: Block,
        fetcher: (any Fetcher)? = nil,
        maximumBytes: Int = ChildAcquisitionPackage.maximumBytes
    ) async throws -> [String: Data] {
        await acquireOperation()
        defer { releaseOperation() }
        let fetcher: any Fetcher = fetcher ?? localFetcher
        return try await Self.collectCandidateEntries(
            for: block,
            fetcher: fetcher,
            maximumBytes: maximumBytes
        )
    }

    /// The public process fetch port is deliberately local-only. Network
    /// acquisition is explicit and root-scoped at admission/retry boundaries.
    public func fetch(rawCid: String) async throws -> Data {
        try await localFetcher.fetch(rawCid: rawCid)
    }

    public func store(volume: SerializedVolume) async throws {
        try await brokerStorer.store(volume: volume)
    }

    @discardableResult
    func persistLocalTransaction(
        _ transaction: Transaction,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) async throws -> String {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        guard addedAt >= 0 else {
            throw NodeStoreError.invalidConfiguration(
                "local transaction timestamp is malformed"
            )
        }
        let volume = try VolumeImpl<Transaction>(node: transaction)
        if try await store.localMempoolTransactions().contains(where: {
            $0.transactionCID == volume.rawCID
        }) {
            return volume.rawCID
        }
        try await volume.store(storer: brokerStorer)
        try Task.checkCancellation()
        try await broker.pin(root: volume.rawCID, owner: durableMempoolOwner)
        do {
            try await store.persistLocalMempoolTransaction(
                transactionCID: volume.rawCID,
                addedAt: addedAt
            )
        } catch {
            try await broker.unpin(
                root: volume.rawCID,
                owner: durableMempoolOwner
            )
            throw error
        }
        return volume.rawCID
    }

    /// Keeps an admitted peer transaction serveable for this process lifetime.
    /// The scope is cleared on restart, so peer gossip never becomes recovery
    /// authority merely because its bytes use the durable broker.
    func persistPeerTransaction(_ transaction: Transaction) async throws -> String {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: brokerStorer)
        // Eviction uses the same process mutation gate, so publishing the
        // complete Volume and its live owner pin is atomic at the node boundary.
        if !livePinnedMempoolRoots.contains(volume.rawCID) {
            try await broker.pin(root: volume.rawCID, owner: liveMempoolOwner)
            livePinnedMempoolRoots.insert(volume.rawCID)
        }
        return volume.rawCID
    }

    /// Owner/count deltas keep live-pool retention O(changes), while startup's
    /// owner reset makes these pins process-local authority.
    func updateLiveMempoolRoots(
        adding: Set<String>,
        removing: Set<String>
    ) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let added = adding.subtracting(livePinnedMempoolRoots)
        let removed = removing.intersection(livePinnedMempoolRoots)
        if !added.isEmpty {
            try await broker.pinBatch(
                roots: added.sorted(),
                owner: liveMempoolOwner
            )
            livePinnedMempoolRoots.formUnion(added)
        }
        if !removed.isEmpty {
            try await broker.unpinBatch(items: removed.sorted().map {
                (root: $0, owner: liveMempoolOwner, count: 1)
            })
            livePinnedMempoolRoots.subtract(removed)
        }
    }

    func removeLocalTransaction(_ transactionCID: String) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try await store.removeLocalMempoolTransaction(
            transactionCID: transactionCID
        )
        try await broker.unpin(
            root: transactionCID,
            owner: durableMempoolOwner
        )
    }

    func localTransactions() async throws -> [DurableLocalTransaction] {
        await acquireOperation()
        defer { releaseOperation() }
        var transactions: [DurableLocalTransaction] = []
        for record in try await store.localMempoolTransactions() {
            let volume = try await VolumeImpl<Transaction>(
                rawCID: record.transactionCID
            ).resolveRecursive(source: localSource)
            guard let transaction = volume.node else {
                throw ChainProcessError.missingMaterializedVolume(
                    record.transactionCID
                )
            }
            transactions.append(DurableLocalTransaction(
                transactionCID: record.transactionCID,
                addedAt: record.addedAt,
                transaction: transaction
            ))
        }
        return transactions
    }

    func localTransactionTimestamps() async throws -> [String: Int64] {
        await acquireOperation()
        defer { releaseOperation() }
        return Dictionary(uniqueKeysWithValues:
            try await store.localMempoolTransactions().map {
                ($0.transactionCID, $0.addedAt)
            }
        )
    }

    public func canonicalTipBlock() async throws -> Block {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        let tip = await level.chain.getMainChainTip()
        let header = BlockHeader(rawCID: tip, node: nil, encryptionInfo: nil)
        guard let block = try await header.resolve(fetcher: localFetcher).node else {
            throw ChainProcessError.unresolvedCanonicalTip(tip)
        }
        return block
    }

    /// Classifies against one coherent Lattice tip while process mutations are
    /// fenced. The returned tip CID lets the service reject a result overtaken
    /// immediately after this operation releases its fence.
    public func preflightTransaction(
        _ transaction: Transaction,
        parentState: LatticeStateHeader? = nil,
        fetcher: (any Fetcher)? = nil
    ) async throws -> TransactionPreflightResult {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        return await level.preflightTransaction(
            transaction,
            parentState: parentState,
            fetcher: fetcher ?? localFetcher
        )
    }

    /// The configured parent is the sole live inherited-work authority. The
    /// caller authenticates the Ivy session; this method binds that identity
    /// to the durable genesis/configured authority before Core sees the facts.
    @discardableResult
    public func applyInheritedWorkSnapshot(
        _ snapshot: InheritedWorkSnapshot,
        from parentAuthorityKey: String
    ) async throws -> ChainCommit? {
        let update = try await applyInheritedWorkSnapshot(
            snapshot,
            from: parentAuthorityKey,
            canonicalCommitPublisher: nil
        )
        return update.commit
    }

    /// The publisher is invoked before releasing this process's mutation
    /// order. Otherwise a ready network admission can commit, publish, and
    /// overtake this inherited reorg in the service FIFO.
    func applyInheritedWorkSnapshot(
        _ snapshot: InheritedWorkSnapshot,
        from parentAuthorityKey: String,
        canonicalCommitPublisher: CanonicalCommitPublisher?
    ) async throws -> InheritedWorkUpdate {
        await acquireOperation()
        defer { releaseOperation() }
        guard !configuration.address.isNexus else {
            throw ChainProcessError.nexusHasNoInheritedWork
        }
        if case .active(let level) = runtimePhase {
            guard let projected = try await projectParentWork(
                snapshot,
                onto: level
            ), await level.chain.acceptsInheritedWork(projected) else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
        }
        guard let changes = try await store.mergeInheritedWorkSnapshot(
            snapshot,
            from: parentAuthorityKey
        ) else {
            return InheritedWorkUpdate(
                commit: nil,
                canonicalCommitReceipt: nil
            )
        }
        guard case .active(let level) = runtimePhase else {
            return InheritedWorkUpdate(
                commit: nil,
                canonicalCommitReceipt: nil
            )
        }
        guard let projected = try await projectParentWork(changes, onto: level)
        else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        let commit = await level.chain.mergeInheritedWork(projected)
        let receipt: CanonicalCommitReceipt?
        if let commit, commit.canonicalChanged,
           let canonicalCommitPublisher {
            receipt = await canonicalCommitPublisher(commit)
        } else {
            receipt = nil
        }
        return InheritedWorkUpdate(
            commit: commit,
            canonicalCommitReceipt: receipt
        )
    }

    /// Every direct child receives the same parent-owned securing-work view.
    /// Child-specific projection belongs exclusively to the receiving child.
    public func parentSecuringWorkSnapshot(
        since revision: UInt64? = nil
    ) async -> InheritedWorkSnapshot? {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.parentSecuringWorkSnapshot(since: revision)
    }

    /// The parent publishes generic locations; only this child joins them to
    /// child blocks through its durable incoming direct edges.
    private func projectParentWork(
        _ parent: InheritedWorkSnapshot,
        onto level: ChainLevel
    ) async throws -> InheritedWorkSnapshot? {
        let parentBlocks = Set(parent.blockCIDs)
        let bindings = if parentBlocks.count <= 256 {
            try await store.incomingParentCarrierBlocksByChildBlock(
                matching: parentBlocks
            )
        } else {
            try await store.incomingParentCarrierBlocksByChildBlock()
        }
        return await level.chain.inheritedWorkSnapshot(
            from: parent,
            parentCarrierBlocksByChildBlock: bindings
        )
    }

    /// Validate the exact relation that will become durable before either a
    /// new child block or a late incoming edge commits. The block need not be
    /// connected yet: Core's unique-grind check is location-based.
    private func prospectiveInheritedWork(
        forChildBlockCID childBlockCID: String,
        adding carrierEvidence: AdmissionCarrierEvidence?
    ) async throws -> InheritedWorkSnapshot? {
        var addedParentCarrierCID: String?
        var addedEdgeCID: String?
        if let carrierEvidence {
            guard let edge = await DirectChildEdge.derive(
                from: carrierEvidence.proof
            ), edge.childCID == childBlockCID,
               let edgeCID = edge.edgeCID else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            addedParentCarrierCID = edge.parentCarrierCID
            addedEdgeCID = edgeCID
        }
        let childAccepted = try await store.hasAcceptedBlock(childBlockCID)
        if childAccepted,
           let addedEdgeCID,
           try await store.hasIncomingCarrierEdge(addedEdgeCID) {
            return nil
        }
        var parentCarrierCIDs = if addedParentCarrierCID != nil,
                                   childAccepted {
            Set<String>()
        } else {
            try await store.incomingParentCarrierBlockCIDs(
                forChildBlockCID: childBlockCID
            )
        }
        if let addedParentCarrierCID {
            parentCarrierCIDs.insert(addedParentCarrierCID)
        }
        guard !parentCarrierCIDs.isEmpty,
              let parent = try await store.inheritedWorkSnapshot(
                matchingParentBlockCIDs: parentCarrierCIDs
              ) else {
            return nil
        }
        var projected: [InheritedWorkFact] = []
        for parentBlockCID in parent.blockCIDs {
            let measure = parent.sourceWork(forBlock: parentBlockCID)
            for grindID in measure.grindIDs {
                guard let work = measure.work(forGrind: grindID),
                      let fact = InheritedWorkFact(
                        blockCID: childBlockCID,
                        grindID: grindID,
                        work: work
                      ) else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                projected.append(fact)
            }
        }
        return InheritedWorkSnapshot(
            revision: parent.revision,
            facts: projected
        )
    }

    public func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String
    ) async throws -> ParentCarrierLink? {
        try await store.issuedParentCarrierLink(
            carrierCID: carrierCID,
            rootCID: rootCID
        )
    }

    /// Pages authenticated root contexts for one local carrier. Nexus is its
    /// own root; every child reuses its durable incoming-proof index.
    func parentCarrierRootPage(
        carrierCID: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        guard limit > 0 else { return [] }
        if configuration.address.isNexus {
            guard afterRootCID == nil,
                  try await store.issuedParentCarrierLink(
                    carrierCID: carrierCID,
                    rootCID: carrierCID
                  ) != nil else {
                return []
            }
            return [carrierCID]
        }
        return try await store.incomingCarrierProofRoots(
            childCID: carrierCID,
            directory: configuration.address.directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    public func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String
    ) async throws -> ParentGenesisLink? {
        try await store.issuedParentGenesisLink(
            directory: directory,
            childGenesisCID: childGenesisCID
        )
    }

    public func hasIssuedChildDirectory(_ directory: String) async throws -> Bool {
        try await store.hasIssuedChildDirectory(directory)
    }

    func prepareChildProofs(
        for candidate: Block,
        children selectedChildren: [DirectChildCandidate] = [],
        capacity: Int
    ) async throws -> [PreparedChildProof] {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        guard let children = candidate.children.node else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        let rootHeader = try BlockHeader(node: candidate)
        let selected = Dictionary(
            selectedChildren.map { ($0.directory, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var prepared: [PreparedChildProof] = []
        for (directory, childHeader) in try children.allKeysAndValues().sorted(by: {
            $0.key < $1.key
        }) {
            guard let child = childHeader.node else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            let childCID = try BlockHeader(node: child).rawCID
            let acquisitionEntries: [String: Data]
            if let supplied = selected[directory] {
                guard try BlockHeader(node: supplied.block).rawCID == childCID else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                acquisitionEntries = try await Self.collectCandidateEntries(
                    for: child,
                    fetcher: CoalescingFetcher(OverlayContentSource(
                        entries: supplied.acquisitionEntries,
                        fallback: localSource
                    )),
                    maximumBytes: ChildAcquisitionPackage.maximumBytes
                )
            } else {
                acquisitionEntries = try await Self.collectCandidateEntries(
                    for: child,
                    fetcher: localFetcher,
                    maximumBytes: ChildAcquisitionPackage.maximumBytes
                )
            }
            prepared.append(try PreparedChildProof(
                directory: directory,
                child: child,
                proof: try await ChildBlockProof.generate(
                    rootHeader: rootHeader,
                    childDirectory: directory,
                    fetcher: localFetcher
                ),
                acquisitionEntries: acquisitionEntries
            ))
        }
        guard selected.keys.allSatisfy({ directory in
            prepared.contains { $0.directory == directory }
        }) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        try Task.checkCancellation()
        try await store.persistPreparedChildProofs(
            carrierCID: rootHeader.rawCID,
            proofs: prepared,
            capacity: capacity
        )
        return prepared
    }

    /// Targeted retry for authenticated direct-child routes. This never walks
    /// or enumerates the complete children trie.
    func prepareChildProofs(
        for carrier: BlockHeader,
        directories: [String]
    ) async throws {
        var directories = try validatedDirectChildDirectories(directories)
        try await acquireMutationOperation()
        do {
            defer { releaseOperation() }
            try Task.checkCancellation()
            let available = Set(try await store.preparedChildProofs(
                carrierCID: carrier.rawCID
            ).map(\.directory)).union(try await store.retainedDirectChildProofs(
                carrierCID: carrier.rawCID
            ).map(\.directory))
            directories.removeAll { available.contains($0) }
            guard !directories.isEmpty else { return }
            try await store.persistPendingChildProofRoutes(
                carrierCID: carrier.rawCID,
                directories: directories,
                capacity: Self.preparedChildProofCapacity
            )
        }
        _ = try await acquirePendingChildProofs(
            carrier: carrier,
            directories: directories,
            fetcher: CoalescingFetcher(acquisitionSource)
        )
    }

    func pendingChildProofCarrierCIDs() async throws -> [String] {
        await acquireOperation()
        defer { releaseOperation() }
        return Array(Set(
            try await store.pendingChildProofRoutes().map(\.carrierCID)
        )).sorted()
    }

    /// Retries one bounded carrier batch retained across a crash after remote
    /// content is available again. Individual acquisition misses remain pending.
    func retryPendingChildProofs(carrierCID: String) async throws -> [String] {
        try await acquireMutationOperation()
        let directories: [String]
        do {
            defer { releaseOperation() }
            directories = try await store.pendingChildProofRoutes()
                .filter { $0.carrierCID == carrierCID }
                .map(\.directory)
                .sorted()
        }
        guard !directories.isEmpty else { return [] }
        return try await acquirePendingChildProofs(
            carrier: BlockHeader(
                rawCID: carrierCID,
                node: nil,
                encryptionInfo: nil
            ),
            directories: directories,
            fetcher: CoalescingFetcher(acquisitionSource)
        )
    }

    func durableDirectChildProofs(
        carrierCID: String,
        rootCID: String,
        directories: Set<String>? = nil
    ) async throws -> [DurableDirectChildProof] {
        var durable: [DurableDirectChildProof] = []
        let retained = try await store.retainedDirectChildProofs(
            carrierCID: carrierCID
        )
        for edge in retained
        where directories?.contains(edge.directory) ?? true {
            guard let evidence = try await store.issuedChildEvidence(
                childCID: edge.childCID,
                directory: edge.directory,
                rootCID: rootCID
            ) else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            durable.append(DurableDirectChildProof(
                directory: edge.directory,
                childCID: edge.childCID,
                childBlock: evidence.child,
                proof: evidence.proof,
                acquisitionEntries: evidence.acquisitionEntries
            ))
        }
        return durable
    }

    func issuedChildEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await store.issuedChildEvidence(
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func childRootAttachment(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> IssuedChildEvidence? {
        try await store.issuedChildEvidence(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
        )
    }

    func childRootAttachmentSummaries(
        scope: IssuedChildProofScope,
        directory: String,
        after: ChildRootAttachmentSummary?,
        limit: Int,
        portableOnly: Bool = false
    ) async throws -> [ChildRootAttachmentSummary] {
        try await store.childRootAttachmentSummaries(
            scope: scope,
            directory: directory,
            after: after,
            limit: limit,
            portableOnly: portableOnly
        )
    }

    func issuedChildProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await store.issuedChildProofRoots(
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    func issuedChildEvidenceSummaries(
        directory: String,
        after: IssuedChildEvidenceSummary?,
        limit: Int
    ) async throws -> [IssuedChildEvidenceSummary] {
        try await store.issuedChildEvidenceSummaries(
            directory: directory,
            after: after,
            limit: limit
        )
    }

    public func status() async -> ChainProcessStatus {
        await acquireOperation()
        defer { releaseOperation() }
        let parentWorkRevision = try? await store.inheritedWorkRevision()
        guard case .active(let level) = runtimePhase else {
            return ChainProcessStatus(
                phase: .awaitingGenesis,
                chainPath: configuration.chainPath,
                nexusGenesisCID: configuration.nexusGenesisCID,
                tipCID: nil,
                height: nil,
                revision: nil,
                parentWorkRevision: parentWorkRevision
            )
        }
        return ChainProcessStatus(
            phase: .active,
            chainPath: configuration.chainPath,
            nexusGenesisCID: configuration.nexusGenesisCID,
            tipCID: await level.chain.getMainChainTip(),
            height: await level.chain.getHighestBlockHeight(),
            revision: await level.chain.currentRevision(),
            parentWorkRevision: parentWorkRevision
        )
    }

    /// Recovery derives every still-unconnected same-chain edge from the
    /// durable accepted graph. The runtime uses these CID-only obligations to
    /// resume predecessor acquisition after a restart.
    func unresolvedSameChainPredecessors() async -> [SameChainPredecessorRequirement] {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else { return [] }
        return await level.chain.unresolvedSameChainPredecessors()
    }

    public func evictUnretainedVolumes() async throws -> Int {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await broker.evictUnpinned()
    }

    private func acquireOperation() async {
        _ = await acquireOperation(cancellable: false)
    }

    private func acquireMutationOperation() async throws {
        guard await acquireOperation(cancellable: true) else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            releaseOperation()
            throw CancellationError()
        }
    }

    private func acquireOperation(cancellable: Bool) async -> Bool {
        guard !cancellable || !Task.isCancelled else { return false }
        if !operationInFlight {
            operationInFlight = true
            if cancellable && Task.isCancelled {
                releaseOperation()
                return false
            }
            return true
        }

        let id = UUID()
        if !cancellable {
            return await withCheckedContinuation { continuation in
                operationWaiters.append(OperationWaiter(
                    id: id,
                    continuation: continuation
                ))
#if DEBUG
                operationWaitersChanged()
#endif
            }
        }

        let acquired = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                operationWaiters.append(OperationWaiter(
                    id: id,
                    continuation: continuation
                ))
#if DEBUG
                operationWaitersChanged()
#endif
                if Task.isCancelled {
                    cancelOperationWaiter(id)
                }
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelOperationWaiter(id)
            }
        })
        guard acquired, !Task.isCancelled else {
            if acquired {
                releaseOperation()
            }
            return false
        }
        return true
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        operationWaiters.remove(at: index).continuation.resume(returning: false)
#if DEBUG
        operationWaitersChanged()
#endif
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInFlight = false
            return
        }
        operationWaiters.removeFirst().continuation.resume(returning: true)
#if DEBUG
        operationWaitersChanged()
#endif
    }

#if DEBUG
    /// Internal deterministic test seam for cancellation of queued mutations.
    func waitForOperationWaiterCount(_ expectedCount: Int) async {
        while operationWaiters.count != expectedCount {
            await withCheckedContinuation { continuation in
                operationWaiterChangeWaiters.append(continuation)
            }
        }
    }

    private func operationWaitersChanged() {
        let waiters = operationWaiterChangeWaiters
        operationWaiterChangeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
#endif

    private func validatedDirectChildDirectories(
        _ directories: [String]
    ) throws -> [String] {
        let canonical = Array(Set(directories)).sorted()
        guard canonical.count <= Self.maximumDirectChildRoutes,
              canonical.allSatisfy({ directory in
                  !directory.isEmpty
                      && !directory.contains("/")
                      && directory.utf8.count <= Int(UInt16.max)
                      && ChainAddress(
                          configuration.chainPath + [directory]
                      ) != nil
              }) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        return canonical
    }

    private nonisolated static func pendingChildProofRoutes(
        carrierCID: String,
        directories: [String],
        parentGenesisLinks: [ParentGenesisLink] = []
    ) -> [PendingChildProofRoute] {
        Set(directories + parentGenesisLinks.map(\.directory))
            .sorted()
            .map {
                PendingChildProofRoute(
                    carrierCID: carrierCID,
                    directory: $0
                )
            }
    }

    /// A child genesis commits the one parent key allowed to influence its
    /// fork choice. Configuration selects the same live peer; accepting a
    /// mismatch would make the durable source differ from consensus authority.
    private func validateParentWorkAuthority(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher
    ) async throws {
        guard let configured = configuration.parentEndpoint?.publicKey,
              let authority = ParentWorkAuthorityKey(configured) else {
            throw ChainProcessError.parentWorkAuthorityMismatch
        }
        let child = try await Self.resolvedCandidate(
            blockHeader,
            fetcher: fetcher
        )
        guard child.parent == nil,
              let spec = try await child.spec.resolve(fetcher: fetcher).node,
              spec.parentWorkAuthorityKey == authority else {
            throw ChainProcessError.parentWorkAuthorityMismatch
        }
    }

    private nonisolated static func collectCandidateEntries(
        for block: Block,
        fetcher: any Fetcher,
        maximumBytes: Int
    ) async throws -> [String: Data] {
        guard maximumBytes > 0 else {
            throw ChainProcessError.acquisitionPackageTooLarge
        }
        let header = try BlockHeader(node: block)
        let collector = BoundedContentCollector(maximumBytes: maximumBytes)
        try await header.storeBlock(fetcher: fetcher, storer: collector)
        let entries = await collector.entries()
        guard let blockData = block.toData(),
              (try? ChildAcquisitionPackage(
                  entries: entries,
                  childCID: header.rawCID,
                  childData: blockData,
                  maximumBytes: maximumBytes
              )) != nil else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        return entries
    }

    /// Proof bytes authenticate the parent path; this package retains only the
    /// child graph Lattice actually resolves while validating the child.
    private nonisolated static func canonicalCarrierEvidence(
        _ header: BlockHeader,
        authenticatedPackage: AuthenticatedChildPackage?,
        fetcher: any Fetcher
    ) async throws -> AdmissionCarrierEvidence {
        guard let authenticatedPackage else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        let package = authenticatedPackage.package
        let child = try await resolvedCandidate(header, fetcher: fetcher)
        return AdmissionCarrierEvidence(
            proof: package.proof,
            child: child,
            acquisitionEntries: try await Self.collectCandidateEntries(
                for: child,
                fetcher: fetcher,
                maximumBytes: ChildAcquisitionPackage.maximumBytes
            ),
            parentCarrierLink: package.parentCarrierLink,
            parentGenesisLink: package.parentGenesisLink,
            parentCarrierCertificate:
                authenticatedPackage.parentCarrierCertificate,
            parentGenesisCertificate:
                authenticatedPackage.parentGenesisCertificate
        )
    }

    private func acquirePendingChildProofs(
        carrier: BlockHeader,
        directories: [String],
        fetcher: any Fetcher
    ) async throws -> [String] {
        guard !directories.isEmpty else { return [] }
        let preparedDirectories = Set(
            try await store.preparedChildProofs(carrierCID: carrier.rawCID)
                .map(\.directory)
        )
        let retainedDirectories = Set(
            try await store.retainedDirectChildProofs(carrierCID: carrier.rawCID)
                .map(\.directory)
        )
        let availableDirectories = preparedDirectories.union(retainedDirectories)
        var prepared: [PreparedChildProof] = []
        var completed: [String] = []
        for directory in directories where !availableDirectories.contains(directory) {
            switch await Self.resolveDirectChildProof(
                carrier: carrier,
                directory: directory,
                fetcher: fetcher
            ) {
            case .absent:
                completed.append(directory)
            case .prepared(let proof):
                prepared.append(proof)
                completed.append(directory)
            case .unavailable:
                break
            }
        }
        try Task.checkCancellation()
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let active = Set(try await store.pendingChildProofRoutes().lazy
            .filter { $0.carrierCID == carrier.rawCID }
            .map(\.directory))
            .intersection(directories)
        guard !active.isEmpty else { return [] }
        let durablePrepared = Set(
            try await store.preparedChildProofs(carrierCID: carrier.rawCID)
                .map(\.directory)
        ).union(try await store.retainedDirectChildProofs(
            carrierCID: carrier.rawCID
        ).map(\.directory))
        prepared = prepared.filter { active.contains($0.directory) }
        completed = Array(active.intersection(
            Set(completed).union(durablePrepared)
        )).sorted()
        try Task.checkCancellation()
        try await store.persistPreparedChildProofs(
            carrierCID: carrier.rawCID,
            proofs: prepared,
            capacity: Self.preparedChildProofCapacity
        )
        try Task.checkCancellation()
        try await Self.promotePreparedChildProofsFromDurableEvidence(
            store: store,
            configuration: configuration,
            carrierCID: carrier.rawCID
        )
        try Task.checkCancellation()
        try await store.removePendingChildProofRoutes(
            carrierCID: carrier.rawCID,
            directories: completed
        )
        return completed
    }

    private nonisolated static func resolveDirectChildProof(
        carrier: BlockHeader,
        directory: String,
        fetcher: any Fetcher
    ) async -> TargetedChildProofResolution {
        do {
            let path: [[String]: ResolutionStrategy] = [
                ["children", directory]: .targeted,
            ]
            let resolvedCarrier = try await carrier.resolve(
                paths: path,
                fetcher: fetcher
            )
            guard let block = resolvedCarrier.node,
                  let children = block.children.node else {
                return .unavailable
            }
            guard let childHeader = try children.get(key: directory) else {
                return .absent
            }
            guard let child = childHeader.node else {
                return .unavailable
            }
            let proof = try await ChildBlockProof.generate(
                rootHeader: resolvedCarrier,
                childDirectory: directory,
                fetcher: fetcher
            )
            let acquisitionEntries = try await Self.collectCandidateEntries(
                for: child,
                fetcher: fetcher,
                maximumBytes: ChildAcquisitionPackage.maximumBytes
            )
            return .prepared(try PreparedChildProof(
                directory: directory,
                child: child,
                proof: proof,
                acquisitionEntries: acquisitionEntries
            ))
        } catch {
            return .unavailable
        }
    }

    private func persistHierarchyArtifacts(
        _ link: ParentCarrierLink,
        carrierEvidence: AdmissionCarrierEvidence?,
        parentGenesisLinks: [ParentGenesisLink] = [],
        pendingChildProofRoutes: [PendingChildProofRoute]
    ) async throws {
        try Task.checkCancellation()
        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: link,
                carrierEvidence: carrierEvidence,
                parentGenesisLinks: parentGenesisLinks
            ),
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: Self.preparedChildProofCapacity
        )
        try await promotePreparedChildProofs(
            carrierCID: link.carrierCID,
            upstreamProof: carrierEvidence?.proof
        )
    }

    private func promotePreparedChildProofs(
        carrierCID: String,
        upstreamProof: ChildBlockProof?
    ) async throws {
        try await Self.promotePreparedChildProofs(
            store: store,
            configuration: configuration,
            carrierCID: carrierCID,
            upstreamProof: upstreamProof
        )
    }

    private nonisolated static func promotePreparedChildProofs(
        store: NodeStore,
        configuration: NodeConfiguration,
        carrierCID: String,
        upstreamProof: ChildBlockProof?,
        additional: [PreparedChildProof] = []
    ) async throws {
        let retained = try await store.retainedDirectChildProofs(
            carrierCID: carrierCID
        )
        let newlyPrepared = try await store.preparedChildProofs(
            carrierCID: carrierCID
        )
        var byDirectory = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.directory, $0) }
        )
        for prepared in newlyPrepared {
            if let existing = byDirectory[prepared.directory] {
                guard existing.childCID == prepared.childCID else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            } else {
                byDirectory[prepared.directory] = prepared
            }
        }
        for prepared in additional {
            if let existing = byDirectory[prepared.directory] {
                guard existing.childCID == prepared.childCID else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            } else {
                byDirectory[prepared.directory] = prepared
            }
        }
        for prepared in byDirectory.values.sorted(by: {
            $0.directory < $1.directory
        }) {
            if prepared.child.parent == nil,
               try await store.issuedParentGenesisLink(
                    directory: prepared.directory,
                    childGenesisCID: prepared.childCID
               ) == nil {
                continue
            }
            let proof: ChildBlockProof
            if configuration.address.isNexus {
                guard upstreamProof == nil else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                proof = prepared.proof
            } else {
                guard let upstreamProof else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                proof = upstreamProof.composing(hop: prepared.proof)
            }
            guard let carrierLink = try await store.issuedParentCarrierLink(
                carrierCID: carrierCID,
                rootCID: proof.rootCID
            ) else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            if try await store.issuedChildEvidence(
                childCID: prepared.childCID,
                directory: prepared.directory,
                rootCID: proof.rootCID
            ) != nil {
                try await store.removePreparedChildProof(
                    carrierCID: carrierCID,
                    directory: prepared.directory
                )
                continue
            }
            let genesisLink: ParentGenesisLink?
            if prepared.child.parent == nil {
                guard let link = try await store.issuedParentGenesisLink(
                    directory: prepared.directory,
                    childGenesisCID: prepared.childCID
                ) else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                genesisLink = link
            } else {
                genesisLink = nil
            }
            let rootEnvelope = try ChildValidationPackageEnvelope(
                ChildValidationPackage(
                    proof: proof,
                    parentCarrierLink: carrierLink,
                    parentGenesisLink: genesisLink
                ),
                certificatesSignedBy: configuration
            )
            guard let rootAuthorityKey = ParentWorkAuthorityKey(
                configuration.processPublicKey
            ) else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            try Task.checkCancellation()
            try await store.persistIssuedChildProof(
                proof,
                child: prepared.child,
                acquisitionEntries: prepared.acquisitionEntries,
                parentCarrierCID: carrierCID,
                rootEnvelope: rootEnvelope,
                rootAuthorityKey: rootAuthorityKey
            )
            // The permanent direct edge now contains everything needed to
            // compose future roots. The preparation row was only a crash bridge.
            try await store.removePreparedChildProof(
                carrierCID: carrierCID,
                directory: prepared.directory
            )
        }
    }

    private nonisolated static func recoverPreparedChildProofs(
        store: NodeStore,
        configuration: NodeConfiguration
    ) async throws {
        var carrierCIDs = Set(try await store.preparedChildProofCarrierCIDs())
        if !configuration.address.isNexus {
            carrierCIDs.formUnion(
                try await store.uncomposedDirectChildProofCarrierCIDs(
                    parentDirectory: configuration.address.directory
                )
            )
        }
        for carrierCID in carrierCIDs.sorted() {
            try await promotePreparedChildProofsFromDurableEvidence(
                store: store,
                configuration: configuration,
                carrierCID: carrierCID
            )
        }
    }

    private nonisolated static func promotePreparedChildProofsFromDurableEvidence(
        store: NodeStore,
        configuration: NodeConfiguration,
        carrierCID: String,
        additional: [PreparedChildProof] = []
    ) async throws {
        if configuration.address.isNexus {
            guard try await store.issuedParentCarrierLink(
                carrierCID: carrierCID,
                rootCID: carrierCID
            ) != nil else { return }
            try await promotePreparedChildProofs(
                store: store,
                configuration: configuration,
                carrierCID: carrierCID,
                upstreamProof: nil,
                additional: additional
            )
            return
        }

        var afterRootCID: String?
        while true {
            let roots = try await store.incomingCarrierProofRoots(
                childCID: carrierCID,
                directory: configuration.address.directory,
                afterRootCID: afterRootCID,
                limit: 257
            )
            for rootCID in roots {
                let evidence = try await store.incomingCarrierEvidence(
                    childCID: carrierCID,
                    directory: configuration.address.directory,
                    rootCID: rootCID
                )
                guard let upstream = evidence?.proof else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                try await promotePreparedChildProofs(
                    store: store,
                    configuration: configuration,
                    carrierCID: carrierCID,
                    upstreamProof: upstream,
                    additional: additional
                )
            }
            guard roots.count == 257, let last = roots.last else { break }
            afterRootCID = last
        }
    }

    /// Parent proof bytes are an attempt-local acquisition overlay. Cashew and
    /// Lattice content-bind every resolved CID; only verified admission paths
    /// copy useful sparse content into the durable NodeStore.
    nonisolated static func attemptContentSource(
        package: ChildValidationPackage?,
        acquisitionEntries: [String: Data] = [:],
        fallback: any ContentSource
    ) throws -> any ContentSource {
        guard let package else {
            guard acquisitionEntries.isEmpty else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            return fallback
        }
        var entries = acquisitionEntries
        for entry in package.proof.entries {
            if let existing = entries[entry.cid] {
                guard existing == entry.data else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            } else {
                entries[entry.cid] = entry.data
            }
        }
        return OverlayContentSource(
            entries: entries,
            fallback: fallback
        )
    }

    nonisolated static func attemptFetcher(
        package: ChildValidationPackage?,
        acquisitionEntries: [String: Data] = [:],
        fallback: any ContentSource
    ) throws -> CoalescingFetcher {
        CoalescingFetcher(try attemptContentSource(
            package: package,
            acquisitionEntries: acquisitionEntries,
            fallback: fallback
        ))
    }

    private nonisolated static func resolvedCandidate(
        _ header: BlockHeader,
        fetcher: any Fetcher
    ) async throws -> Block {
        guard let block = try await header.resolve(fetcher: fetcher).node else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        return block
    }

    nonisolated static func persist(
        _ batch: ChainAdmissionBatch,
        admissionStorage: NodeAdmissionStorage,
        store: NodeStore,
        broker: DiskBroker,
        retentionScope: String,
        pendingChildProofRoutes: [PendingChildProofRoute],
        pendingChildProofCapacity: Int,
        hierarchyArtifacts: AdmissionHierarchyArtifacts? = nil,
        incomingCarrierEvidence: AdmissionCarrierEvidence? = nil,
        afterRetainingRoots: (@Sendable () async -> Void)? = nil
    ) async throws {
        let roots = await admissionStorage.takeStoredVolumeRoots()
        // Retaining an orphan is harmless; staging a batch without durable
        // retention is not. Once retention succeeds, the batch must finish:
        // cancellation between these writes would pin its roots until restart.
        try Task.checkCancellation()
        try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
        if let afterRetainingRoots {
            await afterRetainingRoots()
        }
        // A failed stage may leave a retained orphan. That is deliberately
        // safer than a live exact rollback, which could unretain another
        // writer between its retention and reference commits. Startup removes
        // any such orphan while the process is quiescent.
        try await store.stage(
            batch,
            volumeRoots: roots,
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: pendingChildProofCapacity,
            hierarchyArtifacts: hierarchyArtifacts,
            incomingCarrierEvidence: incomingCarrierEvidence
        )
    }

    private nonisolated static func durableRetainedRoots(
        staged: [StagedAdmission],
        store: NodeStore,
        additionalRoots: [String] = []
    ) async throws -> [String] {
        var roots = Set(staged.flatMap(\.volumeRoots))
        roots.formUnion(try await store.recoveryAttachmentCIDs())
        roots.formUnion(additionalRoots)
        return roots.sorted()
    }
}
