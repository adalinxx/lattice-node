import XCTest
import VolumeBroker

/// MemoryBroker enforces a resident-BYTE budget, not a volume-count
/// cap, so `--max-memory` is a real ceiling even for large volumes.
final class VolumeBrokerTests: XCTestCase {
    private static let mib = 1024 * 1024

    private func oneMiBVolume(_ root: String) -> SerializedVolume {
        SerializedVolume(root: root, entries: [root: Data(count: Self.mib)])
    }

    func testMemoryBrokerEvictsByByteBudget() async throws {
        let budget = 4 * Self.mib
        let broker = MemoryBroker(byteBudget: budget)

        // Store 100 distinct unpinned 1 MiB volumes; resident bytes must stay
        // bounded by the budget rather than retaining all ~100 MiB.
        for i in 0..<100 {
            try await broker.storeVolumeLocal(oneMiBVolume("unpinned-\(i)"))
        }
        let residentAfterUnpinned = await broker.residentBytes()
        XCTAssertLessThanOrEqual(residentAfterUnpinned, budget)

        // Pin one 1 MiB volume, then store 100 more unpinned volumes. The pinned
        // volume must survive eviction and resident bytes must stay <= budget.
        let pinnedRoot = "pinned"
        try await broker.storeVolumeLocal(oneMiBVolume(pinnedRoot))
        try await broker.pin(root: pinnedRoot, owner: "test", count: 1)
        for i in 0..<100 {
            try await broker.storeVolumeLocal(oneMiBVolume("more-unpinned-\(i)"))
        }

        let pinned = await broker.fetchVolumeLocal(root: pinnedRoot)
        XCTAssertNotNil(pinned, "pinned volume must not be evicted")
        let residentFinal = await broker.residentBytes()
        XCTAssertLessThanOrEqual(residentFinal, budget)
    }
}
