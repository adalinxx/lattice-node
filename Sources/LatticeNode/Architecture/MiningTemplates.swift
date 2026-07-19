import Foundation
import Lattice
import UInt256
import cashew

public struct DirectChildCandidate: Sendable {
    public let directory: String
    public let block: Block
    /// Easiest target satisfied by this candidate or anything nested below it.
    public let searchTarget: UInt256
    let acquisitionEntries: [String: Data]

    public init(
        directory: String,
        block: Block,
        searchTarget: UInt256,
        acquisitionEntries: [String: Data]
    ) {
        self.directory = directory
        self.block = block
        self.searchTarget = searchTarget
        self.acquisitionEntries = acquisitionEntries
    }
}

public struct MiningTemplate: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
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
    case missesEveryTarget
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
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        let template = try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
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
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            fetcher: fetcher
        )
    }

    private func assemble(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block?,
        timestamp: Int64,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
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
            fetcher: fetcher
        )
        var chunks = transactions.isEmpty ? [] : [transactions[...]]
        while let chunk = chunks.popLast() {
            do {
                candidate = try await Self.makeCandidate(
                    previous: previous,
                    transactions: selected + chunk,
                    children: childBlocks,
                    parentCarrier: parentCarrier,
                    timestamp: timestamp,
                    fetcher: fetcher
                )
                selected.append(contentsOf: chunk)
            } catch is StateErrors {
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
        let easiestAcceptedTarget = children.reduce(candidate.target) {
            max($0, $1.searchTarget)
        }
        let searchTarget = min(
            easiestAcceptedTarget,
            UInt256.max / minimumRootWork
        )
        let template = MiningTemplate(
            workID: workID,
            block: candidate,
            searchTarget: searchTarget,
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
        fetcher: any Fetcher
    ) async throws -> Block {
        try await BlockBuilder.buildBlock(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentCarrier,
            timestamp: timestamp,
            nonce: 0,
            fetcher: fetcher
        )
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
            throw MiningTemplateError.missesEveryTarget
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
