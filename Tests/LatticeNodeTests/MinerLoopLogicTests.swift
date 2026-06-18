import XCTest
import Lattice
import UInt256
@testable import LatticeMinerCore

/// Unit tests for the external miner's poll-loop decision logic. These cover the
/// bugs caught only in PR review:
///   1. a 503 (syncing) re-poll must abort the search, not keep grinding;
///   2. `lastBlockHex` must be recorded only after the block is actually
///      published — an aborted search OR a block that was never gossiped (no P2P
///      channel) must stay eligible for retry, or the dedup permanently stalls
///      mining.
final class MinerLoopLogicTests: XCTestCase {

    private func tmpl(_ hex: String) -> TemplateResponse { TemplateResponse(blockHex: hex) }

    // MARK: - decideFetch (fetch + dedup)

    func testDecideFetchBacksOffOnNoTemplate() {
        // 503 while syncing / node unavailable → fetchTemplate returns nil.
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: nil, lastBlockHex: "H"), .backoff)
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: nil, lastBlockHex: ""), .backoff)
    }

    func testDecideFetchDedupsSameTemplate() {
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H"), lastBlockHex: "H"), .backoff)
    }

    func testDecideFetchMinesNewTemplate() {
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H"), lastBlockHex: ""), .mine(blockHex: "H"))
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H2"), lastBlockHex: "H1"), .mine(blockHex: "H2"))
    }

    // MARK: - shouldAbortSearch (stale / 503 during search)

    func testAbortSearchOn503() {
        // The key regression: a nil re-poll (503 syncing) must abort, not continue.
        XCTAssertTrue(MinerLoopLogic.shouldAbortSearch(freshTemplate: nil, currentBlockHex: "H"))
    }

    func testNoAbortWhenTemplateUnchanged() {
        XCTAssertFalse(MinerLoopLogic.shouldAbortSearch(freshTemplate: tmpl("H"), currentBlockHex: "H"))
    }

    func testAbortWhenTemplateChanged() {
        XCTAssertTrue(MinerLoopLogic.shouldAbortSearch(freshTemplate: tmpl("H2"), currentBlockHex: "H"))
    }

    // MARK: - recordAfterSolve (only record on success)

    func testRecordsOnSuccessfulSeal() {
        XCTAssertEqual(MinerLoopLogic.recordAfterSolve(published: true, blockHex: "H", lastBlockHex: "prev"), "H")
    }

    func testDoesNotRecordOnAbortedSolve() {
        XCTAssertEqual(MinerLoopLogic.recordAfterSolve(published: false, blockHex: "H", lastBlockHex: "prev"), "prev")
    }

    func testDoesNotRecordWhenNeverPublished() {
        // No P2P channel → the sealed block was never gossiped, so it must stay
        // eligible for retry instead of being deduped away (#50 review follow-up).
        XCTAssertEqual(MinerLoopLogic.recordAfterSolve(published: false, blockHex: "H", lastBlockHex: ""), "")
    }

    // MARK: - Integration: the two bugs, end to end

    /// Regression for the stall bug: an aborted search (503) must leave the same
    /// template eligible for retry, not skip it forever via the dedup.
    func testAbortedSolveDoesNotStallOnSameTemplate() {
        var last = ""
        // Iter 1: fetch H → mine it.
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H"), lastBlockHex: last), .mine(blockHex: "H"))
        // ...search aborts (e.g. transient 503) → do not record.
        last = MinerLoopLogic.recordAfterSolve(published: false, blockHex: "H", lastBlockHex: last)
        XCTAssertEqual(last, "")
        // Iter 2: same template H is still mined (not permanently skipped).
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H"), lastBlockHex: last), .mine(blockHex: "H"))
    }

    /// Counterpart: a *successful* seal dedups the same template (don't re-mine
    /// while waiting for the tip to advance) but mines once the tip moves.
    func testSuccessfulSealDedupsUntilTipAdvances() {
        var last = ""
        last = MinerLoopLogic.recordAfterSolve(published: true, blockHex: "H", lastBlockHex: last)
        XCTAssertEqual(last, "H")
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H"), lastBlockHex: last), .backoff)
        XCTAssertEqual(MinerLoopLogic.decideFetch(template: tmpl("H2"), lastBlockHex: last), .mine(blockHex: "H2"))
    }

    // MARK: - parseTarget (hex UInt256 round-trip with toHexString)

    func testParseTargetRoundTrips() {
        let values: [UInt256] = [
            .max, UInt256(0), UInt256(1), UInt256(1000),
            UInt256([1, 2, 3, 4]), UInt256([0, 0, 0, 0xDEADBEEF]),
            UInt256([0xFFFFFFFFFFFFFFFF, 0, 0xA5A5A5A5A5A5A5A5, 0]),
        ]
        for v in values {
            XCTAssertEqual(MinerLoopLogic.parseTarget(v.toHexString()), v, "round-trip failed for \(v.toHexString())")
        }
    }

    func testParseTargetAcceptsShortHexAndPrefix() {
        XCTAssertEqual(MinerLoopLogic.parseTarget("ff"), UInt256(255))
        XCTAssertEqual(MinerLoopLogic.parseTarget("0xff"), UInt256(255))
        XCTAssertEqual(MinerLoopLogic.parseTarget("0"), UInt256(0))
    }

    func testParseTargetRejectsInvalid() {
        XCTAssertNil(MinerLoopLogic.parseTarget(""))
        XCTAssertNil(MinerLoopLogic.parseTarget("xyz"))
        XCTAssertNil(MinerLoopLogic.parseTarget("0xZZ"))
        // Too long (> 64 hex chars / 256 bits).
        XCTAssertNil(MinerLoopLogic.parseTarget(String(repeating: "f", count: 65)))
    }

    // MARK: - ProofOfWork

    func testProofOfWorkSearchFindsNonceInRequestedRange() async throws {
        let fetcher = cas()
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        let nonce = await ProofOfWork.searchNonce(
            midstate: ProofOfWork.midstate(for: block),
            target: UInt256.max,
            totalBatchSize: 4,
            workerCount: 1,
            nonceOffset: 7
        )

        XCTAssertEqual(nonce, 7)
    }

    func testProofOfWorkWithNonceOnlyChangesNonce() async throws {
        let fetcher = cas()
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        let sealed = ProofOfWork.withNonce(block, nonce: 42)

        XCTAssertEqual(sealed.nonce, 42)
        XCTAssertEqual(sealed.parent?.rawCID, block.parent?.rawCID)
        XCTAssertEqual(sealed.transactions.rawCID, block.transactions.rawCID)
        XCTAssertEqual(sealed.postState.rawCID, block.postState.rawCID)
        XCTAssertNotEqual(sealed.proofOfWorkHash(), block.proofOfWorkHash())
    }
}
