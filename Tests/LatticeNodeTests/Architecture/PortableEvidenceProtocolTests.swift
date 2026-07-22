import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private func protocolCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

final class PortableEvidenceProtocolTests: XCTestCase {
    func testChildEvidenceIsOneCompleteContentAddressedVolume() async throws {
        let (envelope, childCID, acquisition) = try await evidenceFixture()
        let childData = try XCTUnwrap(acquisition[childCID])
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            acquisitionEntries: acquisition,
            childCID: childCID
        )
        let broker = MemoryBroker()
        try await attachment.store(storer: BrokerStorer(broker: broker))
        let fetched = await broker.fetchVolumeLocal(root: attachment.rawCID)
        let volume = try XCTUnwrap(fetched)
        try volume.validate()
        XCTAssertEqual(volume.root, attachment.rawCID)
        XCTAssertEqual(volume.entries.count, acquisition.count + 1)
        XCTAssertEqual(volume.entries[childCID], childData)

        let resolved = try ChildEvidenceVolume(
            serialized: volume,
            childCID: childCID
        )
        XCTAssertEqual(resolved.envelopeBytes, envelope)
        XCTAssertEqual(resolved.acquisitionEntries, acquisition)

        let resolvedWithoutExternalHint = try ChildEvidenceVolume(
            serialized: volume
        )
        XCTAssertEqual(resolvedWithoutExternalHint.acquisitionEntries, acquisition)
    }

    func testChildEvidenceRootIsIndependentOfDictionaryOrder() async throws {
        let (envelope, childCID, childEntries) = try await evidenceFixture()
        let extra = PublicKey(key: "shared-evidence-member")
        let extraHeader = try HeaderImpl<PublicKey>(node: extra)
        let extraData = try extraHeader.mapToData()
        let childData = try XCTUnwrap(childEntries[childCID])
        let first = [
            childCID: childData,
            extraHeader.rawCID: extraData,
        ]
        let second = Dictionary(uniqueKeysWithValues: first.reversed())

        let left = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            acquisitionEntries: first,
            childCID: childCID
        )
        let right = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            acquisitionEntries: second,
            childCID: childCID
        )
        XCTAssertEqual(left.rawCID, right.rawCID)
        XCTAssertEqual(left.serialized.entries, right.serialized.entries)
    }

    func testChildEvidenceRejectsMembershipDrift() async throws {
        let (envelope, childCID, acquisition) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            acquisitionEntries: acquisition,
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
        missing.removeValue(forKey: childCID)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: missing
            ),
            childCID: childCID
        ))

        var corrupt = attachment.serialized.entries
        corrupt[childCID]?.append(0)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: corrupt
            ),
            childCID: childCID
        ))
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

        XCTAssertThrowsError(try PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: Array(attachments.dropFirst()),
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

    private func evidenceFixture() async throws
        -> (envelope: Data, childCID: String, entries: [String: Data]) {
        let source = MemoryBroker()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: BrokerStorer(broker: source)
        )
        let block = try await NexusGenesis.create(
            fetcher: BrokerFetcher(broker: source)
        ).block
        let childCID = try BlockHeader(node: block).rawCID
        return (
            Data("envelope".utf8),
            childCID,
            [childCID: try XCTUnwrap(block.toData())]
        )
    }
}
