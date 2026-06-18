import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker

private actor FailingFetcher: Fetcher {
    enum Error: Swift.Error {
        case unexpectedFetch(String)
    }

    func fetch(rawCid: String) async throws -> Data {
        throw Error.unexpectedFetch(rawCid)
    }
}

private actor GateProbe {
    private var activeByKey: [String: Int] = [:]
    private var maxActiveByKey: [String: Int] = [:]
    private var totalActive = 0
    private var maxTotalActive = 0

    func enter(_ key: String) {
        let active = (activeByKey[key] ?? 0) + 1
        activeByKey[key] = active
        maxActiveByKey[key] = max(maxActiveByKey[key] ?? 0, active)
        totalActive += 1
        maxTotalActive = max(maxTotalActive, totalActive)
    }

    func leave(_ key: String) {
        activeByKey[key, default: 0] -= 1
        totalActive -= 1
    }

    func maxActive(for key: String) -> Int {
        maxActiveByKey[key] ?? 0
    }

    func maxTotal() -> Int {
        maxTotalActive
    }
}

final class I5NodeInvariantTests: XCTestCase {
    private func makeNode() async throws -> (node: LatticeNode, dir: URL) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false,
                minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        return (node, tmp)
    }

    private func buildMaterializedStateFixture() async throws -> (
        block: Block,
        diff: StateDiff,
        materialized: LatticeState,
        fetcher: TestBrokerFetcher
    ) {
        let fetcher = cas()
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: fetcher
        )
        try await storeBlockFixture(genesis, to: fetcher)

        let body = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(spec.rewardAtBlock(1)))],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [minerAddr],
            fee: 0,
            nonce: 0
        )
        let tx = sign(body, kp)
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [tx],
            timestamp: genesis.timestamp + 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        guard let prevState = genesis.postState.node else {
            throw ValidationErrors.prevStateNotResolved
        }
        let (materialized, diff) = try await prevState.proveAndUpdateState(
            allAccountActions: body.accountActions,
            allActions: body.actions,
            allDepositActions: body.depositActions,
            allGenesisActions: body.genesisActions,
            allReceiptActions: body.receiptActions,
            allWithdrawalActions: body.withdrawalActions,
            transactionBodies: [body],
            fetcher: fetcher
        )
        XCTAssertEqual(try LatticeStateHeader(node: materialized).rawCID, block.postState.rawCID)
        XCTAssertFalse(diff.created.isEmpty)
        return (block, diff, materialized, fetcher)
    }

    private func buildMaterializedReceiptStateFixture() async throws -> (
        block: Block,
        diff: StateDiff,
        materialized: LatticeState,
        withdrawal: WithdrawalAction,
        fetcher: TestBrokerFetcher
    ) {
        let fetcher = cas()
        let withdrawer = CryptoUtils.generateKeyPair()
        let demander = CryptoUtils.generateKeyPair()
        let withdrawerAddress = CryptoUtils.createAddress(from: withdrawer.publicKey)
        let demanderAddress = CryptoUtils.createAddress(from: demander.publicKey)
        let spec = testSpec()
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddress, delta: 1_000)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [withdrawerAddress],
            fee: 0,
            nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [sign(premineBody, withdrawer)],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: fetcher
        )
        try await storeBlockFixture(genesis, to: fetcher)

        let receipt = ReceiptAction(
            withdrawer: withdrawerAddress,
            nonce: 7,
            demander: demanderAddress,
            amountDemanded: 75,
            directory: "FastTest"
        )
        let body = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddress, delta: Int64(spec.rewardAtBlock(1)))],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [receipt],
            withdrawalActions: [],
            signers: [withdrawerAddress],
            fee: 0,
            nonce: 1
        )
        let tx = sign(body, withdrawer)
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [tx],
            timestamp: genesis.timestamp + 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        guard let prevState = genesis.postState.node else {
            throw ValidationErrors.prevStateNotResolved
        }
        let (materialized, diff) = try await prevState.proveAndUpdateState(
            allAccountActions: body.accountActions,
            allActions: body.actions,
            allDepositActions: body.depositActions,
            allGenesisActions: body.genesisActions,
            allReceiptActions: body.receiptActions,
            allWithdrawalActions: body.withdrawalActions,
            transactionBodies: [body],
            fetcher: fetcher
        )
        XCTAssertEqual(try LatticeStateHeader(node: materialized).rawCID, block.postState.rawCID)
        XCTAssertFalse(diff.created.isEmpty)
        let withdrawal = WithdrawalAction(
            withdrawer: withdrawerAddress,
            nonce: receipt.nonce,
            demander: demanderAddress,
            amountDemanded: receipt.amountDemanded,
            amountWithdrawn: 75
        )
        return (block, diff, materialized, withdrawal, fetcher)
    }

    func testAcceptedStateStorageUsesMaterializedPostStateAndKeepsCIDGuard() async throws {
        let (node, dir) = try await makeNode()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let network = await node.network(for: "Nexus") else {
            return XCTFail("Nexus network should exist")
        }
        let fixture = try await buildMaterializedStateFixture()

        let roots = await node.storeAcceptedStateDiffRoots(
            block: fixture.block,
            stateDiff: fixture.diff,
            materializedPostState: fixture.materialized,
            network: network,
            source: FetcherContentSource(FailingFetcher()),
            directory: "Nexus"
        )

        XCTAssertNotNil(roots, "threaded materialized state path should not re-fetch transactions or prevState")
        XCTAssertTrue(roots?.contains(fixture.block.postState.rawCID) == true)

        let rejected = await node.storeAcceptedStateDiffRoots(
            block: fixture.block,
            stateDiff: fixture.diff,
            materializedPostState: LatticeState.emptyState(),
            network: network,
            source: FetcherContentSource(fixture.fetcher),
            directory: "Nexus"
        )
        XCTAssertNil(rejected, "wrong materialized post-state must trip the postState CID guard")
    }

    func testAcceptedReceiptStateStorageKeepsSubstateVolumeDurable() async throws {
        let (node, dir) = try await makeNode()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let network = await node.network(for: "Nexus") else {
            return XCTFail("Nexus network should exist")
        }
        let fixture = try await buildMaterializedReceiptStateFixture()
        let receiptRoot = fixture.materialized.receiptState.rawCID

        let roots = await node.storeAcceptedStateDiffRoots(
            block: fixture.block,
            stateDiff: fixture.diff,
            materializedPostState: fixture.materialized,
            network: network,
            source: FetcherContentSource(FailingFetcher()),
            directory: "Nexus"
        )

        XCTAssertTrue(roots?.contains(receiptRoot) == true)
        let receiptRootIsDurable = await network.hasDurableVolume(rootCID: receiptRoot)
        XCTAssertTrue(receiptRootIsDurable)
        let receiptState = ReceiptStateHeader(rawCID: receiptRoot)
        _ = try await receiptState.proveExistenceAndVerifyWithdrawers(
            directory: "FastTest",
            withdrawalActions: [fixture.withdrawal],
            fetcher: network.canonicalContentFetcher()
        )
    }

    func testSameChainMutationGateSerializesAndDifferentChainsProceedConcurrently() async throws {
        let (node, dir) = try await makeNode()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = GateProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await node.withChainMutation("Nexus") {
                        await probe.enter("Nexus")
                        try? await Task.sleep(for: .milliseconds(50))
                        await probe.leave("Nexus")
                    }
                }
            }
        }
        let sameChainMaxActive = await probe.maxActive(for: "Nexus")
        XCTAssertEqual(sameChainMaxActive, 1)

        let crossChainProbe = GateProbe()
        await withTaskGroup(of: Void.self) { group in
            for key in ["Nexus", "Nexus/Child"] {
                group.addTask {
                    await node.withChainMutation(key) {
                        await crossChainProbe.enter(key)
                        try? await Task.sleep(for: .milliseconds(75))
                        await crossChainProbe.leave(key)
                    }
                }
            }
        }
        let nexusMaxActive = await crossChainProbe.maxActive(for: "Nexus")
        let childMaxActive = await crossChainProbe.maxActive(for: "Nexus/Child")
        let maxTotal = await crossChainProbe.maxTotal()
        XCTAssertEqual(nexusMaxActive, 1)
        XCTAssertEqual(childMaxActive, 1)
        XCTAssertEqual(maxTotal, 2, "different chain keys should not share the same gate")
    }
}
