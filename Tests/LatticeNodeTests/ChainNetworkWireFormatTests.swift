import XCTest
@testable import LatticeNode
import Lattice
import LatticeNodeWire
import OrderedCollections
import UInt256

final class ChainNetworkWireFormatTests: XCTestCase {
    func testMempoolFullPayloadUsesLittleEndianLengths() {
        let cid = "tx-cid"
        let body = Data([0xaa, 0xbb, 0xcc])
        let tx = Data([0x01, 0x02])

        let payload = ChainNetwork.encodeMempoolFullPayload(
            cid: cid,
            bodyData: body,
            transactionData: tx
        )

        XCTAssertEqual(Array(payload.prefix(2)), [UInt8(cid.utf8.count), 0x00])
        let bodyLenOffset = 2 + cid.utf8.count
        XCTAssertEqual(Array(payload[bodyLenOffset..<(bodyLenOffset + 4)]), [0x03, 0x00, 0x00, 0x00])

        let decoded = ChainNetwork.decodeMempoolFullPayload(payload)
        XCTAssertEqual(decoded?.cid, cid)
        XCTAssertEqual(decoded?.bodyData, body)
        XCTAssertEqual(decoded?.transactionData, tx)
    }

    /// (L2): the `gossipTransaction` tx-relay wire format must write its
    /// `cidLen` (UInt16) and `bodyLen` (UInt32) length prefixes little-endian so
    /// big-endian hosts decode the same bytes the LE reader expects. The existing
    /// test uses single-byte lengths where every high byte is 0x00 — a
    /// BE/LE flip is invisible there. This uses multi-byte lengths so the layout
    /// is unambiguous: it would fail if either field were written big-endian.
    func testGossipTransactionLengthPrefixesAreLittleEndian() {
        // cid 258 bytes -> cidLen 0x0102; body 513 bytes -> bodyLen 0x0000_0201.
        let cid = String(repeating: "c", count: 0x0102)
        let body = Data(repeating: 0xab, count: 0x0201)
        let tx = Data([0x07, 0x08, 0x09])

        let payload = ChainNetwork.encodeMempoolFullPayload(
            cid: cid,
            bodyData: body,
            transactionData: tx
        )

        // cidLen: UInt16 LE -> low byte first.
        XCTAssertEqual(Array(payload.prefix(2)), [0x02, 0x01],
            "cidLen must be little-endian (low byte first); BE would be [0x01, 0x02]")

        // bodyLen: UInt32 LE -> low byte first, immediately after cid bytes.
        let bodyLenOffset = 2 + cid.utf8.count
        XCTAssertEqual(Array(payload[bodyLenOffset..<(bodyLenOffset + 4)]), [0x01, 0x02, 0x00, 0x00],
            "bodyLen must be little-endian (low byte first); BE would be [0x00, 0x00, 0x02, 0x01]")

        // Round-trip through the real reader the gossip path uses.
        let decoded = ChainNetwork.decodeMempoolFullPayload(payload)
        XCTAssertEqual(decoded?.cid, cid)
        XCTAssertEqual(decoded?.bodyData, body)
        XCTAssertEqual(decoded?.transactionData, tx)
    }

    func testNewBlockFramingSingleSource() {
        let cid = "bafy-test-block"
        let data = Data([0xde, 0xad, 0xbe, 0xef])

        let payload = ChainNetwork.encodeBlockPayload(cid: cid, data: data)

        XCTAssertEqual(Array(payload.prefix(2)), [UInt8(cid.utf8.count), 0x00])
        XCTAssertEqual(String(data: payload[2..<(2 + cid.utf8.count)], encoding: .utf8), cid)
        XCTAssertEqual(Data(payload[(2 + cid.utf8.count)...]), data)

        let decoded = ChainNetwork.decodeBlockPayload(payload)
        XCTAssertEqual(decoded?.cid, cid)
        XCTAssertEqual(decoded?.data, data)
        XCTAssertEqual(payload, ChainNetwork.encodeBlockPayload(cid: cid, data: data))
    }

    func testChildBlockProofEnvelopeCanonicalizesWireOrder() {
        let proofA = ChildBlockProof(
            rootCID: "root-b",
            directoryPath: ["Child"],
            entries: [
                (cid: "z", data: Data([0x02])),
                (cid: "a", data: Data([0x01])),
            ]
        )
        let proofB = ChildBlockProof(
            rootCID: "root-a",
            directoryPath: ["Child"],
            entries: [(cid: "b", data: Data([0x03]))]
        )

        let left = ChildBlockProofEnvelope.serialize([proofA, proofB])
        let right = ChildBlockProofEnvelope.serialize([proofB, proofA])

        XCTAssertEqual(left, right)
        let decoded = ChildBlockProofEnvelope.deserialize(left)
        XCTAssertEqual(decoded?.map(\.canonicalProofID), [proofB.canonicalized, proofA.canonicalized].map(\.canonicalProofID).sorted())
        XCTAssertEqual(decoded?.first?.entries.map(\.cid), ["b"])
        XCTAssertEqual(decoded?.last?.entries.map(\.cid), ["a", "z"])
    }

    func testRecentTxCIDEvictsOldestTimestampNotInsertionOrder() {
        let base = ContinuousClock.Instant.now
        var recent: OrderedDictionary<String, ContinuousClock.Instant> = [
            "A": base,
            "B": base + .seconds(1),
        ]
        recent["A"] = base + .seconds(2)
        recent["C"] = base + .seconds(3)

        ChainNetwork.evictRecentTxCIDs(&recent, limit: 2)

        XCTAssertNotNil(recent["A"], "refreshed A should remain in the recent set")
        XCTAssertNil(recent["B"], "oldest timestamp should be evicted even when it was not inserted first")
        XCTAssertNotNil(recent["C"])
    }
}
