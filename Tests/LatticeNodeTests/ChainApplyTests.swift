import XCTest
import UInt256
@testable import LatticeNode

/// Contract tests for the single `apply(candidate)` choke point — the operation
/// gossip, sync, and rescue all funnel into. Fakes for the four injected steps, so
/// the whole contract (four outcomes + the cheap-fork-choice-first ordering + the
/// authoritative re-check at adopt) is pinned with no actor and no network.
final class ChainApplyTests: XCTestCase {

    /// Records which steps ran, in order, so we can assert the pipeline short-circuits.
    private actor CallLog {
        private(set) var steps: [String] = []
        func add(_ s: String) { steps.append(s) }
    }

    private let candidate = CandidateExtension(
        tipCID: "bafycandidate", tipHeight: 589, claimedWork: UInt256(1_000), source: nil)

    /// Test gather kinds (the payload for `.complete` is the candidate itself).
    private enum GatherKind { case complete, incomplete, mismatch(String) }

    /// Build a `ChainApply` whose steps return the given results and log their calls.
    /// `Gathered = CandidateExtension` — gather passes the candidate through.
    private func makeApply(
        log: CallLog,
        heavier: Bool = true,
        gather: GatherKind = .complete,
        validate: ValidationResult = .valid,
        adopt: AdoptResult = .adopted
    ) -> ChainApply<CandidateExtension> {
        ChainApply(
            isStrictlyHeavier: { _ in await log.add("forkChoice"); return heavier },
            gather: { c in
                await log.add("gather")
                switch gather {
                case .complete:        return .complete(c)
                case .incomplete:      return .incomplete
                case .mismatch(let r): return .contentMismatch(r)
                }
            },
            validate: { _ in await log.add("validate"); return validate },
            adopt: { _ in await log.add("adopt"); return adopt }
        )
    }

    func testAdoptedWhenHeavierAvailableValid() async {
        let log = CallLog()
        let outcome = await makeApply(log: log).apply(candidate)
        XCTAssertEqual(outcome, .adopted(tipCID: "bafycandidate"))
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather", "validate", "adopt"], "full pipeline, in order")
    }

    func testIgnoredWhenLighterShortCircuitsBeforeAnyFetch() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, heavier: false).apply(candidate)
        XCTAssertEqual(outcome, .ignoredLighter)
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice"], "a lighter candidate must NOT trigger a fetch (cheap-first)")
    }

    func testPendingWhenDataIncompleteIsNotInvalid() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, gather: .incomplete).apply(candidate)
        XCTAssertEqual(outcome, .pendingUnavailable, "missing data → retry, NEVER invalid")
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather"], "no validate/adopt on a data miss")
    }

    func testInvalidWhenContentMismatch() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, gather: .mismatch("cid≠hash")).apply(candidate)
        XCTAssertEqual(outcome, .invalid(reason: "cid≠hash"), "content-binding failure is attributable → invalid")
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather"])
    }

    func testInvalidWhenValidationFails() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, validate: .invalid("bad PoW")).apply(candidate)
        XCTAssertEqual(outcome, .invalid(reason: "bad PoW"))
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather", "validate"], "no adopt on invalid")
    }

    func testIgnoredWhenSupersededAtAdopt() async {
        // Everything passed, but the local chain advanced during gather/validate —
        // the authoritative re-check under the lock holds the (now-heavier) incumbent.
        let log = CallLog()
        let outcome = await makeApply(log: log, adopt: .supersededByHeavierLocal).apply(candidate)
        XCTAssertEqual(outcome, .ignoredLighter, "mid-apply local advance → hold incumbent (twice-check)")
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather", "validate", "adopt"])
    }

    func testPendingWhenAdoptTransientFailure() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, adopt: .transientFailure).apply(candidate)
        XCTAssertEqual(outcome, .pendingUnavailable, "a commit-time miss retries, never dead-ends silently")
    }
}
