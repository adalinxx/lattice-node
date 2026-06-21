import Foundation

/// Central home for the node's OPERATIONAL tunables — the timeouts, retry
/// budgets, structural caps, dedup windows, token-bucket rates, and intervals
/// that used to live as scattered `static let` literals across the node.
///
/// Scope rules (see docs/readiness/tunables.md):
///   • These are node-local OPERATIONAL knobs only. They affect performance,
///     resource ceilings, and timing — never block/transaction VALIDITY. Two
///     honest nodes with different `NodeTuning` still agree on the same chain.
///   • CONSENSUS-bound numbers (block size, target/retarget schedule, MTP,
///     reward/halving, min-fee floor, finality semantics) are NOT here — they
///     are sourced from `ChainSpec`/genesis so every node computes validity
///     identically. Making them per-node would fork a node off the network.
///
/// Every field defaults to the value it replaced. Overrides are read once at
/// startup via `fromEnvironment()`; the CLI layer may construct a `NodeTuning`
/// directly to map flags onto these fields.
public struct NodeTuning: Sendable {
    public var sync: Sync
    public var gossip: Gossip
    public var rateLimit: RateLimit
    public var parentExtractor: ParentExtractor
    public var storage: Storage

    public init(
        sync: Sync = Sync(),
        gossip: Gossip = Gossip(),
        rateLimit: RateLimit = RateLimit(),
        parentExtractor: ParentExtractor = ParentExtractor(),
        storage: Storage = Storage()
    ) {
        self.sync = sync
        self.gossip = gossip
        self.rateLimit = rateLimit
        self.parentExtractor = parentExtractor
        self.storage = storage
    }

    public static let `default` = NodeTuning()

    // MARK: - Groups

    /// Headers-first sync + content-fetch timing and bounds.
    public struct Sync: Sendable {
        /// Overall budget for one sync attempt before it is abandoned.
        public var timeout: Duration = .seconds(600)
        /// Height gap above which a peer tip triggers a full catch-up sync
        /// (smaller gaps reorg via direct block processing).
        public var catchUpThreshold: UInt64 = 3
        /// Gap at/below which a sync is "shallow" and mining keeps running.
        public var shallowThreshold: UInt64 = 200
        /// Per-CID peer-fetch deadline in `IvyFetcher.fetch` (absorbs transient
        /// notHave while freshly-accepted content writes through / a data
        /// channel negotiates).
        public var fetchDeadline: Duration = .seconds(15)
        /// Poll interval while waiting on a peer fetch.
        public var fetchPollInterval: Duration = .milliseconds(400)
        public init() {}
    }

    /// Gossip dedup windows + concurrency caps for block/tx/pin relay.
    public struct Gossip: Sendable {
        public var txDedupWindow: Duration = .seconds(60)
        public var pinAnnounceDedupWindow: Duration = .seconds(60)
        public var blockDedupWindow: Duration = .milliseconds(100)
        public var dandelionStemEpoch: Duration = .seconds(600)
        public var maxRecentTxCIDs: Int = 8_192
        public var maxRecentPinAnnounces: Int = 8_192
        public var maxRecentPeerBlocks: Int = 4_096
        public var maxConcurrentBlockValidations: Int = 4
        public var maxPendingGossipTasks: Int = 64
        public var maxPendingChainAnnounceTasks: Int = 64
        public var peerBlockCountWindow: Duration = .seconds(30)
        public var recentPeerBlockRetention: Duration = .seconds(60)
        public var peerBlockCountCleanupThreshold: Int = 5_000
        public init() {}
    }

    /// Per-peer / per-topic token-bucket rates and ban thresholds.
    public struct RateLimit: Sendable {
        public var mempoolGossipCapacity: Double = 200
        public var mempoolGossipRefillPerSec: Double = 100
        public var getHeadersCapacity: Double = 30
        public var getHeadersRefillPerSec: Double = 10
        public var chainAnnounceCapacity: Double = 30
        public var chainAnnounceRefillPerSec: Double = 10
        public var pinRequestCapacity: Double = 30
        public var pinRequestRefillPerSec: Double = 10
        /// Sliding window for per-peer block-rate accounting.
        public var peerRateWindow: Duration = .seconds(10)
        /// Mempool-rejection count at which a peer is flood-banned.
        public var mempoolFullBanThreshold: Int = 100
        /// Hard-fault (unforgeable fraud) count at which a peer is durably banned.
        public var hardFaultBanThreshold: Int = 5
        public init() {}
    }

    /// Parent-chain block extractor (per-process child) bounds + ingress rate.
    public struct ParentExtractor: Sendable {
        public var inboundCapacity: Double = 200
        public var inboundRefillPerSec: Double = 100
        /// Per-peer token bucket on the chainAnnounce backfill path. A single
        /// announce fans out to up to `maxAnnounceBackfillBlocks` network fetches
        /// before the inbound bucket inside `handle` is ever reached, so it needs
        /// its own gate — mirrors RateLimit.chainAnnounce{Capacity,RefillPerSec}.
        public var announceCapacity: Double = 30
        public var announceRefillPerSec: Double = 10
        public var maxBucketEntries: Int = 2_048
        public var maxPendingExtractionTasks: Int = 64
        /// Isolated cap for chainAnnounce-handling tasks, kept off the shared
        /// extraction pool so an announce flood can't starve real block ingestion.
        public var maxPendingAnnounceTasks: Int = 16
        public var maxAnnounceBackfillBlocks: Int = 256
        public var maxParentAncestorBackfill: Int = 2_048
        public init() {}
    }

    /// Mempool admission bounds not already owned by `NodeResourceConfig`.
    /// NOTE: kept as a TYPE only — `NodeMempool.init` uses
    /// `NodeTuning.Mempool()` for its parameter defaults. The `mempool` stored
    /// property and MEMPOOL_MAX_* env mappings were dead (nothing read
    /// `tuning.mempool`) and have been removed.
    public struct Mempool: Sendable {
        /// Largest gap between an admitted tx's nonce and the sender's confirmed
        /// nonce. Caps how far into the future a sender reserves slots.
        public var maxNonceGap: UInt64 = 64
        /// Max queued txs a single sender may hold (per-account slot squatting).
        public var maxPerAccount: UInt64 = 64
        public init() {}
    }

    /// Retention / eviction timing.
    public struct Storage: Sendable {
        /// Grace before the eviction sweep may reclaim freshly-stored, now-unpinned
        /// content (I4 store-then-pin protection). Env: EVICT_GRACE_SECONDS.
        /// NOTE: currently honored via a direct EVICT_GRACE_SECONDS environment
        /// read at DiskBroker construction, not through this struct; the knob is
        /// kept here as the documented home until that wiring lands.
        public var evictGraceSeconds: Int = 600
        /// Height window over which a node keeps its own tx pins.
        public var ownTxPinWindow: UInt64 = 4_096
        /// How long an unconfirmed transaction may sit in the mempool before the
        /// periodic prune drops it. INVARIANT: this MUST exceed the chain's block
        /// interval by a wide margin, otherwise valid txs expire before any block
        /// can include them (the old hardcoded 600s was shorter than a single
        /// block on a low-hashrate network, so funded txs never confirmed). The
        /// mempool byte budget + fee-rate eviction bound memory independently, so
        /// a long TTL is safe. Env: MEMPOOL_TX_EXPIRY_SECONDS.
        public var mempoolTxExpirySeconds: Int = 86_400
        public init() {}
    }

    // MARK: - Environment resolution

    /// Build a tuning from defaults, applying any environment-variable overrides.
    /// Operational knobs only — unset variables keep the documented default.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> NodeTuning {
        var t = NodeTuning()
        func int(_ key: String, _ apply: (Int) -> Void) { if let v = env[key].flatMap(Int.init) { apply(v) } }
        func u64(_ key: String, _ apply: (UInt64) -> Void) { if let v = env[key].flatMap(UInt64.init) { apply(v) } }
        func dbl(_ key: String, _ apply: (Double) -> Void) { if let v = env[key].flatMap(Double.init) { apply(v) } }
        func secs(_ key: String, _ apply: (Duration) -> Void) { if let v = env[key].flatMap(Double.init) { apply(.seconds(v)) } }
        func millis(_ key: String, _ apply: (Duration) -> Void) { if let v = env[key].flatMap(Int.init) { apply(.milliseconds(v)) } }

        secs("SYNC_TIMEOUT_SECONDS") { t.sync.timeout = $0 }
        u64("SYNC_CATCHUP_THRESHOLD") { t.sync.catchUpThreshold = $0 }
        u64("SYNC_SHALLOW_THRESHOLD") { t.sync.shallowThreshold = $0 }
        secs("FETCH_DEADLINE_SECONDS") { t.sync.fetchDeadline = $0 }
        millis("FETCH_POLL_MILLIS") { t.sync.fetchPollInterval = $0 }

        secs("TX_DEDUP_WINDOW_SECONDS") { t.gossip.txDedupWindow = $0 }
        secs("PIN_ANNOUNCE_DEDUP_WINDOW_SECONDS") { t.gossip.pinAnnounceDedupWindow = $0 }
        int("MAX_RECENT_TX_CIDS") { t.gossip.maxRecentTxCIDs = $0 }
        int("MAX_RECENT_PIN_ANNOUNCES") { t.gossip.maxRecentPinAnnounces = $0 }
        int("MAX_RECENT_PEER_BLOCKS") { t.gossip.maxRecentPeerBlocks = $0 }
        int("MAX_CONCURRENT_BLOCK_VALIDATIONS") { t.gossip.maxConcurrentBlockValidations = $0 }
        int("MAX_PENDING_GOSSIP_TASKS") { t.gossip.maxPendingGossipTasks = $0 }
        int("MAX_PENDING_CHAIN_ANNOUNCE_TASKS") { t.gossip.maxPendingChainAnnounceTasks = $0 }

        dbl("MEMPOOL_GOSSIP_CAPACITY") { t.rateLimit.mempoolGossipCapacity = $0 }
        dbl("MEMPOOL_GOSSIP_REFILL_PER_SEC") { t.rateLimit.mempoolGossipRefillPerSec = $0 }
        int("MEMPOOL_FULL_BAN_THRESHOLD") { t.rateLimit.mempoolFullBanThreshold = $0 }
        int("HARD_FAULT_BAN_THRESHOLD") { t.rateLimit.hardFaultBanThreshold = $0 }

        int("EXTRACTOR_MAX_PENDING_TASKS") { t.parentExtractor.maxPendingExtractionTasks = $0 }

        int("EVICT_GRACE_SECONDS") { t.storage.evictGraceSeconds = $0 }
        int("MEMPOOL_TX_EXPIRY_SECONDS") { t.storage.mempoolTxExpirySeconds = $0 }

        return t
    }
}
