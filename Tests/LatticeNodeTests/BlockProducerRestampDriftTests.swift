import XCTest
import Synchronization
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew

/// MIN-A2 : on a long nonce search the producer's frozen candidate
/// timestamp drifts down toward (and below) the advancing MedianTimePast. The
/// producer must RE-STAMP during the search so the sealed block is not rejected
/// for `timestamp <= median`.
///
/// `produceBlock`'s loop re-stamps via `shouldRestampCandidate` (1s wall-clock
/// cadence) + `adjustedCandidateTimestamp` (clamps above the parent floor AND the
/// MedianTimePast floor, monotonically). These pin that contract: a candidate
/// frozen at search-start would fall at/below the median once wall-clock advances,
/// while the re-stamp keeps it strictly above — and the real `produceBlock` seals a
/// block that passes `validateTimestamp`.
final class BlockProducerRestampDriftTests: XCTestCase {

    private func store(_ block: Block, to fetcher: TestBrokerFetcher) async throws {
        let header = try VolumeImpl<Block>(node: block)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        await storer.flush(to: fetcher)
    }

    /// The re-stamp restores `timestamp > median` after a long search.
    ///
    /// Setup: a future-stamped ancestor window whose MedianTimePast is `M`, and a
    /// search that began when wall-clock was below `M` (so the initial stamp landed
    /// at the median floor `M + 1`). As the search runs long, wall-clock advances
    /// past `M`. The re-stamp must keep the candidate strictly above the median; a
    /// stale frozen value at exactly `M` (or below) would be rejected by
    /// `validateTimestamp` (`timestamp <= median`).
    func testRestampKeepsCandidateAboveMedianAfterLongSearch() {
        // A future-stamped window whose MedianTimePast `M` sits ABOVE the parent
        // timestamp. Because the parent is below the median, the ONLY floor keeping
        // a candidate above the median is the producer's MedianTimePast clamp — so
        // this isolates the MTP-drift guard (not the parent-monotonicity floor).
        let median: Int64 = 5_000_000
        let parentTimestamp: Int64 = median - 50_000  // parent strictly below MTP
        // 11-deep window: a majority at M so the median is exactly M, with the
        // (lower) parent timestamp included as the most-recent entry.
        let ancestors = [parentTimestamp] + Array(repeating: median, count: 10)
        XCTAssertEqual(BlockProducer.medianTimePast(ancestors), median)

        // The producer's clamp lifts the candidate strictly above the median even
        // while wall-clock `now` is still below the median floor.
        let earlyNow = median - 10_000
        let initial = BlockProducer.adjustedCandidateTimestamp(
            nowMs: earlyNow, previousTimestamp: parentTimestamp, ancestorTimestamps: ancestors
        )
        XCTAssertGreaterThan(initial, median,
                             "initial stamp must clear the MedianTimePast floor (parent floor alone would not)")

        // Long search: wall-clock advances past the median. The re-stamp cadence
        // fires (>= 1s); the re-stamp keeps the candidate monotonically
        // non-decreasing AND strictly above the (still-static) median — it never
        // drifts back to/below it, which would be rejected as `timestamp <= median`.
        XCTAssertTrue(BlockProducer.shouldRestampCandidate(nowMs: earlyNow + 1_000, lastRestampMs: earlyNow))
        let advancedNow = median + 30_000
        let restamped = BlockProducer.adjustedCandidateTimestamp(
            nowMs: advancedNow,
            previousTimestamp: parentTimestamp,
            ancestorTimestamps: ancestors,
            previousCandidateTimestamp: initial
        )
        XCTAssertGreaterThan(restamped, median, "re-stamp must keep the sealed timestamp strictly above the median")
        XCTAssertGreaterThanOrEqual(restamped, initial, "re-stamp is monotonic — it never moves the candidate backwards")
    }

    /// Load-bearing produceBlock drive of the in-loop re-stamp (BlockProducer.swift
    /// 298-337). A deterministic advancing clock (injected `nowProvider`) simulates a LONG nonce
    /// search: the clock reads `searchStart` when the initial stamp is taken, then
    /// jumps `> timestampRestampIntervalMs` before the first loop-top check so
    /// `shouldRestampCandidate` fires and the in-loop re-stamp recomputes the
    /// candidate against the now-advanced wall-clock.
    ///
    /// Non-vacuity: the chain's tip is stamped slightly in the PAST, so the INITIAL
    /// clamp (line 190) freezes the candidate at the stale parent floor
    /// `searchStart` — already valid on its own. The advanced wall-clock value
    /// (`freshNow`) is strictly larger. Only the in-loop re-stamp lifts the sealed
    /// timestamp to `freshNow`. Deleting lines 298-337 makes produceBlock seal the
    /// stale initial value instead, so the equality assertion below fails — the
    /// initial clamp alone is provably insufficient for the asserted outcome.
    ///
    /// (The MTP/median floor cannot be the binding floor here: in a VALID chain the
    /// most-recent block's timestamp is the maximum of the window, so the median is
    /// always <= the parent floor. The dedicated isolation of the MedianTimePast
    /// clamp lives in `testRestampKeepsCandidateAboveMedianAfterLongSearch`, which
    /// is permitted an artificial ancestor array exactly as `validateTimestamp`
    /// accepts an arbitrary `ancestorTimestamps`.)
    func testProduceBlockRestampsStaleCandidateDuringLongSearch() async throws {
        let fetcher = cas()
        let spec = testSpec(retargetWindow: 1_000)
        // Tip stamped in the recent past so the parent floor (the binding lower
        // bound) sits below wall-clock — a stale frozen candidate would still be
        // valid, which is what makes the re-stamp the load-bearing difference.
        let baseTimestamp = now() - 30_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: baseTimestamp, target: UInt256.max, fetcher: fetcher
        )
        try await store(genesis, to: fetcher)
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var blocks = [genesis]
        var previous = genesis
        for index in 1...12 {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: baseTimestamp + Int64(index) * 1_000,
                target: UInt256.max,
                nonce: UInt64(index),
                fetcher: fetcher
            )
            try await store(block, to: fetcher)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block),
                block: block
            )
            XCTAssertTrue(result.extendsMainChain)
            blocks.append(block)
            previous = block
        }

        let previousBlock = blocks.last!
        let ancestors = blocks.suffix(Int(BlockProducer.timestampMedianPastWindow)).reversed().map(\.timestamp)
        let median = try XCTUnwrap(BlockProducer.medianTimePast(ancestors))

        // Deterministic advancing clock: the FIRST read (the initial stamp) returns
        // `searchStart`; every later read (the in-loop re-stamp's `nowProvider()`)
        // returns `freshNow`, which is > searchStart by more than the re-stamp
        // interval, so `shouldRestampCandidate` fires on the first loop iteration.
        let searchStart = previousBlock.timestamp + 1   // == the initial parent-floor clamp
        let freshNow = now() + 3_000                    // advanced wall-clock; within future-drift
        XCTAssertGreaterThan(freshNow, searchStart + BlockProducer.timestampRestampIntervalMs,
                             "fixture: the simulated search must advance past the re-stamp cadence")
        // The clock is read serially from the producer actor; a Mutex<Int> is the
        // project's standard guard (cf. TestHelpers `_testPortCounter`).
        let callCount = Mutex<Int>(0)
        let clock: @Sendable () -> Int64 = {
            let n = callCount.withLock { c -> Int in let v = c; c += 1; return v }
            return n == 0 ? searchStart : freshNow
        }

        let producer = BlockProducer(
            chainState: chain,
            mempool: NodeMempool(maxSize: 100),
            fetcher: fetcher,
            spec: spec,
            chainPath: [DEFAULT_ROOT_DIRECTORY],
            batchSize: 10_000,
            nowProvider: clock
        )
        let producedMaybe = try await producer.produceBlock()
        let produced = try XCTUnwrap(producedMaybe)
        let block = produced.block

        // The discriminator: the sealed timestamp is the RE-STAMPED `freshNow`, NOT
        // the stale initial `searchStart`. Removing the in-loop re-stamp (298-337)
        // seals `searchStart` here and fails both assertions.
        XCTAssertEqual(block.timestamp, freshNow,
                       "the in-loop re-stamp must lift the sealed timestamp to the advanced wall-clock")
        XCTAssertGreaterThan(block.timestamp, searchStart,
                             "a producer without the in-loop re-stamp would seal the stale initial candidate")
        XCTAssertGreaterThan(block.timestamp, median,
                             "sealed timestamp clears the MedianTimePast")
        XCTAssertGreaterThan(block.timestamp, previousBlock.timestamp,
                             "sealed timestamp is strictly above the parent (monotonicity)")
        XCTAssertTrue(block.validateTimestamp(parent: previousBlock, ancestorTimestamps: ancestors),
                      "the sealed block must pass validateTimestamp at accept")
    }
}
