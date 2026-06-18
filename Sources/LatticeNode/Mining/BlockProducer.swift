import Lattice
import LatticeMinerCore
import Foundation
import cashew
import UInt256

public actor BlockProducer {
    internal struct NonceRoundLayout: Sendable, Equatable {
        let ranges: [NonceSearchRange]
        let advance: UInt64

        var coverage: UInt64 {
            ranges.reduce(UInt64(0)) { $0 &+ $1.count }
        }
    }

    private let chainState: ChainState
    private let mempool: NodeMempool
    private let fetcher: Fetcher
    private let spec: ChainSpec
    /// Full nexus-to-this-chain path, e.g. `["Nexus"]` when mining the nexus.
    /// Required for coinbase `chainPath`, which `validateChainPaths` compares
    /// against the full expected path — the directory (`chainPath.last`) alone is
    /// only the last segment and isn't valid on anything below the nexus.
    private let chainPath: [String]
    private let identity: MinerIdentity?
    private let coinbaseRecipientAddress: String?
    private let batchSize: UInt64
    private let tipCache: TipCache?
    private let timestampOverride: Int64?
    /// Wall-clock source used for the initial stamp and the in-loop re-stamp.
    /// Defaults to `Self.currentTimeMilliseconds`; tests inject a deterministic
    /// advancing clock to exercise the long-search re-stamp path without timing
    /// flakiness.
    private let nowProvider: @Sendable () -> Int64
    private var nonceOffset: UInt64 = 0
    // Cache of the last-mined block with its frontier LatticeState still
    // resolved in memory. When the next iteration's tip matches this CID, we
    // reuse the cached block instead of re-fetching + re-resolving the entire
    // frontier, which is O(state_size). Without this cache, every iteration
    // re-resolves the full state (minutes per iteration on large chains) and
    // any other actor touching the same ChainNetwork/CAS (e.g. a dashboard
    // RPC) competes for the same actor time and stalls mining visibly.
    private var cachedTipBlock: Block?
    private var cachedTipCID: String?
    /// Coinbase-signing account-trie slice as of `cachedTipCID`: resolved paths
    /// for the authority nonce key and account key. Reused across miner iterations
    /// so `buildCoinbaseTransaction` skips the trie walk + fetch hops. Each
    /// `produceBlock()` call resolves it fresh against the current tip's frontier,
    /// so there is no cross-reorg staleness to invalidate — the producer is
    /// constructed per block-production request.
    private var cachedMinerAccountTrie: AccountState?

    internal static func nonceRoundLayout(
        startNonce: UInt64,
        batchSize: UInt64,
        workerCount: Int
    ) -> NonceRoundLayout {
        let ranges = ProofOfWork.nonceSearchRanges(
            totalBatchSize: batchSize,
            workerCount: workerCount,
            nonceOffset: startNonce
        )
        let advance = ranges.reduce(UInt64(0)) { $0 &+ $1.count }
        return NonceRoundLayout(ranges: ranges, advance: advance)
    }

    internal static let timestampRestampIntervalMs: Int64 = 1_000
    internal static let timestampMedianPastWindow: UInt64 = 11
    internal static let maxCandidateFutureDriftMs: Int64 = 2 * 60 * 60 * 1000

    internal static func currentTimeMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    internal static func medianTimePast(_ ancestorTimestamps: [Int64]) -> Int64? {
        guard !ancestorTimestamps.isEmpty else { return nil }
        let sorted = ancestorTimestamps.prefix(Int(timestampMedianPastWindow)).sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    internal static func adjustedCandidateTimestamp(
        nowMs: Int64,
        previousTimestamp: Int64,
        ancestorTimestamps: [Int64],
        previousCandidateTimestamp: Int64? = nil,
        maxFutureDriftMs: Int64 = maxCandidateFutureDriftMs
    ) -> Int64 {
        let parentFloor = previousTimestamp.addingReportingOverflow(1).overflow ? Int64.max : previousTimestamp + 1
        let medianFloor: Int64
        if let median = medianTimePast(ancestorTimestamps) {
            medianFloor = median.addingReportingOverflow(1).overflow ? Int64.max : median + 1
        } else {
            medianFloor = Int64.min
        }
        let monotoneFloor = previousCandidateTimestamp ?? Int64.min
        let lowerBound = max(parentFloor, medianFloor, monotoneFloor)
        let upperBound = nowMs.addingReportingOverflow(maxFutureDriftMs).overflow ? Int64.max : nowMs + maxFutureDriftMs
        return min(max(nowMs, lowerBound), upperBound)
    }

    internal static func shouldRestampCandidate(
        nowMs: Int64,
        lastRestampMs: Int64,
        intervalMs: Int64 = timestampRestampIntervalMs
    ) -> Bool {
        let deadline = lastRestampMs.addingReportingOverflow(intervalMs)
        return deadline.overflow || nowMs >= deadline.partialValue
    }

    public init(
        chainState: ChainState,
        mempool: NodeMempool,
        fetcher: Fetcher,
        spec: ChainSpec,
        chainPath: [String],
        identity: MinerIdentity? = nil,
        coinbaseRecipientAddress: String? = nil,
        batchSize: UInt64 = 10_000,
        tipCache: TipCache? = nil,
        timestampOverride: Int64? = nil,
        nowProvider: (@Sendable () -> Int64)? = nil
    ) {
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
        self.chainPath = chainPath
        self.identity = identity
        self.coinbaseRecipientAddress = coinbaseRecipientAddress
        self.batchSize = batchSize
        self.tipCache = tipCache
        self.timestampOverride = timestampOverride
        self.nowProvider = nowProvider ?? { Self.currentTimeMilliseconds() }
    }

    /// Resolve (or reuse) the miner's account-trie slice for `tip`. Cached
    /// after the first successful call after a tip change; subsequent
    /// callers share the same resolved paths. When `tip` is `cachedTipBlock`
    /// straight off the submit path, `frontier.node` is already populated
    /// by BlockBuilder — we extract the trie directly without re-fetching.
    private func minerAccountTrie(tip: Block, identity: MinerIdentity) async -> AccountState? {
        if let cached = cachedMinerAccountTrie { return cached }
        let nonceKey = AccountStateHeader.nonceTrackingKey(identity.address)
        // Happy path: freshly-mined block has its frontier fully resolved
        // already (BlockBuilder ran proveAndUpdateState on both paths).
        if let frontier = tip.postState.node,
           let trie = frontier.accountState.node,
           (try? trie.get(key: nonceKey)) != nil || (try? trie.get(key: identity.address)) != nil {
            cachedMinerAccountTrie = trie
            return trie
        }
        // Gossip-advance or cold start: resolve both paths in one shot.
        guard let frontierNode = try? await tip.postState.resolve(fetcher: fetcher).node else { return nil }
        guard let resolved = try? await frontierNode.accountState.resolve(
            paths: [[nonceKey]: .targeted, [identity.address]: .targeted],
            fetcher: fetcher
        ) else { return nil }
        guard let trie = resolved.node else { return nil }
        cachedMinerAccountTrie = trie
        return trie
    }

    /// Build one candidate block for the local chain and search for a valid
    /// nonce. Returns the sealed block plus the mempool removals to
    /// apply on acceptance, or `nil` if the tip moved, no nonce was found this
    /// round, or the task was cancelled.
    ///
    /// This is the one-shot core: the production loop drives it repeatedly, and
    /// tests drive it directly (no continuous loop, no delegate, no RPC). It is
    /// NOT a miner — producing a block on demand is just block assembly + PoW.
    public func produceBlock() async throws -> ProducedMinedBlock? {
        let log = NodeLogger("miner")
        guard let tipResult = try await resolveCurrentTip() else { return nil }
        let previousBlock = tipResult.block
        let previousBlockHash = tipResult.cid  // already computed — no reserialisation
        let initialNowMs = timestampOverride ?? nowProvider()
        let timestampValidationAncestors: [Int64]
        if let fast = await chainState.getMainChainTimestamps(
            forParentHash: previousBlockHash,
            count: Self.timestampMedianPastWindow
        ) {
            timestampValidationAncestors = fast
        } else {
            timestampValidationAncestors = await Self.collectAncestorTimestamps(
                from: previousBlock,
                count: Self.timestampMedianPastWindow,
                fetcher: fetcher
            )
        }
        var candidateTimestamp = timestampOverride ?? Self.adjustedCandidateTimestamp(
            nowMs: initialNowMs,
            previousTimestamp: previousBlock.timestamp,
            ancestorTimestamps: timestampValidationAncestors
        )
        var lastRestampWallClockMs = initialNowMs
        log.info("\(chainPath.last ?? ""): mining on tip \(String(previousBlockHash.prefix(16)))… at index \(previousBlock.height), building block \(previousBlock.height + 1)")

        let maxTxCount = Int(spec.maxNumberOfTransactionsPerBlock) - 1 // reserve slot for coinbase
        var transactions = await mempool.selectTransactions(maxCount: max(0, maxTxCount))
        // keep the user-transaction set separate from the coinbase
        // so we can trim it (and rebuild the coinbase) if the assembled block
        // exceeds spec.maxBlockSize / spec.maxStateGrowth.
        var userTransactions = transactions

        do {
            if let coinbase = try await buildCoinbaseTransaction(
                previousBlock: previousBlock,
                previousBlockHash: previousBlockHash,
                mempoolTransactions: transactions
            ) {
                // Coinbase goes AFTER user txs so its nonce doesn't
                // collide with same-authority mempool transactions.
                transactions.append(coinbase)
            }
        } catch {
            NodeLogger("miner").warn("Coinbase build failed: \(error)")
        }
        let blockTarget = max(previousBlock.nextTarget, ChainSpec.minimumTarget)
        let nextBlockIndex = previousBlock.height + 1
        // P-402: prefer the in-memory ChainState fast path over N
        // sequential CAS fetches. getMainChainTimestamps reads from
        // the blockTimestamps dict (O(n) in memory, no I/O).
        // Fall back to the CAS walk only if the chain doesn't have
        // the block in its in-memory retention window.
        func computeNextTarget(timestamp: Int64) async -> UInt256 {
            await Self.canonicalNextTarget(
                chainState: chainState,
                spec: spec,
                parentHash: previousBlockHash,
                parentBlock: previousBlock,
                timestamp: timestamp,
                blockTarget: blockTarget,
                fetcher: fetcher
            )
        }
        let blockFetcher: Fetcher = fetcher
        var computedNextTarget = await computeNextTarget(timestamp: candidateTimestamp)

        // assemble the nexus template for a user-tx set, then trim the
        // lowest-priority user transaction (rebuilding the coinbase over the
        // smaller set) until the sealed block fits spec.maxBlockSize /
        // spec.maxStateGrowth — down to coinbase-only. Assembly otherwise bounds
        // only tx-count, so an oversize template would be mined then rejected
        // (wasted PoW). Used for BOTH the initial assembly and every restamp
        // rebuild so neither path can seal a doomed block.
        func assembleFittingTemplate(
            userTransactions: [Transaction],
            timestamp: Int64,
            nextTarget: UInt256
        ) async throws -> (block: Block, transactions: [Transaction], userTransactions: [Transaction]) {
            func build(_ users: [Transaction]) async throws -> (block: Block, transactions: [Transaction]) {
                var txs = users
                if let coinbase = try? await buildCoinbaseTransaction(
                    previousBlock: previousBlock,
                    previousBlockHash: previousBlockHash,
                    mempoolTransactions: users
                ) {
                    txs.append(coinbase)
                }
                return try await buildNexusTemplate(
                    previousBlock: previousBlock,
                    transactions: txs,
                    timestamp: timestamp,
                    blockTarget: blockTarget,
                    nextTarget: nextTarget,
                    blockFetcher: blockFetcher,
                    nextBlockIndex: nextBlockIndex
                )
            }
            var remaining = userTransactions
            var built = try await build(remaining)
            while !remaining.isEmpty
                && !Self.templateFitsBlockLimits(built.block, transactions: built.transactions, spec: spec) {
                remaining.removeLast()
                built = try await build(remaining)
            }
            if !Self.templateFitsBlockLimits(built.block, transactions: built.transactions, spec: spec) {
                // No user txs left to drop and still over a cap — maxBlockSize
                // is misconfigured below the empty-block envelope. Nothing more
                // the producer can do; seal it (the validator will reject) and
                // surface why.
                log.warn("\(chainPath.last ?? ""): block still exceeds size/state-growth caps with no user transactions left to drop; sealing anyway")
            }
            return (built.block, built.transactions, remaining)
        }

        var assembled = try await assembleFittingTemplate(
            userTransactions: userTransactions,
            timestamp: candidateTimestamp,
            nextTarget: computedNextTarget
        )
        var template = assembled.block
        transactions = assembled.transactions
        userTransactions = assembled.userTransactions
        var midstate = ProofOfWork.midstate(for: template)
        let target = max(previousBlock.nextTarget, ChainSpec.minimumTarget)
        let batchSize = self.batchSize
        let workerCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
        log.info("\(chainPath.last ?? ""): nonce search started for block \(previousBlock.height + 1) (target=\(String(target.toHexString().prefix(16)))… workers=\(workerCount) batch=\(batchSize))")

        while !Task.isCancelled {
            // Lock-free tip check avoids actor hop into ChainState per batch
            let currentTip: String
            if let cached = tipCache?.tip {
                currentTip = cached
            } else {
                currentTip = await chainState.getMainChainTip()
            }
            if currentTip != previousBlockHash { return nil }

            if timestampOverride == nil {
                let nowMs = nowProvider()
                if Self.shouldRestampCandidate(
                    nowMs: nowMs,
                    lastRestampMs: lastRestampWallClockMs
                ) {
                    let refreshedTimestamp = Self.adjustedCandidateTimestamp(
                        nowMs: nowMs,
                        previousTimestamp: previousBlock.timestamp,
                        ancestorTimestamps: timestampValidationAncestors,
                        previousCandidateTimestamp: candidateTimestamp
                    )
                    if refreshedTimestamp != candidateTimestamp {
                        computedNextTarget = await computeNextTarget(timestamp: refreshedTimestamp)
                        // re-apply the size/state-growth trim on the
                        // restamp rebuild too, so a refreshed template set
                        // can't bypass the cap.
                        assembled = try await assembleFittingTemplate(
                            userTransactions: userTransactions,
                            timestamp: refreshedTimestamp,
                            nextTarget: computedNextTarget
                        )
                        template = assembled.block
                        transactions = assembled.transactions
                        userTransactions = assembled.userTransactions
                        midstate = ProofOfWork.midstate(for: template)
                        candidateTimestamp = refreshedTimestamp
                    }
                    lastRestampWallClockMs = nowMs
                }
            }

            let layout = Self.nonceRoundLayout(
                startNonce: nonceOffset,
                batchSize: batchSize,
                workerCount: workerCount
            )
            let foundNonce = await ProofOfWork.searchNonce(
                midstate: midstate,
                target: target,
                ranges: layout.ranges
            )

            if let foundNonce {
                let mined = ProofOfWork.withNonce(template, nonce: foundNonce)
                let nexusPoWHash = mined.proofOfWorkHash()
                let rootClearsTarget = mined.validateProofOfWork(nexusHash: nexusPoWHash)
                guard rootClearsTarget else {
                    nonceOffset = foundNonce &+ 1
                    await Task.yield()
                    continue
                }
                let confirmedCIDs = Set(transactions.map { $0.body.rawCID })
                let pendingRemovals = MinedBlockPendingRemovals(
                    nexusTxCIDs: confirmedCIDs
                )
                // Cache the fully-resolved mined block so the next
                // produceBlock's resolveCurrentTip reuses it (BlockBuilder
                // already populated postState.node).
                cachedTipBlock = mined
                cachedTipCID = try VolumeImpl<Block>(node: mined).rawCID
                cachedMinerAccountTrie = mined.postState.node?.accountState.node
                return ProducedMinedBlock(
                    block: mined,
                    pendingRemovals: pendingRemovals,
                    rootHash: nexusPoWHash,
                    rootClearsTarget: rootClearsTarget
                )
            }

            nonceOffset &+= layout.advance
            await Task.yield()
        }
        return nil
    }

    // MARK: - Coinbase Transaction

    /// Resolve the miner's latest transaction nonce from the previous block's state.
    /// Returns nil when the state can't be read or no nonce exists yet.
    private static func resolveLatestMinerNonce(
        previousBlock: Block,
        identity: MinerIdentity,
        fetcher: Fetcher
    ) async -> UInt64? {
        guard let frontierNode = try? await previousBlock.postState.resolve(fetcher: fetcher).node else { return nil }
        let nonceKey = AccountStateHeader.nonceTrackingKey(identity.address)
        guard let resolvedAccounts = try? await frontierNode.accountState.resolve(
            paths: [[nonceKey]: .targeted],
            fetcher: fetcher
        ) else { return nil }
        guard let accountsNode = resolvedAccounts.node,
              let nonce: UInt64 = try? accountsNode.get(key: nonceKey) else { return nil }
        return nonce
    }

    /// Build a coinbase transaction that credits `recipientAddress` (defaulting
    /// to `identity.address`) by `reward + fees` for `previousBlock.height + 1`
    /// on `spec`. Callers append this to the block's transaction list so the
    /// reward is collected; child chains use the same helper with their own
    /// spec/fetcher. `chainPath` must equal the full nexus-to-chain path expected
    /// by `validateChainPaths`, e.g. `["Nexus","FastTest"]` for a FastTest coinbase.
    ///
    /// (Mechanism A): the coinbase credit is positive, and Lattice
    /// only requires authorization (a matching signer) for *debits*
    /// (`accountActionsAreValid` checks `where action.isDebit`). So the signer
    /// (`identity`) may differ from the payout recipient (`recipientAddress`):
    /// the node signs with a node-local coinbase authority while crediting a public
    /// payout address, never holding the payout address's private key. The
    /// per-signer nonce is tracked against `identity.address` (the authority),
    /// leaving the payout account's user-spend nonce untouched.
    static func buildCoinbaseTransaction(
        spec: ChainSpec,
        identity: MinerIdentity,
        chainPath: [String],
        previousBlock: Block,
        mempoolTransactions: [Transaction],
        fetcher: Fetcher,
        cachedLatestNonce: UInt64? = nil,
        recipientAddress: String? = nil
    ) async throws -> Transaction? {
        let reward = spec.rewardAtBlock(previousBlock.height + 1)
        var totalFees: UInt64 = 0
        for tx in mempoolTransactions {
            guard let fee = tx.body.node?.fee else { continue }
            let (newTotal, overflow) = totalFees.addingReportingOverflow(fee)
            if overflow { return nil }
            totalFees = newTotal
        }
        let (rawPayout, payoutOverflow) = reward.addingReportingOverflow(totalFees)
        // cap the coinbase at the representable maximum rather than
        // forfeiting the entire reward+fees when the sum exceeds Int64.max
        // (AccountAction.delta is Int64). On overflow the sum is past Int64.max,
        // so it saturates to the cap. Only a zero payout yields no coinbase.
        let payout = payoutOverflow ? UInt64(Int64.max) : min(rawPayout, UInt64(Int64.max))
        guard payout > 0 else { return nil }

        // Coinbase nonce must follow the coinbase authority's latest nonce in the state
        // PLUS any same-authority mempool txs that precede the coinbase in the block.
        // `cachedLatestNonce` short-circuits the targeted frontier resolve
        // when the caller (BlockProducer) knows `previousBlock` is the same tip
        // it just mined on — we are the sole writer of our own nonce, so
        // the last coinbase we produced IS the current frontier value.
        // Skipping the resolve drops the fetch round-trips per trie level
        // to zero on cache hit.
        let latestNonce: UInt64?
        if let cached = cachedLatestNonce {
            latestNonce = cached
        } else {
            latestNonce = await resolveLatestMinerNonce(
                previousBlock: previousBlock, identity: identity, fetcher: fetcher
            )
        }
        let authorityTxsInBlock = mempoolTransactions.filter { tx in
            tx.body.node?.signers.contains(identity.address) == true
        }.count
        // TransactionState.proveAndUpdateState requires the first-ever nonce for
        // a signer to be 0, regardless of the current block index. Using
        // previousBlock.index here meant a fresh authority joining a non-genesis
        // chain always hit nonceGap and the block fell back to empty (no reward).
        let coinbaseNonce: UInt64
        if let latest = latestNonce {
            let (step1, o1) = latest.addingReportingOverflow(1)
            let (step2, o2) = step1.addingReportingOverflow(UInt64(authorityTxsInBlock))
            if o1 || o2 { return nil }
            coinbaseNonce = step2
        } else {
            coinbaseNonce = UInt64(authorityTxsInBlock)
        }

        let accountAction = AccountAction(
            owner: recipientAddress ?? identity.address,
            delta: Int64(payout)
        )

        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [identity.address],
            fee: 0,
            nonce: coinbaseNonce,
            chainPath: chainPath
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)

        guard let signature = TransactionSigning.sign(body: body, bodyCID: bodyHeader.rawCID, privateKeyHex: identity.privateKeyHex) else { return nil }

        return Transaction(
            signatures: [identity.publicKeyHex: signature],
            body: bodyHeader
        )
    }

    private func buildCoinbaseTransaction(
        previousBlock: Block,
        previousBlockHash: String,
        mempoolTransactions: [Transaction]
    ) async throws -> Transaction? {
        guard let identity = identity else { return nil }
        // Only use the cached account trie when the tip we're about to
        // mine on is exactly the one our cache was derived from. Any CID
        // mismatch means a reorg/gossip advance arrived between iterations
        // and the cached paths are stale.
        let cachedNonce: UInt64?
        if cachedTipCID == previousBlockHash,
           let trie = await minerAccountTrie(tip: previousBlock, identity: identity) {
            let nonceKey = AccountStateHeader.nonceTrackingKey(identity.address)
            cachedNonce = try? trie.get(key: nonceKey)
        } else {
            cachedNonce = nil
        }
        return try await Self.buildCoinbaseTransaction(
            spec: spec,
            identity: identity,
            chainPath: chainPath,
            previousBlock: previousBlock,
            mempoolTransactions: mempoolTransactions,
            fetcher: fetcher,
            cachedLatestNonce: cachedNonce,
            recipientAddress: coinbaseRecipientAddress
        )
    }

    // MARK: - Template Assembly

    private func buildNexusTemplate(
        previousBlock: Block,
        transactions inputTransactions: [Transaction],
        timestamp: Int64,
        blockTarget: UInt256,
        nextTarget: UInt256,
        blockFetcher: Fetcher,
        nextBlockIndex: UInt64
    ) async throws -> (block: Block, transactions: [Transaction]) {
        let hasCoinbase = identity != nil && !inputTransactions.isEmpty
        return try await TemplateAssembly.buildWithFallback(
            directory: chainPath.last ?? "",
            context: "block \(nextBlockIndex)",
            transactions: inputTransactions,
            hasCoinbase: hasCoinbase,
            build: { txs in
                try await BlockBuilder.buildBlock(
                    previous: previousBlock,
                    transactions: txs,
                    timestamp: timestamp,
                    target: blockTarget,
                    nextTarget: nextTarget,
                    nonce: 0,
                    fetcher: blockFetcher
                )
            },
            removeFromMempool: { await self.mempool.remove(txCID: $0) }
        )
    }

    // MARK: - Helpers

    /// a produced block must satisfy the same size / state-growth caps the
    /// validator enforces (`Block.validateBlockSize` / `validateStateDeltaSize`), so the
    /// producer never burns PoW on a block that would be rejected. Block size is checked
    /// exactly via the public `toData()`. State growth is bounded *conservatively* by the
    /// summed serialized transaction-body sizes — an upper bound on the true state delta
    /// (a tx cannot grow state by more than the bytes it carries), because the exact
    /// `TransactionBody.getStateDelta()` is `internal` to the Lattice module and not
    /// callable here. The conservative bound may trim slightly more aggressively than the
    /// validator strictly requires, but never seals an over-limit block.
    private static func templateFitsBlockLimits(
        _ block: Block, transactions: [Transaction], spec: ChainSpec
    ) -> Bool {
        guard (block.toData()?.count ?? Int.max) <= spec.maxBlockSize else { return false }
        var growth = 0
        for tx in transactions {
            // A body we cannot measure is treated as not-fitting (conservative): never
            // declare a block within the state-growth cap when part of it is unbounded.
            guard let bodySize = tx.body.node?.toData()?.count else { return false }
            growth += bodySize
            if growth > spec.maxStateGrowth { return false }
        }
        return true
    }

    /// the canonical copy of this windowed-timestamp walk lives in the Lattice
    /// module (`Block+Validate`'s ancestor-timestamp collection used by the retarget
    /// validator). This node-local copy exists because the helper is `internal` to Lattice
    /// and cannot be reused across the module boundary; the LWMA retarget itself is
    /// consensus-shared, so the producer and validator feed identical windowed timestamps
    /// into the same `calculateWindowedTarget` — there is no producer/validator drift to
    /// reconcile here.
    private static func collectAncestorTimestamps(from block: Block, count: UInt64, fetcher: Fetcher) async -> [Int64] {
        var timestamps: [Int64] = [block.timestamp]
        var current = block
        for _ in 1..<count {
            guard let prev = try? await current.parent?.resolve(fetcher: fetcher) else { break }
            timestamps.append(prev.timestamp)
            current = prev
        }
        return timestamps
    }

    /// Compute the next-block PoW target for a block extending `parentBlock`,
    /// reading ancestor timestamps from the in-memory main-chain index
    /// (`ChainState.getMainChainTimestamps`) and falling back to the on-CAS
    /// ancestor walk only when the index can't serve the window.
    ///
    /// This is the single source of truth for `nextTarget` on the production
    /// side, used by BOTH the internal producer and the external-miner template
    /// route. It MUST read the same timestamp source the validator reads
    /// (`validateTimestampAndNextTarget` → `getMainChainTimestamps`): the
    /// in-memory index retains ancestor timestamps after a content prune, but the
    /// CAS ancestor walk (`BlockBuilder.buildBlock`'s internal default) breaks at
    /// the first pruned body and returns a short window. A short window over
    /// recent fast-solve blocks hardens the target past what the validator — which
    /// still sees the full window via the index — expects, so every externally
    /// mined block is rejected and the chain freezes once mining outruns the
    /// retention window. Routing both producers through this keeps production and
    /// validation computing `nextTarget` from the identical window.
    static func canonicalNextTarget(
        chainState: ChainState,
        spec: ChainSpec,
        parentHash: String,
        parentBlock: Block,
        timestamp: Int64,
        blockTarget: UInt256,
        fetcher: Fetcher
    ) async -> UInt256 {
        let windowTimestamps: [Int64]
        if let fast = await chainState.getMainChainTimestamps(
            forParentHash: parentHash,
            count: spec.retargetWindow
        ) {
            windowTimestamps = [timestamp] + fast
        } else {
            let ancestorTimestamps = await collectAncestorTimestamps(
                from: parentBlock, count: spec.retargetWindow, fetcher: fetcher
            )
            windowTimestamps = [timestamp] + ancestorTimestamps
        }
        return spec.calculateWindowedTarget(
            previousTarget: blockTarget,
            ancestorTimestamps: windowTimestamps
        )
    }

    /// Returns the current tip block AND its CID. The CID is returned alongside
    /// the block so callers never need to recompute it via try VolumeImpl(node:).rawCID
    /// — that involves CBOR serialisation + SHA256 + multibase encoding every call.
    private func resolveCurrentTip() async throws -> (block: Block, cid: String)? {
        let tipHash = await chainState.getMainChainTip()
        if let cachedCID = cachedTipCID, let cachedBlock = cachedTipBlock, cachedCID == tipHash {
            return (cachedBlock, cachedCID)  // zero-cost: CID already known
        }
        // Tip changed (reorg or gossip advance) — drop stale cache
        cachedTipBlock = nil
        cachedTipCID = nil
        cachedMinerAccountTrie = nil
        let stub = VolumeImpl<Block>(rawCID: tipHash, node: nil, encryptionInfo: nil)
        let resolved = try await stub.resolve(fetcher: fetcher)
        guard let block = resolved.node else { return nil }
        // tipHash IS the CID (we fetched by it), so no recomputation needed.
        return (block, tipHash)
    }

}
