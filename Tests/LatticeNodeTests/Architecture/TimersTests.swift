import XCTest
@testable import LatticeNode

/// The real clock, for the tests that exercise real sleeps.
private let timers = Timers(clock: SystemClock())

final class TimersTests: XCTestCase {

    private actor Recorder {
        var fired: [UInt64] = []
        var count = 0
        func record(_ generation: UInt64) { fired.append(generation) }
        func bump() -> Int {
            count += 1
            return count
        }
    }

    func testDeadlineFiresWithItsGeneration() async {
        let recorder = Recorder()
        let task = timers.deadline(after: .milliseconds(10), generation: 42) {
            await recorder.record($0)
        }
        await task.value
        let fired = await recorder.fired
        XCTAssertEqual(fired, [42])
    }

    func testCancelledDeadlineDoesNotFire() async throws {
        let recorder = Recorder()
        let task = timers.deadline(after: .milliseconds(50), generation: 7) {
            await recorder.record($0)
        }
        task.cancel()
        await task.value
        try await Task.sleep(nanoseconds: 100_000_000)
        let fired = await recorder.fired
        XCTAssertEqual(fired, [])
    }

    func testSleepReportsCancellation() async {
        let completed = await timers.sleep(nanoseconds: 1_000_000)
        XCTAssertTrue(completed)
        let task = Task { await timers.sleep(nanoseconds: 10_000_000_000) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertFalse(cancelled)
    }

    func testNanosecondsClampsAndSaturates() {
        XCTAssertEqual(Timers.nanoseconds(.milliseconds(1500)), 1_500_000_000)
        XCTAssertEqual(Timers.nanoseconds(.seconds(-1)), 0)
        XCTAssertEqual(Timers.nanoseconds(.seconds(Int64.max)), UInt64.max)
    }

    func testRetryReturnsTheFirstValueWithCapacity() async {
        let recorder = Recorder()
        let result = await timers.retryWhileCapacityUnavailable(
            every: .milliseconds(1),
            attempt: { await recorder.bump() },
            capacityUnavailable: { $0 < 3 },
            stillCurrent: { true }
        )
        guard case .value(let value) = result else {
            return XCTFail("expected a value, got \(result)")
        }
        XCTAssertEqual(value, 3)
    }

    func testRetryReportsStaleAfterTheSleep() async {
        let recorder = Recorder()
        let result = await timers.retryWhileCapacityUnavailable(
            every: .milliseconds(1),
            attempt: { await recorder.bump() },
            capacityUnavailable: { _ in true },
            stillCurrent: { false }
        )
        guard case .stale = result else {
            return XCTFail("expected stale, got \(result)")
        }
        let attempts = await recorder.count
        XCTAssertEqual(attempts, 1)
    }

    func testRetryReportsCancellation() async {
        let task = Task { () -> String in
            let result = await timers.retryWhileCapacityUnavailable(
                every: .seconds(10),
                attempt: { 0 },
                capacityUnavailable: { _ in true },
                stillCurrent: { true }
            )
            return "\(result)"
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    func testPollReturnsDoneValue() async {
        let recorder = Recorder()
        let result = await timers.poll(every: .milliseconds(1), onCancel: -1) {
            let count = await recorder.bump()
            return count < 3 ? .again : .done(count)
        }
        XCTAssertEqual(result, 3)
    }

    func testPollReturnsOnCancelWhenItsSleepIsCancelled() async {
        let task = Task {
            await timers.poll(every: .seconds(10), onCancel: -1) {
                Timers.Step<Int>.again
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, -1)
    }

    func testRepeatingActsFirstThenSleepsWhileTheConditionHolds() async {
        let recorder = Recorder()
        var remaining = 3
        await timers.repeating(every: .milliseconds(1), while: { remaining > 0 }) {
            remaining -= 1
            _ = await recorder.bump()
        }
        let count = await recorder.count
        XCTAssertEqual(count, 3)
    }

    // MARK: - On the manual clock

    func testDeadlineFiresOnlyWhenTheClockReachesIt() async throws {
        let clock = ManualClock()
        let recorder = Recorder()
        let task = Timers(clock: clock).deadline(after: .seconds(30), generation: 5) {
            await recorder.record($0)
        }
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(29))
        XCTAssertEqual(clock.sleeperCount, 1, "one second short: still asleep")
        let early = await recorder.fired
        XCTAssertEqual(early, [])
        clock.advance(by: .seconds(1))
        try await eventually("the deadline fires") { await recorder.fired == [5] }
        await task.value
    }

    func testCancelledManualSleepReturnsFalseAndLeavesNoSleeper() async throws {
        let clock = ManualClock()
        let recorder = Recorder()
        let task = Task {
            let completed = await clock.sleep(nanoseconds: 1_000_000_000)
            await recorder.record(completed ? 1 : 0)
        }
        try await clock.waitForSleepers(1)
        task.cancel()
        try await eventually("the cancelled sleep returns false") {
            await recorder.fired == [0]
        }
        XCTAssertEqual(clock.sleeperCount, 0, "the cancelled sleeper was removed")
        clock.advance(by: .seconds(2))
        await task.value
        let fired = await recorder.fired
        XCTAssertEqual(fired, [0], "an advance does not resume it a second time")
    }

    func testSleepCancelledBeforeItRegistersReturnsFalse() async throws {
        let clock = ManualClock()
        let recorder = Recorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let completed = await clock.sleep(nanoseconds: 1_000_000_000)
            await recorder.record(completed ? 1 : 0)
        }
        try await eventually("the pre-cancelled sleep returns false") {
            await recorder.fired == [0]
        }
        XCTAssertEqual(clock.sleeperCount, 0)
        await task.value
    }

    func testAdvanceWakesDueSleepersInDeadlineOrder() async throws {
        let clock = ManualClock()
        let recorder = Recorder()
        var tasks: [Task<Void, Never>] = []
        for seconds: UInt64 in [30, 10, 20, 40] {
            tasks.append(Task {
                if await clock.sleep(nanoseconds: seconds * 1_000_000_000) {
                    await recorder.record(seconds)
                }
            })
        }
        try await clock.waitForSleepers(4)

        clock.advance(by: .seconds(15))
        try await eventually("the 10s sleeper wakes") { await recorder.fired == [10] }
        XCTAssertEqual(clock.sleeperCount, 3)

        clock.advance(by: .seconds(5))
        try await eventually("the 20s sleeper wakes") { await recorder.fired == [10, 20] }
        XCTAssertEqual(clock.sleeperCount, 2)

        // One advance past several deadlines wakes every due sleeper.
        clock.advance(by: .seconds(100))
        try await eventually("the rest wake") { await recorder.fired.count == 4 }
        let fired = await recorder.fired
        XCTAssertEqual(Set(fired.suffix(2)), [30, 40])
        XCTAssertEqual(clock.sleeperCount, 0)
        for task in tasks { await task.value }
    }

    func testZeroLengthSleepResumesWithoutAnAdvance() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(7))
        let recorder = Recorder()
        let task = Task {
            let completed = await clock.sleep(nanoseconds: 0)
            await recorder.record(completed ? 1 : 0)
        }
        try await eventually("the zero-length sleep returns") {
            await recorder.fired == [1]
        }
        XCTAssertEqual(clock.sleeperCount, 0, "it never parked")
        await task.value
    }

    func testASaturatedSleepParksInsteadOfWrappingPastNow() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(1))
        let task = Task { await clock.sleep(nanoseconds: .max) }
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(3_600))
        XCTAssertEqual(clock.sleeperCount, 1, "an effectively infinite sleep never completes")
        task.cancel()
        let completed = await task.value
        XCTAssertFalse(completed)
    }

    func testSleepDeadlineIsRelativeToTheAdvancedTime() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(100))
        let task = Task { await clock.sleep(nanoseconds: 5_000_000_000) }
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(4))
        XCTAssertEqual(clock.sleeperCount, 1)
        clock.advance(by: .seconds(1))
        try await eventually("the sleeper wakes") { clock.sleeperCount == 0 }
        let completed = await task.value
        XCTAssertTrue(completed)
    }
}
