import Foundation
import Lattice
import cashew

public enum TransactionPoolError: Error, Equatable {
    case unresolved
    case invalidSignature
    case wrongChainPath
    case invalidShape
    case invalidPolicy
    case policyUnavailable
    case tooLarge
    case full
}

public actor TransactionPool {
    private static let maximumSignatureFieldBytes = 256

    private struct Entry: Sendable {
        let cid: String
        let transaction: Transaction
        let fee: UInt64
        let size: Int
    }

    private let maxCount: Int
    private let maxBytes: Int
    private let maxSignatures: Int
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64
    ) {
        precondition(maxCount > 0 && maxBytes > 0 && maxSignatures > 0)
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
    }

    @discardableResult
    public func submit(
        _ transaction: Transaction,
        chainPath: [String],
        spec: ChainSpec,
        fetcher: any Fetcher,
        storer: any Storer
    ) async throws -> String {
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
        guard body.chainPath == chainPath else { throw TransactionPoolError.wrongChainPath }
        guard body.signers.count <= maxSignatures,
              body.accountActionsAreValid(),
              body.depositActionsAreValid(),
              body.genesisActionsAreValid(),
              body.receiptActionsAreValid(),
              body.withdrawalActionsAreValid(),
              body.actions.allSatisfy({ $0.verify() }),
              body.valueConservation().conserved else {
            throw TransactionPoolError.invalidShape
        }
        guard resolved.signaturesAreValid(), resolved.signaturesMatchSigners() else {
            throw TransactionPoolError.invalidSignature
        }
        if chainPath.count == 1,
           (!body.depositActions.isEmpty || !body.withdrawalActions.isEmpty) {
            throw TransactionPoolError.invalidShape
        }
        do {
            guard try await TransactionBody.batchVerifyPolicies(
                bodies: [body],
                spec: spec,
                chainPath: chainPath,
                fetcher: fetcher
            ) else {
                throw TransactionPoolError.invalidPolicy
            }
        } catch let error as WasmPolicyError {
            if case .missingModule = error {
                throw TransactionPoolError.policyUnavailable
            }
            throw TransactionPoolError.invalidPolicy
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
        if entries[cid] != nil { return cid }
        guard entries.count < maxCount,
              storedSize <= maxBytes - totalBytes else {
            throw TransactionPoolError.full
        }
        try await header.storeRecursively(storer: storer)
        entries[cid] = Entry(
            cid: cid,
            transaction: resolved,
            fee: body.fee,
            size: storedSize
        )
        totalBytes += storedSize
        return cid
    }

    public func transactions(limit: Int) -> [Transaction] {
        entries.values.sorted {
            let ordering = compareProducts(
                $0.fee,
                UInt64($1.size),
                $1.fee,
                UInt64($0.size)
            )
            if ordering != 0 { return ordering > 0 }
            return $0.cid < $1.cid
        }.prefix(max(0, limit)).map(\.transaction)
    }

    public func remove(_ cids: some Sequence<String>) {
        for cid in cids {
            if let removed = entries.removeValue(forKey: cid) {
                totalBytes -= removed.size
            }
        }
    }

    public var count: Int { entries.count }
    public var byteCount: Int { totalBytes }
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
