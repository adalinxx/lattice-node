import Crypto
import Hummingbird
import HummingbirdTesting
import Lattice
import LatticeLightClient
import UInt256
import XCTest
import cashew
@testable import LatticeNode
@testable import LatticeNodeDaemon

final class DaemonHTTPTests: XCTestCase {
    func testPeriodicMaintenanceRunsAndStopsOnCancellation() async {
        let probe = MaintenanceProbe()
        let task = Task {
            await runPeriodicMaintenance(every: .milliseconds(1)) {
                await probe.record()
            }
        }
        await probe.waitForFirstRun()
        task.cancel()
        await task.value
        let count = await probe.count
        try? await Task.sleep(for: .milliseconds(5))
        let finalCount = await probe.count
        XCTAssertEqual(finalCount, count)
    }

    func testConcurrentTemplateRequestsRemainIndependent() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-concurrency-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let body = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            let workIDs = try await withThrowingTaskGroup(
                of: String.self,
                returning: [String].self
            ) { group in
                for _ in 0..<32 {
                    group.addTask {
                        var workID: String?
                        try await client.execute(
                            uri: "/v1/mining/templates",
                            method: .post,
                            headers: [.contentType: "application/json"],
                            body: ByteBuffer(bytes: body)
                        ) { response in
                            guard response.status == .ok else {
                                throw HTTPConcurrencyTestError.unexpectedStatus
                            }
                            workID = try JSONDecoder().decode(
                                MiningTemplateResponse.self,
                                from: Data(response.body.readableBytesView)
                            ).workID
                        }
                        return try XCTUnwrap(workID)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            XCTAssertEqual(workIDs.count, 32)
            XCTAssertEqual(Set(workIDs).count, 32)
        }
    }

    func testHealthFailsWhenServiceProjectionFailsButStatusRemainsReadable()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-degraded-health-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        let receipt = await service.enqueueCanonicalCommit(ChainCommit(
            tipHash: "missing-block",
            mainChainBlocksAdded: ["missing-block": 0]
        ))
        await receipt.wait()
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)

        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                let status = try JSONDecoder().decode(
                    ChainServiceStatusResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertFalse(status.mempoolAvailable)
            }
            try await client.execute(uri: "/v1/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let status = try JSONDecoder().decode(
                    ChainServiceStatusResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertFalse(status.mempoolAvailable)
            }
        }
    }

    func testReadRoutesReturnAcceptedContentAndCanonicalProofs() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-read-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let genesis = try await process.canonicalTipBlock()
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let loose = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [],
            timestamp: genesis.timestamp + 1,
            nonce: 0,
            fetcher: process
        )
        let looseVolume = try VolumeImpl<Block>(node: loose)
        try await looseVolume.store(storer: process)
        let looseTransaction = try signedHTTPTransaction()
        let looseTransactionVolume = try VolumeImpl<Transaction>(
            node: looseTransaction
        )
        try await looseTransactionVolume.store(storer: process)
        let transaction = try signedHTTPTransaction()
        let submitted = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: transaction)
        )

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/blocks/\(genesisCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let block = try JSONDecoder().decode(
                    Block.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(try BlockHeader(node: block).rawCID, genesisCID)
            }
            try await client.execute(
                uri: "/v1/blocks/\(looseVolume.rawCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
            try await client.execute(
                uri: "/v1/transactions/\(submitted.transactionCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let content = try JSONDecoder().decode(
                    ContentBoundTransaction.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(
                    try HeaderImpl(node: content.body).rawCID,
                    transaction.body.rawCID
                )
            }
            try await client.execute(
                uri: "/v1/transactions/\(looseTransactionVolume.rawCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }

            var proof: LightClientProof?
            try await client.execute(
                uri: "/v1/accounts/\(NexusGenesis.ownerAddress)/proof",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                proof = try JSONDecoder().decode(
                    LightClientProof.self,
                    from: Data(response.body.readableBytesView)
                )
            }
            let decodedProof = try XCTUnwrap(proof)
            XCTAssertEqual(
                try BlockHeader(node: decodedProof.block).rawCID,
                genesisCID
            )
            let proofIsValid = await LightClientProtocol.verify(decodedProof)
            XCTAssertEqual(proofIsValid, genesisCID)

            let absentAddress = CryptoUtils.createAddress(
                from: CryptoUtils.generateKeyPair().publicKey
            )
            var absentProof: LightClientProof?
            try await client.execute(
                uri: "/v1/accounts/\(absentAddress)/proof",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                absentProof = try JSONDecoder().decode(
                    LightClientProof.self,
                    from: Data(response.body.readableBytesView)
                )
            }
            let decodedAbsentProof = try XCTUnwrap(absentProof)
            XCTAssertEqual(decodedAbsentProof.balance, 0)
            XCTAssertEqual(decodedAbsentProof.nonce, 0)
            let absentProofIsValid = await LightClientProtocol.verify(
                decodedAbsentProof
            )
            XCTAssertEqual(absentProofIsValid, genesisCID)

            try await client.execute(
                uri: "/v1/blocks/not-a-cid",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testJSONTransportRejectsMalformedAndOversizedBodies() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-body-limit-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{")
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }

            try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: [UInt8](
                    repeating: 0,
                    count: ChainServiceLimits.maximumPayloadBytes + 1
                ))
            ) { response in
                XCTAssertEqual(response.status, .contentTooLarge)
            }
        }
    }

    func testParentUnavailableIsServiceUnavailable() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-parent-unavailable-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        await service.setParentConsensusReady(false)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let body = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: body)
            ) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
            }
        }
    }

    func testMiningTemplateRequestJSONDefaultsAndDeploymentMode() throws {
        let legacy = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(legacy.rewards.isEmpty)
        XCTAssertEqual(legacy.mode, .normal)

        let deployment = MiningTemplateRequest(mode: .deployment)
        let decoded = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: JSONEncoder().encode(deployment)
        )
        XCTAssertTrue(decoded.rewards.isEmpty)
        XCTAssertEqual(decoded.mode, .deployment)
    }

    func testMiningTemplateAndWorkRoutesRoundTrip() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-mining-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        let app = makeApplication(
            service: service,
            host: "127.0.0.1",
            port: 8080
        )
        let templateRequest = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            var template: MiningTemplateResponse?
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: templateRequest)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                template = try JSONDecoder().decode(
                    MiningTemplateResponse.self,
                    from: Data(response.body.readableBytesView)
                )
            }

            let issued = try XCTUnwrap(template)
            XCTAssertEqual(issued.chainPath, ["Nexus"])
            XCTAssertEqual(issued.block.nonce, 0)
            let workRequest = try JSONEncoder().encode(SubmitWorkRequest(
                workID: issued.workID,
                nonce: 0
            ))
            try await client.execute(
                uri: "/v1/mining/work",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: workRequest)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let submitted = try JSONDecoder().decode(
                    SubmitWorkResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertTrue(submitted.accepted)
                XCTAssertEqual(submitted.disposition, .canonicalized)
                XCTAssertNotNil(submitted.tipCID)
            }

            let deploymentRequest = try JSONEncoder().encode(
                MiningTemplateRequest(mode: .deployment)
            )
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: deploymentRequest)
            ) { response in
                XCTAssertEqual(response.status, .conflict)
            }
        }
    }

    func testTransactionRoutePreservesConcreteBody() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        let app = makeApplication(
            service: service,
            host: "127.0.0.1",
            port: 8080
        )
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(TransactionSigning.sign(
            bodyHeader: bodyHeader,
            privateKeyHex: key.privateKey
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: signature],
            body: bodyHeader
        )
        let requestData = try JSONEncoder().encode(
            SubmitTransactionRequest(transaction: transaction)
        )

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: requestData)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let submitted = try JSONDecoder().decode(
                    SubmitTransactionResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(
                    submitted.transactionCID,
                    try VolumeImpl<Transaction>(node: transaction).rawCID
                )
            }
        }
    }

    private func signedHTTPTransaction() throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let header = try HeaderImpl(node: body)
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: key.privateKey
            ))],
            body: header
        )
    }
}

private actor MaintenanceProbe {
    private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForFirstRun() async {
        if count > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private enum HTTPConcurrencyTestError: Error {
    case unexpectedStatus
}
