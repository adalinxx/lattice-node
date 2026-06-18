import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticeMinerCore
@testable import LatticeNode

final class BlockProducerMiningTests: XCTestCase {
    // In-process merged mining (the producer building/mining child blocks
    // itself) was removed: each chain runs as its own node process and child
    // CANDIDATES flow over the registered template RPC routes. Cross-chain
    // coverage lives in SmokeTests.

    func testNonceCoverageHasNoGap() {
        let startNonce: UInt64 = 42
        let layout = BlockProducer.nonceRoundLayout(
            startNonce: startNonce,
            batchSize: 10_000,
            workerCount: 7
        )

        XCTAssertEqual(layout.coverage, 10_000)
        XCTAssertEqual(layout.advance, 10_000)
        XCTAssertEqual(layout.ranges.count, 7)
        XCTAssertEqual(layout.ranges.first?.startNonce, startNonce)

        var expectedStart = startNonce
        var seen = Set<UInt64>()
        for range in layout.ranges {
            XCTAssertEqual(range.startNonce, expectedStart)
            XCTAssertGreaterThan(range.count, 0)
            for nonce in range.startNonce..<(range.startNonce &+ range.count) {
                XCTAssertTrue(seen.insert(nonce).inserted, "nonce \(nonce) must be covered exactly once")
            }
            expectedStart &+= range.count
        }

        XCTAssertEqual(seen.count, 10_000)
        XCTAssertEqual(expectedStart, startNonce &+ layout.advance)

        let nextLayout = BlockProducer.nonceRoundLayout(
            startNonce: startNonce &+ layout.advance,
            batchSize: 10_000,
            workerCount: 7
        )
        XCTAssertEqual(nextLayout.ranges.first?.startNonce, expectedStart)
    }

    func testProofOfWorkSearchRangesDistributeRemainder() {
        let ranges = ProofOfWork.nonceSearchRanges(
            totalBatchSize: 10_000,
            workerCount: 7,
            nonceOffset: 0
        )

        XCTAssertEqual(ranges.map(\.count), [1_429, 1_429, 1_429, 1_429, 1_428, 1_428, 1_428])
        XCTAssertEqual(ranges.reduce(UInt64(0)) { $0 &+ $1.count }, 10_000)

        var nextStart: UInt64 = 0
        for range in ranges {
            XCTAssertEqual(range.startNonce, nextStart)
            nextStart &+= range.count
        }
        XCTAssertEqual(nextStart, 10_000)
    }
}
