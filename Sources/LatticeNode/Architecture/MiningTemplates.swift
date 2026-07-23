import Foundation
import Lattice
import UInt256
import cashew

private enum MiningCandidateValidationError: Error {
    case invalid
}

public struct DirectChildCandidate: Sendable {
    public let directory: String
    public let block: Block
    let acquisitionEntries: [String: Data]

    public init(
        directory: String,
        block: Block,
        acquisitionEntries: [String: Data]
    ) {
        self.directory = directory
        self.block = block
        self.acquisitionEntries = acquisitionEntries
    }
}

/// Derives scheduling exclusively from the committed block DAG.
func committedCandidateTargets(
    block: Block,
    fetcher: any Fetcher
) async throws -> (search: UInt256, deployment: UInt256?) {
    var pending = [block]
    var seen: Set<String> = []
    var searchTarget = UInt256.zero
    var deploymentTarget = block.parent == nil ? block.target : nil

    while let current = pending.popLast() {
        let currentCID = try BlockHeader(node: current).rawCID
        guard seen.insert(currentCID).inserted else { continue }
        searchTarget = max(searchTarget, current.target)

        let childrenHeader = try await current.children.resolve(fetcher: fetcher)
        guard let childrenNode = childrenHeader.node else {
            throw MiningCandidateValidationError.invalid
        }
        let children = try await childrenNode.resolveList(fetcher: fetcher)
        for childHeader in try children.allKeysAndValues().values {
            guard let child = try await childHeader.resolve(fetcher: fetcher).node else {
                throw MiningCandidateValidationError.invalid
            }
            if child.parent == nil {
                deploymentTarget = min(
                    deploymentTarget ?? current.target,
                    current.target,
                    child.target
                )
            }
            pending.append(child)
        }
    }
    guard searchTarget > .zero else {
        throw MiningCandidateValidationError.invalid
    }
    return (searchTarget, deploymentTarget)
}

public struct MiningTemplate: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let deploymentTarget: UInt256?
    public let chainPath: [String]
    public let expiresAt: ContinuousClock.Instant
    let childCandidates: [DirectChildCandidate]

    var remainingLifetimeMilliseconds: UInt64 {
        let components = ContinuousClock.now.duration(to: expiresAt).components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return 0
        }
        let seconds = UInt64(components.seconds)
        let milliseconds = UInt64(
            components.attoseconds / 1_000_000_000_000_000
        )
        let scaled = seconds.multipliedReportingOverflow(by: 1_000)
        guard !scaled.overflow else { return .max }
        let total = scaled.partialValue.addingReportingOverflow(milliseconds)
        return total.overflow ? .max : total.partialValue
    }
}

public enum MiningTemplateError: Error, Equatable {
    case invalidChildDirectory
    case duplicateChildDirectory
    case unknownWork
    case expired
    case belowSetupFloor
    case missesSearchTarget
}

/// Bounded work cache for external miners. It never searches a nonce.
public actor MiningTemplateBook {
    private let chainPath: [String]
    private let minimumRootWork: UInt256
    private let lifetime: Duration
    private let capacity: Int
    private var templates: [String: MiningTemplate] = [:]
    private var order: [String] = []

    public init(
        chainPath: [String],
        minimumRootWork: UInt256,
        lifetime: Duration = .seconds(30),
        capacity: Int = 16
    ) {
        precondition(
            capacity > 0 && lifetime > .zero && minimumRootWork > .zero
        )
        self.chainPath = chainPath
        self.minimumRootWork = minimumRootWork
        self.lifetime = lifetime
        self.capacity = capacity
    }

    public func build(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block? = nil,
        timestamp: Int64,
        transactionLimit: Int = .max,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        let template = try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            transactionLimit: transactionLimit,
            fetcher: fetcher
        )
        return issue(template)
    }

    func issue(_ template: MiningTemplate) -> MiningTemplate {
        precondition(template.chainPath == chainPath)
        if let existing = templates[template.workID],
           ContinuousClock.now < existing.expiresAt {
            return existing
        }
        templates[template.workID] = template
        order.removeAll { $0 == template.workID }
        order.append(template.workID)
        while order.count > capacity {
            templates.removeValue(forKey: order.removeFirst())
        }
        return template
    }

    /// Assembles candidate context without issuing miner work or consuming cache
    /// capacity. Used for contextual child requests before the final child set is
    /// known.
    func preview(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block? = nil,
        timestamp: Int64,
        transactionLimit: Int = .max,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            transactionLimit: transactionLimit,
            fetcher: fetcher
        )
    }

    private func assemble(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block?,
        timestamp: Int64,
        transactionLimit: Int,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        precondition(transactionLimit >= 0)
        var childBlocks: [String: Block] = [:]
        for child in children {
            guard !child.directory.isEmpty, !child.directory.contains("/") else {
                throw MiningTemplateError.invalidChildDirectory
            }
            guard childBlocks[child.directory] == nil else {
                throw MiningTemplateError.duplicateChildDirectory
            }
            childBlocks[child.directory] = child.block
        }
        // A stale/conflicting pool entry must never suppress all external work.
        // Accept valid chunks greedily and bisect only the chunks that fail the
        // consensus state transform.
        var selected: [Transaction] = []
        var candidate = try await Self.makeCandidate(
            previous: previous,
            transactions: [],
            children: childBlocks,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            chainPath: chainPath,
            fetcher: fetcher
        )
        var chunks = transactions.isEmpty ? [] : [transactions[...]]
        while selected.count < transactionLimit, let chunk = chunks.popLast() {
            let remaining = transactionLimit - selected.count
            if chunk.count > remaining {
                let split = chunk.index(chunk.startIndex, offsetBy: remaining)
                chunks.append(chunk[split...])
                chunks.append(chunk[..<split])
                continue
            }
            do {
                candidate = try await Self.makeCandidate(
                    previous: previous,
                    transactions: selected + chunk,
                    children: childBlocks,
                    parentCarrier: parentCarrier,
                    timestamp: timestamp,
                    chainPath: chainPath,
                    fetcher: fetcher
                )
                selected.append(contentsOf: chunk)
            } catch let error
                where error is StateErrors
                    || error is ProofErrors
                    || error is MiningCandidateValidationError {
                guard chunk.count > 1 else { continue }
                let midpoint = chunk.index(
                    chunk.startIndex,
                    offsetBy: chunk.count / 2
                )
                chunks.append(chunk[midpoint...])
                chunks.append(chunk[..<midpoint])
            }
        }
        let workID = try BlockHeader(node: candidate).rawCID
        var schedulingEntries: [String: Data] = [:]
        for child in children {
            for (cid, data) in child.acquisitionEntries {
                if let existing = schedulingEntries[cid], existing != data {
                    throw MiningCandidateValidationError.invalid
                }
                schedulingEntries[cid] = data
            }
        }
        let schedulingFetcher = CoalescingFetcher(OverlayContentSource(
            entries: schedulingEntries,
            fallback: FetcherContentSource(fetcher)
        ))
        let committed = try await committedCandidateTargets(
            block: candidate,
            fetcher: schedulingFetcher
        )
        let searchTarget = min(
            committed.search,
            committed.deployment ?? .max,
            UInt256.max / minimumRootWork
        )
        let template = MiningTemplate(
            workID: workID,
            block: candidate,
            searchTarget: searchTarget,
            deploymentTarget: committed.deployment,
            chainPath: chainPath,
            expiresAt: ContinuousClock.now + lifetime,
            childCandidates: children
        )
        return template
    }

    private nonisolated static func makeCandidate(
        previous: Block,
        transactions: [Transaction],
        children: [String: Block],
        parentCarrier: Block?,
        timestamp: Int64,
        chainPath: [String],
        fetcher: any Fetcher
    ) async throws -> Block {
        let candidate = try await BlockBuilder.buildBlock(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentCarrier,
            timestamp: timestamp,
            nonce: 0,
            fetcher: fetcher
        )
        if transactions.contains(where: {
            $0.body.node?.withdrawalActions.isEmpty != true
        }) {
            let valid = try await candidate.validateWithdrawals(
                fetcher: fetcher,
                chainPath: chainPath
            )
            guard valid else { throw MiningCandidateValidationError.invalid }
        }
        return candidate
    }

    public func candidate(workID: String, nonce: UInt64) throws -> Block {
        try submission(workID: workID, nonce: nonce).block
    }

    func submission(
        workID: String,
        nonce: UInt64
    ) throws -> (block: Block, children: [DirectChildCandidate]) {
        guard let template = templates[workID] else {
            throw MiningTemplateError.unknownWork
        }
        guard ContinuousClock.now < template.expiresAt else {
            templates.removeValue(forKey: workID)
            order.removeAll { $0 == workID }
            throw MiningTemplateError.expired
        }
        let candidate = template.block.replacingNonce(nonce)
        let rootHash = candidate.proofOfWorkHash()
        guard workForHash(rootHash) >= minimumRootWork else {
            throw MiningTemplateError.belowSetupFloor
        }
        guard rootHash <= template.searchTarget else {
            throw MiningTemplateError.missesSearchTarget
        }
        return (candidate, template.childCandidates)
    }

    public func invalidateAll() {
        templates.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

private extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}
