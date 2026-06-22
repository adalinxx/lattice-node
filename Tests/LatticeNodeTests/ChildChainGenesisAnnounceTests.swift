import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew

/// Child-chain creation/discovery wiring: a deployed child chain must be
/// announced into a parent (Nexus) block via a `GenesisAction(directory,
/// blockCID)`, embedded in the authorization-free coinbase, so peers discover
/// the child by reading the parent's committed `genesisState`.
///
/// The action carries ONLY `{directory, blockCID}` — an opaque anchor. The
/// parent never resolves or validates the child's genesis content
/// (verify-not-trust), and never creates a parent-side child ChainState
/// (children run as separate node processes — see
/// `RecoveryLifecycleTests.testRestoredChildDeployMetadataDoesNotCreateParentSideChildState`).
final class ChildChainGenesisAnnounceTests: XCTestCase {

    /// Read the directory→genesisCID entries committed to a chain tip's
    /// `genesisState` merkle dictionary, resolving over the chain's content.
    private func committedGenesis(
        node: LatticeNode,
        directory: String
    ) async throws -> [String: String] {
        guard let chain = await node.chain(for: directory),
              let network = await node.network(for: directory) else {
            return [:]
        }
        let tipHash = await chain.getMainChainTip()
        guard !tipHash.isEmpty else { return [:] }
        let source = await node.buildMempoolAwareSource(directory: directory, baseFetcher: network.ivyFetcher)
        let stub = VolumeImpl<Block>(rawCID: tipHash, node: nil, encryptionInfo: nil)
        guard let tipBlock = try await stub.resolve(source: source).node,
              let stateNode = try await tipBlock.postState.resolve(source: source).node,
              let genesisDict = try await stateNode.genesisState.resolveRecursive(source: source).node else {
            return [:]
        }
        return try genesisDict.allKeysAndValues()
    }

    func testDeployedChildIsAnnouncedIntoParentBlockGenesisState() async throws {
        let payoutKP = CryptoUtils.generateKeyPair()
        let coinbaseAddress = CryptoUtils.createAddress(from: payoutKP.publicKey)

        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(), storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0, coinbaseAddress: coinbaseAddress
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        addTeardownBlock { [node] in
            await node.stop()
            try? FileManager.default.removeItem(at: tmp)
        }

        let nexusDir = await node.genesisConfig.directory

        // Before deploying any child, the nexus genesisState is empty.
        let preDeploy = try await committedGenesis(node: node, directory: nexusDir)
        XCTAssertTrue(preDeploy.isEmpty, "no children announced before deploy")

        // Deploy a child. This stores+pins its genesis under the parent and records
        // deploy metadata, but (by design) does NOT announce it into a parent block.
        let nexusNet = await node.network(for: nexusDir)!
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Child"),
            transactions: [],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: nexusNet.ivyFetcher
        )
        try await node.deployChildChain(
            directory: "Child",
            parentDirectory: nexusDir,
            genesisBlock: childGenesis,
            bootstrapEntries: []
        )
        let childGenesisCID = try VolumeImpl<Block>(node: childGenesis).rawCID

        // Deploy alone must not have announced the child yet.
        let afterDeploy = try await committedGenesis(node: node, directory: nexusDir)
        XCTAssertTrue(afterDeploy.isEmpty, "deploy alone must not commit a GenesisAction")

        // Produce a parent (Nexus) block. Its coinbase must carry the child's
        // GenesisAction, which commits {Child → childGenesisCID} into genesisState.
        try await mineBlocks(1, on: node)

        let announced = try await committedGenesis(node: node, directory: nexusDir)
        XCTAssertEqual(announced["Child"], childGenesisCID,
                       "the parent block must anchor the child's genesis CID in genesisState (discovery)")
        XCTAssertEqual(announced.count, 1, "exactly the one deployed child is announced")

        // Idempotency: producing another block must NOT re-announce the child (it is
        // already in genesisState). A second GenesisAction for the same directory
        // would be rejected by the genesis-state transform as conflictingActions, so
        // a successful block here also proves the dedup fired.
        try await mineBlocks(1, on: node)

        let afterSecond = try await committedGenesis(node: node, directory: nexusDir)
        XCTAssertEqual(afterSecond["Child"], childGenesisCID, "anchor persists")
        XCTAssertEqual(afterSecond.count, 1, "child is announced exactly once across blocks")

        // Discovery/registration contract (design ruling): the anchor makes the
        // child discoverable, but the parent process must NOT spin up a child
        // ChainState/network — child views are owned by child processes.
        let childNetwork = await node.network(for: "Child")
        let childChain = await node.chain(for: "Child")
        XCTAssertNil(childNetwork, "announcing a child must not create a parent-side child network")
        XCTAssertNil(childChain, "announcing a child must not create a parent-side child ChainState")
    }

    /// M1 (TOCTOU): the producer re-resolves the building tip independently of the
    /// caller, so the genesis announce set MUST be derived against the tip the block
    /// actually extends — not a snapshot frozen at the caller's read. If a child's
    /// directory was already committed into the resolved tip's `genesisState`, a
    /// stale `GenesisAction` for it in the coinbase makes the genesis-state transform
    /// reject the block (insertion proof on a present key) and every template build
    /// fails that round. This drives `BlockProducer.produceBlock()` against a tip that
    /// already commits the child and asserts: (a) the produced coinbase carries NO
    /// stale action, and (b) the block still seals (no collision throw).
    func testProducerDerivesGenesisActionsAgainstResolvedTipNotSnapshot() async throws {
        let payoutKP = CryptoUtils.generateKeyPair()
        let coinbaseAddress = CryptoUtils.createAddress(from: payoutKP.publicKey)

        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(), storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0, coinbaseAddress: coinbaseAddress
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        addTeardownBlock { [node] in
            await node.stop()
            try? FileManager.default.removeItem(at: tmp)
        }

        let nexusDir = await node.genesisConfig.directory
        let nexusNet = await node.network(for: nexusDir)!

        // Deploy + announce a child so its directory lands in the nexus tip's
        // committed genesisState.
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Child"),
            transactions: [],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: nexusNet.ivyFetcher
        )
        try await node.deployChildChain(
            directory: "Child",
            parentDirectory: nexusDir,
            genesisBlock: childGenesis,
            bootstrapEntries: []
        )
        let childGenesisCID = try VolumeImpl<Block>(node: childGenesis).rawCID
        try await mineBlocks(1, on: node)

        // The child is now committed in the tip.
        let committed = try await committedGenesis(node: node, directory: nexusDir)
        XCTAssertEqual(committed["Child"], childGenesisCID, "child committed into tip genesisState")

        let chainState = await node.chain(for: nexusDir)!
        let nexusSpec = await node.genesisConfig.spec
        let nexusAuthority = await node.coinbaseAuthority
        let nexusFetcher = await nexusNet.ivyFetcher
        let nexusMempool = await nexusNet.nodeMempool
        let resolvedTipHash = await chainState.getMainChainTip()
        let resolvedTip = try await VolumeImpl<Block>(rawCID: resolvedTipHash, node: nil, encryptionInfo: nil)
            .resolve(fetcher: nexusFetcher).node!

        // Control: a STALE GenesisAction for the already-committed child (the frozen
        // snapshot the old caller would have carried) DOES collide — building a block
        // whose coinbase re-announces a present directory throws. This is the failure
        // the fix prevents; the producer run below must avoid it by re-deriving.
        let staleCoinbaseTx = try await BlockProducer.buildCoinbaseTransaction(
            spec: nexusSpec,
            identity: nexusAuthority,
            chainPath: [nexusDir],
            previousBlock: resolvedTip,
            mempoolTransactions: [],
            fetcher: nexusNet.ivyFetcher,
            recipientAddress: coinbaseAddress,
            genesisActions: [GenesisAction(directory: "Child", blockCID: childGenesisCID)]
        )
        let staleCoinbase = try XCTUnwrap(staleCoinbaseTx)
        do {
            _ = try await BlockBuilder.buildBlock(
                previous: resolvedTip,
                transactions: [staleCoinbase],
                timestamp: resolvedTip.timestamp + 1,
                target: UInt256.max,
                nextTarget: UInt256.max,
                nonce: 0,
                fetcher: nexusNet.ivyFetcher
            )
            XCTFail("re-announcing a directory already in genesisState must collide")
        } catch {
            // expected: insertion proof on a present key
        }

        // Drive the producer with the SAME provider wiring production uses: re-derive
        // the announce set against the resolved `previousBlock`. Against this tip the
        // child is already committed, so the set is empty and no collision occurs.
        let producer = BlockProducer(
            chainState: chainState,
            mempool: nexusMempool,
            fetcher: nexusFetcher,
            spec: nexusSpec,
            chainPath: [nexusDir],
            identity: nexusAuthority,
            coinbaseRecipientAddress: coinbaseAddress,
            timestampOverride: now(),
            genesisActionsProvider: { [weak node] previousBlock in
                guard let node else { return [] }
                let source = await node.buildMempoolAwareSource(directory: nexusDir, baseFetcher: nexusFetcher)
                return await node.pendingChildGenesisActions(
                    parentChainPath: [nexusDir], tipBlock: previousBlock, source: source
                )
            }
        )

        var produced: ProducedMinedBlock? = nil
        let deadline = Date().addingTimeInterval(10)
        while produced == nil && Date() < deadline {
            // No throw here is itself the assertion: with the frozen-snapshot bug the
            // stale GenesisAction would make every template build fail and produceBlock
            // would throw.
            produced = try await producer.produceBlock()
        }
        let block = try XCTUnwrap(produced?.block, "producer must seal a block extending the child-committed tip")
        XCTAssertEqual(block.parent?.rawCID, resolvedTipHash, "block extends the resolved tip")

        // (a) No stale GenesisAction for the already-committed child.
        let txDict = try await block.transactions.resolve(fetcher: nexusFetcher).node!
        var carriesStaleChild = false
        for (_, txVolume) in try txDict.allKeysAndValues() {
            guard let tx = try? await txVolume.resolve(fetcher: nexusFetcher).node,
                  let actions = tx.body.node?.genesisActions else { continue }
            if actions.contains(where: { $0.directory == "Child" }) { carriesStaleChild = true }
        }
        XCTAssertFalse(
            carriesStaleChild,
            "coinbase must not carry a GenesisAction for a directory already in the resolved tip's genesisState"
        )
    }
}
