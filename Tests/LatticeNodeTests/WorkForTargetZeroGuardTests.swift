import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256

// the node's sync work-from-target sites (LatticeNode+Sync,
// HeaderChain) now reuse Lattice's single public `workForTarget` primitive.
// Guard that a zero target returns 0 work rather than trapping on a
// divide-by-zero, which is what the node relies on at those sites.
final class WorkForTargetZeroGuardTests: XCTestCase {

    func testZeroTargetReturnsZeroNotTrap() {
        XCTAssertEqual(workForTarget(.zero), .zero)
    }

    func testNonZeroTargetIsMaxOverTarget() {
        XCTAssertEqual(workForTarget(UInt256(2)), UInt256.max / 2)
    }
}
