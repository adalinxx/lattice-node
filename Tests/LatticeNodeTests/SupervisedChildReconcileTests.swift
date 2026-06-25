import XCTest
@testable import Lattice
@testable import LatticeNode

/// Item 2: the supervised-child lifecycle is a durable, reconciled state machine.
/// These cover the transitions that don't require a live child process — detach
/// durability and the detached-skip invariant — so a detached child is never
/// auto-respawned and detach is reflected in persisted metadata + registration.
final class SupervisedChildReconcileTests: XCTestCase {

    private func makeSupervisedNode() async throws -> (LatticeNode, URL) {
        let kp = CryptoUtils.generateKeyPair()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervised-reconcile-\(UUID().uuidString)")
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: path,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(
            config: config, genesisConfig: testGenesis(),
            superviseChildren: true, childRPCBasePort: nextTestPort()
        )
        return (node, path)
    }

    private func meta(detached: Bool = false) -> LatticeNode.DeployedChainMetadata {
        LatticeNode.DeployedChainMetadata(
            chainPath: ["Nexus", "Child"], directory: "Child", parentDirectory: "Nexus",
            genesisHash: "g", genesisHex: "ab", timestamp: 1, detached: detached
        )
    }

    func test_detachedChild_isSkippedByReconcile() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }
        await node.recordDeployedChildChain(meta(detached: true))
        let state = await node.ensureSupervisedChild(meta(detached: true))
        XCTAssertEqual(state, .detached, "a detached child must never be (re)spawned")
    }

    // Regression for the detach/reconcile race: reconcile snapshots a NON-detached
    // metadata, but an operator `chain detach` lands before the ensure pass acts. The
    // ensure pass must consult LIVE state (detached) — not its stale snapshot — and must
    // not register or spawn the child.
    func test_detach_beatsStaleReconcileSnapshot() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }

        await node.recordDeployedChildChain(meta())                 // managed, non-detached
        let staleSnapshot = meta(detached: false)                   // what reconcile captured
        await node.detachSupervisedChild(chainPath: ["Nexus", "Child"])  // live state now detached

        // Acting on the stale (non-detached) snapshot must still honor the live detach.
        let state = await node.ensureSupervisedChild(staleSnapshot)
        XCTAssertEqual(state, .detached, "ensure must honor live detached state, not its stale snapshot")
        let endpoint = await node.registeredRPCEndpoint(chainPath: ["Nexus", "Child"])
        XCTAssertNil(endpoint, "a detached child must not be re-registered by a stale reconcile pass")
        let running = await node.childSupervisor?.isRunning("Child")
        XCTAssertNotEqual(running, true, "a detached child must not be respawned by a stale reconcile pass")
    }

    func test_detach_isDurable_and_dropsRegistration() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }

        await node.recordDeployedChildChain(meta())
        await node.registerRPCEndpoint(chainPath: ["Nexus", "Child"],
                                       endpoint: "http://127.0.0.1:65000/api", authToken: "tok")
        let registeredBefore = await node.registeredRPCEndpoint(chainPath: ["Nexus", "Child"])
        XCTAssertNotNil(registeredBefore)

        await node.detachSupervisedChild(chainPath: ["Nexus", "Child"])

        // Registration dropped...
        let endpoint = await node.registeredRPCEndpoint(chainPath: ["Nexus", "Child"])
        XCTAssertNil(endpoint, "detach must drop the child's RPC registration")
        // ...and the detached flag is durable across a reload.
        let reloaded = LatticeNode.decodeDeployedChildChains(
            try Data(contentsOf: path.appendingPathComponent("deployed_child_chains.json"))
        )
        XCTAssertEqual(reloaded["Nexus/Child"]?.detached, true,
                       "detach must persist so restart/idempotent-deploy do not auto-respawn")

        // And a subsequent reconcile pass leaves it detached (no respawn).
        let state = await node.ensureSupervisedChild(reloaded["Nexus/Child"]!)
        XCTAssertEqual(state, .detached)
    }

    func test_nonSupervisedNode_doesNotManageChildren() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsupervised-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: path,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        let state = await node.ensureSupervisedChild(meta())
        XCTAssertEqual(state, .detached, "a node without a supervisor manages nothing")
    }
}
