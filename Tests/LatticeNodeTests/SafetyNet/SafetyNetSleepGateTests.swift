import Foundation
import XCTest

/// Structural gate over `Sources/LatticeNode/Architecture`:
/// `NodeEnvironment.swift` (the `SystemClock` binding of the clock port) is
/// the only file that suspends on a sleep. Everything else sleeps through
/// the port, `clock.sleep(nanoseconds:)` or `timers.sleep(nanoseconds:)`, or
/// arms a `Timers` deadline, retry, poll or repeat, so no site can reach for
/// `Task.sleep(for:)` / `Clock.sleep(for:)` (which miscompile under Swift
/// 6.3 -O) or re-grow its own copy of the deadline pattern.
///
/// Comments are skipped: prose may name the primitive.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetSleepGateTests: XCTestCase {

    /// A direct sleep. A port sleep, `clock.sleep(nanoseconds:` or
    /// `timers.sleep(nanoseconds:`, is the sanctioned call, not a site.
    private static let sleepPattern =
        #"Task\.sleep|(?<!\btimers|\bclock)\.sleep\(|\.sleep\((?!nanoseconds:)"#

    private func sources() throws -> [SourceFile] {
        try SourceTree.swiftFiles(under: "Sources/LatticeNode/Architecture")
    }

    private func matches(_ pattern: String, in files: [SourceFile]) throws -> [String] {
        try SwiftSource.matchingLines(pattern, in: files, view: SwiftSource.blankingComments)
    }

    func testGateSeesTheSleepPrimitive() throws {
        let files = try sources()
        XCTAssertTrue(
            files.map(\.path).contains("NodeEnvironment.swift"), "gate walked \(files.count) files"
        )
        let found = try matches(
            Self.sleepPattern, in: files.filter { $0.path == "NodeEnvironment.swift" }
        )
        XCTAssertFalse(found.isEmpty, "the pattern no longer finds the primitive itself")
    }

    func testPatternCatchesEverySleepSpelling() throws {
        let caught = [
            "try await Task.sleep(nanoseconds: 1)",
            "try await Task.sleep(for: .seconds(1))",
            "try? await ContinuousClock.continuous",
            "    .sleep(until: ContinuousClock.now)",
            "try await clock.sleep(for: .seconds(1))",
            "try await Timers.sleep(nanoseconds: 1)",
        ]
        let allowed = [
            "_ = await self?.timers.sleep(nanoseconds: delay)",
            "guard await clock.sleep(nanoseconds: delay) else { return }",
        ]
        let sample = [SourceFile(path: "sample", text: (caught + allowed).joined(separator: "\n"))]
        let found = try matches(Self.sleepPattern, in: sample)
        XCTAssertEqual(found, [
            "sample:1: try await Task.sleep(nanoseconds: 1)",
            "sample:2: try await Task.sleep(for: .seconds(1))",
            "sample:4: .sleep(until: ContinuousClock.now)",
            "sample:5: try await clock.sleep(for: .seconds(1))",
            "sample:6: try await Timers.sleep(nanoseconds: 1)",
        ])
    }

    func testOnlySystemClockSleeps() throws {
        let found = try matches(
            Self.sleepPattern,
            in: sources().filter { $0.path != "NodeEnvironment.swift" }
        )
        XCTAssertEqual(found, [], "sleep outside NodeEnvironment.swift; use the clock port")
    }
}
