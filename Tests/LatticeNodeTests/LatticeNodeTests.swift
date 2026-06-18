import XCTest
import Lattice
@testable import LatticeNode
import Ivy
import UInt256
import cashew
import VolumeBroker
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 1)
    }
}

private struct StoredDataFetcher: Fetcher {
    let dataByCID: [String: Data]

    func fetch(rawCid: String) async throws -> Data {
        guard let data = dataByCID[rawCid] else {
            throw NSError(domain: "StoredDataFetcher", code: 1)
        }
        return data
    }
}

final class LatticeNodeTests: XCTestCase {
    // MARK: - NexusGenesis boots correctly

    func testNexusGenesisSpecIsValid() {
        XCTAssertTrue(NexusGenesis.spec.isValid)
        XCTAssertEqual(NexusGenesis.config.directory, "Nexus")
    }

    func testNexusGenesisCreatesBlock() async throws {
        let result = try await NexusGenesis.create(fetcher: TestFetcher())
        XCTAssertFalse(result.blockHash.isEmpty)
        XCTAssertNotNil(result.chainState)
    }


    func testNexusGenesisBlockIsDeterministic() async throws {
        let r1 = try await NexusGenesis.create(fetcher: TestFetcher())
        let r2 = try await NexusGenesis.create(fetcher: TestFetcher())
        XCTAssertEqual(r1.blockHash, r2.blockHash)
    }

    // MARK: - ChainLevel hierarchy for multi-chain

    func testChainLevelStartsWithNoChildren() async throws {
        let genesis = try await NexusGenesis.create(fetcher: TestFetcher())
        let level = ChainLevel(chain: genesis.chainState, children: [:])
        let dirs = await level.childDirectories()
        XCTAssertTrue(dirs.isEmpty)
    }

    func testRegisterChildChain() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])

        let childSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 0, target: UInt256(1000), fetcher: fetcher
        )
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        await level.restoreChildChain(directory: "Payments", level: childLevel)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs, ["Payments"])
    }

    func testRestoreChildChain() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])

        let childSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 0, target: UInt256(1000), fetcher: fetcher
        )
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])

        await level.restoreChildChain(directory: "Data", level: childLevel)
        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs, ["Data"])
    }

    func testDuplicateRegisterIgnored() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])

        let childSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let g = try await BlockBuilder.buildGenesis(spec: childSpec, timestamp: 0, target: UInt256(1000), fetcher: fetcher)
        let xChain = ChainState.fromGenesis(block: g, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let xLevel = ChainLevel(chain: xChain, children: [:])
        await level.restoreChildChain(directory: "X", level: xLevel)
        await level.restoreChildChain(directory: "X", level: xLevel)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs.count, 1)
    }

    // MARK: - Lattice actor processes blocks

    func testLatticeProcessesNexusBlock() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])
        let lattice = Lattice(nexus: level)

        let height = await lattice.nexus.chain.getHighestBlockHeight()
        XCTAssertEqual(height, 0)
    }

    func testChainAddressNormalizesPathIdentity() {
        let address = ChainAddress(["Nexus", "A", "Payments"])
        XCTAssertEqual(address?.root, "Nexus")
        XCTAssertEqual(address?.edgeLabel, "Payments")
        XCTAssertEqual(address?.key, "Nexus/A/Payments")
        XCTAssertNil(ChainAddress([]))
        XCTAssertNil(ChainAddress(["Nexus", ""]))
    }

    func testRPCChainSelectorsDefaultToPerProcessChainPath() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let nodeConfig = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false,
            fullChainPath: ["Nexus", "Child"], minPeerKeyBits: 0
        )
        let node = try await LatticeNode(
            config: nodeConfig,
            genesisConfig: testGenesis(spec: testSpec(), directory: "Child")
        )
        try await node.start()

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        defer {
            rpcTask.cancel()
            Task { await node.stop() }
        }
        try await waitForRPCServer(port: rpcPort)

        let base = "http://127.0.0.1:\(rpcPort)/api"
        func status(_ path: String) async throws -> Int {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "\(base)\(path)")!)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        let omittedStatus = try await status("/peers")
        XCTAssertEqual(omittedStatus, 200,
            "Omitted chainPath must resolve to the queried child process path Nexus/Child")
    }

    func testChainTemplateHonorsBodyChainPathSelector() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let nodeConfig = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: nodeConfig, genesisConfig: testGenesis())
        try await node.start()

        let rpcPort = nextTestPort()
        // chain/template is an admin endpoint and requires a cookie credential.
        let (server, adminToken) = try makeAdminRPCServer(node: node, port: rpcPort)
        let rpcTask = Task { try await server.run() }
        defer {
            rpcTask.cancel()
            Task { await node.stop() }
        }
        try await waitForRPCServer(port: rpcPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/template")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "chainPath": ["Nexus", "Missing"]
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            404,
            "Body chainPath must select the requested path instead of silently falling back to the current chain"
        )
    }

    // MARK: - Chain state persistence roundtrip

    func testPersistAndRestoreChainState() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = try ChainState.restore(from: decoded)

        let originalTip = await chain.getMainChainTip()
        let restoredTip = await restored.getMainChainTip()
        XCTAssertEqual(originalTip, restoredTip)

        let restoredHeight = await restored.getHighestBlockHeight()
        XCTAssertEqual(restoredHeight, 1)
    }

    func testRestoredChainAcceptsNewBlocks() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        let restored = try ChainState.restore(from: persisted)

        let b2 = try await BlockBuilder.buildBlock(
            previous: b1, timestamp: t + 2000,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let result = await restored.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: b2), block: b2
        )
        XCTAssertTrue(result.extendsMainChain)
        let height = await restored.getHighestBlockHeight()
        XCTAssertEqual(height, 2)
    }

    // MARK: - Miner lifecycle

    // MARK: - Multi-chain block building

    func testBuildBlockWithChildBlocks() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let nexusSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let childSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, target: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, target: UInt256(1000), fetcher: fetcher
        )

        let block = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            children: ["Child": childGenesis],
            timestamp: t + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let header = try VolumeImpl<Block>(node: block)
        XCTAssertFalse(header.rawCID.isEmpty)
    }

    func testBlockResolveRejectsBytesStoredUnderWrongCID() async throws {
        let fetcher = TestFetcher()
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        let blockA = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000, target: UInt256(1000), fetcher: fetcher
        )
        let blockB = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 2_000, target: UInt256(1000), fetcher: fetcher
        )
        let cidA = try VolumeImpl<Block>(node: blockA).rawCID
        let cidB = try VolumeImpl<Block>(node: blockB).rawCID

        XCTAssertNotEqual(cidA, cidB)

        let mismatchedFetcher = StoredDataFetcher(dataByCID: [cidA: blockB.toData()!])
        do {
            _ = try await VolumeImpl<Block>(rawCID: cidA).resolve(fetcher: mismatchedFetcher)
            XCTFail("Resolving CID A with block B bytes must fail")
        } catch DataErrors.cidMismatch {
            // Expected: Cashew enforces content addressing before Lattice sees the block.
        }
    }

    func testPersistedChainStateRequiresResolvableTipFrontier() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let disk = try DiskBroker(path: tmpDir.appendingPathComponent("volumes.sqlite").path)
        let fetcher = cas()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256(1000),
            fetcher: fetcher
        )
        let tipCID = try VolumeImpl<Block>(node: genesis).rawCID
        let persisted = PersistedChainState(
            chainTip: tipCID,
            tipPostStateCID: genesis.postState.rawCID,
            tipPrevStateCID: genesis.prevState.rawCID,
            tipSpecCID: genesis.spec.rawCID,
            tipTarget: genesis.target.toHexString(),
            tipNextTarget: genesis.nextTarget.toHexString(),
            tipHeight: genesis.height,
            tipTimestamp: genesis.timestamp,
            mainChainHashes: [tipCID],
            blocks: [PersistedBlockMeta(
                blockHash: tipCID,
                parentBlockHash: nil,
                blockHeight: genesis.height,
                parentChainBlocks: [:],
                childHashes: [],
                target: genesis.target.toHexString(),
                timestamp: genesis.timestamp
            )],
            parentChainMap: [:],
            missingBlockHashes: []
        )

        try await disk.storeVolumeLocal(SerializedVolume(root: tipCID, entries: [tipCID: genesis.toData()!]))
        let missingFrontierIsUsable = await LatticeNode.isPersistedChainStateUsable(persisted, diskBroker: disk)
        XCTAssertFalse(
            missingFrontierIsUsable,
            "startup must reject a cached tip whose frontier roots are missing from CAS"
        )

        let storer = BrokerStorer(broker: disk)
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        try await storer.flush(root: tipCID)

        let completeFrontierIsUsable = await LatticeNode.isPersistedChainStateUsable(persisted, diskBroker: disk)
        XCTAssertTrue(
            completeFrontierIsUsable,
            "a recursively stored tip should be usable for startup"
        )
    }
}
