import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import UInt256

final class SubscriptionFrameBudgetTests: XCTestCase {
    private func chainSpec(directory: String, maxBlockSize: Int) -> ChainSpec {
        // `directory` is retained on this helper for readability/call-site clarity, but
        // it no longer lives on ChainSpec; deploys pass it positionally below.
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: maxBlockSize,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            retargetWindow: 100
        )
    }

    private func genesisBlock(spec: ChainSpec) async throws -> Block {
        try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: cas()
        )
    }

    private func withNode(
        maxFrameSize: UInt32 = IvyConfig.defaultMaxFrameSize,
        _ body: (LatticeNode) async throws -> Void
    ) async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false,
            maxFrameSize: maxFrameSize, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        do {
            try await body(node)
            await node.stop()
        } catch {
            await node.stop()
            throw error
        }
    }

    func testSubscriptionBudgetAllowsDeclaredBlockSizeAtUsableFrameBudget() async throws {
        let budget = LatticeNode.maxSubscribableBlockSize(maxFrameSize: IvyConfig.defaultMaxFrameSize)
        XCTAssertEqual(
            LatticeNode.requiredSubscriptionFrameSize(maxBlockSize: Int(budget)),
            UInt64(IvyConfig.defaultMaxFrameSize)
        )

        try await withNode { node in
            let spec = chainSpec(directory: "AtBudget", maxBlockSize: Int(budget))
            let genesis = try await genesisBlock(spec: spec)

            try await node.deployChildChain(directory: "AtBudget", genesisBlock: genesis)

            // Per-process children: deploy validates the frame budget and
            // records child metadata on the parent; it does NOT register a
            // parent-side network or subscription (child processes own those).
            let deployed = await node.deployedChildChains.values
                .contains { $0.chainPath == ["Nexus", "AtBudget"] }
            XCTAssertTrue(deployed, "deploy at exactly the usable budget must be accepted")
        }
    }

    func testSubscriptionBudgetRejectsDeclaredBlockSizeOneByteOverUsableBudget() async throws {
        let budget = LatticeNode.maxSubscribableBlockSize(maxFrameSize: IvyConfig.defaultMaxFrameSize)

        try await withNode { node in
            let spec = chainSpec(directory: "OverBudget", maxBlockSize: Int(budget + 1))
            let genesis = try await genesisBlock(spec: spec)

            do {
                try await node.deployChildChain(directory: "OverBudget", genesisBlock: genesis)
                XCTFail("Expected oversized chain spec to be rejected")
            } catch let error as NodeError {
                guard case .chainSpecExceedsFrameLimit(let chainPath, let maxBlockSize, let required, let configured) = error else {
                    return XCTFail("Unexpected NodeError: \(error)")
                }
                XCTAssertEqual(chainPath, ["Nexus", "OverBudget"])
                XCTAssertEqual(maxBlockSize, Int(budget + 1))
                XCTAssertEqual(required, UInt64(IvyConfig.defaultMaxFrameSize) + 1)
                XCTAssertEqual(configured, IvyConfig.defaultMaxFrameSize)
            }

            let network = await node.network(forPath: ["Nexus", "OverBudget"])
            XCTAssertNil(network)
        }
    }

    func testRaisedFrameBudgetAllowsLargerChainSubscription() async throws {
        let defaultBudget = LatticeNode.maxSubscribableBlockSize(maxFrameSize: IvyConfig.defaultMaxFrameSize)
        let largerMaxBlockSize = defaultBudget + 1
        let raisedFrameSize = UInt32(LatticeNode.requiredSubscriptionFrameSize(maxBlockSize: Int(largerMaxBlockSize)))

        try await withNode(maxFrameSize: raisedFrameSize) { node in
            let spec = chainSpec(directory: "RaisedBudget", maxBlockSize: Int(largerMaxBlockSize))
            let genesis = try await genesisBlock(spec: spec)

            try await node.deployChildChain(directory: "RaisedBudget", genesisBlock: genesis)

            // Per-process children: see the at-budget test above.
            let deployed = await node.deployedChildChains.values
                .contains { $0.chainPath == ["Nexus", "RaisedBudget"] }
            XCTAssertTrue(deployed, "deploy within the raised frame budget must be accepted")
        }
    }
}
