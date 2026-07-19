import Foundation
import Lattice
import UInt256
import cashew

public struct SubmitTransactionRequest: Codable, Sendable {
    public let transaction: Transaction

    public init(transaction: Transaction) {
        self.transaction = transaction
    }

    private enum CodingKeys: String, CodingKey {
        case transaction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transaction = try container.decode(
            ContentBoundTransaction.self,
            forKey: .transaction
        ).transaction()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            ContentBoundTransaction(transaction: transaction),
            forKey: .transaction
        )
    }
}

public struct SubmitTransactionResponse: Codable, Sendable, Equatable {
    public let transactionCID: String
    public let mempoolCount: Int
    public let mempoolBytes: Int
}

/// One externally signed reward transaction for one absolute chain path.
/// Process identity is never accepted as, or converted into, wallet identity.
public struct MiningReward: Codable, Sendable {
    public let chainPath: [String]
    public let transaction: Transaction

    public init(chainPath: [String], transaction: Transaction) {
        self.chainPath = chainPath
        self.transaction = transaction
    }

    private enum CodingKeys: String, CodingKey {
        case chainPath
        case transaction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainPath = try container.decode([String].self, forKey: .chainPath)
        transaction = try container.decode(
            ContentBoundTransaction.self,
            forKey: .transaction
        ).transaction()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chainPath, forKey: .chainPath)
        try container.encode(
            ContentBoundTransaction(transaction: transaction),
            forKey: .transaction
        )
    }
}

public struct MiningTemplateRequest: Codable, Sendable {
    public let rewards: [MiningReward]

    public init(rewards: [MiningReward] = []) {
        self.rewards = rewards
    }
}

public struct MiningTemplateResponse: Codable, Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let chainPath: [String]
    public let expiresInMilliseconds: UInt64

    init(
        template: MiningTemplate,
        maximumLifetimeMilliseconds: UInt64
    ) {
        workID = template.workID
        block = template.block
        searchTarget = template.searchTarget
        chainPath = template.chainPath
        expiresInMilliseconds = min(
            maximumLifetimeMilliseconds,
            template.remainingLifetimeMilliseconds
        )
    }
}

public struct SubmitWorkRequest: Codable, Sendable, Equatable {
    public let workID: String
    public let nonce: UInt64

    public init(workID: String, nonce: UInt64) {
        self.workID = workID
        self.nonce = nonce
    }
}

public enum WorkDisposition: String, Codable, Sendable {
    case canonicalized
    case acceptedSide
    case carrier
    case duplicate
    case unavailable
    case temporarilyInvalid
    case invalid
    case localFailure
    case storageFailed
}

public struct SubmitWorkResponse: Codable, Sendable {
    public let accepted: Bool
    public let disposition: WorkDisposition
    public let tipCID: String?
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLinks: [ParentGenesisLink]
    public let publishedChildProofs: [DirectChildProofSummary]
}

/// Bounded miner-facing acknowledgement. Proof bytes stay on the authenticated
/// hierarchy plane.
public struct DirectChildProofSummary: Codable, Sendable, Equatable {
    public let directory: String
    public let childCID: String

    public init(directory: String, childCID: String) {
        self.directory = directory
        self.childCID = childCID
    }
}

/// Internal publication passed directly to the hierarchy runtime. Deliberately
/// not Codable so it cannot accidentally become an HTTP DTO.
public struct DirectChildProofPublication: Sendable {
    public let directory: String
    public let childCID: String
    public let childBlock: Block
    public let proof: ChildBlockProof
}

/// The runtime requests authenticated direct-child candidates against this
/// exact provisional carrier. It owns the bounded deadline and returns partial
/// success when only some children respond.
public struct ChildCandidateRequestContext: Sendable {
    public let parentCarrier: Block
    public let rewards: [MiningReward]

    public init(parentCarrier: Block, rewards: [MiningReward]) {
        self.parentCarrier = parentCarrier
        self.rewards = rewards
    }
}

public typealias ChildCandidateProvider = @Sendable (
    ChildCandidateRequestContext
) async throws
    -> [DirectChildCandidate]
public typealias ChildProofPublisher = @Sendable (
    DirectChildProofPublication
) async throws -> Void
public typealias AcceptedBlockPublisher = @Sendable (
    _ blockCID: String,
    _ canonicalized: Bool
) async throws -> Void

public struct AdmissionEffects: Sendable {
    public let parentGenesisLinks: [ParentGenesisLink]
    public let publishedChildProofs: [DirectChildProofSummary]
}

/// Creates an ordinary direct-child genesis bound to the current parent state.
/// Its signed parent anchor is submitted later through `submitTransaction`.
public struct ChildDeployIntentRequest: Codable, Sendable {
    public let directory: String
    public let spec: ChainSpec
    public let genesisTransactions: [Transaction]
    public let target: UInt256
    public let timestamp: Int64

    public init(
        directory: String,
        spec: ChainSpec,
        genesisTransactions: [Transaction],
        target: UInt256,
        timestamp: Int64
    ) {
        self.directory = directory
        self.spec = spec
        self.genesisTransactions = genesisTransactions
        self.target = target
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case spec
        case genesisTransactions
        case target
        case timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decode(String.self, forKey: .directory)
        spec = try container.decode(ChainSpec.self, forKey: .spec)
        genesisTransactions = try container.decode(
            [ContentBoundTransaction].self,
            forKey: .genesisTransactions
        ).map { try $0.transaction() }
        target = try container.decode(UInt256.self, forKey: .target)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directory, forKey: .directory)
        try container.encode(spec, forKey: .spec)
        try container.encode(
            genesisTransactions.map {
                try ContentBoundTransaction(transaction: $0)
            },
            forKey: .genesisTransactions
        )
        try container.encode(target, forKey: .target)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public struct ChildDeployIntentResponse: Codable, Sendable {
    public let directory: String
    public let chainPath: [String]
    public let genesisCID: String
    public let genesisBlock: Block
    public let parentStateCID: String
}

public enum ChainServicePhase: String, Codable, Sendable {
    case awaitingGenesis
    case active
}

public struct ChainServiceStatusResponse: Codable, Sendable, Equatable {
    public let phase: ChainServicePhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    public let height: UInt64?
    public let mempoolCount: Int
    public let mempoolBytes: Int
    public let pendingChildIntents: Int
}

public enum ChainServiceError: Error, Equatable, Sendable {
    case unresolvedChainSpec
    case invalidRewardTransaction
    case invalidRewardPlan
    case rewardPlanTooLarge
    case requestTooLarge
    case invalidChildDirectory
    case invalidChildGenesis
    case childIntentTooLarge
    case childIntentLimitReached
    case childCandidateLimitReached
    case invalidParentCarrier
    case parentCarrierRequired
    case unresolvedChildContent
    case unresolvedTransactionContent
    case templateContextChanged
    case invalidWorkID
    case timestampOverflow
    case templateTooLarge
}

/// Transport-independent operations for one path. A future HTTP layer only
/// decodes a bounded DTO, calls this actor, and encodes the response.
public actor ChainService {
    private struct ChildIntent: Sendable {
        let directory: String
        let chainPath: [String]
        let genesisCID: String
        let genesis: Block
        let parentStateCID: String
        let acquisitionEntries: [String: Data]
    }

    private struct Anchor: Hashable {
        let directory: String
        let genesisCID: String
    }

    private struct ValidatedRewardPlan {
        let current: Transaction?
        let descendants: [MiningReward]
    }

    private static let maximumWorkIDBytes = 256
    private static let maximumDirectoryBytes = 64
    private static let maximumRewardSignatures = 64
    private static let maximumSignatureFieldBytes = 256
    private static let maximumRewardPlanEntries = 256
    private static let maximumRewardPlanBytes =
        ChainServiceLimits.maximumPayloadBytes

    private let process: ChainProcess
    private let pool: TransactionPool
    private let templates: MiningTemplateBook
    private let childCandidateProvider: ChildCandidateProvider
    private let childProofPublisher: ChildProofPublisher
    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let maximumChildIntents: Int
    private let maximumChildIntentBytes: Int
    private let maximumChildCandidates: Int
    private let maximumChildCandidateBytes: Int
    private let templateLifetimeMilliseconds: UInt64
    private let templateCapacity: Int
    private var childIntents: [String: ChildIntent] = [:]

    // This actor calls other actors and is therefore reentrant. Keep its pool,
    // template cache, and pending intents in one externally observable order.
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        process: ChainProcess,
        childCandidateProvider: @escaping ChildCandidateProvider,
        childProofPublisher: @escaping ChildProofPublisher,
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher,
        mempoolMaxCount: Int = 10_000,
        mempoolMaxBytes: Int = 64 * 1024 * 1024,
        maximumChildIntents: Int = 64,
        maximumChildIntentBytes: Int = ChainServiceLimits.maximumPayloadBytes,
        maximumChildCandidates: Int = 64,
        maximumChildCandidateBytes: Int = 16 * 1024 * 1024,
        templateLifetimeSeconds: UInt64 = 30,
        templateCapacity: Int = 16
    ) {
        precondition(
            maximumChildIntents > 0
                && maximumChildIntentBytes > 0
                && maximumChildCandidates > 0
                && maximumChildCandidateBytes > 0
                && maximumChildIntentBytes
                    <= ChainServiceLimits.maximumPayloadBytes
                && templateLifetimeSeconds > 0
                && templateCapacity > 0
                && templateLifetimeSeconds <= UInt64(Int64.max / 1_000)
        )
        self.process = process
        self.childCandidateProvider = childCandidateProvider
        self.childProofPublisher = childProofPublisher
        self.acceptedBlockPublisher = acceptedBlockPublisher
        self.pool = TransactionPool(
            maxCount: mempoolMaxCount,
            maxBytes: mempoolMaxBytes
        )
        self.templates = MiningTemplateBook(
            chainPath: process.configuration.chainPath,
            minimumRootWork: process.configuration.minimumRootWork,
            lifetime: .seconds(Int64(templateLifetimeSeconds)),
            capacity: templateCapacity
        )
        self.maximumChildIntents = maximumChildIntents
        self.maximumChildIntentBytes = maximumChildIntentBytes
        self.maximumChildCandidates = maximumChildCandidates
        self.maximumChildCandidateBytes = maximumChildCandidateBytes
        self.templateLifetimeMilliseconds = templateLifetimeSeconds * 1_000
        self.templateCapacity = templateCapacity
    }

    public func status() async -> ChainServiceStatusResponse {
        await acquireOperation()
        defer { releaseOperation() }
        let status = await process.status()
        if status.phase == .active,
           let tip = try? await process.canonicalTipBlock() {
            removeStaleChildIntents(parentStateCID: tip.postState.rawCID)
        }
        return ChainServiceStatusResponse(
            phase: status.phase == .active ? .active : .awaitingGenesis,
            chainPath: status.chainPath,
            nexusGenesisCID: status.nexusGenesisCID,
            tipCID: status.tipCID,
            height: status.height,
            mempoolCount: await pool.count,
            mempoolBytes: await pool.byteCount,
            pendingChildIntents: childIntents.count
        )
    }

    public func submitTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        await acquireOperation()
        defer { releaseOperation() }
        guard let payload = try? JSONEncoder().encode(request),
              payload.count <= ChainServiceLimits.maximumPayloadBytes else {
            throw ChainServiceError.requestTooLarge
        }
        let previous = try await process.canonicalTipBlock()
        removeStaleChildIntents(parentStateCID: previous.postState.rawCID)
        let spec = try await chainSpec(for: previous)
        let cid = try await pool.submit(
            request.transaction,
            chainPath: process.configuration.chainPath,
            spec: spec,
            fetcher: process,
            storer: process
        )
        return SubmitTransactionResponse(
            transactionCID: cid,
            mempoolCount: await pool.count,
            mempoolBytes: await pool.byteCount
        )
    }

    public func createChildDeployIntent(
        _ request: ChildDeployIntentRequest
    ) async throws -> ChildDeployIntentResponse {
        await acquireOperation()
        defer { releaseOperation() }
        guard request.directory.utf8.count <= Self.maximumDirectoryBytes,
              let childAddress = ChainAddress(
                  process.configuration.chainPath + [request.directory]
              ) else {
            throw ChainServiceError.invalidChildDirectory
        }
        guard let encoded = try? JSONEncoder().encode(request),
              encoded.count <= maximumChildIntentBytes else {
            throw ChainServiceError.childIntentTooLarge
        }
        let parent = try await process.canonicalTipBlock()
        removeStaleChildIntents(parentStateCID: parent.postState.rawCID)
        guard childIntents[request.directory] != nil
            || childIntents.count < maximumChildIntents else {
            throw ChainServiceError.childIntentLimitReached
        }
        let genesis = try await BlockBuilder.buildChildGenesis(
            spec: request.spec,
            parentState: parent.postState,
            transactions: request.genesisTransactions,
            timestamp: request.timestamp,
            target: request.target,
            fetcher: process
        )
        let valid = try await genesis.validateGenesis(
            fetcher: process,
            chainPath: childAddress.components
        ).0
        guard valid else { throw ChainServiceError.invalidChildGenesis }

        let header = try BlockHeader(node: genesis)

        // Store the prepared genesis envelope and its request-owned content.
        // `parentState` deliberately references the parent's existing state;
        // recursively claiming that graph as child-deploy content would invent
        // cross-volume ownership.
        try await (header as any Header).store(storer: process)
        try await (genesis.transactions as any Header).storeRecursively(
            storer: process
        )
        try await (genesis.spec as any Header).storeRecursively(storer: process)
        let acquisitionEntries = try await process.durableCandidateEntries(
            for: genesis
        )
        let intent = ChildIntent(
            directory: request.directory,
            chainPath: childAddress.components,
            genesisCID: header.rawCID,
            genesis: genesis,
            parentStateCID: parent.postState.rawCID,
            acquisitionEntries: acquisitionEntries
        )
        childIntents[request.directory] = intent

        return ChildDeployIntentResponse(
            directory: intent.directory,
            chainPath: intent.chainPath,
            genesisCID: intent.genesisCID,
            genesisBlock: intent.genesis,
            parentStateCID: intent.parentStateCID
        )
    }

    public func miningTemplate(
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        await acquireOperation()
        defer { releaseOperation() }
        guard process.configuration.address.isNexus else {
            throw ChainServiceError.parentCarrierRequired
        }
        let assembled = try await buildMiningTemplate(
            rewards: request.rewards,
            parentCarrier: nil
        )
        let template = await templates.issue(assembled)
        return MiningTemplateResponse(
            template: template,
            maximumLifetimeMilliseconds: templateLifetimeMilliseconds
        )
    }

    /// Hierarchy-only child candidate construction. The authenticated parent
    /// supplies the provisional carrier whose `prevState` this block must bind.
    public func miningCandidate(
        parentCarrier: Block,
        rewards: [MiningReward] = []
    ) async throws -> DirectChildCandidate {
        await acquireOperation()
        defer { releaseOperation() }
        guard !process.configuration.address.isNexus,
              (try? BlockHeader(node: parentCarrier)) != nil else {
            throw ChainServiceError.invalidParentCarrier
        }
        let template = try await buildMiningTemplate(
            rewards: rewards,
            parentCarrier: parentCarrier
        )
        _ = try await process.prepareChildProofs(
            for: template.block,
            children: template.childCandidates,
            capacity: templateCapacity
        )
        let acquisitionEntries = try await process.durableCandidateEntries(
            for: template.block
        )
        return DirectChildCandidate(
            directory: process.configuration.address.directory,
            block: template.block,
            searchTarget: template.searchTarget,
            acquisitionEntries: acquisitionEntries
        )
    }

    private func buildMiningTemplate(
        rewards: [MiningReward],
        parentCarrier: Block?
    ) async throws -> MiningTemplate {
        let previous = try await process.canonicalTipBlock()
        removeStaleChildIntents(parentStateCID: previous.postState.rawCID)
        let spec = try await chainSpec(for: previous)
        let rewardPlan = try await validatedRewardPlan(rewards)
        let reward = try await validatedRewardTransaction(
            rewardPlan.current,
            previous: previous,
            spec: spec
        )
        let maximumTransactions = Int(clamping: spec.maxNumberOfTransactionsPerBlock)
        var poolLimit = max(0, maximumTransactions - (reward == nil ? 0 : 1))
        let timestamp = try nextTimestamp(after: previous.timestamp)

        while true {
            let pooled = await pool.transactions(limit: poolLimit)
            let transactions = (reward.map { [$0] } ?? []) + pooled
            let provisional = try await templates.preview(
                previous: previous,
                transactions: transactions,
                children: [],
                parentCarrier: parentCarrier,
                timestamp: timestamp,
                fetcher: process
            )
            try requireReward(rewardPlan.current, in: provisional.block)
            if !blockFits(provisional.block, spec: spec) {
                guard poolLimit > 0 else {
                    throw ChainServiceError.templateTooLarge
                }
                poolLimit /= 2
                continue
            }

            let selectedTransactions = try await blockTransactions(
                in: provisional.block
            )
            let providedChildren = try await validatedProvidedChildren(
                context: ChildCandidateRequestContext(
                    parentCarrier: provisional.block,
                    rewards: rewardPlan.descendants
                )
            )
            let children = try combineChildren(
                providedChildren,
                eligibleChildren(
                    parentStateCID: previous.postState.rawCID,
                    anchors: anchors(in: selectedTransactions)
                )
            )
            let template = try await templates.preview(
                previous: previous,
                transactions: selectedTransactions,
                children: children,
                parentCarrier: parentCarrier,
                timestamp: timestamp,
                fetcher: process
            )
            try requireReward(rewardPlan.current, in: template.block)
            try requireSameTemplateContext(
                provisional.block,
                final: template.block
            )

            if blockFits(template.block, spec: spec) {
                return template
            }
            guard poolLimit > 0 else {
                throw ChainServiceError.templateTooLarge
            }
            poolLimit /= 2
        }
    }

    public func submitWork(
        _ request: SubmitWorkRequest
    ) async throws -> SubmitWorkResponse {
        await acquireOperation()
        defer { releaseOperation() }
        guard process.configuration.address.isNexus else {
            throw ChainServiceError.parentCarrierRequired
        }
        guard !request.workID.isEmpty,
              request.workID.utf8.count <= Self.maximumWorkIDBytes else {
            throw ChainServiceError.invalidWorkID
        }
        let submission = try await templates.submission(
            workID: request.workID,
            nonce: request.nonce
        )
        let candidate = submission.block
        let header = try BlockHeader(node: candidate)
        _ = try await process.prepareChildProofs(
            for: candidate,
            children: submission.children,
            capacity: templateCapacity
        )
        let outcome = try await process.admit(header)
        let effects = try await applyAdmissionEffects(
            block: candidate,
            header: header,
            outcome: outcome
        )

        let status = await process.status()
        let accepted: Bool
        switch outcome.decision {
        case .canonicalized, .acceptedSide:
            accepted = true
        default:
            accepted = false
        }
        return SubmitWorkResponse(
            accepted: accepted,
            disposition: WorkDisposition(outcome.decision),
            tipCID: status.tipCID,
            parentCarrierLink: outcome.parentCarrierLink,
            parentGenesisLinks: effects.parentGenesisLinks,
            publishedChildProofs: effects.publishedChildProofs
        )
    }

    /// Reconciles service-owned state and publishes hierarchy effects after a
    /// candidate was admitted through gossip, sync, or the hierarchy plane.
    /// Consensus admission itself remains exclusively in `ChainProcess`.
    @discardableResult
    public func handleAdmission(
        block: Block,
        outcome: NodeAdmissionOutcome
    ) async throws -> AdmissionEffects {
        await acquireOperation()
        defer { releaseOperation() }
        return try await applyAdmissionEffects(
            block: block,
            header: BlockHeader(node: block),
            outcome: outcome
        )
    }

    private func applyAdmissionEffects(
        block: Block,
        header: BlockHeader,
        outcome: NodeAdmissionOutcome
    ) async throws -> AdmissionEffects {
        var genesisLinks: [ParentGenesisLink] = []
        let durableProofs: [DurableDirectChildProof]
        if let link = outcome.parentCarrierLink {
            durableProofs = (try? await process.durableDirectChildProofs(
                carrierCID: header.rawCID,
                rootCID: link.rootCID
            )) ?? []
        } else {
            durableProofs = []
        }

        switch outcome.decision {
        case .canonicalized, .acceptedSide, .duplicate:
            let transactions = try await blockTransactions(in: block)
            let blockAnchors = anchors(in: transactions).sorted {
                ($0.directory, $0.genesisCID) < ($1.directory, $1.genesisCID)
            }
            var includedChildren = Dictionary(
                uniqueKeysWithValues: durableProofs.map {
                    ($0.directory, $0.childBlock)
                }
            )
            if !blockAnchors.allSatisfy({ includedChildren[$0.directory] != nil }) {
                includedChildren.merge(
                    try await children(in: block),
                    uniquingKeysWith: { prepared, _ in prepared }
                )
            }
            for anchor in blockAnchors {
                guard let child = includedChildren[anchor.directory],
                      anchor.genesisCID
                        == (try? BlockHeader(node: child).rawCID) else { continue }
                if case .success(let link) = try await process.genesisLink(
                    parentBlockHeader: header,
                    directory: anchor.directory,
                    childGenesisCID: anchor.genesisCID
                ) {
                    genesisLinks.append(link)
                    if childIntents[anchor.directory]?.genesisCID
                        == anchor.genesisCID {
                        childIntents.removeValue(forKey: anchor.directory)
                    }
                }
            }
        default:
            break
        }

        switch outcome.decision {
        case .canonicalized:
            let transactionCIDs = try await blockTransactions(in: block).compactMap {
                try? VolumeImpl<Transaction>(node: $0).rawCID
            }
            await pool.remove(transactionCIDs)
            await templates.invalidateAll()
            removeStaleChildIntents(parentStateCID: block.postState.rawCID)
            do {
                try await acceptedBlockPublisher(header.rawCID, true)
            } catch {
                // Admission is already durable. Peers can recover through the
                // normal announcement/pull path; publication cannot rewrite it.
            }
        case .acceptedSide:
            do {
                try await acceptedBlockPublisher(header.rawCID, false)
            } catch {
                // As above, a retryable push is not part of consensus admission.
            }
        default:
            break
        }

        var publishedChildProofs: [DirectChildProofSummary] = []
        if outcome.parentCarrierLink != nil {
            for durable in durableProofs {
                let publication = DirectChildProofPublication(
                    directory: durable.directory,
                    childCID: durable.childCID,
                    childBlock: durable.childBlock,
                    proof: durable.proof
                )
                do {
                    try await childProofPublisher(publication)
                    publishedChildProofs.append(DirectChildProofSummary(
                        directory: publication.directory,
                        childCID: publication.childCID
                    ))
                } catch {
                    // Proofs and links are durable; hierarchy pull/reconnect can
                    // retry a failed eager publication.
                }
            }
        }
        return AdmissionEffects(
            parentGenesisLinks: genesisLinks.sorted {
                $0.directory < $1.directory
            },
            publishedChildProofs: publishedChildProofs
        )
    }

    private func chainSpec(for block: Block) async throws -> ChainSpec {
        guard let spec = try await block.spec.resolve(fetcher: process).node else {
            throw ChainServiceError.unresolvedChainSpec
        }
        return spec
    }

    private func validatedRewardTransaction(
        _ transaction: Transaction?,
        previous: Block,
        spec: ChainSpec
    ) async throws -> Transaction? {
        guard let transaction else { return nil }
        guard let bodyHeader = try? await transaction.body.resolve(fetcher: process),
              let body = bodyHeader.node else {
            throw ChainServiceError.invalidRewardTransaction
        }
        let resolved = Transaction(
            signatures: transaction.signatures,
            body: bodyHeader
        )
        let (height, overflow) = previous.height.addingReportingOverflow(1)
        guard !overflow,
              transaction.signatures.count <= Self.maximumRewardSignatures,
              transaction.signatures.allSatisfy({ key, signature in
                  key.utf8.count <= Self.maximumSignatureFieldBytes
                      && signature.utf8.count <= Self.maximumSignatureFieldBytes
              }),
              body.chainPath == process.configuration.chainPath,
              body.fee == 0,
              !body.accountActions.isEmpty,
              body.accountActions.allSatisfy(\.isCredit),
              body.actions.isEmpty,
              body.depositActions.isEmpty,
              body.genesisActions.isEmpty,
              body.receiptActions.isEmpty,
              body.withdrawalActions.isEmpty,
              body.accountActionsAreValid(),
              resolved.signaturesAreValid(),
              resolved.signaturesMatchSigners(),
              let envelope = resolved.toData(),
              let bodyData = body.toData(),
              envelope.count <= spec.maxBlockSize,
              bodyData.count <= spec.maxBlockSize else {
            throw ChainServiceError.invalidRewardTransaction
        }
        var claimed: UInt64 = 0
        for action in body.accountActions {
            let addition = claimed.addingReportingOverflow(action.absoluteAmount)
            guard !addition.overflow else {
                throw ChainServiceError.invalidRewardTransaction
            }
            claimed = addition.partialValue
        }
        guard claimed <= spec.rewardAtBlock(height),
              try await TransactionBody.batchVerifyPolicies(
                  bodies: [body],
                  spec: spec,
                  chainPath: process.configuration.chainPath,
                  fetcher: process
              ) else {
            throw ChainServiceError.invalidRewardTransaction
        }
        try await VolumeImpl<Transaction>(node: resolved).storeRecursively(
            storer: process
        )
        return resolved
    }

    private func validatedRewardPlan(
        _ rewards: [MiningReward]
    ) async throws -> ValidatedRewardPlan {
        guard rewards.count <= Self.maximumRewardPlanEntries,
              let encoded = try? JSONEncoder().encode(
                  MiningTemplateRequest(rewards: rewards)
              ),
              encoded.count <= Self.maximumRewardPlanBytes else {
            throw ChainServiceError.rewardPlanTooLarge
        }
        let currentPath = process.configuration.chainPath
        var seen: Set<String> = []
        var current: Transaction?
        var descendants: [MiningReward] = []
        var resolvedBytes = 0
        for reward in rewards {
            guard let address = ChainAddress(reward.chainPath),
                  address.components.count >= currentPath.count,
                  Array(address.components.prefix(currentPath.count))
                    == currentPath,
                  seen.insert(address.key).inserted,
                  reward.transaction.signatures.count
                    <= Self.maximumRewardSignatures,
                  reward.transaction.signatures.allSatisfy({ key, signature in
                      key.utf8.count <= Self.maximumSignatureFieldBytes
                          && signature.utf8.count
                            <= Self.maximumSignatureFieldBytes
                  }),
                  let bodyHeader = try? await reward.transaction.body.resolve(
                      fetcher: process
                  ),
                  let body = bodyHeader.node,
                  body.chainPath == address.components,
                  let bodyData = body.toData(),
                  let transactionData = reward.transaction.toData(),
                  bodyData.count <= Self.maximumRewardPlanBytes - resolvedBytes,
                  transactionData.count <= Self.maximumRewardPlanBytes
                    - resolvedBytes - bodyData.count else {
                throw ChainServiceError.invalidRewardPlan
            }
            resolvedBytes += bodyData.count + transactionData.count
            let resolvedReward = MiningReward(
                chainPath: address.components,
                transaction: Transaction(
                    signatures: reward.transaction.signatures,
                    body: bodyHeader
                )
            )
            if address.components == currentPath {
                current = resolvedReward.transaction
            } else {
                descendants.append(resolvedReward)
            }
        }
        return ValidatedRewardPlan(
            current: current,
            descendants: descendants.sorted {
                $0.chainPath.lexicographicallyPrecedes($1.chainPath)
            }
        )
    }

    private func eligibleChildren(
        parentStateCID: String,
        anchors: Set<Anchor>
    ) -> [DirectChildCandidate] {
        childIntents.values.compactMap { intent in
            guard intent.parentStateCID == parentStateCID,
                  anchors.contains(Anchor(
                      directory: intent.directory,
                      genesisCID: intent.genesisCID
                  )) else { return nil }
            return DirectChildCandidate(
                directory: intent.directory,
                block: intent.genesis,
                searchTarget: intent.genesis.target,
                acquisitionEntries: intent.acquisitionEntries
            )
        }.sorted { $0.directory < $1.directory }
    }

    private func validatedProvidedChildren(
        context: ChildCandidateRequestContext
    ) async throws
        -> [DirectChildCandidate] {
        let candidates = try await childCandidateProvider(context)
        var directories: Set<String> = []
        var encodedBytes = 0
        var accepted: [DirectChildCandidate] = []
        for candidate in candidates.sorted(by: candidateOrder) {
            guard let childCID = try? BlockHeader(node: candidate.block).rawCID,
                  let childData = candidate.block.toData() else { continue }
            guard let package = try? ChildAcquisitionPackage(
                entries: candidate.acquisitionEntries,
                childCID: childCID,
                childData: childData,
                maximumBytes: min(
                    maximumChildCandidateBytes,
                    ChildAcquisitionPackage.maximumBytes
                )
            ) else { continue }
            guard accepted.count < maximumChildCandidates,
                  candidate.directory.utf8.count <= Self.maximumDirectoryBytes,
                  ChainAddress(
                      process.configuration.chainPath + [candidate.directory]
                  ) != nil,
                  candidate.block.parentState.rawCID
                      == context.parentCarrier.prevState.rawCID,
                  candidate.searchTarget >= candidate.block.target,
                  package.framedByteCount
                    <= maximumChildCandidateBytes - encodedBytes,
                  directories.insert(candidate.directory).inserted else {
                continue
            }
            encodedBytes += package.framedByteCount
            accepted.append(DirectChildCandidate(
                directory: candidate.directory,
                block: candidate.block,
                searchTarget: candidate.searchTarget,
                acquisitionEntries: candidate.acquisitionEntries
            ))
        }
        return accepted
    }

    private func candidateOrder(
        _ left: DirectChildCandidate,
        _ right: DirectChildCandidate
    ) -> Bool {
        if left.directory != right.directory {
            return left.directory < right.directory
        }
        let leftCID = try? BlockHeader(node: left.block).rawCID
        let rightCID = try? BlockHeader(node: right.block).rawCID
        return (leftCID ?? "") < (rightCID ?? "")
    }

    private func blockFits(_ block: Block, spec: ChainSpec) -> Bool {
        block.toData().map { $0.count <= spec.maxBlockSize } ?? false
    }

    private func requireSameTemplateContext(
        _ provisional: Block,
        final: Block
    ) throws {
        guard provisional.version == final.version,
              provisional.parent?.rawCID == final.parent?.rawCID,
              provisional.transactions.rawCID == final.transactions.rawCID,
              provisional.target == final.target,
              provisional.nextTarget == final.nextTarget,
              provisional.spec.rawCID == final.spec.rawCID,
              provisional.parentState.rawCID == final.parentState.rawCID,
              provisional.prevState.rawCID == final.prevState.rawCID,
              provisional.postState.rawCID == final.postState.rawCID,
              provisional.height == final.height,
              provisional.timestamp == final.timestamp,
              provisional.nonce == final.nonce else {
            throw ChainServiceError.templateContextChanged
        }
    }

    private func combineChildren(
        _ provided: [DirectChildCandidate],
        _ deployments: [DirectChildCandidate]
    ) throws -> [DirectChildCandidate] {
        guard deployments.count <= maximumChildCandidates else {
            throw ChainServiceError.childCandidateLimitReached
        }
        let deploymentDirectories = Set(deployments.map(\.directory))
        var byDirectory = Dictionary(
            uniqueKeysWithValues: provided.filter {
                !deploymentDirectories.contains($0.directory)
            }.prefix(
                maximumChildCandidates - deployments.count
            ).map { ($0.directory, $0) }
        )
        for deployment in deployments {
            byDirectory[deployment.directory] = deployment
        }
        return byDirectory.values.sorted { $0.directory < $1.directory }
    }

    private func removeStaleChildIntents(parentStateCID: String) {
        childIntents = childIntents.filter {
            $0.value.parentStateCID == parentStateCID
        }
    }

    private func requireReward(
        _ reward: Transaction?,
        in block: Block
    ) throws {
        guard let reward else { return }
        let rewardCID = try VolumeImpl<Transaction>(node: reward).rawCID
        guard let transactions = block.transactions.node,
              try transactions.allKeysAndValues().values.contains(where: {
                  $0.rawCID == rewardCID
              }) else {
            throw ChainServiceError.invalidRewardTransaction
        }
    }

    private func anchors(in transactions: [Transaction]) -> Set<Anchor> {
        Set(transactions.flatMap { transaction in
            transaction.body.node?.genesisActions.map {
                Anchor(directory: $0.directory, genesisCID: $0.blockCID)
            } ?? []
        })
    }

    private func blockTransactions(in block: Block) async throws -> [Transaction] {
        let transactionsHeader = try await block.transactions.resolve(
            fetcher: process
        )
        guard let dictionary = transactionsHeader.node else {
            throw ChainServiceError.unresolvedTransactionContent
        }
        let entries = try dictionary.allKeysAndValues()
        var transactions: [Transaction] = []
        for index in 0..<entries.count {
            guard let transactionHeader = entries[String(index)] else {
                throw ChainServiceError.unresolvedTransactionContent
            }
            let resolved = try await transactionHeader.resolve(fetcher: process)
            guard let transaction = resolved.node else {
                throw ChainServiceError.unresolvedTransactionContent
            }
            transactions.append(transaction)
        }
        return transactions
    }

    private func children(in block: Block) async throws -> [String: Block] {
        let childrenHeader = try await block.children.resolve(fetcher: process)
        guard let dictionary = childrenHeader.node else {
            throw ChainServiceError.unresolvedChildContent
        }
        var children: [String: Block] = [:]
        for (directory, childHeader) in try dictionary.allKeysAndValues() {
            let resolved = try await childHeader.resolve(fetcher: process)
            guard let child = resolved.node else {
                throw ChainServiceError.unresolvedChildContent
            }
            children[directory] = child
        }
        return children
    }

    private func nextTimestamp(after previous: Int64) throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        if now > previous { return now }
        let (next, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else { throw ChainServiceError.timestampOverflow }
        return next
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
}

private extension WorkDisposition {
    init(_ decision: NodeAdmissionDecision) {
        switch decision {
        case .canonicalized: self = .canonicalized
        case .acceptedSide: self = .acceptedSide
        case .carrier: self = .carrier
        case .duplicate: self = .duplicate
        case .unavailable: self = .unavailable
        case .temporarilyInvalid: self = .temporarilyInvalid
        case .invalid: self = .invalid
        case .localFailure: self = .localFailure
        case .storageFailed: self = .storageFailed
        }
    }
}
