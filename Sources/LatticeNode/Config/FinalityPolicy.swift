import Foundation
import Lattice

public struct FinalityPolicy: Sendable {
    public let chain: String
    public let confirmations: UInt64

    public init(chain: String, confirmations: UInt64) {
        self.chain = chain
        self.confirmations = confirmations
    }

    public static func parse(_ str: String) -> FinalityPolicy? {
        let parts = str.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let n = UInt64(parts[1]) else { return nil }
        return FinalityPolicy(chain: String(parts[0]), confirmations: n)
    }
}

public struct FinalityConfig: Sendable {
    private let policies: [String: UInt64]
    public let defaultConfirmations: UInt64

    public init(policies: [FinalityPolicy] = [], defaultConfirmations: UInt64 = DEFAULT_RETENTION_DEPTH) {
        var map: [String: UInt64] = [:]
        for p in policies { map[p.chain] = p.confirmations }
        self.policies = map
        self.defaultConfirmations = defaultConfirmations
    }

    public func confirmations(for chain: String) -> UInt64 {
        policies[chain] ?? defaultConfirmations
    }

    public func isFinal(chain: String, blockHeight: UInt64, currentHeight: UInt64) -> Bool {
        guard currentHeight >= blockHeight else { return false }
        return currentHeight - blockHeight >= confirmations(for: chain)
    }
}
