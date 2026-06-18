import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256

// Block reorg handling for LatticeNode.
// Reorg handling for the local chain: orphan-transaction recovery, common-
// ancestor walk, reorg-event emission, and inherited-weight fold + fork-choice
// re-evaluation. Parent reorgs are not child-chain rollback events.

extension LatticeNode {

    @discardableResult
    func recordLiveParentAnchor(
        directory: String,
        blockHash: String,
        parentHash: String,
        source: any ContentSource
    ) async -> Bool {
        await withChainMutation(chainKey(forDirectory: directory)) {
            await recordLiveParentAnchorUnlocked(
                directory: directory,
                blockHash: blockHash,
                parentHash: parentHash,
                source: source
            )
        }
    }

    @discardableResult
    private func recordLiveParentAnchorUnlocked(
        directory: String,
        blockHash: String,
        parentHash: String,
        source: any ContentSource
    ) async -> Bool {
        let liveIndex = await ensureLiveInheritedWeightIndex(directory: directory)
        guard liveIndex.recordParentAnchor(childHash: blockHash, parentHash: parentHash) else { return true }
        return await reevaluateInheritedWeightUnlocked(directory: directory, blockHash: blockHash, source: source)
    }

    @discardableResult
    private func reevaluateInheritedWeightUnlocked(directory: String, blockHash: String, source: any ContentSource) async -> Bool {
        guard let chain = await chain(for: directory),
              await chain.getConsensusBlock(hash: blockHash) != nil else { return true }
        return await reevaluateAndPublish(
            directory: directory,
            blockHash: blockHash,
            reason: "live inherited-weight",
            chain: chain,
            source: source
        )
    }

    /// F5-4 (Hierarchical GHOST): fold a newly-accepted block's verified inherited
    /// work into this chain's per-child contribution store, then re-run fork choice
    /// so the block is promoted if its securing weight now makes it the heaviest.
    /// Must be called AFTER the block is accepted and `proof` is verified.
    @discardableResult
    func applyInheritedWeight(directory: String, blockHash: String, proof: ChildBlockProof, source: any ContentSource) async -> Bool {
        await withChainMutation(chainKey(forDirectory: directory)) {
            await applyInheritedWeightUnlocked(
                directory: directory,
                blockHash: blockHash,
                proof: proof,
                source: source
            )
        }
    }

    @discardableResult
    private func applyInheritedWeightUnlocked(directory: String, blockHash: String, proof: ChildBlockProof, source: any ContentSource) async -> Bool {
        if let anchor = await proof.committingParentAnchor() {
            guard await recordLiveParentAnchorUnlocked(
                directory: directory,
                blockHash: blockHash,
                parentHash: anchor.blockHash,
                source: source
            ) else { return false }
        }
        // The contribution fold below this point was a byte-identical twin of
        // applyInheritedWorkContributionsUnlocked — delegate to it, keeping this
        // site's historical "inherited-weight" reason tag.
        return await applyInheritedWorkContributionsUnlocked(
            directory: directory,
            blockHash: blockHash,
            contributions: await proof.securingWorkContributions(),
            source: source,
            reason: "inherited-weight"
        )
    }

    /// Install verified inherited work before submitting a child candidate to
    /// `ChainState`. A parent-secured child block may arrive as a side fork; fork
    /// choice needs its inherited weight during the first submit, otherwise the
    /// Lattice API reports the valid side insert as a non-accepted block and the
    /// caller never reaches the post-acceptance weight-recording path.
    func preloadInheritedWeight(directory: String, blockHash: String, proof: ChildBlockProof) async {
        let contributions = await proof.securingWorkContributions()
        await preloadInheritedWorkContributions(directory: directory, blockHash: blockHash, contributions: contributions)
    }

    func preloadInheritedWorkContributions(
        directory: String,
        blockHash: String,
        contributions: [(id: String, work: UInt256)]
    ) async {
        guard !contributions.isEmpty else { return }
        let store = await ensureInheritedWeightStore(directory: directory)
        _ = store.recordVerifiedWorkContributions(contributions, committingChild: blockHash)
    }

    @discardableResult
    func applyInheritedWorkContributions(
        directory: String,
        blockHash: String,
        contributions: [(id: String, work: UInt256)],
        source: any ContentSource
    ) async -> Bool {
        await withChainMutation(chainKey(forDirectory: directory)) {
            await applyInheritedWorkContributionsUnlocked(
                directory: directory,
                blockHash: blockHash,
                contributions: contributions,
                source: source
            )
        }
    }

    @discardableResult
    private func applyInheritedWorkContributionsUnlocked(
        directory: String,
        blockHash: String,
        contributions: [(id: String, work: UInt256)],
        source: any ContentSource,
        reason: String = "inherited-contribution"
    ) async -> Bool {
        guard !contributions.isEmpty else { return true }
        guard let chain = await chain(for: directory) else { return true }
        if let height = await chain.getConsensusBlock(hash: blockHash)?.blockHeight {
            guard await persistVerifiedInheritedWorkContributions(
                directory: directory,
                blockHash: blockHash,
                height: height,
                contributions: contributions
            ) else { return false }
        }
        let store = await ensureInheritedWeightStore(directory: directory)
        let recordedNewWork = store.recordVerifiedWorkContributions(contributions, committingChild: blockHash)

        // Persisting/replaying the same proof is idempotent. Only newly-counted
        // inherited work is allowed to drive a fork-choice publish; recovery has
        // already restored the durable floor before duplicate parent proofs replay.
        guard recordedNewWork else { return true }
        return await reevaluateAndPublish(
            directory: directory,
            blockHash: blockHash,
            reason: reason,
            chain: chain,
            source: source
        )
    }

    private func persistVerifiedInheritedWorkContributions(
        directory: String,
        blockHash: String,
        height: UInt64,
        contributions: [(id: String, work: UInt256)]
    ) async -> Bool {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return true }
        do {
            try await store.persistInheritedWorkContributions(
                height: height,
                blockHash: blockHash,
                contributions: contributions
            )
            return true
        } catch {
            NodeLogger("blocks").error("\(directory): failed to persist inherited-work contributors for \(String(blockHash.prefix(16)))… at height \(height): \(error)")
            await markChainUnhealthy(directory: directory, reason: "failed to persist inherited-work contributors")
            return false
        }
    }

    /// Walk back from `oldTip` up to `retentionDepth` blocks, collecting
    /// hashes that are NOT in `newChainHashes` as orphans. Reports whether a
    /// common ancestor was actually found — if not, the reorg exceeds the
    /// retention window and the caller must refuse recovery rather than
    /// proceed with a truncated orphan set (S3).
    ///
    /// Static + `resolveParent` closure so the walk is directly testable
    /// without spinning up a `ChainState`/`LatticeNode`.
    static func walkOrphansToCommonAncestor(
        oldTip: String,
        newChainHashes: Set<String>,
        retentionDepth: UInt64,
        resolveParent: (String) async -> String?
    ) async -> (orphans: [String], foundCommonAncestor: Bool) {
        var orphans: [String] = []
        var current = oldTip
        for _ in 0..<retentionDepth {
            if newChainHashes.contains(current) {
                return (orphans, true)
            }
            orphans.append(current)
            guard let prev = await resolveParent(current) else {
                return (orphans, false)
            }
            current = prev
        }
        return (orphans, false)
    }
    func recoverOrphanedTransactions(
        transition: BoundedReorgWalkResult,
        oldTip: String,
        newTip: String,
        directory: String,
        source: any ContentSource
    ) async {
        // `CoalescingFetcher(source)` resolves byte-identically to the prior raw
        // `fetcher` (transparent per-wave batching); the orphan walk below resolves
        // blocks/tx structure over it directly.
        let fetcher: Fetcher = CoalescingFetcher(source)
        let log = NodeLogger("reorg")
        let dir = directory
        let network = network(for: dir)

        let newChainHashes = transition.newChainHashes
        let orphanedBlockHashes = transition.orphaned

        guard !orphanedBlockHashes.isEmpty else { return }

        // S3: retentionDepth is a consensus-safety parameter, not just storage.
        // If the transition was derived by walking `retentionDepth` blocks back
        // from oldTip without finding a common ancestor with the new chain, the
        // fork is deeper than our retention window and we cannot correctly
        // identify the orphan set. Applying a reorg with a truncated/incomplete
        // orphan list silently corrupts local mempool recovery and canonical
        // side effects — refuse and log loudly instead of guessing.
        // (A Reorganization-fed transition always carries the exact sets.)
        if !transition.foundCommonAncestor {
            log.error("Reorg refused: no common ancestor within retentionDepth=\(config.retentionDepth) blocks from oldTip=\(String(oldTip.prefix(16)))… to newTip=\(String(newTip.prefix(16)))…. Fork either exceeds the retention window (honest — raise retentionDepth) or indicates a malicious peer.")
            return
        }

        log.info("Reorg: \(orphanedBlockHashes.count) orphaned block(s)")

        // SEC-101: no finality floor and no depth-based rejection here.
        // Fork choice (Lattice, heaviest-trueCumWork) has already moved the tip to
        // the strictly-heavier chain before this runs; refusing mempool recovery on
        // depth would only strand the mempool/child state inconsistent with the
        // accepted consensus tip. Heaviest-chain only — recover unconditionally.

        // Step 1 — Phase A: resolve orphaned block tx CIDs cheaply with .list
        // strategy (no leaf/body data fetched). Phase B, below, fetches full tx
        // bodies only for the subset NOT already confirmed on the new chain,
        // reducing reorg I/O by 10–20× for typical reorg depths.
        let reorgFetcher: Fetcher = CoalescingFetcher(await buildMempoolAwareSource(directory: dir, baseFetcher: fetcher))

        struct OrphanedBlockSummary {
            let block: Block
            let txCIDs: [String]
        }
        var orphanedSummaries: [OrphanedBlockSummary] = []
        for blockHash in orphanedBlockHashes {
            let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            guard let block = try? await stub.resolve(fetcher: fetcher).node else {
                log.error("Missing CAS data for orphaned block \(blockHash) — skipping")
                continue
            }
            // .list: loads radix trie structure only; no transaction body fetches
            let txCIDs: [String]
            if let txDict = try? await block.transactions.resolve(
                paths: [[""]: ResolutionStrategy.list], fetcher: fetcher
            ).node,
               let entries = try? txDict.allKeysAndValues() {
                txCIDs = entries.values.map(\.rawCID)
            } else {
                txCIDs = []
            }
            orphanedSummaries.append(OrphanedBlockSummary(block: block, txCIDs: txCIDs))
        }

        // SHADOW: revert the refcount index for the abandoned fork. The new branch's
        // blocks re-enter the index through the normal accept path, so we only have
        // to inverse-apply the orphaned heights' accept increments here. Best-effort —
        // never perturbs reorg recovery. (Orphaned blocks are content-addressed, so
        // each block's height is authoritative.)
        let orphanedHeights = orphanedSummaries.map { $0.block.height }
        if !orphanedHeights.isEmpty {
            await forgetStateRefcountOnReorg(orphanedHeights: orphanedHeights, directory: dir)
        }

        // Compute orphaned CIDs from phase-A summaries (no body fetch needed here)
        let orphanedTxCIDs = Set(orphanedSummaries.flatMap { $0.txCIDs })

        // Remove stale receipt index entries before re-admitting orphaned transactions.
        // If a transaction is re-confirmed on the new chain, batchIndexReceipts will write
        // fresh entries pointing at the canonical block. Without this, getReceipt returns
        // an orphaned block hash that is no longer on the main chain.
        if !orphanedTxCIDs.isEmpty, let store = stateStores[chainKey(forDirectory: dir)] {
            do {
                try await store.deleteReceiptsForOrphanedTxCIDs(orphanedTxCIDs)
            } catch {
                // Peripheral cleanup: a stale receipt index points at an orphaned
                // block hash until re-confirmation rewrites it. Log and continue —
                // re-admission of orphaned txs must still proceed.
                NodeLogger("blocks").error("\(dir): deleteReceiptsForOrphanedTxCIDs failed for \(orphanedTxCIDs.count) cids: \(error)")
            }
        }

        // Step 2: Collect confirmed transaction-volume CIDs from the NEW chain
        // (to avoid re-adding them) plus body CIDs for mempool removal. Blocks
        // store VolumeImpl<Transaction>.rawCID, while NodeMempool is keyed by
        // transaction.body.rawCID, so the two sets must not be conflated.
        let newChainTxIDs: (transactionCIDs: Set<String>, bodyCIDs: Set<String>) = await withTaskGroup(
            of: (transactionCIDs: Set<String>, bodyCIDs: Set<String>).self
        ) { group in
            for newBlockHash in newChainHashes {
                group.addTask {
                    let stub = VolumeImpl<Block>(rawCID: newBlockHash, node: nil, encryptionInfo: nil)
                    guard let block = try? await stub.resolve(fetcher: fetcher).node,
                          let txDict = try? await block.transactions.resolve(
                              paths: [[""]: .list], fetcher: fetcher
                          ).node,
                          let txEntries = try? txDict.allKeysAndValues() else { return ([], []) }
                    var transactionCIDs = Set<String>()
                    var bodyCIDs = Set<String>()
                    for txHeader in txEntries.values {
                        transactionCIDs.insert(txHeader.rawCID)
                        if let tx = try? await txHeader.resolve(fetcher: reorgFetcher).node {
                            bodyCIDs.insert(tx.body.rawCID)
                        }
                    }
                    return (transactionCIDs, bodyCIDs)
                }
            }
            var transactionCIDs = Set<String>()
            var bodyCIDs = Set<String>()
            for await ids in group {
                transactionCIDs.formUnion(ids.transactionCIDs)
                bodyCIDs.formUnion(ids.bodyCIDs)
            }
            return (transactionCIDs, bodyCIDs)
        }
        let newChainTxCIDs = newChainTxIDs.transactionCIDs

        // Step 3: Remove new chain's confirmed txs from mempool
        if !newChainTxIDs.bodyCIDs.isEmpty, let network {
            await network.nodeMempool.removeAll(txCIDs: newChainTxIDs.bodyCIDs)
        }

        // Step 1 — Phase B: fetch full tx bodies only for transactions that are NOT
        // confirmed on the new chain. This avoids fetching bodies for the majority
        // of orphaned transactions that were already re-confirmed.
        var orphanedBlockTxs: [(block: Block, txEntries: [String: VolumeImpl<Transaction>])] = []
        for summary in orphanedSummaries {
            let candidateCIDs = summary.txCIDs.filter { !newChainTxCIDs.contains($0) }
            guard !candidateCIDs.isEmpty else { continue }
            var txEntries: [String: VolumeImpl<Transaction>] = [:]
            txEntries.reserveCapacity(candidateCIDs.count)
            for cid in candidateCIDs {
                let header = VolumeImpl<Transaction>(rawCID: cid, node: nil, encryptionInfo: nil)
                if let tx = try? await header.resolve(fetcher: reorgFetcher).node {
                    let materialized: Transaction
                    if tx.body.node != nil {
                        materialized = tx
                    } else if let body = try? await tx.body.resolve(fetcher: reorgFetcher).node {
                        materialized = Transaction(
                            signatures: tx.signatures,
                            // known-valid local node; CID cannot fail
                            body: try! HeaderImpl<TransactionBody>(node: body)
                        )
                    } else {
                        log.info("\(dir): orphaned tx \(String(cid.prefix(16)))… body unavailable during recovery")
                        continue
                    }
                    txEntries[cid] = try! VolumeImpl(node: materialized)
                }
            }
            if !txEntries.isEmpty {
                orphanedBlockTxs.append((block: summary.block, txEntries: txEntries))
            }
        }

        if let network {
            var senders = Set<String>()
            senders.formUnion(await network.nodeMempool.allSenders())
            for entry in orphanedBlockTxs {
                for (_, txHeader) in entry.txEntries {
                    // every signer's floor needs a reset — consensus
                    // tracks a nonce sequence per signer, not per signers.first.
                    for sender in txHeader.node?.body.node?.signers ?? [] where !sender.isEmpty {
                        senders.insert(sender)
                    }
                }
            }
            if !senders.isEmpty {
                var nonceResets: [(sender: String, nonce: UInt64)] = []
                for sender in senders.sorted() {
                    if let nonce = try? await getNonce(address: sender, directory: dir) {
                        nonceResets.append((sender: sender, nonce: nonce))
                    }
                }
                await network.nodeMempool.resetConfirmedNoncesAfterReorg(updates: nonceResets)
            }
        }

        // Step 4: Re-classify orphaned txs through the unified admission
        // helper. admitToMempool runs the validator + parent-receipt probe
        // so a withdrawal whose required receipt is no longer canonical in
        // the new chain lands in pending (or evicts on wrong-owner) instead
        // of being silently dropped.
        var recovered = 0
        for entry in orphanedBlockTxs {
            for (cid, txHeader) in entry.txEntries {
                guard let tx = txHeader.node else { continue }
                if tx.body.node?.fee == 0 && tx.body.node?.nonce == entry.block.height { continue }
                if newChainTxCIDs.contains(cid) { continue }
                // M9: re-admit through the unified seam with
                // `allowWithdrawalWithoutDeposit` so a withdrawal whose backing
                // deposit is momentarily non-canonical is tolerated AND still runs
                // the cumulative per-sender double-spend bound (the prior raw
                // `addTransaction(confirmedBalance: nil)` bypass + string match is
                // gone). The validator returns a typed `.withdrawalWithoutDeposit`;
                // admitToMempool resolves the sender's balance/debit and threads
                // them into addTransaction.
                let addResult = await admitToMempool(
                    transaction: tx,
                    directory: dir,
                    allowWithdrawalWithoutDeposit: true
                )
                switch addResult {
                case .added, .replacedExisting:
                    recovered += 1
                case .rejected(let reason):
                    log.info("\(dir): orphaned tx \(String(cid.prefix(16)))… not recovered: \(reason)")
                    continue
                }
            }
        }

        log.info("Reorg complete: \(recovered) tx(s) recovered, \(newChainTxCIDs.count) confirmed in new chain")

        await emitReorgEvent(
            directory: dir,
            oldTip: oldTip,
            newTip: newTip,
            depth: UInt64(orphanedBlockHashes.count)
        )
    }

    /// Parent reorgs do not roll back child chains. Child chains are independent
    /// chains whose blocks are validated by proof paths and same-chain parent
    /// pointers; parent canonicity is not part of child consensus.
    func rollbackChildChains(orphanedBlockHashes: [String], fetcher: Fetcher) async {
        let log = NodeLogger("reorg")
        if !orphanedBlockHashes.isEmpty {
            log.info("Parent reorg orphaned \(orphanedBlockHashes.count) parent block(s); child-chain state left unchanged")
        }
    }

    // MARK: - Block Reception (ChainNetworkDelegate) with Rate Limiting & Reputation
    func emitReorgEvent(directory: String, oldTip: String, newTip: String, depth: UInt64) async {
        await subscriptions.emit(.chainReorg(
            directory: directory,
            oldTip: oldTip,
            newTip: newTip,
            depth: depth
        ))
    }
}
