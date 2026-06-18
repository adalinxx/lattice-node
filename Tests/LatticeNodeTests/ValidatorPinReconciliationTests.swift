import XCTest
import Synchronization
@testable import LatticeNode
import VolumeBroker

/// validator-pin reconciliation — the safety net for the no-halt
/// decision on `deleteValidatorPins`/`releaseValidatorPins` failure. When a
/// release silently fails (surfaced + logged, but not halted on), the broker
/// `validates:<childCID>` pin + StateStore row leak. `reconcileValidatorPins`
/// re-derives the authoritative live set from the chain tip + retention config
/// and reclaims any orphaned pin the prune cycle should already have removed.
///
/// Authoritative live-set rule (mirrors `pruneBlocks`): in `.retention` a pin at
/// `height` is live iff `height > chainTip - retentionDepth`; everything at/below
/// that boundary is supposed to be gone.
///
/// This drives the reclamation invariant through a deterministic StateStore +
/// DiskBroker harness (the same `static reconcileValidatorPins` core the live node
/// calls), so it runs in CI — no live node, no networking, no mining.
final class ValidatorPinReconciliationTests: XCTestCase {

    private let retention: UInt64 = 2

    /// A deterministic harness: a real StateStore + a real (disk-backed, no-network)
    /// DiskBroker, mirroring the per-chain durable pair the node wires up. `tip` stands
    /// in for the canonical chain tip the live method reads from `getHighestBlockHeight`.
    private struct Harness {
        let store: StateStore
        let broker: DiskBroker
        let dir: URL
        let tip: UInt64
    }

    private func makeHarness(tip: UInt64) throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(storagePath: dir, chain: "Nexus")
        let broker = try DiskBroker(path: dir.appendingPathComponent("broker.db").path)
        return Harness(store: store, broker: broker, dir: dir, tip: tip)
    }

    /// Install a validator pin (StateStore row + broker `validates:<childCID>` pin)
    /// at `height`, exactly as the merged-mining apply path would.
    private func installPin(
        _ h: Harness,
        height: UInt64,
        childCID: String,
        nexusCID: String
    ) async throws {
        try await h.store.persistValidatorPin(height: height, childCID: childCID, parentCID: nexusCID)
        try await h.broker.pin(root: nexusCID, owner: "validates:\(childCID)")
    }

    private func reconcile(_ h: Harness) async -> Int {
        await LatticeNode.reconcileValidatorPins(
            store: h.store,
            broker: h.broker,
            chainTip: h.tip,
            retention: .retention,
            retentionDepth: retention,
            label: "Nexus"
        )
    }

    // MARK: - 1. A leaked pin (release silently failed) is reclaimed by reconcile

    func testReconcileReclaimsOrphanedPinAfterSwallowedDeleteFailure() async throws {
        let tip: UInt64 = 5
        let h = try makeHarness(tip: tip)
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let orphanHeight: UInt64 = 1                       // <= boundary (tip - retention)
        let liveHeight = tip                               // > boundary
        let orphanChild = "orphan-child-cid"
        let liveChild = "live-child-cid"
        let orphanNexus = "orphan-nexus-cid"
        let liveNexus = "live-nexus-cid"

        try await installPin(h, height: liveHeight, childCID: liveChild, nexusCID: liveNexus)

        // Simulate the residue: a release at an orphaned height whose
        // `deleteValidatorPins` silently fails, so the row + broker pin leak.
        // Reuse the `_armWriteFault` seam to make the delete throw.
        try await installPin(h, height: orphanHeight, childCID: orphanChild, nexusCID: orphanNexus)
        await h.store._armWriteFault()
        do {
            try await h.store.deleteValidatorPins(height: orphanHeight)
            XCTFail("armed deleteValidatorPins should have thrown")
        } catch {
            // expected — in production this is surfaced + logged, not halted on.
        }
        await h.store._disarmWriteFault()

        // RED precondition: the orphan leaked (row + broker pin both present).
        XCTAssertEqual(h.store.getValidatorParent(childCID: orphanChild), orphanNexus, "orphan row should have leaked")
        var orphanOwners = await h.broker.owners(root: orphanNexus)
        XCTAssertTrue(orphanOwners.contains("validates:\(orphanChild)"), "orphan broker pin should have leaked")

        // Reconcile: re-derive the live set and reclaim the orphan.
        let reclaimed = await reconcile(h)
        XCTAssertEqual(reclaimed, 1, "exactly one orphaned pin-height should be reclaimed")

        // The orphan is gone — both the StateStore row and the broker pin.
        XCTAssertNil(h.store.getValidatorParent(childCID: orphanChild), "orphan row should be released")
        XCTAssertTrue(h.store.getValidatorPins(height: orphanHeight).isEmpty, "orphan height should be empty")
        orphanOwners = await h.broker.owners(root: orphanNexus)
        XCTAssertFalse(orphanOwners.contains("validates:\(orphanChild)"), "orphan broker pin should be released")

        // The live pin (above the boundary) is untouched — the persisted/broker
        // set now equals the re-derived authoritative live set.
        XCTAssertEqual(h.store.getValidatorParent(childCID: liveChild), liveNexus, "live row must survive")
        let liveOwners = await h.broker.owners(root: liveNexus)
        XCTAssertTrue(liveOwners.contains("validates:\(liveChild)"), "live broker pin must survive")
    }

    // MARK: - 2. Idempotent no-op on a healthy store

    func testReconcileNoOpWhenNoOrphans() async throws {
        let tip: UInt64 = 5
        let h = try makeHarness(tip: tip)
        defer { try? FileManager.default.removeItem(at: h.dir) }

        // Only a live pin above the boundary — nothing to reclaim.
        let liveChild = "healthy-child-cid"
        let liveNexus = "healthy-nexus-cid"
        try await installPin(h, height: tip, childCID: liveChild, nexusCID: liveNexus)

        let reclaimed = await reconcile(h)
        XCTAssertEqual(reclaimed, 0, "a healthy store should reclaim nothing")

        // Live pin intact, idempotent across a second run.
        XCTAssertEqual(h.store.getValidatorParent(childCID: liveChild), liveNexus)
        let owners = await h.broker.owners(root: liveNexus)
        XCTAssertTrue(owners.contains("validates:\(liveChild)"))

        let reclaimedAgain = await reconcile(h)
        XCTAssertEqual(reclaimedAgain, 0, "reconcile must be idempotent")
        XCTAssertEqual(h.store.getValidatorParent(childCID: liveChild), liveNexus)
    }

    // MARK: - 3. The retry/recovery invariant across a restart (close/reopen)

    /// A non-destructive broker fault seam: wraps a real `DiskBroker` and conforms to
    /// the same `ValidatorPinReleaser` seam the prune/reconcile core depends on. While
    /// `failUnpin` is set, `unpinAllBatch` THROWS without touching the underlying pins
    /// — so the leaked broker owner stays intact and is reclaimable on a later retry.
    /// Clearing the flag delegates straight through to the real broker.
    ///
    /// This is the key difference from a table-drop fault: dropping `volume_pins` to
    /// force the throw also destroys the broker owner, so a "successful retry" runs
    /// against an emptied table and proves nothing about reclaiming the ORIGINAL owner.
    private final class FailingUnpinBroker: LatticeNode.ValidatorPinReleaser, Sendable {
        let real: DiskBroker
        // Guarded by a Mutex so the type is genuinely Sendable (no @unchecked):
        // the flag is flipped from the test thread and read on the reconcile path.
        private let _failUnpin = Mutex(false)
        init(_ real: DiskBroker) { self.real = real }
        var failUnpin: Bool {
            get { _failUnpin.withLock { $0 } }
            set { _failUnpin.withLock { $0 = newValue } }
        }
        struct InjectedUnpinFailure: Error {}
        func unpinAllBatch(owners: [String]) async throws {
            if failUnpin { throw InjectedUnpinFailure() }
            try await real.unpinAllBatch(owners: owners)
        }
    }

    /// Core invariant, proven across a RESTART. The validator-pin store
    /// rows ARE the durable retry ledger: a broker-unpin failure must leave them intact,
    /// they must SURVIVE a close/reopen of the StateStore + DiskBroker, and then — with
    /// broker availability restored and the ORIGINAL `volume_pins` owner still present —
    /// reconcile must release the broker owner AND delete the rows.
    ///
    /// RED on pre-fix code: the old `try?` swallowed the broker failure and deleted the
    /// rows anyway, so the rows would NOT survive (the post-failure count would be 0).
    /// RED on an emptied-table "retry": the broker owner would already be gone before
    /// recovery, so the "owner released by reconcile" assertion would be vacuous — here
    /// the owner is verified present right up to the reconcile that removes it.
    func testRetryLedgerSurvivesRestartThenReconcileReclaims() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brokerPath = dir.appendingPathComponent("broker.db").path
        let tip: UInt64 = 5
        let orphanHeight: UInt64 = 1                       // <= boundary (tip - retention)

        // ----- Pre-restart: install two orphan-height pins, then fail the release. -----
        do {
            let store = try StateStore(storagePath: dir, chain: "Nexus")
            let broker = try DiskBroker(path: brokerPath)
            let failing = FailingUnpinBroker(broker)

            try await store.persistValidatorPin(height: orphanHeight, childCID: "child-a", parentCID: "nexus-a")
            try await store.persistValidatorPin(height: orphanHeight, childCID: "child-b", parentCID: "nexus-b")
            try await broker.pin(root: "nexus-a", owner: "validates:child-a")
            try await broker.pin(root: "nexus-b", owner: "validates:child-b")

            // Inject a NON-destructive unpin failure: throws without dropping the pins.
            failing.failUnpin = true
            do {
                try await LatticeNode.releaseValidatorPins(store: store, broker: failing, height: orphanHeight)
                XCTFail("releaseValidatorPins must propagate the broker unpin failure, not swallow it")
            } catch {
                // expected — in production this is surfaced + logged, not halted on.
            }

            // The rows survive the in-process failure...
            XCTAssertEqual(store.getValidatorPins(height: orphanHeight).count, 2,
                "rows must survive an in-process broker-unpin failure (they are the retry ledger)")
            // ...and the original broker owners are STILL pinned (non-destructive fault).
            let ownersA = await broker.owners(root: "nexus-a")
            let ownersB = await broker.owners(root: "nexus-b")
            XCTAssertTrue(ownersA.contains("validates:child-a"), "original broker owner must be intact for retry")
            XCTAssertTrue(ownersB.contains("validates:child-b"), "original broker owner must be intact for retry")
            // Drop the connections to force a real close before reopen.
        }

        // ----- Restart: reopen the SAME StateStore + DiskBroker on disk. -----
        let store = try StateStore(storagePath: dir, chain: "Nexus")
        let broker = try DiskBroker(path: brokerPath)

        // The retry ledger SURVIVED the restart: rows are still on disk.
        XCTAssertEqual(store.getValidatorPins(height: orphanHeight).count, 2,
            "validator-pin rows must survive a close/reopen — they are the durable retry ledger")
        XCTAssertEqual(store.getValidatorParent(childCID: "child-a"), "nexus-a")
        XCTAssertEqual(store.getValidatorParent(childCID: "child-b"), "nexus-b")
        // The ORIGINAL broker owners survived too (NOT an emptied/recreated table).
        let survivedA = await broker.owners(root: "nexus-a")
        let survivedB = await broker.owners(root: "nexus-b")
        XCTAssertTrue(survivedA.contains("validates:child-a"),
            "original broker owner must survive the restart for reconcile to reclaim it")
        XCTAssertTrue(survivedB.contains("validates:child-b"))

        // ----- Recovery: broker available again → reconcile reclaims the orphan. -----
        let reclaimed = await LatticeNode.reconcileValidatorPins(
            store: store,
            broker: broker,
            chainTip: tip,
            retention: .retention,
            retentionDepth: retention,
            label: "Nexus"
        )
        XCTAssertEqual(reclaimed, 1, "the single orphaned pin-height must be reclaimed on recovery")

        // (a) The broker owners are released.
        let afterA = await broker.owners(root: "nexus-a")
        let afterB = await broker.owners(root: "nexus-b")
        XCTAssertFalse(afterA.contains("validates:child-a"),
            "reconcile must release the leaked broker owner on recovery")
        XCTAssertFalse(afterB.contains("validates:child-b"))
        // (b) deleteValidatorPins removed the rows.
        XCTAssertTrue(store.getValidatorPins(height: orphanHeight).isEmpty,
            "reconcile must reach the store-delete commit point on a successful broker unpin")
        XCTAssertNil(store.getValidatorParent(childCID: "child-a"))
        XCTAssertNil(store.getValidatorParent(childCID: "child-b"))
    }

    // MARK: - 4. The retry-ledger invariant driven through the REAL prune-path release

    /// `.retention` prune-boundary arithmetic, copied verbatim from `pruneBlocks`
    /// (`LatticeNode+Blocks.swift`, `case .retention`): an accepted block at
    /// `tipHeight` releases validator pins at `tipHeight - retentionDepth` whenever
    /// `tipHeight > retentionDepth`. The test computes the pin height from the tip the
    /// same way the production prune path does, so the release fires because the tip
    /// crossed the retention boundary past the pinned height — not because a test
    /// poked the release method at an arbitrary height.
    private func pruneReleaseHeight(tipHeight: UInt64, retentionDepth: UInt64) -> UInt64? {
        guard tipHeight > retentionDepth else { return nil }
        return tipHeight - retentionDepth
    }

    /// Reviewer-requested coverage (PR #147 / #116 / #149): prove the validator-pin
    /// retry-ledger invariant through the SAME release primitive the real
    /// `pruneBlocks` retention path executes — `LatticeNode.releaseValidatorPins(store:
    /// broker:height:)`, reached via `pruneBlocks → releaseValidatorPins(directory:
    /// height:network:)` — at the height the prune path itself derives from the tip
    /// crossing the retention boundary, NOT through any `*ForTesting` shim.
    ///
    /// Flow:
    ///   1. Seed a validator pin at height `H` via the `persistValidatorPin` store
    ///      primitive + `broker.pin(owner: "validates:<childCID>")` (the apply/install
    ///      path was dead-code-removed in 7a2d48b, so we seed directly).
    ///   2. Advance the tip past the retention boundary so the prune path's own
    ///      arithmetic (`pruneReleaseHeight`) selects exactly `H` for release.
    ///   3. Run that release primitive with a NON-DESTRUCTIVE `unpinAllBatch` failure
    ///      injected (the `FailingUnpinBroker` seam: throws without dropping the pin).
    ///   4. Close/reopen the StateStore + DiskBroker; assert BOTH the `validator_pins`
    ///      row AND the broker owner survive (they are the durable retry ledger).
    ///   5. Run the real reconcile/maintenance path; assert BOTH are cleared ONLY after
    ///      the broker unpin succeeds.
    ///
    /// RED on pre-fix code: the old release swallowed the broker failure with `try?`
    /// and deleted the row anyway, so step 4 would find the row already gone (count 0).
    /// The non-destructive fault guarantees the broker owner is verified present right
    /// up to the reconcile that removes it, so step 5's "released by reconcile"
    /// assertion is not vacuous.
    func testRealPrunePathReleaseKeepsRetryLedgerOnBrokerFailureThenReconcileReclaims() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brokerPath = dir.appendingPathComponent("broker.db").path

        // A pin seeded at this height...
        let pinHeight: UInt64 = 3
        // ...is released by the prune path when the tip reaches pinHeight + retentionDepth.
        let tipHeight = pinHeight + retention
        // The prune path's own arithmetic must select exactly the seeded height.
        XCTAssertEqual(
            pruneReleaseHeight(tipHeight: tipHeight, retentionDepth: retention), pinHeight,
            "the retention-boundary crossing at tip \(tipHeight) must release exactly height \(pinHeight)"
        )

        // ----- 1+2: seed the pin, then drive the real prune-path release with a fault. -----
        do {
            let store = try StateStore(storagePath: dir, chain: "Nexus")
            let broker = try DiskBroker(path: brokerPath)
            let failing = FailingUnpinBroker(broker)

            // Seed via the StateStore primitive + broker.pin (install path removed in 7a2d48b).
            try await store.persistValidatorPin(height: pinHeight, childCID: "child-x", parentCID: "nexus-x")
            try await broker.pin(root: "nexus-x", owner: "validates:child-x")

            // 3: run the SAME release the prune path runs, at the prune-derived height,
            // with a non-destructive broker-unpin failure injected.
            let releaseHeight = try XCTUnwrap(pruneReleaseHeight(tipHeight: tipHeight, retentionDepth: retention))
            failing.failUnpin = true
            do {
                try await LatticeNode.releaseValidatorPins(store: store, broker: failing, height: releaseHeight)
                XCTFail("the prune-path release must propagate the broker unpin failure, not swallow it")
            } catch {
                // expected — production surfaces + logs this, does not halt (no-halt).
            }

            // The row survives the in-process failure; the broker owner is untouched.
            XCTAssertEqual(store.getValidatorPins(height: pinHeight).count, 1,
                "the prune-path release must keep the row as the retry ledger on broker failure")
            let owners = await broker.owners(root: "nexus-x")
            XCTAssertTrue(owners.contains("validates:child-x"),
                "the non-destructive fault must leave the broker owner intact for retry")
        }

        // ----- 4: restart — reopen the SAME store + broker on disk. -----
        let store = try StateStore(storagePath: dir, chain: "Nexus")
        let broker = try DiskBroker(path: brokerPath)

        XCTAssertEqual(store.getValidatorPins(height: pinHeight).count, 1,
            "validator_pins row must survive a close/reopen — it is the durable retry ledger")
        XCTAssertEqual(store.getValidatorParent(childCID: "child-x"), "nexus-x")
        let survived = await broker.owners(root: "nexus-x")
        XCTAssertTrue(survived.contains("validates:child-x"),
            "the broker owner must survive the restart for reconcile to reclaim it")

        // ----- 5: recovery — reconcile (real maintenance path) clears BOTH only on broker success. -----
        let reclaimed = await LatticeNode.reconcileValidatorPins(
            store: store,
            broker: broker,
            chainTip: tipHeight,
            retention: .retention,
            retentionDepth: retention,
            label: "Nexus"
        )
        XCTAssertEqual(reclaimed, 1, "reconcile must reclaim the single orphaned pin-height on recovery")

        let after = await broker.owners(root: "nexus-x")
        XCTAssertFalse(after.contains("validates:child-x"),
            "reconcile must release the leaked broker owner once the unpin succeeds")
        XCTAssertTrue(store.getValidatorPins(height: pinHeight).isEmpty,
            "reconcile must delete the row ONLY after the broker unpin succeeds")
        XCTAssertNil(store.getValidatorParent(childCID: "child-x"))
    }
}
