import Lattice
import Foundation
import Ivy

public struct NodeResourceConfig: Sendable {
    public let memoryBudgetGB: Double
    public let diskBudgetGB: Double
    public let mempoolBudgetMB: Double
    public let miningBatchSize: UInt64
    public let nodeIdentityHash: [UInt8]?
    /// Per-source-IP RPC ingress rate limit. Each distinct client IP gets an
    /// independent token bucket of `rpcBurstSize` tokens refilling at
    /// `rpcRequestsPerSecond`. Node-configurable; defaults are sized for a
    /// public bind where one client must not be able to starve the rest.
    public let rpcRequestsPerSecond: Int
    public let rpcBurstSize: Int

    public init(
        memoryBudgetGB: Double = 0.25,
        diskBudgetGB: Double = 1.0,
        mempoolBudgetMB: Double = 64.0,
        miningBatchSize: UInt64 = 10_000,
        nodeIdentityHash: [UInt8]? = nil,
        rpcRequestsPerSecond: Int = 50,
        rpcBurstSize: Int = 100
    ) {
        self.memoryBudgetGB = memoryBudgetGB
        self.diskBudgetGB = diskBudgetGB
        self.mempoolBudgetMB = mempoolBudgetMB
        self.miningBatchSize = miningBatchSize
        self.nodeIdentityHash = nodeIdentityHash
        self.rpcRequestsPerSecond = rpcRequestsPerSecond
        self.rpcBurstSize = rpcBurstSize
    }

    public static let `default` = NodeResourceConfig()

    public static let light = NodeResourceConfig(
        memoryBudgetGB: 0.064,
        diskBudgetGB: 0.25,
        mempoolBudgetMB: 16.0,
        miningBatchSize: 5_000
    )

    public func memoryBytesPerChain(chainCount: Int) -> Int {
        let total = safeGBtoBytes(memoryBudgetGB)
        return max(total / max(chainCount, 1), 1_048_576)
    }

    /// Total disk budget for the node's shared content-addressed store.
    /// All chains share this budget; per-chain protection pins decide what survives LRU.
    /// A budget of 0 is honored as-is (stateless mode); otherwise we floor at 1 MiB to avoid
    /// accidentally configuring a useless sub-MiB store.
    public func totalDiskBytes() -> Int {
        if diskBudgetGB <= 0 { return 0 }
        return max(safeGBtoBytes(diskBudgetGB), 1_048_576)
    }

    public func mempoolSizePerChain(chainCount: Int) -> Int {
        let totalBytes = safeMBtoBytes(mempoolBudgetMB)
        let estimatedTxSize = 512
        let totalTxs = totalBytes / estimatedTxSize
        return max(totalTxs / max(chainCount, 1), 100)
    }

    /// H7: the REAL per-node mempool byte budget (the sum of admitted txs'
    /// serialized body bytes the mempool is allowed to retain), derived from
    /// `mempoolBudgetMB`. Bounding the mempool by tx COUNT alone (the legacy
    /// `mempoolSizePerChain`) lets a flood of large bodies amplify memory ~200×
    /// over the intended budget; this byte budget is what NodeMempool enforces
    /// alongside the count cap so neither dimension can be exceeded.
    /// H7: the node-wide mempool byte budget. This is enforced as a SHARED
    /// cross-chain cap (a single `MempoolByteLimiter` every chain's mempool debits)
    /// rather than sliced per-chain, so the total holds regardless of how many
    /// chains are subscribed or registered later. 0 means unbounded bytes.
    public var mempoolByteBudgetBytes: UInt64 {
        UInt64(max(safeMBtoBytes(mempoolBudgetMB), 0))
    }

    /// H7: largest permitted gap between an admitted tx's nonce and the sender's
    /// confirmed nonce (mirrors NodeMempool's default). Caps how far into the
    /// future a sender can reserve mempool slots.
    public var mempoolMaxNonceGap: UInt64 { 64 }

    /// H7: maximum number of queued transactions a single sender may hold in the
    /// mempool (mirrors NodeMempool's default). Bounds per-account slot squatting.
    public var mempoolMaxPerAccount: UInt64 { 64 }

    /// Maximum CID data size (bytes) accepted via pinRequest.
    /// Peers send pinRequest messages to push data into this node's disk.
    /// Without a size cap, a malicious peer can exhaust disk at the rate-limit
    /// rate × CID size (SEC-502). Defaults to 10 MB — large enough for any
    /// valid block, small enough to bound the per-request disk footprint.
    public var maxPinRequestBytes: Int { 10 * 1_048_576 }

    /// Convert a GB value to bytes, clamped to [0, Int.max] to prevent
    /// Swift runtime traps on infinity, NaN, or values exceeding Int.max.
    private func safeGBtoBytes(_ gb: Double) -> Int {
        let bytes = gb * 1_073_741_824
        guard bytes.isFinite, bytes >= 0, bytes <= Double(Int.max) else {
            return gb > 0 ? Int.max / 2 : 0
        }
        return Int(bytes)
    }

    private func safeMBtoBytes(_ mb: Double) -> Int {
        let bytes = mb * 1_048_576
        guard bytes.isFinite, bytes >= 0, bytes <= Double(Int.max) else {
            return mb > 0 ? Int.max / 2 : 0
        }
        return Int(bytes)
    }

    public func withIdentity(publicKey: String) -> NodeResourceConfig {
        NodeResourceConfig(
            memoryBudgetGB: memoryBudgetGB,
            diskBudgetGB: diskBudgetGB,
            mempoolBudgetMB: mempoolBudgetMB,
            miningBatchSize: miningBatchSize,
            nodeIdentityHash: Router.hash(publicKey),
            rpcRequestsPerSecond: rpcRequestsPerSecond,
            rpcBurstSize: rpcBurstSize
        )
    }

    public static func autosize(
        dataDir: URL,
        maxMemoryGB: Double? = nil,
        maxDiskGB: Double? = nil
    ) -> NodeResourceConfig {
        let systemRAMBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let systemRAMGB = systemRAMBytes / 1_073_741_824

        let freeDiskBytes = (try? FileManager.default.attributesOfFileSystem(
            forPath: dataDir.path
        )[.systemFreeSize] as? Int) ?? 0
        let freeDiskGB = Double(freeDiskBytes) / 1_073_741_824

        // Memory: 25% of system RAM, minimum 128MB, reserve 1GB for OS
        var memGB = max((systemRAMGB - 1.0) * 0.25, 0.128)
        if let cap = maxMemoryGB { memGB = min(memGB, cap) }

        // Disk: 50% of free disk, minimum 1GB, reserve 5GB for OS
        var diskGB = max((freeDiskGB - 5.0) * 0.50, 1.0)
        if let cap = maxDiskGB { diskGB = min(diskGB, cap) }

        // Mempool: 1% of memory budget, minimum 16MB
        let mempoolMB = max(memGB * 1024 * 0.01, 16.0)

        // Mining batch: scale with available cores
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let batch = UInt64(max(cores * 5_000, 10_000))

        return NodeResourceConfig(
            memoryBudgetGB: memGB,
            diskBudgetGB: diskGB,
            mempoolBudgetMB: mempoolMB,
            miningBatchSize: batch
        )
    }
}
