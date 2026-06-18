import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256

// F5-4: the child-side inherited-weight store. A child has one continuity anchor
// but may have many verified parent/root proof paths; overlapping contributors
// must count once per child. The store is a scalar inherited-weight index, not a proof
// graph: proofs/segments install the inherited work at the boundary, and fork
// choice reads it in O(1).

final class InheritedWeightStoreTests: XCTestCase {

    func testAccumulatesContributorsForOneChild() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkContributions(
            [(id: "P1", work: UInt256(10)), (id: "P2", work: UInt256(7))],
            committingChild: "C"
        )
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(17))
    }

    func testUnknownChildInheritsZero() {
        let store = InheritedWeightStore()
        store.recordVerifiedParentWork(UInt256(5), parentBlockHash: "P1", committingChild: "C")
        XCTAssertEqual(store.inheritedWeight(forChild: "UNKNOWN"), .zero, "no anchor ⇒ 0 (pure same-chain GHOST)")
    }

    func testOverlappingProofPathsCountSharedContributorOnce() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkContributions(
            [(id: "Root", work: UInt256(10)), (id: "MidA", work: UInt256(5))],
            committingChild: "C"
        )
        store.recordVerifiedWorkContributions(
            [(id: "Root", work: UInt256(10)), (id: "MidB", work: UInt256(7))],
            committingChild: "C"
        )
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(22),
                       "shared Root is counted once, distinct parent paths both contribute")
    }

    func testInheritedWeightDoesNotWalkContributorGraphAtLookup() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkContributions(
            [(id: "Root", work: UInt256(10))],
            committingChild: "Parent"
        )
        store.recordVerifiedWorkContributions(
            [(id: "Parent", work: UInt256(7))],
            committingChild: "Child"
        )

        XCTAssertEqual(
            store.inheritedWeight(forChild: "Child"),
            UInt256(7),
            "the hot path reads Child's scalar inherited weight; proofs must install the full inherited value explicitly"
        )
    }

    func testFullProofCheckpointCarriesAncestorWorkExplicitly() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkContributions(
            [(id: "Root", work: UInt256(10))],
            committingChild: "Parent"
        )
        store.recordVerifiedWorkContributions(
            [(id: "Root", work: UInt256(10)), (id: "Parent", work: UInt256(7))],
            committingChild: "Child"
        )

        XCTAssertEqual(
            store.inheritedWeight(forChild: "Child"),
            UInt256(17),
            "the verified full proof carries both Root and Parent work directly"
        )
    }

    func testSegmentContributionCanInstallOneCheckedRun() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkSegment(
            ConsensusWorkSegment(
                baseHash: "P10",
                tipHash: "P20",
                startWork: UInt256(10),
                endWork: UInt256(110)
            ),
            committingChild: "C"
        )
        store.recordVerifiedWorkSegment(
            ConsensusWorkSegment(
                baseHash: "P10",
                tipHash: "P20",
                startWork: UInt256(10),
                endWork: UInt256(110)
            ),
            committingChild: "C"
        )

        XCTAssertEqual(
            store.inheritedWeight(forChild: "C"),
            UInt256(100),
            "a no-fork parent run can be represented by one deduped segment"
        )
    }

    func testOverlappingLinearSegmentsDedupeByRepeatedBlockHash() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkSegments(
            [
                ConsensusWorkSegment(
                    headHash: "P1",
                    baseHash: nil,
                    tipHash: "P2",
                    blocks: ["P1", "P2"],
                    cumulativeWorkByBlock: [
                        "P1": UInt256(50),
                        "P2": UInt256(100),
                    ],
                    startWork: UInt256(0),
                    endWork: UInt256(100)
                ),
                ConsensusWorkSegment(
                    headHash: "P2",
                    baseHash: "P50",
                    tipHash: "P3",
                    blocks: ["P2", "P3"],
                    cumulativeWorkByBlock: [
                        "P2": UInt256(100),
                        "P3": UInt256(150),
                    ],
                    startWork: UInt256(50),
                    endWork: UInt256(150)
                ),
            ],
            committingChild: "C"
        )

        XCTAssertEqual(
            store.inheritedWeight(forChild: "C"),
            UInt256(150),
            "overlapping same-chain segments share block P2, so P2 is counted once by block identity"
        )
    }

    func testForkSiblingSegmentsWithOverlappingPrefixCoordinatesBothCount() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkSegments(
            [
                ConsensusWorkSegment(
                    headHash: "P",
                    baseHash: nil,
                    tipHash: "P",
                    blocks: ["P"],
                    cumulativeWorkByBlock: [
                        "P": UInt256(2)
                    ],
                    startWork: UInt256(0),
                    endWork: UInt256(2),
                    children: [
                        ConsensusWorkSegment(
                            headHash: "A",
                            baseHash: "P",
                            tipHash: "A",
                            blocks: ["A"],
                            cumulativeWorkByBlock: [
                                "A": UInt256(5)
                            ],
                            startWork: UInt256(2),
                            endWork: UInt256(5)
                        ),
                        ConsensusWorkSegment(
                            headHash: "B",
                            baseHash: "P",
                            tipHash: "B",
                            blocks: ["B"],
                            cumulativeWorkByBlock: [
                                "B": UInt256(7)
                            ],
                            startWork: UInt256(2),
                            endWork: UInt256(7)
                        ),
                    ]
                ),
            ],
            committingChild: "C"
        )

        XCTAssertEqual(
            store.inheritedWeight(forChild: "C"),
            UInt256(10),
            "sibling forks may share numeric prefix coordinates; distinct block hashes both add work"
        )
    }

    func testSameContributorCanCreditDifferentChildrenIndependently() {
        let store = InheritedWeightStore()
        store.recordVerifiedParentWork(UInt256(10), parentBlockHash: "P1", committingChild: "C1")
        store.recordVerifiedParentWork(UInt256(10), parentBlockHash: "P1", committingChild: "C2")
        XCTAssertEqual(store.inheritedWeight(forChild: "C1"), UInt256(10))
        XCTAssertEqual(store.inheritedWeight(forChild: "C2"), UInt256(10))
    }

    func testBlocktreeSiblingChildrenInheritSameParentSegmentIndependently() {
        let store = InheritedWeightStore()
        let parentSegment = ConsensusWorkSegment(
            headHash: "N0",
            baseHash: nil,
            tipHash: "N2",
            blocks: ["N0", "N1", "N2"],
            cumulativeWorkByBlock: [
                "N0": UInt256(2),
                "N1": UInt256(5),
                "N2": UInt256(11),
            ],
            startWork: UInt256(0),
            endWork: UInt256(11)
        )

        store.recordVerifiedWorkSegments([parentSegment], committingChild: "StableBlock")
        store.recordVerifiedWorkSegments([parentSegment], committingChild: "OtherBlock")
        store.recordVerifiedWorkSegments([parentSegment], committingChild: "StableBlock")

        XCTAssertEqual(store.inheritedWeight(forChild: "StableBlock"), UInt256(11))
        XCTAssertEqual(store.inheritedWeight(forChild: "OtherBlock"), UInt256(11))
        XCTAssertEqual(
            store.totalParentWork,
            UInt256(22),
            "each blocktree child has its own inherited-work entry; duplicate proofs for one child do not inflate it"
        )
    }

    func testNestedBlocktreeProjectionCarriesAncestorWorkInOneParentSegment() {
        let store = InheritedWeightStore()
        let midProjection = ConsensusWorkSegment(
            headHash: "M0",
            baseHash: nil,
            tipHash: "M0",
            blocks: ["M0"],
            cumulativeWorkByBlock: ["M0": UInt256(20)],
            startWork: UInt256(0),
            endWork: UInt256(20)
        )

        store.recordVerifiedWorkSegments([midProjection], committingChild: "StableBlock")
        store.recordVerifiedWorkSegments([midProjection], committingChild: "StableBlock")
        XCTAssertEqual(
            store.inheritedWeight(forChild: "StableBlock"),
            UInt256(20),
            "the immediate parent projection carries root-plus-parent blocktree work before segment recording"
        )
    }

    func testProviderReadsStore() {
        let store = InheritedWeightStore()
        store.recordVerifiedParentWork(UInt256(42), parentBlockHash: "P1", committingChild: "C")
        let provider = store.makeProvider()
        XCTAssertEqual(provider("C"), UInt256(42), "provider closure reflects the store")
        XCTAssertEqual(provider("nope"), .zero)
    }

    func testDuplicateContributorDoesNotInflateWeight() {
        let store = InheritedWeightStore()
        store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P1", committingChild: "C")
        store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P1", committingChild: "C")
        XCTAssertEqual(store.totalParentWork, UInt256(50), "duplicate contributor must not inflate total")
    }
}
