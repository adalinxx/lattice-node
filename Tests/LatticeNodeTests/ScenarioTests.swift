import XCTest
@testable import LatticeNode
import Lattice
import cashew
import UInt256
import VolumeBroker
import Ivy

// MARK: - Test Infrastructure

private func testSpec(blockTime: UInt64 = 1000) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: blockTime,
        initialReward: 1024,
        halvingInterval: 210_000
    )
}

private actor TestCAS: Fetcher {
    var store: [String: Data] = [:]
    func fetch(rawCid: String) async throws -> Data {
        guard let data = store[rawCid] else { throw NSError(domain: "NotFound", code: 404) }
        return data
    }
    func put(cid: String, data: Data) { store[cid] = data }
}

// MARK: - StateStore Scenario Tests

final class StateStoreScenarioTests: XCTestCase {

    private func makeStore() throws -> StateStore {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try StateStore(storagePath: tmp, chain: "Test")
    }

    func testApplyBlockMetadata() async throws {
        let store = try makeStore()
        let changeset = StateChangeset(
            height: 1,
            blockHash: "block1",
            stateRoot: "root1"
        )
        await store.applyBlock(changeset)

        let h = store.getHeight()
        XCTAssertEqual(h, 1)
        let tip = store.getChainTip()
        XCTAssertEqual(tip, "block1")
    }

    func testTransactionHistoryQuery() async throws {
        let store = try makeStore()
        try await store.indexTransaction(address: "alice", txCID: "tx1", blockHash: "b1", height: 1)
        try await store.indexTransaction(address: "alice", txCID: "tx2", blockHash: "b2", height: 2)
        try await store.indexTransaction(address: "bob", txCID: "tx3", blockHash: "b2", height: 2)

        let aliceHistory = store.getTransactionHistory(address: "alice")
        XCTAssertEqual(aliceHistory.count, 2)
        XCTAssertEqual(aliceHistory.first?.txCID, "tx2")  // newest first

        let bobHistory = store.getTransactionHistory(address: "bob")
        XCTAssertEqual(bobHistory.count, 1)
    }

}

// MARK: - NodeMempool Adversarial Tests

final class MempoolAdversarialTests: XCTestCase {

    func testRBFOverflowProtection() async throws {
        let mempool = NodeMempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)

        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -Int64(1000))],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [],
            signers: [addr], fee: UInt64.max - 10, nonce: 1
        )
        let h1 = try HeaderImpl<TransactionBody>(node: body1)
        let sig1 = TransactionSigning.sign(bodyHeader: h1, privateKeyHex: kp.privateKey)!
        let tx1 = Transaction(signatures: [kp.publicKey: sig1], body: h1)
        let r1 = await mempool.addTransaction(tx1)
        if case .added = r1 {} else { XCTFail("Expected .added") }

        // Try to replace with same nonce but lower fee — should fail even with overflow
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -Int64(1000))],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [],
            signers: [addr], fee: 5, nonce: 1
        )
        let h2 = try HeaderImpl<TransactionBody>(node: body2)
        let sig2 = TransactionSigning.sign(bodyHeader: h2, privateKeyHex: kp.privateKey)!
        let tx2 = Transaction(signatures: [kp.publicKey: sig2], body: h2)
        let r2 = await mempool.addTransaction(tx2)
        if case .rejected = r2 {
            // Expected
        } else {
            XCTFail("Should reject RBF with lower fee")
        }
    }

    func testMempoolStressTest() async throws {
        let mempool = NodeMempool(maxSize: 500)
        var added = 0

        for i in 0..<1000 {
            let kp = CryptoUtils.generateKeyPair()
            let addr = CryptoUtils.createAddress(from: kp.publicKey)
            let body = TransactionBody(
                accountActions: [AccountAction(owner: addr, delta: -Int64(1000))],
                actions: [], depositActions: [], genesisActions: [], receiptActions: [],
                withdrawalActions: [],
                signers: [addr], fee: UInt64(i + 1), nonce: 0
            )
            let h = try HeaderImpl<TransactionBody>(node: body)
            let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: h)
            if await mempool.add(transaction: tx) { added += 1 }
        }

        let count = await mempool.count
        XCTAssertTrue(count <= 500)
        XCTAssertGreaterThan(added, 0)

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 10)

        // Verify fee ordering — each tx should have >= fee of next
        for i in 0..<(selected.count - 1) {
            let fee1 = selected[i].body.node?.fee ?? 0
            let fee2 = selected[i + 1].body.node?.fee ?? 0
            XCTAssertGreaterThanOrEqual(fee1, fee2)
        }
    }

    func testPerAccountFloodPrevention() async throws {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 10)
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)

        var accepted = 0
        for i in 0..<20 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: addr, delta: Int64(UInt64(999 - i)) - Int64(1000))],
                actions: [], depositActions: [], genesisActions: [], receiptActions: [],
                withdrawalActions: [],
                signers: [addr], fee: UInt64(100 + i), nonce: UInt64(i)
            )
            let h = try HeaderImpl<TransactionBody>(node: body)
            let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: h)
            if await mempool.add(transaction: tx) { accepted += 1 }
        }

        XCTAssertEqual(accepted, 10, "Should accept exactly maxPerAccount transactions")
    }
}

// MARK: - Protocol Version Tests

final class ProtocolVersionTests: XCTestCase {

    func testCompatibility() {
        XCTAssertTrue(LatticeProtocol.isCompatible(peerVersion: 2))
        XCTAssertFalse(LatticeProtocol.isCompatible(peerVersion: 1))
        XCTAssertFalse(LatticeProtocol.isCompatible(peerVersion: 0))
        XCTAssertFalse(LatticeProtocol.isCompatible(peerVersion: 99))
    }

    func testActiveForks() {
        let forks = LatticeProtocol.activeForks(atHeight: 0)
        XCTAssertEqual(forks.count, 2)
        XCTAssertEqual(forks.first?.name, "genesis")
        XCTAssertEqual(forks.last?.name, "child-block-proof-envelope")
    }

    func testChainAnnounceDataRoundtrip() {
        let original = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipHeight: 42,
            tipCID: "baguqeera123",
            specCID: "baguqeera456",
            protocolVersion: LatticeProtocol.version
        )

        let serialized = original.serialize()
        let deserialized = ChainAnnounceData.deserialize(serialized)

        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized?.chainDirectory, "Nexus")
        XCTAssertEqual(deserialized?.tipHeight, 42)
        XCTAssertEqual(deserialized?.tipCID, "baguqeera123")
        XCTAssertEqual(deserialized?.specCID, "baguqeera456")
        XCTAssertEqual(deserialized?.protocolVersion, LatticeProtocol.version)
    }

    func testChainAnnounceDataRejectsCorruptedData() {
        let bad = Data([0x00])
        XCTAssertNil(ChainAnnounceData.deserialize(bad))
        XCTAssertNil(ChainAnnounceData.deserialize(Data()))
    }
}

// MARK: - Metrics Tests

final class MetricsTests: XCTestCase {

    func testCounterIncrement() {
        let m = NodeMetrics()
        m.increment("test_counter")
        m.increment("test_counter")
        m.increment("test_counter", by: 5)

        let output = m.prometheus()
        XCTAssertTrue(output.contains("test_counter 7"))
    }

    func testGaugeSet() {
        let m = NodeMetrics()
        m.set("test_gauge", value: 42.5)

        let output = m.prometheus()
        XCTAssertTrue(output.contains("test_gauge 42.5"))
    }

    func testPrometheusFormat() {
        let m = NodeMetrics()
        m.increment("blocks_total")
        m.set("chain_height", value: 100)

        let output = m.prometheus()
        XCTAssertTrue(output.contains("# TYPE blocks_total counter"))
        XCTAssertTrue(output.contains("# TYPE chain_height gauge"))
    }
}

// MARK: - Peer Diversity Tests

final class PeerDiversityTests: XCTestCase {

    func testSubnetExtraction() {
        XCTAssertEqual(PeerDiversity.subnet("192.168.1.1"), "v4:192.168")
        XCTAssertEqual(PeerDiversity.subnet("10.0.0.1"), "v4:10.0")
        XCTAssertEqual(PeerDiversity.subnet("::1"), "v6:0000.0000")
    }

    func testShouldConnectRespectsLimit() {
        let existing = [
            PeerEndpoint(publicKey: "a", host: "192.168.1.1", port: 4001),
            PeerEndpoint(publicKey: "b", host: "192.168.1.2", port: 4001),
        ]
        let sameSubnet = PeerEndpoint(publicKey: "c", host: "192.168.1.3", port: 4001)
        let diffSubnet = PeerEndpoint(publicKey: "d", host: "10.0.0.1", port: 4001)

        XCTAssertFalse(PeerDiversity.shouldConnect(to: sameSubnet, existingPeers: existing))
        XCTAssertTrue(PeerDiversity.shouldConnect(to: diffSubnet, existingPeers: existing))
    }

    func testSelectDiversePeersDistributesAcrossSubnets() {
        let candidates = (0..<20).map {
            PeerEndpoint(publicKey: "p\($0)", host: "\($0 / 5).\($0 % 5).0.1", port: 4001)
        }
        let selected = PeerDiversity.selectDiversePeers(from: candidates, existing: [], maxNew: 8)
        XCTAssertEqual(selected.count, 8)

        var subnets = Set<String>()
        for peer in selected {
            subnets.insert(PeerDiversity.subnet(peer.host))
        }
        XCTAssertGreaterThan(subnets.count, 1, "Should select from multiple subnets")
    }
}

// MARK: - SQLite Edge Cases

final class SQLiteDatabaseTests: XCTestCase {

    func testOpenAndCreateTable() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO test (id, name) VALUES (?1, ?2)", params: [.int(1), .text("hello")])

        let rows = try db.query("SELECT * FROM test")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"]?.textValue, "hello")
    }

    func testTransactionRollback() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)")
        try db.execute("INSERT INTO test VALUES (1, 'original')")

        try db.beginTransaction()
        try db.execute("UPDATE test SET val = 'modified' WHERE id = 1")
        try db.rollbackTransaction()

        let rows = try db.query("SELECT val FROM test WHERE id = 1")
        XCTAssertEqual(rows[0]["val"]?.textValue, "original")
    }

    func testBlobStorageRoundtrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE blobs (key TEXT PRIMARY KEY, data BLOB)")

        let testData = Data([0x00, 0xFF, 0x42, 0x13, 0x37])
        try db.execute("INSERT INTO blobs VALUES (?1, ?2)", params: [.text("test"), .blob(testData)])

        let rows = try db.query("SELECT data FROM blobs WHERE key = ?1", params: [.text("test")])
        XCTAssertEqual(rows[0]["data"]?.blobValue, testData)
    }
}

// MARK: - Genesis Determinism

final class GenesisDeterminismTests: XCTestCase {

    func testGenesisIsDeterministic() async throws {
        let broker = MemoryBroker()
        try await seedEmptyStateVolume(into: broker)
        let fetcher = BrokerFetcher(broker: broker)
        let r1 = try await NexusGenesis.create(fetcher: fetcher)
        let r2 = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(r1.blockHash, r2.blockHash, "Genesis must be deterministic")
    }

    func testGenesisHasCorrectReward() {
        let spec = NexusGenesis.spec
        XCTAssertEqual(spec.initialReward, 1_048_576)
        XCTAssertEqual(spec.halvingInterval, 876_600)   // 100 years at 1h/block
        XCTAssertEqual(spec.targetBlockTime, 3_600_000) // 1 hour in ms
    }

    func testPremineAmountIsAbout10Percent() {
        let spec = NexusGenesis.spec
        let premineAmount = spec.premineAmount()
        let totalSupply = spec.initialReward * spec.halvingInterval * 2
        let ratio = Double(premineAmount) / Double(totalSupply)
        XCTAssertGreaterThan(ratio, 0.09)
        XCTAssertLessThan(ratio, 0.11)
    }
}
