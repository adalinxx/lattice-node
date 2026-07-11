import Lattice
import Foundation
import Ivy
import VolumeBroker
import cashew
import UInt256

// Canonical publish/announce choke points for LatticeNode (wave-4).
// One accepted-block publish sequence (relay, stored-block announce, accepted
// state-root announce, tip announce) with per-site deltas as explicit
// parameters, replacing the hand-copied variants in the gossip ingestion paths.

extension LatticeNode {

    /// The single accepted-block publish/announce sequence. Call sites differ
    /// only in explicit parameters:
    /// - `data == nil`: block bytes unavailable (announcement path whose CAS
    ///   fetch failed) — skip relay + stored-block announce, still announce the
    ///   accepted state roots.
    /// - `childRelayRootHash`/`childRelayProofs`: child-chain blocks relay with
    ///   their carrier root + verified work proofs (publishBlock wire format);
    ///   root-chain blocks relay compact data only.
    /// - `announceCurrentTipWhenNotPromoted`: see broadcastCanonicalTipAnnounce.
    func publishAcceptedBlock(
        block: Block,
        cid: String,
        data: Data?,
        network: ChainNetwork,
        childRelayRootHash: UInt256? = nil,
        childRelayProofs: [ChildBlockProof] = [],
        announceCurrentTipWhenNotPromoted: Bool = false
    ) async {
        if let data {
            if let childRelayRootHash {
                await network.relayBlock(cid: cid, data: data, rootHash: childRelayRootHash, proofs: childRelayProofs)
            } else {
                await network.relayBlock(cid: cid, data: data)
            }
            await network.announceStoredBlock(cid: cid, data: data)
        }
        await announceAcceptedBlockState(block, blockHash: cid, network: network)
        await broadcastCanonicalTipAnnounce(
            block: block,
            cid: cid,
            network: network,
            announceCurrentTipWhenNotPromoted: announceCurrentTipWhenNotPromoted
        )
    }

    /// Tip announcement after a block was ingested: announce `cid` as the tip
    /// when it was promoted to the canonical tip. When it landed as a side fork,
    /// announce the actual current tip only if
    /// `announceCurrentTipWhenNotPromoted` (child-chain ingestion keeps peers'
    /// headers-first sync primed even when the proof-carrying block was not
    /// promoted); the root-chain gossip paths announce promoted tips only.
    func broadcastCanonicalTipAnnounce(
        block: Block,
        cid: String,
        network: ChainNetwork,
        announceCurrentTipWhenNotPromoted: Bool = false
    ) async {
        guard let chain = await chain(for: network.directory) else { return }
        let tipCID = await chain.getMainChainTip()
        if tipCID == cid {
            await network.broadcastChainAnnounce(tipCID: cid, tipHeight: block.height, specCID: block.spec.rawCID)
        } else if announceCurrentTipWhenNotPromoted,
                  let tipMeta = await chain.getConsensusBlock(hash: tipCID) {
            await network.broadcastChainAnnounce(tipCID: tipCID, tipHeight: tipMeta.blockHeight, specCID: block.spec.rawCID)
        }
    }

    /// The single reevaluate→publish choke point every inherited-weight fold ends
    /// in: re-run fork choice for `blockHash`, then — if the canonical tip moved,
    /// or the durable tip lags an unchanged in-memory tip — durably publish the
    /// canonical transition. A promotion driven by inherited weight is a real
    /// reorg; if the in-memory tip already moved, this also repairs a lagging
    /// durable tip. Callers differ only in their `reason` tag (kept per-site for
    /// log continuity) and in their own pre-fold guards/no-change semantics.
    @discardableResult
    func reevaluateAndPublish(
        directory: String,
        blockHash: String,
        reason: String,
        chain: ChainState,
        source: any ContentSource
    ) async -> Bool {
        let tipBefore = await chain.getMainChainTip()
        let reorganization = await chain.reevaluateForkChoice(blockHash: blockHash)
        let tipAfter = await chain.getMainChainTip()
        let publishOldTip = await durablePublishOldTip(directory: directory, inMemoryOldTip: tipBefore, newTip: tipAfter, chain: chain)
        guard let publishOldTip else { return true }
        return await publishCanonicalTransition(
            oldTip: publishOldTip,
            newTip: tipAfter,
            directory: directory,
            chain: chain,
            source: source,
            reason: reason,
            reorganization: reorganization
        )
    }

    private func durablePublishOldTip(
        directory: String,
        inMemoryOldTip: String,
        newTip: String,
        chain: ChainState
    ) async -> String? {
        if inMemoryOldTip != newTip { return inMemoryOldTip }
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let durableTip = store.getChainTip(),
              !durableTip.isEmpty,
              durableTip != newTip,
              let newTipHeight = await chain.getConsensusBlock(hash: newTip)?.blockHeight else {
            return nil
        }
        let durableHeight = store.getHeight() ?? 0
        guard durableHeight <= newTipHeight else { return nil }
        return durableTip
    }

    /// Publish all local StateStore side effects for blocks that became canonical
    /// after fork choice moved outside the normal single-block apply path. Inherited
    /// work can promote an already-accepted side branch long after
    /// `processBlockHeader` returned, so merely reconciling block_index/meta:tip
    /// leaves receipts, tx_history, confirmed nonces, and parent-header edges stale.
    @discardableResult
    func publishCanonicalTransition(
        oldTip: String,
        newTip: String,
        directory: String,
        chain: ChainState,
        source: any ContentSource,
        reason: String,
        reorganization: Reorganization? = nil
    ) async -> Bool {
        guard oldTip != newTip else { return true }
        let durableOldTip = stateStores[chainKey(forDirectory: directory)]?.getChainTip()
        let publishBaseTip = durableOldTip.flatMap { $0.isEmpty ? nil : $0 } ?? oldTip
        guard await updateCanonicalTipSnapshot(newTip: newTip, directory: directory, chain: chain, source: source) else {
            return false
        }

        // Common path: fork choice just produced this transition's exact
        // promoted/orphaned sets — consume them instead of re-walking the graph.
        // Valid only when the durable publish base IS the in-memory pre-reorg tip
        // the Reorganization describes (publishBaseTip == oldTip).
        //
        // boundedReorgWalk remains as the fallback, used precisely when:
        // (a) no Reorganization is in hand — fork choice ran inside
        //     processBlockHeader (block-processing path), or this is a
        //     durable-repair publish where the in-memory tip never moved; or
        // (b) durable divergence — the durable tip != the in-memory pre-reorg
        //     tip (a crash or earlier failed publish left meta:chain-tip behind),
        //     so the transition to publish starts from a base the Reorganization
        //     does not describe; or
        // (c) the Reorganization no longer matches the tip being published or
        //     references blocks whose height is unresolvable (stale under actor
        //     reentrancy) — canonicalTransition(from:) returns nil.
        let transition: BoundedReorgWalkResult
        if publishBaseTip == oldTip,
           let reorganization,
           let fed = await Self.canonicalTransition(
               from: reorganization,
               newTip: newTip,
               resolveHeight: { await chain.getConsensusBlock(hash: $0)?.blockHeight }
           ) {
            transition = fed
        } else {
            transition = await boundedReorgWalk(oldTip: publishBaseTip, newTip: newTip, chain: chain)
        }

        let parentOfNewTip = await chain.getConsensusBlock(hash: newTip)?.parentBlockHash
        if publishBaseTip != newTip, parentOfNewTip != publishBaseTip {
            await recoverOrphanedTransactions(
                transition: transition,
                oldTip: publishBaseTip,
                newTip: newTip,
                directory: directory,
                source: source
            )
        }

        guard transition.foundCommonAncestor else {
            NodeLogger("blocks").error("\(directory): failed to publish \(reason) transition; no common ancestor within retentionDepth=\(config.retentionDepth)")
            await markChainUnhealthy(directory: directory, reason: "failed to identify promoted canonical segment")
            return false
        }
        let promoted = transition.promoted.reversed()

        let txSource = await buildMempoolAwareSource(directory: directory, baseFetcher: CoalescingFetcher(source))
        for item in promoted {
            let stub = VolumeImpl<Block>(rawCID: item.hash, node: nil, encryptionInfo: nil)
            guard let block = try? await stub.resolve(source: txSource).node else {
                NodeLogger("blocks").error("\(directory): failed to resolve promoted canonical block \(String(item.hash.prefix(16)))… for \(reason) side effects")
                await markChainUnhealthy(directory: directory, reason: "failed to resolve promoted canonical block")
                return false
            }
            let txEntries = await resolveBlockTransactions(block: block, source: txSource)
            guard await applyAcceptedBlock(
                block: block,
                blockHash: item.hash,
                txEntries: txEntries,
                directory: directory,
                allowLowerHeightReplay: true
            ) else {
                await markChainUnhealthy(directory: directory, reason: "failed to durably publish promoted canonical block")
                return false
            }
            await chain.updateTipSnapshot(block: block)
        }

        let tipSR = await resolveTipStateRoot(blockHash: newTip, source: txSource)
        do {
            try await reconcileBlockIndex(directory: directory, tipStateRoot: tipSR)
            if let network = network(for: directory),
               let tipMeta = await chain.getConsensusBlock(hash: newTip) {
                try await advanceStateRetainedRoots(
                    directory: directory,
                    network: network,
                    tipHeight: tipMeta.blockHeight,
                    tipHash: newTip
                )
            }
            // W4 bug fix: re-point the lock-free miner tip cache. An
            // inherited-weight promotion reaches here without passing the
            // ordinary per-block apply path (the only other place that updates
            // it), so the block producer would keep building on the orphaned tip
            // until the next ordinary accept. Idempotent for callers that
            // already updated it (block-processing path).
            tipCaches[chainKey(forDirectory: directory)]?.update(newTip)
            // AUDIT-ONLY (Module 3): record this canonical transition for
            // observability. Best-effort and NON-FATAL — a failure here must
            // never change this function's return value or abort the commit, and
            // nothing in recovery/reconcile reads this log.
            if let store = stateStores[chainKey(forDirectory: directory)] {
                let h = await chain.getConsensusBlock(hash: newTip)?.blockHeight ?? 0
                do {
                    try await store.appendCanonicalTransition(
                        oldTip: publishBaseTip,
                        newTip: newTip,
                        height: h,
                        reason: reason,
                        promoted: transition.promoted,
                        orphaned: transition.orphaned
                    )
                } catch {
                    NodeLogger("blocks").error("\(directory): canonical transition audit append failed (non-fatal): \(error)")
                }
            }
            return true
        } catch {
            NodeLogger("blocks").error("\(directory): failed to publish \(reason) reorg commitment: \(error)")
            await markChainUnhealthy(directory: directory, reason: "failed to durably publish \(reason) reorg")
            return false
        }
    }

    private func updateCanonicalTipSnapshot(
        newTip: String,
        directory: String,
        chain: ChainState,
        source: any ContentSource
    ) async -> Bool {
        let stub = VolumeImpl<Block>(rawCID: newTip, node: nil, encryptionInfo: nil)
        let tipSource = await buildMempoolAwareSource(directory: directory, baseFetcher: CoalescingFetcher(source))
        guard let block = try? await stub.resolve(source: tipSource).node else {
            NodeLogger("blocks").error("\(directory): failed to resolve new canonical tip \(String(newTip.prefix(16)))… for tipSnapshot update")
            await markChainUnhealthy(directory: directory, reason: "failed to resolve new canonical tip")
            return false
        }
        await chain.updateTipSnapshot(block: block)
        postStateCaches[chainKey(forDirectory: directory)]?.invalidate()
        return true
    }

    /// Convert the `Reorganization` fork choice just returned into the same
    /// shape `boundedReorgWalk` produces, so the publish step can consume it
    /// directly. Returns nil when the descriptor cannot be trusted for the tip
    /// being published (its heaviest added block != `newTip`, or a removed
    /// block's height is no longer resolvable) — callers then fall back to the
    /// graph walk. `foundCommonAncestor` is always true here: the sets come from
    /// fork choice itself, so they are exact (never truncated by the retention
    /// window, which is what the walk's flag guards against). The one shape
    /// difference from the walk is that `newChainHashes` does not include the
    /// common ancestor — harmless for the orphan-recovery consumer, because a
    /// transaction confirmed at/below the fork point cannot also appear in an
    /// orphaned block above it on the same pre-reorg chain.
    static func canonicalTransition(
        from reorganization: Reorganization,
        newTip: String,
        resolveHeight: (String) async -> UInt64?
    ) async -> BoundedReorgWalkResult? {
        var promoted = reorganization.mainChainBlocksAdded
            .map { (hash: $0.key, height: $0.value) }
        promoted.sort { $0.height > $1.height }
        guard promoted.first?.hash == newTip else { return nil }
        // Strict parity with boundedReorgWalk: Lattice resolves added-block
        // heights via its pruning-durable weight index, but the walk (and our
        // downstream apply) resolve via hashToBlock only. If any promoted block
        // is not hashToBlock-resolvable here, fall back to the walk so the two
        // paths produce the identical transition (the walk would refuse such a
        // body-pruned interior block) rather than diverging — both fail closed,
        // but this keeps the equivalence exact and test-pinnable.
        for entry in promoted where await resolveHeight(entry.hash) == nil {
            return nil
        }
        var orphanedWithHeight: [(hash: String, height: UInt64)] = []
        orphanedWithHeight.reserveCapacity(reorganization.mainChainBlocksRemoved.count)
        for hash in reorganization.mainChainBlocksRemoved {
            guard let height = await resolveHeight(hash) else { return nil }
            orphanedWithHeight.append((hash: hash, height: height))
        }
        orphanedWithHeight.sort { $0.height > $1.height }
        return BoundedReorgWalkResult(
            orphaned: orphanedWithHeight.map(\.hash),
            promoted: promoted,
            newChainHashes: Set(reorganization.mainChainBlocksAdded.keys),
            foundCommonAncestor: true
        )
    }

    struct ReorgWalkMeta {
        let parentBlockHash: String?
        let blockHeight: UInt64
    }

    struct BoundedReorgWalkResult {
        let orphaned: [String]
        let promoted: [(hash: String, height: UInt64)]
        let newChainHashes: Set<String>
        let foundCommonAncestor: Bool
    }

    func boundedReorgWalk(
        oldTip: String,
        newTip: String,
        chain: ChainState
    ) async -> BoundedReorgWalkResult {
        await Self.boundedReorgWalk(
            oldTip: oldTip,
            newTip: newTip,
            retentionDepth: config.retentionDepth
        ) { hash in
            guard let meta = await chain.getConsensusBlock(hash: hash) else { return nil }
            return ReorgWalkMeta(parentBlockHash: meta.parentBlockHash, blockHeight: meta.blockHeight)
        }
    }

    static func boundedReorgWalk(
        oldTip: String,
        newTip: String,
        retentionDepth: UInt64,
        resolveMeta: (String) async -> ReorgWalkMeta?
    ) async -> BoundedReorgWalkResult {
        guard var oldMeta = await resolveMeta(oldTip),
              var newMeta = await resolveMeta(newTip) else {
            return BoundedReorgWalkResult(orphaned: [], promoted: [], newChainHashes: [], foundCommonAncestor: false)
        }

        var oldHash = oldTip
        var newHash = newTip
        var oldDepth: UInt64 = 0
        var newDepth: UInt64 = 0
        var orphaned: [String] = []
        var promoted: [(hash: String, height: UInt64)] = []
        var newChainHashes = Set<String>()

        while true {
            if oldHash == newHash {
                newChainHashes.insert(newHash)
                return BoundedReorgWalkResult(
                    orphaned: orphaned,
                    promoted: promoted,
                    newChainHashes: newChainHashes,
                    foundCommonAncestor: true
                )
            }

            if newMeta.blockHeight > oldMeta.blockHeight {
                guard newDepth < retentionDepth,
                      let parent = newMeta.parentBlockHash,
                      let parentMeta = await resolveMeta(parent) else {
                    return BoundedReorgWalkResult(orphaned: orphaned, promoted: promoted, newChainHashes: newChainHashes, foundCommonAncestor: false)
                }
                promoted.append((hash: newHash, height: newMeta.blockHeight))
                newChainHashes.insert(newHash)
                newHash = parent
                newMeta = parentMeta
                newDepth += 1
                continue
            }

            if oldMeta.blockHeight > newMeta.blockHeight {
                guard oldDepth < retentionDepth,
                      let parent = oldMeta.parentBlockHash,
                      let parentMeta = await resolveMeta(parent) else {
                    return BoundedReorgWalkResult(orphaned: orphaned, promoted: promoted, newChainHashes: newChainHashes, foundCommonAncestor: false)
                }
                orphaned.append(oldHash)
                oldHash = parent
                oldMeta = parentMeta
                oldDepth += 1
                continue
            }

            guard oldDepth < retentionDepth,
                  newDepth < retentionDepth,
                  let oldParent = oldMeta.parentBlockHash,
                  let newParent = newMeta.parentBlockHash,
                  let oldParentMeta = await resolveMeta(oldParent),
                  let newParentMeta = await resolveMeta(newParent) else {
                return BoundedReorgWalkResult(orphaned: orphaned, promoted: promoted, newChainHashes: newChainHashes, foundCommonAncestor: false)
            }
            orphaned.append(oldHash)
            promoted.append((hash: newHash, height: newMeta.blockHeight))
            newChainHashes.insert(newHash)
            oldHash = oldParent
            oldMeta = oldParentMeta
            newHash = newParent
            newMeta = newParentMeta
            oldDepth += 1
            newDepth += 1
        }
    }

    /// Rewrite the durable `block_index` commitment to the canonical main chain after a
    /// reorg or sync reset. Walks the new main chain from `newTip` toward genesis via
    /// same-chain parents, overwriting each height whose stored hash differs, and stops
    /// as soon as `block_index` already agrees (everything below the fork point is
    /// unchanged) — O(reorg depth), not O(chain). Without this, a multi-block reorg or a
    /// sync reset leaves stale rows at promoted/abandoned heights, and a stale row that
    /// later finalizes could bind a wrong PoW root in `isCanonicalRoot` (F5-4). The
    /// per-block apply path already keeps the single-extend case correct; this covers
    /// the cases where more than the tip changes.
    /// Resolve a block's executed state-root CID for the canonical tip marker. The tip's
    /// state root is part of the atomic publish, so reorg/inherited-weight reconciles must
    /// supply it (commitCanonicalSegment leaves meta:state-root untouched when it's nil,
    /// which would strand it at the old tip after a no-apply inherited-weight promotion).
    func resolveTipStateRoot(blockHash: String, source: any ContentSource) async -> String? {
        let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
        return (try? await stub.resolve(source: source).node)?.postState.rawCID
    }

    func reconcileBlockIndex(directory: String, tipStateRoot: String? = nil) async throws {
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let chain = await chain(for: directory) else { return }
        // Snapshot the live tip ourselves — never trust a caller-passed tip. LatticeNode
        // is actor-reentrant across awaits, so a tip handed in (or read before the walk)
        // can already be a side fork by the time we write. Walk from the snapshot; if the
        // main chain moved before we persist, discard and re-snapshot rather than write a
        // non-current fork. Bounded retries; the triggering reorg also reconciles.
        for _ in 0..<3 {
            let startTip = await chain.getMainChainTip()
            guard !startTip.isEmpty else { return }
            var hash = startTip
            var descending: [CanonicalSegmentBlock] = []
            // The per-block apply may have already written the tip's row (and an
            // inherited-weight promotion writes none), so block_index[tip] could be
            // aligned OR stale — always include the first height (the tip), then stop at
            // the first GENUINE match below it: the fork point, below which both chains
            // agree (so the segment connects there).
            var first = true
            while let meta = await chain.getConsensusBlock(hash: hash) {
                if !first && store.getBlockHash(atHeight: meta.blockHeight) == hash { break }
                // The tip (first iteration) carries the optional state root into the
                // commit's tip marker; lower blocks only contribute their (height,hash).
                descending.append(CanonicalSegmentBlock(
                    height: meta.blockHeight, hash: hash, stateRoot: first ? tipStateRoot : nil))
                first = false
                guard let parent = meta.parentBlockHash else { break }
                hash = parent
            }
            guard await chain.getMainChainTip() == startTip else { continue }  // moved — re-snapshot
            guard !descending.isEmpty else { return }
            // A reorg always connects at the fork point (the aligned height we stopped at).
            try await store.commitCanonicalSegment(
                CanonicalSegment(blocks: descending.reversed(), connectsBelow: true))
            return
        }
    }
}
