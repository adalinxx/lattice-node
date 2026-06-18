import Foundation

public actor FeeEstimator {
    private var blockFeeData: [(height: UInt64, fees: [UInt64])] = []
    /// Maintained in ascending sorted order — avoids re-sorting on every estimate() call.
    private var sortedMinimums: [UInt64] = []
    private let windowSize: Int

    public init(windowSize: Int = 100) {
        self.windowSize = windowSize
    }

    public func recordBlock(height: UInt64, transactionFees: [UInt64]) {
        // Evict oldest block and its minimum from the sorted cache
        if blockFeeData.count >= windowSize {
            let oldest = blockFeeData.first!
            if let oldMin = oldest.fees.min() {
                let idx = sortedMinimums.ascendingInsertionIndex(for: oldMin)
                if idx < sortedMinimums.count && sortedMinimums[idx] == oldMin {
                    sortedMinimums.remove(at: idx)
                }
            }
            blockFeeData.removeFirst()
        }
        blockFeeData.append((height: height, fees: transactionFees))
        // Insert new minimum in sorted position: O(log n) search + O(n) shift
        if let newMin = transactionFees.min() {
            let insertIdx = sortedMinimums.ascendingInsertionIndex(for: newMin)
            sortedMinimums.insert(newMin, at: insertIdx)
        }
    }

    public func estimate(confirmationTarget: Int) -> UInt64 {
        guard !sortedMinimums.isEmpty else { return 1 }

        let percentile: Double
        switch confirmationTarget {
        case ...1:
            percentile = 0.90
        case 2...5:
            percentile = 0.60
        case 6...10:
            percentile = 0.30
        default:
            percentile = 0.10
        }

        let index = min(Int(Double(sortedMinimums.count - 1) * percentile), sortedMinimums.count - 1)
        return max(sortedMinimums[index], 1)
    }

    public func histogram() -> [(range: String, count: Int)] {
        // Single pass through all fees — no intermediate array allocation, O(n) instead of O(5n)
        var counts = (0, 0, 0, 0, 0)
        var total = 0
        for block in blockFeeData {
            for fee in block.fees {
                total += 1
                switch fee {
                case 1...10:     counts.0 += 1
                case 11...100:   counts.1 += 1
                case 101...1000: counts.2 += 1
                case 1001...10000: counts.3 += 1
                default: if fee > 10000 { counts.4 += 1 }
                }
            }
        }
        guard total > 0 else { return [] }

        var result: [(range: String, count: Int)] = []
        if counts.0 > 0 { result.append((range: "1-10", count: counts.0)) }
        if counts.1 > 0 { result.append((range: "11-100", count: counts.1)) }
        if counts.2 > 0 { result.append((range: "101-1000", count: counts.2)) }
        if counts.3 > 0 { result.append((range: "1001-10000", count: counts.3)) }
        if counts.4 > 0 { result.append((range: "10001+", count: counts.4)) }
        return result
    }

    public var blockCount: Int { blockFeeData.count }
}
