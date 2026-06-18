import Foundation
import Ivy

public actor PeerStore {
    private let path: URL

    public init(dataDir: URL) {
        self.path = dataDir.appendingPathComponent("peers.json")
    }

    /// Persists candidates tagged with their provenance. `source` granularity is
    /// what the node can determine without a new Ivy callback — "anchor",
    /// "manual", "dns", or "discovered" (router/PEX/findNode collapsed). A finer
    /// pex-vs-findNode split would require an Ivy discovery hook (future).
    public func save(_ peers: [PeerEndpoint], source: String = "discovered") {
        let log = NodeLogger("peerstore")
        let entries = peers.map { PeerEntry(publicKey: $0.publicKey, host: $0.host, port: $0.port, source: source) }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: path, options: .atomic)
        } catch {
            log.error("Failed to save \(peers.count) peers: \(error)")
        }
    }

    public func load() -> [PeerEndpoint] {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let entries = try? JSONDecoder().decode([PeerEntry].self, from: data) else {
            return []
        }
        return entries.compactMap { entry -> PeerEndpoint? in
            guard isValidPeerEntry(entry) else { return nil }
            return PeerEndpoint(publicKey: entry.publicKey, host: entry.host, port: entry.port)
        }
    }

    private func isValidPeerEntry(_ entry: PeerEntry) -> Bool {
        guard entry.port >= 1 && entry.port <= 65535 else { return false }
        guard !entry.host.isEmpty else { return false }
        guard entry.publicKey.count >= 64,
              entry.publicKey.allSatisfy({ $0.isHexDigit }) else { return false }
        return true
    }
}

private struct PeerEntry: Codable {
    let publicKey: String
    let host: String
    let port: UInt16
    let source: String

    init(publicKey: String, host: String, port: UInt16, source: String) {
        self.publicKey = publicKey
        self.host = host
        self.port = port
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        // Backwards-compat: a peers.json written before Module 6 has no source.
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "discovered"
    }
}
