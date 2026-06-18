import Foundation
import Ivy
import LatticeNodeWire
import XCTest
@testable import LatticeNode
import Lattice

final class P2PWireFuzzTargetTests: XCTestCase {
    func testCommittedCorpusReplaysWithoutCrashing() throws {
        let corpus = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("FuzzCorpus/P2PWire")
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
        XCTAssertFalse(files.isEmpty, "requires a committed P2P wire fuzz corpus")

        for file in files {
            P2PWireFuzzTarget.exercise(try Data(contentsOf: file))
        }
    }

    func testStructuredSeedsHitProductionWireParsers() {
        P2PWireFuzzTarget.exercise(Data("block-cid".utf8))

        var inlineBlock = Data()
        var cidLen = UInt16(3).littleEndian
        inlineBlock.append(Data(bytes: &cidLen, count: 2))
        inlineBlock.append(Data("cid".utf8))
        inlineBlock.append(Data([0xaa]))
        XCTAssertEqual(NetworkWireCodecs.parseNewBlockPayload(inlineBlock)?.cid, "cid")
        P2PWireFuzzTarget.exercise(inlineBlock)

        let malformedInlineBlock = Data("abc".utf8)
        XCTAssertNil(NetworkWireCodecs.parseNewBlockPayload(malformedInlineBlock))
        P2PWireFuzzTarget.exercise(malformedInlineBlock)

        let announcement = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 1,
            tipCID: "tip",
            specCID: "spec"
        ).serialize()
        XCTAssertNotNil(ChainAnnounceData.deserialize(announcement))
        P2PWireFuzzTarget.exercise(announcement)

        let mempool = ChainNetwork.encodeMempoolFullPayload(
            cid: "tx",
            bodyData: Data([0x01]),
            transactionData: Data([0x02])
        )
        XCTAssertNotNil(NetworkWireCodecs.decodeMempoolFullPayload(mempool))
        P2PWireFuzzTarget.exercise(mempool)

        var headerRequest = Data(repeating: 0xaa, count: 16)
        var fromLen = UInt16(4).littleEndian
        headerRequest.append(Data(bytes: &fromLen, count: 2))
        headerRequest.append(Data("from".utf8))
        var count = UInt32(2).littleEndian
        headerRequest.append(Data(bytes: &count, count: 4))
        XCTAssertEqual(NetworkWireCodecs.parseHeaderRequestPayload(headerRequest)?.fromCID, "from")
        P2PWireFuzzTarget.exercise(headerRequest)

        // headerBatch / headerBatch2 responses (canonical fail-closed codec).
        var headerBatch = Data(repeating: 0xbb, count: 16)
        var numHeaders = UInt32(1).littleEndian
        headerBatch.append(Data(bytes: &numHeaders, count: 4))
        var entryCIDLen = UInt16(3).littleEndian
        headerBatch.append(Data(bytes: &entryCIDLen, count: 2))
        headerBatch.append(Data("cid".utf8))
        var entryDataLen = UInt32(2).littleEndian
        headerBatch.append(Data(bytes: &entryDataLen, count: 4))
        headerBatch.append(Data([0x01, 0x02]))
        XCTAssertEqual(NetworkWireCodecs.parseHeaderBatch(headerBatch, maxHeaders: 1_000)?.first?.cid, "cid")
        P2PWireFuzzTarget.exercise(headerBatch)

        var headerBatch2 = headerBatch
        var proofLen = UInt32(1).littleEndian
        headerBatch2.append(Data(bytes: &proofLen, count: 4))
        headerBatch2.append(Data([0xcc]))
        XCTAssertEqual(NetworkWireCodecs.parseHeaderBatch2(headerBatch2, maxHeaders: 1_000)?.first?.proof, Data([0xcc]))
        P2PWireFuzzTarget.exercise(headerBatch2)

        // Truncated headerBatch2 must reject WHOLE (the extractor's old twin
        // parser returned a truncated prefix here).
        let truncated = headerBatch2.dropLast(1)
        XCTAssertNil(NetworkWireCodecs.parseHeaderBatch2(truncated, maxHeaders: 1_000))
        P2PWireFuzzTarget.exercise(Data(truncated))
    }

    /// `childBlockDeclaredProofLength` must read the `proofLen` header
    /// field straight from the raw childBlock wire bytes — the value the gossip
    /// handler bounds BEFORE `parseChildBlockPayload` copies the proof body — so it
    /// must equal the proof length the full parser recovers, and must read the
    /// DECLARED length even when the frame is too short to actually carry it (the
    /// case that lets the handler reject an oversized declared proof without first
    /// allocating the oversized copy). Returns nil only when the prefix is absent.
    func testChildBlockDeclaredProofLengthMatchesParserAndReadsHeaderOnly() {
        func encode(proofLen: UInt32, proof: Data, cid: String, block: Data) -> Data {
            var payload = Data()
            var len = proofLen.littleEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(proof)
            let cidBytes = Data(cid.utf8)
            var cidLen = UInt16(cidBytes.count).littleEndian
            payload.append(Data(bytes: &cidLen, count: 2))
            payload.append(cidBytes)
            payload.append(block)
            return payload
        }

        let proof = ChildBlockProofEnvelope.serialize([
            ChildBlockProof(rootCID: "root", directoryPath: ["Child"], entries: [(cid: "entry", data: Data([0xab]))])
        ])
        let wellFormed = encode(proofLen: UInt32(proof.count), proof: proof, cid: "cid", block: Data([0x01, 0x02]))
        XCTAssertEqual(NetworkWireCodecs.childBlockDeclaredProofLength(wellFormed), proof.count)
        XCTAssertEqual(NetworkWireCodecs.parseChildBlockPayload(wellFormed)?.proofData?.count, proof.count)

        // Declared length far exceeds the actual frame: the peek still returns the
        // DECLARED value (so the handler can reject before copying), while the full
        // parser refuses the frame outright.
        let oversizeDeclared = encode(proofLen: 1_000_000, proof: proof, cid: "cid", block: Data([0x01]))
        XCTAssertEqual(NetworkWireCodecs.childBlockDeclaredProofLength(oversizeDeclared), 1_000_000)
        XCTAssertNil(NetworkWireCodecs.parseChildBlockPayload(oversizeDeclared))

        // Too short to carry the [proofLen:4] prefix -> nil.
        XCTAssertNil(NetworkWireCodecs.childBlockDeclaredProofLength(Data(repeating: 0x00, count: 3)))
    }
}

private enum P2PWireFuzzTarget {
    static let maxInputBytes = 1 << 20

    static func exercise(_ payload: Data) {
        guard payload.count <= maxInputBytes else { return }
        _ = Message.deserialize(payload)
        NetworkWireCodecs.exerciseParserSurface(payload)
        _ = ChainAnnounceData.deserialize(payload)
    }
}
