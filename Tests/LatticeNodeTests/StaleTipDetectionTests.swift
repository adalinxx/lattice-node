import XCTest
@testable import LatticeNode

/// Module 4: the pure stale-tip decision used by the peer-refresh loop to decide
/// whether to open feeler probes.
final class StaleTipDetectionTests: XCTestCase {

    func testNotStaleBeforeThreshold() {
        // Stuck for fewer than `staleThreshold` intervals → not stale yet.
        XCTAssertFalse(LatticeNode.tipLooksStale(
            intervalsSinceAdvance: 2, staleThreshold: 3, localHeight: 100, peerMaxHeight: 100))
    }

    func testStaleWhenStuckAndNoHeavierPeer() {
        // Stuck past threshold and no connected peer claims anything heavier.
        XCTAssertTrue(LatticeNode.tipLooksStale(
            intervalsSinceAdvance: 3, staleThreshold: 3, localHeight: 100, peerMaxHeight: 100))
        XCTAssertTrue(LatticeNode.tipLooksStale(
            intervalsSinceAdvance: 9, staleThreshold: 3, localHeight: 100, peerMaxHeight: 80))
    }

    func testNotStaleWhenAPeerHasHeavierTip() {
        // A peer advertising a heavier tip is a sync gap, not an eclipse — do not
        // treat it as stale (and do not open eclipse probes).
        XCTAssertFalse(LatticeNode.tipLooksStale(
            intervalsSinceAdvance: 9, staleThreshold: 3, localHeight: 100, peerMaxHeight: 101))
    }
}
