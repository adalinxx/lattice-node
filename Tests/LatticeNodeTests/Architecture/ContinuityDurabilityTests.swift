import Crypto
import Foundation
import Lattice
import LatticeMinerCore
import cashew
import UInt256
import XCTest
@testable import LatticeNode

final class ContinuityDurabilityTests: XCTestCase {

    private func nonce(
        of block: Block,
        from start: UInt64,
        where accepts: (UInt256) -> Bool
    ) -> UInt64 {
        let midstate = ProofOfWork.midstate(for: block)
        var n = start
        while n - start < (1 << 24) {
            if accepts(ProofOfWork.hash(midstate: midstate, nonce: n)) { return n }
            n += 1
        }
        XCTFail("unsatisfiable nonce search")
        return start
    }

    private func mine(
        on producer: ChainProcess,
        depth: Int,
        miner: (privateKey: String, publicKey: String)
    ) async throws -> [Block] {
        let service = ChainService(
            process: producer,
            childCandidateProvider: { _ in [] },
            childCandidateReservationReconciler: { _ in true },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
            acceptedTransactionPublisher: { _ in }
        )
        var blocks: [Block] = []
        for index in 0..<depth {
            let body = TransactionBody(
                accountActions: [AccountAction(
                    owner: CryptoUtils.createAddress(from: miner.publicKey),
                    delta: 1
                )],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [CryptoUtils.createAddress(from: miner.publicKey)],
                fee: 0, nonce: UInt64(index), chainPath: ["Nexus"]
            )
            let header = try HeaderImpl(node: body)
            let signature = try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: miner.privateKey
            ))
            let reward = Transaction(
                signatures: [miner.publicKey: signature], body: header
            )
            let template = try await service.miningTemplate(
                MiningTemplateRequest(rewards: [MiningReward(
                    chainPath: ["Nexus"], transaction: reward
                )])
            )
            let block = template.block.auditReplacingNonce(
                nonce(of: template.block, from: 0) { $0 <= template.block.target }
            )
            let outcome = try await producer.admit(BlockHeader(node: block))
            XCTAssertTrue(outcome.decision.isAccepted, "block \(index)")
            blocks.append(block)
        }
        return blocks
    }

    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-audit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func configuration(_ dir: URL) throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: dir,
            privateKeyHex: String(repeating: "01", count: 32)
        )
    }

    /// EAGER tier: a locally mined chain must still be attestable after a restart.
    func testEagerChainStaysAttestableAcrossRestart() async throws {
        let dir = directory()
        let config = try configuration(dir)
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        let chain = try await mine(on: process!, depth: 3, miner: CryptoUtils.generateKeyPair())
        let tipState = try XCTUnwrap(chain.last).postState.rawCID

        let live = await process!.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        XCTAssertTrue(live, "live eager chain must attest its own tip state")

        process = nil
        let restarted = try await ChainProcess.open(configuration: config)
        let recovered = await restarted.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        XCTAssertTrue(recovered, "eager chain must still attest its tip state after restart")
    }

    /// WEIGHED -> VALIDATE tier: the path this diff adds the durable fact for.
    func testWalkValidatedChainStaysAttestableAcrossRestart() async throws {
        let producerDir = directory()
        let producer = try await ChainProcess.open(
            configuration: try configuration(producerDir)
        )
        let chain = try await mine(on: producer, depth: 3, miner: CryptoUtils.generateKeyPair())
        let tipState = try XCTUnwrap(chain.last).postState.rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                let outcome = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted, "\(mode) admission")
            }
        }
        let live = await consumer!.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        XCTAssertTrue(live, "live walk-validated chain must attest its tip state")

        consumer = nil
        let restarted = try await ChainProcess.open(configuration: config)
        let recovered = await restarted.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        XCTAssertTrue(
            recovered,
            "walk-validated chain must still attest its tip state after restart"
        )
    }

    /// A WEIGHED-only chain must NOT be attestable (the defect being fixed).
    func testWeighedOnlyChainIsNotAttestable() async throws {
        let producerDir = directory()
        let producer = try await ChainProcess.open(
            configuration: try configuration(producerDir)
        )
        let chain = try await mine(on: producer, depth: 3, miner: CryptoUtils.generateKeyPair())
        let tipState = try XCTUnwrap(chain.last).postState.rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for block in chain {
            let outcome = try await consumer!.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        for block in chain {
            let cid = try BlockHeader(node: block).rawCID
            let v = await consumer!.blockValidated(cid)
            print("AUDIT weighed-only h=\(block.height) validated=\(v)")
        }
        let live = await consumer!.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        print("AUDIT live continuity = \(live)")
        XCTAssertFalse(live, "a weighed (unexecuted) tip must not be attestable")

        consumer = nil
        let restarted = try await ChainProcess.open(configuration: config)
        let recovered = await restarted.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        XCTAssertFalse(
            recovered, "a weighed tip must not become attestable by restarting"
        )
    }

    /// Item 2/3: a demoted (retention-evicted) marker must NOT retract the
    /// durable execution fact, and the restarted chain must still attest.
    func testDemotedMarkerDoesNotRetractExecutionAcrossRestart() async throws {
        let producer = try await ChainProcess.open(
            configuration: try configuration(directory())
        )
        let chain = try await mine(
            on: producer, depth: 3, miner: CryptoUtils.generateKeyPair()
        )
        let tipState = try XCTUnwrap(chain.last).postState.rawCID
        let tipCID = try BlockHeader(node: try XCTUnwrap(chain.last)).rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                _ = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
            }
        }
        try await consumer!.demoteValidatedForTesting(tipCID)
        let afterDemote = await consumer!.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        print("AUDIT live-after-demote attestable = \(afterDemote)")
        consumer = nil

        let restarted = try await ChainProcess.open(configuration: config)
        let marker = await restarted.blockValidated(tipCID)
        let attestable = await restarted.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        print("AUDIT restarted marker=\(marker) attestable=\(attestable)")
        XCTAssertTrue(
            attestable,
            "a demoted marker must not unmake the durable execution fact"
        )
    }

    /// Item 6: cost of one unbounded continuity walk as a function of height.
    func testContinuityWalkCostGrowsWithHeight() async throws {
        let depth = 60
        let producer = try await ChainProcess.open(
            configuration: try configuration(directory())
        )
        let chain = try await mine(
            on: producer, depth: depth, miner: CryptoUtils.generateKeyPair()
        )
        let tipState = try XCTUnwrap(chain.last).postState.rawCID
        // Attacker shape: `to` is a real produced state, `from` is a CID that
        // is nowhere in the graph, so the walk exhausts the whole ancestry.
        let bogus = LatticeState.emptyHeader.rawCID.replacingOccurrences(
            of: "a", with: "b"
        )
        let start = ContinuousClock.now
        var answered = false
        for _ in 0..<200 {
            answered = await producer.hasParentStateContinuity(
                from: bogus, to: tipState
            )
        }
        let elapsed = ContinuousClock.now - start
        print("AUDIT 200 exhaustive walks at height \(depth): \(elapsed) answered=\(answered)")
        XCTAssertFalse(answered)
    }

    /// Item 3/4: for LEGACY rows (written before the validation fact existed)
    /// the COLUMN is the only execution record, it is re-read on every boot
    /// (the synthesized batches are never persisted), and it is MUTABLE. A
    /// demote of such a row therefore erases an execution permanently.
    func testLegacyColumnIsTheSoleAndMutableExecutionRecord() async throws {
        let producer = try await ChainProcess.open(
            configuration: try configuration(directory())
        )
        let chain = try await mine(
            on: producer, depth: 3, miner: CryptoUtils.generateKeyPair()
        )
        let tipState = try XCTUnwrap(chain.last).postState.rawCID
        let tipCID = try BlockHeader(node: try XCTUnwrap(chain.last)).rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                _ = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
            }
        }
        consumer = nil

        // Simulate a store written by the PREVIOUS build: the tier column is
        // set, but no validation fact/batch was ever written.
        let db = dir.appendingPathComponent("state.db").path
        let genesis = NexusGenesis.expectedBlockHash
        try runSQL(db, """
            DELETE FROM admission_batches
              WHERE CAST(payload AS TEXT) LIKE '%validation%'
                AND CAST(payload AS TEXT) NOT LIKE '%blockHeight%';
            DELETE FROM admission_facts
              WHERE CAST(fact_id AS TEXT) LIKE '%validation%'
                AND CAST(fact_id AS TEXT) NOT LIKE '%\(genesis)%';
            """)

        var migrated: ChainProcess? = try await ChainProcess.open(configuration: config)
        let afterMigration = await migrated!.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        print("AUDIT legacy-store attestable after migration = \(afterMigration)")
        XCTAssertTrue(afterMigration, "the migration must carry legacy history")

        // Now demote that legacy row exactly as boot reconciliation or
        // retention eviction would.
        try await migrated!.demoteValidatedForTesting(tipCID)
        migrated = nil
        let reopened = try await ChainProcess.open(configuration: config)
        let afterDemote = await reopened.hasParentStateContinuity(
            from: LatticeState.emptyHeader.rawCID, to: tipState
        )
        print("AUDIT legacy-store attestable after demote+restart = \(afterDemote)")
        XCTAssertTrue(
            afterDemote,
            "LEGACY REGRESSION: demoting a pre-fact row erased the execution"
        )
    }

    private func runSQL(_ path: String, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private extension Block {
    func auditReplacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version, parent: parent, transactions: transactions,
            target: target, nextTarget: nextTarget, spec: spec,
            parentState: parentState, prevState: prevState, postState: postState,
            children: children, height: height, timestamp: timestamp, nonce: nonce
        )
    }
}
