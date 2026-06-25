import XCTest
@testable import Lattice
@testable import LatticeNode

/// Discovery + follow: a node can enumerate a chain's announced children from its on-chain
/// GenesisState (listChildChains), and declare intent to FOLLOW a child it did not deploy.
/// A followed child is a first-class reconciler citizen whose genesis is resolved from the
/// parent state on a later pass — until then it must NOT spawn. The end-to-end resolution +
/// spawn + sync over CAS is covered by the permissionless-child-join smoke scenario; these
/// cover the metadata/durability/state-machine pieces that don't need a live network.
final class ChildFollowTests: XCTestCase {

    private func makeSupervisedNode() async throws -> (LatticeNode, URL) {
        let kp = CryptoUtils.generateKeyPair()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-follow-\(UUID().uuidString)")
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

    private func reload(_ path: URL) throws -> [String: LatticeNode.DeployedChainMetadata] {
        LatticeNode.decodeDeployedChildChains(
            try Data(contentsOf: path.appendingPathComponent("deployed_child_chains.json")))
    }

    // A fresh chain has no announced children; the enumeration read returns empty, not throws.
    func test_listChildChains_emptyOnFreshNode() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }
        let children = try await node.listChildChains(chainPath: ["Nexus"])
        XCTAssertTrue(children.isEmpty, "a fresh Nexus has no announced children in GenesisState")
    }

    // follow records a durable followed stub: followed=true, no genesis yet, not detached.
    func test_followChild_recordsDurableFollowedStub() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }
        await node.followChild(chainPath: ["Nexus", "Toy"])
        let meta = try reload(path)["Nexus/Toy"]
        XCTAssertEqual(meta?.followed, true, "follow must persist a followed stub")
        XCTAssertEqual(meta?.genesisHex, "", "a followed stub starts with no genesis (resolved on reconcile)")
        XCTAssertEqual(meta?.detached, false)
    }

    // A followed child whose genesis can't be resolved (not announced in this node's
    // GenesisState) must stay `resolving` and never spawn a process without a genesis.
    func test_followedChild_unresolvableGenesis_staysResolving() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }
        await node.followChild(chainPath: ["Nexus", "Toy"])
        let meta = LatticeNode.DeployedChainMetadata(
            chainPath: ["Nexus", "Toy"], directory: "Toy", parentDirectory: "Nexus",
            genesisHash: "", genesisHex: "", timestamp: 0, followed: true)
        let state = await node.ensureSupervisedChild(meta)
        XCTAssertEqual(state, .resolving,
            "a followed child whose genesis isn't resolvable must stay resolving, not spawn")
        let running = await node.childSupervisor?.isRunning("Toy")
        XCTAssertNotEqual(running, true, "must not spawn a child without a resolved genesis")
    }

    // Re-following a previously detached child clears the detach so management resumes.
    func test_refollow_clearsPriorDetach() async throws {
        let (node, path) = try await makeSupervisedNode()
        defer { try? FileManager.default.removeItem(at: path) }
        await node.followChild(chainPath: ["Nexus", "Toy"])
        await node.detachSupervisedChild(chainPath: ["Nexus", "Toy"])
        XCTAssertEqual(try reload(path)["Nexus/Toy"]?.detached, true)
        await node.followChild(chainPath: ["Nexus", "Toy"])
        let meta = try reload(path)["Nexus/Toy"]
        XCTAssertEqual(meta?.detached, false, "re-following must clear a prior detach")
        XCTAssertEqual(meta?.followed, true)
    }
}
