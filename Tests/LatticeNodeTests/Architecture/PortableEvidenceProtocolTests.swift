import Ivy
import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private func protocolCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

final class PortableEvidenceProtocolTests: XCTestCase {
    func testChildEvidenceIsACompleteContentAddressedDAG() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let broker = MemoryBroker()
        try await attachment.store(storer: broker)
        let fetched = await broker.fetchVolumeLocal(root: attachment.rawCID)
        let volume = try XCTUnwrap(fetched)
        try volume.validate()
        XCTAssertEqual(volume.root, attachment.rawCID)
        // A real DAG: the header node plus one entry per proof CAS node — not a
        // single flattened blob.
        XCTAssertGreaterThan(volume.entries.count, 1)
        XCTAssertNotNil(volume.entries[attachment.rawCID], "header present")

        let resolved = try ChildEvidenceVolume(
            serialized: volume,
            childCID: childCID
        )
        XCTAssertEqual(resolved.envelopeBytes, envelope)

        let resolvedWithoutExternalHint = try ChildEvidenceVolume(
            serialized: volume
        )
        XCTAssertEqual(resolvedWithoutExternalHint.envelopeBytes, envelope)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: volume,
            childCID: protocolCID("wrong-child")
        ))
    }

    func testChildEvidenceRootCommitsItsExactProofAndChild() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let left = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let right = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        XCTAssertEqual(left.rawCID, right.rawCID)
        XCTAssertEqual(left.serialized.entries, right.serialized.entries)
        // A different proof (different entry set) commits to a different root.
        let differentEnvelope = try ChildValidationPackageEnvelope(
            proof: evidenceProof(entryCount: 4)
        ).encode()
        XCTAssertNotEqual(
            left.rawCID,
            try ChildEvidenceVolume(
                envelopeBytes: differentEnvelope,
                childCID: childCID
            ).rawCID
        )
        // A different child commits to a different root.
        XCTAssertNotEqual(
            left.rawCID,
            try ChildEvidenceVolume(
                envelopeBytes: envelope,
                childCID: protocolCID("another-child")
            ).rawCID
        )
        // A corrupted envelope is rejected outright (not silently re-rooted).
        XCTAssertThrowsError(try ChildEvidenceVolume(
            envelopeBytes: envelope + Data([0]),
            childCID: childCID
        ))
    }

    func testChildEvidenceRejectsMembershipDrift() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let extra = PublicKey(key: "uncommitted-evidence-member")
        let extraHeader = try HeaderImpl<PublicKey>(node: extra)
        var withExtra = attachment.serialized.entries
        withExtra[extraHeader.rawCID] = try extraHeader.mapToData()
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: withExtra
            ),
            childCID: childCID
        ))

        var missing = attachment.serialized.entries
        missing.removeValue(forKey: attachment.rawCID)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: missing
            ),
            childCID: childCID
        ))

        var corrupt = attachment.serialized.entries
        corrupt[attachment.rawCID]?.append(0)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: corrupt
            ),
            childCID: childCID
        ))
    }

    func testEvidenceMemberBudgetAdmitsTheMultiEntryDAG() async throws {
        // The DAG is always header + >=1 proof node, so the network fetch's
        // per-volume member budget MUST exceed 1 — a stale `maximumMembers: 1`
        // silently drops the whole volume on cross-node fetch (the local-broker
        // tests can't see it). Guard the invariant the recover sites depend on.
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        XCTAssertGreaterThan(attachment.serialized.entries.count, 1)
        XCTAssertLessThanOrEqual(
            attachment.serialized.entries.count,
            ChildEvidenceVolume.maximumMembers
        )
        XCTAssertGreaterThanOrEqual(ChildEvidenceVolume.maximumMembers, 2)
    }

    func testLargeMultiHopProofIsNotWedgedByTheFrameSize() async throws {
        // A proof whose entries SUM past one Ivy frame — the old single-blob
        // format threw `.oversized` at ~4 MiB and wedged the child chain here.
        // As a cashew DAG each node stays small and the total rides the
        // operator budget, so it builds, stores, round-trips, and re-resolves.
        let frame = Int(IvyConfig.defaultProtocolMaxFrameSize)
        // Six entries at ~frame/4 each: total > one frame (the old wedge), each
        // node well under a frame.
        let proof = try evidenceProof(entryCount: 6, perEntryBytes: frame / 4)
        let envelope = try ChildValidationPackageEnvelope(proof: proof).encode()
        XCTAssertGreaterThan(envelope.count, frame,
            "fixture must exceed one frame to exercise the old wedge")
        let childCID = protocolCID("child")
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        // Each stored node stays under a frame; the whole DAG rides the budget.
        for (_, data) in attachment.serialized.entries {
            XCTAssertLessThan(data.count, frame)
        }
        let total = attachment.serialized.entries.values.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(total, frame)
        XCTAssertLessThanOrEqual(total, ChildEvidenceVolume.maximumArchiveBytes)
        let broker = MemoryBroker()
        try await attachment.store(storer: broker)
        let maybeFetched = await broker.fetchVolumeLocal(root: attachment.rawCID)
        let fetched = try XCTUnwrap(maybeFetched)
        let resolved = try ChildEvidenceVolume(serialized: fetched, childCID: childCID)
        XCTAssertEqual(resolved.envelopeBytes, envelope)
        XCTAssertEqual(resolved.proof.entries.count, 6)
        XCTAssertEqual(resolved.rawCID, attachment.rawCID)
    }

    func testPortableAttachmentTopicsStayOnOverlay() {
        for topic in [
            NodeNetworkTopic.portableAttachmentAvailable,
            NodeNetworkTopic.portableAttachmentIndexRequest,
            NodeNetworkTopic.portableAttachmentIndexResponse,
        ] {
            XCTAssertEqual(NodeNetworkTopic.plane(for: topic), .overlay)
        }
    }

    func testParentChainFactsAreExactSessionBoundQueries() throws {
        let genesis = ParentChainFactMessage(
            requestID: 1,
            fact: .genesis(
                childGenesisCID: protocolCID("child-genesis"),
                parentStateCID: protocolCID("deployment-parent-state")
            )
        )
        XCTAssertEqual(
            try ParentChainFactMessage.decoded(genesis.encoded()),
            genesis
        )

        let continuity = ParentChainFactMessage(
            requestID: 2,
            fact: .continuity(
                fromStateCID: protocolCID("from-state"),
                toStateCID: protocolCID("to-state")
            )
        )
        XCTAssertEqual(
            try ParentChainFactMessage.decoded(continuity.encoded()),
            continuity
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.parentChainFactRequest),
            .hierarchy
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.parentChainFactResponse),
            .hierarchy
        )

        XCTAssertThrowsError(try ParentChainFactMessage(
            requestID: 0,
            fact: genesis.fact
        ).encoded())
        XCTAssertThrowsError(try ParentChainFactMessage(
            requestID: 4,
            fact: .continuity(
                fromStateCID: protocolCID("same-state"),
                toStateCID: protocolCID("same-state")
            )
        ).encoded())
    }

    func testChildCandidateReservationSnapshotIsCanonicalAndBounded() throws {
        let childPath = ["Nexus", "Payments"]
        let candidates = (0..<ChildCandidateReservationRequestMessage
            .maximumCandidateCIDs)
            .map { protocolCID("reserved-child-\($0)") }
            .sorted()
        let request = ChildCandidateReservationRequestMessage(
            requestID: 7,
            childPath: childPath,
            candidateCIDs: candidates
        )
        XCTAssertEqual(
            try ChildCandidateReservationRequestMessage.decoded(request.encoded()),
            request
        )
        let release = ChildCandidateReservationRequestMessage(
            requestID: 8,
            childPath: childPath,
            candidateCIDs: []
        )
        XCTAssertEqual(
            try ChildCandidateReservationRequestMessage.decoded(release.encoded()),
            release
        )

        let response = ChildCandidateReservationResponseMessage(
            requestID: request.requestID,
            childPath: childPath,
            accepted: true
        )
        XCTAssertEqual(
            try ChildCandidateReservationResponseMessage.decoded(
                response.encoded()
            ),
            response
        )
        for topic in [
            NodeNetworkTopic.childCandidateReservationRequest,
            NodeNetworkTopic.childCandidateReservationResponse,
        ] {
            XCTAssertEqual(NodeNetworkTopic.plane(for: topic), .hierarchy)
        }
    }

    func testChildCandidateReservationSnapshotRejectsMalformedWire() throws {
        let childPath = ["Nexus", "Payments"]
        let first = protocolCID("reserved-child-a")
        let second = protocolCID("reserved-child-b")
        let sorted = [first, second].sorted()
        for candidateCIDs in [
            [sorted[1], sorted[0]],
            [sorted[0], sorted[0]],
            ["not-a-canonical-cid"],
            (0...ChildCandidateReservationRequestMessage.maximumCandidateCIDs)
                .map { protocolCID("too-many-reserved-children-\($0)") }
                .sorted(),
        ] {
            XCTAssertThrowsError(try ChildCandidateReservationRequestMessage(
                requestID: 1,
                childPath: childPath,
                candidateCIDs: candidateCIDs
            ).encoded()) { error in
                XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
            }
        }

        XCTAssertThrowsError(try ChildCandidateReservationRequestMessage(
            requestID: 0,
            childPath: childPath,
            candidateCIDs: []
        ).encoded())
        XCTAssertThrowsError(try ChildCandidateReservationResponseMessage(
            requestID: 1,
            childPath: ["Nexus"],
            accepted: false
        ).encoded())

        let oversized = Data(
            repeating: 0,
            count: Int(IvyConfig.defaultProtocolMaxFrameSize)
        )
        XCTAssertThrowsError(
            try ChildCandidateReservationRequestMessage.decoded(oversized)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .oversized)
        }

        var nonCanonical = try ChildCandidateReservationRequestMessage(
            requestID: 1,
            childPath: childPath,
            candidateCIDs: sorted
        ).encoded()
        nonCanonical.append(0x20)
        XCTAssertThrowsError(
            try ChildCandidateReservationRequestMessage.decoded(nonCanonical)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testPortableAttachmentVocabularyIsCanonicalAndCursorBound() throws {
        let attachments = [
            PortableAttachmentSummary(
                edgeCID: protocolCID("portable-edge-a"),
                rootCID: protocolCID("portable-root-a"),
                attachmentCID: protocolCID("portable-attachment-a")
            ),
            PortableAttachmentSummary(
                edgeCID: protocolCID("portable-edge-b"),
                rootCID: protocolCID("portable-root-b"),
                attachmentCID: protocolCID("portable-attachment-b")
            ),
            PortableAttachmentSummary(
                edgeCID: protocolCID("portable-edge-c"),
                rootCID: protocolCID("portable-root-c"),
                attachmentCID: protocolCID("portable-attachment-c")
            ),
        ].sorted {
            ($0.edgeCID, $0.rootCID) < ($1.edgeCID, $1.rootCID)
        }
        let cursor = attachments[0]
        let page = [attachments[1]]

        let indexRequest = PortableAttachmentIndexRequestMessage(
            requestID: 1,
            after: cursor
        )
        XCTAssertEqual(
            try PortableAttachmentIndexRequestMessage.decoded(
                indexRequest.encoded()
            ),
            indexRequest
        )

        let indexResponse = PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: page,
            hasMore: true
        )
        XCTAssertEqual(
            try PortableAttachmentIndexResponseMessage.decoded(
                indexResponse.encoded()
            ),
            indexResponse
        )

        let available = PortableAttachmentAvailableMessage(
            edgeCID: page[0].edgeCID,
            rootCID: page[0].rootCID,
            attachmentCID: page[0].attachmentCID
        )
        XCTAssertEqual(
            try PortableAttachmentAvailableMessage.decoded(available.encoded()),
            available
        )

        // Over the page cap throws — built cap-relative so it survives page-size
        // changes (canonical CIDs distinct per index so the entries stay sorted
        // and unique, the other bounds validate() enforces).
        let overCap = (0...PortableAttachmentIndexResponseMessage.maximumEntries)
            .map { i in
                PortableAttachmentSummary(
                    edgeCID: protocolCID("overcap-edge-\(i)"),
                    rootCID: protocolCID("overcap-root-\(i)"),
                    attachmentCID: protocolCID("overcap-attachment-\(i)")
                )
            }
            .sorted { ($0.edgeCID, $0.rootCID) < ($1.edgeCID, $1.rootCID) }
        XCTAssertThrowsError(try PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: overCap,
            hasMore: false
        ).encoded())
        XCTAssertThrowsError(try PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: [],
            hasMore: true
        ).encoded())
        XCTAssertThrowsError(try PortableAttachmentAvailableMessage(
            edgeCID: "not-a-canonical-cid",
            rootCID: page[0].rootCID,
            attachmentCID: page[0].attachmentCID
        ).encoded())

        var nonCanonical = try available.encoded()
        nonCanonical.append(0x20)
        XCTAssertThrowsError(
            try PortableAttachmentAvailableMessage.decoded(nonCanonical)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testPortableAttachmentLocateRequestIsCanonicalAndCIDBound() throws {
        let request = PortableAttachmentLocateRequestMessage(
            requestID: 9,
            childCID: protocolCID("locate-child")
        )
        XCTAssertEqual(
            try PortableAttachmentLocateRequestMessage.decoded(request.encoded()),
            request
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(
                for: NodeNetworkTopic.portableAttachmentLocateRequest
            ),
            .overlay
        )
        XCTAssertThrowsError(try PortableAttachmentLocateRequestMessage(
            requestID: 0,
            childCID: protocolCID("locate-child")
        ).encoded())
        XCTAssertThrowsError(try PortableAttachmentLocateRequestMessage(
            requestID: 9,
            childCID: "not-a-canonical-cid"
        ).encoded())

        var nonCanonical = try request.encoded()
        nonCanonical.append(0x20)
        XCTAssertThrowsError(
            try PortableAttachmentLocateRequestMessage.decoded(nonCanonical)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    private struct EvidenceBlob: Scalar { let bytes: Data }

    /// A real content-addressed CAS entry: (rawCID, canonical bytes). Passes
    /// SerializedVolume's per-entry content-address check.
    private func contentEntry(bytes: Data) throws -> (cid: String, data: Data) {
        let header = try HeaderImpl<EvidenceBlob>(node: EvidenceBlob(bytes: bytes))
        return (header.rawCID, try header.mapToData())
    }

    private func evidenceProof(
        entryCount: Int = 3,
        perEntryBytes: Int = 8
    ) throws -> ChildBlockProof {
        let entries = try (0..<entryCount).map { i in
            try contentEntry(
                bytes: Data("entry-\(i)-".utf8)
                    + Data(repeating: UInt8(i & 0xff), count: perEntryBytes)
            )
        }
        return ChildBlockProof(
            rootCID: protocolCID("proof-root"),
            directoryPath: ["dir"],
            entries: entries
        )
    }

    private func evidenceFixture() async throws
        -> (envelope: Data, childCID: String) {
        let envelope = try ChildValidationPackageEnvelope(
            proof: evidenceProof()
        ).encode()
        return (envelope, protocolCID("child"))
    }
}
