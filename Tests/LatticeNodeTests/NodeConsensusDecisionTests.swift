import XCTest
@testable import Lattice
@testable import LatticeNode
import Tally

final class NodeConsensusDecisionTests: XCTestCase {
    func testEveryChainLocalOutcomeHasDistinctNodeMeaning() {
        let cases: [(ChainLocalBlockResult, NodeConsensusDecision)] = [
            (.canonicalized(.empty), .canonicalized),
            (.acceptedSide(.empty), .acceptedSide),
            (.duplicate, .duplicate),
            (.unavailable, .unavailable),
            (.invalid, .invalid),
            (.storageFailed, .storageFailed),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(NodeConsensusDecision(input), expected)
        }
    }

    func testValidityAndCanonicityRemainSeparate() {
        let canonical = NodeConsensusDecision.acceptedSide

        XCTAssertTrue(canonical.isValidAdmission)
        XCTAssertFalse(canonical.shouldPublishCanonicalTip)
        XCTAssertFalse(canonical.mayPenalizeSupplyingPeer)
    }

    func testAvailabilityIsNotInvalidity() {
        let unavailable = NodeConsensusDecision.unavailable

        XCTAssertFalse(unavailable.isValidAdmission)
        XCTAssertTrue(unavailable.shouldRetryWhenAvailabilityChanges)
        XCTAssertFalse(unavailable.mayPenalizeSupplyingPeer)
        XCTAssertEqual(
            unavailable.attributedPeerObservation,
            .localFailure(.validationUnavailable)
        )
    }

    func testLocalStorageFailureCannotPenalizePeer() {
        let storage = NodeConsensusDecision.storageFailed

        XCTAssertFalse(storage.mayPenalizeSupplyingPeer)
        XCTAssertEqual(
            storage.attributedPeerObservation,
            .localFailure(.storageUnavailable)
        )
    }

    func testOnlyProtocolInvalidityProducesRemoteFailureObservation() {
        XCTAssertEqual(
            NodeConsensusDecision.invalid.attributedPeerObservation,
            .remoteFailure(.invalidEvidence)
        )
        XCTAssertEqual(
            NodeConsensusDecision.canonicalized.attributedPeerObservation,
            .responseSucceeded()
        )
        XCTAssertEqual(
            NodeConsensusDecision.acceptedSide.attributedPeerObservation,
            .responseSucceeded()
        )
        XCTAssertEqual(
            NodeConsensusDecision.duplicate.attributedPeerObservation,
            .responseSucceeded()
        )
    }
}
