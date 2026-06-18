import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import cashew

final class ChainHealthTests: XCTestCase {
    private func makeNode(storagePath: URL) async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        return try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: storagePath,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
    }

    private func makeTransaction(chainPath: [String]) -> Transaction {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [kp.publicKey],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        // known-valid local node; CID cannot fail
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: kp.privateKey)!
        return Transaction(signatures: [kp.publicKey: signature], body: header)
    }

    private func makeSignedTransaction(chainPath: [String]) -> Transaction {
        let kp = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: kp.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 1,
            nonce: 0,
            chainPath: chainPath
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: kp.privateKey)!
        return Transaction(signatures: [kp.publicKey: signature], body: header)
    }

    func testUnhealthyRootIsReportedUnavailableAndBlocksMining() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        try await node.start()
        let root = await node.genesisConfig.directory

        await node.markChainUnhealthy(chainPath: [root], reason: "test")

        let syncing = await node.isSyncing
        let unavailable = await node.isChainUnavailable(chainPath: [root])
        let produced = await node.produceAndSubmitBlock()

        XCTAssertTrue(syncing, "root health must feed public availability checks")
        XCTAssertTrue(unavailable)
        XCTAssertFalse(produced, "mining must not build on an unhealthy in-memory tip")
        await node.stop()
    }

    func testStorageDegradedRootUsesRecoverableHealthState() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        let root = await node.genesisConfig.directory

        await node.markChainStorageDegraded(chainPath: [root], reason: "transient storage outage")
        let unavailableBefore = await node.isChainUnavailable(chainPath: [root])
        XCTAssertTrue(unavailableBefore)

        let health = await node.chainHealth[root]
        guard case .degraded(let reason, _, .committedTipFrontier)? = health else {
            XCTFail("storage degradation must be represented as recoverable degraded health, got \(String(describing: health))")
            await node.stop()
            return
        }
        XCTAssertEqual(reason, "transient storage outage")
        await node.stop()
    }

    func testFatalUnhealthyRootDoesNotSelfRecover() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        let root = await node.genesisConfig.directory

        await node.markChainUnhealthy(chainPath: [root], reason: "corrupt committed state")
        await node.recoverRecoverableUnhealthyChains()

        let unavailable = await node.isChainUnavailable(chainPath: [root])
        XCTAssertTrue(unavailable,
                      "fatal chain health must not clear just because CAS is readable")
        let health = await node.chainHealth[root]
        guard case .fatal(let reason, _)? = health else {
            XCTFail("fatal health must remain fatal, got \(String(describing: health))")
            await node.stop()
            return
        }
        XCTAssertEqual(reason, "corrupt committed state")
        await node.stop()
    }

    func testUnhealthyRootRejectsTipStateReads() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        let root = await node.genesisConfig.directory

        await node.markChainUnhealthy(chainPath: [root], reason: "test")

        do {
            _ = try await node.getBalance(address: "alice", directory: root)
            XCTFail("balance reads must not resolve the stale in-memory tip of an unhealthy chain")
        } catch NodeError.chainUnavailable(let directory) {
            XCTAssertEqual(directory, root)
        }

        do {
            _ = try await node.getBalance(address: "alice", chainPath: [root])
            XCTFail("chain-path balance reads must not bypass unhealthy-chain gating")
        } catch NodeError.chainUnavailable(let directory) {
            XCTAssertEqual(directory, root)
        }

        await node.stop()
    }

    func testUnhealthyRootRejectsMempoolAdmission() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        let root = await node.genesisConfig.directory
        let transaction = makeTransaction(chainPath: [root])

        await node.markChainUnhealthy(chainPath: [root], reason: "test")

        let direct = await node.submitTransactionWithReason(directory: root, transaction: transaction)
        if case .failure(let reason) = direct {
            XCTAssertTrue(reason.contains("unavailable"))
        } else {
            XCTFail("direct transaction submit must fail closed for unhealthy chains")
        }

        let pathResult = await node.submitTransactionWithReason(chainPath: [root], transaction: transaction)
        if case .failure(let reason) = pathResult {
            XCTAssertTrue(reason.contains("unavailable"))
        } else {
            XCTFail("chain-path transaction submit must fail closed for unhealthy chains")
        }

        guard let network = await node.network(forPath: [root]) else {
            XCTFail("missing test network")
            return
        }
        let mempoolCount = await network.nodeMempool.count
        XCTAssertEqual(mempoolCount, 0, "unhealthy admission must not populate the mempool")
        await node.stop()
    }

    func testUnhealthyRootStatusUsesCommittedTip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        let root = await node.genesisConfig.directory

        guard let store = await node.stateStore(forPath: [root]) else {
            XCTFail("missing root state store")
            return
        }
        await store.applyBlock(StateChangeset(
            height: 42,
            blockHash: "committed-tip",
            stateRoot: "committed-state"
        ))
        await node.markChainUnhealthy(chainPath: [root], reason: "test")

        let status = await node.chainStatus().first { $0.chainPath == [root] }

        XCTAssertEqual(status?.height, 42)
        XCTAssertEqual(status?.tip, "committed-tip")
        XCTAssertEqual(status?.unhealthy, true)
        await node.stop()
    }

    func testValidatorRejectsDuplicateLeafWrongSiblingPath() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let node = try await makeNode(storagePath: tmpDir)
        let root = await node.genesisConfig.directory
        let left = [root, "A", "Payments"]
        let right = [root, "B", "Payments"]

        guard let chain = await node.chain(forPath: [root]),
              let network = await node.network(forPath: [root]) else {
            XCTFail("missing root chain/network")
            return
        }
        let validator = TransactionValidator(
            fetcher: await network.fetcher,
            chainState: chain,
            expectedChainPath: left
        )

        let wrongSiblingTx = makeSignedTransaction(chainPath: right)
        let result = await validator.validate(wrongSiblingTx).result

        if case .failure(.chainPathMismatch) = result {
            // expected
        } else {
            XCTFail("validator must compare the full chain path, not only duplicate leaf/depth")
        }
        await node.stop()
    }
}
