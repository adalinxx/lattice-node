import Lattice
import XCTest
@testable import LatticeNode

final class AdmissionDecisionTests: XCTestCase {
    func testAvailabilityAndInvalidityStayDistinct() {
        let unavailable = NodeAdmissionDecision(
            .rejected(.crossChainEvidenceRequired(.childProof(
                chainPath: ["Nexus", "Payments"],
                childCID: "child"
            )))
        )
        XCTAssertTrue(unavailable.shouldRetryWhenEvidenceChanges)
        XCTAssertFalse(unavailable.mayPenalizeAuthenticatedSupplier(
            as: .sameChainCandidate
        ))

        let invalid = NodeAdmissionDecision(.rejected(.protocolInvalid))
        XCTAssertFalse(invalid.shouldRetryWhenEvidenceChanges)
        XCTAssertTrue(invalid.mayPenalizeAuthenticatedSupplier(
            as: .sameChainCandidate
        ))
        XCTAssertFalse(invalid.mayPenalizeAuthenticatedSupplier(
            as: .parentEvidence
        ))
    }

    func testCarrierAndLocalFailureNeverPenalize() {
        XCTAssertFalse(NodeAdmissionDecision(.carrier(nil))
            .mayPenalizeAuthenticatedSupplier(as: .sameChainCandidate))
        XCTAssertFalse(
            NodeAdmissionDecision(.rejected(.localVerificationFailure))
                .mayPenalizeAuthenticatedSupplier(as: .sameChainCandidate)
        )
    }

    func testTemporalAndTargetMissResultsStayNeutral() {
        let temporal = NodeAdmissionDecision(.rejected(.notYetAdmissible))
        XCTAssertTrue(temporal.shouldRetryLater)
        XCTAssertFalse(temporal.shouldRetryWhenEvidenceChanges)
        XCTAssertFalse(temporal.mayPenalizeAuthenticatedSupplier(
            as: .sameChainCandidate
        ))

        let targetMiss = NodeAdmissionDecision(
            .rejected(.notAcceptedAtCurrentChain)
        )
        XCTAssertEqual(targetMiss, .carrier)
        XCTAssertFalse(targetMiss.mayPenalizeAuthenticatedSupplier(
            as: .sameChainCandidate
        ))
    }
}
