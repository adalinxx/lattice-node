import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import Tally

/// (H8): `didReceiveChildBlock` must apply the same front-of-path guards
/// the `newBlock` gossip path uses BEFORE doing any relay-triggering work
/// (disk write + pin + DHT announce + broadcast-to-all-including-sender).
/// Without them a child block ping-pongs A→B→A indefinitely.
///
/// These drive the real relay-decision function (`childBlockRelayGate`) directly
/// — the same gate `didReceiveChildBlock` calls — so they run in CI without any
/// TCP / multi-node E2E setup.
final class ChildBlockRelayGateTests: XCTestCase {

    private func makeNode() async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        return try await LatticeNode(config: config, genesisConfig: testGenesis())
    }

    /// (a) A duplicate childBlock CID seen again inside the dedup window is NOT
    /// re-admitted, so it is never relayed/announced a second time.
    func testDuplicateChildBlockIsNotRelayedTwice() async throws {
        let node = try await makeNode()
        let peer = PeerID(publicKey: "child-relay-peer")
        let cid = "bafychildblockduplicate0000000000000000000000"

        let now = ContinuousClock.Instant.now
        let first = await node.childBlockRelayGate(cid: cid, peer: peer, now: now)
        XCTAssertEqual(first, .admit, "first sighting of a childBlock must be admitted for relay")

        // The dedup window is primed only AFTER the payload parses + CID matches —
        // i.e. once the bytes are confirmed to genuinely be this CID's block. The
        // gate itself is a pure check and must not record.
        await node.recordChildBlockSeen(cid: cid, now: now)

        // Second sighting within the 100ms dedup window: must be suppressed so the
        // relay (disk write + pin + announce + broadcast) does not re-fire.
        let secondNow = now + .milliseconds(10)
        let second = await node.childBlockRelayGate(cid: cid, peer: peer, now: secondNow)
        XCTAssertEqual(second, .duplicate, "a duplicate childBlock inside the dedup window must NOT be relayed again")
    }

    /// DoS regression (external review on PR #170): the gate must NOT prime the
    /// dedup window. A forged/mismatched packet under a real CID — which never
    /// reaches `recordChildBlockSeen` because parse/`blockCIDMatches` rejects it —
    /// must not cause the subsequent VALID packet for that CID to be dropped as a
    /// `.duplicate`. I.e. unvalidated bytes can never suppress the real block.
    func testGateCheckDoesNotPrimeDedup() async throws {
        let node = try await makeNode()
        let attacker = PeerID(publicKey: "child-relay-attacker")
        let honest = PeerID(publicKey: "child-relay-honest-victim")
        let cid = "bafychildblockcontested00000000000000000000000"

        let now = ContinuousClock.Instant.now

        // Attacker's forged packet hits the gate first. `didReceiveChildBlock`
        // would parse it and find `blockCIDMatches` false, so it NEVER calls
        // `recordChildBlockSeen`. The gate check alone must leave the window unprimed.
        let attackerOutcome = await node.childBlockRelayGate(cid: cid, peer: attacker, now: now)
        XCTAssertEqual(attackerOutcome, .admit,
            "the gate is a pure check and must admit (validation happens after, in the receive path)")
        // Forged bytes are rejected at parse/CID-match, so the window stays unprimed —
        // recordChildBlockSeen is intentionally NOT called here.

        // The real block now arrives from an honest peer a few ms later. It must
        // still be admitted (and then relayed), not dropped as a duplicate.
        let honestOutcome = await node.childBlockRelayGate(cid: cid, peer: honest, now: now + .milliseconds(10))
        XCTAssertEqual(honestOutcome, .admit,
            "a forged/mismatched packet must NOT prime the dedup window and suppress the real block")
    }

    /// (b) A single-peer flood of distinct childBlock CIDs is throttled by the
    /// per-peer rate limit before any of them reach broadcast.
    func testOnePeerFloodIsRateLimitedBeforeBroadcast() async throws {
        let node = try await makeNode()
        let flooder = PeerID(publicKey: "child-relay-flooder")
        let now = ContinuousClock.Instant.now

        // Each CID is distinct (so dedup never fires) — only the per-peer rate
        // limit can stop the flood. maxBlocksPerPeerPerWindow admits a bounded
        // number; everything past the cap in the same window is rejected.
        var admitted = 0
        var rateLimited = 0
        let attempts = LatticeNode.maxBlocksPerPeerPerWindow + 50
        for i in 0..<attempts {
            let cid = "bafychildflood\(i)"
            switch await node.childBlockRelayGate(cid: cid, peer: flooder, now: now) {
            case .admit: admitted += 1
            case .rateLimited: rateLimited += 1
            case .duplicate: XCTFail("distinct CIDs must never be deduped")
            }
        }

        XCTAssertEqual(admitted, LatticeNode.maxBlocksPerPeerPerWindow,
            "the per-peer rate limit must cap admissions at maxBlocksPerPeerPerWindow within one window")
        XCTAssertGreaterThan(rateLimited, 0,
            "a one-peer flood must be throttled (rejected) before broadcast once the per-peer cap is hit")
    }

    /// A different peer is unaffected by another peer's exhausted budget — the
    /// rate limit is per-peer, not global, so honest peers still get through.
    func testRateLimitIsPerPeer() async throws {
        let node = try await makeNode()
        let flooder = PeerID(publicKey: "child-relay-flooder-2")
        let honest = PeerID(publicKey: "child-relay-honest")
        let now = ContinuousClock.Instant.now

        for i in 0...(LatticeNode.maxBlocksPerPeerPerWindow + 10) {
            _ = await node.childBlockRelayGate(cid: "bafyflood-b\(i)", peer: flooder, now: now)
        }

        let honestOutcome = await node.childBlockRelayGate(cid: "bafyhonest-distinct", peer: honest, now: now)
        XCTAssertEqual(honestOutcome, .admit,
            "an honest peer must still be admitted even after another peer floods")
    }
}
