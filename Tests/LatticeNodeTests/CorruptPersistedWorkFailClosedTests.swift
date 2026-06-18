import XCTest
@testable import LatticeNode
import Lattice
import UInt256
import Foundation

// CFC-A3 : the node restart guard must fail closed when a persisted
// chain snapshot carries corrupted (present-but-undecodable) block target.
// Without the guard, ChainState.restore/resetFrom maps such a target to
// UInt256.zero work, silently understating the chain's accumulated work and
// inviting a spurious fork. LatticeNode.init consults
// `persistedHasUndecodableTarget` and, when true, throws
// NodeError.corruptPersistedChainState (reindex-or-halt) instead. (init only
// throws — markChainUnhealthy/`self` aren't available yet at this point.)
//
// This pins the guard's decision contract — the load-bearing predicate the
// init startup path branches on.
final class CorruptPersistedWorkFailClosedTests: XCTestCase {

    private func persisted(blocks: [PersistedBlockMeta], tip: String) -> PersistedChainState {
        PersistedChainState(
            chainTip: tip, tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: nil, tipTimestamp: nil,
            mainChainHashes: blocks.map { $0.blockHash }, blocks: blocks,
            parentChainMap: [:], missingBlockHashes: []
        )
    }

    func testPresentButUndecodableTargetIsFlagged() {
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: ["A"], target: UInt256(1000).toHexString(),
            timestamp: 1, cumulativeWork: nil
        )
        // Present but not valid hex — corruption.
        let a = PersistedBlockMeta(
            blockHash: "A", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [], target: "zzz-not-hex",
            timestamp: 2, cumulativeWork: nil
        )
        let snapshot = persisted(blocks: [g, a], tip: "A")
        XCTAssertTrue(LatticeNode.persistedHasUndecodableTarget(snapshot),
            "present-but-undecodable target must fail the startup guard (markChainUnhealthy / reindex)")
    }

    func testAllDecodableTargetIsAccepted() {
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: ["A"], target: UInt256(1000).toHexString(),
            timestamp: 1, cumulativeWork: nil
        )
        let a = PersistedBlockMeta(
            blockHash: "A", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [], target: UInt256(2048).toHexString(),
            timestamp: 2, cumulativeWork: nil
        )
        let snapshot = persisted(blocks: [g, a], tip: "A")
        XCTAssertFalse(LatticeNode.persistedHasUndecodableTarget(snapshot),
            "a snapshot whose every target decodes is not corrupt")
    }

    func testNilTargetIsNotCorruption() {
        // Pre-prefix-sum / sync-produced blocks legitimately omit target.
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: [], target: nil,
            timestamp: 1, cumulativeWork: nil
        )
        let snapshot = persisted(blocks: [g], tip: "G")
        XCTAssertFalse(LatticeNode.persistedHasUndecodableTarget(snapshot),
            "a nil target is legitimately absent, not corruption")
    }

    // MARK: - Real entry point: LatticeNode.init must fail closed

    /// Drives the named entry point (resetFrom/restore at node restart) end to
    /// end: build a node, mine, persist, then corrupt a persisted block's
    /// target on disk and re-init over the same storage. The startup guard
    /// must throw `NodeError.corruptPersistedChainState` (reindex-or-halt) rather
    /// than silently restoring onto a UInt256.zero-work tip. This exercises the
    /// actual init throw, not just the predicate it branches on.
    func testNodeInitFailsClosedOnCorruptPersistedTarget() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storagePath = tmpDir.appendingPathComponent("node")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        func makeConfig() -> LatticeNodeConfig {
            LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: storagePath,
                enableLocalDiscovery: false,
                retentionDepth: 100,
                storageMode: .stateful,
                blockRetention: .retention, minPeerKeyBits: 0
            )
        }
        let genesis = testGenesis()

        // First boot: mine a couple of blocks and persist a healthy snapshot.
        let node = try await LatticeNode(config: makeConfig(), genesisConfig: genesis)
        try await node.start()
        try await mineBlocks(2, on: node)
        await node.stop()

        // Corrupt the persisted chain_state.json: replace one block's target
        // hex with a present-but-undecodable string. This is the exact corruption
        // ChainState.restore/resetFrom would silently map to UInt256.zero work.
        let stateFile = storagePath.appendingPathComponent("Nexus").appendingPathComponent("chain_state.json")
        let raw = try Data(contentsOf: stateFile)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]], "persisted blocks array")
        XCTAssertGreaterThanOrEqual(blocks.count, 1, "need at least one persisted block to corrupt")
        // Corrupt the first block that actually carries a target string.
        var corrupted = false
        for i in blocks.indices where blocks[i]["target"] is String {
            blocks[i]["target"] = "zzz-not-hex"
            corrupted = true
            break
        }
        XCTAssertTrue(corrupted, "a persisted block must carry a target string to corrupt")
        json["blocks"] = blocks
        let patched = try JSONSerialization.data(withJSONObject: json)
        try patched.write(to: stateFile)

        // Second boot over the corrupt snapshot: init must fail closed.
        do {
            let restarted = try await LatticeNode(config: makeConfig(), genesisConfig: genesis)
            await restarted.stop()
            XCTFail("init must throw on corrupt persisted target, not restore onto a zeroed tip")
        } catch let error as NodeError {
            guard case .corruptPersistedChainState = error else {
                return XCTFail("expected .corruptPersistedChainState, got \(error)")
            }
            // fail-closed at the choke point — correct.
        }
    }
}
