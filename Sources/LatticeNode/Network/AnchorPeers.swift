import Foundation
import Ivy

/// Reputation scoring closure — called with a candidate endpoint and returns
/// its current Tally reputation. Used by AnchorPeers to refuse/evict peers
/// that have gone Byzantine since they were first trusted.
public typealias ReputationScoring = @Sendable (PeerEndpoint) -> Double

public actor AnchorPeers {
    private let storagePath: URL
    private var anchors: [PeerEndpoint] = []
    private let maxAnchors: Int = 6
    /// Default reputation floor for anchor insertion. Anything at-or-below
    /// this is dropped. Exposed via `update`/`evictLowScoring` for tests.
    public static let defaultMinimumScore: Double = 0

    public init(dataDir: URL) {
        self.storagePath = dataDir.appendingPathComponent("anchors.json")
    }

    public func load() -> [PeerEndpoint] {
        guard let data = try? Data(contentsOf: storagePath),
              let decoded = try? JSONDecoder().decode([StoredPeer].self, from: data) else {
            return []
        }
        anchors = decoded.map { PeerEndpoint(publicKey: $0.publicKey, host: $0.host, port: $0.port) }
        return anchors
    }

    /// Persist a new set of anchor peers. When `scoring` is provided, peers
    /// with reputation <= `minimumScore` are rejected — a peer that was
    /// well-behaved yesterday but is now serving stale tips must not be
    /// pinned into the bootstrap set across restarts.
    public func update(
        peers: [PeerEndpoint],
        scoring: ReputationScoring? = nil,
        minimumScore: Double = defaultMinimumScore
    ) {
        let filtered: [PeerEndpoint]
        if let scoring {
            filtered = peers.filter { scoring($0) > minimumScore }
        } else {
            filtered = peers
        }
        anchors = Array(filtered.prefix(maxAnchors))
        persist()
    }

    /// Drop any currently-saved anchor whose reputation has fallen to or
    /// below `minimumScore`. Returns the number of peers evicted so callers
    /// can log non-zero passes. Called periodically so a peer going Byzantine
    /// after it was already saved gets demoted without waiting for the next
    /// `update(peers:)` call from the peer-refresh loop.
    @discardableResult
    public func evictLowScoring(
        scoring: ReputationScoring,
        minimumScore: Double = defaultMinimumScore
    ) -> Int {
        let before = anchors.count
        anchors = anchors.filter { scoring($0) > minimumScore }
        let removed = before - anchors.count
        if removed > 0 { persist() }
        return removed
    }

    public var current: [PeerEndpoint] { anchors }

    private func persist() {
        let stored = anchors.map { StoredPeer(publicKey: $0.publicKey, host: $0.host, port: $0.port) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storagePath, options: .atomic)
    }
}

private struct StoredPeer: Codable {
    let publicKey: String
    let host: String
    let port: UInt16
}
