import Foundation
import Lattice
import cashew

public struct TransactionReceipt: Codable, Sendable {
    public let txCID: String
    public let blockHash: String
    public let blockHeight: UInt64
    public let timestamp: Int64
    public let fee: UInt64
    public let sender: String
    public let status: String
    public let accountActions: [ReceiptAction]

    public struct ReceiptAction: Codable, Sendable {
        public let owner: String
        public let delta: Int64
    }
}

public actor TransactionReceiptStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private let store: StateStore
    private let fetcher: Fetcher

    public init(store: StateStore, fetcher: Fetcher) {
        self.store = store
        self.fetcher = fetcher
    }

    public func getReceipt(txCID: String) async -> TransactionReceipt? {
        if let data = store.getGeneral(key: "receipt:\(txCID)"),
           let receipt = try? Self.decoder.decode(TransactionReceipt.self, from: data) {
            return receipt
        }

        guard let indexData = store.getGeneral(key: "receipt-idx:\(txCID)"),
              let index = try? Self.decoder.decode(ReceiptIndex.self, from: indexData) else { return nil }

        return await deriveFromCAS(txCID: txCID, index: index)
    }

    public func indexReceipt(txCID: String, blockHash: String, blockHeight: UInt64) async throws {
        guard let data = try? Self.encoder.encode(ReceiptIndex(blockHash: blockHash, blockHeight: blockHeight)) else { return }
        try await store.setGeneral(key: "receipt-idx:\(txCID)", value: data, atHeight: blockHeight)
    }

    private func deriveFromCAS(txCID: String, index: ReceiptIndex) async -> TransactionReceipt? {
        let stub = VolumeImpl<Block>(rawCID: index.blockHash, node: nil, encryptionInfo: nil)
        guard let block = try? await stub.resolve(fetcher: fetcher).node else { return nil }

        // Dict keys are sequential indices, not CIDs — resolve all and match by rawCID
        guard let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
              let entries = try? txDict.allKeysAndValues() else { return nil }

        var matchedHeader: VolumeImpl<Transaction>?
        for (_, txHeader) in entries {
            if txHeader.rawCID == txCID { matchedHeader = txHeader; break }
        }
        guard let txHeader = matchedHeader else { return nil }

        let tx: Transaction
        if let n = txHeader.node {
            tx = n
        } else {
            guard let resolved = try? await txHeader.resolve(fetcher: fetcher).node else { return nil }
            tx = resolved
        }

        let body: TransactionBody
        if let n = tx.body.node {
            body = n
        } else if let resolved = try? await tx.body.resolve(fetcher: fetcher).node {
            body = resolved
        } else {
            return nil
        }

        let actions = body.accountActions.map {
            TransactionReceipt.ReceiptAction(owner: $0.owner, delta: $0.delta)
        }
        return TransactionReceipt(
            txCID: txCID, blockHash: index.blockHash, blockHeight: index.blockHeight,
            timestamp: block.timestamp, fee: body.fee,
            sender: body.signers.first ?? "", status: "confirmed",
            accountActions: actions
        )
    }
}

private struct ReceiptIndex: Codable {
    let blockHash: String
    let blockHeight: UInt64
}
