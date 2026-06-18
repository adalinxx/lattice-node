import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker

// Helpers in TestHelpers.swift: cas(), testSpec(), sign(), addr(), now()
private func fetcher() -> TestBrokerFetcher { cas() }

private func deepCopyCID(_ cid: String, from source: TestBrokerFetcher, to dest: TestBrokerFetcher, visited: inout Set<String>) async {
    guard !cid.isEmpty, !visited.contains(cid) else { return }
    visited.insert(cid)
    guard let data = try? await source.fetch(rawCid: cid) else { return }
    await dest.store(rawCid: cid, data: data)

    if let block = Block(data: data) {
        if let prevCID = block.parent?.rawCID {
            await deepCopyCID(prevCID, from: source, to: dest, visited: &visited)
        }
        await deepCopyCID(block.transactions.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.spec.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.prevState.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.postState.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.parentState.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.children.rawCID, from: source, to: dest, visited: &visited)
    }
}

// ============================================================================
// MARK: - Smoke Tests: Node boots, mines, persists
// ============================================================================

final class SmokeTests: XCTestCase {

    func testNexusGenesisBootAndChainState() async throws {
        let f = fetcher()
        let result = try await NexusGenesis.create(fetcher: f)
        XCTAssertFalse(result.blockHash.isEmpty)
        let height = await result.chainState.getHighestBlockHeight()
        XCTAssertEqual(height, 0)
        let tip = await result.chainState.getMainChainTip()
        XCTAssertEqual(tip, result.blockHash)
    }

    func testMineBlocksAndAdvanceChain() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var prev = genesis
        for i in 1...10 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = try VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            prev = block
        }

        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 10)
    }

    func testMinerProducesCoinbaseTransaction() async throws {
        let f = fetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        // Trivial target so the on-demand producer seals immediately —
        // produceBlock() searches until it finds a valid nonce.
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256.max, fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let mempool = NodeMempool(maxSize: 100)

        // Store the full genesis sub-volume tree (not just the block) so the
        // coinbase builder can resolve the miner's account frontier — with
        // premine 0 the miner isn't in the trie, so it resolves from the fetcher.
        let genesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)

        let miner = BlockProducer(
            chainState: chain, mempool: mempool, fetcher: f,
            spec: spec, chainPath: [DEFAULT_ROOT_DIRECTORY], identity: identity
        )

        // Produce one block on demand and verify it carries a coinbase tx.
        var produced: ProducedMinedBlock? = nil
        let deadline = Date().addingTimeInterval(10)
        while produced == nil && Date() < deadline {
            produced = try await miner.produceBlock()
        }
        let block = try XCTUnwrap(produced?.block, "producer should mine a block")
        XCTAssertEqual(block.height, 1)
        XCTAssertGreaterThanOrEqual(block.transactions.node?.count ?? 0, 1, "block should include a coinbase")
    }

    func testChainStatePersistAndRestore() async throws {
        let f = fetcher()
        let t = now() - 30_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var prev = genesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block), block: block
            )
            prev = block
        }

        let persisted = await chain.persist()
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = try ChainState.restore(from: decoded)

        let origTip = await chain.getMainChainTip()
        let resTip = await restored.getMainChainTip()
        XCTAssertEqual(origTip, resTip)

        let block6 = try await BlockBuilder.buildBlock(
            previous: prev, timestamp: t + 6000,
            target: UInt256(1000), nonce: 6, fetcher: f
        )
        let result = await restored.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: block6), block: block6
        )
        XCTAssertTrue(result.extendsMainChain)
        let rh = await restored.getHighestBlockHeight()
        XCTAssertEqual(rh, 6)
    }

    func testPersistToDiskAndReload() async throws {
        let f = fetcher()
        let t = now() - 20_000
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persister = ChainStatePersister(storagePath: tmpDir, directory: "Nexus")
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        try await persister.save(persisted)

        let loaded = try await persister.load()
        XCTAssertNotNil(loaded)
        let restored = try ChainState.restore(from: loaded!)
        let resTip = await restored.getMainChainTip()
        let origTip = await chain.getMainChainTip()
        XCTAssertEqual(resTip, origTip)
    }
}

// ============================================================================
// MARK: - Multi-Chain End-to-End: Nexus + Child chains
// ============================================================================

final class MultiChainEndToEndTests: XCTestCase {

    func testNexusWithChildChainHierarchy() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let dirs = await nexusLevel.childDirectories()
        XCTAssertEqual(dirs, ["Payments"])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            children: ["Payments": childGenesis],
            timestamp: t + 1000, target: UInt256(1000), nonce: 1, fetcher: f
        )
        let result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        XCTAssertTrue(result.extendsMainChain)
        let nh = await nexusChain.getHighestBlockHeight()
        XCTAssertEqual(nh, 1)
    }

    // In-process merged mining (ChildMiningContext / childContexts on the
    // producer) was removed: each chain runs as its own node process and child
    // candidates flow over the registered template RPC routes. Cross-chain
    // coverage lives in SmokeTests.
}

// ============================================================================
// MARK: - Mempool End-to-End
// ============================================================================

final class MempoolEndToEndTests: XCTestCase {

    func testTransactionAddedAndSelected() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = NodeMempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 50, nonce: 0
        )
        let tx = sign(body, kp)
        let added = await mempool.add(transaction: tx)
        XCTAssertTrue(added)

        let count = await mempool.count
        XCTAssertEqual(count, 1)

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 1)
    }

    func testMempoolRejectsDuplicates() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = NodeMempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let tx = sign(body, kp)
        let first = await mempool.add(transaction: tx)
        let second = await mempool.add(transaction: tx)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testMempoolSelectsHighestFeeFirst() async {
        let mempool = NodeMempool(maxSize: 100)

        // Distinct senders — otherwise nonce-ordering within a single account
        // forces ascending-nonce selection, which can conflict with fee order.
        for i: UInt64 in 0..<5 {
            let kp = CryptoUtils.generateKeyPair()
            let kpAddr = addr(kp.publicKey)
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], fee: i * 10, nonce: 0
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }

        let selected = await mempool.selectTransactions(maxCount: 3)
        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertEqual(fees, fees.sorted(by: >))
    }

    func testMempoolPrunesConfirmedTransactions() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = NodeMempool(maxSize: 100)

        var cids: [String] = []
        for i: UInt64 in 0..<3 {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], fee: 10, nonce: i
            )
            let tx = sign(body, kp)
            let _ = await mempool.add(transaction: tx)
            cids.append(tx.body.rawCID)
        }

        let mc3 = await mempool.count
        XCTAssertEqual(mc3, 3)

        await mempool.removeAll(txCIDs: Set([cids[0], cids[1]]))
        let mc1 = await mempool.count
        XCTAssertEqual(mc1, 1)
    }

    func testMempoolRejectsInvalidSignature() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let mempool = NodeMempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["fake"], fee: 10, nonce: 0
        )
        let tx = Transaction(signatures: [kp.publicKey: "deadbeef"], body: try HeaderImpl<TransactionBody>(node: body))

        let added = await mempool.add(transaction: tx)
        XCTAssertTrue(added, "NodeMempool accepts all txs; signature validation is in TransactionValidator")
    }

    func testMempoolPerChainIsolation() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusMempool = NodeMempool(maxSize: 100)
        let childMempool = NodeMempool(maxSize: 100)

        let nexusBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let childBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 20, nonce: 0
        )

        let _ = await nexusMempool.add(transaction: sign(nexusBody, kp))
        let _ = await childMempool.add(transaction: sign(childBody, kp))

        let nmc = await nexusMempool.count
        XCTAssertEqual(nmc, 1)
        let cmc = await childMempool.count
        XCTAssertEqual(cmc, 1)

        let nexusTxs = await nexusMempool.selectTransactions(maxCount: 10)
        let childTxs = await childMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(nexusTxs.first?.body.node?.fee, 10)
        XCTAssertEqual(childTxs.first?.body.node?.fee, 20)
    }
}

// ============================================================================
// MARK: - Two-Node Convergence
// ============================================================================

final class TwoNodeEndToEndTests: XCTestCase {

    func testTwoNodesConvergeFromSameGenesis() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let spec = testSpec()
        let config = GenesisConfig.standard(spec: spec)

        let genesisA = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let genesisB = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)
        XCTAssertEqual(genesisA.blockHash, genesisB.blockHash)

        let fA = fetcher()
        let fB = fetcher()
        await fA.store(rawCid: genesisA.blockHash, data: genesisA.block.toData()!)
        await fB.store(rawCid: genesisB.blockHash, data: genesisB.block.toData()!)

        var prev = genesisA.block
        var blocks: [Block] = []
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fA
            )
            await fA.store(rawCid: try VolumeImpl<Block>(node: block).rawCID, data: block.toData()!)
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block), block: block
            )
            blocks.append(block)
            prev = block
        }

        for block in blocks {
            let header = try VolumeImpl<Block>(node: block)
            await fB.store(rawCid: header.rawCID, data: block.toData()!)
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
        }

        let tipA = await genesisA.chainState.getMainChainTip()
        let tipB = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB)
        let ah5 = await genesisA.chainState.getHighestBlockHeight()
        XCTAssertEqual(ah5, 5)
        let bh5 = await genesisB.chainState.getHighestBlockHeight()
        XCTAssertEqual(bh5, 5)
    }

    func testNodeConvergesAfterReceivingLongerFork() async throws {
        let f = fetcher()
        let t = now() - 100_000
        let spec = testSpec()
        let config = GenesisConfig.standard(spec: spec)

        let genesisA = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let genesisB = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var shortPrev = genesisB.block
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: shortPrev, timestamp: t + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 100), fetcher: f
            )
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: b), block: b
            )
            shortPrev = b
        }
        let bh3 = await genesisB.chainState.getHighestBlockHeight()
        XCTAssertEqual(bh3, 3)

        var longPrev = genesisA.block
        var longBlocks: [Block] = []
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: longPrev, timestamp: t + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: b), block: b
            )
            longBlocks.append(b)
            longPrev = b
        }

        for block in longBlocks {
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block), block: block
            )
        }

        let tipA = await genesisA.chainState.getMainChainTip()
        let tipB = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Node B should reorg to longer chain")
        let bh5 = await genesisB.chainState.getHighestBlockHeight()
        XCTAssertEqual(bh5, 5)
    }
}

// ============================================================================
// MARK: - Multi-Chain Content Storage
// ============================================================================

final class MultiChainReceptionTests: XCTestCase {

    func testBufferedStorerFlushesAllData() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        let header = try VolumeImpl<Block>(node: genesis)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        XCTAssertGreaterThan(storer.entries.count, 1)

        let freshFetcher = fetcher()
        await storer.flush(to: freshFetcher)

        let fetched = try await freshFetcher.fetch(rawCid: header.rawCID)
        XCTAssertEqual(fetched, genesis.toData()!)

        let specData = try await freshFetcher.fetch(rawCid: genesis.spec.rawCID)
        XCTAssertNotNil(ChainSpec(data: specData))
    }
}

// ============================================================================
// MARK: - Block Storage via Acorn CAS
// ============================================================================

final class AcornStorageTests: XCTestCase {

    func testBlockStoreAndRetrieve() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        let header = try VolumeImpl<Block>(node: genesis)
        let blockData = genesis.toData()!

        await f.store(rawCid: header.rawCID, data: blockData)

        let fetched = try await f.fetch(rawCid: header.rawCID)
        XCTAssertEqual(fetched, blockData)
    }

    func testBlockSerializeDeserializeRoundtrip() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        let data = genesis.toData()!
        let restored = Block(data: data)
        XCTAssertNotNil(restored)

        let originalCID = try VolumeImpl<Block>(node: genesis).rawCID
        let restoredCID = try VolumeImpl<Block>(node: restored!).rawCID
        XCTAssertEqual(originalCID, restoredCID)
    }

    func testFetchMissingBlockThrows() async {
        let f = fetcher()
        do {
            let _ = try await f.fetch(rawCid: "nonexistent-cid")
            XCTFail("Should throw for missing CID")
        } catch {
            // expected
        }
    }

    func testMultiBlockStoreAndRetrieve() async throws {
        let f = fetcher()
        let t = now() - 30_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        var prev = genesis
        var cids: [String] = []
        for i in 0...5 {
            let block = i == 0 ? genesis : try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = try VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            cids.append(header.rawCID)
            prev = block
        }

        for cid in cids {
            let data = try await f.fetch(rawCid: cid)
            let block = Block(data: data)
            XCTAssertNotNil(block)
        }
    }
}

// ============================================================================
// MARK: - Multi-Chain Deep Integration Tests
// ============================================================================

private struct MultiChainEnv {
    let f: TestBrokerFetcher
    let t: Int64
    let nexusSpec: ChainSpec
    let childSpec: ChainSpec
    let nexusGenesis: Block
    let childGenesis: Block
    let nexusChain: ChainState
    let childChain: ChainState
    let nexusLevel: ChainLevel
    let kp: (privateKey: String, publicKey: String)
    let kpAddr: String

    static func create(childDir: String = "Payments", premine: UInt64 = 1000) async throws -> MultiChainEnv {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec(childDir, premine: premine)
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(childSpec.premineAmount()))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(premineBody, kp)],
            timestamp: t, target: UInt256(1000), fetcher: f
        )

        let nexusStorer = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: nexusStorer)
        await nexusStorer.flush(to: f)
        let childStorer = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: childStorer)
        await childStorer.flush(to: f)

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: [childDir: childLevel])

        return MultiChainEnv(
            f: f, t: t, nexusSpec: nexusSpec, childSpec: childSpec,
            nexusGenesis: nexusGenesis, childGenesis: childGenesis,
            nexusChain: nexusChain, childChain: childChain, nexusLevel: nexusLevel,
            kp: kp, kpAddr: kpAddr
        )
    }

    func buildNexusBlock(
        previous: Block, children: [String: Block] = [:],
        offset: Int64 = 1000, nonce: UInt64 = 1
    ) async throws -> Block {
        try await BlockBuilder.buildBlock(
            previous: previous, children: children,
            timestamp: previous.timestamp + offset,
            target: UInt256(1000), nonce: nonce, fetcher: f
        )
    }

    func submitNexus(_ block: Block) async -> SubmissionResult {
        await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            // known-valid local node; CID cannot fail
            blockHeader: try! VolumeImpl<Block>(node: block), block: block
        )
    }
}

final class MultiChainPersistenceTests: XCTestCase {

    func testMultipleChildChainsPersistIndependently() async throws {
        let f = fetcher()
        let t = now() - 10_000
        // Directory is positional now and is NOT part of ChainSpec, so chains with
        // identical specs produce identical genesis CIDs (they are distinguished by
        // their anchor/path, not the genesis blob). Give each chain genuinely distinct
        // content (premine) so these are three different chains with distinct geneses.
        let nexusSpec = testSpec("Nexus", premine: 0)
        let childASpec = testSpec("Payments", premine: 1)
        let childBSpec = testSpec("Identity", premine: 2)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let childAGenesis = try await BlockBuilder.buildGenesis(
            spec: childASpec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let childBGenesis = try await BlockBuilder.buildGenesis(
            spec: childBSpec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainA = ChainState.fromGenesis(block: childAGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainB = ChainState.fromGenesis(block: childBGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let persistedA = await chainA.persist()
        let persistedB = await chainB.persist()

        let restoredA = try ChainState.restore(from: persistedA)
        let restoredB = try ChainState.restore(from: persistedB)

        let tipA = await restoredA.getMainChainTip()
        let tipB = await restoredB.getMainChainTip()
        XCTAssertNotEqual(tipA, tipB)

        let nexusTip = await nexusChain.getMainChainTip()
        XCTAssertNotEqual(nexusTip, tipA)
        XCTAssertNotEqual(nexusTip, tipB)
    }
}

final class MultiChainBalanceAndStateTests: XCTestCase {

    func testChildChainHasValidTipSnapshot() async throws {
        let env = try await MultiChainEnv.create()
        let snapshot = await env.childChain.tipSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.tipHeight, 0)
        XCTAssertFalse(snapshot!.postStateCID.isEmpty)
        XCTAssertFalse(snapshot!.specCID.isEmpty)
    }

    func testChildChainTransactionAdvancesChain() async throws {
        let env = try await MultiChainEnv.create()
        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = addr(receiver.publicKey)
        let premineAmount = env.childSpec.premineAmount()

        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: env.kpAddr, delta: Int64(premineAmount - 500) - Int64(premineAmount)),
                AccountAction(owner: receiverAddr, delta: Int64(500))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [env.kpAddr], fee: 0, nonce: 1
        )
        let tx = sign(transferBody, env.kp)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: env.childGenesis, transactions: [tx],
            timestamp: env.t + 1000, target: UInt256(1000), nonce: 1, fetcher: env.f
        )
        let childResult = await env.childChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: childBlock1), block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let childHeight = await env.childChain.getHighestBlockHeight()
        XCTAssertEqual(childHeight, 1)

        let snapshot = await env.childChain.tipSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.tipHeight, 1)
    }
}

final class MultiChainMiningContextTests: XCTestCase {

    // In-process merged mining (ChildMiningContext / childContexts on the
    // producer) was removed: each chain runs as its own node process and child
    // candidates flow over the registered template RPC routes. Cross-chain
    // coverage lives in SmokeTests.

    func testChildMempoolIsolation() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusMempool = NodeMempool(maxSize: 100)
        let childAMempool = NodeMempool(maxSize: 100)
        let childBMempool = NodeMempool(maxSize: 100)

        for (mempool, fee) in [(nexusMempool, 10 as UInt64), (childAMempool, 20), (childBMempool, 30)] {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], 
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], fee: fee, nonce: 0
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }

        let nc = await nexusMempool.count
        let ac = await childAMempool.count
        let bc = await childBMempool.count
        XCTAssertEqual(nc, 1)
        XCTAssertEqual(ac, 1)
        XCTAssertEqual(bc, 1)

        let nexusTxs = await nexusMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(nexusTxs.first?.body.node?.fee, 10)
        let aTxs = await childAMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(aTxs.first?.body.node?.fee, 20)
        let bTxs = await childBMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(bTxs.first?.body.node?.fee, 30)
    }
}

// ============================================================================
// MARK: - Full Integration: BlockProducer → Lattice → Child Chain Validation
// ============================================================================

/// Drive the producer until it yields a block. Difficulty in these tests is
/// trivial (UInt256.max), so this returns on the first attempt; the loop just
/// guards against a transient empty batch.
private func produceBlockWithRetry(
    _ producer: BlockProducer,
    file: StaticString = #filePath, line: UInt = #line
) async throws -> ProducedMinedBlock {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let produced = try await producer.produceBlock() { return produced }
    }
    XCTFail("producer did not yield a block", file: file, line: line)
    throw XCTestError(.failureWhileWaiting)
}

final class FullMiningIntegrationTests: XCTestCase {

    func testMinerProducesBlockAndChainAdvances() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let spec = testSpec("Nexus")
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256.max, fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let mempool = NodeMempool(maxSize: 100)

        let genesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)

        let miner = BlockProducer(
            chainState: chain, mempool: mempool, fetcher: f,
            spec: spec, chainPath: [DEFAULT_ROOT_DIRECTORY], identity: identity, batchSize: 10_000
        )

        let produced = try await produceBlockWithRetry(miner)
        let minedBlocks: [(Block, String)] = [(produced.block, try VolumeImpl<Block>(node: produced.block).rawCID)]
        XCTAssertGreaterThan(minedBlocks.count, 0, "Miner should produce at least one block")

        for (block, _) in minedBlocks {
            let header = try VolumeImpl<Block>(node: block)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)

            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
        }

        let height = await chain.getHighestBlockHeight()
        XCTAssertGreaterThan(height, 0, "Chain should advance after submitting mined blocks")
    }

    // In-process merged mining (ChildMiningContext / childContexts on the
    // producer) was removed: each chain runs as its own node process and child
    // candidates flow over the registered template RPC routes. Cross-chain
    // coverage lives in SmokeTests.
}

// ============================================================================
// MARK: - CAS Isolation: Separate CAS per chain
// ============================================================================

final class CASIsolationTests: XCTestCase {

    func testDeepCopyBlockBetweenSeparateCAS() async throws {
        let nexusCAS = fetcher()
        let childCAS = fetcher()
        let t = now() - 5_000
        let childSpec = testSpec("Payments", premine: 1000)
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(childSpec.premineAmount()))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(premineBody, kp)],
            timestamp: t, target: UInt256(1000), fetcher: nexusCAS
        )

        let genesisHeader = try VolumeImpl<Block>(node: childGenesis)
        let storer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: storer)
        await storer.flush(to: nexusCAS)

        let genesisCID = genesisHeader.rawCID

        do {
            let _ = try await childCAS.fetch(rawCid: genesisCID)
            XCTFail("Child CAS should not have the block yet")
        } catch {}

        // Deep copy using CID walking (same as production handleChildChainDiscovery)
        var visited = Set<String>()
        await deepCopyCID(genesisCID, from: nexusCAS, to: childCAS, visited: &visited)
        XCTAssertGreaterThan(visited.count, 3, "Should copy block + multiple child CIDs")

        let fetchedData = try await childCAS.fetch(rawCid: genesisCID)
        XCTAssertEqual(fetchedData, childGenesis.toData()!)

        let specData = try await childCAS.fetch(rawCid: childGenesis.spec.rawCID)
        XCTAssertNotNil(ChainSpec(data: specData))

        let frontierData = try await childCAS.fetch(rawCid: childGenesis.postState.rawCID)
        XCTAssertNotNil(frontierData)
    }

    func testMinerCanBuildChildBlockFromSeparateCAS() async throws {
        let nexusCAS = fetcher()
        let childCAS = fetcher()
        let t = now() - 5_000
        let childSpec = testSpec("Payments")

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, target: UInt256(1000), fetcher: nexusCAS
        )
        let genesisHeader = try VolumeImpl<Block>(node: childGenesis)
        let storer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: storer)
        await storer.flush(to: nexusCAS)

        // Deep copy to child CAS
        var visited = Set<String>()
        await deepCopyCID(genesisHeader.rawCID, from: nexusCAS, to: childCAS, visited: &visited)

        // Simulate what BlockProducer.buildChildBlocks does: fetch tip, build new block
        let tipData = try await childCAS.fetch(rawCid: genesisHeader.rawCID)
        let tipBlock = Block(data: tipData)
        XCTAssertNotNil(tipBlock, "Should deserialize child genesis from child CAS")
        XCTAssertEqual(tipBlock!.height, 0)

        // This is the critical call — BlockBuilder needs frontier data from child CAS
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: tipBlock!, timestamp: t + 1000,
            target: UInt256(1000), nonce: 1, fetcher: childCAS
        )
        XCTAssertEqual(childBlock1.height, 1)
        XCTAssertEqual(childBlock1.prevState.rawCID, tipBlock!.postState.rawCID)
    }
}
