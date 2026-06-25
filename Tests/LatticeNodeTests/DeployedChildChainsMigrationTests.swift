import XCTest
@testable import Lattice
@testable import LatticeNode

/// Persisted files are protocol formats: adding a field must not wipe a parent's
/// deployed-child set on upgrade. These tests pin the decode/migration behavior of
/// `deployed_child_chains.json` against old- and new-schema fixtures.
final class DeployedChildChainsMigrationTests: XCTestCase {

    // v1 legacy fixture: a bare `[chainKey: metadata]` map with NO `detached` key —
    // exactly what a pre-`detached` node wrote. This is the regression that silently
    // returned [:] (erasing all deployed-child metadata) before the custom decoder.
    private let legacyV1JSON = """
    {
      "Nexus/Payments": {
        "chainPath": ["Nexus", "Payments"],
        "directory": "Payments",
        "parentDirectory": "Nexus",
        "genesisHash": "baguqeeraGENESIS",
        "genesisHex": "deadbeef",
        "timestamp": 1700000000000
      }
    }
    """

    func test_v1LegacyMap_decodesAndDefaultsDetachedFalse() throws {
        let data = Data(legacyV1JSON.utf8)
        let map = LatticeNode.decodeDeployedChildChains(data)
        let entry = try XCTUnwrap(map["Nexus/Payments"], "legacy v1 metadata must NOT be silently dropped")
        XCTAssertEqual(entry.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(entry.genesisHash, "baguqeeraGENESIS")
        XCTAssertEqual(entry.genesisHex, "deadbeef")
        XCTAssertFalse(entry.detached, "a field absent in the old schema must default, not throw")
    }

    func test_v2Envelope_roundTripsIncludingDetached() throws {
        let meta = LatticeNode.DeployedChainMetadata(
            chainPath: ["Nexus", "A"], directory: "A", parentDirectory: "Nexus",
            genesisHash: "g", genesisHex: "ab", timestamp: 1, detached: true
        )
        let file = LatticeNode.DeployedChildChainsFile(chains: ["Nexus/A": meta])
        let data = try JSONEncoder().encode(file)
        // The on-disk form is the versioned envelope, not a bare map.
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, LatticeNode.DeployedChildChainsFile.currentVersion)
        XCTAssertNotNil(obj?["chains"])

        let decoded = LatticeNode.decodeDeployedChildChains(data)
        XCTAssertEqual(decoded["Nexus/A"]?.detached, true)
        XCTAssertEqual(decoded["Nexus/A"]?.directory, "A")
    }

    func test_corruptFile_returnsEmptyWithoutThrowing() {
        let map = LatticeNode.decodeDeployedChildChains(Data("{ not json".utf8))
        XCTAssertTrue(map.isEmpty, "a corrupt file must fail closed to empty, not crash")
    }

    // The real upgrade path: an old-schema file already on disk must survive a node
    // restart (restoreDeployedChildChains) — i.e. the parent retains its deployed-child
    // genesis for reconcile / idempotent deploy / /chain/genesis.
    func test_upgrade_oldSchemaFileSurvivesRestart() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("deployed-child-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        try legacyV1JSON.write(
            to: storagePath.appendingPathComponent("deployed_child_chains.json"),
            atomically: true, encoding: .utf8
        )

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: storagePath,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        await node.restoreDeployedChildChains()

        let deployed = await node.deployedChildChains
        let entry = try XCTUnwrap(deployed["Nexus/Payments"],
                                  "upgrading a node must NOT erase deployed-child metadata written by the old schema")
        XCTAssertEqual(entry.genesisHex, "deadbeef")
        XCTAssertFalse(entry.detached)

        // Re-persist now writes the versioned envelope.
        await node.persistDeployedChildChains()
        let reread = try Data(contentsOf: storagePath.appendingPathComponent("deployed_child_chains.json"))
        let obj = try JSONSerialization.jsonObject(with: reread) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, LatticeNode.DeployedChildChainsFile.currentVersion,
                       "after load+persist the file is migrated to the versioned envelope")
    }
}
