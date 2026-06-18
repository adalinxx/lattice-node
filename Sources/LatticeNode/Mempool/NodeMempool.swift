import Lattice
import Foundation
import cashew

/// Per-trie key sets tracking which state keys a transaction touches.
/// Separate sets per state trie — no prefix disambiguation needed.
public struct StateKeySet: Sendable {
    public var accounts: Set<String> = []
    public var deposits: Set<String> = []
    public var receipts: Set<String> = []
    public var general: Set<String> = []
    public var genesis: Set<String> = []

    public static func from(_ body: TransactionBody) -> StateKeySet {
        var s = StateKeySet()
        for a in body.accountActions { s.accounts.insert(a.owner) }
        for a in body.depositActions { s.deposits.insert(DepositKey(depositAction: a).description) }
        for a in body.withdrawalActions { s.deposits.insert(DepositKey(withdrawalAction: a).description) }
        for a in body.receiptActions {
            s.receipts.insert(ReceiptKey(receiptAction: a).description)
        }
        for a in body.actions { s.general.insert(a.key) }
        for a in body.genesisActions { s.genesis.insert(a.directory) }
        return s
    }

    public func isDisjoint(with other: StateKeySet) -> Bool {
        // accounts excluded: delta model aggregates per owner, so
        // multiple transactions touching the same account are safe
        deposits.isDisjoint(with: other.deposits) &&
        receipts.isDisjoint(with: other.receipts) &&
        general.isDisjoint(with: other.general) &&
        genesis.isDisjoint(with: other.genesis)
    }

    public mutating func formUnion(_ other: StateKeySet) {
        accounts.formUnion(other.accounts)
        deposits.formUnion(other.deposits)
        receipts.formUnion(other.receipts)
        general.formUnion(other.general)
        genesis.formUnion(other.genesis)
    }
}

public struct MempoolEntry: Sendable {
    public let transaction: Transaction
    public let cid: String
    public let fee: UInt64
    /// Serialized-body length in bytes — the SAME measure the minFeeRate
    /// floor uses (`body.toData().count`, what validateSize() measures). Cached
    /// per entry so fee-rate eviction never re-serializes on every admission.
    public let bodyBytes: UInt64
    public let sender: String
    public let nonce: UInt64
    public let addedAt: ContinuousClock.Instant
    public let stateKeys: StateKeySet
    /// ALL signer addresses (deduped, primary `sender` first).
    /// Consensus validates every signer's nonce sequence and advances every
    /// signer's nonce on block apply, so per-sender mempool tracking (queue
    /// slot / nonce floor / RBF / cumulative debit) indexes this entry under
    /// EVERY signer, not only `signers.first`.
    public let signers: [String]
    /// per-signer net outflow — the consensus `netDebit`
    /// restricted to each net-negative signer. Each value is the per-tx
    /// contribution to that signer's cumulative double-spend bound; summed
    /// across the signer's queued txs it must not exceed the signer's confirmed
    /// on-chain balance. Mirrors the consensus per-owner balance check so the
    /// mempool can bound a signer across MULTIPLE nonces (which the per-tx
    /// consensus check, run independently, cannot).
    public let debitBySigner: [String: UInt64]

    /// The primary signer's net outflow (legacy single-sender view).
    public var senderDebit: UInt64 { debitBySigner[sender] ?? 0 }

    public init(
        transaction: Transaction,
        cid: String,
        fee: UInt64,
        bodyBytes: UInt64,
        sender: String,
        nonce: UInt64,
        addedAt: ContinuousClock.Instant,
        stateKeys: StateKeySet,
        senderDebit: UInt64 = 0,
        signers: [String]? = nil,
        debitBySigner: [String: UInt64]? = nil
    ) {
        self.transaction = transaction
        self.cid = cid
        self.fee = fee
        self.bodyBytes = bodyBytes
        self.sender = sender
        self.nonce = nonce
        self.addedAt = addedAt
        self.stateKeys = stateKeys
        self.signers = signers ?? [sender]
        self.debitBySigner = debitBySigner ?? (senderDebit > 0 ? [sender: senderDebit] : [:])
    }

    /// Fee per serialized-body byte, scaled by FEE_RATE_SCALE to keep integer
    /// precision (a tx paying fee=15 over a 340-byte body has rate 0 under naive
    /// integer division). Reuses the byte measure. bodyBytes is always
    /// >= 1 for an admitted tx (an empty body cannot serialize), so the divide is
    /// safe; the `max(.,1)` is belt-and-suspenders against a degenerate 0.
    public var feeRate: UInt64 {
        let scaled = fee.multipliedReportingOverflow(by: FEE_RATE_SCALE)
        let numerator = scaled.overflow ? UInt64.max : scaled.partialValue
        return numerator / max(bodyBytes, 1)
    }
}

/// Fixed-point scale for fee-rate comparison so sub-1-per-byte rates stay
/// distinguishable under integer division.
private let FEE_RATE_SCALE: UInt64 = 1_000_000

public struct AccountTxQueue: Sendable {
    public var txsByNonce: [UInt64: MempoolEntry] = [:]
    public var confirmedNonce: UInt64 = 0

    public init(txsByNonce: [UInt64: MempoolEntry] = [:], confirmedNonce: UInt64 = 0) {
        self.txsByNonce = txsByNonce
        self.confirmedNonce = confirmedNonce
    }
}

/// R5: typed mempool rejection classification. Peer-penalty decisions
/// (`GossipAdmission` via `ConsensusClass`) previously string-prefix-matched the
/// human rejection message, so a reworded message silently reclassified them.
/// Every rejection site now states its kind explicitly; the message remains the
/// human string for logs/RPC and is NEVER consulted for classification.
public enum MempoolRejectionKind: Sendable, Equatable {
    // addTransaction sites
    case missingBody
    case duplicate
    case feeFloor
    case feeRateFloor
    case nonceConfirmed
    case nonceGap
    case multiSignerNonceConflict
    case accountLimit
    case cumulativeDebit
    case oversizedBody
    case full
    case feeRateOutbid
    // tryReplace (RBF) sites
    case rbfUnderpay
    case rbfStateKeyConflict
    case rbfByteBudget
    // admission-funnel sites (LatticeNode+Transactions) — these carry their
    // ConsensusClass explicitly at the construction site; the kind exists so
    // every AddResult rejection is typed.
    case unknownChain
    case chainUnavailable
    case invalidChainPath
    case validationFailed
    case policyViolation
    case stateUnavailable
}

/// A typed rejection: `kind` drives classification, `message` is the unchanged
/// human string. Interpolating a rejection (`"\(reason)"`) yields the message,
/// so existing log call sites print exactly what they printed before.
public struct MempoolRejection: Sendable, Equatable, CustomStringConvertible {
    public let kind: MempoolRejectionKind
    public let message: String

    public init(kind: MempoolRejectionKind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

public enum AddResult: Sendable {
    case added
    case replacedExisting(oldCID: String)
    case rejected(reason: MempoolRejection)

    /// Shorthand producer keeping rejection sites compact.
    static func rejected(_ kind: MempoolRejectionKind, _ message: String) -> AddResult {
        .rejected(reason: MempoolRejection(kind: kind, message: message))
    }
}

/// H7: the NODE-WIDE mempool byte budget, shared across every chain's
/// `NodeMempool`. The byte cap bounds the node's MEMORY, which is a property of
/// the node, not of any single chain — so all mempools debit/credit one shared
/// accountant rather than each holding an independent per-chain slice. This keeps
/// the cap correct under dynamic chain registration (a chain added later shares
/// the same budget instead of getting a fresh full/partial cap, so the aggregate
/// can't grow with chain count) and avoids per-chain-floor amplification.
/// `maxBytes == nil` means UNBOUNDED bytes (the per-chain count cap still applies).
public final class MempoolByteLimiter: @unchecked Sendable {
    public let maxBytes: UInt64?
    private let lock = NSLock()
    private var _used: UInt64 = 0

    public init(maxBytes: UInt64?) { self.maxBytes = maxBytes }

    /// Node-wide bytes currently retained across ALL chains' mempools.
    public func used() -> UInt64 { lock.lock(); defer { lock.unlock() }; return _used }

    /// Atomically admit `incoming` bytes against the node-wide budget, crediting
    /// `freed` bytes the caller will remove from its OWN mempool in the same
    /// admission. Under ONE lock: if `used - freed + incoming` fits `maxBytes`,
    /// commit the net delta and return true; otherwise leave `_used` unchanged and
    /// return false. This makes check+reserve atomic across chain mempool actors —
    /// two chains can no longer both read the same `used()` and both reserve past
    /// the cap. `maxBytes == nil` => unbounded (always admits, still tracks usage).
    /// On success the caller MUST apply the matching local mutations WITHOUT further
    /// limiter adjustment (removeEntry/insertEntry with adjustLimiter: false), since
    /// the net delta is already committed here. On failure it must mutate nothing.
    func tryReserve(incoming: UInt64, freed: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let base = _used >= freed ? _used - freed : 0
        let (projected, overflow) = base.addingReportingOverflow(incoming)
        let projectedTotal = overflow ? UInt64.max : projected
        if let maxBytes, projectedTotal > maxBytes { return false }
        _used = projectedTotal
        return true
    }

    /// Unconditional debit — for entries inserted outside an atomic admission.
    func reserveUnchecked(_ n: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let (sum, overflow) = _used.addingReportingOverflow(n)
        _used = overflow ? .max : sum
    }

    /// Credit bytes back — for entries that leave the pool outside an admission
    /// commit (expiry prune, explicit removal, reorg eviction, removeAll).
    func release(_ n: UInt64) {
        lock.lock(); defer { lock.unlock() }
        _used = _used >= n ? _used - n : 0
    }
}

public actor NodeMempool {
    private var byCID: [String: MempoolEntry] = [:]
    private var byAccount: [String: AccountTxQueue] = [:]
    /// Drained senders retain only their confirmed nonce floor here, not a full
    /// empty AccountTxQueue. Bounded by `confirmedNonceFloorLimit` and evicted as
    /// LRU so active + recent senders are bounded by mempool capacity.
    private var confirmedNonceFloorByAccount: [String: UInt64] = [:]
    private var confirmedNonceFloorGenerationByAccount: [String: UInt64] = [:]
    private var confirmedNonceFloorLRU: [(sender: String, generation: UInt64)] = []
    private var confirmedNonceFloorLRUHead: Int = 0
    private var nextConfirmedNonceFloorGeneration: UInt64 = 0
    /// Ordered by (feeRate DESC, addedAt ASC). Both block-template
    /// selection (`selectTransactions`) and the eviction victim (`sortedEntries.last`,
    /// the lowest fee-rate resident) read this single ordering, so eviction-by-rate
    /// and selection-by-rate stay consistent and the victim is O(1) instead of an
    /// O(n) min-scan.
    private var sortedEntries: [MempoolEntry] = []
    /// CID → current index in `sortedEntries`. Lets `removeEntry`
    /// locate the doomed element directly instead of binary-searching the fee tier
    /// and LINEAR-scanning equal-rate entries (which is O(n) when rates cluster at
    /// the floor, making `pruneExpired` O(n²)). Maintained on every insert/remove.
    private var indexByCID: [String: Int] = [:]
    /// Test-only operation counter. Counts the ACTUAL dominant
    /// work of the removal paths: every `indexByCID` write performed by a reindex
    /// (`reindexFrom`/`rebuildIndex`) plus every equal-tier comparison in the
    /// fallback scan. This is the metric that distinguishes O(k·log n)/O(n) batch
    /// pruning from the pre-fix per-entry `removeEntry` loop, where each removal
    /// reindexed the whole array tail — totalling ~N²/2 index writes across a full
    /// `pruneExpired`. `MempoolPruneComplexityTests` asserts a sub-quadratic bound
    /// on it, so a regression to per-entry full-tail reindex would FAIL the test.
    internal var lastRemovalScanSteps: Int = 0
    /// CID→Data view served via the mempool overlay source. Maintained incrementally
    /// on insert/remove so `fetcherCache()` is O(1); the previous build-on-call
    /// approach re-serialized every transaction and body on every miner round
    /// (P1 #6).
    private var cachedFetcherData: [String: Data] = [:]
    private var generation: UInt64 = 0
    private let maxSize: Int
    private let confirmedNonceFloorLimit: Int
    /// H7: optional byte budget — the maximum sum of admitted entries'
    /// `bodyBytes` the mempool may retain. `nil` leaves the mempool bounded by
    /// COUNT only (legacy behavior). When set, admission rejects a newcomer that
    /// would push the total past the budget (after fee-rate eviction tries to
    /// make room), and eviction evicts the lowest-fee-rate residents until BOTH
    /// the byte total and the count are within budget.
    /// H7: the NODE-WIDE byte budget this mempool debits/credits. Shared across
    /// every chain's mempool (or a private single-chain limiter when constructed
    /// standalone), so the byte cap bounds total node memory rather than each chain
    /// independently. `byteLimiter.maxBytes == nil` means unbounded bytes.
    private let byteLimiter: MempoolByteLimiter
    /// H7: running sum of THIS chain's `bodyBytes` across its resident entries.
    /// Maintained incrementally by insertEntry/removeEntry. Used to size how many
    /// bytes eviction can free from THIS chain (it can only evict its own
    /// residents); the budget check itself reads the node-wide `byteLimiter`.
    private var totalBytes: UInt64 = 0
    /// Maximum queued transactions per sender. `UInt64` per the storage-agent
    /// interface contract (`NodeResourceConfig.mempoolMaxPerAccount` is `UInt64`).
    private let maxPerAccount: UInt64
    /// Largest permitted distance between an admitted tx's nonce and the
    /// sender's currently-confirmed nonce. Caps how far into the future a
    /// sender can reserve slots — a sender submitting `confirmedNonce +
    /// 100_000` would otherwise squat slots that can never clear until
    /// 99_999 earlier nonces arrive.
    private let maxNonceGap: UInt64
    /// Absolute minimum fee for admission, independent of mempool fullness.
    /// Defaults to 0 to preserve existing behavior; raise to impose a spam tax.
    private let minFeeFloor: UInt64
    /// Node-local minimum fee RATE in units per serialized-body byte.
    /// A transaction whose `fee < minFeeRate * body.bytes` is rejected from THIS
    /// node's mempool admission and not relayed. This is mempool/relay POLICY
    /// only — it is NOT a consensus rule: a below-floor tx in a received block is
    /// still consensus-valid (another miner may run a lower floor), so
    /// Block+Validate is intentionally untouched. Defaults to 0 to preserve
    /// existing behavior; NodeCommand wires the configured default of 1.
    private let minFeeRate: UInt64

    public init(
        maxSize: Int = 10_000,
        maxBytes: UInt64? = nil,
        byteLimiter: MempoolByteLimiter? = nil,
        maxPerAccount: UInt64 = NodeTuning.Mempool().maxPerAccount,
        maxNonceGap: UInt64 = NodeTuning.Mempool().maxNonceGap,
        minFeeFloor: UInt64 = 0,
        minFeeRate: UInt64 = 0
    ) {
        self.maxSize = maxSize
        self.confirmedNonceFloorLimit = max(0, maxSize)
        // A shared node-wide limiter takes precedence; otherwise wrap the local
        // `maxBytes` in a private single-chain limiter so all byte-accounting flows
        // through one path. (Both nil => unbounded bytes.)
        self.byteLimiter = byteLimiter ?? MempoolByteLimiter(maxBytes: maxBytes)
        self.maxPerAccount = maxPerAccount
        self.maxNonceGap = maxNonceGap
        self.minFeeFloor = minFeeFloor
        self.minFeeRate = minFeeRate
    }

    public var count: Int { byCID.count }

    public var currentGeneration: UInt64 { generation }

    /// test hook: reset the equal-tier scan-step counter so a test
    /// can measure the steps a single `pruneExpired` sweep performs in isolation.
    internal func resetRemovalScanSteps() { lastRemovalScanSteps = 0 }

    /// test hook: read the accumulated equal-tier scan steps.
    internal func removalScanSteps() -> Int { lastRemovalScanSteps }

    internal func accountQueueCountForTesting() -> Int { byAccount.count }

    internal func retainedConfirmedNonceFloorCountForTesting() -> Int {
        confirmedNonceFloorByAccount.count
    }

    internal func retainedConfirmedNonceFloorForTesting(sender: String) -> UInt64? {
        confirmedNonceFloorByAccount[sender]
    }

    /// True when the mempool is at its configured capacity. Used by the gossip
    /// layer to distinguish a capacity rejection (penalize the flooding source)
    /// from a policy/validity rejection (drop only this tx).
    public var isAtCapacity: Bool {
        if byCID.count >= maxSize { return true }
        // Node-wide byte budget: full when the shared accountant is at/over budget.
        if let maxBytes = byteLimiter.maxBytes, byteLimiter.used() >= maxBytes { return true }
        return false
    }

    public func add(transaction: Transaction) -> Bool {
        switch addTransaction(transaction) {
        case .added, .replacedExisting:
            return true
        case .rejected:
            return false
        }
    }

    /// Legacy single-sender admission seam: maps `confirmedBalance`/`senderDebit`
    /// onto the primary signer and funnels into the per-signer overload below.
    public func addTransaction(_ transaction: Transaction, confirmedBalance: UInt64?, senderDebit: UInt64 = 0) -> AddResult {
        let sender = transaction.body.node?.signers.first ?? ""
        var confirmedBalances: [String: UInt64] = [:]
        if let confirmedBalance { confirmedBalances[sender] = confirmedBalance }
        return addTransaction(
            transaction,
            confirmedBalances: confirmedBalances,
            debits: senderDebit > 0 ? [sender: senderDebit] : [:]
        )
    }

    /// Admit `transaction`, atomically enforcing the cumulative
    /// double-spend bound for every signer present in `confirmedBalances`. The
    /// balances are resolved ONCE at the admission seam (the same locked frontier
    /// view the validator's per-tx balance check uses) and passed in here so the
    /// cumulative check and the insert happen in a SINGLE actor-atomic step — no
    /// second await re-reads balance between the check and the insert (closes the
    /// validate->insert TOCTOU for distinct nonces). A signer absent from
    /// `confirmedBalances` leaves its bound inert (legacy callers that admit
    /// without resolving balance), preserving prior behavior.
    ///
    /// (M10): every per-sender structure — nonce floor/gap, the
    /// same-nonce RBF slot, per-account count cap, cumulative debit — is checked
    /// and indexed per EVERY signer, mirroring consensus, which validates all
    /// signers' nonce sequences and all net-negative owners' balances. A
    /// multi-signer tx whose debited/co-signing account is a secondary signer can
    /// no longer evade tracking under that account.
    public func addTransaction(
        _ transaction: Transaction,
        confirmedBalances: [String: UInt64] = [:],
        debits: [String: UInt64] = [:]
    ) -> AddResult {
        guard let body = transaction.body.node else {
            return .rejected(.missingBody, "Missing transaction body")
        }

        let cid = transaction.body.rawCID
        let fee = body.fee
        // Dedup preserving order; an unsigned body degenerates to the legacy
        // single "" key so it cannot bypass per-sender bounds entirely.
        let trackedSigners = Self.orderedUniqueSigners(body.signers)
        let sender = trackedSigners[0]
        let nonce = body.nonce
        let stateKeys = StateKeySet.from(body)
        // Serialized-body length: the SAME measure the floor and
        // validateSize() use. Computed once here and reused for both the rate
        // floor and fee-rate eviction so we never re-serialize per admission.
        let bodyBytes = UInt64(body.toData()?.count ?? 0)

        if byCID[cid] != nil {
            return .rejected(.duplicate, "Duplicate transaction")
        }

        if fee < minFeeFloor {
            return .rejected(.feeFloor, "Fee below floor: \(fee) < \(minFeeFloor)")
        }

        // node-local min-fee-RATE floor (relay policy, NOT consensus).
        // body.bytes is the same serialized length validateSize() measures.
        // Saturating math: minFeeRate * bytes can't wrap and falsely admit.
        if minFeeRate > 0, bodyBytes > 0 {
            let required = minFeeRate.multipliedReportingOverflow(by: bodyBytes)
            let requiredFee = required.overflow ? UInt64.max : required.partialValue
            if fee < requiredFee {
                return .rejected(.feeRateFloor, "Fee below rate floor: \(fee) < \(minFeeRate)/byte * \(bodyBytes) bytes = \(requiredFee)")
            }
        }

        // nonce floor + far-future gap are enforced per EVERY signer —
        // consensus rejects a tx whose nonce is below (or too far above) ANY
        // signer's next expected nonce. A sender at confirmedNonce=5 with
        // maxNonceGap=64 may submit nonces 5..69; a submission at nonce=100_005
        // would pin a slot that can never clear until 99_999 other txs from the
        // same sender arrive first.
        var queueBySigner: [String: AccountTxQueue] = [:]
        queueBySigner.reserveCapacity(trackedSigners.count)
        for signer in trackedSigners {
            let queue = byAccount[signer] ?? AccountTxQueue(
                confirmedNonce: retainedConfirmedNonceFloor(sender: signer) ?? 0
            )
            if nonce < queue.confirmedNonce {
                return .rejected(.nonceConfirmed, "Nonce already confirmed: \(nonce) < \(queue.confirmedNonce)")
            }
            let (gapLimit, gapOverflow) = queue.confirmedNonce.addingReportingOverflow(maxNonceGap)
            if !gapOverflow && nonce > gapLimit {
                return .rejected(.nonceGap, "Nonce gap exceeds limit: \(nonce) > \(gapLimit)")
            }
            queueBySigner[signer] = queue
        }

        // a same-nonce conflict in ANY signer's queue is an RBF event —
        // consensus can confirm only one tx per (signer, nonce) slot, so a
        // multi-signer tx colliding with a resident through a secondary signer
        // must displace it (paying the package fee) or be rejected, never be
        // admitted alongside it. Conflicts with several DISTINCT residents at
        // once (one per signer) cannot be expressed as a single replacement —
        // fail closed.
        var conflictsByCID: [String: MempoolEntry] = [:]
        for signer in trackedSigners {
            if let existing = queueBySigner[signer]?.txsByNonce[nonce] {
                conflictsByCID[existing.cid] = existing
            }
        }
        if !conflictsByCID.isEmpty {
            guard conflictsByCID.count == 1, let existing = conflictsByCID.values.first else {
                return .rejected(.multiSignerNonceConflict, "Same-nonce conflict with multiple resident transactions")
            }
            return tryReplace(existing: existing, transaction: transaction, cid: cid, fee: fee, bodyBytes: bodyBytes, signers: trackedSigners, nonce: nonce, stateKeys: stateKeys, debits: debits, confirmedBalances: confirmedBalances)
        }

        for signer in trackedSigners {
            if let queue = queueBySigner[signer], UInt64(queue.txsByNonce.count) >= maxPerAccount {
                return .rejected(.accountLimit, "Account transaction limit reached")
            }
        }

        // cumulative per-signer double-spend bound. Each queued tx is
        // independently affordable against the confirmed balance, but they all
        // draw from the SAME balance — k txs each <= balance can cumulatively
        // exceed it. The per-tx consensus balance check (run independently per
        // tx at admission) cannot see this; only the mempool, which holds the
        // signer's whole queue, can. The balances are the locked frontier view
        // the admission seam already resolved for the per-tx check, passed in so
        // this cumulative gate is atomic with the insert. For every signer with
        // a supplied balance, reject a newcomer whose debit pushes that signer's
        // total queued outflow past the confirmed balance (: checked per
        // signer, not only for `signers.first`).
        for signer in trackedSigners {
            guard let balance = confirmedBalances[signer], let queue = queueBySigner[signer] else { continue }
            // Sum only the CONTIGUOUS queued nonce range starting at confirmedNonce
            // (with the incoming tx hypothetically inserted at `nonce`). Nonces beyond
            // the first gap can never be selected until their predecessors arrive, so
            // they don't draw against the confirmed balance yet — counting them would
            // let a single resident high-nonce tx wrongly reject affordable low-nonce
            // txs whose gap predecessors are absent (gaps up to maxNonceGap are admitted).
            var cumulative: UInt64 = 0
            var n = queue.confirmedNonce
            while true {
                let debitAtN: UInt64?
                if n == nonce {
                    debitAtN = debits[signer] ?? 0
                } else if let entry = queue.txsByNonce[n] {
                    debitAtN = entry.debitBySigner[signer] ?? 0
                } else {
                    debitAtN = nil
                }
                guard let d = debitAtN else { break }
                let (sum, overflow) = cumulative.addingReportingOverflow(d)
                cumulative = overflow ? UInt64.max : sum
                n += 1
            }
            if cumulative > balance {
                return .rejected(.cumulativeDebit, "Cumulative sender debit exceeds balance: \(cumulative) > \(balance)")
            }
        }

        let incoming = MempoolEntry(
            transaction: transaction,
            cid: cid,
            fee: fee,
            bodyBytes: bodyBytes,
            sender: sender,
            nonce: nonce,
            addedAt: .now,
            stateKeys: stateKeys,
            signers: trackedSigners,
            debitBySigner: debits.filter { trackedSigners.contains($0.key) }
        )

        // H7: a single body larger than the entire NODE byte budget can never fit,
        // even after evicting everything else — reject before touching residents.
        if let maxBytes = byteLimiter.maxBytes, incoming.bodyBytes > maxBytes {
            return .rejected(.oversizedBody, "Transaction body exceeds mempool byte budget: \(incoming.bodyBytes) > \(maxBytes)")
        }

        // + H7: eviction by fee-RATE bounded on BOTH count and
        // bytes. The mempool is over budget if admitting `incoming` would push the
        // entry count past this chain's `maxSize` OR the NODE-WIDE byte total past
        // the shared `byteLimiter.maxBytes`. While over budget, evict the
        // lowest-fee-rate resident (`sortedEntries.last` — O(1), rate-consistent
        // with selection) to make room for a strictly-higher-rate newcomer; reject
        // only when the newcomer cannot outbid the cheapest resident. Fee-rate
        // reuses the byte measure so a small dense-fee tx isn't evicted by a
        // large fee-padded one.
        //
        // Bytes are bounded NODE-WIDE: eviction can only free THIS chain's residents
        // (`bytesFreed` <= this chain's totalBytes), so if the node is full mostly of
        // OTHER chains' bytes this chain rejects once it runs out of its own victims
        // — correct for a shared cap.
        //
        // Precompute the FULL victim set against running totals BEFORE mutating the
        // pool: a rejected admission must never be destructive. If we evicted as we
        // went, a multi-eviction newcomer could remove one or more lower-fee
        // residents and THEN reach a resident it cannot outbid, returning .rejected
        // after having already churned the pool — letting a peer evict mempool
        // contents with transactions that never enter. removeEntry is single-element
        // (no descendant cascade), so simulating count-1 / bytes-bodyBytes per
        // victim is exact.
        let nodeBytesUsed = byteLimiter.used()
        func admissionExceedsBudget(evicted: Int, bytesFreed: UInt64) -> Bool {
            if byCID.count - evicted >= maxSize { return true }
            if let maxBytes = byteLimiter.maxBytes {
                let base = nodeBytesUsed >= bytesFreed ? nodeBytesUsed - bytesFreed : 0
                let (projected, overflow) = base.addingReportingOverflow(incoming.bodyBytes)
                if overflow || projected > maxBytes { return true }
            }
            return false
        }
        var victims: [MempoolEntry] = []
        var freedBytes: UInt64 = 0
        var victimIndex = sortedEntries.count - 1
        while admissionExceedsBudget(evicted: victims.count, bytesFreed: freedBytes) {
            guard victimIndex >= 0 else {
                // Ran out of residents to evict and admitting still exceeds budget.
                return .rejected(.full, "Mempool full")
            }
            // sortedEntries is fee-rate DESC, so the tail is the cheapest. Once the
            // newcomer can't outbid a candidate, no earlier (higher-rate) resident
            // is outbiddable either — reject having removed NOTHING.
            let candidate = sortedEntries[victimIndex]
            if incoming.feeRate <= candidate.feeRate {
                return .rejected(.feeRateOutbid, "Fee rate too low to enter mempool")
            }
            victims.append(candidate)
            let (sum, overflow) = freedBytes.addingReportingOverflow(candidate.bodyBytes)
            freedBytes = overflow ? UInt64.max : sum
            victimIndex -= 1
        }
        // Atomically commit the byte reservation under the limiter's lock, crediting
        // the bytes the precomputed victims will free. This closes the cross-actor
        // race: the `nodeBytesUsed` snapshot above only SIZED the victim set; the
        // shared budget may have moved since, so the real admit/reject decision is
        // made here against the live node-wide total. On failure (another chain took
        // the headroom) we reject having mutated NOTHING — the victims are still
        // resident. On success the net delta (-freed + incoming) is already applied,
        // so the local mutations below use adjustLimiter: false to avoid double-count.
        guard byteLimiter.tryReserve(incoming: incoming.bodyBytes, freed: freedBytes) else {
            return .rejected(.full, "Mempool full")
        }
        for victim in victims { removeEntry(victim, adjustLimiter: false) }
        insertEntry(incoming, adjustLimiter: false)
        bumpGeneration()
        return .added
    }

    public func selectTransactions(maxCount: Int) -> [Transaction] {
        var selected: [Transaction] = []
        var selectedNonces: [String: UInt64] = [:]
        var claimedKeys = StateKeySet()

        // an entry is buildable only when its nonce is the next
        // expected nonce for EVERY signer (consensus enforces contiguous
        // per-signer sequences), and selecting it advances every signer's
        // expected nonce — mirroring how block apply advances every signer's
        // nonce-tracking key.
        func selectable(_ entry: MempoolEntry) -> Bool {
            for signer in entry.signers {
                guard let queue = byAccount[signer] else { return false }
                let nextExpected = selectedNonces[signer] ?? queue.confirmedNonce
                guard entry.nonce == nextExpected else { return false }
            }
            return claimedKeys.isDisjoint(with: entry.stateKeys)
        }
        func markSelected(_ entry: MempoolEntry) {
            selected.append(entry.transaction)
            claimedKeys.formUnion(entry.stateKeys)
            for signer in entry.signers {
                selectedNonces[signer] = entry.nonce + 1
            }
        }

        for entry in sortedEntries {
            if selected.count >= maxCount { break }
            guard selectable(entry) else { continue }
            markSelected(entry)
            // Opportunistically include consecutive higher-nonce txs from the
            // same signer(s). sortedEntries is fee-descending, so a signer's
            // higher-nonce tx with a higher fee would be iterated BEFORE its
            // lower-nonce tx and skipped (nonce mismatch) — without this, it
            // would stay stuck until the next block even though it's now valid.
            for signer in entry.signers {
                guard let account = byAccount[signer] else { continue }
                var next = entry.nonce + 1
                while selected.count < maxCount,
                      let nextEntry = account.txsByNonce[next],
                      selectable(nextEntry) {
                    markSelected(nextEntry)
                    next += 1
                }
            }
        }
        return selected
    }

    /// Batch update confirmed nonces for multiple senders in one actor call.
    /// Collects all stale CIDs across senders, then does a single O(n) pass
    /// over sortedEntries instead of N separate full scans.
    public func batchUpdateConfirmedNonces(updates: [(sender: String, nonce: UInt64)]) {
        var highestNonceBySender: [String: UInt64] = [:]
        for update in updates {
            highestNonceBySender[update.sender] = max(highestNonceBySender[update.sender] ?? 0, update.nonce)
        }
        applyConfirmedNonceChanges(highestNonceBySender, monotonic: true)
    }

    /// M11: drop resident transactions that became unaffordable against a freshly
    /// confirmed balance. A tx admitted while a sender's balance covered it can go
    /// unbuildable after a later block changes that balance (e.g. another spend
    /// confirms); left resident it produces O(n) trial-build churn every block.
    /// For each `(sender, confirmedBalance)`, walk the contiguous queued nonce run
    /// from `confirmedNonce`, summing `senderDebit`; once the cumulative crosses
    /// the fresh balance, evict that tx and every higher-nonce contiguous
    /// successor (they all depend on it and can never be afforded behind it).
    /// This re-runs the SAME cumulative bound admission enforces, so a tx that
    /// would no longer be admittable is no longer retained.
    public func dropUnaffordable(updates: [(sender: String, confirmedBalance: UInt64)]) {
        guard !updates.isEmpty else { return }
        // a multi-signer entry can become doomed through more than one
        // of its signers — dedup by CID so bytes are credited back exactly once.
        var doomedByCID: [String: MempoolEntry] = [:]
        for (sender, balance) in updates {
            guard let queue = byAccount[sender] else { continue }
            var cumulative: UInt64 = 0
            var n = queue.confirmedNonce
            var evicting = false
            while let entry = queue.txsByNonce[n] {
                if !evicting {
                    let (sum, overflow) = cumulative.addingReportingOverflow(entry.debitBySigner[sender] ?? 0)
                    cumulative = overflow ? UInt64.max : sum
                    if cumulative > balance { evicting = true }
                }
                if evicting { doomedByCID[entry.cid] = entry }
                n += 1
            }
        }
        guard !doomedByCID.isEmpty else { return }
        for entry in doomedByCID.values { removeEntry(entry) }
        bumpGeneration()
    }

    public func updateConfirmedNonce(sender: String, nonce: UInt64) {
        batchUpdateConfirmedNonces(updates: [(sender: sender, nonce: nonce)])
    }

    /// Seed the mempool's confirmedNonce for a sender from persisted state if
    /// it hasn't been set this session. Without this, a sender whose most
    /// recent tx predates the current node session has confirmedNonce=0 (the
    /// default) but submits body.nonce=N>0, so selectTransactions' equality
    /// check never matches and the tx sits invisible until the expiry pruner
    /// evicts it. batchUpdateConfirmedNonces is only fired on block-apply, so
    /// it never covers the first-submit-after-restart case.
    public func seedConfirmedNonceIfUnset(sender: String, nonce: UInt64) {
        guard !sender.isEmpty, nonce > 0 else { return }
        if var queue = byAccount[sender] {
            guard queue.confirmedNonce == 0 else { return }
            queue.confirmedNonce = nonce
            byAccount[sender] = queue
            removeConfirmedNonceFloor(sender: sender)
            if !queue.txsByNonce.isEmpty {
                bumpGeneration()
            }
            return
        }
        guard confirmedNonceFloorByAccount[sender] == nil else { return }
        storeConfirmedNonceFloor(sender: sender, nonce: nonce)
    }

    /// Advance confirmedNonce to at least `nonce` and evict pending transactions
    /// that are now below that floor. If the queue drains, retain only the scalar
    /// floor in the bounded LRU floor map so the addTransaction call that follows
    /// admission-time refresh still sees the raised floor.
    public func refreshConfirmedNonce(sender: String, nonce: UInt64) {
        guard !sender.isEmpty, nonce > 0 else { return }
        applyConfirmedNonceChanges([sender: nonce], monotonic: true)
    }

    /// Rebase sender nonce floors after fork choice abandons a branch. Normal
    /// confirmation updates are monotonic, but reorg recovery must match the new
    /// canonical tip before orphaned txs are re-admitted.
    public func resetConfirmedNoncesAfterReorg(updates: [(sender: String, nonce: UInt64)]) {
        var nonceBySender: [String: UInt64] = [:]
        for update in updates {
            nonceBySender[update.sender] = update.nonce
        }
        applyConfirmedNonceChanges(nonceBySender, monotonic: false)
    }

    public func remove(txCID: String) {
        guard let entry = byCID[txCID] else { return }
        removeEntry(entry)
        bumpGeneration()
    }

    public func removeAll(txCIDs: Set<String>) {
        var cidsToDrop = Set<String>()
        for cid in txCIDs {
            guard let entry = byCID.removeValue(forKey: cid) else { continue }
            releaseBytes(entry.bodyBytes)
            detachFromAccountQueues(entry)
            cidsToDrop.insert(entry.cid)
            removeFetcherEntries(for: entry)
        }
        if !cidsToDrop.isEmpty {
            sortedEntries.removeAll(where: { cidsToDrop.contains($0.cid) })
            rebuildIndex()
            bumpGeneration()
        }
    }

    public func contains(txCID: String) -> Bool {
        byCID[txCID] != nil
    }

    public func allTransactions() -> [Transaction] {
        byCID.values.map { $0.transaction }
    }

    public func allSenders() -> Set<String> {
        Set(byAccount.keys)
    }

    /// CID→Data view of admitted transactions, served via the mempool overlay source.
    /// Maintained incrementally by insertEntry/removeEntry; returning the
    /// stored dict is O(1) per miner round instead of O(n·serialize) on every
    /// call.
    public func fetcherCache() -> [String: Data] {
        return cachedFetcherData
    }

    public func totalFees() -> UInt64 {
        byCID.values.reduce(0) { $0 + $1.fee }
    }

    public func pruneExpired(olderThan age: Duration) {
        let cutoff = ContinuousClock.Instant.now - age
        let expired = byCID.values.filter { $0.addedAt < cutoff }
        guard !expired.isEmpty else { return }
        // batch removal so pruning k of n entries is O(n + k·log n),
        // not O(n²). Removing entries one at a time would each do an O(n)
        // `sortedEntries.remove(at:)` shift PLUS an O(n) tail reindex — O(k·n)
        // overall, the quadratic the AC requires us to eliminate. Instead collect
        // the doomed CIDs and do a SINGLE O(n) `removeAll(where:)` splice + one
        // rebuildIndex(), the same pattern applyConfirmedNonceUpdates/removeAll use.
        let expiredCIDs = Set(expired.map { $0.cid })
        for entry in expired {
            byCID.removeValue(forKey: entry.cid)
            releaseBytes(entry.bodyBytes)
            detachFromAccountQueues(entry)
            removeFetcherEntries(for: entry)
        }
        sortedEntries.removeAll(where: { expiredCIDs.contains($0.cid) })
        rebuildIndex()
        bumpGeneration()
    }

    public func feeHistogram(bucketCount: Int = 10) -> [(minFee: UInt64, maxFee: UInt64, count: Int)] {
        guard !sortedEntries.isEmpty else { return [] }

        // `sortedEntries` is now ordered by fee-RATE, not absolute
        // fee, so we can no longer read min/max fee off the ends or binary-search
        // by fee. The histogram buckets ABSOLUTE fees, so derive its bounds and
        // counts from a direct pass over the entries.
        var minFee = UInt64.max
        var maxFee: UInt64 = 0
        for entry in sortedEntries {
            minFee = min(minFee, entry.fee)
            maxFee = max(maxFee, entry.fee)
        }

        if minFee == maxFee {
            return [(minFee: minFee, maxFee: maxFee, count: sortedEntries.count)]
        }

        let range = maxFee - minFee
        let bucketSize = max(range / UInt64(bucketCount), 1)
        var counts = [Int](repeating: 0, count: bucketCount)
        for entry in sortedEntries {
            var idx = Int((entry.fee - minFee) / bucketSize)
            if idx >= bucketCount { idx = bucketCount - 1 }
            counts[idx] += 1
        }

        var buckets: [(minFee: UInt64, maxFee: UInt64, count: Int)] = []
        for i in 0..<bucketCount {
            let lo = minFee + UInt64(i) * bucketSize
            let hi = (i == bucketCount - 1) ? maxFee : lo + bucketSize - 1
            if counts[i] > 0 {
                buckets.append((minFee: lo, maxFee: hi, count: counts[i]))
            }
        }

        return buckets
    }

    // MARK: - Private

    /// Dedup `signers` preserving order (primary first). An unsigned body
    /// degenerates to the legacy single "" key, matching prior behavior.
    private static func orderedUniqueSigners(_ signers: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for signer in signers where seen.insert(signer).inserted {
            unique.append(signer)
        }
        return unique.isEmpty ? [""] : unique
    }

    /// Remove `entry` from every signer queue it occupies. A drained
    /// queue is dropped from `byAccount` but retains its scalar confirmed-nonce
    /// floor in the bounded LRU map (SEC-401 bounded growth + floor
    /// survival): losing the floor here would let a below-floor nonce be
    /// re-admitted after a bulk prune. The CID guard makes the detach
    /// idempotent and protects a slot that was already re-occupied.
    private func detachFromAccountQueues(_ entry: MempoolEntry) {
        for signer in entry.signers {
            guard var queue = byAccount[signer] else { continue }
            guard let resident = queue.txsByNonce[entry.nonce], resident.cid == entry.cid else { continue }
            queue.txsByNonce.removeValue(forKey: entry.nonce)
            if queue.txsByNonce.isEmpty {
                storeConfirmedNonceFloor(sender: signer, nonce: queue.confirmedNonce)
                byAccount.removeValue(forKey: signer)
            } else {
                byAccount[signer] = queue
                removeConfirmedNonceFloor(sender: signer)
            }
        }
    }

    private func retainedConfirmedNonceFloor(sender: String) -> UInt64? {
        guard let nonce = confirmedNonceFloorByAccount[sender] else { return nil }
        touchConfirmedNonceFloor(sender: sender, nonce: nonce)
        return nonce
    }

    private func storeConfirmedNonceFloor(sender: String, nonce: UInt64, allowDecrease: Bool = false) {
        guard !sender.isEmpty else { return }
        let previous = confirmedNonceFloorByAccount[sender]
        let retained = allowDecrease ? nonce : max(previous ?? 0, nonce)
        guard retained > 0 else {
            removeConfirmedNonceFloor(sender: sender)
            return
        }
        touchConfirmedNonceFloor(sender: sender, nonce: retained)
    }

    private func touchConfirmedNonceFloor(sender: String, nonce: UInt64) {
        nextConfirmedNonceFloorGeneration &+= 1
        let generation = nextConfirmedNonceFloorGeneration
        confirmedNonceFloorByAccount[sender] = nonce
        confirmedNonceFloorGenerationByAccount[sender] = generation
        confirmedNonceFloorLRU.append((sender: sender, generation: generation))
        evictConfirmedNonceFloorsIfNeeded()
    }

    private func removeConfirmedNonceFloor(sender: String) {
        confirmedNonceFloorByAccount.removeValue(forKey: sender)
        confirmedNonceFloorGenerationByAccount.removeValue(forKey: sender)
    }

    private func evictConfirmedNonceFloorsIfNeeded() {
        guard confirmedNonceFloorLimit > 0 else {
            confirmedNonceFloorByAccount.removeAll(keepingCapacity: false)
            confirmedNonceFloorGenerationByAccount.removeAll(keepingCapacity: false)
            confirmedNonceFloorLRU.removeAll(keepingCapacity: false)
            confirmedNonceFloorLRUHead = 0
            return
        }

        while confirmedNonceFloorByAccount.count > confirmedNonceFloorLimit,
              confirmedNonceFloorLRUHead < confirmedNonceFloorLRU.count {
            let candidate = confirmedNonceFloorLRU[confirmedNonceFloorLRUHead]
            confirmedNonceFloorLRUHead += 1
            guard confirmedNonceFloorGenerationByAccount[candidate.sender] == candidate.generation else {
                continue
            }
            confirmedNonceFloorByAccount.removeValue(forKey: candidate.sender)
            confirmedNonceFloorGenerationByAccount.removeValue(forKey: candidate.sender)
        }

        compactConfirmedNonceFloorLRUIfNeeded()
    }

    private func compactConfirmedNonceFloorLRUIfNeeded() {
        let maxRecords = max(confirmedNonceFloorLimit * 4, 1_024)
        guard confirmedNonceFloorLRUHead > 0 || confirmedNonceFloorLRU.count > maxRecords else {
            return
        }
        guard confirmedNonceFloorLRUHead > 1_024 ||
              confirmedNonceFloorLRU.count > maxRecords ||
              confirmedNonceFloorLRUHead * 2 > confirmedNonceFloorLRU.count else {
            return
        }

        var compacted: [(sender: String, generation: UInt64)] = []
        compacted.reserveCapacity(confirmedNonceFloorByAccount.count)
        for record in confirmedNonceFloorLRU.dropFirst(confirmedNonceFloorLRUHead) {
            if confirmedNonceFloorGenerationByAccount[record.sender] == record.generation {
                compacted.append(record)
            }
        }
        confirmedNonceFloorLRU = compacted
        confirmedNonceFloorLRUHead = 0
    }

    /// Shared implementation behind `batchUpdateConfirmedNonces` /
    /// `refreshConfirmedNonce` (`monotonic: true` — the floor only rises) and
    /// `resetConfirmedNoncesAfterReorg` (`monotonic: false` — reorg recovery may
    /// rebase the floor downward). Stale entries (nonce below the new floor) are
    /// purged from EVERY signer's queue, and any queue that drains
    /// retains only its scalar floor in the bounded LRU map — whether it
    /// belonged to an updated sender or to a co-signer of a purged entry —
    /// so nonce-floor enforcement survives the drain (SEC-401).
    private func applyConfirmedNonceChanges(
        _ nonceBySender: [String: UInt64],
        monotonic: Bool
    ) {
        guard !nonceBySender.isEmpty else { return }

        var doomedByCID: [String: MempoolEntry] = [:]
        var selectableFloorChanged = false
        var touchedSenders = Set<String>()

        for (sender, requestedNonce) in nonceBySender {
            var queue = byAccount[sender] ?? AccountTxQueue(
                confirmedNonce: retainedConfirmedNonceFloor(sender: sender) ?? 0
            )
            let previousConfirmedNonce = queue.confirmedNonce
            let confirmedNonce = monotonic ? max(previousConfirmedNonce, requestedNonce) : requestedNonce
            queue.confirmedNonce = confirmedNonce
            if !queue.txsByNonce.isEmpty, confirmedNonce != previousConfirmedNonce {
                selectableFloorChanged = true
            }
            for (nonce, entry) in queue.txsByNonce where nonce < confirmedNonce {
                doomedByCID[entry.cid] = entry
            }
            byAccount[sender] = queue
            touchedSenders.insert(sender)
        }

        // a stale entry may reside in several signers' queues — detach
        // it from ALL of them, not only the updated sender's.
        for entry in doomedByCID.values {
            for signer in entry.signers {
                guard var queue = byAccount[signer] else { continue }
                guard let resident = queue.txsByNonce[entry.nonce], resident.cid == entry.cid else { continue }
                queue.txsByNonce.removeValue(forKey: entry.nonce)
                byAccount[signer] = queue
                touchedSenders.insert(signer)
            }
        }

        for sender in touchedSenders {
            guard let queue = byAccount[sender] else { continue }
            if queue.txsByNonce.isEmpty {
                // Whether this was the SEC-401 drained-queue path or an empty
                // floor refresh, never retain a full AccountTxQueue just to hold
                // confirmedNonce. The bounded scalar map preserves nonce-floor
                // enforcement for recent senders. Only an explicit reorg reset
                // may lower an already-retained floor.
                storeConfirmedNonceFloor(
                    sender: sender,
                    nonce: queue.confirmedNonce,
                    allowDecrease: !monotonic && nonceBySender[sender] != nil
                )
                byAccount.removeValue(forKey: sender)
            } else {
                removeConfirmedNonceFloor(sender: sender)
            }
        }

        guard !doomedByCID.isEmpty || selectableFloorChanged else { return }

        if !doomedByCID.isEmpty {
            let staleCIDs: Set<String> = Set(doomedByCID.keys)
            for entry in doomedByCID.values {
                byCID.removeValue(forKey: entry.cid)
                releaseBytes(entry.bodyBytes)
                removeFetcherEntries(for: entry)
            }
            sortedEntries.removeAll(where: { staleCIDs.contains($0.cid) })
            rebuildIndex()
        }
        bumpGeneration()
    }

    private func tryReplace(
        existing: MempoolEntry,
        transaction: Transaction,
        cid: String,
        fee: UInt64,
        bodyBytes: UInt64,
        signers: [String],
        nonce: UInt64,
        stateKeys: StateKeySet,
        debits: [String: UInt64],
        confirmedBalances: [String: UInt64]
    ) -> AddResult {
        // BIP125-style replace-by-fee for same (sender, nonce).
        // A replacement is accepted only if all three hold:
        //
        //  (1) PACKAGE FEE — the replacement fee covers the total fee of EVERY
        //      same-sender tx it conflicts with: the replaced tx plus every
        //      higher-nonce descendant of the same sender that the replacement
        //      evicts (replacing nonce N invalidates the contiguous chain
        //      N+1, N+2, … this sender has queued, since they depend on N's
        //      state effects). On top of that it must clear the standard bump
        //      `existing.fee/10 + 1`. This stops a free replacement that drops
        //      otherwise-payable descendants.
        //
        //  (2) NO NEW STATE-KEY CONFLICT — the replacement may not introduce a
        //      `StateKeySet` conflict against OTHER residents that the replaced
        //      tx did not already have. Otherwise a replacement could wedge in
        //      keys that block unrelated residents from ever being selected.
        //
        //  (3) NO CLOCK RESET — the new entry inherits the REPLACED entry's
        //      `addedAt`, so repeated bumps can't evade `pruneExpired` by
        //      perpetually refreshing the expiry clock.
        //
        // removeEntry drops the old entry (and any evicted descendants) before
        // insertEntry adds the new one, so fees/balances aren't double-counted:
        // at most one tx per (signer, nonce) is ever resident.
        let descendants = higherNonceDescendants(of: existing, replacedNonce: nonce)

        var conflictingPackageFee = existing.fee
        for d in descendants {
            let (sum, overflow) = conflictingPackageFee.addingReportingOverflow(d.fee)
            conflictingPackageFee = overflow ? UInt64.max : sum
        }
        let bump = existing.fee / 10 + 1
        let (required, reqOverflow) = conflictingPackageFee.addingReportingOverflow(bump)
        let requiredFee = reqOverflow ? UInt64.max : required
        guard fee >= requiredFee else {
            return .rejected(.rbfUnderpay, "RBF underpays conflicting package: need >= \(requiredFee), got \(fee)")
        }

        // (2) The replacement must not create a state-key conflict against any
        // resident that the replaced tx (and its evicted descendants) did not
        // already conflict with. Build the set of keys the outgoing package
        // already owned, then check the replacement only against residents
        // OUTSIDE that package.
        let outgoingCIDs = Set([existing.cid] + descendants.map { $0.cid })
        if introducesNewStateKeyConflict(stateKeys: stateKeys, outgoingCIDs: outgoingCIDs) {
            return .rejected(.rbfStateKeyConflict, "RBF introduces new state-key conflict")
        }

        // the replacement must keep EVERY signer's total queued
        // outflow within that signer's confirmed balance (the locked view passed
        // in by admission). Sum the surviving queued debits (the replaced tx and
        // its evicted descendants drop out) plus the replacement's own debit.
        for signer in signers {
            guard let balance = confirmedBalances[signer] else { continue }
            let queue = byAccount[signer]
            let confirmedNonce = queue?.confirmedNonce ?? retainedConfirmedNonceFloor(sender: signer) ?? 0
            // Walk the contiguous queued nonce range from confirmedNonce with the
            // replacement substituted at `nonce`. The replacement evicts the
            // contiguous descendant run above `nonce` (higherNonceDescendants), so
            // those drop out — exclude them, which makes the post-replacement
            // contiguous prefix end at `nonce`. Only this prefix draws against the
            // confirmed balance; nonces past the first gap don't count yet.
            var cumulative: UInt64 = 0
            var n = confirmedNonce
            while true {
                let debitAtN: UInt64?
                if n == nonce {
                    debitAtN = debits[signer] ?? 0
                } else if let entry = queue?.txsByNonce[n], !outgoingCIDs.contains(entry.cid) {
                    debitAtN = entry.debitBySigner[signer] ?? 0
                } else {
                    debitAtN = nil
                }
                guard let d = debitAtN else { break }
                let (sum, overflow) = cumulative.addingReportingOverflow(d)
                cumulative = overflow ? UInt64.max : sum
                n += 1
            }
            if cumulative > balance {
                return .rejected(.cumulativeDebit, "Cumulative sender debit exceeds balance: \(cumulative) > \(balance)")
            }
        }

        // H7: the NODE-WIDE byte cap must also hold across RBF — a small resident
        // must not be replaceable by an oversized higher-fee tx. A body larger than
        // the whole budget can never fit; reject before touching residents.
        if let maxBytes = byteLimiter.maxBytes, bodyBytes > maxBytes {
            return .rejected(.oversizedBody, "Transaction body exceeds mempool byte budget: \(bodyBytes) > \(maxBytes)")
        }
        // The outgoing package (replaced tx + evicted descendants) frees these bytes
        // from THIS chain; reserve atomically against the shared node-wide total so
        // a concurrent admission on another chain can't push us past the cap. On
        // failure mutate nothing; on success the net delta is committed, so the local
        // mutations below use adjustLimiter: false.
        var freed = existing.bodyBytes
        for d in descendants {
            let (sum, overflow) = freed.addingReportingOverflow(d.bodyBytes)
            freed = overflow ? UInt64.max : sum
        }
        guard byteLimiter.tryReserve(incoming: bodyBytes, freed: freed) else {
            return .rejected(.rbfByteBudget, "RBF replacement exceeds mempool byte budget")
        }

        let oldCID = existing.cid
        let preservedAddedAt = existing.addedAt
        removeEntry(existing, adjustLimiter: false)
        for d in descendants { removeEntry(d, adjustLimiter: false) }

        let entry = MempoolEntry(
            transaction: transaction,
            cid: cid,
            fee: fee,
            bodyBytes: bodyBytes,
            sender: signers.first ?? "",
            nonce: nonce,
            addedAt: preservedAddedAt,
            stateKeys: stateKeys,
            signers: signers,
            debitBySigner: debits.filter { signers.contains($0.key) }
        )
        insertEntry(entry, adjustLimiter: false)
        bumpGeneration()
        return .replacedExisting(oldCID: oldCID)
    }

    private func bumpGeneration() {
        generation &+= 1
    }

    /// The txs at nonces strictly above `replacedNonce` in ANY of the replaced
    /// entry's signer queues that a replacement of `replacedNonce` would
    /// invalidate (deduped by CID). Only the CONTIGUOUS run
    /// (replacedNonce+1, +2, …) per queue is a true descendant chain; a gap
    /// means the higher-nonce tx can never have been selectable behind the
    /// replaced one, so it is not part of this package.
    private func higherNonceDescendants(of existing: MempoolEntry, replacedNonce: UInt64) -> [MempoolEntry] {
        var seen = Set<String>([existing.cid])
        var result: [MempoolEntry] = []
        for signer in existing.signers {
            guard let queue = byAccount[signer] else { continue }
            var n = replacedNonce + 1
            while let entry = queue.txsByNonce[n] {
                if seen.insert(entry.cid).inserted {
                    result.append(entry)
                }
                n += 1
            }
        }
        return result
    }

    /// True if `stateKeys` collides (non-account state) with a resident that is
    /// NOT part of the outgoing package — i.e. the replacement would introduce a
    /// conflict the replaced tx did not already have.
    private func introducesNewStateKeyConflict(stateKeys: StateKeySet, outgoingCIDs: Set<String>) -> Bool {
        for entry in sortedEntries where !outgoingCIDs.contains(entry.cid) {
            if !stateKeys.isDisjoint(with: entry.stateKeys) {
                return true
            }
        }
        return false
    }

    /// Decrement only THIS chain's running byte total, saturating at 0 so a
    /// bookkeeping mismatch can never underflow. Does NOT touch the shared limiter —
    /// used on the admission-commit path where the net delta was already applied
    /// atomically by `tryReserve`.
    private func subtractLocalBytes(_ bytes: UInt64) {
        totalBytes = totalBytes >= bytes ? totalBytes - bytes : 0
    }

    /// An entry left the pool OUTSIDE an atomic admission commit (expiry prune,
    /// explicit removal, reorg eviction, removeAll): drop the bytes locally AND
    /// credit them back to the shared node-wide budget.
    private func releaseBytes(_ bytes: UInt64) {
        subtractLocalBytes(bytes)
        byteLimiter.release(bytes)
    }

    /// Insert a single entry. `adjustLimiter` is false ONLY on the admission-commit
    /// path (addTransaction / RBF), where `tryReserve` already debited the shared
    /// budget; everywhere else it debits it here.
    private func insertEntry(_ entry: MempoolEntry, adjustLimiter: Bool = true) {
        byCID[entry.cid] = entry
        // index the entry under EVERY signer's queue — consensus
        // enforces each signer's nonce sequence, so each signer's (nonce → tx)
        // slot must see this entry.
        for signer in entry.signers {
            var queue = byAccount[signer] ?? AccountTxQueue(
                confirmedNonce: retainedConfirmedNonceFloor(sender: signer) ?? 0
            )
            queue.txsByNonce[entry.nonce] = entry
            byAccount[signer] = queue
            removeConfirmedNonceFloor(sender: signer)
        }
        // H7: keep this chain's byte total in step with its resident set, and (unless
        // the shared budget was already debited atomically by tryReserve) debit it
        // so the node-wide cap holds across all chains.
        let (sum, overflow) = totalBytes.addingReportingOverflow(entry.bodyBytes)
        totalBytes = overflow ? UInt64.max : sum
        if adjustLimiter { byteLimiter.reserveUnchecked(entry.bodyBytes) }

        // sort by (feeRate DESC, addedAt ASC) — denser fee-rate
        // wins; within the same rate tier, earlier arrival wins (reduces MEV
        // front-running: an attacker matching an existing rate no longer jumps
        // ahead purely by being the miner). Block-template selection and the
        // eviction victim both read this single ordering.
        let insertIndex = sortedEntries.binarySearchDescending {
            entryOrderedBefore($0, entry)
        }
        sortedEntries.insert(entry, at: insertIndex)
        reindexFrom(insertIndex)

        addFetcherEntries(for: entry)
    }

    /// Total order for `sortedEntries`: higher fee-rate first; ties broken by
    /// earlier arrival. Returns true when `a` should sort strictly before `b`.
    private func entryOrderedBefore(_ a: MempoolEntry, _ b: MempoolEntry) -> Bool {
        if a.feeRate != b.feeRate { return a.feeRate > b.feeRate }
        return a.addedAt <= b.addedAt
    }

    /// Remove a single entry. `adjustLimiter` is false ONLY on the admission-commit
    /// path (addTransaction / RBF), where `tryReserve` already applied the net byte
    /// delta to the shared budget; everywhere else it credits the freed bytes back.
    private func removeEntry(_ entry: MempoolEntry, adjustLimiter: Bool = true) {
        byCID.removeValue(forKey: entry.cid)
        if adjustLimiter { releaseBytes(entry.bodyBytes) } else { subtractLocalBytes(entry.bodyBytes) }

        detachFromAccountQueues(entry)

        // single-element removal. The CID→index map gives the
        // exact position in O(1), so we never linear-scan the equal-fee-rate tier.
        // The array splice + tail reindex is O(n); this is fine for the
        // ONE-AT-A-TIME callers (remove(txCID:), eviction, RBF), but the bulk
        // `pruneExpired` deliberately does NOT loop this path — it batches into a
        // single removeAll + rebuildIndex (see pruneExpired) so k removals cost
        // O(n + k·log n), not O(k·n). The guarded fallback below only runs if the
        // map is ever stale.
        if let idx = indexByCID[entry.cid], idx < sortedEntries.count, sortedEntries[idx].cid == entry.cid {
            sortedEntries.remove(at: idx)
            indexByCID.removeValue(forKey: entry.cid)
            reindexFrom(idx)
        } else {
            let feeIdx = sortedEntries.binarySearchDescending { $0.feeRate > entry.feeRate }
            for i in feeIdx..<sortedEntries.count {
                if sortedEntries[i].feeRate < entry.feeRate { break }
                lastRemovalScanSteps += 1
                if sortedEntries[i].cid == entry.cid {
                    sortedEntries.remove(at: i)
                    indexByCID.removeValue(forKey: entry.cid)
                    reindexFrom(i)
                    break
                }
            }
        }

        removeFetcherEntries(for: entry)
    }

    /// Rebuild `indexByCID` for every entry at or after `start` after a splice.
    /// An insert/remove at position `start` only shifts the suffix, so we touch
    /// just the tail rather than the whole array.
    private func reindexFrom(_ start: Int) {
        var i = start
        while i < sortedEntries.count {
            indexByCID[sortedEntries[i].cid] = i
            lastRemovalScanSteps += 1
            i += 1
        }
    }

    /// Rebuild the whole CID→index map after a bulk `removeAll(where:)` splice
    /// (batch-confirm / removeAll). These already pay O(n) for the filter, so a
    /// full reindex adds no asymptotic cost and keeps `indexByCID` exact.
    private func rebuildIndex() {
        indexByCID.removeAll(keepingCapacity: true)
        for (i, entry) in sortedEntries.enumerated() {
            indexByCID[entry.cid] = i
            lastRemovalScanSteps += 1
        }
    }

    private func addFetcherEntries(for entry: MempoolEntry) {
        let tx = entry.transaction
        if let data = tx.toData() {
            // known-valid local node; CID cannot fail
            cachedFetcherData[try! VolumeImpl<Transaction>(node: tx).rawCID] = data
        }
        if let bodyNode = tx.body.node, let bodyData = bodyNode.toData() {
            cachedFetcherData[tx.body.rawCID] = bodyData
        }
    }

    private func removeFetcherEntries(for entry: MempoolEntry) {
        let tx = entry.transaction
        cachedFetcherData.removeValue(forKey: try! VolumeImpl<Transaction>(node: tx).rawCID)
        if tx.body.node != nil {
            cachedFetcherData.removeValue(forKey: tx.body.rawCID)
        }
    }

}

extension Array {
    /// Binary search on a descending-sorted array.
    /// Returns the index of the first element where `predicate` returns false.
    func binarySearchDescending(predicate: (Element) -> Bool) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(self[mid]) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

extension Array where Element: Comparable {
    /// Binary search on an ascending-sorted array.
    /// Returns the insertion index for `value` (first position where element >= value).
    func ascendingInsertionIndex(for value: Element) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if self[mid] < value {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
