import Crypto
import Lattice
import UInt256

public struct NonceSearchRange: Sendable, Equatable {
    public let startNonce: UInt64
    public let count: UInt64

    public init(startNonce: UInt64, count: UInt64) {
        self.startNonce = startNonce
        self.count = count
    }
}

public enum ProofOfWork {
    /// Nonce-independent PoW preimage bytes the miner hashes once into a midstate.
    /// The consensus byte layout is owned by `Lattice.Block`; this delegates to the
    /// single source of truth rather than re-deriving it (see #135).
    public static func proofOfWorkHashPrefixBytes(_ block: Block) -> ContiguousArray<UInt8> {
        ContiguousArray(Block.makeProofOfWorkPreimagePrefix(block: block))
    }

    public static func withNonce(_ block: Block, nonce: UInt64) -> Block {
        Block(
            version: block.version,
            parent: block.parent,
            transactions: block.transactions,
            target: block.target,
            nextTarget: block.nextTarget,
            spec: block.spec,
            parentState: block.parentState,
            prevState: block.prevState,
            postState: block.postState,
            children: block.children,
            height: block.height,
            timestamp: block.timestamp,
            nonce: nonce
        )
    }

    public static func midstate(for block: Block) -> SHA256 {
        let prefixBytes = proofOfWorkHashPrefixBytes(block)
        return prefixBytes.withUnsafeBufferPointer { ptr in
            var hasher = SHA256()
            hasher.update(bufferPointer: UnsafeRawBufferPointer(ptr))
            return hasher
        }
    }

    public static func hash(midstate: SHA256, nonce: UInt64) -> UInt256 {
        var nonceBuf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let nonceLen = writeDecimalNonce(nonce, into: &nonceBuf)
        var hasher = midstate
        withUnsafePointer(to: &nonceBuf) { ptr in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: UnsafeRawPointer(ptr),
                count: nonceLen
            ))
        }
        let digest = hasher.finalize()
        return digest.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt64.self)
            return UInt256([
                UInt64(bigEndian: p[0]),
                UInt64(bigEndian: p[1]),
                UInt64(bigEndian: p[2]),
                UInt64(bigEndian: p[3])
            ])
        }
    }

    public static func searchNonce(
        midstate: SHA256,
        target: UInt256,
        totalBatchSize: UInt64,
        workerCount: Int,
        nonceOffset: UInt64
    ) async -> UInt64? {
        await searchNonce(
            midstate: midstate,
            target: target,
            ranges: nonceSearchRanges(
                totalBatchSize: totalBatchSize,
                workerCount: workerCount,
                nonceOffset: nonceOffset
            )
        )
    }

    public static func nonceSearchRanges(
        totalBatchSize: UInt64,
        workerCount: Int,
        nonceOffset: UInt64
    ) -> [NonceSearchRange] {
        let workerCount = max(workerCount, 1)
        let totalBatchSize = max(totalBatchSize, 1)
        let baseCount = totalBatchSize / UInt64(workerCount)
        let remainder = Int(totalBatchSize % UInt64(workerCount))

        var ranges: [NonceSearchRange] = []
        ranges.reserveCapacity(workerCount)

        var startNonce = nonceOffset
        for i in 0..<workerCount {
            let count = baseCount &+ (i < remainder ? 1 : 0)
            if count == 0 { continue }
            ranges.append(NonceSearchRange(startNonce: startNonce, count: count))
            startNonce &+= count
        }
        return ranges
    }

    public static func searchNonce(
        midstate: SHA256,
        target: UInt256,
        ranges: [NonceSearchRange]
    ) async -> UInt64? {
        guard !ranges.isEmpty else { return nil }
        let args = SendableSearchArgs(
            midstate: midstate,
            target: target
        )

        return await withTaskGroup(of: UInt64?.self) { group in
            for range in ranges {
                group.addTask {
                    searchBatch(
                        midstate: args.midstate,
                        target: args.target,
                        startNonce: range.startNonce,
                        count: range.count
                    )
                }
            }
            for await result in group {
                if let nonce = result {
                    group.cancelAll()
                    return nonce
                }
            }
            return nil
        }
    }

    public static func searchBatch(
        midstate: SHA256,
        target: UInt256,
        startNonce: UInt64,
        count: UInt64
    ) -> UInt64? {
        let end = startNonce &+ count
        var nonce = startNonce

        var nonceBuf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        while nonce < end {
            if nonce & 0x3FF == 0 && Task.isCancelled { return nil }

            let nonceLen = writeDecimalNonce(nonce, into: &nonceBuf)

            var hasher = midstate
            withUnsafePointer(to: &nonceBuf) { ptr in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(ptr),
                    count: nonceLen
                ))
            }
            let digest = hasher.finalize()
            let hash: UInt256 = digest.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt64.self)
                return UInt256([
                    UInt64(bigEndian: p[0]),
                    UInt64(bigEndian: p[1]),
                    UInt64(bigEndian: p[2]),
                    UInt64(bigEndian: p[3])
                ])
            }
            if target >= hash { return nonce }
            nonce &+= 1
        }
        return nil
    }

    private static func writeDecimalNonce(
        _ nonce: UInt64,
        into nonceBuf: inout (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    ) -> Int {
        if nonce == 0 {
            nonceBuf.0 = 0x30
            return 1
        }
        var n = nonce
        var digitCount = 0
        withUnsafeMutablePointer(to: &nonceBuf) { ptr in
            let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            while n > 0 {
                buf[digitCount] = UInt8(0x30 &+ (n % 10))
                n /= 10
                digitCount &+= 1
            }
            var lo = 0
            var hi = digitCount &- 1
            while lo < hi {
                let tmp = buf[lo]
                buf[lo] = buf[hi]
                buf[hi] = tmp
                lo &+= 1
                hi &-= 1
            }
        }
        return digitCount
    }
}

private struct SendableSearchArgs: @unchecked Sendable {
    let midstate: SHA256
    let target: UInt256
}
