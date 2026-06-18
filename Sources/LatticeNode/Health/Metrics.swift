import Foundation
import Synchronization

public final class NodeMetrics: Sendable {
    private struct Storage {
        var counters: [String: Int64] = [:]
        var gauges: [String: Double] = [:]
    }

    private let storage = Mutex(Storage())

    public init() {}

    public func increment(_ name: String, by value: Int64 = 1) {
        storage.withLock { $0.counters[name, default: 0] += value }
    }

    public func set(_ name: String, value: Double) {
        storage.withLock { $0.gauges[name] = value }
    }

    /// Drop every counter/gauge whose name contains `substring`.
    /// Used to clear per-chain label series when a chain is torn down, so the
    /// metrics map doesn't grow forever as chains are deployed and destroyed.
    public func removeKeys(containing substring: String) {
        storage.withLock { s in
            s.counters = s.counters.filter { !$0.key.contains(substring) }
            s.gauges = s.gauges.filter { !$0.key.contains(substring) }
        }
    }

    public func prometheus() -> String {
        let snap = storage.withLock { $0 }
        var lines: [String] = []

        for (name, value) in snap.counters.sorted(by: { $0.key < $1.key }) {
            lines.append("# TYPE \(name) counter")
            lines.append("\(name) \(value)")
        }

        for (name, value) in snap.gauges.sorted(by: { $0.key < $1.key }) {
            lines.append("# TYPE \(name) gauge")
            lines.append("\(name) \(value)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
