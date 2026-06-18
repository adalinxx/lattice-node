import Foundation
import Lattice

/// Shared build→fallback dialect for assembling a block template/candidate from
/// mempool transactions. One implementation serves BlockProducer's internal
/// template path and the four RPC template/candidate sites, so the M11 retention
/// bound applies on every path that trial-rebuilds around a failing transaction.
enum TemplateAssembly {
    /// M11: upper bound on the number of temporarily-unbuildable WITHDRAWAL txs a
    /// single template build will retain in the mempool before it starts evicting
    /// the overflow instead. Without a cap, a sender can flood withdrawals whose
    /// backing receipts never materialize; each stays resident and is re-trial-built
    /// on every block (O(n) churn). Retain a small set (the ones most likely to
    /// become buildable as receipts confirm) and evict the rest.
    internal static let maxRetainedUnbuildableWithdrawals: Int = 64

    /// Builds a block from `transactions`, falling back when the build fails:
    /// - `StateErrors.nonceGap` on the full build → straight to an empty block.
    /// - any other failure → per-tx trial rebuild keeping every tx that still
    ///   builds. Unbuildable WITHDRAWAL txs are retained in the mempool up to
    ///   `maxRetainedUnbuildableWithdrawals` (M11); every other unbuildable tx
    ///   (and overflow withdrawals) is evicted via `removeFromMempool`. If no
    ///   trial build succeeds, falls back to an empty block.
    ///
    /// `hasCoinbase` marks `transactions.last` as the coinbase: it is never
    /// trial-built alone, never evicted, and is re-appended to the kept set.
    /// Throws only if even the empty build fails.
    static func buildWithFallback(
        directory: String,
        context: String,
        transactions initialTransactions: [Transaction],
        hasCoinbase: Bool,
        isolation: isolated (any Actor)? = #isolation,
        build: ([Transaction]) async throws -> Block,
        removeFromMempool: (String) async -> Void
    ) async throws -> (block: Block, transactions: [Transaction]) {
        let log = NodeLogger("miner")
        do {
            let block = try await build(initialTransactions)
            return (block, initialTransactions)
        } catch StateErrors.nonceGap {
            log.warn("\(directory): nonceGap building \(context), falling back to empty block")
            return (try await build([]), [])
        } catch {
            // Non-nonceGap failure (e.g. stale deposit/withdrawal after reorg):
            // retain every tx that still builds instead of letting one stale
            // mempool entry starve later valid transactions.
            log.warn("\(directory): \(context) build failed (\(error)), filtering invalid txs")
            let coinbaseTx = hasCoinbase ? initialTransactions.last : nil
            let userTxs = hasCoinbase ? Array(initialTransactions.dropLast()) : initialTransactions
            var kept: [Transaction] = []
            var lastBuilt: Block?
            var retainedUnbuildableWithdrawals = 0
            for tx in userTxs {
                let candidateTxs = kept + [tx] + (coinbaseTx.map { [$0] } ?? [])
                if let built = try? await build(candidateTxs) {
                    kept.append(tx)
                    lastBuilt = built
                } else if tx.body.node?.withdrawalActions.isEmpty == false,
                          retainedUnbuildableWithdrawals < maxRetainedUnbuildableWithdrawals {
                    // M11: retain temporarily-unbuildable withdrawals only up to a
                    // bound; evict the overflow so an unbounded backlog can't churn
                    // the trial-build path every block.
                    retainedUnbuildableWithdrawals += 1
                    log.warn("\(directory): retaining temporarily unbuildable withdrawal tx \(String(tx.body.rawCID.prefix(16)))…")
                } else {
                    log.warn("\(directory): evicting unbuildable mempool tx \(String(tx.body.rawCID.prefix(16)))…")
                    await removeFromMempool(tx.body.rawCID)
                }
            }
            if let lastBuilt {
                return (lastBuilt, kept + (coinbaseTx.map { [$0] } ?? []))
            }
            log.warn("\(directory): fallback — dropping all \(initialTransactions.count) tx(s) from this \(context)")
            return (try await build([]), [])
        }
    }
}
