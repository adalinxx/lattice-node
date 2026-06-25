import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth

// Item 2 follow-up: exercise the supervised reconciler's probe → adopt/degraded
// branches against a REAL child RPC (a live HTTP server on the child's deterministic
// port), plus the health-grace booting decision against a real tracked process. These
// are the new, intricate paths that the non-network unit tests don't reach.
//
// The reconciler probes http://127.0.0.1:<deterministicPort(rpcBase,"Child")>/api/...,
// so we reverse-derive rpcBase from a free port we control and bind the child RPC there.
// (The recover-spawn and force-restart paths launch the node binary and are covered by
// ChildProcessSupervisorTests' spawn/restart mechanics; here we cover everything up to,
// but not including, launching a real child process.)
final class SupervisedReconcileIntegrationTests: XCTestCase {

    private let childPath = ["Nexus", "Child"]
    private var cleanups: [() async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
    }

    // base such that deterministicPort(base, "Child") == port (FNV-1a, 14-bit slot).
    private func baseTargeting(_ port: UInt16, dir: String = "Child") -> UInt16 {
        var h: UInt32 = 2166136261
        for b in dir.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return port &- 1 &- UInt16(h & 0x3FFF)
    }

    private func meta() -> LatticeNode.DeployedChainMetadata {
        LatticeNode.DeployedChainMetadata(
            chainPath: childPath, directory: "Child", parentDirectory: "Nexus",
            genesisHash: "g", genesisHex: "ab", timestamp: 1)
    }

    private func makeParent(childRpcPort: UInt16) async throws -> (LatticeNode, URL) {
        let kp = CryptoUtils.generateKeyPair()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("recon-parent-\(UUID().uuidString)")
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(), storagePath: path,
                enableLocalDiscovery: false, minPeerKeyBits: 0),
            genesisConfig: testGenesis(),
            superviseChildren: true, childRPCBasePort: baseTargeting(childRpcPort))
        cleanups.append { await node.stop(); try? FileManager.default.removeItem(at: path) }
        return (node, path)
    }

    /// Stand up a real child RPC on `port` that accepts exactly `token`.
    private func startChildRPC(port: UInt16, token: String) async throws {
        let kp = CryptoUtils.generateKeyPair()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("recon-child-\(UUID().uuidString)")
        let child = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(), storagePath: path,
                enableLocalDiscovery: false, minPeerKeyBits: 0),
            genesisConfig: testGenesis())
        try await child.start()
        let auth = CookieAuth(token: token, path: path.appendingPathComponent(".cookie"))
        let server = RPCServer(node: child, port: port, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: auth)
        let task = Task { try await server.run() }
        try await waitForRPCServer(port: port)
        cleanups.append { task.cancel(); await child.stop(); try? FileManager.default.removeItem(at: path) }
    }

    /// Write the cookie the reconciler will read from the child's data dir.
    private func writeChildCookie(parentStorage: URL, token: String?) throws {
        let dir = parentStorage.appendingPathComponent("children").appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cookie = dir.appendingPathComponent(".cookie")
        if let token { try token.write(to: cookie, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: cookie) }
    }

    // Parent restart, child still alive, persisted token still valid ⇒ ADOPT (no spawn).
    func test_adoptLiveChild_withValidPersistedToken() async throws {
        let childRpcPort = nextTestPort()
        let (parent, ppath) = try await makeParent(childRpcPort: childRpcPort)
        try await startChildRPC(port: childRpcPort, token: "cookieC")

        await parent.recordDeployedChildChain(meta())
        await parent.registerRPCEndpoint(chainPath: childPath, endpoint: "http://127.0.0.1:\(childRpcPort)/api", authToken: "cookieC")

        let state = await parent.ensureSupervisedChild(meta())
        XCTAssertEqual(state, .registered, "a live child with a valid persisted token must be adopted")
        let running = await parent.childSupervisor?.isRunning("Child")
        XCTAssertNotEqual(running, true, "adoption must not spawn a duplicate process")
        let token = await parent.registeredRPCAuthToken(chainPath: childPath)
        XCTAssertEqual(token, "cookieC")
    }

    // Child rotated its cookie (persisted token now 401). Reconciler re-reads the
    // on-disk cookie, re-probes, and adopts with the fresh token — never spawning.
    func test_adoptLiveChild_withRotatedCookie() async throws {
        let childRpcPort = nextTestPort()
        let (parent, ppath) = try await makeParent(childRpcPort: childRpcPort)
        try await startChildRPC(port: childRpcPort, token: "cookieNEW")

        await parent.recordDeployedChildChain(meta())
        // Parent holds a STALE token; the child's current cookie is on disk.
        await parent.registerRPCEndpoint(chainPath: childPath, endpoint: "http://127.0.0.1:\(childRpcPort)/api", authToken: "cookieOLD")
        try writeChildCookie(parentStorage: ppath, token: "cookieNEW")

        let state = await parent.ensureSupervisedChild(meta())
        XCTAssertEqual(state, .registered, "a live child with a rotated cookie must be adopted via the on-disk cookie")
        let running = await parent.childSupervisor?.isRunning("Child")
        XCTAssertNotEqual(running, true, "rotated-cookie adoption must not spawn into the occupied port")
        let token = await parent.registeredRPCAuthToken(chainPath: childPath)
        XCTAssertEqual(token, "cookieNEW", "the reconciler must adopt the child's current on-disk cookie")
    }

    // Live child but NO on-disk cookie authenticates ⇒ DEGRADED: never spawn into the
    // occupied port; leave for manual recovery.
    func test_degraded_liveChildButNoWorkingCookie() async throws {
        let childRpcPort = nextTestPort()
        let (parent, ppath) = try await makeParent(childRpcPort: childRpcPort)
        try await startChildRPC(port: childRpcPort, token: "cookieNEW")

        await parent.recordDeployedChildChain(meta())
        await parent.registerRPCEndpoint(chainPath: childPath, endpoint: "http://127.0.0.1:\(childRpcPort)/api", authToken: "cookieOLD")
        try writeChildCookie(parentStorage: ppath, token: nil)   // no usable cookie on disk

        let state = await parent.ensureSupervisedChild(meta())
        XCTAssertEqual(state, .degraded, "a live child with no authenticating cookie must be DEGRADED, not respawned")
        let running = await parent.childSupervisor?.isRunning("Child")
        XCTAssertNotEqual(running, true, "degraded must not spawn into the live port")
    }

    // Tracked process alive but RPC not yet answering, within the health grace ⇒ BOOTING
    // (no forced restart). Uses a real tracked stub process so isRunning is true while the
    // probe to the (unserved) child RPC port fails.
    func test_healthGrace_trackedButRpcDown_isBootingWithinGrace() async throws {
        let childRpcPort = nextTestPort()   // nothing will listen here
        let (parent, ppath) = try await makeParent(childRpcPort: childRpcPort)

        await parent.recordDeployedChildChain(meta())
        // Make the supervisor track a live process under label "Child" without serving RPC.
        _ = try await parent.childSupervisor?.spawn(
            SupervisedLaunch(label: "Child", executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]))

        let state = await parent.ensureSupervisedChild(meta())
        XCTAssertEqual(state, .booting,
            "a tracked process whose RPC is not up yet must be treated as booting within the health grace, not force-restarted")
    }
}
