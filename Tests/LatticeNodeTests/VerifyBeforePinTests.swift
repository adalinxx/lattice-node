import XCTest
import Foundation
import Ivy
import VolumeBroker
@testable import Lattice
@testable import LatticeNode

/// Adversarial tests for the VERIFY-BEFORE-PIN availability invariant:
///
///   "A Volume is verified complete + correct BEFORE it is pinned; an
///    incomplete/unverified bundle must never become pin-reachable (and thus
///    never servable)."
///
/// The serve plane is gated by pin-reachability (`volumeData` returns [] for an
/// unpinned root in DiskBroker mode). The two production facts under attack:
///
///   - `ChainNetwork.storeSyncedBlock(cid:data:)` (ChainNetwork+Gossip.swift)
///     persists the header BYTES durably but DOES NOT pin — a pin is a
///     commitment to serve a closure we have not yet verified complete.
///   - The verified pin is taken later in
///     `materializeSyncedCanonicalContent → pinBatchDurably(...)`
///     (LatticeNode+Sync.swift), only AFTER content resolution/validation.
///
/// So between store-local and verify, the bytes must be fetchable by CID
/// locally (headers-first sync walks them; they survive a restart) yet the
/// root must NOT be pin-reachable and the volume responder must serve nothing.
///
/// All tests are unit-level: a standalone `ChainNetwork` (never started — no
/// TCP), a temp-sqlite `DiskBroker`, and an `Ivy` constructed but never started
/// (connectedPeers == []). Deterministic and CI-safe.
final class VerifyBeforePinTests: XCTestCase {

    // MARK: - Fixtures (mirrors AdversarialAvailabilityTests; intentionally
    // self-contained so this suite does not depend on that file.)

    private func noPeerIvy() -> Ivy {
        let kp = CryptoUtils.generateKeyPair()
        return Ivy(config: IvyConfig(
            publicKey: kp.publicKey,
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            stunServers: []
        ))
    }

    private func tempDiskBroker() throws -> DiskBroker {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)
    }

    /// Standalone ChainNetwork in LOCAL mode (durableBroker === sharedDiskBroker,
    /// so the pin-reachability serve gate is active). Never started — no TCP.
    private func makeNetwork() async throws -> ChainNetwork {
        let disk = try tempDiskBroker()
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - 1. Synced header bytes persisted but NOT pinned

    /// ATTACK: drive the real `storeSyncedBlock` path and demand it pin so the
    /// stub becomes servable. It must NOT: the header bytes are fetchable by CID
    /// locally (headers-first sync walks them), but the root is not
    /// pin-reachable and the volume responder serves nothing — the bare-root
    /// stub is reclaimable, never advertised.
    func test_syncedHeaderBytesPersistedButNotPinned() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let cid = "vbp1-synced-header"
        let headerBytes = bytes("synced-header-node")

        await network.storeSyncedBlock(cid: cid, data: headerBytes)

        // The bytes ARE durably persisted: fetchable by CID locally (the
        // per-CID responder resolves the durable root-keyed grouping).
        let byCID = await network.data(for: cid)
        XCTAssertEqual(byCID, headerBytes,
            "Synced header bytes must be persisted and fetchable by CID locally for headers-first walk + restart survival")

        // …but the root is NOT pinned, so NOT pin-reachable.
        let reachable = await disk.isPinReachable(cid: cid)
        XCTAssertFalse(reachable,
            "storeSyncedBlock must NOT pin — a pre-verification header stub must not become pin-reachable")
        let owners = await disk.owners(root: cid)
        XCTAssertTrue(owners.isEmpty,
            "storeSyncedBlock must take no pin owner on the synced header — got \(owners)")

        // …and therefore the volume responder serves nothing (verify-before-pin:
        // an unverified bundle must never be servable).
        let served = await network.volumeData(for: cid, cids: [])
        XCTAssertTrue(served.isEmpty,
            "An unpinned, unverified synced header must not be served as a volume — got \(served.count) entries")
    }

    // MARK: - 2. Incomplete bundle (bare-root grouping, no pin) is never served

    /// ATTACK: stash a bare-root grouping durably WITHOUT a pin — exactly the
    /// shape an in-flight, not-yet-verified sync bundle has — and ask the node
    /// to serve it. The gate must refuse: a node never serves an unpinned,
    /// unverified grouping.
    func test_incompleteBundleNeverServed() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let root = "vbp2-bare-root"
        // A single-entry (bare-root) grouping: the unverified stub, no closure.
        try await network.storeVolumeDurably(SerializedVolume(root: root, entries: [root: bytes("bare-root-node")]))

        // Precondition: bytes are present durably but nothing pins the root.
        let reachable = await disk.isPinReachable(cid: root)
        XCTAssertFalse(reachable,
            "Precondition: an unpinned durable grouping must not be pin-reachable")

        let served = await network.volumeData(for: root, cids: [])
        XCTAssertTrue(served.isEmpty,
            "An unpinned, unverified bundle must never be served — verify-before-pin gate must refuse it; got \(served.count) entries")
    }

    // MARK: - 3. Positive control: a pinned closure IS served in full

    /// Verify-before-pin must not break the legitimate path: once a full,
    /// verified closure is durably stored AND its root pinned (the commitment
    /// `materializeSyncedCanonicalContent` makes after validation), the volume
    /// responder serves the entire closure.
    func test_pinnedClosureIsServed() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let root = "vbp3-root"
        let closure = [
            root: bytes("root-node"),
            "vbp3-a": bytes("entry-a"),
            "vbp3-b": bytes("entry-b")
        ]
        try await network.storeVolumeDurably(SerializedVolume(root: root, entries: closure))
        // The verified pin — exactly what pinBatchDurably takes after resolve().
        try await network.pinBatchDurably(roots: [root], owner: "Nexus:0")

        let reachable = await disk.isPinReachable(cid: root)
        XCTAssertTrue(reachable,
            "A verified, pinned closure root must be pin-reachable")

        let served = await network.volumeData(for: root, cids: [])
        XCTAssertEqual(Set(served.map(\.cid)), Set(closure.keys),
            "A verified, pinned closure must serve its full grouping (legitimate path must not regress)")
        for (cid, data) in served {
            XCTAssertEqual(data, closure[cid], "Served bytes for \(cid) must match stored bytes")
        }
    }

    // MARK: - 4. Pin-reachability only via an explicit pin, never a side effect

    /// ATTACK: store bytes durably through every non-pinning local-store seam
    /// (`storeVolumeDurably`, `storeSyncedBlock`) and assert NONE of them flips
    /// pin-reachability — a grouping becomes pin-reachable ONLY via an explicit
    /// pin call, never as a side effect of a fetch/store-local. Then the
    /// explicit pin (and only it) flips the gate.
    func test_pinReachabilityOnlyViaExplicitPinNeverAsStoreSideEffect() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker

        // Seam A: storeVolumeDurably (the durable store-local path).
        let rootA = "vbp4-storeDurably"
        try await network.storeVolumeDurably(SerializedVolume(root: rootA, entries: [rootA: bytes("a")]))
        let reachableA_afterStore = await disk.isPinReachable(cid: rootA)
        XCTAssertFalse(reachableA_afterStore,
            "storeVolumeDurably must not pin as a side effect")

        // Seam B: storeSyncedBlock (the headers-first sync store path).
        let rootB = "vbp4-storeSynced"
        await network.storeSyncedBlock(cid: rootB, data: bytes("b"))
        let reachableB_afterStore = await disk.isPinReachable(cid: rootB)
        XCTAssertFalse(reachableB_afterStore,
            "storeSyncedBlock must not pin as a side effect")

        // Only the explicit pin flips reachability — and only for its own root.
        try await network.pinBatchDurably(roots: [rootA], owner: "Nexus:0")
        let reachableA_afterPin = await disk.isPinReachable(cid: rootA)
        XCTAssertTrue(reachableA_afterPin,
            "An explicit pin must make exactly its root pin-reachable")
        let reachableB_afterPinA = await disk.isPinReachable(cid: rootB)
        XCTAssertFalse(reachableB_afterPinA,
            "Pinning rootA must not make the unpinned rootB pin-reachable")
    }
}
