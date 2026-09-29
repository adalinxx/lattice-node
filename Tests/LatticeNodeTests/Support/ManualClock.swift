import Foundation
@testable import LatticeNode

/// A `NodeClock` that moves only when the test calls `advance(by:)`. A
/// sleeper registers at `now + nanoseconds` and resumes once an advance
/// reaches that deadline (a zero-length sleep resumes at once, like
/// `Task.sleep(nanoseconds: 0)`), or with `false` as soon as its task is
/// cancelled. Like `SystemClock`, a resumed sleep returns `false` if its task
/// was cancelled by the time it returns. Due sleepers resume in deadline
/// order (registration order within one deadline).
final class ManualClock: NodeClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var now: UInt64 = 0
    private var nextID: UInt64 = 0
    /// Sorted by (deadline, id).
    private var sleepers: [Sleeper] = []

    /// Sleepers currently waiting.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(nanoseconds: UInt64) async -> Bool {
        let id = lock.withLock { () -> UInt64 in
            nextID += 1
            return nextID
        }
        let resumed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool? = lock.withLock {
                    // The cancelled flag is set before the handler runs, so a
                    // cancel that found nothing to remove is seen here.
                    if Task.isCancelled { return false }
                    let (deadline, overflow) = now.addingReportingOverflow(nanoseconds)
                    if !overflow && deadline <= now { return true }
                    let sleeper = Sleeper(
                        id: id,
                        deadline: overflow ? UInt64.max : deadline,
                        continuation: continuation
                    )
                    let index = sleepers.firstIndex {
                        ($0.deadline, $0.id) > (sleeper.deadline, sleeper.id)
                    } ?? sleepers.endIndex
                    sleepers.insert(sleeper, at: index)
                    return nil
                }
                if let resumeNow { continuation.resume(returning: resumeNow) }
            }
        } onCancel: {
            let cancelled: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(returning: false)
        }
        return resumed && !Task.isCancelled
    }

    /// Moves time forward by `duration` and resumes every sleeper now due, in
    /// deadline order.
    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            let (moved, overflow) = now.addingReportingOverflow(Timers.nanoseconds(duration))
            now = overflow ? UInt64.max : moved
            let split = sleepers.firstIndex { $0.deadline > now } ?? sleepers.endIndex
            let due = Array(sleepers[..<split])
            sleepers.removeFirst(split)
            return due
        }
        for sleeper in due { sleeper.continuation.resume(returning: true) }
    }

    /// Waits (bounded, scaled) until at least `count` sleepers are registered,
    /// so a test never advances before the sleep it means to release.
    func waitForSleepers(
        _ count: Int,
        within: Duration = .seconds(10)
    ) async throws {
        try await eventually("\(count) sleeper(s) on the manual clock", within: within) {
            sleeperCount >= count
        }
    }
}
