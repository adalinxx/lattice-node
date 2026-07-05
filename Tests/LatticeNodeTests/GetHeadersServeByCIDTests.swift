import XCTest
@testable import LatticeNode
import VolumeBroker

/// Regression for the `getHeaders2`/`getHeaders` serve-path bug: header serving read the
/// ROOT-keyed volume index (`fetchVolumeLocal(root:)`), so it could only serve a block that
/// was ingested as a top-level volume on this chain. A block that arrived EMBEDDED inside a
/// parent volume (e.g. a toy block inside a Nexus block, root=nexusHash) — or was rebuilt by
/// CID-only crash recovery — has its bytes in `cas_data` (RPC serves it) but NO
/// `volume_entries(root=blockHash)` row, so `fetchVolumeLocal(root: blockHash)` returned nil
/// and the header walk stalled at genesis. The fix serves by CID (`fetchDataLocal(cid:)`),
/// which is exactly what the RPC block path and crash recovery already use.
///
/// This locks in the storage-layer invariant the fix depends on: embedded content is
/// fetchable by CID even when it has no root-keyed volume of its own.
final class GetHeadersServeByCIDTests: XCTestCase {

    func testEmbeddedBlockIsFetchableByCIDButNotByOwnRoot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)

        // A parent volume (root=parent) that EMBEDS a child block as a non-root entry —
        // mirrors a toy block carried inside a Nexus parent-block volume.
        let parentCID = "bafyparent0000000000000000000000000000000000000000000000000"
        let childCID  = "bafychild00000000000000000000000000000000000000000000000000"
        let parentData = Data("nexus-parent-block-bytes".utf8)
        let childData  = Data("toy-child-block-bytes".utf8)
        try await disk.storeVolumeLocal(
            SerializedVolume(root: parentCID, entries: [parentCID: parentData, childCID: childData]))

        // The child's bytes ARE present, addressable by CID (what RPC + the fixed serve path use).
        let byCID = await disk.fetchDataLocal(cid: childCID)
        XCTAssertEqual(byCID, childData, "embedded child block must be fetchable by CID (cas_data)")

        // But the child has NO root-keyed volume of its own — the old serve path's lookup.
        let byOwnRoot = await disk.fetchVolumeLocal(root: childCID)
        XCTAssertNil(byOwnRoot?.entries[childCID],
            "embedded child has no volume_entries(root=childCID) — this is why the old getHeaders2 stalled")

        // The parent, ingested as a top-level volume, IS fetchable by its own root (genesis-like).
        let parentByRoot = await disk.fetchVolumeLocal(root: parentCID)
        XCTAssertEqual(parentByRoot?.entries[parentCID], parentData,
            "a top-level volume IS root-fetchable — which is why only genesis served before the fix")
    }
}
