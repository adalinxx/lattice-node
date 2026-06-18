import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import Foundation

/// `pruneExpired` must be sub-quadratic even when every resident
/// shares the same fee-rate (fees clustered at the floor). The pre-fix removal
/// path removed expired entries ONE AT A TIME — each `removeEntry` did an O(n)
/// array splice AND an O(n) tail reindex — so pruning k of n entries was O(k·n)
/// (≈ O(n²) when k ≈ n). The batched `pruneExpired` collects all doomed CIDs and
/// does a SINGLE `removeAll(where:)` splice + one `rebuildIndex()`, which is
/// O(n + k·log n).
///
/// The machine-check measures the ACTUAL dominant work: `lastRemovalScanSteps`
/// counts every `indexByCID` write a reindex performs (plus any fallback
/// equal-tier comparison). Under the old per-entry loop that total is the sum of
/// the shrinking tails reindexed on each of the k removals — ≈ k·n/2 ≈ N²/2
/// index writes. Under the batched path it is a single O(n) rebuild pass. The
/// bound below (c·N·log₂N) fails for the quadratic and passes for the batch.
final class MempoolPruneComplexityTests: XCTestCase {

    /// Fill maxSize=N entries at IDENTICAL fee (one giant equal-rate tier), age
    /// them all past the cutoff, then prune them all. The batched `pruneExpired`
    /// does ONE `removeAll(where:)` splice + one `rebuildIndex()` over the
    /// survivors (here 0) → O(N) predicate work and ≈0 index writes. The pre-fix
    /// per-entry loop reindexed the array tail on EACH of the N removals →
    /// ≈ N²/2 index writes, which `lastRemovalScanSteps` now faithfully counts.
    /// The bound c·N·log₂N passes for the batch and fails for the quadratic.
    func testPruneExpiredIsNotQuadratic() async {
        let n = 4096
        let mempool = NodeMempool(maxSize: n, maxPerAccount: 1)

        // Distinct senders, identical fee → identical fee-rate (addresses are
        // fixed-length, so bodies serialize to the same length). All land in one
        // equal-rate tier — the worst case for the old per-entry tail reindex.
        for _ in 0..<n {
            let w = Wallet.create()
            let tx = w.buildTransfer(to: w.address, amount: 1, fee: 1000, nonce: 0)!
            guard case .added = await mempool.addTransaction(tx) else {
                return XCTFail("seed admit must succeed")
            }
        }
        let filled = await mempool.count
        XCTAssertEqual(filled, n, "mempool must be full of equal-rate entries")

        // Let wall-clock advance so every entry is older than the cutoff, then
        // prune everything (olderThan .zero → cutoff == now, all past entries go).
        // This is deterministic regardless of how long seeding took.
        try? await Task.sleep(nanoseconds: 5_000_000)
        await mempool.resetRemovalScanSteps()
        await mempool.pruneExpired(olderThan: .zero)

        let remaining = await mempool.count
        XCTAssertEqual(remaining, 0, "all aged entries pruned")

        let steps = await mempool.removalScanSteps()
        // Bound: c · N · log₂(N) with a generous c=4. log2(4096)=12 → 4*4096*12.
        // Batched prune: one rebuildIndex over 0 survivors ≈ 0 index writes.
        // Per-entry loop (regression): ≈ N²/2 index writes >> bound.
        let log2N = Double(n).logarithm2()
        let bound = Int(4.0 * Double(n) * log2N)
        XCTAssertLessThan(steps, bound,
            "pruneExpired index-write steps (\(steps)) must stay sub-quadratic (< \(bound)); per-entry reindex regression would total ≈ N²/2 = \(n*n/2)")
    }
}

private extension Double {
    func logarithm2() -> Double { Foundation.log2(self) }
}
