import XCTest
@testable import LatticeNode

final class StateRetentionOperationIDTests: XCTestCase {
    func testStateRetainedRootOperationIDIsPayloadBoundAndOrderIndependent() {
        let first = LatticeNode.stateRetainedRootOperationID(
            scope: "Nexus:state-retained-roots",
            tipHeight: 42,
            tipHash: "tip",
            roots: ["b", "a"]
        )
        let sameSetDifferentOrder = LatticeNode.stateRetainedRootOperationID(
            scope: "Nexus:state-retained-roots",
            tipHeight: 42,
            tipHash: "tip",
            roots: ["a", "b"]
        )
        let differentPayload = LatticeNode.stateRetainedRootOperationID(
            scope: "Nexus:state-retained-roots",
            tipHeight: 42,
            tipHash: "tip",
            roots: ["a"]
        )

        XCTAssertEqual(first, sameSetDifferentOrder)
        XCTAssertNotEqual(first, differentPayload)
    }

    func testStateRetainedRootMergeOperationIDIsDistinctFromReplace() {
        let replace = LatticeNode.stateRetainedRootOperationID(
            scope: "Nexus:state-retained-roots",
            tipHeight: 42,
            tipHash: "tip",
            roots: ["a"]
        )
        let merge = LatticeNode.stateRetainedRootMergeOperationID(
            scope: "Nexus:state-retained-roots",
            tipHeight: 42,
            tipHash: "tip",
            roots: ["a"]
        )

        XCTAssertNotEqual(replace, merge)
    }

    func testRetainedStateRootHeightsFailTowardTipForZeroRetentionDepth() {
        XCTAssertEqual(
            LatticeNode.retainedStateRootHeights(
                tipHeight: 10,
                blockRetention: .retention,
                retentionDepth: 0
            ),
            [10]
        )
    }

    func testRetainedStateRootHeightsMatchRetentionWindow() {
        XCTAssertEqual(
            LatticeNode.retainedStateRootHeights(
                tipHeight: 10,
                blockRetention: .tip,
                retentionDepth: 3
            ),
            [10]
        )
        XCTAssertEqual(
            LatticeNode.retainedStateRootHeights(
                tipHeight: 10,
                blockRetention: .retention,
                retentionDepth: 3
            ),
            [8, 9, 10]
        )
        XCTAssertEqual(
            LatticeNode.retainedStateRootHeights(
                tipHeight: 3,
                blockRetention: .historical,
                retentionDepth: 1
            ),
            [0, 1, 2, 3]
        )
    }

    func testHistoricalStorageModeRetainsAllStateRootsIndependentOfBlockRetention() {
        XCTAssertEqual(
            LatticeNode.retainedStateRootHeights(
                tipHeight: 10,
                storageMode: .historical,
                blockRetention: .retention,
                retentionDepth: 3
            ),
            Array(UInt64(0)...10)
        )
    }

    func testPrePublishRetainedRootsPreserveExistingScopeWithoutDuplicates() {
        XCTAssertEqual(
            LatticeNode.mergeRetainedRoots(
                primary: ["new-a", "shared", "", "new-b"],
                preserving: ["old-a", "shared", "", "old-b"]
            ),
            ["new-a", "shared", "new-b", "old-a", "old-b"]
        )
    }
}
