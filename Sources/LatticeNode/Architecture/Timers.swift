import Foundation

/// The timer shapes built on the node's clock port.
///
/// Every sleep goes through `clock.sleep(nanoseconds:)` (`NodeEnvironment.swift`),
/// so a test binding decides when every timer fires. `Duration` is converted
/// to nanoseconds before any task is created or any suspension happens, so it
/// never sits in an optimized async task frame (Swift 6.3 -O; see
/// `SystemClock`).
///
/// Timers does no generation gating. `deadline` passes `generation` through
/// to its fire closure and every fire target does its own check.
struct Timers: Sendable {
    let clock: any NodeClock

    /// Sleeps `nanoseconds` on the clock. Returns `false` iff the task was
    /// cancelled.
    func sleep(nanoseconds: UInt64) async -> Bool {
        await clock.sleep(nanoseconds: nanoseconds)
    }

    /// `duration` in nanoseconds, zero for a negative duration, saturating at
    /// `UInt64.max`.
    static func nanoseconds(_ duration: Duration) -> UInt64 {
        // Keep Duration out of optimized async task frames: the generic Clock
        // sleep overload can trip Swift's task allocator during teardown.
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return additionOverflow ? UInt64.max : total
    }

    /// One-shot: `fire(generation)` runs iff the sleep completes uncancelled.
    /// `Task {}`, not `Task.detached`: task-locals (the child-candidate budget)
    /// must still inherit. Callers capture `[weak self]` in `fire` so a
    /// sleeping timer does not retain its owner.
    @discardableResult
    func deadline(
        after delay: Duration,
        generation: UInt64,
        _ fire: @escaping @Sendable (UInt64) async -> Void
    ) -> Task<Void, Never> {
        let delayNanoseconds = Timers.nanoseconds(delay)
        let clock = self.clock
        return Task {
            guard await clock.sleep(nanoseconds: delayNanoseconds) else { return }
            await fire(generation)
        }
    }

    enum Retry<T: Sendable>: Sendable {
        case value(T)
        case cancelled
        case stale
    }

    /// `attempt`; while its result is `capacityUnavailable`, sleep `every`,
    /// then re-check `stillCurrent` and attempt again. The closures run on
    /// the caller's actor.
    func retryWhileCapacityUnavailable<T: Sendable>(
        every interval: Duration,
        isolation: isolated (any Actor)? = #isolation,
        attempt: () async -> T,
        capacityUnavailable: (T) -> Bool,
        stillCurrent: () -> Bool
    ) async -> Retry<T> {
        let intervalNanoseconds = Timers.nanoseconds(interval)
        while true {
            let result = await attempt()
            guard capacityUnavailable(result) else { return .value(result) }
            guard await clock.sleep(nanoseconds: intervalNanoseconds) else {
                return .cancelled
            }
            guard stillCurrent() else { return .stale }
        }
    }

    enum Step<T: Sendable>: Sendable {
        case again
        case done(T)
    }

    /// `step`; while it answers `.again`, sleep `every` and step again.
    /// Returns `onCancel` when a sleep is cancelled. The step runs on the
    /// caller's actor.
    func poll<T: Sendable>(
        every interval: Duration,
        onCancel: T,
        isolation: isolated (any Actor)? = #isolation,
        _ step: () async -> Step<T>
    ) async -> T {
        let intervalNanoseconds = Timers.nanoseconds(interval)
        while true {
            if case .done(let value) = await step() { return value }
            guard await clock.sleep(nanoseconds: intervalNanoseconds) else {
                return onCancel
            }
        }
    }

    /// While `while` holds: `body`, then sleep `every`. Acts first, then
    /// sleeps; returns when a sleep is cancelled. Runs on the caller's actor.
    func repeating(
        every interval: Duration,
        isolation: isolated (any Actor)? = #isolation,
        while condition: () -> Bool,
        _ body: () async -> Void
    ) async {
        let intervalNanoseconds = Timers.nanoseconds(interval)
        while condition() {
            await body()
            guard await clock.sleep(nanoseconds: intervalNanoseconds) else {
                return
            }
        }
    }
}
