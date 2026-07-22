import Foundation
import Lattice
import cashew

public enum TransactionPoolError: Error, Equatable {
    case unresolved
    case tooLarge
    case full
    case invalidState
    case conflictingNonce
    case replacementUnderpriced
}

public enum TransactionPoolDisposition: Sendable, Equatable {
    case ready
    case future
    case unavailable
    case invalid
}

public struct TransactionPoolItem: Sendable {
    public let cid: String
    public let transaction: Transaction
    public let disposition: TransactionPoolDisposition
    public let addedAt: Date
}

public struct TransactionPoolMutation: Sendable {
    public let transactionCID: String?
    public let inserted: TransactionPoolItem?
    public let replaced: [TransactionPoolItem]
    public let evicted: [TransactionPoolItem]
    public let expired: [TransactionPoolItem]
    public let removed: [TransactionPoolItem]
    public let reclassified: [TransactionPoolItem]

    fileprivate var allRemoved: [TransactionPoolItem] {
        replaced + evicted + expired + removed
    }
}

public actor TransactionPool {
    private static let maximumSignatureFieldBytes = 256

    private struct Entry: Sendable {
        let cid: String
        let transaction: Transaction
        let fee: UInt64
        let size: Int
        let conflictKey: ConflictKey
        var disposition: TransactionPoolDisposition
        let addedAt: Date
    }

    private struct ConflictKey: Hashable, Sendable {
        let signers: [String]
        let nonce: UInt64
    }

    private struct SignerNonce: Hashable, Sendable {
        let signer: String
        let nonce: UInt64
    }

    private let maxCount: Int
    private let maxBytes: Int
    private let maxSignatures: Int
    private let entryLifetime: TimeInterval
    private var entries: [String: Entry] = [:]
    private var signerNonces: [SignerNonce: String] = [:]
    private var totalBytes = 0

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64,
        entryLifetime: TimeInterval = 3 * 60 * 60
    ) {
        precondition(
            maxCount > 0 && maxBytes > 0 && maxSignatures > 0
                && entryLifetime > 0
        )
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
        self.entryLifetime = entryLifetime
    }

    @discardableResult
    public func submit(
        _ transaction: Transaction,
        spec: ChainSpec,
        fetcher: any Fetcher,
        disposition: TransactionPoolDisposition = .ready,
        addedAt: Date = Date()
    ) async throws -> TransactionPoolMutation {
        guard disposition != .invalid else {
            throw TransactionPoolError.invalidState
        }
        guard transaction.signatures.count <= maxSignatures,
              transaction.signatures.allSatisfy({ key, signature in
                  key.utf8.count <= Self.maximumSignatureFieldBytes
                      && signature.utf8.count <= Self.maximumSignatureFieldBytes
              }) else {
            throw TransactionPoolError.tooLarge
        }
        if let body = transaction.body.node {
            guard let bodyData = body.toData(),
                  bodyData.count <= spec.maxBlockSize else {
                throw TransactionPoolError.tooLarge
            }
        } else {
            let bodyData = try await fetcher.fetch(rawCid: transaction.body.rawCID)
            guard bodyData.count <= spec.maxBlockSize else {
                throw TransactionPoolError.tooLarge
            }
        }
        guard let envelopeData = transaction.toData(),
              envelopeData.count <= spec.maxBlockSize else {
            throw TransactionPoolError.tooLarge
        }
        let bodyHeader = try await transaction.body.resolve(fetcher: fetcher)
        guard let body = bodyHeader.node else { throw TransactionPoolError.unresolved }
        let resolved = Transaction(signatures: transaction.signatures, body: bodyHeader)
        // Lattice preflight owns state and consensus validity. The pool only
        // enforces bounded local-resource policy and indexes replacement keys.
        guard body.signers.count <= maxSignatures else {
            throw TransactionPoolError.tooLarge
        }

        guard let bodyData = body.toData() else {
            throw TransactionPoolError.unresolved
        }
        let (storedSize, sizeOverflow) = envelopeData.count.addingReportingOverflow(
            bodyData.count
        )
        guard !sizeOverflow, storedSize <= spec.maxBlockSize else {
            throw TransactionPoolError.tooLarge
        }
        let header = try VolumeImpl<Transaction>(node: resolved)
        let cid = header.rawCID
        if entries[cid] != nil {
            return TransactionPoolMutation(
                transactionCID: cid,
                inserted: nil,
                replaced: [],
                evicted: [],
                expired: [],
                removed: [],
                reclassified: []
            )
        }
        guard storedSize <= maxBytes else {
            throw TransactionPoolError.tooLarge
        }
        let conflictKey = ConflictKey(
            signers: Array(Set(body.signers)).sorted(),
            nonce: body.nonce
        )
        let entry = Entry(
            cid: cid,
            transaction: resolved,
            fee: body.fee,
            size: storedSize,
            conflictKey: conflictKey,
            disposition: disposition,
            addedAt: addedAt
        )

        let overlappingCIDs = Set(conflictKey.signers.compactMap {
            signerNonces[SignerNonce(signer: $0, nonce: conflictKey.nonce)]
        })
        let replacedCID: String?
        if overlappingCIDs.isEmpty {
            replacedCID = nil
        } else if overlappingCIDs.count == 1,
                  let overlap = overlappingCIDs.first,
                  entries[overlap]?.conflictKey == conflictKey {
            replacedCID = overlap
        } else {
            throw TransactionPoolError.conflictingNonce
        }
        if let replacedCID, let replaced = entries[replacedCID] {
            guard entry.fee > replaced.fee,
                  feeRateComparison(
                    entry.fee,
                    entry.size,
                    replaced.fee,
                    replaced.size
                  ) > 0 else {
                throw TransactionPoolError.replacementUnderpriced
            }
        }

        var prospectiveCount = entries.count - (replacedCID == nil ? 0 : 1)
        var prospectiveBytes = totalBytes
            - (replacedCID.flatMap { entries[$0]?.size } ?? 0)
        var evictions: [String] = []
        let candidates = entries.values
            .filter { $0.cid != replacedCID }
            .sorted {
                feeRateComparison($0.fee, $0.size, $1.fee, $1.size) < 0
            }
        for candidate in candidates
        where prospectiveCount >= maxCount
            || storedSize > maxBytes - prospectiveBytes {
            guard feeRateComparison(
                entry.fee,
                entry.size,
                candidate.fee,
                candidate.size
            ) > 0 else {
                throw TransactionPoolError.full
            }
            evictions.append(candidate.cid)
            prospectiveCount -= 1
            prospectiveBytes -= candidate.size
        }
        guard prospectiveCount < maxCount,
              storedSize <= maxBytes - prospectiveBytes else {
            throw TransactionPoolError.full
        }

        let replaced = replacedCID.flatMap { entries[$0].map(item) }
        let evicted = evictions.compactMap { entries[$0].map(item) }
        if let replacedCID { _ = remove(replacedCID) }
        for cid in evictions { _ = remove(cid) }
        insert(entry)
        return TransactionPoolMutation(
            transactionCID: cid,
            inserted: item(entry),
            replaced: replaced.map { [$0] } ?? [],
            evicted: evicted,
            expired: [],
            removed: [],
            reclassified: []
        )
    }

    public func transactions(limit: Int) -> [Transaction] {
        orderedTransactions(
            limit: limit,
            includesUnavailable: false,
            includesFuture: true
        )
    }

    /// Candidate parent state can make a child withdrawal executable. Future
    /// nonces stay excluded; unavailable entries get authoritative contextual
    /// preflight before template selection.
    public func contextualTransactions(
        limit: Int
    ) -> [Transaction] {
        orderedTransactions(
            limit: limit,
            includesUnavailable: true,
            includesFuture: true
        )
    }

    private func orderedTransactions(
        limit: Int,
        includesUnavailable: Bool,
        includesFuture: Bool
    ) -> [Transaction] {
        let maximum = max(0, limit)
        guard maximum > 0 else { return [] }
        var remaining = entries.values.filter {
            $0.disposition == .ready
                || (includesFuture && $0.disposition == .future)
                || (includesUnavailable && $0.disposition == .unavailable)
        }
        var nextNonce: [String: UInt64] = [:]
        var selected: [Entry] = []
        while selected.count < maximum {
            let eligible = remaining.filter { entry in
                if entry.disposition == .ready { return true }
                guard entry.disposition == .future,
                      !entry.conflictKey.signers.isEmpty else { return false }
                return entry.conflictKey.signers.allSatisfy {
                    nextNonce[$0] == entry.conflictKey.nonce
                }
            }
            guard let best = eligible.sorted(by: higherFeePriority).first else {
                break
            }
            selected.append(best)
            remaining.removeAll { $0.cid == best.cid }
            if best.conflictKey.nonce < UInt64.max {
                for signer in best.conflictKey.signers {
                    nextNonce[signer] = best.conflictKey.nonce + 1
                }
            }
        }
        if includesUnavailable, selected.count < maximum {
            // Parent context may turn unavailable entries into a dependency
            // frontier. Preserve nonce order for Lattice's contextual preflight
            // and sequential BlockBuilder validation.
            selected += remaining.sorted {
                if $0.conflictKey.nonce != $1.conflictKey.nonce {
                    return $0.conflictKey.nonce < $1.conflictKey.nonce
                }
                return higherFeePriority($0, $1)
            }.prefix(maximum - selected.count)
        }
        return selected.map(\.transaction)
    }

    private func higherFeePriority(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let ordering = compareProducts(
            lhs.fee,
            UInt64(rhs.size),
            rhs.fee,
            UInt64(lhs.size)
        )
        if ordering != 0 { return ordering > 0 }
        return lhs.cid < rhs.cid
    }

    public func snapshot() -> [TransactionPoolItem] {
        entries.values.sorted { $0.cid < $1.cid }.map(item)
    }

    /// Reclassifies the pool against a canonical tip. The classifier is supplied
    /// by the Lattice-owning layer so the pool never copies consensus rules.
    @discardableResult
    public func revalidate(
        _ classify: @Sendable (Transaction) async throws
            -> TransactionPoolDisposition
    ) async rethrows -> TransactionPoolMutation {
        let snapshot = entries.values.sorted { $0.cid < $1.cid }
        var dispositions: [String: TransactionPoolDisposition] = [:]
        for entry in snapshot {
            dispositions[entry.cid] = try await classify(entry.transaction)
        }

        var removed: [TransactionPoolItem] = []
        var reclassified: [TransactionPoolItem] = []
        for (cid, disposition) in dispositions {
            guard entries[cid] != nil else { continue }
            if disposition == .invalid {
                if let entry = remove(cid) { removed.append(item(entry)) }
            } else {
                if entries[cid]!.disposition != disposition {
                    reclassified.append(item(entries[cid]!))
                }
                entries[cid]!.disposition = disposition
            }
        }
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: [],
            removed: removed.sorted { $0.cid < $1.cid },
            reclassified: reclassified.sorted { $0.cid < $1.cid }
        )
    }

    @discardableResult
    public func remove(_ cids: some Sequence<String>) -> TransactionPoolMutation {
        let removed = cids.compactMap { remove($0).map(item) }
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: [],
            removed: removed,
            reclassified: []
        )
    }

    @discardableResult
    public func clear() -> TransactionPoolMutation {
        let removed = entries.values.map(item)
        entries.removeAll()
        signerNonces.removeAll()
        totalBytes = 0
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: [],
            removed: removed,
            reclassified: []
        )
    }

    @discardableResult
    public func expire(at now: Date = Date()) -> TransactionPoolMutation {
        let cutoff = now.addingTimeInterval(-entryLifetime)
        let expired = entries.values
            .filter { $0.addedAt <= cutoff }
            .sorted { $0.cid < $1.cid }
            .compactMap { remove($0.cid).map(item) }
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: expired,
            removed: [],
            reclassified: []
        )
    }

    public func rollback(_ mutation: TransactionPoolMutation) {
        if let inserted = mutation.inserted { _ = remove(inserted.cid) }
        for removed in mutation.allRemoved {
            guard let body = removed.transaction.body.node,
                  let envelope = removed.transaction.toData(),
                  let bodyData = body.toData() else {
                preconditionFailure("pooled transaction lost resolved content")
            }
            insert(Entry(
                cid: removed.cid,
                transaction: removed.transaction,
                fee: body.fee,
                size: envelope.count + bodyData.count,
                conflictKey: ConflictKey(
                    signers: Array(Set(body.signers)).sorted(),
                    nonce: body.nonce
                ),
                disposition: removed.disposition,
                addedAt: removed.addedAt
            ))
        }
        for previous in mutation.reclassified where entries[previous.cid] != nil {
            entries[previous.cid]!.disposition = previous.disposition
        }
    }

    public var count: Int {
        entries.count
    }

    public var byteCount: Int {
        return totalBytes
    }

    private func item(_ entry: Entry) -> TransactionPoolItem {
        TransactionPoolItem(
            cid: entry.cid,
            transaction: entry.transaction,
            disposition: entry.disposition,
            addedAt: entry.addedAt
        )
    }

    private func insert(_ entry: Entry) {
        precondition(entries[entry.cid] == nil)
        entries[entry.cid] = entry
        for signer in entry.conflictKey.signers {
            signerNonces[SignerNonce(
                signer: signer,
                nonce: entry.conflictKey.nonce
            )] = entry.cid
        }
        totalBytes += entry.size
    }

    @discardableResult
    private func remove(_ cid: String) -> Entry? {
        guard let removed = entries.removeValue(forKey: cid) else { return nil }
        for signer in removed.conflictKey.signers {
            let key = SignerNonce(signer: signer, nonce: removed.conflictKey.nonce)
            if signerNonces[key] == cid { signerNonces.removeValue(forKey: key) }
        }
        totalBytes -= removed.size
        return removed
    }
}

private func feeRateComparison(
    _ lhsFee: UInt64,
    _ lhsSize: Int,
    _ rhsFee: UInt64,
    _ rhsSize: Int
) -> Int {
    compareProducts(
        lhsFee,
        UInt64(rhsSize),
        rhsFee,
        UInt64(lhsSize)
    )
}

private func compareProducts(
    _ leftA: UInt64,
    _ leftB: UInt64,
    _ rightA: UInt64,
    _ rightB: UInt64
) -> Int {
    let left = leftA.multipliedFullWidth(by: leftB)
    let right = rightA.multipliedFullWidth(by: rightB)
    if left.high != right.high { return left.high > right.high ? 1 : -1 }
    if left.low != right.low { return left.low > right.low ? 1 : -1 }
    return 0
}
