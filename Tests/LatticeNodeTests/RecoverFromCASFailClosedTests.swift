import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy
import UInt256
import cashew

/// recovery must fail CLOSED, never fail-open into a silent divergent-state
/// boot. `recoverFromCAS` asserts convergence — after projecting ChainState from the
/// authoritative committed StateStore tip it must reach exactly that tip; if it can't
/// (e.g. a committed block is unfetchable from CAS so convergence is impossible) it
/// returns false and `start()` calls `markChainUnhealthy` → the chain is marked
/// unhealthy and its network stopped, rather than booting at a stale height with a
/// healthy live chain.
///
/// This is the small, FAST CI slice of that fail-closed guarantee, driven entirely
/// through existing observable surfaces
/// (`stateStore(for:)`, `network(for:).diskBroker`, `isChainUnhealthy(directory:)`).
final class RecoverFromCASFailClosedTests: XCTestCase {

    func testUnfetchableCommittedBlockFailsClosed() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis(spec: testSpec(), directory: "Nexus")
        let storagePath = tmpDir.appendingPathComponent("node1")

        // persistInterval high so mining past H=1 does NOT auto-persist chain_state:
        // the restart's ChainState is stale at H=1 while StateStore committed H=3, so
        // recoverFromCAS must walk forward from the committed tip on boot.
        func makeConfig(_ port: UInt16) -> LatticeNodeConfig {
            LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: port, storagePath: storagePath,
                enableLocalDiscovery: false, persistInterval: 100, retentionDepth: 3, minPeerKeyBits: 0
            )
        }

        let node1 = try await LatticeNode(config: makeConfig(nextTestPort()), genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(1, on: node1)
        await node1.persistChainState(directory: "Nexus")   // ChainState durably at H=1
        try await mineBlocks(2, on: node1)                   // committed tip advances to H=3 (not persisted)

        let store1Opt = await node1.stateStore(for: "Nexus")
        let store1 = try XCTUnwrap(store1Opt)
        let committedTip = try XCTUnwrap(store1.getChainTip())
        let committedHeight = store1.getHeight() ?? 0
        XCTAssertGreaterThanOrEqual(committedHeight, 3, "committed tip must have advanced past the persisted H=1")

        // Make the committed tip unfetchable from the durable broker so the recovery
        // walk from the StateStore head hits a CID resolve() cannot return.
        let network1Opt = await node1.network(for: "Nexus")
        let network1 = try XCTUnwrap(network1Opt)
        for owner in await network1.diskBroker.owners(root: committedTip) {
            try? await network1.diskBroker.unpin(root: committedTip, owner: owner, count: Int.max)
        }
        _ = try? await network1.diskBroker.evictUnpinned()
        // Ungraceful drop (no stop()).

        // Restart: recoverFromCAS cannot project ChainState to the committed tip, so
        // start() must fail closed.
        let node2 = try await LatticeNode(config: makeConfig(nextTestPort()), genesisConfig: genesis)
        try await node2.start()
        defer { Task { await node2.stop() } }

        let unhealthy = await node2.isChainUnhealthy(directory: "Nexus")
        let recoveredHeight = await node2.chain(for: "Nexus")!.getHighestBlockHeight()
        let convergedToCommitted = recoveredHeight == committedHeight

        // Fail-closed invariant: either the broker still served the data and recovery
        // converged to the committed tip, OR the block was unfetchable and the chain is
        // marked unhealthy. A silent HEALTHY boot at the stale persisted height (1) is
        // the fail-open behaviour recovery forbids.
        XCTAssertTrue(unhealthy || convergedToCommitted,
                      "unfetchable committed block must fail closed (markChainUnhealthy) or converge to the committed tip — got height \(recoveredHeight), unhealthy=\(unhealthy)")
        if recoveredHeight != committedHeight {
            XCTAssertTrue(unhealthy,
                          "a recovery that could not reach the committed tip must be marked unhealthy, never a silent healthy stale-height boot")
        }
    }
}
