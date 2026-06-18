import XCTest
@testable import LatticeNode
import Lattice
import cashew
import UInt256
import Foundation

/// Module 5: CID-based candidate bundle. `CandidateBundle` is the CID-only,
/// volume-free description of one merged-mining assembly — reproducibility tooling
/// whose consumer is exactly these tests: they capture a real mined candidate +
/// child by CID, serialize the bundle to a single fixture, replay it byte-for-byte,
/// and pin the structural CID/root validation rules.
final class CandidateBundleTests: XCTestCase {

    /// Build a CandidateBundle from REAL mined block CIDs (genesis parent carrier +
    /// a real child candidate block), JSON-encode then JSON-decode, and assert
    /// equality. Proves a merged-mining assembly is reproducible from one fixture.
    func test_bundleRoundTrip() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let parentCarrier = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        try await storeBlockFixture(parentCarrier, to: f)
        let rootCID = try VolumeImpl<Block>(node: parentCarrier).rawCID

        // A real child candidate block extending the same carrier.
        let childBlock = try await buildRetargetedTestBlock(
            previous: parentCarrier,
            timestamp: timestamp + 1_000,
            nonce: 1,
            fetcher: f
        )
        let childCID = try VolumeImpl<Block>(node: childBlock).rawCID

        // A real, content-addressed CID string for the proof reference (the bundle
        // treats proofCID opaquely; it only needs to be a genuine CID). The child
        // block's spec CID is a real content address derived from real bytes.
        let proofCID = childBlock.spec.rawCID

        let bundle = CandidateBundle(
            rootCandidateCID: rootCID,
            parentCarrierHash: rootCID,
            childCandidates: [
                ChildCandidateRef(
                    chainPath: ["Nexus", "SwapTest"],
                    blockCID: childCID,
                    proofCID: proofCID
                )
            ],
            effectiveTarget: UInt256.max.toHexString()
        )

        let encoded = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(CandidateBundle.self, from: encoded)
        XCTAssertEqual(decoded, bundle)
        // The root is a real, resolvable block CID, not a placeholder.
        XCTAssertEqual(decoded.rootCandidateCID, rootCID)
        XCTAssertEqual(CandidateBundleValidationResult.valid, decoded.validate())
    }

    private func wellFormedBundle(
        childProofCID: String? = "proof-cid",
        childPath: [String] = ["Nexus", "SwapTest"],
        parentCarrierHash: String = "root-cid"
    ) -> CandidateBundle {
        CandidateBundle(
            rootCandidateCID: "root-cid",
            parentCarrierHash: parentCarrierHash,
            childCandidates: [
                ChildCandidateRef(chainPath: childPath, blockCID: "child-cid", proofCID: childProofCID)
            ],
            effectiveTarget: "ff"
        )
    }

    func test_validate_acceptsWellFormedBundle() {
        XCTAssertEqual(CandidateBundleValidationResult.valid, wellFormedBundle().validate())
    }

    func test_validate_rejectsMissingChildProof() {
        let bundle = wellFormedBundle(childProofCID: nil)
        XCTAssertEqual(CandidateBundleValidationResult.invalid(.missingChildProof(["Nexus", "SwapTest"])),
            bundle.validate()
        )
        // …but allowed when proofs aren't required (same-process child).
        XCTAssertEqual(CandidateBundleValidationResult.valid, bundle.validate(requireChildProofs: false))
    }

    func test_validate_rejectsWrongParentCarrierHash() {
        let bundle = wellFormedBundle(parentCarrierHash: "some-other-block")
        XCTAssertEqual(CandidateBundleValidationResult.invalid(.parentCarrierMismatch(declared: "some-other-block", root: "root-cid")),
            bundle.validate()
        )
    }

    func test_validate_rejectsWrongChainPath() {
        // Empty component → ChainAddress rejects → malformedChainPath.
        let malformed = wellFormedBundle(childPath: ["Nexus", ""])
        XCTAssertEqual(CandidateBundleValidationResult.invalid(.malformedChainPath(["Nexus", ""])),
            malformed.validate()
        )
        // Empty path → also malformed.
        XCTAssertEqual(CandidateBundleValidationResult.invalid(.malformedChainPath([])),
            wellFormedBundle(childPath: []).validate()
        )
        // Duplicate child chain paths → duplicateChainPath.
        let dup = CandidateBundle(
            rootCandidateCID: "root-cid",
            parentCarrierHash: "root-cid",
            childCandidates: [
                ChildCandidateRef(chainPath: ["Nexus", "A"], blockCID: "c1", proofCID: "p1"),
                ChildCandidateRef(chainPath: ["Nexus", "A"], blockCID: "c2", proofCID: "p2"),
            ],
            effectiveTarget: "ff"
        )
        XCTAssertEqual(CandidateBundleValidationResult.invalid(.duplicateChainPath(["Nexus", "A"])),
            dup.validate()
        )
    }
}
