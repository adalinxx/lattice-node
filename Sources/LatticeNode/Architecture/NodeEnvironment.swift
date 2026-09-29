import Foundation

/// The node's time port. Production binds `SystemClock`; tests bind a
/// manual clock so every timer fires only when the test advances time.
public protocol NodeClock: Sendable {
    /// Sleeps `nanoseconds`. Returns `false` iff the task was cancelled.
    func sleep(nanoseconds: UInt64) async -> Bool
}

/// The real clock, and the node's one suspension primitive.
///
/// Sleeps use `Task.sleep(nanoseconds:)` ONLY. Never `Task.sleep(for:)` and
/// never `Clock.sleep(for:)`: both bodies are emitted into the client and
/// miscompile under Swift 6.3 -O (swift_task_dealloc aborts with "freed
/// pointer was not the last allocation" on resume).
public struct SystemClock: NodeClock {
    public init() {}

    public func sleep(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
