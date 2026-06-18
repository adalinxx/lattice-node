import XCTest
@testable import LatticeNode
import Lattice
import Foundation

/// F5-4 (Hierarchical GHOST): the multi-hop generalization of ChildBlockProof —
/// the path `root → … → block` and the `composing(hop:)` operation a relaying node
/// uses to extend its own `root→self` proof by one level. These pin the pure
/// mechanics (path concat, entry union/dedup, wire round-trip) on every platform;
/// the end-to-end generate/verify against real block trees lives in the
/// Linux-gated ChildBlockProofTests.
final class ChildBlockProofMultiHopTests: XCTestCase {

    func testComposeConcatenatesPathAndUnionsEntries() {
        let upstream = ChildBlockProof(
            rootCID: "root",
            directoryPath: ["Mid"],
            entries: [("root", Data([0x01])), ("midHeader", Data([0x02]))]
        )
        // Mid→Stable hop, rooted at Mid. Shares the "midHeader" entry (dedup) and
        // adds Mid's children expansion + the Stable leaf.
        let hop = ChildBlockProof(
            rootCID: "midHeader",
            directoryPath: ["Stable"],
            entries: [("midHeader", Data([0x02])), ("stableHeader", Data([0x03]))]
        )
        let composed = upstream.composing(hop: hop)

        XCTAssertEqual(composed.rootCID, "root", "root is preserved from the upstream proof")
        XCTAssertEqual(composed.directoryPath, ["Mid", "Stable"], "path is upstream ∘ hop")
        let cids = composed.entries.map { $0.cid }.sorted()
        XCTAssertEqual(cids, ["midHeader", "root", "stableHeader"], "entries are the deduped union")
        XCTAssertEqual(composed.entries.filter { $0.cid == "midHeader" }.count, 1, "shared entry appears once")
    }

    // Compose is inductive: chaining hops extends the path one level each time, to
    // arbitrary depth. root→Mid ∘ Mid→Stable ∘ Stable→Leaf ∘ Leaf→Deep = a 4-level
    // path with all entries unioned — the same operation a relay applies per level,
    // so great-grandchildren and deeper work with no special casing.
    func testComposeChainsToArbitraryDepth() {
        let a = ChildBlockProof(rootCID: "root", directoryPath: ["Mid"], entries: [("root", Data([0]))])
        let b = ChildBlockProof(rootCID: "mid", directoryPath: ["Stable"], entries: [("mid", Data([1]))])
        let c = ChildBlockProof(rootCID: "stable", directoryPath: ["Leaf"], entries: [("stable", Data([2]))])
        let d = ChildBlockProof(rootCID: "leaf", directoryPath: ["Deep"], entries: [("leaf", Data([3]))])

        let composed = a.composing(hop: b).composing(hop: c).composing(hop: d)
        XCTAssertEqual(composed.rootCID, "root", "the absolute PoW root is preserved across all levels")
        XCTAssertEqual(composed.directoryPath, ["Mid", "Stable", "Leaf", "Deep"], "one directory appended per hop")
        XCTAssertEqual(composed.entries.map { $0.cid }.sorted(), ["leaf", "mid", "root", "stable"],
                       "every level's entries accumulate in the union")
    }

    func testSerializeRoundTripMultiHop() {
        let proof = ChildBlockProof(
            rootCID: "bafyROOT",
            directoryPath: ["Mid", "Stable", "Leaf"],
            entries: [("a", Data([0xAA, 0xBB])), ("b", Data()), ("c", Data([0x00, 0x01, 0x02, 0x03]))]
        )
        guard let round = ChildBlockProof.deserialize(proof.serialize()) else {
            return XCTFail("multi-hop proof must round-trip through the wire format")
        }
        XCTAssertEqual(round.rootCID, proof.rootCID)
        XCTAssertEqual(round.directoryPath, proof.directoryPath, "the directory path survives the round-trip")
        XCTAssertEqual(round.entries.count, proof.entries.count)
        for (a, b) in zip(round.entries, proof.entries) {
            XCTAssertEqual(a.cid, b.cid); XCTAssertEqual(a.data, b.data)
        }
    }

    func testSingleHopRoundTrip() {
        // The depth-1 case (a direct child of the PoW root) is just a 1-element path.
        let proof = ChildBlockProof(rootCID: "r", directoryPath: ["SwapTest"], entries: [("r", Data([0x09]))])
        let round = ChildBlockProof.deserialize(proof.serialize())
        XCTAssertEqual(round?.directoryPath, ["SwapTest"])
    }
}
