import Foundation
import Lattice

public struct SerializedTransaction: Codable, Sendable {
    public let signatures: [String: String]
    public let bodyCID: String

    public init(signatures: [String: String], bodyCID: String) {
        self.signatures = signatures
        self.bodyCID = bodyCID
    }
}

public struct MempoolPersistence: Sendable {
    public let storagePath: URL

    public init(dataDir: URL) {
        self.storagePath = dataDir.appendingPathComponent("mempool.json")
    }

    public func save(transactions: [Transaction]) throws {
        let serialized = transactions.map {
            SerializedTransaction(signatures: $0.signatures, bodyCID: $0.body.rawCID)
        }
        let data = try JSONEncoder().encode(serialized)
        try data.write(to: storagePath, options: .atomic)
    }

    public func load() -> [SerializedTransaction] {
        let log = NodeLogger("mempool-persist")
        guard FileManager.default.fileExists(atPath: storagePath.path) else { return [] }
        do {
            let data = try Data(contentsOf: storagePath)
            return try JSONDecoder().decode([SerializedTransaction].self, from: data)
        } catch {
            log.error("Failed to load mempool: \(error)")
            return []
        }
    }

    public func delete() {
        do {
            try FileManager.default.removeItem(at: storagePath)
        } catch {
            NodeLogger("mempool-persist").warn("Failed to delete mempool file: \(error)")
        }
    }
}
