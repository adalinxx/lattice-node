import Foundation
import Ivy
import Tally

/// Persistent, cross-restart peer ban store.
///
/// A peer that floods the node (e.g. sustained mempool-full spam that keeps
/// failing admission) is banned for `banDuration`. The ban is written to a JSON
/// file in the node's storage path and reloaded on startup, so a banned peer
/// cannot clear its penalty by waiting for — or provoking — a node restart.
///
/// Lifecycle / restart / prune semantics:
/// - `load()` is called once at startup; expired entries are dropped on load.
/// - `ban(_:)` and `isBanned(_:)` lazily prune expired entries before acting,
///   so the on-disk set never accumulates dead bans without bound.
/// - bans are keyed by `PeerID.publicKey`; the wall-clock expiry is stored as a
///   Unix timestamp so it survives process restarts (a monotonic clock would
///   reset to zero on reboot).
public actor PeerBanStore {
    /// Fail-closed errors. A ban store that cannot read its persisted state, or
    /// cannot durably record a new ban, must surface the failure rather than
    /// silently admitting a peer that should be banned.
    public enum BanStoreError: Error, CustomStringConvertible {
        /// `peer_bans.json` exists but is unreadable or undecodable. Treating this
        /// as "no bans" would silently re-admit every previously banned peer, so we
        /// refuse startup instead.
        case corruptBanState(path: String, underlying: Error)
        /// A new ban could not be written to disk, so it would not survive a
        /// restart. Surfaced so the caller can refuse to keep serving the peer.
        case persistFailed(path: String, underlying: Error)

        public var description: String {
            switch self {
            case .corruptBanState(let path, let underlying):
                return "Persisted peer ban state at \(path) is unreadable/corrupt (\(underlying)); refusing startup to avoid silently re-admitting banned peers"
            case .persistFailed(let path, let underlying):
                return "Failed to durably persist peer ban to \(path) (\(underlying)); ban would not survive restart"
            }
        }
    }

    /// Default ban window: 24 hours.
    public static let defaultBanDuration: TimeInterval = 24 * 60 * 60

    private let storagePath: URL
    private let banDuration: TimeInterval
    /// publicKey -> Unix expiry timestamp (seconds).
    private var bans: [String: Double] = [:]

    public init(dataDir: URL, banDuration: TimeInterval = defaultBanDuration) {
        self.storagePath = dataDir.appendingPathComponent("peer_bans.json")
        self.banDuration = banDuration
    }

    /// Load persisted bans, dropping any that have already expired. Idempotent.
    ///
    /// Fail-closed: a missing file is a legitimate fresh state (returns 0), but a
    /// file that exists yet cannot be read or decoded is corrupt persisted ban
    /// state — we throw rather than return 0, because silently treating corruption
    /// as "no bans" would re-admit every previously banned peer.
    @discardableResult
    public func load() throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: storagePath)
        } catch {
            // Absent file = fresh state. Distinguish "no such file" from a real
            // read failure (permissions, I/O error) on an existing file.
            if !FileManager.default.fileExists(atPath: storagePath.path) {
                return 0
            }
            throw BanStoreError.corruptBanState(path: storagePath.path, underlying: error)
        }
        let decoded: [String: Double]
        do {
            decoded = try JSONDecoder().decode([String: Double].self, from: data)
        } catch {
            throw BanStoreError.corruptBanState(path: storagePath.path, underlying: error)
        }
        let now = Date().timeIntervalSince1970
        bans = decoded.filter { $0.value > now }
        // Rewrite if load dropped expired entries so the file doesn't keep them.
        if bans.count != decoded.count { try persist() }
        return bans.count
    }

    /// Ban a peer until now + `banDuration`. Re-banning extends the window.
    ///
    /// Fail-closed: throws if the ban cannot be durably written, so a caller never
    /// believes a peer is banned across restarts when it is not. The in-memory ban
    /// is still applied (the peer is dropped this session) before the throw.
    public func ban(_ peer: PeerID) throws {
        // Prune expired entries in memory, then add the new ban, then persist once.
        // (A single durable write covers both the prune and the new ban.)
        let now = Date().timeIntervalSince1970
        bans = bans.filter { $0.value > now }
        bans[peer.publicKey] = now + banDuration
        try persist()
    }

    /// True if the peer currently has a non-expired ban.
    public func isBanned(_ peer: PeerID) -> Bool {
        let now = Date().timeIntervalSince1970
        guard let expiry = bans[peer.publicKey] else { return false }
        if expiry <= now {
            bans.removeValue(forKey: peer.publicKey)
            // Best-effort cleanup: this only *removes* an already-expired ban, so a
            // failed rewrite cannot re-admit a still-banned peer. The stale entry is
            // re-pruned on the next load/ban.
            try? persist()
            return false
        }
        return true
    }

    public var count: Int {
        let now = Date().timeIntervalSince1970
        return bans.values.filter { $0 > now }.count
    }

    /// Durably write the current ban set. Throws on encode/write failure so callers
    /// that must guarantee durability (e.g. `ban`) fail closed instead of believing
    /// a ban was recorded when it was not.
    private func persist() throws {
        do {
            let data = try JSONEncoder().encode(bans)
            try data.write(to: storagePath, options: .atomic)
        } catch {
            throw BanStoreError.persistFailed(path: storagePath.path, underlying: error)
        }
    }
}
