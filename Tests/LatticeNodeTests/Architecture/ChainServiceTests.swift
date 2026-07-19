import Crypto
import Foundation
import Ivy
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode

final class ChainServiceTests: XCTestCase {
    func testTransactionRequestsCarryConcreteBodiesThroughJSON() throws {
        let key = CryptoUtils.generateKeyPair()
        let transaction = try signedTransaction(
            key: key,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: 1
            )]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let submitted = try decoder.decode(
            SubmitTransactionRequest.self,
            from: encoder.encode(SubmitTransactionRequest(
                transaction: transaction
            ))
        )
        XCTAssertNotNil(submitted.transaction.body.node)
        XCTAssertEqual(submitted.transaction.body.rawCID, transaction.body.rawCID)

        let reward = try decoder.decode(
            MiningReward.self,
            from: encoder.encode(MiningReward(
                chainPath: ["Nexus"],
                transaction: transaction
            ))
        )
        XCTAssertNotNil(reward.transaction.body.node)
        XCTAssertEqual(reward.transaction.body.rawCID, transaction.body.rawCID)

        let intent = ChildDeployIntentRequest(
            directory: "Sandbox",
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 1,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100
            ),
            genesisTransactions: [transaction],
            target: UInt256.max,
            timestamp: 1
        )
        let decodedIntent = try decoder.decode(
            ChildDeployIntentRequest.self,
            from: encoder.encode(intent)
        )
        XCTAssertNotNil(decodedIntent.genesisTransactions.first?.body.node)
        XCTAssertEqual(
            decodedIntent.genesisTransactions.first?.body.rawCID,
            transaction.body.rawCID
        )
    }

    func testRequestPayloadCeilingIsInclusive() async throws {
        let key = CryptoUtils.generateKeyPair()
        let body = try signedTransaction(
            key: key,
            chainPath: ["Nexus"]
        ).body
        func request(signatureBytes: Int) -> SubmitTransactionRequest {
            SubmitTransactionRequest(transaction: Transaction(
                signatures: ["k": String(repeating: "x", count: signatureBytes)],
                body: body
            ))
        }
        let encoder = JSONEncoder()
        let emptySize = try encoder.encode(request(signatureBytes: 0)).count
        let padding = ChainServiceLimits.maximumPayloadBytes - emptySize
        let exact = request(signatureBytes: padding)
        let oversized = request(signatureBytes: padding + 1)
        XCTAssertEqual(
            try encoder.encode(exact).count,
            ChainServiceLimits.maximumPayloadBytes
        )
        XCTAssertEqual(
            try encoder.encode(oversized).count,
            ChainServiceLimits.maximumPayloadBytes + 1
        )

        let service = makeService(process: try await nexusProcess())
        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(exact)
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(oversized)
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .requestTooLarge)
        }
    }

    func testPublicationFailureDoesNotRewriteAcceptedWork() async throws {
        let service = makeService(
            process: try await nexusProcess(),
            acceptedBlockPublisher: { _, _ in throw TestPublicationError.failed }
        )
        let template = try await service.miningTemplate(MiningTemplateRequest())

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .canonicalized)
        let status = await service.status()
        XCTAssertEqual(status.height, 1)
    }

    func testDuplicateWorkIsReportedWithoutClaimingNewAcceptance() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let first = try await process.admit(BlockHeader(node: template.block))
        guard case .canonicalized = first.decision else {
            return XCTFail("expected initial canonical admission")
        }

        let duplicate = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: template.block.nonce
        ))
        XCTAssertFalse(duplicate.accepted)
        XCTAssertEqual(duplicate.disposition, .duplicate)
    }

    func testExternalRewardTransactionProducesAndSubmitsWork() async throws {
        let process = try await nexusProcess()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { blockCID, _ in
                await publishedBlocks.record(blockCID)
            }
        )
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )

        let template = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [MiningReward(
                chainPath: ["Nexus"],
                transaction: reward
            )])
        )
        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.chainPath, ["Nexus"])
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            1
        )
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues()
                .values.first?.rawCID,
            try VolumeImpl<Transaction>(node: reward).rawCID
        )
        XCTAssertEqual(Set(reward.signatures.keys), [miner.publicKey])
        XCTAssertFalse(reward.signatures.keys.contains(
            process.configuration.processPublicKey
        ))

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .canonicalized)
        let blockCIDs = await publishedBlocks.all()
        XCTAssertEqual(blockCIDs, [try XCTUnwrap(submitted.tipCID)])
        let status = await service.status()
        XCTAssertEqual(status.height, 1)
    }

    func testStateInvalidRewardIsRejectedInsteadOfSilentlyDropped() async throws {
        let service = makeService(process: try await nexusProcess())
        let issued = try await service.miningTemplate(MiningTemplateRequest())
        let miner = CryptoUtils.generateKeyPair()
        let rewardWithNonceGap = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )],
            nonce: 1
        )

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest(
                rewards: [MiningReward(
                    chainPath: ["Nexus"],
                    transaction: rewardWithNonceGap
                )]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidRewardTransaction)
        }

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: issued.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
    }

    func testRewardPlanBindsDeclaredPathBeforeRouting() async throws {
        let service = makeService(process: try await nexusProcess())
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest(rewards: [
                MiningReward(
                    chainPath: ["Nexus", "Payments"],
                    transaction: reward
                )
            ]))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidRewardPlan)
        }
    }

    func testServiceOwnsABoundedMempool() async throws {
        let service = makeService(
            process: try await nexusProcess(),
            mempoolMaxCount: 1
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                nonce: 0
            )
        ))

        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(SubmitTransactionRequest(
                transaction: try signedTransaction(
                    key: key,
                    chainPath: ["Nexus"],
                    nonce: 1
                )
            ))
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }
        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
    }

    func testChildIntentNeedsSignedGenesisAndParentAnchor() async throws {
        let process = try await nexusProcess()
        let publishedProofs = PublishedProofs()
        let service = makeService(
            process: process,
            childProofPublisher: { await publishedProofs.record($0) }
        )
        let childKey = CryptoUtils.generateKeyPair()
        let childOwner = CryptoUtils.createAddress(from: childKey.publicKey)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 1,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        )
        let premineBody = transactionBody(
            key: childKey,
            chainPath: ["Nexus", "Sandbox"],
            accountActions: [AccountAction(
                owner: childOwner,
                delta: Int64(spec.premineAmount())
            )]
        )
        let unsignedPremine = Transaction(
            signatures: [:],
            body: try HeaderImpl(node: premineBody)
        )
        let unsignedRequest = ChildDeployIntentRequest(
            directory: "Sandbox",
            spec: spec,
            genesisTransactions: [unsignedPremine],
            target: UInt256.max,
            timestamp: 1
        )
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(unsignedRequest)
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }

        let premine = try signedTransaction(
            key: childKey,
            chainPath: ["Nexus", "Sandbox"],
            accountActions: premineBody.accountActions
        )
        let intent = try await service.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Sandbox",
                spec: spec,
                genesisTransactions: [premine],
                target: UInt256.max,
                timestamp: 1
            )
        )
        XCTAssertEqual(intent.chainPath, ["Nexus", "Sandbox"])
        XCTAssertEqual(intent.genesisBlock.parentState.rawCID, intent.parentStateCID)

        let beforeAnchor = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        XCTAssertEqual(beforeAnchor.block.children.node?.count, 0)

        let anchorKey = CryptoUtils.generateKeyPair()
        let anchor = try signedTransaction(
            key: anchorKey,
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID
            )]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: anchor)
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(
            try children.allKeysAndValues()["Sandbox"]?.rawCID,
            intent.genesisCID
        )

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.parentGenesisLinks.count, 1)
        XCTAssertEqual(submitted.parentGenesisLinks[0].parentPath, ["Nexus"])
        XCTAssertEqual(submitted.parentGenesisLinks[0].directory, "Sandbox")
        XCTAssertEqual(
            submitted.parentGenesisLinks[0].childGenesisCID,
            intent.genesisCID
        )
        let proofSummary = try XCTUnwrap(submitted.publishedChildProofs.first)
        let recordedPublication = await publishedProofs.first()
        let publication = try XCTUnwrap(recordedPublication)
        XCTAssertEqual(proofSummary.directory, "Sandbox")
        XCTAssertEqual(proofSummary.childCID, intent.genesisCID)
        XCTAssertEqual(publication.directory, "Sandbox")
        XCTAssertEqual(publication.childCID, intent.genesisCID)
        let proof = publication.proof
        XCTAssertEqual(proof.directoryPath, ["Sandbox"])
        let responseJSON = try JSONEncoder().encode(submitted)
        XCTAssertFalse(String(decoding: responseJSON, as: UTF8.self).contains(
            "serializedProof"
        ))
        let status = await service.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
    }

    func testReplacingIntentDoesNotDeleteUserOwnedAnchor() async throws {
        let service = makeService(process: try await nexusProcess())
        let original = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: original.directory,
                    blockCID: original.genesisCID
                )]
            )
        ))

        let replacement = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 2
        )
        XCTAssertNotEqual(replacement.genesisCID, original.genesisCID)
        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
        XCTAssertEqual(status.pendingChildIntents, 1)
    }

    func testCanonicalStateChangeExpiresStaleChildIntent() async throws {
        let service = makeService(process: try await nexusProcess())
        _ = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )
        let template = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [MiningReward(
                chainPath: ["Nexus"],
                transaction: reward
            )])
        )
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))

        let status = await service.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
    }

    func testParentTargetMissKeepsDurableProofWhenPublicationFails() async throws {
        let process = try await nexusProcess()
        let genesis = try await process.canonicalTipBlock()
        let retargetingBlock = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 0,
            fetcher: process
        )
        XCTAssertEqual(retargetingBlock.nextTarget, UInt256.max / UInt256(2))
        let first = try await process.admit(BlockHeader(node: retargetingBlock))
        XCTAssertTrue(first.decision.isAccepted)

        let publishedProofs = PublishedProofs()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            childProofPublisher: {
                await publishedProofs.record($0)
                throw TestPublicationError.failed
            },
            acceptedBlockPublisher: { blockCID, _ in
                await publishedBlocks.record(blockCID)
            }
        )
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID
                )]
            )
        ))
        let template = try await service.miningTemplate(MiningTemplateRequest())
        var nonce: UInt64 = 0
        while template.block.replacingNonce(nonce).proofOfWorkHash()
                <= template.block.target {
            nonce += 1
        }

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertFalse(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .carrier)
        XCTAssertNotNil(submitted.parentCarrierLink)
        XCTAssertTrue(submitted.publishedChildProofs.isEmpty)
        let publicationCount = await publishedProofs.count()
        XCTAssertEqual(publicationCount, 1)
        let publishedBlockCount = await publishedBlocks.count()
        XCTAssertEqual(publishedBlockCount, 0)
    }

    func testAuthenticatedProviderSuppliesOrdinaryChildCandidate() async throws {
        let process = try await nexusProcess()
        let parent = try await process.canonicalTipBlock()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        let child = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: 2,
            nonce: 0,
            fetcher: process
        )
        let childEntries = try await process.durableCandidateEntries(for: child)
        let publication = PublishedProofs()
        let provisionalParents = ProvisionalParents()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                await provisionalParents.record(context.parentCarrier)
                return [DirectChildCandidate(
                    directory: "Existing",
                    block: child,
                    searchTarget: child.target,
                    acquisitionEntries: childEntries
                )]
            },
            childProofPublisher: { await publication.record($0) }
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        let recordedProvisional = await provisionalParents.first()
        let provisional = try XCTUnwrap(recordedProvisional)
        XCTAssertEqual(
            provisional.transactions.rawCID,
            template.block.transactions.rawCID
        )
        XCTAssertEqual(provisional.timestamp, template.block.timestamp)
        XCTAssertEqual(provisional.target, template.block.target)
        XCTAssertEqual(provisional.nextTarget, template.block.nextTarget)
        XCTAssertEqual(provisional.prevState.rawCID, template.block.prevState.rawCID)
        XCTAssertEqual(
            try template.block.children.node?.allKeysAndValues()["Existing"]?
                .rawCID,
            try BlockHeader(node: child).rawCID
        )
        let provisionalWorkID = try BlockHeader(node: provisional).rawCID
        XCTAssertNotEqual(provisionalWorkID, template.workID)
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: provisionalWorkID,
                nonce: 0
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.publishedChildProofs, [
            DirectChildProofSummary(
                directory: "Existing",
                childCID: try BlockHeader(node: child).rawCID
            )
        ])
        let publicationCount = await publication.count()
        XCTAssertEqual(publicationCount, 1)
    }

    func testChildCandidateProviderIsBoundedByService() async throws {
        let process = try await nexusProcess()
        let parent = try await process.canonicalTipBlock()
        let child = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        let childEntries = try await process.durableCandidateEntries(for: child)
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in
                ["A", "B"].map {
                    DirectChildCandidate(
                        directory: $0,
                        block: child,
                        searchTarget: child.target,
                        acquisitionEntries: childEntries
                    )
                }
            },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _, _ in },
            maximumChildCandidates: 1
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(Set(try children.allKeysAndValues().keys), ["A"])
    }

    func testContextualChildCandidateBindsNewParentCarrierState() async throws {
        let parentProcess = try await nexusProcess()
        let parentGenesis = try await parentProcess.canonicalTipBlock()
        let childSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        )
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: childSpec,
            parentState: parentGenesis.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: parentProcess
        )
        let childHeader = try BlockHeader(node: childGenesis)
        let anchor = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: "Payments",
                blockCID: childHeader.rawCID
            )]
        )
        try await VolumeImpl<Transaction>(node: anchor).storeRecursively(
            storer: parentProcess
        )
        let firstCarrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [anchor],
            children: ["Payments": childGenesis],
            timestamp: parentGenesis.timestamp + 1,
            nonce: 0,
            fetcher: parentProcess
        )
        let firstCarrierHeader = try BlockHeader(node: firstCarrier)
        let parentOutcome = try await parentProcess.admit(firstCarrierHeader)
        let carrierLink = try XCTUnwrap(parentOutcome.parentCarrierLink)
        guard case .success(let genesisLink) = try await parentProcess.genesisLink(
            parentBlockHeader: firstCarrierHeader,
            directory: "Payments",
            childGenesisCID: childHeader.rawCID
        ) else {
            return XCTFail("accepted parent did not issue child genesis link")
        }
        let proof = try await ChildBlockProof.generate(
            rootHeader: firstCarrierHeader,
            childDirectory: "Payments",
            fetcher: parentProcess
        )

        let childDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: childDirectory) }
        let childProcess = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: childDirectory,
            privateKeyHex: String(repeating: "02", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parentProcess.configuration.processPublicKey,
                host: "127.0.0.1",
                port: 4002
            )
        ))
        try await (childHeader as any Header).store(storer: childProcess)
        try await (childGenesis.transactions as any Header).storeRecursively(
            storer: childProcess
        )
        try await (childGenesis.spec as any Header).storeRecursively(
            storer: childProcess
        )
        try await (childGenesis.postState as any Header).storeRecursively(
            storer: childProcess
        )
        let bootstrap = try await childProcess.admit(
            childHeader,
            authenticatedChildPackage: AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentCarrierLink: carrierLink,
                    parentGenesisLink: genesisLink
                )
            )
        )
        XCTAssertTrue(
            bootstrap.decision.isAccepted,
            "unexpected bootstrap decision: \(bootstrap.decision)"
        )

        let nextParentCarrier = try await BlockBuilder.buildBlock(
            previous: firstCarrier,
            timestamp: firstCarrier.timestamp + 1,
            nonce: 0,
            fetcher: parentProcess
        )
        XCTAssertNotEqual(
            nextParentCarrier.prevState.rawCID,
            childGenesis.parentState.rawCID
        )
        let childService = makeService(process: childProcess)
        await XCTAssertThrowsErrorAsync(
            try await childService.miningTemplate(MiningTemplateRequest())
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .parentCarrierRequired
            )
        }
        let childMiner = CryptoUtils.generateKeyPair()
        let childReward = try signedTransaction(
            key: childMiner,
            chainPath: ["Nexus", "Payments"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: childMiner.publicKey),
                delta: 1
            )]
        )
        let candidate: DirectChildCandidate
        do {
            candidate = try await childService.miningCandidate(
                parentCarrier: nextParentCarrier,
                rewards: [MiningReward(
                    chainPath: ["Nexus", "Payments"],
                    transaction: childReward
                )]
            )
        } catch {
            XCTFail("contextual child candidate failed: \(error)")
            throw error
        }

        XCTAssertEqual(candidate.directory, "Payments")
        XCTAssertEqual(
            candidate.block.parentState.rawCID,
            nextParentCarrier.prevState.rawCID
        )
        XCTAssertNotEqual(
            candidate.block.parentState.rawCID,
            childGenesis.parentState.rawCID
        )
        XCTAssertEqual(
            try candidate.block.transactions.node?.allKeysAndValues()
                .values.first?.rawCID,
            try VolumeImpl<Transaction>(node: childReward).rawCID
        )
        await XCTAssertThrowsErrorAsync(
            try await childService.submitWork(SubmitWorkRequest(
                workID: try BlockHeader(node: candidate.block).rawCID,
                nonce: candidate.block.nonce
            ))
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .parentCarrierRequired
            )
        }
    }

    private func nexusProcess() async throws -> ChainProcess {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
    }

    private func makeService(
        process: ChainProcess,
        childCandidateProvider: @escaping ChildCandidateProvider = { _ in [] },
        childProofPublisher: @escaping ChildProofPublisher = { _ in },
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher = { _, _ in },
        mempoolMaxCount: Int = 10_000
    ) -> ChainService {
        ChainService(
            process: process,
            childCandidateProvider: childCandidateProvider,
            childProofPublisher: childProofPublisher,
            acceptedBlockPublisher: acceptedBlockPublisher,
            mempoolMaxCount: mempoolMaxCount
        )
    }

    private func simpleChildIntent(
        service: ChainService,
        directory: String,
        timestamp: Int64
    ) async throws -> ChildDeployIntentResponse {
        try await service.createChildDeployIntent(ChildDeployIntentRequest(
            directory: directory,
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100
            ),
            genesisTransactions: [],
            target: UInt256.max,
            timestamp: timestamp
        ))
    }
}

private enum TestPublicationError: Error {
    case failed
}

private actor PublishedProofs {
    private var values: [DirectChildProofPublication] = []

    func record(_ publication: DirectChildProofPublication) {
        values.append(publication)
    }

    func first() -> DirectChildProofPublication? {
        values.first
    }

    func count() -> Int {
        values.count
    }
}

private actor PublishedBlocks {
    private var values: [String] = []

    func record(_ blockCID: String) {
        values.append(blockCID)
    }

    func all() -> [String] {
        values
    }

    func count() -> Int {
        values.count
    }
}

private actor ProvisionalParents {
    private var values: [Block] = []

    func record(_ block: Block) {
        values.append(block)
    }

    func first() -> Block? {
        values.first
    }
}

private func signedTransaction(
    key: (privateKey: String, publicKey: String),
    chainPath: [String],
    accountActions: [AccountAction] = [],
    genesisActions: [GenesisAction] = [],
    nonce: UInt64 = 0
) throws -> Transaction {
    let body = transactionBody(
        key: key,
        chainPath: chainPath,
        accountActions: accountActions,
        genesisActions: genesisActions,
        nonce: nonce
    )
    let header = try HeaderImpl(node: body)
    let signature = try XCTUnwrap(TransactionSigning.sign(
        bodyHeader: header,
        privateKeyHex: key.privateKey
    ))
    return Transaction(signatures: [key.publicKey: signature], body: header)
}

private func transactionBody(
    key: (privateKey: String, publicKey: String),
    chainPath: [String],
    accountActions: [AccountAction] = [],
    genesisActions: [GenesisAction] = [],
    nonce: UInt64 = 0
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: [],
        depositActions: [],
        genesisActions: genesisActions,
        receiptActions: [],
        withdrawalActions: [],
        signers: [CryptoUtils.createAddress(from: key.publicKey)],
        fee: 0,
        nonce: nonce,
        chainPath: chainPath
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}
