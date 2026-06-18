import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import Foundation

/// BIP125-style replace-by-fee. A same-(sender,nonce)
/// replacement is accepted only if it (1) pays for the whole conflicting
/// same-sender package (replaced tx + evicted higher-nonce descendants) plus a
/// bump, (2) introduces no new state-key conflict, and (3) inherits the
/// replaced entry's `addedAt` (no expiry-clock reset). Mempool ADMISSION
/// policy, not consensus. Drives the REAL `NodeMempool.addTransaction`.
final class MempoolBIP125RBFTests: XCTestCase {

    private func tx(_ w: Wallet, fee: UInt64, nonce: UInt64) -> Transaction {
        w.buildTransfer(to: w.address, amount: 1, fee: fee, nonce: nonce)!
    }

    /// A tx whose body touches a GENERAL state key — `StateKeySet.from` records
    /// `actions[*].key` into `general`, and `isDisjoint` (unlike accounts) does
    /// NOT exclude general keys, so two txs sharing a general key conflict.
    private func keyedTx(_ w: Wallet, key: String, fee: UInt64, nonce: UInt64) -> Transaction {
        w.buildActionTransaction(
            actions: [Action(key: key, oldValue: nil, newValue: "v")],
            fee: fee,
            nonce: nonce
        )!
    }

    /// (b1) The replacement must out-pay the FULL conflicting package, not just
    /// the single replaced tx. Sender S has nonce0 fee=100 and nonce1 fee=100
    /// (nonce1 is a higher-nonce descendant the replacement evicts → package
    /// fee 200). Replacing nonce0 at fee=150 clears the single-tx bump (111) but
    /// underpays the package (200 + bump 11 = 211) → rejected. At fee=250 it
    /// covers the package + bump → replaced.
    func testReplacementMustPayForConflictingPackage() async {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 64)
        let s = Wallet.create()

        let nonce0 = tx(s, fee: 100, nonce: 0)
        let nonce1 = tx(s, fee: 100, nonce: 1)
        guard case .added = await mempool.addTransaction(nonce0) else { return XCTFail("nonce0 admit") }
        guard case .added = await mempool.addTransaction(nonce1) else { return XCTFail("nonce1 admit") }

        // fee=150: > single-tx bump (111) but < package+bump (211) → rejected.
        let underPackage = tx(s, fee: 150, nonce: 0)
        switch await mempool.addTransaction(underPackage) {
        case .rejected: break
        default: XCTFail("replacement underpaying the conflicting package must be rejected")
        }
        // The original package is untouched after the rejected replacement.
        let stillOriginal = await mempool.contains(txCID: nonce0.body.rawCID)
        XCTAssertTrue(stillOriginal, "rejected replacement must not evict the resident")
        let countAfterReject = await mempool.count
        XCTAssertEqual(countAfterReject, 2, "no descendant dropped on a rejected replacement")

        // fee=250: covers package (200) + bump (11) → replaced. The evicted
        // descendant (nonce1) is dropped as part of the package replacement.
        let coversPackage = tx(s, fee: 250, nonce: 0)
        switch await mempool.addTransaction(coversPackage) {
        case .replacedExisting(let oldCID):
            XCTAssertEqual(oldCID, nonce0.body.rawCID)
        default:
            XCTFail("replacement covering the conflicting package must replace")
        }
        let oldGone = await mempool.contains(txCID: nonce0.body.rawCID)
        let newHere = await mempool.contains(txCID: coversPackage.body.rawCID)
        let descendantGone = await mempool.contains(txCID: nonce1.body.rawCID)
        XCTAssertFalse(oldGone, "replaced nonce0 evicted")
        XCTAssertTrue(newHere, "replacement resident")
        XCTAssertFalse(descendantGone, "the evicted higher-nonce descendant is dropped")
        let fees = await mempool.totalFees()
        XCTAssertEqual(fees, 250, "no double-count: only the replacement's fee remains")
    }

    /// (b2) RBF carries over the REPLACED entry's `addedAt` — repeated bumps can't
    /// evade `pruneExpired`. Add nonce0 at t0; bump it; then prune with an age
    /// between 0 and (now − t0). If the clock had been reset to .now the bumped
    /// tx would survive; because addedAt is preserved it is evicted (count==0).
    func testRBFPreservesAddedAt() async {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 64)
        let s = Wallet.create()

        let original = tx(s, fee: 100, nonce: 0)
        guard case .added = await mempool.addTransaction(original) else { return XCTFail("original admit") }

        // Let real wall-clock time elapse so the original is measurably aged.
        try? await Task.sleep(nanoseconds: 50_000_000)   // 50ms

        // Bump (single tx, no descendants): fee 100 → 250 clears bump 111.
        let bumped = tx(s, fee: 250, nonce: 0)
        switch await mempool.addTransaction(bumped) {
        case .replacedExisting: break
        default: XCTFail("bump must replace")
        }
        let before = await mempool.count
        XCTAssertEqual(before, 1, "bump replaced, did not add")

        // Prune anything older than 10ms. The bumped entry inherited the
        // original's (>50ms-old) addedAt, so it is evicted.
        await mempool.pruneExpired(olderThan: .milliseconds(10))
        let after = await mempool.count
        XCTAssertEqual(after, 0, "RBF preserved addedAt → bumped tx is pruned, proving no clock reset")
    }

    /// (b3) The replacement must NOT introduce a state-key conflict against a
    /// DIFFERENT-sender resident that the replaced tx did not already have.
    /// Resident R (sender B) owns general key "shared:k". Sender A's original
    /// nonce0 touches an UNRELATED key, so it does not conflict with R. A bump of
    /// A's nonce0 that suddenly grabs "shared:k" would wedge in a conflict R is
    /// powerless to avoid → the bump is rejected even though it clears the fee
    /// bump, and the original resident is untouched.
    func testRBFRejectsNewStateKeyConflict() async {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 64)
        let a = Wallet.create()
        let b = Wallet.create()

        // Different-sender resident owning the contested key.
        let resident = keyedTx(b, key: "shared:k", fee: 100, nonce: 0)
        guard case .added = await mempool.addTransaction(resident) else { return XCTFail("resident admit") }

        // A's original nonce0 touches an unrelated key → no conflict with R.
        let original = keyedTx(a, key: "a:own", fee: 100, nonce: 0)
        guard case .added = await mempool.addTransaction(original) else { return XCTFail("original admit") }

        // Bump clears the fee bump (250 >= 100+11) but grabs R's key → rejected
        // on the new-state-key-conflict gate, not on fee.
        let conflictingBump = keyedTx(a, key: "shared:k", fee: 250, nonce: 0)
        switch await mempool.addTransaction(conflictingBump) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("state-key conflict"), "wrong rejection reason: \(reason)")
        default:
            XCTFail("a bump introducing a new cross-sender state-key conflict must be rejected")
        }
        // The original resident survives the rejected bump (no eviction).
        let originalStillHere = await mempool.contains(txCID: original.body.rawCID)
        XCTAssertTrue(originalStillHere, "rejected conflicting bump must not evict the resident")
        let countAfter = await mempool.count
        XCTAssertEqual(countAfter, 2, "no entry added or dropped on the rejected bump")
    }

    /// (b3 inverse) A bump that reuses ONLY keys the replaced package already
    /// owned — i.e. introduces no NEW conflict — is allowed even though it shares
    /// a general key with the very tx it replaces. Sender A's nonce0 owns
    /// "a:own"; the bump owns the same "a:own" and no other contested key, so it
    /// conflicts with nothing the replaced tx didn't already conflict with.
    func testRBFAllowsReuseOfReplacedPackageKeys() async {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 64)
        let a = Wallet.create()
        let b = Wallet.create()

        // Unrelated different-sender resident on its own key — never contested.
        let resident = keyedTx(b, key: "b:own", fee: 100, nonce: 0)
        guard case .added = await mempool.addTransaction(resident) else { return XCTFail("resident admit") }

        let original = keyedTx(a, key: "a:own", fee: 100, nonce: 0)
        guard case .added = await mempool.addTransaction(original) else { return XCTFail("original admit") }

        // Bump reuses only "a:own" (the replaced tx's own key) → no new conflict.
        let cleanBump = keyedTx(a, key: "a:own", fee: 250, nonce: 0)
        switch await mempool.addTransaction(cleanBump) {
        case .replacedExisting(let oldCID):
            XCTAssertEqual(oldCID, original.body.rawCID)
        default:
            XCTFail("a bump reusing only the replaced package's own keys must be allowed")
        }
        let originalGone = await mempool.contains(txCID: original.body.rawCID)
        let bumpHere = await mempool.contains(txCID: cleanBump.body.rawCID)
        let finalCount = await mempool.count
        XCTAssertFalse(originalGone, "replaced tx evicted")
        XCTAssertTrue(bumpHere, "bump resident")
        XCTAssertEqual(finalCount, 2, "resident + bump")
    }
}
