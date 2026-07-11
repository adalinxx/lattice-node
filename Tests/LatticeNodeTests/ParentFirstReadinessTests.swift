import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew

/// P1-3 parent-first readiness gate (re-review). `autoFollowAnnouncedChildren` must not
/// spawn descendants while this (parent) chain is far behind the best tip a peer has
/// advertised — otherwise the child outruns the parent and its blocks anchor to carriers
/// the parent hasn't synced. But the gate applies ONLY when there is peer-tip data to
/// judge against: a chain fed via PARENT-EXTRACTION (embedded in parent carriers, not peer
/// sync) records no peer tip, so the caught-up test must be SKIPPED for it (else the
/// recursion defers forever — the exact regression this test guards against). These lock
/// in the two predicates the gate is built from, driven deterministically against a fresh
/// node whose local tip is genesis (height 0).
final class ParentFirstReadinessTests: XCTestCase {

    private func makeNode() async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        return node
    }

    /// No advertised peer tip ⇒ the gate has nothing to measure and must NOT apply
    /// (`hasKnownPeerTip == false`), so a parent-extraction-fed child is never deferred
    /// forever. This is the guard against the recursion regression.
    func testNoPeerTipSkipsGate() async throws {
        let node = try await makeNode()
        defer { Task { await node.stop() } }
        let has = await node.hasKnownPeerTip(directory: "Nexus")
        XCTAssertFalse(has, "with no advertised peer tip the caught-up gate must be skipped")
    }

    /// A peer far ahead of our local tip (0) ⇒ NOT caught up ⇒ the gate defers spawning
    /// descendants. This is the reviewer's scenario (middle at height 1, peer at 1000).
    func testFarBehindPeerIsNotCaughtUp() async throws {
        let node = try await makeNode()
        defer { Task { await node.stop() } }
        await node.recordPeerTip(directory: "Nexus", peerKey: "peerFar", tipCID: "cidFar", height: 1000)
        let hasTip = await node.hasKnownPeerTip(directory: "Nexus")
        XCTAssertTrue(hasTip)
        let caughtUp = await node.chainCaughtUpToBestKnownPeer(directory: "Nexus")
        XCTAssertFalse(caughtUp, "local height 0 vs peer 1000 → behind → gate defers")
    }

    /// A peer within tolerance of our local tip (0) ⇒ caught up ⇒ the gate allows spawning.
    /// A live chain is never EXACTLY at tip, hence the tolerance.
    func testWithinToleranceIsCaughtUp() async throws {
        let node = try await makeNode()
        defer { Task { await node.stop() } }
        await node.recordPeerTip(directory: "Nexus", peerKey: "peerNear", tipCID: "cidNear", height: 2)
        let caughtUp = await node.chainCaughtUpToBestKnownPeer(directory: "Nexus", tolerance: 2)
        XCTAssertTrue(caughtUp, "local 0 + tolerance 2 ≥ peer 2 → caught up → gate allows")
    }

    /// The MAX advertised tip governs: a far peer keeps us "behind" even alongside a near one.
    func testBestPeerTipDominates() async throws {
        let node = try await makeNode()
        defer { Task { await node.stop() } }
        await node.recordPeerTip(directory: "Nexus", peerKey: "peerNear", tipCID: "cidNear", height: 1)
        await node.recordPeerTip(directory: "Nexus", peerKey: "peerFar", tipCID: "cidFar", height: 1000)
        let caughtUp = await node.chainCaughtUpToBestKnownPeer(directory: "Nexus")
        XCTAssertFalse(caughtUp, "the MAX advertised tip (1000) governs → still behind")
    }
}
