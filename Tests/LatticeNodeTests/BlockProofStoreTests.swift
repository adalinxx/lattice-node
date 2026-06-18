import XCTest
@testable import LatticeNode
import Foundation

/// F5-4 (Hierarchical GHOST): block sparse work proofs are persisted as block
/// metadata, keyed by block hash and stamped at the block's height so they prune
/// on the same schedule as the block (the historical-retention knob). These pin
/// the StateStore round-trip + height-scoped deletion the retention path relies on.
final class BlockProofStoreTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(storagePath: dir, chain: "Nexus"), dir)
    }

    func testPersistAndFetchByHash() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let proof = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await store.persistBlockProof(height: 7, blockHash: "blockA", proofID: "p1", proof: proof)
        XCTAssertEqual(store.getBlockProofs(blockHash: "blockA"), [proof], "proof round-trips by block hash")
        XCTAssertEqual(store.getBlockProofs(blockHash: "absent"), [], "unknown block ⇒ empty (no proof / is its own anchor)")
    }

    func testStoresMultipleProofPathsAndDedupesByProofID() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.persistBlockProof(height: 1, blockHash: "B", proofID: "path-a", proof: Data([0x01]))
        try await store.persistBlockProof(height: 1, blockHash: "B", proofID: "path-b", proof: Data([0x02]))
        try await store.persistBlockProof(height: 1, blockHash: "B", proofID: "path-a", proof: Data([0x03]))
        XCTAssertEqual(store.getBlockProofs(blockHash: "B"), [Data([0x01]), Data([0x02])],
                       "distinct proof paths are retained; duplicate path IDs are first-wins")
    }

    func testDeleteByHeightPrunesOnlyThatHeight() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.persistBlockProof(height: 10, blockHash: "old", proofID: "p", proof: Data([0xAA]))
        try await store.persistBlockProof(height: 11, blockHash: "keep", proofID: "p", proof: Data([0xBB]))
        try await store.deleteBlockProofs(height: 10)   // tip/retention prune the aged-out height
        XCTAssertEqual(store.getBlockProofs(blockHash: "old"), [], "pruned height's proof is gone")
        XCTAssertEqual(store.getBlockProofs(blockHash: "keep"), [Data([0xBB])], "newer height's proof survives")
    }

    // Historical mode evicts only an orphaned fork's proof; a canonical block's
    // proof at the SAME height must survive (the keep-every-main-chain-proof
    // invariant). Height-scoped deletion would wrongly drop both.
    func testHashScopedDeletePreservesCanonicalAtSameHeight() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.persistBlockProof(height: 5, blockHash: "canonical", proofID: "p", proof: Data([0xC0]))
        try await store.persistBlockProof(height: 5, blockHash: "orphanFork", proofID: "p", proof: Data([0xF0]))
        try await store.deleteBlockProof(height: 5, blockHash: "orphanFork")
        XCTAssertEqual(store.getBlockProofs(blockHash: "orphanFork"), [], "the orphaned fork's proof is evicted")
        XCTAssertEqual(store.getBlockProofs(blockHash: "canonical"), [Data([0xC0])],
                       "the canonical block's proof at the same height is kept")
    }
}
