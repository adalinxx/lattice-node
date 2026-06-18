import XCTest
@testable import Lattice
@testable import LatticeNode
import VolumeBroker
import cashew
import UInt256

final class AtomicApplyRecoveryTests: XCTestCase {

    private func makeOneTxBlock(
        node: LatticeNode,
        network: ChainNetwork,
        keyPair: (privateKey: String, publicKey: String)
    ) async throws -> (block: Block, blockHash: String, txCID: String, miner: String, txEntries: [String: VolumeImpl<Transaction>]) {
        let genesis = await node.genesisResult.block
        let miner = CryptoUtils.createAddress(from: keyPair.publicKey)
        let reward = genesis.spec.node?.rewardAtBlock(1) ?? 1024
        let body = TransactionBody(
            accountActions: [AccountAction(owner: miner, delta: Int64(reward))],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [miner],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = sign(body, keyPair)
        let txCID = try VolumeImpl<Transaction>(node: tx).rawCID
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [tx],
            timestamp: genesis.timestamp + 1_000,
            target: genesis.nextTarget,
            nonce: 1,
            fetcher: network.ivyFetcher
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        return (block, blockHash, txCID, miner, [txCID: try VolumeImpl<Transaction>(node: tx)])
    }

    func test_appliedThroughMarker_writtenInSameTxnAsTip() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try StateStore(storagePath: tmp, chain: "Nexus")
        let changeset = StateChangeset(
            height: 1,
            blockHash: "block-1",
            stateRoot: "state-1"
        )
        let txCID = "tx-1"
        let address = "address-1"

        let committed = await store.applyBlock(
            changeset,
            receiptGeneralEntries: [
                (key: "receipt:\(txCID)", value: Data("receipt".utf8), height: 1),
                (key: "receipt-idx:\(txCID)", value: Data("index".utf8), height: 1)
            ],
            txHistory: [(address: address, txCID: txCID, blockHash: changeset.blockHash, height: 1)]
        )

        XCTAssertTrue(committed)
        XCTAssertEqual(store.getChainTip(), changeset.blockHash)
        XCTAssertEqual(store.getHeight(), 1)
        XCTAssertEqual(store.getBlockHash(atHeight: 1), changeset.blockHash)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 1)
        XCTAssertEqual(store.getGeneral(key: "receipt:\(txCID)"), Data("receipt".utf8))
        XCTAssertEqual(store.getGeneral(key: "receipt-idx:\(txCID)"), Data("index".utf8))
        XCTAssertEqual(store.getTransactionHistory(address: address).first?.txCID, txCID)
    }

    /// The design declares the receipts-applied-through marker monotone,
    /// but `applyBlock` used to write `changes.height` unconditionally — a
    /// replay at a lower height (recovery re-applying an already-covered
    /// height, or a shorter-fork promotion) regressed the marker and re-opened
    /// an already-closed recovery gap. RED before the single monotone
    /// marker-write helper; GREEN after.
    func test_appliedThroughMarker_doesNotRegressOnLowerHeightReplay() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try StateStore(storagePath: tmp, chain: "Nexus")
        func changeset(_ h: UInt64) -> StateChangeset {
            StateChangeset(
                height: h,
                blockHash: "block-\(h)",
                stateRoot: "state-\(h)"
            )
        }

        let applied5 = await store.applyBlock(changeset(5))
        XCTAssertTrue(applied5)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 5)

        // applyBlock replay at a LOWER height must not lower the marker.
        let applied4 = await store.applyBlock(changeset(4))
        XCTAssertTrue(applied4)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 5,
            "applyBlock replay at height 4 must not regress the monotone marker")

        // The other two marker writers share the same monotone helper.
        try await store.commitReceiptsThrough(height: 3, generalEntries: [], txHistory: [])
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 5)
        try await store.batchIndexReceipts(generalEntries: [], txHistory: [], appliedThroughHeight: 2)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 5)

        // And it still advances when the height genuinely rises.
        let applied6 = await store.applyBlock(changeset(6))
        XCTAssertTrue(applied6)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 6)
    }

    func test_commitCanonicalSegmentWithBlockEffects_writesIndexesAtomically() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try StateStore(storagePath: tmp, chain: "Nexus")
        let changeset = StateChangeset(
            height: 1,
            blockHash: "block-1",
            stateRoot: "state-1"
        )
        let txCID = "tx-1"
        let address = "address-1"

        try await store.commitCanonicalSegment(
            CanonicalSegment(
                blocks: [
                    CanonicalSegmentBlock(
                        height: changeset.height,
                        hash: changeset.blockHash,
                        stateRoot: changeset.stateRoot
                    )
                ],
                connectsBelow: true
            ),
            blockEffects: [
                CanonicalBlockEffects(
                    changes: changeset,
                    receiptGeneralEntries: [
                        (key: "receipt:\(txCID)", value: Data("receipt".utf8), height: 1),
                        (key: "receipt-idx:\(txCID)", value: Data("index".utf8), height: 1)
                    ],
                    txHistory: [(address: address, txCID: txCID, blockHash: changeset.blockHash, height: 1)]
                )
            ]
        )

        XCTAssertEqual(store.getChainTip(), changeset.blockHash)
        XCTAssertEqual(store.getHeight(), changeset.height)
        XCTAssertEqual(store.getBlockHash(atHeight: changeset.height), changeset.blockHash)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), changeset.height)
        XCTAssertEqual(store.getGeneral(key: "receipt:\(txCID)"), Data("receipt".utf8))
        XCTAssertEqual(store.getGeneral(key: "receipt-idx:\(txCID)"), Data("index".utf8))
        XCTAssertEqual(store.getTransactionHistory(address: address).first?.txCID, txCID)
    }

    func test_productionApplyPath_writesMarkerAtomicallyWithTipAndReceipts() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        guard let network = await node.network(for: "Nexus"),
              let store = await node.stateStore(for: "Nexus") else {
            XCTFail("expected Nexus network and store")
            return
        }

        let built = try await makeOneTxBlock(node: node, network: network, keyPair: kp)

        await store.armReceiptsCommitFailure()
        let applied = await node.applyAcceptedBlock(
            block: built.block,
            blockHash: built.blockHash,
            txEntries: built.txEntries,
            directory: "Nexus"
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.getChainTip(), built.blockHash)
        XCTAssertEqual(store.getHeight(), 1)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 1)
        XCTAssertNotNil(store.getGeneral(key: "receipt:\(built.txCID)"))
        XCTAssertEqual(store.getTransactionHistory(address: built.miner).first?.txCID, built.txCID)
    }

    func test_crashBetweenTipCommitAndReceipts_recoveryReindexes() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        guard let network = await node.network(for: "Nexus"),
              let store = await node.stateStore(for: "Nexus") else {
            XCTFail("expected Nexus network and store")
            return
        }

        let built = try await makeOneTxBlock(node: node, network: network, keyPair: kp)
        let block = built.block
        let blockHash = built.blockHash
        let txCID = built.txCID
        let miner = built.miner

        guard await node.storeBlockData(block, network: network) != nil else {
            XCTFail("expected block data to persist into CAS")
            return
        }

        try await store.commitCanonicalSegment(CanonicalSegment(
            blocks: [CanonicalSegmentBlock(height: 1, hash: blockHash, stateRoot: block.postState.rawCID)],
            connectsBelow: true
        ))

        XCTAssertEqual(store.getChainTip(), blockHash)
        XCTAssertNil(store.getReceiptsAppliedThroughHeight())
        XCTAssertNil(store.getGeneral(key: "receipt:\(txCID)"))
        XCTAssertTrue(store.getTransactionHistory(address: miner).isEmpty)

        let recovered = await node.recoverFromCAS(directory: "Nexus")
        XCTAssertTrue(recovered)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 1)
        XCTAssertNotNil(store.getGeneral(key: "receipt-idx:\(txCID)"))
        XCTAssertNotNil(store.getGeneral(key: "receipt:\(txCID)"))

        let history = store.getTransactionHistory(address: miner)
        XCTAssertEqual(history.first?.txCID, txCID)
        XCTAssertEqual(history.first?.blockHash, blockHash)
        XCTAssertEqual(history.first?.height, 1)
    }

    func test_nonConnectingSyncWithLaggingReceiptMarker_clampsReplayToBlockIndexFloor() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        defer { Task { await node.stop() } }

        guard let network = await node.network(for: "Nexus"),
              let store = await node.stateStore(for: "Nexus") else {
            XCTFail("expected Nexus network and store")
            return
        }

        let genesis = await node.genesisResult.block
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: genesis.nextTarget,
            nonce: 1,
            fetcher: network.ivyFetcher
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1,
            timestamp: genesis.timestamp + 2_000,
            target: block1.nextTarget,
            nonce: 2,
            fetcher: network.ivyFetcher
        )

        let miner = CryptoUtils.createAddress(from: kp.publicKey)
        let reward = genesis.spec.node?.rewardAtBlock(3) ?? 1024
        let body = TransactionBody(
            accountActions: [AccountAction(owner: miner, delta: Int64(reward))],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [miner],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = sign(body, kp)
        let txCID = try VolumeImpl<Transaction>(node: tx).rawCID
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2,
            transactions: [tx],
            timestamp: genesis.timestamp + 3_000,
            target: block2.nextTarget,
            nonce: 3,
            fetcher: network.ivyFetcher
        )
        let block1Hash = try VolumeImpl<Block>(node: block1).rawCID
        let block2Hash = try VolumeImpl<Block>(node: block2).rawCID
        let block3Hash = try VolumeImpl<Block>(node: block3).rawCID

        let storedBlock1 = await node.storeBlockData(block1, network: network)
        let storedBlock2 = await node.storeBlockData(block2, network: network)
        let storedBlock3 = await node.storeBlockData(block3, network: network)
        XCTAssertNotNil(storedBlock1)
        XCTAssertNotNil(storedBlock2)
        XCTAssertNotNil(storedBlock3)

        await store.backfillBlockIndex([
            (height: 1, blockHash: block1Hash),
            (height: 2, blockHash: block2Hash)
        ])
        try await store.commitCanonicalSegment(CanonicalSegment(
            blocks: [CanonicalSegmentBlock(height: 3, hash: block3Hash, stateRoot: block3.postState.rawCID)],
            connectsBelow: false
        ))

        XCTAssertNil(store.getBlockHash(atHeight: 1))
        XCTAssertNil(store.getBlockHash(atHeight: 2))
        XCTAssertEqual(store.getLowestBlockIndexHeight(), 3)
        XCTAssertNil(store.getReceiptsAppliedThroughHeight())

        let recovered = await node.recoverFromCAS(directory: "Nexus")
        XCTAssertTrue(recovered)
        XCTAssertEqual(store.getReceiptsAppliedThroughHeight(), 3)
        XCTAssertNotNil(store.getGeneral(key: "receipt-idx:\(txCID)"))
        XCTAssertNotNil(store.getGeneral(key: "receipt:\(txCID)"))
    }

}
