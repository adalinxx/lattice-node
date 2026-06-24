import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256

private enum BlockContentResolutionFailure: Error {
    case missingBlockNode
}

// Block validation for LatticeNode.
// Behavior-preserving extraction : timestamp/PoW checks, durable-resolve /
// missing-root helpers, parent-anchor verification + pre-submit consistency, and
// validation-cache pre-warming. Pure relocation; no logic change.

extension LatticeNode {

    /// Wall-clock sanity check applied on the GOSSIP path only.
    ///
    /// The 24h lower bound (SEC-014, `testAncientBlockRejected`) is a deliberate
    /// relay-spam policy, NOT a consensus rule: live gossip carries recent blocks,
    /// so a block whose own timestamp is >24h old is dropped from the hot path
    /// rather than triggering a full content resolve. This does NOT contradict
    /// spec §5 ("no lower bound against wall-clock, so historical blocks still
    /// validate during cold sync") — historical blocks are obtained through the
    /// headers-first SYNC path (`HeaderChain`), which deliberately applies no
    /// wall-clock floor. A chain recovering from a >24h stall is also unaffected:
    /// the extending block is mined now and carries a fresh timestamp. Keep this
    /// floor OFF the sync path; it is relay policy, not validity.
    nonisolated public func isBlockTimestampValid(_ block: Block) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if block.timestamp > nowMs + Self.maxTimestampDriftMs { return false }
        if block.timestamp < nowMs - Self.maxTimestampAgeMs { return false }
        return true
    }
    /// Extends the wall-clock check with a monotonicity check against the parent.
    /// A block whose timestamp is before its parent's is invalid regardless of
    /// wall-clock position — without this, a miner can backdate blocks to shift
    /// the retarget window and artificially soften the target.
    nonisolated public func isBlockTimestampValid(_ block: Block, parentTimestamp: Int64) -> Bool {
        guard isBlockTimestampValid(block) else { return false }
        return block.timestamp >= parentTimestamp
    }
    /// Cheap O(1) proof-of-work sanity check: does the block's hash actually
    /// meet its own claimed target? Runs against header fields only
    /// — no CAS touch, no state resolve. Catches lazy gossip spam that forged
    /// target without burning any nonce work; correctness of the claimed
    /// target itself (vs. chain rules) is re-checked later in
    /// `validateNextTarget` once ancestor timestamps are available.
    nonisolated func isBlockPoWValid(_ block: Block) -> Bool {
        guard block.validateProofOfWork(nexusHash: block.proofOfWorkHash()) else {
            return false
        }
        // If the parent is cached, verify the claimed target matches parent.nextTarget.
        // A peer claiming target=.max passes the hash check trivially — this closes that gap.
        // Pure memory lookup, no I/O, safe for the gossip hot path.
        // On cold start or unknown fork the parent won't be cached; full validation catches fraud.
        if let parentCID = block.parent?.rawCID,
           let expected = cachedNextTarget(for: parentCID) {
            // Accept the minimum-difficulty recovery case in addition to an exact
            // match, so this cheap gate does not REJECT a block that full
            // consensus would ACCEPT (admission must be a superset of consensus on
            // the accept side, else valid recovery blocks get dropped from the
            // gossip hot path). Mirrors the library's internal
            // `ChainSpec.isMinimumTargetRecovery(target:parentNextTarget:)`
            // (Block+Validate.validateNextTarget / ChainSyncer.validateHeaderConsensus);
            // replicated here only because that predicate is module-internal. Keep
            // in sync with the library if the recovery clause ever changes.
            if block.target == expected { return true }
            return block.target == ChainSpec.minimumTarget && expected < ChainSpec.minimumTarget
        }
        return true
    }

    // MARK: - State Root Extraction
    func persistVerifiedParentHeaderEdge(directory: String, anchor: ParentAnchor) async {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        do {
            try await store.persistParentHeader(
                parentHash: anchor.blockHash,
                previousHash: anchor.parentHash,
                height: anchor.height
            )
        } catch {
            NodeLogger("blocks").error("\(directory): persistParentHeader failed for \(String(anchor.blockHash.prefix(16)))… at \(anchor.height): \(error)")
        }
    }

    /// Whether a verified parent-header edge is already persisted for `blockHash`
    /// in this child's continuity index. Used by the parent extractor to terminate
    /// ancestor backfill / announce backfill at the first already-recorded block —
    /// the durable equivalent of the former in-memory parent-view "already known"
    /// marker.
    func hasVerifiedParentHeaderEdge(directory: String, blockHash: String) -> Bool {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return false }
        return store.getParentHeader(parentHash: blockHash) != nil
    }

    func persistVerifiedParentStateEdge(directory: String, parentBlock: Block) async {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        do {
            try await store.persistParentStateEdge(
                fromRoot: parentBlock.prevState.rawCID,
                toRoot: parentBlock.postState.rawCID
            )
        } catch {
            NodeLogger("blocks").error("\(directory): persistParentStateEdge failed \(String(parentBlock.prevState.rawCID.prefix(16)))… -> \(String(parentBlock.postState.rawCID.prefix(16)))…: \(error)")
        }
    }

    /// Record a parent transition pushed directly from the parent process (a
    /// minted block, embedding this child or not). The parent — which is the
    /// authority on its own state transitions — delivers every block it mints to
    /// its children so their continuity index stays current without depending on
    /// best-effort gossip or an on-demand fetch race. The pushed block is verified
    /// independently (CID + PoW by the caller); here we record the verified
    /// `prevState→postState` edge for every local chain whose parent is the
    /// pushed block's chain. This grants no child fork-choice weight — only the
    /// continuity edge a child needs to anchor candidates as the parent advances.
    func recordPushedParentContinuity(parentDirectory: String, parentBlock: Block, parentCID: String) async {
        let anchor = ParentAnchor(
            blockHash: parentCID,
            parentHash: parentBlock.parent?.rawCID,
            height: parentBlock.height,
            prevStateCID: parentBlock.prevState.rawCID
        )
        let childDirectories = networks.values
            .filter { $0.parentDirectory == parentDirectory }
            .map(\.directory)
        for childDirectory in childDirectories {
            await persistVerifiedParentHeaderEdge(directory: childDirectory, anchor: anchor)
            await persistVerifiedParentStateEdge(directory: childDirectory, parentBlock: parentBlock)
        }
    }
    func persistCommittingParentEdgeFromVerifiedProof(
        directory: String,
        proof: ChildBlockProof
    ) async -> ParentAnchor? {
        guard let committedParent = await proof.committingParentBlock() else { return nil }
        let anchor = ParentAnchor(
            blockHash: committedParent.cid,
            parentHash: committedParent.block.parent?.rawCID,
            height: committedParent.block.height,
            prevStateCID: committedParent.block.prevState.rawCID
        )
        await persistVerifiedParentHeaderEdge(directory: directory, anchor: anchor)
        await persistVerifiedParentStateEdge(directory: directory, parentBlock: committedParent.block)
        return anchor
    }
    func verifiedCommittingParentAnchor(
        directory: String,
        chainPath: [String],
        childBlock: Block,
        childCID: String,
        proof: ChildBlockProof
    ) async -> ParentAnchor? {
        guard let root = await proof.anchorRoot() else { return nil }
        // Validity is per-chain PoW: `accepts` proves the carrier's blocktree hash
        // clears THIS child's target. A child mined at its own difficulty under a
        // harder-target parent legitimately inherits ZERO parent work — the carrier
        // did not clear the parent's target — which is correct per-level crediting,
        // not an invalid block. Gating validity on `securingWork() > .zero` wrongly
        // rejected such children; it is reachable only with a real (non-max) parent
        // target, so max-target test genesis masked it. Inherited weight remains a
        // fork-choice quantity applied separately; zero is legitimate here.
        guard await MinedChildBlockSelection.accepts(
            chainPath: chainPath,
            block: childBlock,
            childCID: childCID,
            rootHash: root.hash,
            proof: proof
        ) else {
            return nil
        }
        guard let committedParent = await proof.committingParentBlock() else { return nil }
        guard childBlock.parentState.rawCID == committedParent.block.prevState.rawCID else {
            NodeLogger("blocks").warn("\(directory): child block \(String(childCID.prefix(16)))… parent state root \(String(childBlock.parentState.rawCID.prefix(16)))… does not match proven parent prevState \(String(committedParent.block.prevState.rawCID.prefix(16)))…")
            return nil
        }
        let anchor = ParentAnchor(
            blockHash: committedParent.cid,
            parentHash: committedParent.block.parent?.rawCID,
            height: committedParent.block.height,
            prevStateCID: committedParent.block.prevState.rawCID
        )
        await persistVerifiedParentHeaderEdge(directory: directory, anchor: anchor)
        await persistVerifiedParentStateEdge(directory: directory, parentBlock: committedParent.block)
        return anchor
    }
    func parentStateRootIsContinuous(
        previousRoot: String,
        currentRoot: String,
        directory: String
    ) async -> Bool {
        if previousRoot == currentRoot { return true }
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return false }
        return store.hasParentStatePath(from: previousRoot, to: currentRoot)
    }

    func validateParentAnchorConsistencyBeforeSubmit(
        directory: String,
        blockHash: String,
        block: Block,
        parentAnchor: ParentAnchor?,
        source: (any ContentSource)? = nil
    ) async -> Bool {
        guard parentAnchor != nil else {
            let isChildChain = (network(for: directory)?.chainPath.count ?? 1) >= 2
            return !isChildChain || block.height == 0
        }
        guard let parentAnchor else { return false }
        guard parentAnchor.prevStateCID == nil || parentAnchor.prevStateCID == block.parentState.rawCID else {
            return false
        }
        guard block.height > 1, let previousChildHash = block.parent?.rawCID else {
            return true
        }
        // Same single-CID lookup as before; `CoalescingFetcher(source)` resolves
        // byte-identically to the prior fetcher (transparent per-wave batching).
        guard let source,
              let previousChildData = try? await CoalescingFetcher(source).fetch(rawCid: previousChildHash),
              let previousChildBlock = Block(data: previousChildData),
              // known-valid local node; CID cannot fail
              try! VolumeImpl<Block>(node: previousChildBlock).rawCID == previousChildHash else {
            return false
        }

        return await parentStateRootIsContinuous(
            previousRoot: previousChildBlock.parentState.rawCID,
            currentRoot: block.parentState.rawCID,
            directory: directory
        )
    }

    func selectChildParentAnchor(
        directory: String,
        blockHash: String,
        block: Block,
        candidates: [ParentAnchor]
    ) async -> ParentAnchor? {
        guard !candidates.isEmpty,
              let store = stateStores[chainKey(forDirectory: directory)] else { return nil }

        let orderedCandidates = candidates.canonicalAnchorSorted()

        let stateCompatible = orderedCandidates.filter {
            $0.prevStateCID == nil || $0.prevStateCID == block.parentState.rawCID
        }
        guard !stateCompatible.isEmpty else { return nil }

        if let existing = store.getChildParentAnchor(childHash: blockHash),
           let matching = stateCompatible.first(where: { $0.blockHash == existing }) {
            return matching
        }

        return stateCompatible.first
    }

    func parentCompatibleCandidateBase(
        directory: String,
        tipBlock: Block,
        parentChainBlock: Block?,
        fetcher: Fetcher
    ) async -> Block? {
        guard let parentChainBlock, tipBlock.height > 0 else {
            return tipBlock
        }

        let candidateParentStateRoot = parentChainBlock.prevState.rawCID
        let previousRoot = tipBlock.parentState.rawCID
        if await parentStateRootIsContinuous(
            previousRoot: previousRoot,
            currentRoot: candidateParentStateRoot,
            directory: directory
        ) {
            return tipBlock
        }

        // Continuity isn't established yet from the edges the child already
        // learned via parent gossip/extraction. That extraction is asynchronous
        // and best-effort, so it can lag (or transiently gap) behind a fast
        // parent — leaving the child unable to anchor a candidate to the parent's
        // current carrier even though the carrier and its ancestry are perfectly
        // verifiable. Establish continuity on demand: walk the carrier's parent
        // ancestry through the parent-reaching fetcher, verifying each block's CID
        // and PoW, recording the prevState→postState edges, until the path from
        // this child's tip parentState to the carrier's prevState is complete.
        // This is the proof-availability model (consensus-fork-choice.md): a child
        // verifies parent transitions itself rather than waiting on push delivery.
        if let committingParentHash = parentChainBlock.parent?.rawCID,
           await backfillSyncedParentStatePath(
               directory: directory,
               previousRoot: previousRoot,
               currentRoot: candidateParentStateRoot,
               committingParentHash: committingParentHash,
               fetcher: fetcher,
               requireProofOfWork: true
           ) {
            return tipBlock
        }

        NodeLogger("candidate").warn("\(directory): no child candidate for parent prevState \(String(candidateParentStateRoot.prefix(16)))…; current child tip parentState \(String(previousRoot.prefix(16)))… is not continuous")
        return nil
    }
    /// Pre-warm the fetcher cache with prevState trie nodes for validatePostState.
    func preWarmValidationCache(_ block: Block, network: ChainNetwork) async {
        if !block.prevState.rawCID.isEmpty,
           let prevStateRoot = try? await VolumeImpl<LatticeState>(
               rawCID: block.prevState.rawCID, node: nil, encryptionInfo: nil
           ).resolve(fetcher: network.ivyFetcher).node,
           let txsNode = try? await block.transactions.resolve(
               paths: [[""]: ResolutionStrategy.list], fetcher: network.ivyFetcher
           ).node,
           let txEntries = try? txsNode.allKeysAndValues() {
            let bodies = txEntries.values.compactMap { $0.node?.body.node }
            var resolvePaths = [[String]: ResolutionStrategy]()
            for body in bodies {
                for action in body.accountActions {
                    resolvePaths[[action.owner]] = .targeted
                }
                for signer in Set(body.signers) {
                    resolvePaths[[AccountStateHeader.nonceTrackingKey(signer)]] = .targeted
                }
            }
            if !resolvePaths.isEmpty {
                _ = try? await prevStateRoot.accountState.resolve(
                    paths: resolvePaths, fetcher: network.ivyFetcher
                )
            }
        }
    }
    func requiredLocalRoots(block: Block, blockHash: String) -> [String] {
        Self.blockContentRoots(of: block, blockHash: blockHash)
    }
    func requiredCanonicalRoots(block: Block, blockHash: String, stateDiff: StateDiff) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for root in Self.blockContentRoots(of: block, blockHash: blockHash) {
            guard seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        for root in Self.stateRoots(of: block) {
            guard seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        // Lattice state headers are the externally-fetched Volume boundaries for
        // validation. Their internal trie entries resolve by CID from the durable
        // store's content (cas_data), but they are not all consensus publication roots.
        func appendMaterializedRoot(_ header: any Header) {
            guard header.node != nil else { return }
            if !header.rawCID.isEmpty, seen.insert(header.rawCID).inserted {
                roots.append(header.rawCID)
            }
        }

        // Expand sub-state tries only for postState (owned by this block).
        // prevState/parentState root CIDs remain required-durable elsewhere (via
        // `stateRoots(of:)`); they are References whose sub-tries are owned by
        // their producers and resolved by CID on demand, and their `.node` is nil
        // for synced blocks anyway — so there is nothing to expand here.
        appendMaterializedRoot(block.postState)
        if let stateNode = block.postState.node {
            appendMaterializedRoot(stateNode.accountState)
            appendMaterializedRoot(stateNode.generalState)
            appendMaterializedRoot(stateNode.depositState)
            appendMaterializedRoot(stateNode.genesisState)
            appendMaterializedRoot(stateNode.receiptState)
        }
        for root in stateDiff.created.keys where !root.isEmpty {
            guard seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        return roots
    }
    func missingLocalRoots(block: Block, blockHash: String, network: ChainNetwork) async -> [String] {
        var missing: [String] = []
        for root in requiredLocalRoots(block: block, blockHash: blockHash) {
            if !(await network.hasVolume(rootCID: root)) {
                missing.append(root)
            }
        }
        return missing
    }
    func missingDurableRoots(block: Block, blockHash: String, network: ChainNetwork, stateDiff: StateDiff) async -> [String] {
        var missing: [String] = []
        let createdStateCIDs = Set(stateDiff.created.keys.filter { !$0.isEmpty })
        for root in requiredCanonicalRoots(block: block, blockHash: blockHash, stateDiff: stateDiff) {
            if createdStateCIDs.contains(root) {
                if !(await network.hasCID(root)) {
                    missing.append(root)
                }
                continue
            }
            if !(await network.hasDurableVolume(rootCID: root)) {
                missing.append(root)
            }
        }
        return missing
    }
    func resolveBlockForDurableValidation(
        header: BlockHeader,
        block: Block,
        directory: String,
        network: ChainNetwork,
        source: any ContentSource
    ) async -> Block? {
        let log = NodeLogger("blocks")
        var bundleRoots = await prefetchBlockContentClosure(blockHash: header.rawCID, network: network)

        var resolvedBlock: Block?
        for attempt in 0..<3 {
            do {
                // Gossip-validation resolution now runs over cashew's batched
                // `resolve(paths:source:)` with a NATIVE `ContentSource` composition
                // (mempool overlay → child/parent-state fallbacks → IvyContentSource)
                // built in `processBlockAndRecoverReorgUnlocked`. The source mirrors
                // the prior fetcher composition byte-for-byte (proven in
                // SourceResolutionEquivalenceProofTests #284 generically and
                // ValidationSourceSwitchTests for the production composition); the
                // wave-batching cuts the per-CID round-trips on the dominant gossip
                // path.
                await network.ivyFetcher.beginVolumeTrace()
                guard let node = try await header.resolve(paths: Block.contentResolutionPaths, source: source).node else {
                    throw BlockContentResolutionFailure.missingBlockNode
                }
                _ = await network.ivyFetcher.takeVolumeTrace()
                resolvedBlock = node
                break
            } catch {
                let traced = await network.ivyFetcher.takeVolumeTrace()
                var seen = Set(bundleRoots)
                for root in traced where seen.insert(root).inserted { bundleRoots.append(root) }
                let punished = await network.ivyFetcher.reportDeficientVolumes(roots: bundleRoots)
                if punished.isEmpty {
                    if attempt == 2 {
                        log.warn("\(directory): block content \(String(header.rawCID.prefix(16)))… unresolved with no attributable deficient server; retrying on next announce/sync")
                        return nil
                    }
                    log.warn("\(directory): block content \(String(header.rawCID.prefix(16)))… unresolved with no attributable deficient server; refetching before retry")
                    let refetched = await prefetchBlockContentClosure(
                        blockHash: header.rawCID, network: network, force: true)
                    var refetchedSet = Set(refetched)
                    for root in bundleRoots where refetchedSet.insert(root).inserted {
                        await network.ivyFetcher.fetchVolumeBundle(rootCID: root, force: true)
                    }
                    continue
                }
                if attempt == 2 {
                    log.error("\(directory): failed to resolve block content for \(String(header.rawCID.prefix(16)))…: \(error)")
                    return nil
                }
                log.warn("\(directory): block content \(String(header.rawCID.prefix(16)))… did not resolve from served bundles; punished \(punished.count) peer(s), refetching")
                let refetched = await prefetchBlockContentClosure(
                    blockHash: header.rawCID, network: network, force: true)
                var refetchedSet = Set(refetched)
                for root in bundleRoots where refetchedSet.insert(root).inserted {
                    await network.ivyFetcher.fetchVolumeBundle(rootCID: root, force: true)
                }
            }
        }
        guard let resolvedBlock else {
            log.error("\(directory): failed to resolve block content for \(String(header.rawCID.prefix(16)))… after deficiency retries")
            return nil
        }

        let missing = await missingLocalRoots(block: block, blockHash: header.rawCID, network: network)
        guard !missing.isEmpty else { return resolvedBlock }

        let labels: [(String, String)] = [
            ("block", header.rawCID),
            ("postState", block.postState.rawCID),
            ("prevState", block.prevState.rawCID),
            ("parentState", block.parentState.rawCID),
            ("spec", block.spec.rawCID),
            ("transactions", block.transactions.rawCID),
            ("children", block.children.rawCID),
        ]
        let missingDescription = missing.map { root in
            let label = labels.first { $0.1 == root }?.0 ?? "unknown"
            return "\(label)=\(String(root.prefix(16)))"
        }.joined(separator: ",")
        log.error("\(directory): block \(String(header.rawCID.prefix(16)))… still missing \(missing.count) local root(s) after resolution: \(missingDescription)")
        return nil
    }
}
