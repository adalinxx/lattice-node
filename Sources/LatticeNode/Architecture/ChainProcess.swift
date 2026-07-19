import Foundation
import Lattice
import VolumeBroker
import cashew

public enum ChainProcessError: Error, Equatable, Sendable {
    case invalidStoragePath
    case invalidNexusGenesis
    case missingMaterializedVolume(String)
    case nexusHasNoInheritedWork
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
}

/// The result must be routed immediately when `parentCarrierLink` is present;
/// the link is authenticated evidence, not local consensus state.
public struct NodeAdmissionOutcome: Sendable {
    public let decision: NodeAdmissionDecision
    public let parentCarrierLink: ParentCarrierLink?
    public let sameChainPredecessor: SameChainPredecessorRequirement?
}

struct DurableDirectChildProof: Sendable {
    let directory: String
    let childCID: String
    let childBlock: Block
    let proof: ChildBlockProof
    let acquisitionEntries: [String: Data]
}

private final class InheritedWorkCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InheritedWorkSnapshot

    init(_ value: InheritedWorkSnapshot) {
        self.value = value
    }

    func snapshot() -> InheritedWorkSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(with value: InheritedWorkSnapshot) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor BoundedContentCollector: Storer {
    private let maximumBytes: Int
    private var byteCount = 0
    private var values: [String: Data] = [:]

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func store(entries: [String: Data]) throws {
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

/// One process owns one absolute chain path. Child processes have an explicit
/// pre-genesis phase so target-miss carriers can relay deeper accepted work
/// without inventing local chain state.
public actor ChainProcess: Fetcher, Storer {
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
    private let fetcher: CoalescingFetcher
    private let retentionScope: String
    private let inheritedWork: InheritedWorkCache
    private var runtimePhase: RuntimePhase

    // Actors are reentrant. This queue keeps admission, inherited-work updates,
    // and eviction in one durability order across their suspension points.
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    private init(
        configuration: NodeConfiguration,
        store: NodeStore,
        broker: DiskBroker,
        brokerStorer: BrokerStorer,
        fetcher: CoalescingFetcher,
        retentionScope: String,
        inheritedWork: InheritedWorkCache,
        runtimePhase: RuntimePhase
    ) {
        self.configuration = configuration
        self.store = store
        self.broker = broker
        self.brokerStorer = brokerStorer
        self.fetcher = fetcher
        self.retentionScope = retentionScope
        self.inheritedWork = inheritedWork
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

        let store = try NodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWork: configuration.minimumRootWork
        )
        let broker = try DiskBroker(
            path: configuration.storagePath.appendingPathComponent("volumes.db").path
        )
        let brokerStorer = BrokerStorer(broker: broker)
        let brokerFetcher = BrokerFetcher(broker: broker)
        var sources: [any ContentSource] = [store, brokerFetcher]
        if let remoteSource { sources.append(remoteSource) }
        let fetcher = CoalescingFetcher(CompositeContentSource(sources))
        let retentionScope = [
            configuration.nexusGenesisCID,
            configuration.address.key,
        ].joined(separator: ":")

        let staged = try await store.stagedAdmissions()
        try await store.auditNormalizedIndexes()
        let retainedRoots = Array(Set(staged.flatMap(\.volumeRoots))).sorted()
        for root in retainedRoots where !(await broker.hasVolume(root: root)) {
            throw ChainProcessError.missingMaterializedVolume(root)
        }
        try await broker.advanceRetainedRoots(
            scope: retentionScope,
            roots: retainedRoots
        )

        let inheritedSnapshot = try await store.inheritedWorkSnapshot() ?? .zero
        let inheritedWork = InheritedWorkCache(inheritedSnapshot)
        let provider: InheritedWorkProvider?
        if configuration.address.isNexus {
            provider = nil
        } else {
            provider = { @Sendable in inheritedWork.snapshot() }
        }
        let context = try configuration.runtimeContext
        let runtimePhase: RuntimePhase
        // The empty state is a protocol constant, not parent-supplied content.
        // Every path can materialize it before a child genesis is available.
        try await LatticeState.emptyHeader.storeRecursively(storer: store)

        if staged.isEmpty {
            if configuration.address.isNexus {
                let genesis = try await NexusGenesis.create(fetcher: fetcher)
                guard genesis.blockHash == NexusGenesis.expectedBlockHash else {
                    throw ChainProcessError.invalidNexusGenesis
                }
                let admissionStorage = NodeAdmissionStorage(
                    validationContent: store,
                    materializedVolumes: brokerStorer
                )
                let bootstrapped = try await ChainLevel.bootstrap(
                    context: context,
                    genesisHeader: try BlockHeader(node: genesis.block),
                    expectedUnsignedGenesisCID: NexusGenesis.expectedBlockHash,
                    fetcher: fetcher,
                    validationContentStorer: admissionStorage,
                    materializedVolumeStorer: admissionStorage,
                    stage: { batch in
                        try await persist(
                            batch,
                            coverage: [],
                            admissionStorage: admissionStorage,
                            store: store,
                            broker: broker,
                            retentionScope: retentionScope,
                            pendingChildProofRoutes: [],
                            pendingChildProofCapacity: Self.preparedChildProofCapacity
                        )
                    }
                )
                try await store.saveCanonicalProjection(
                    await bootstrapped.level.chain.persist()
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
            let projection = try await store.canonicalProjection()
            let chain: ChainState
            if let projection {
                chain = try await ChainState.restore(
                    from: projection,
                    replaying: batches,
                    inheritedWorkProvider: provider
                )
            } else {
                chain = try await ChainState.restore(
                    replaying: batches,
                    inheritedWorkProvider: provider
                )
            }
            let level = ChainLevel(chain: chain, context: context)
            try await store.saveCanonicalProjection(await chain.persist())
            runtimePhase = .active(level)
        }

        try await recoverPreparedChildProofs(
            store: store,
            address: configuration.address,
            issuerKey: configuration.processPublicKey
        )

        return ChainProcess(
            configuration: configuration,
            store: store,
            broker: broker,
            brokerStorer: brokerStorer,
            fetcher: fetcher,
            retentionScope: retentionScope,
            inheritedWork: inheritedWork,
            runtimePhase: runtimePhase
        )
    }

    public func admit(
        _ blockHeader: BlockHeader,
        authenticatedChildPackage: AuthenticatedChildPackage? = nil,
        preparingChildDirectories: [String] = []
    ) async throws -> NodeAdmissionOutcome {
        await acquireOperation()
        defer { releaseOperation() }

        let directChildDirectories = try validatedDirectChildDirectories(
            preparingChildDirectories
        )
        let pendingChildProofRoutes = directChildDirectories.map {
            PendingChildProofRoute(
                carrierCID: blockHeader.rawCID,
                directory: $0
            )
        }

        let package = authenticatedChildPackage?.package
        let acquisitionEntries = authenticatedChildPackage?.acquisitionEntries ?? [:]
        let attemptFetcher = try Self.attemptFetcher(
            package: package,
            acquisitionEntries: acquisitionEntries,
            fallback: fetcher
        )
        let coverage = package?.parentCarrierLink.map {
            [ParentCoverageBinding(
                childBlockCID: blockHeader.rawCID,
                parentCarrierCID: $0.carrierCID
            )]
        } ?? []
        let admissionStorage = NodeAdmissionStorage(
            validationContent: store,
            materializedVolumes: brokerStorer
        )
        let stage: @Sendable (ChainAdmissionBatch) async throws -> Void = { batch in
            try await Self.persist(
                batch,
                coverage: coverage,
                admissionStorage: admissionStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                pendingChildProofRoutes: pendingChildProofRoutes,
                pendingChildProofCapacity: Self.preparedChildProofCapacity
            )
        }

        switch runtimePhase {
        case .awaitingGenesis:
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
            let result = try await ChainLevel.bootstrap(
                context: configuration.runtimeContext,
                genesisHeader: blockHeader,
                fetcher: attemptFetcher,
                childPackage: package,
                validationContentStorer: admissionStorage,
                materializedVolumeStorer: admissionStorage,
                stage: stage
            )
            switch result {
            case .carrier(let link):
                try await persistCarrierEvidence(
                    link,
                    proof: package.proof,
                    child: try await Self.resolvedCandidate(
                        blockHeader,
                        fetcher: attemptFetcher
                    ),
                    acquisitionEntries: acquisitionEntries,
                    pendingChildProofRoutes: pendingChildProofRoutes
                )
                _ = try? await acquirePendingChildProofs(
                    carrier: blockHeader,
                    directories: directChildDirectories,
                    fetcher: attemptFetcher
                )
                return NodeAdmissionOutcome(
                    decision: .carrier,
                    parentCarrierLink: link,
                    sameChainPredecessor: nil
                )
            case .rejected(let failure, let link):
                try await persistCarrierEvidence(
                    link,
                    proof: package.proof,
                    child: try await Self.resolvedCandidate(
                        blockHeader,
                        fetcher: attemptFetcher
                    ),
                    acquisitionEntries: acquisitionEntries,
                    pendingChildProofRoutes: pendingChildProofRoutes
                )
                _ = try? await acquirePendingChildProofs(
                    carrier: blockHeader,
                    directories: directChildDirectories,
                    fetcher: attemptFetcher
                )
                return NodeAdmissionOutcome(
                    decision: NodeAdmissionDecision(failure),
                    parentCarrierLink: link,
                    sameChainPredecessor: nil
                )
            case .accepted(let acceptance):
                let projection = await acceptance.level.chain.persist()
                // The exact admission batch is already durable. Projection and
                // hierarchy-proof promotion are recoverable post-commit work;
                // neither may turn an accepted block into a reported failure.
                runtimePhase = .active(acceptance.level)
                _ = try? await store.saveCanonicalProjection(projection)
                _ = try? await persistCarrierEvidence(
                    acceptance.parentCarrierLink,
                    proof: package.proof,
                    child: try await Self.resolvedCandidate(
                        blockHeader,
                        fetcher: attemptFetcher
                    ),
                    acquisitionEntries: acquisitionEntries,
                    pendingChildProofRoutes: pendingChildProofRoutes
                )
                _ = try? await acquirePendingChildProofs(
                    carrier: blockHeader,
                    directories: directChildDirectories,
                    fetcher: attemptFetcher
                )
                return NodeAdmissionOutcome(
                    decision: .canonicalized(ChainCommit(
                        revision: projection.revision,
                        tipHash: projection.chainTip,
                        mainChainBlocksAdded: [projection.chainTip: 0]
                    )),
                    parentCarrierLink: acceptance.parentCarrierLink,
                    sameChainPredecessor: nil
                )
            }

        case .active(let level):
            let result = try await level.admitBlockHeaderChainLocal(
                blockHeader,
                fetcher: attemptFetcher,
                childPackage: package,
                validationContentStorer: admissionStorage,
                materializedVolumeStorer: admissionStorage,
                stage: stage
            )
            let admissionCommitted = result.commit != nil
            if admissionCommitted {
                _ = try? await store.saveCanonicalProjection(
                    await level.chain.persist()
                )
            }
            if let link = result.parentCarrierLink {
                if let package {
                    if admissionCommitted {
                        if let child = try? await Self.resolvedCandidate(
                            blockHeader,
                            fetcher: attemptFetcher
                        ) {
                            _ = try? await persistCarrierEvidence(
                                link,
                                proof: package.proof,
                                child: child,
                                acquisitionEntries: acquisitionEntries,
                                pendingChildProofRoutes: pendingChildProofRoutes
                            )
                        }
                    } else {
                        let child = try await Self.resolvedCandidate(
                            blockHeader,
                            fetcher: attemptFetcher
                        )
                        try await persistCarrierEvidence(
                            link,
                            proof: package.proof,
                            child: child,
                            acquisitionEntries: acquisitionEntries,
                            pendingChildProofRoutes: pendingChildProofRoutes
                        )
                    }
                } else {
                    if admissionCommitted {
                        _ = try? await persistNexusCarrierEvidence(
                            link,
                            carrierCID: blockHeader.rawCID,
                            pendingChildProofRoutes: pendingChildProofRoutes
                        )
                    } else {
                        try await persistNexusCarrierEvidence(
                            link,
                            carrierCID: blockHeader.rawCID,
                            pendingChildProofRoutes: pendingChildProofRoutes
                        )
                    }
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
                sameChainPredecessor: result.sameChainPredecessor
            )
        }
    }

    /// Persist first, then update the synchronous provider observed by Lattice.
    @discardableResult
    public func applyInheritedWorkSnapshot(
        _ snapshot: InheritedWorkSnapshot
    ) async throws -> ChainCommit? {
        await acquireOperation()
        defer { releaseOperation() }
        guard !configuration.address.isNexus else {
            throw ChainProcessError.nexusHasNoInheritedWork
        }
        try await store.persistInheritedWorkSnapshot(snapshot)
        let merged = try await store.inheritedWorkSnapshot() ?? .zero
        inheritedWork.replace(with: merged)
        guard case .active(let level) = runtimePhase else { return nil }
        let commit = await level.chain.reevaluateForkChoice()
        if commit != nil {
            try await store.saveCanonicalProjection(await level.chain.persist())
        }
        return commit
    }

    public func parentCoverage() async throws -> [String: Set<String>] {
        try await store.parentCoverage()
    }

    /// Same-chain content serving reads only this process's durable local tiers.
    public func content(_ cids: Set<String>) async -> [String: Data] {
        var entries = await store.fetch(cids)
        for cid in cids where entries[cid] == nil {
            if let data = await broker.fetchDataLocal(cid: cid) {
                entries[cid] = data
            }
        }
        return entries
    }

    /// Collects exactly the durable inputs Lattice will read while validating
    /// this block: block content, policy modules, and targeted state paths. It
    /// never traverses children or ancestors.
    func durableAdmissionEntries(
        for block: Block,
        maximumBytes: Int
    ) async throws -> [String: Data] {
        await acquireOperation()
        defer { releaseOperation() }
        guard maximumBytes > 0 else {
            throw ChainProcessError.acquisitionPackageTooLarge
        }
        let localFetcher = CoalescingFetcher(CompositeContentSource([
            store,
            BrokerFetcher(broker: broker),
        ]))
        let header = try BlockHeader(node: block)
        let collector = BoundedContentCollector(maximumBytes: maximumBytes)
        try await header.storeBlock(fetcher: localFetcher, storer: collector)
        let entries = await collector.entries()
        guard entries[header.rawCID] == block.toData() else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        return entries
    }

    /// Candidate availability contains only this chain's exact validation
    /// inputs. Descendant packages remain owned by their immediate parent.
    func durableCandidateEntries(
        for block: Block,
        maximumBytes: Int = ChildAcquisitionPackage.maximumBytes
    ) async throws -> [String: Data] {
        await acquireOperation()
        defer { releaseOperation() }
        return try await collectCandidateEntries(
            for: block,
            fetcher: CoalescingFetcher(CompositeContentSource([
                store,
                BrokerFetcher(broker: broker),
            ])),
            maximumBytes: maximumBytes
        )
    }

    public func fetch(rawCid: String) async throws -> Data {
        try await fetcher.fetch(rawCid: rawCid)
    }

    public func store(entries: [String: Data]) async throws {
        try await store.store(entries: entries)
    }

    public func canonicalTipBlock() async throws -> Block {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        let tip = await level.chain.getMainChainTip()
        let header = BlockHeader(rawCID: tip, node: nil, encryptionInfo: nil)
        guard let block = try await header.resolve(fetcher: fetcher).node else {
            throw ChainProcessError.unresolvedCanonicalTip(tip)
        }
        return block
    }

    public func inheritedWorkSnapshot(
        forChildCoverage coverage: [String: Set<String>]
    ) async throws -> InheritedWorkSnapshot? {
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        return await level.chain.inheritedWorkSnapshot(
            forChildCoverage: coverage
        )
    }

    public func genesisLink(
        parentBlockHeader: BlockHeader,
        directory: String,
        childGenesisCID: String
    ) async throws -> Result<ParentGenesisLink, ChainAdmissionFailure> {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        let result = await level.genesisLink(
            parentBlockHeader: parentBlockHeader,
            directory: directory,
            childGenesisCID: childGenesisCID,
            fetcher: fetcher
        )
        if case .success(let link) = result {
            try await store.persistIssuedParentGenesisLink(
                link,
                issuerKey: configuration.processPublicKey
            )
        }
        return result
    }

    public func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String
    ) async throws -> ParentCarrierLink? {
        try await store.issuedParentCarrierLink(
            carrierCID: carrierCID,
            rootCID: rootCID,
            issuerKey: configuration.processPublicKey
        )
    }

    public func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String
    ) async throws -> ParentGenesisLink? {
        try await store.issuedParentGenesisLink(
            directory: directory,
            childGenesisCID: childGenesisCID,
            issuerKey: configuration.processPublicKey
        )
    }

    public func hasIssuedChildDirectory(_ directory: String) async throws -> Bool {
        try await store.hasIssuedChildDirectory(
            directory,
            issuerKey: configuration.processPublicKey
        )
    }

    func prepareChildProofs(
        for candidate: Block,
        children selectedChildren: [DirectChildCandidate] = [],
        capacity: Int
    ) async throws -> [PreparedChildProof] {
        await acquireOperation()
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
                acquisitionEntries = supplied.acquisitionEntries
            } else {
                acquisitionEntries = try await collectCandidateEntries(
                    for: child,
                    fetcher: self,
                    maximumBytes: ChildAcquisitionPackage.maximumBytes
                )
            }
            prepared.append(try PreparedChildProof(
                directory: directory,
                child: child,
                proof: try await ChildBlockProof.generate(
                    rootHeader: rootHeader,
                    childDirectory: directory,
                    fetcher: self
                ),
                acquisitionEntries: acquisitionEntries
            ))
        }
        guard selected.keys.allSatisfy({ directory in
            prepared.contains { $0.directory == directory }
        }) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
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
        await acquireOperation()
        defer { releaseOperation() }
        let directories = try validatedDirectChildDirectories(directories)
        try await store.persistPendingChildProofRoutes(
            carrierCID: carrier.rawCID,
            directories: directories,
            capacity: Self.preparedChildProofCapacity
        )
        try await acquirePendingChildProofs(
            carrier: carrier,
            directories: directories,
            fetcher: fetcher
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
    func retryPendingChildProofs(carrierCID: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        let directories = try await store.pendingChildProofRoutes()
            .filter { $0.carrierCID == carrierCID }
            .map(\.directory)
        guard !directories.isEmpty else { return }
        try await acquirePendingChildProofs(
            carrier: BlockHeader(
                rawCID: carrierCID,
                node: nil,
                encryptionInfo: nil
            ),
            directories: directories,
            fetcher: fetcher
        )
    }

    func durableDirectChildProofs(
        carrierCID: String,
        rootCID: String
    ) async throws -> [DurableDirectChildProof] {
        var durable: [DurableDirectChildProof] = []
        for prepared in try await store.preparedChildProofs(carrierCID: carrierCID) {
            guard let evidence = try await store.issuedChildEvidence(
                childCID: prepared.childCID,
                rootCID: rootCID
            ) else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            durable.append(DurableDirectChildProof(
                directory: prepared.directory,
                childCID: prepared.childCID,
                childBlock: evidence.child,
                proof: evidence.proof,
                acquisitionEntries: evidence.acquisitionEntries
            ))
        }
        return durable
    }

    func issuedChildProof(
        childCID: String,
        rootCID: String? = nil
    ) async throws -> ChildBlockProof? {
        try await store.issuedChildProof(
            childCID: childCID,
            rootCID: rootCID
        )
    }

    func issuedChildEvidence(
        childCID: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await store.issuedChildEvidence(
            childCID: childCID,
            rootCID: rootCID
        )
    }

    func issuedChildProofRoots(
        childCID: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await store.issuedChildProofRoots(
            childCID: childCID,
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
            issuerKey: configuration.processPublicKey,
            after: after,
            limit: limit
        )
    }

    public func status() async -> ChainProcessStatus {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            return ChainProcessStatus(
                phase: .awaitingGenesis,
                chainPath: configuration.chainPath,
                nexusGenesisCID: configuration.nexusGenesisCID,
                tipCID: nil,
                height: nil
            )
        }
        return ChainProcessStatus(
            phase: .active,
            chainPath: configuration.chainPath,
            nexusGenesisCID: configuration.nexusGenesisCID,
            tipCID: await level.chain.getMainChainTip(),
            height: await level.chain.getHighestBlockHeight()
        )
    }

    public func evictUnretainedVolumes() async throws -> Int {
        await acquireOperation()
        defer { releaseOperation() }
        return try await broker.evictUnpinned()
    }

    private func acquireOperation() async {
        if !operationInFlight {
            operationInFlight = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInFlight = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

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

    private func collectCandidateEntries(
        for block: Block,
        fetcher: any Fetcher,
        maximumBytes: Int
    ) async throws -> [String: Data] {
        try await Self.collectCandidateEntries(
            for: block,
            fetcher: fetcher,
            maximumBytes: maximumBytes
        )
    }

    private func acquirePendingChildProofs(
        carrier: BlockHeader,
        directories: [String],
        fetcher: any Fetcher
    ) async throws {
        guard !directories.isEmpty else { return }
        var prepared: [PreparedChildProof] = []
        var completed: [String] = []
        for directory in directories {
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
        try await store.persistPreparedChildProofs(
            carrierCID: carrier.rawCID,
            proofs: prepared,
            capacity: Self.preparedChildProofCapacity
        )
        try await store.removePendingChildProofRoutes(
            carrierCID: carrier.rawCID,
            directories: completed
        )
        try await Self.promotePreparedChildProofsFromDurableEvidence(
            store: store,
            address: configuration.address,
            carrierCID: carrier.rawCID,
            issuerKey: configuration.processPublicKey
        )
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
            let acquisitionEntries = try await collectCandidateEntries(
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

    private func persistCarrierEvidence(
        _ link: ParentCarrierLink,
        proof: ChildBlockProof,
        child: Block,
        acquisitionEntries: [String: Data],
        pendingChildProofRoutes: [PendingChildProofRoute]
    ) async throws {
        try await store.persistIssuedCarrierEvidence(
            link: link,
            proof: proof,
            child: child,
            acquisitionEntries: acquisitionEntries,
            issuerKey: configuration.processPublicKey,
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: Self.preparedChildProofCapacity
        )
        try await promotePreparedChildProofs(
            carrierCID: try BlockHeader(node: child).rawCID,
            upstreamProof: proof
        )
    }

    private func persistNexusCarrierEvidence(
        _ link: ParentCarrierLink,
        carrierCID: String,
        pendingChildProofRoutes: [PendingChildProofRoute]
    ) async throws {
        try await store.persistIssuedParentCarrierLink(
            link,
            issuerKey: configuration.processPublicKey,
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: Self.preparedChildProofCapacity
        )
        try await promotePreparedChildProofs(
            carrierCID: carrierCID,
            upstreamProof: nil
        )
    }

    private func promotePreparedChildProofs(
        carrierCID: String,
        upstreamProof: ChildBlockProof?
    ) async throws {
        try await Self.promotePreparedChildProofs(
            store: store,
            address: configuration.address,
            carrierCID: carrierCID,
            upstreamProof: upstreamProof
        )
    }

    private nonisolated static func promotePreparedChildProofs(
        store: NodeStore,
        address: ChainAddress,
        carrierCID: String,
        upstreamProof: ChildBlockProof?
    ) async throws {
        for prepared in try await store.preparedChildProofs(carrierCID: carrierCID) {
            let proof: ChildBlockProof
            if address.isNexus {
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
            try await store.persistIssuedChildProof(
                proof,
                child: prepared.child,
                acquisitionEntries: prepared.acquisitionEntries
            )
        }
    }

    private nonisolated static func recoverPreparedChildProofs(
        store: NodeStore,
        address: ChainAddress,
        issuerKey: String
    ) async throws {
        for carrierCID in try await store.preparedChildProofCarrierCIDs() {
            try await promotePreparedChildProofsFromDurableEvidence(
                store: store,
                address: address,
                carrierCID: carrierCID,
                issuerKey: issuerKey
            )
        }
    }

    private nonisolated static func promotePreparedChildProofsFromDurableEvidence(
        store: NodeStore,
        address: ChainAddress,
        carrierCID: String,
        issuerKey: String
    ) async throws {
        if address.isNexus {
            guard try await store.issuedParentCarrierLink(
                carrierCID: carrierCID,
                rootCID: carrierCID,
                issuerKey: issuerKey
            ) != nil else { return }
            try await promotePreparedChildProofs(
                store: store,
                address: address,
                carrierCID: carrierCID,
                upstreamProof: nil
            )
            return
        }

        var afterRootCID: String?
        while true {
            let roots = try await store.issuedChildProofRoots(
                childCID: carrierCID,
                afterRootCID: afterRootCID,
                limit: 257
            )
            for rootCID in roots {
                guard let upstream = try await store.issuedChildProof(
                    childCID: carrierCID,
                    rootCID: rootCID
                ) else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                try await promotePreparedChildProofs(
                    store: store,
                    address: address,
                    carrierCID: carrierCID,
                    upstreamProof: upstream
                )
            }
            guard roots.count == 257, let last = roots.last else { break }
            afterRootCID = last
        }
    }

    /// Parent proof bytes are an attempt-local acquisition overlay. Cashew and
    /// Lattice content-bind every resolved CID; only verified admission paths
    /// copy useful sparse content into the durable NodeStore.
    private nonisolated static func attemptFetcher(
        package: ChildValidationPackage?,
        acquisitionEntries: [String: Data] = [:],
        fallback: any Fetcher
    ) throws -> any Fetcher {
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
        return CoalescingFetcher(OverlayContentSource(
            entries: entries,
            fallback: FetcherContentSource(fallback)
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

    private nonisolated static func persist(
        _ batch: ChainAdmissionBatch,
        coverage: [ParentCoverageBinding],
        admissionStorage: NodeAdmissionStorage,
        store: NodeStore,
        broker: DiskBroker,
        retentionScope: String,
        pendingChildProofRoutes: [PendingChildProofRoute],
        pendingChildProofCapacity: Int
    ) async throws {
        let roots = await admissionStorage.takeStoredVolumeRoots()
        // Retaining an orphan is harmless; staging a batch without durable
        // retention is not. Recovery's exact advance clears any orphan roots.
        try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
        try await store.stage(
            batch,
            volumeRoots: roots,
            parentCoverage: coverage,
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: pendingChildProofCapacity
        )
    }
}
