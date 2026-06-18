import Foundation
import UInt256

// Pure, dependency-light decision logic for the external miner's poll loop,
// extracted from the `lattice-miner` executable so it can be unit-tested (SPM
// can't `@testable import` an executable target). The executable wires real
// HTTP/Ivy I/O around these decisions; the decisions themselves — dedup,
// stale/503 abort, and when to record a completed template — are the bug-prone
// parts (two were caught only in review) and live here, fully covered by tests.

/// The block template the node serves to the miner.
public struct TemplateResponse: Decodable, Sendable, Equatable {
    /// CID of the nonce-0 candidate returned by the node. Coordinators submit
    /// this plus a nonce to the node-owned solution API.
    public let workId: String?
    public let blockHex: String
    public let childBlocks: [String: String]?
    /// Easiest PoW target across the parent + embedded child blocks, computed
    /// authoritatively by the node (hex `UInt256`). Optional for older nodes
    /// that don't return it.
    public let effectiveTarget: String?
    /// Stable freshness token (the node returns the current tip hash). Invariant
    /// to timestamp-only template rebuilds, so a coordinator can tell genuine
    /// staleness (tip advanced) from the volatile workId. Optional for older
    /// nodes that don't return it.
    public let staleToken: String?

    public init(workId: String? = nil, blockHex: String, childBlocks: [String: String]? = nil, effectiveTarget: String? = nil, staleToken: String? = nil) {
        self.workId = workId
        self.blockHex = blockHex
        self.childBlocks = childBlocks
        self.effectiveTarget = effectiveTarget
        self.staleToken = staleToken
    }
}

/// What the poll loop should do with a freshly fetched template.
public enum MinerStep: Equatable, Sendable {
    /// Sleep briefly and poll again (no usable / no new work).
    case backoff
    /// Search for a nonce on the template with this `blockHex`.
    case mine(blockHex: String)
}

public enum MinerLoopLogic {
    /// Decide what to do with a freshly fetched template:
    /// - `nil` (node unavailable / 503 while syncing) → back off.
    /// - same `blockHex` as the last *sealed* template → back off (dedup: don't
    ///   re-mine a block while waiting for the tip to advance).
    /// - otherwise → mine it.
    public static func decideFetch(template: TemplateResponse?, lastBlockHex: String) -> MinerStep {
        guard let template else { return .backoff }
        if template.blockHex == lastBlockHex { return .backoff }
        return .mine(blockHex: template.blockHex)
    }

    /// During a nonce search, decide whether to abandon the current template.
    /// A failed re-poll (`nil` — e.g. the node started returning 503 because the
    /// chain is syncing) counts as stale, so the miner stops grinding a
    /// soon-to-be-doomed pre-sync block; a changed `blockHex` does too.
    public static func shouldAbortSearch(freshTemplate: TemplateResponse?, currentBlockHex: String) -> Bool {
        return freshTemplate == nil || freshTemplate?.blockHex != currentBlockHex
    }

    /// New value of `lastBlockHex` after a solve attempt. Record the template as
    /// done only once the sealed block was actually `published` to the network —
    /// an aborted search (503 / stale) or a block that was never gossiped (e.g.
    /// no P2P channel) must leave the template eligible for retry, otherwise the
    /// dedup in `decideFetch` would skip it forever and permanently stall mining.
    public static func recordAfterSolve(published: Bool, blockHex: String, lastBlockHex: String) -> String {
        return published ? blockHex : lastBlockHex
    }

    /// Parse a hex `UInt256` target (as produced by `UInt256.toHexString()`:
    /// four big-endian 64-bit words, most-significant first). Left-pads short
    /// strings and accepts an optional `0x` prefix. Inverse of `toHexString()`.
    public static func parseTarget(_ hex: String) -> UInt256? {
        var s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard !s.isEmpty, s.count <= 64, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count < 64 { s = String(repeating: "0", count: 64 - s.count) + s }
        var words: [UInt64] = []
        var idx = s.startIndex
        for _ in 0..<4 {
            let end = s.index(idx, offsetBy: 16)
            guard let w = UInt64(s[idx..<end], radix: 16) else { return nil }
            words.append(w)
            idx = end
        }
        return UInt256(words)
    }
}
