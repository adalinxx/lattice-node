import XCTest
@testable import Lattice
@testable import LatticeNode
import VolumeBroker
import Ivy
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unit tests for the broker-backed IvyDataSource contract.
///
/// Ivy now asks for opaque Volumes by root CID. `volumeData(root, cids: [])`
/// is the serving path and must return the entries scoped to that root, while
/// `hasVolume` remains a root-only compatibility/introspection helper.
final class WantProtocolUnitTests: XCTestCase {

    // MARK: - Helpers

    private func makeBrokers(tmpDir: URL) throws -> (memory: MemoryBroker, disk: DiskBroker) {
        let diskPath = tmpDir.appendingPathComponent("test.db").path
        let disk = try DiskBroker(path: diskPath)
        let memory = MemoryBroker(capacity: 1024)
        return (memory, disk)
    }

    /// Minimal IvyDataSource that mirrors ChainNetwork.hasVolume logic.
    /// Tests the broker-chain logic directly without spinning up a full ChainNetwork.
    private actor BrokerBackedDataSource: IvyDataSource {
        let memory: MemoryBroker
        let disk: DiskBroker

        init(memory: MemoryBroker, disk: DiskBroker) {
            self.memory = memory
            self.disk = disk
        }

        func data(for cid: String) async -> Data? {
            if let data = await memory.fetchVolumeLocal(root: cid)?.entries[cid] {
                return data
            }
            return await disk.fetchVolumeLocal(root: cid)?.entries[cid]
        }

        func volumeData(for rootCID: String, cids: [String]) async -> [(cid: String, data: Data)] {
            let payload: SerializedVolume?
            if let memoryPayload = await memory.fetchVolumeLocal(root: rootCID) {
                payload = memoryPayload
            } else {
                payload = await disk.fetchVolumeLocal(root: rootCID)
            }
            guard let payload else { return [] }
            if cids.isEmpty { return payload.entries.map { (cid: $0.key, data: $0.value) } }
            return cids.compactMap { cid in payload.entries[cid].map { (cid: cid, data: $0) } }
        }

        func hasVolume(rootCID: String) async -> Bool {
            if let payload = await memory.fetchVolumeLocal(root: rootCID), !payload.entries.isEmpty {
                return true
            }
            return await disk.hasVolume(root: rootCID)
        }

        func storeInMemory(rootCID: String, data: Data) async throws {
            try await memory.storeVolumeLocal(SerializedVolume(root: rootCID, entries: [rootCID: data]))
        }

        func storeInDisk(rootCID: String, data: Data) async throws {
            try await disk.storeVolumeLocal(SerializedVolume(root: rootCID, entries: [rootCID: data]))
        }
    }

    // MARK: - Tests

    func testHasVolumeReturnsTrueForMemoryBroker() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootCID = "bafy-memory-test-cid"
        let data = Data("block bytes".utf8)
        try await ds.storeInMemory(rootCID: rootCID, data: data)

        let result = await ds.hasVolume(rootCID: rootCID)
        XCTAssertTrue(result, "hasVolume must return true for content in MemoryBroker")
    }

    func testHasVolumeReturnsTrueForDiskBroker() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootCID = "bafy-disk-test-cid00"
        let data = Data("block bytes on disk".utf8)
        // Store only in disk (not memory)
        try await ds.storeInDisk(rootCID: rootCID, data: data)

        let result = await ds.hasVolume(rootCID: rootCID)
        XCTAssertTrue(result, "hasVolume must return true for content in DiskBroker when MemoryBroker misses")
    }

    func testHasVolumeReturnsFalseForUnknown() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let result = await ds.hasVolume(rootCID: "bafy-unknown-cid-000")
        XCTAssertFalse(result, "hasVolume must return false for unknown rootCID")
    }

    /// Critical: if a block is in MemoryBroker but NOT DiskBroker (recently received,
    /// not yet flushed), hasVolume must still return true.
    /// This prevents a node from sending notHave for content it actually has.
    func testHasVolumeChecksMemoryBeforeDisk() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootCID = "bafy-memory-only-cid"
        // Store ONLY in memory — disk is empty
        try await memory.storeVolumeLocal(SerializedVolume(root: rootCID, entries: [rootCID: Data("data".utf8)]))

        // Verify disk is empty for this CID
        let diskHas = await disk.hasVolume(root: rootCID)
        XCTAssertFalse(diskHas, "Precondition: disk must not have this CID")

        // hasVolume must still return true (found in MemoryBroker)
        let result = await ds.hasVolume(rootCID: rootCID)
        XCTAssertTrue(result,
            "hasVolume must return true when content is in MemoryBroker — not only when on disk")
    }

    /// Before storing a Volume root: hasVolume returns false.
    /// After storing that Volume root: hasVolume returns true.
    func testHasVolumeIsFalseBeforeTrueAfterStore() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootCID = "bafy-before-after-00"
        let before = await ds.hasVolume(rootCID: rootCID)
        XCTAssertFalse(before, "hasVolume must be false before storing")

        try await ds.storeInDisk(rootCID: rootCID, data: Data("stored now".utf8))

        let after = await ds.hasVolume(rootCID: rootCID)
        XCTAssertTrue(after, "hasVolume must be true after storing the root CID")
    }

    func testHasDurableVolumeBypassesDiskNegativeCacheAfterLargeBatchStore() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let disk = try DiskBroker(path: tmpDir.appendingPathComponent("volumes.sqlite").path)
        let kp = CryptoUtils.generateKeyPair()
        let network = try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )

        let target = "bafy-negative-cache-target"
        let beforeStore = await network.hasDurableVolume(rootCID: target)
        XCTAssertFalse(beforeStore)

        let payloads: [SerializedVolume] = (0..<600).map { index in
            let root = index == 0 ? target : "bafy-negative-cache-\(index)"
            return SerializedVolume(root: root, entries: [root: Data("payload-\(index)".utf8)])
        }
        try await network.storeVolumesDurably(payloads)

        let storedTarget = await disk.fetchVolumeLocal(root: target)
        XCTAssertNotNil(storedTarget, "precondition: target bytes are durably stored")
        let afterStore = await network.hasDurableVolume(rootCID: target)
        XCTAssertTrue(
            afterStore,
            "durable consensus guards must verify stored bytes, not trust DiskBroker's negative-cache fast path"
        )
    }

    /// hasVolume only checks root CIDs, not sub-CIDs.
    /// Internal entries are stored inside their owning Volume, not promoted to
    /// roots. hasVolume for a sub-CID must return false.
    func testHasVolumeIsRootOnlyNotSubCID() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootCID = "bafy-root-cid-000000"
        let subCID = "bafy-sub-cid-0000000"

        // Store root with subCID as an internal entry (not as a root)
        try await disk.storeVolumeLocal(SerializedVolume(root: rootCID, entries: [
            rootCID: Data("root bytes".utf8),
            subCID: Data("sub bytes".utf8)
        ]))

        // Root CID is findable as a root
        let rootHas = await ds.hasVolume(rootCID: rootCID)
        XCTAssertTrue(rootHas, "hasVolume must return true for the stored root CID")

        // Sub-CID is NOT stored as its own root — hasVolume returns false
        let subHas = await ds.hasVolume(rootCID: subCID)
        XCTAssertFalse(subHas,
            "hasVolume must return false for a sub-CID that's only stored as an entry, not as a root")
    }

    func testChainNetworkHasCIDSeesDurableInternalEntries() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let disk = try DiskBroker(path: tmpDir.appendingPathComponent("volumes.sqlite").path)
        let kp = CryptoUtils.generateKeyPair()
        let network = try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )

        let rootCID = "bafy-root-cid-000000"
        let subCID = "bafy-sub-cid-0000000"
        try await network.storeVolumesDurably([
            SerializedVolume(root: rootCID, entries: [
                rootCID: Data("root bytes".utf8),
                subCID: Data("sub bytes".utf8),
            ])
        ])

        let rootHasVolume = await network.hasDurableVolume(rootCID: rootCID)
        let subHasVolume = await network.hasDurableVolume(rootCID: subCID)
        let subHasCID = await network.hasCID(subCID)
        let missingHasCID = await network.hasCID("bafy-missing-cid-000000")

        XCTAssertTrue(rootHasVolume)
        XCTAssertFalse(subHasVolume,
            "hasDurableVolume must stay root-only for volume-boundary checks")
        XCTAssertTrue(subHasCID,
            "hasCID must report durable CAS bytes for internal state-diff entries")
        XCTAssertFalse(missingHasCID)
    }

    func testVolumeDataEmptyCIDsReturnsRootScopedVolume() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootA = "bafy-root-a-0000000"
        let childA = "bafy-child-a-000000"
        let rootB = "bafy-root-b-0000000"

        try await disk.storeVolumeLocal(SerializedVolume(root: rootA, entries: [
            rootA: Data("root a".utf8),
            childA: Data("child a".utf8)
        ]))
        try await disk.storeVolumeLocal(SerializedVolume(root: rootB, entries: [
            rootB: Data("root b".utf8)
        ]))

        let entries = await ds.volumeData(for: rootA, cids: [])
        let cids = Set(entries.map(\.cid))

        XCTAssertEqual(cids, Set([rootA, childA]),
            "Empty cids must mean the full Volume for the requested root, not every stored CID")
    }

    func testVolumeDataFiltersWithinRequestedRootOnly() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (memory, disk) = try makeBrokers(tmpDir: tmpDir)
        let ds = BrokerBackedDataSource(memory: memory, disk: disk)

        let rootA = "bafy-root-filter-a"
        let childA = "bafy-child-filter-a"
        let rootB = "bafy-root-filter-b"

        try await disk.storeVolumeLocal(SerializedVolume(root: rootA, entries: [
            rootA: Data("root a".utf8),
            childA: Data("child a".utf8)
        ]))
        try await disk.storeVolumeLocal(SerializedVolume(root: rootB, entries: [
            rootB: Data("root b".utf8)
        ]))

        let entries = await ds.volumeData(for: rootA, cids: [childA, rootB])
        let cids = Set(entries.map(\.cid))

        XCTAssertEqual(cids, Set([childA]),
            "Filtered Volume reads must not leak entries from another Volume root")
    }
}
