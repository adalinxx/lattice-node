import Crypto
import Foundation
import Ivy
import Lattice
import LatticeLightClient
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

final class ChainServiceTests: XCTestCase {
    func testReadSurfaceUsesAcceptedFactsAndVerifiableCanonicalState() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let genesis = try await process.canonicalTipBlock()
        let genesisCID = try BlockHeader(node: genesis).rawCID

        let accepted = try await service.acceptedBlock(genesisCID)
        XCTAssertEqual(try BlockHeader(node: accepted).rawCID, genesisCID)
        let genesisTransactions = try await accepted.transactions.resolve(
            fetcher: process
        )
        let transactionDictionary = try XCTUnwrap(genesisTransactions.node)
        let transactionEntries = try await transactionDictionary.boundedKeysAndValues(
            limit: transactionDictionary.count,
            fetcher: process
        )
        let premineCID = try XCTUnwrap(transactionEntries.first?.1.rawCID)
        let premine = try await service.transaction(premineCID)
        XCTAssertEqual(try VolumeImpl(node: premine.transaction()).rawCID, premineCID)

        let loose = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [],
            timestamp: genesis.timestamp + 1,
            nonce: 0,
            fetcher: process
        )
        let looseVolume = try VolumeImpl<Block>(node: loose)
        try await looseVolume.store(storer: process)
        await XCTAssertThrowsErrorAsync(
            try await service.acceptedBlock(looseVolume.rawCID)
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .resourceNotFound)
        }

        let looseTransaction = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        let looseTransactionVolume = try VolumeImpl<Transaction>(
            node: looseTransaction
        )
        try await looseTransactionVolume.store(storer: process)
        await XCTAssertThrowsErrorAsync(
            try await service.transaction(looseTransactionVolume.rawCID)
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .resourceNotFound)
        }

        let transaction = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        let submitted = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: transaction)
        )
        let returned = try await service.transaction(submitted.transactionCID)
        XCTAssertEqual(
            try returned.transaction().body.rawCID,
            transaction.body.rawCID
        )

        let proof = try await service.accountProof(
            address: NexusGenesis.ownerAddress
        )
        XCTAssertEqual(try BlockHeader(node: proof.block).rawCID, genesisCID)
        XCTAssertEqual(proof.balance, NexusGenesis.spec.premineAmount())
        let proofIsValid = await LightClientProtocol.verify(proof)
        XCTAssertEqual(proofIsValid, genesisCID)

        let absentAddress = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let absentProof = try await service.accountProof(address: absentAddress)
        XCTAssertEqual(absentProof.balance, 0)
        XCTAssertEqual(absentProof.nonce, 0)
        let absentProofIsValid = await LightClientProtocol.verify(absentProof)
        XCTAssertEqual(absentProofIsValid, genesisCID)
    }

    func testParentReadinessGatesConsensusWorkButNotTransactions() async throws {
        let service = ChainService(
            process: try await nexusProcess(),
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in }
        )
        await service.setParentConsensusReady(false)

        let stale = await service.status()
        XCTAssertEqual(stale.phase, .awaitingParent)
        XCTAssertNotNil(stale.tipCID)
        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest())
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .parentUnavailable)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(ChildDeployIntentRequest(
                directory: "Child",
                spec: NexusGenesis.spec,
                genesisTransactions: [],
                target: .max,
                timestamp: 1
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .parentUnavailable)
        }

        let transaction = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: transaction)
        )

        await service.setParentConsensusReady(true)
        let ready = await service.status()
        XCTAssertEqual(ready.phase, .active)
        _ = try await service.miningTemplate(MiningTemplateRequest())
    }

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
            policyModules: [WasmPolicyModule(bytes: Data([0, 1, 2]))],
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
        XCTAssertEqual(decodedIntent.policyModules.first?.bytes, Data([0, 1, 2]))
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
            acceptedBlockPublisher: { _ in throw TestPublicationError.failed }
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

    func testNetworkAdmissionPublishesBeforeOptionalChildMaterialization()
        async throws {
        let process = try await nexusProcess()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID,
                    parentWorkAuthorityKey: try childAuthority(for: intent)
                )]
            )
        ))
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let header = try BlockHeader(node: template.block)

        // `Block.storeBlock` deliberately leaves child links independent. This
        // network path has no authenticated direct-child route to materialize,
        // so hierarchy extraction is optional, but canonical visibility is not.
        let result = try await service.admitNetworkCandidate(
            header,
            authenticatedChildPackage: nil,
            preparingChildDirectories: []
        )

        guard case .canonicalized = result.decision else {
            return XCTFail("expected canonical network admission")
        }
        let publications = await publishedBlocks.all()
        XCTAssertEqual(publications, [header.rawCID])
    }

    func testBlockedNetworkPreflightDoesNotDelayTemplateCreation() async throws {
        let producer = try await nexusProcess()
        let genesis = try await producer.canonicalTipBlock()
        let candidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 0,
            fetcher: producer
        )
        let header = try BlockHeader(node: candidate)
        let remote = BlockingContentSource(blockedCID: header.rawCID)
        await remote.setEntries(
            try await producer.durableCandidateEntries(for: candidate)
        )
        let process = try await nexusProcess(remoteSource: remote)
        let service = makeService(process: process)
        let unresolved = BlockHeader(
            rawCID: header.rawCID,
            node: nil,
            encryptionInfo: nil
        )
        let admission = Task {
            try await service.admitNetworkCandidate(
                unresolved,
                authenticatedChildPackage: nil,
                preparingChildDirectories: []
            )
        }
        await remote.waitForBlockedFetch()

        let templateFinished = expectation(
            description: "local template finishes while remote admission is blocked"
        )
        let template = Task {
            defer { templateFinished.fulfill() }
            do {
                return try await service.miningTemplate(MiningTemplateRequest())
            } catch {
                throw error
            }
        }
        await fulfillment(of: [templateFinished], timeout: 1)

        await remote.releaseBlockedFetch()
        _ = try await admission.value
        _ = try await template.value
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
            acceptedBlockPublisher: { blockCID in
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

    func testLocalMempoolTransactionIsDurableContent() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let key = CryptoUtils.generateKeyPair()
        let submitted = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"]
            ))
        )

        let stored = await process.content([submitted.transactionCID])
        XCTAssertNotNil(stored[submitted.transactionCID])
    }

    func testCanonicalCommitFencePrecedesLaterTemplateRequest()
        async throws {
        let publication = CanonicalCommitLatch()
        let process = try await nexusProcess()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { _ in await publication.wait() }
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let submittedTemplate = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let submission = Task {
            try await service.submitWork(SubmitWorkRequest(
                workID: submittedTemplate.workID,
                nonce: 0
            ))
        }
        await publication.waitUntilEntered()

        // The process has already enqueued its canonical commit, while the
        // service operation is deliberately paused in publication.
        let laterRequestStarted = TaskStartLatch()
        let laterTemplate = Task {
            await laterRequestStarted.signal()
            return try await service.miningTemplate(MiningTemplateRequest())
        }
        await laterRequestStarted.wait()
        await Task.yield()
        await Task.yield()
        await publication.release()

        let submitted = try await submission.value
        XCTAssertTrue(submitted.accepted)
        let template = try await laterTemplate.value
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            0
        )
    }

    func testIdleCanonicalCommitFencePrecedesLaterTemplateRequest()
        async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let mined = try await service.miningTemplate(MiningTemplateRequest())
        let admission = try await process.admit(BlockHeader(node: mined.block))
        guard case .canonicalized(let commit) = admission.decision else {
            return XCTFail("expected canonical direct admission")
        }

        let receipt = await service.enqueueCanonicalCommit(commit)
        let laterRequestStarted = TaskStartLatch()
        let laterTemplate = Task {
            await laterRequestStarted.signal()
            return try await service.miningTemplate(MiningTemplateRequest())
        }
        await laterRequestStarted.wait()
        await Task.yield()
        await Task.yield()
        await receipt.wait()

        let template = try await laterTemplate.value
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            0
        )
    }

    func testCanonicalCommitFenceCoalescesQueuedCommitsInSourceOrder()
        async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        let blockCID = try XCTUnwrap(submitted.tipCID)
        let block = try await process.canonicalTipBlock()

        let removed = await service.enqueueCanonicalCommit(ChainCommit(
            revision: 2,
            tipHash: blockCID,
            mainChainBlocksRemoved: [blockCID]
        ))
        let added = await service.enqueueCanonicalCommit(ChainCommit(
            revision: 3,
            tipHash: blockCID,
            mainChainBlocksAdded: [blockCID: block.height]
        ))
        await removed.wait()
        await added.wait()

        // Removing the block re-admits its ordinary transaction; adding it
        // again must then remove it. A reversed queue would leave it pooled.
        let status = await service.status()
        XCTAssertTrue(status.mempoolAvailable)
        XCTAssertEqual(status.mempoolCount, 0)
    }

    func testInheritedReorgQueuesBehindEarlierNetworkCommit() async throws {
        let fixture = try await inheritedForkFixture()
        _ = try await fixture.process.applyInheritedWorkSnapshot(
            InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    fixture.siblingCarrierCID: WorkMeasure(
                        try verifiedWorkContribution(
                            id: fixture.siblingCarrierCID,
                            work: 10
                        )
                    ),
                ]
            ),
            from: fixture.parentAuthority.value
        )
        _ = try await fixture.service.submitTransaction(SubmitTransactionRequest(
            transaction: fixture.siblingTransaction
        ))
        let networkCommit = CanonicalCommitLatch()
        let admission = Task {
            try await fixture.process.admit(
                fixture.siblingHeader,
                authenticatedChildPackage: fixture.siblingPackage,
                canonicalCommitPublisher: { commit in
                    await networkCommit.wait()
                    return await fixture.service.enqueueCanonicalCommit(commit)
                }
            )
        }
        await networkCommit.waitUntilEntered()

        // The parent update acquires the service gate, then waits on the
        // network admission's process mutation. Releasing that admission puts
        // its commit on the FIFO before the inherited reorg is available.
        let inheritedStarted = TaskStartLatch()
        let inheritedContribution = try verifiedWorkContribution(
            id: fixture.activeCarrierCID,
            work: 1_000_000
        )
        let inherited = Task {
            await inheritedStarted.signal()
            return try await fixture.service.applyInheritedWorkSnapshot(
                InheritedWorkSnapshot(
                    revision: 1,
                    workByBlock: [
                        fixture.activeCarrierCID: WorkMeasure(inheritedContribution),
                    ]
                ),
                from: fixture.parentAuthority.value
            )
        }
        await inheritedStarted.wait()
        await Task.yield()
        await Task.yield()
        await networkCommit.release()

        let admissionOutcome = try await admission.value
        guard admissionOutcome.decision.isAccepted,
              admissionOutcome.canonicalCommitReceipt != nil else {
            return XCTFail(
                "expected queued sibling admission to publish a canonical commit, got \(admissionOutcome.decision)"
            )
        }
        let inheritedCommit = try await inherited.value
        XCTAssertTrue(inheritedCommit?.canonicalChanged ?? false)
        let reorgTipCID = try BlockHeader(
            node: try await fixture.process.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(
            reorgTipCID,
            fixture.activeCID
        )

        // A then B removes the sibling-genesis transaction and re-adds it
        // when B removes that genesis. Directly reconciling B before its
        // already-queued A would leave the transaction absent.
        let finalStatus = await fixture.service.status()
        XCTAssertEqual(finalStatus.mempoolCount, 1)
    }

#if DEBUG
    func testInheritedReorgReservesFIFOAheadOfLaterNetworkCommit()
        async throws {
        let fixture = try await inheritedForkFixture()

        // First accept the transaction-bearing sibling without involving the
        // service. The inherited reorg below must put its transaction back in
        // the pool, and the later branch must remove that same transaction.
        _ = try await fixture.process.applyInheritedWorkSnapshot(
            InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    fixture.siblingCarrierCID: WorkMeasure(
                        try verifiedWorkContribution(
                            id: fixture.siblingCarrierCID,
                            work: 10
                        )
                    ),
                ]
            ),
            from: fixture.parentAuthority.value
        )
        let sibling = try await fixture.process.admit(
            fixture.siblingHeader,
            authenticatedChildPackage: fixture.siblingPackage
        )
        XCTAssertTrue(sibling.decision.isAccepted)
        let siblingTip = await fixture.process.status().tipCID
        XCTAssertEqual(
            siblingTip,
            fixture.siblingCID
        )

        let activeContribution = try verifiedWorkContribution(
            id: fixture.activeCarrierCID,
            work: 100
        )
        let lateContribution = try verifiedWorkContribution(
            id: fixture.lateCarrierCID,
            work: 1_000
        )
        let inheritedSnapshot = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [
                fixture.activeCarrierCID: WorkMeasure(activeContribution),
                fixture.lateCarrierCID: WorkMeasure(lateContribution),
            ]
        )
        let inheritedPublisher = CanonicalCommitLatch()
        let inherited = Task {
            try await fixture.process.applyInheritedWorkSnapshot(
                inheritedSnapshot,
                from: fixture.parentAuthority.value,
                canonicalCommitPublisher: { commit in
                    await inheritedPublisher.wait()
                    return await fixture.service.enqueueCanonicalCommit(commit)
                }
            )
        }
        await inheritedPublisher.waitUntilEntered()

        // The ready network admission is waiting for the process mutation
        // lane. Releasing the inherited publisher must enqueue that reorg
        // before this admission can enqueue its own canonical commit.
        let network = Task {
            try await fixture.process.admit(
                fixture.lateHeader,
                authenticatedChildPackage: fixture.latePackage,
                canonicalCommitPublisher: { commit in
                    await fixture.service.enqueueCanonicalCommit(commit)
                }
            )
        }
        await fixture.process.waitForOperationWaiterCount(1)
        await inheritedPublisher.release()

        let inheritedUpdate = try await inherited.value
        guard let inheritedReceipt = inheritedUpdate.canonicalCommitReceipt else {
            return XCTFail("expected inherited canonical commit receipt")
        }
        let admitted = try await network.value
        guard admitted.decision.isAccepted,
              let networkReceipt = admitted.canonicalCommitReceipt else {
            return XCTFail(
                "expected later admission to publish a canonical commit, got \(admitted.decision)"
            )
        }
        await inheritedReceipt.wait()
        await networkReceipt.wait()

        let tipCID = try BlockHeader(
            node: try await fixture.process.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(tipCID, fixture.lateCID)

        // The inherited reorg removes the sibling genesis and re-adds this
        // transaction. The later canonical branch includes it, so ordered
        // reconciliation must remove it again.
        let finalStatus = await fixture.service.status()
        XCTAssertEqual(finalStatus.mempoolCount, 0)
    }
#endif

    func testProjectionFailureFailsStopWithoutDeletingDurableInputs()
        async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let stale = try await service.miningTemplate(MiningTemplateRequest())
        _ = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )

        // Inject a malformed projection event at the component boundary. A
        // production Lattice commit cannot name unavailable block content,
        // but storage/content failures must preserve every recovery input.
        let receipt = await service.enqueueCanonicalCommit(ChainCommit(
            tipHash: "missing-block",
            mainChainBlocksAdded: ["missing-block": 0]
        ))
        let laterRequestStarted = TaskStartLatch()
        let laterTemplate = Task {
            await laterRequestStarted.signal()
            return try await service.miningTemplate(MiningTemplateRequest())
        }
        await laterRequestStarted.wait()
        await Task.yield()
        await Task.yield()
        await receipt.wait()

        let status = await service.status()
        XCTAssertFalse(status.mempoolAvailable)
        XCTAssertEqual(status.mempoolCount, 0)
        XCTAssertEqual(status.pendingChildIntents, 1)
        let durable = try await process.localTransactions()
        XCTAssertEqual(durable.count, 1)
        await XCTAssertThrowsErrorAsync(try await laterTemplate.value) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .mempoolUnavailable
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: stale.workID,
                nonce: 0
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
    }

    func testServiceReconcilesLocalWorkAfterRuntimeStopAndRestart()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-runtime-stop-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5c", count: 32)
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )
        let service = makeService(process: process)

        // This is the daemon's runtime-to-service injection. Local work must
        // still reconcile while that runtime is stopped.
        await runtime.installAdmissionHandler { header, package, directories in
            try await service.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        do {
            try await runtime.start(process: process)
            await runtime.stop()

            _ = try await service.submitTransaction(SubmitTransactionRequest(
                transaction: try signedTransaction(
                    key: CryptoUtils.generateKeyPair(),
                    chainPath: ["Nexus"]
                )
            ))
            let stale = try await service.miningTemplate(MiningTemplateRequest())
            let submittedTemplate = try await service.miningTemplate(
                MiningTemplateRequest()
            )
            let submitted = try await service.submitWork(SubmitWorkRequest(
                workID: submittedTemplate.workID,
                nonce: 0
            ))

            XCTAssertTrue(submitted.accepted)
            let status = await service.status()
            XCTAssertEqual(status.mempoolCount, 0)
            await XCTAssertThrowsErrorAsync(
                try await service.submitWork(SubmitWorkRequest(
                    workID: stale.workID,
                    nonce: 0
                ))
            ) { error in
                XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
            }

            try await runtime.start(process: process)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    func testRestartRestoresLocalTransactionsButNotPeerTransactions() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-mempool-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5e", count: 32)
        )
        let local = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        let peer = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        var service: ChainService? = makeService(process: process!)
        let submitted = try await service!.submitTransaction(
            SubmitTransactionRequest(transaction: local)
        )
        _ = try await service!.submitNetworkTransaction(peer)
        let beforeRestart = await service!.transactionInventoryRoots()
        XCTAssertEqual(beforeRestart.count, 2)

        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        try await service!.restoreLocalTransactions()

        let restored = await service!.transactionInventoryRoots()
        XCTAssertEqual(restored, [submitted.transactionCID])
    }

    func testRestartReplaysProjectionAfterCheckpointWriteFailure() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-projection-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "6e", count: 32)
        )

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        var service: ChainService? = makeService(process: process!)
        let genesis = try await process!.canonicalTipBlock()
        let transaction = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        let inserted = try await service!.submitNetworkTransaction(transaction)
        XCTAssertTrue(inserted)
        let transactionCID = try VolumeImpl<Transaction>(node: transaction).rawCID
        let losingTemplate = try await service!.miningTemplate(
            MiningTemplateRequest()
        )
        let losing = try await service!.submitWork(SubmitWorkRequest(
            workID: losingTemplate.workID,
            nonce: 0
        ))
        XCTAssertTrue(losing.accepted)
        let losingCID = try XCTUnwrap(losing.tipCID)
        _ = try await simpleChildIntent(
            service: service!,
            directory: "RecoveryChild",
            timestamp: 1
        )
        let unrelatedPeer = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        let unrelatedInserted = try await service!
            .submitNetworkTransaction(unrelatedPeer)
        XCTAssertTrue(unrelatedInserted)
        var recovery = try await process!.serviceProjectionRecoveryCommit()
        XCTAssertNil(recovery)

        let fork1 = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1,
            nonce: 1,
            fetcher: process!
        )
        let fork1Admission = try await process!.admit(BlockHeader(node: fork1))
        XCTAssertTrue(fork1Admission.decision.isAccepted)
        let fork2 = try await BlockBuilder.buildBlock(
            previous: fork1,
            timestamp: fork1.timestamp + 1,
            nonce: 2,
            fetcher: process!
        )
        let fork2Header = try BlockHeader(node: fork2)
        let fork2Admission = try await process!.admit(fork2Header)
        XCTAssertTrue(fork2Admission.decision.isAccepted)
        let status = await process!.status()
        XCTAssertEqual(status.tipCID, fork2Header.rawCID)

        // Abort only the final checkpoint write. Every earlier projection
        // effect uses the real stores and completes before this trigger fires.
        let database = try NodeSQLite(
            path: configuration.storagePath
                .appendingPathComponent("state.db").path
        )
        try database.execute("""
            CREATE TRIGGER fail_service_projection_checkpoint
            BEFORE UPDATE OF service_projection_tip_cid ON node_metadata
            BEGIN
                SELECT RAISE(ABORT, 'injected checkpoint failure');
            END
            """)
        recovery = try await process!.serviceProjectionRecoveryCommit()
        let missedCommit = try XCTUnwrap(recovery)
        let receipt = await service!.enqueueCanonicalCommit(missedCommit)
        await receipt.wait()

        let degraded = await service!.status()
        XCTAssertFalse(degraded.mempoolAvailable)
        XCTAssertEqual(degraded.pendingChildIntents, 0)
        let durableCIDs = try await process!.localTransactions()
            .map(\.transactionCID)
        XCTAssertEqual(durableCIDs, [transactionCID])
        let checkpointRows = try database.query(
            "SELECT service_projection_tip_cid FROM node_metadata WHERE singleton = 1"
        )
        XCTAssertEqual(
            checkpointRows.first?["service_projection_tip_cid"]?.textValue,
            losingCID
        )
        let pendingRecovery = try await process!
            .serviceProjectionRecoveryCommit()
        XCTAssertNotNil(pendingRecovery)
        try database.execute("DROP TRIGGER fail_service_projection_checkpoint")

        // A real reopen replays the same endpoint delta. The already-persisted
        // reorg candidate remains exact, unrelated gossip stays volatile, and
        // stale child-intent cleanup is idempotent.
        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        try await service!.restoreLocalTransactions()
        var roots = await service!.transactionInventoryRoots()
        XCTAssertEqual(roots, [transactionCID])
        let recoveredStatus = await service!.status()
        XCTAssertEqual(recoveredStatus.pendingChildIntents, 0)

        // The checkpoint is written last, so replay is idempotent and the
        // resurrected transaction remains exact across another reopen.
        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        try await service!.restoreLocalTransactions()
        roots = await service!.transactionInventoryRoots()
        XCTAssertEqual(roots, [transactionCID])
        recovery = try await process!.serviceProjectionRecoveryCommit()
        XCTAssertNil(recovery)
    }

    func testProjectionRecoverySupportsDistinctChildGenesisRoots() async throws {
        let fixture = try await inheritedForkFixture()
        try await fixture.service.restoreLocalTransactions()
        var recovery = try await fixture.process
            .serviceProjectionRecoveryCommit()
        XCTAssertNil(recovery)

        _ = try await fixture.process.applyInheritedWorkSnapshot(
            InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    fixture.siblingCarrierCID: WorkMeasure(
                        try verifiedWorkContribution(
                            id: fixture.siblingCarrierCID,
                            work: 1_000
                        )
                    ),
                ]
            ),
            from: fixture.parentAuthority.value
        )
        let admitted = try await fixture.process.admit(
            fixture.siblingHeader,
            authenticatedChildPackage: fixture.siblingPackage
        )
        XCTAssertTrue(admitted.decision.isAccepted)
        let status = await fixture.process.status()
        XCTAssertEqual(status.tipCID, fixture.siblingCID)

        recovery = try await fixture.process.serviceProjectionRecoveryCommit()
        let recovered = try XCTUnwrap(recovery)
        XCTAssertEqual(recovered.tipHash, fixture.siblingCID)
        XCTAssertEqual(recovered.mainChainBlocksAdded, [fixture.siblingCID: 0])
        XCTAssertEqual(recovered.mainChainBlocksRemoved, [fixture.activeCID])

        try await fixture.service.restoreLocalTransactions()
        recovery = try await fixture.process.serviceProjectionRecoveryCommit()
        XCTAssertNil(recovery)
        try await fixture.service.restoreLocalTransactions()
        recovery = try await fixture.process.serviceProjectionRecoveryCommit()
        XCTAssertNil(recovery)
    }

    func testProjectionRecoveryTreatsUnprojectedRoundTripAsVolatile()
        async throws {
        let context = try await {
            let fixture = try await inheritedForkFixture()
            try await fixture.service.restoreLocalTransactions()
            let local = try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus", "Payments"]
            )
            let submitted = try await fixture.service.submitTransaction(
                SubmitTransactionRequest(transaction: local)
            )

            _ = try await fixture.process.applyInheritedWorkSnapshot(
                InheritedWorkSnapshot(
                    revision: 1,
                    workByBlock: [
                        fixture.siblingCarrierCID: WorkMeasure(
                            try verifiedWorkContribution(
                                id: fixture.siblingCarrierCID,
                                work: 1_000
                            )
                        ),
                    ]
                ),
                from: fixture.parentAuthority.value
            )
            let sibling = try await fixture.process.admit(
                fixture.siblingHeader,
                authenticatedChildPackage: fixture.siblingPackage
            )
            XCTAssertTrue(sibling.decision.isAccepted)
            let siblingTip = await fixture.process.status().tipCID
            XCTAssertEqual(siblingTip, fixture.siblingCID)

            _ = try await fixture.process.applyInheritedWorkSnapshot(
                InheritedWorkSnapshot(
                    revision: 2,
                    workByBlock: [
                        fixture.activeCarrierCID: WorkMeasure(
                            try verifiedWorkContribution(
                                id: fixture.activeCarrierCID,
                                work: 1_000_000
                            )
                        ),
                    ]
                ),
                from: fixture.parentAuthority.value
            )
            let activeTip = await fixture.process.status().tipCID
            XCTAssertEqual(activeTip, fixture.activeCID)

            // The service checkpoint and current tip are both A, so the
            // transient peer-only B branch has no endpoint delta to replay.
            let recovery = try await fixture.process
                .serviceProjectionRecoveryCommit()
            XCTAssertNil(recovery)
            return (
                configuration: fixture.process.configuration,
                localCID: submitted.transactionCID,
                peerCID: try VolumeImpl<Transaction>(
                    node: fixture.siblingTransaction
                ).rawCID
            )
        }()

        // Reopen the real stores. Local submissions remain restart authority;
        // peer transactions seen only on the transient branch do not.
        let process = try await ChainProcess.open(
            configuration: context.configuration
        )
        let service = makeService(process: process)
        try await service.restoreLocalTransactions()
        let inventory = await service.transactionInventoryRoots()
        XCTAssertEqual(inventory, [context.localCID])
        XCTAssertFalse(inventory.contains(context.peerCID))
        let recovery = try await process.serviceProjectionRecoveryCommit()
        XCTAssertNil(recovery)
    }

    func testRestartRestoresPreparedChildDeploymentAndExpiresItDurably()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-child-intent-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5f", count: 32)
        )

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        var service: ChainService? = makeService(process: process!)
        let childKey = CryptoUtils.generateKeyPair()
        let premine = try signedTransaction(
            key: childKey,
            chainPath: ["Nexus", "Sandbox"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: childKey.publicKey),
                delta: 1
            )]
        )
        let intent = try await service!.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Sandbox",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 1,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [premine],
                target: .max,
                timestamp: 1
            )
        )
        let anchor = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID,
                parentWorkAuthorityKey: try childAuthority(for: intent)
            )]
        )
        _ = try await service!.submitTransaction(
            SubmitTransactionRequest(transaction: anchor)
        )
        _ = try await process!.evictUnretainedVolumes()

        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        try await service!.restoreLocalTransactions()

        var status = await service!.status()
        XCTAssertEqual(status.pendingChildIntents, 1)
        var duplicateService: ChainService? = makeService(process: process!)
        let duplicateStatus = await duplicateService!.status()
        XCTAssertEqual(duplicateStatus.pendingChildIntents, 0)
        duplicateService = nil
        let broker = try DiskBroker(
            path: storage.appendingPathComponent("volumes.db").path
        )
        let intentOwner = [configuration.nexusGenesisCID, configuration.address.key]
            .joined(separator: ":") + ":child-intents"
        let retainedRoots = await broker.pinnedRoots(owners: [intentOwner])
        XCTAssertTrue(retainedRoots.contains(intent.genesisCID))
        XCTAssertGreaterThan(retainedRoots.count, 1)
        try await broker.pin(
            root: configuration.nexusGenesisCID,
            owner: intentOwner
        )
        _ = try await process!.evictUnretainedVolumes()
        let reconciledOwners = await broker.owners(
            root: configuration.nexusGenesisCID
        )
        XCTAssertFalse(reconciledOwners.contains(intentOwner))
        let deployment = try await service!.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let deployedChild = try XCTUnwrap(
            try deployment.block.children.node?.allKeysAndValues()["Sandbox"]?
                .node
        )
        XCTAssertEqual(try BlockHeader(node: deployedChild).rawCID, intent.genesisCID)
        let deployedTransactions = try await deployedChild.transactions.resolve(
            fetcher: process!
        )
        XCTAssertEqual(deployedTransactions.node?.count, 1)

        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )
        let ordinary = try await service!.miningTemplate(MiningTemplateRequest(
            rewards: [MiningReward(chainPath: ["Nexus"], transaction: reward)]
        ))
        _ = try await service!.submitWork(SubmitWorkRequest(
            workID: ordinary.workID,
            nonce: 0
        ))
        status = await service!.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
        for root in retainedRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.contains(intentOwner))
        }

        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        status = await service!.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
    }

    func testCanonicalCommitReconcilesEveryAddedAndRemovedTransaction() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let key = CryptoUtils.generateKeyPair()
        let removed = try signedTransaction(
            key: key,
            chainPath: ["Nexus"],
            nonce: 0
        )
        let rewardKey = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: rewardKey,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: rewardKey.publicKey),
                delta: 1
            )]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: removed)
        )
        let firstTemplate = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [MiningReward(
                chainPath: ["Nexus"],
                transaction: reward
            )])
        )
        let first = try await service.submitWork(SubmitWorkRequest(
            workID: firstTemplate.workID,
            nonce: 0
        ))
        let removedBlockCID = try XCTUnwrap(first.tipCID)

        let addedFirst = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: addedFirst)
        )
        let addedTemplate = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: addedTemplate.workID,
            nonce: 0
        ))
        let addedBlock = try await process.canonicalTipBlock()
        let addedBlockCID = try BlockHeader(node: addedBlock).rawCID
        let addedSecond = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: addedSecond)
        )
        let descendantTemplate = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: descendantTemplate.workID,
            nonce: 0
        ))
        let addedDescendant = try await process.canonicalTipBlock()
        let addedDescendantCID = try BlockHeader(node: addedDescendant).rawCID

        let stale = try await service.miningTemplate(MiningTemplateRequest())
        let receipt = await service.enqueueCanonicalCommit(ChainCommit(
            tipHash: addedDescendantCID,
            mainChainBlocksAdded: [
                addedBlockCID: addedBlock.height,
                addedDescendantCID: addedDescendant.height,
            ],
            mainChainBlocksRemoved: [removedBlockCID]
        ))
        await receipt.wait()

        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: stale.workID,
                nonce: 0
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }

        let status = await service.status()
        // This synthetic projection says a spent transaction was removed
        // without changing the real canonical state. Authoritative Lattice
        // preflight therefore rejects it instead of resurrecting it.
        XCTAssertEqual(status.mempoolCount, 0)
    }

    func testChildIntentNeedsValidPremineAndSignedParentAnchor() async throws {
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
                blockCID: intent.genesisCID,
                parentWorkAuthorityKey: try childAuthority(for: intent)
            )]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: anchor)
        )

        let normal = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(normal.block.children.node?.count, 0)
        let template = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
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

    func testChildIntentRequiresExactValidPolicyModules() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let validModule = try policySentinelModule()
        let validModuleCID = try WasmPolicyModuleHeader(
            node: validModule
        ).rawCID
        let invalidModule = WasmPolicyModule(bytes: Data([0]))
        let invalidModuleCID = try WasmPolicyModuleHeader(
            node: invalidModule
        ).rawCID
        let policySpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100,
            wasmPolicies: [WasmPolicyRef(
                moduleCID: validModuleCID,
                scope: .transaction
            )]
        )
        let plainSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        )

        func request(
            spec: ChainSpec,
            modules: [WasmPolicyModule]
        ) -> ChildDeployIntentRequest {
            ChildDeployIntentRequest(
                directory: "Policy",
                spec: spec,
                genesisTransactions: [],
                policyModules: modules,
                target: .max,
                timestamp: 1
            )
        }

        let initialStatus = await service.status()
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(request(
                spec: policySpec,
                modules: []
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(request(
                spec: plainSpec,
                modules: [validModule]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(request(
                spec: policySpec,
                modules: [validModule, validModule]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(request(
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100,
                    wasmPolicies: [WasmPolicyRef(
                        moduleCID: invalidModuleCID,
                        scope: .transaction
                    )]
                ),
                modules: [invalidModule]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }
        let oversizedModule = WasmPolicyModule(bytes: Data(
            repeating: 0,
            count: WasmPolicyEvaluator.maxModuleBytes + 1
        ))
        let oversizedCID = try WasmPolicyModuleHeader(
            node: oversizedModule
        ).rawCID
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(request(
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100,
                    wasmPolicies: [WasmPolicyRef(
                        moduleCID: oversizedCID,
                        scope: .transaction
                    )]
                ),
                modules: [oversizedModule]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }
        let rejectedStatus = await service.status()
        XCTAssertEqual(
            rejectedStatus.pendingChildIntents,
            initialStatus.pendingChildIntents
        )
        let broker = try DiskBroker(
            path: process.configuration.storagePath
                .appendingPathComponent("volumes.db").path
        )
        let invalidOwners = await broker.owners(root: invalidModuleCID)
        let oversizedOwners = await broker.owners(root: oversizedCID)
        XCTAssertTrue(invalidOwners.isEmpty)
        XCTAssertTrue(oversizedOwners.isEmpty)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let invalidVolume = await broker.fetchVolumeLocal(root: invalidModuleCID)
        let oversizedVolume = await broker.fetchVolumeLocal(root: oversizedCID)
        XCTAssertNil(invalidVolume)
        XCTAssertNil(oversizedVolume)

        let repeatedReferenceSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100,
            wasmPolicies: [
                WasmPolicyRef(moduleCID: validModuleCID, scope: .transaction),
                WasmPolicyRef(moduleCID: validModuleCID, scope: .action),
            ]
        )
        _ = try await service.createChildDeployIntent(request(
            spec: repeatedReferenceSpec,
            modules: [validModule]
        ))
        let acceptedStatus = await service.status()
        XCTAssertEqual(acceptedStatus.pendingChildIntents, 1)
    }

    func testPolicyChildIntentRetainsModuleAcrossEvictionAndRestart()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-policy-intent-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "6f", count: 32)
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        var service: ChainService? = makeService(process: process!)
        let module = try policySentinelModule()
        let moduleCID = try WasmPolicyModuleHeader(node: module).rawCID
        let intent = try await service!.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Policy",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100,
                    wasmPolicies: [WasmPolicyRef(
                        moduleCID: moduleCID,
                        scope: .action
                    )]
                ),
                genesisTransactions: [],
                policyModules: [module],
                target: .max,
                timestamp: 1
            )
        )
        let broker = try DiskBroker(
            path: storage.appendingPathComponent("volumes.db").path
        )
        let intentOwner = [configuration.nexusGenesisCID, configuration.address.key]
            .joined(separator: ":") + ":child-intents"
        let owners = await broker.owners(root: moduleCID)
        XCTAssertTrue(owners.contains(intentOwner))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let retainedModule = await broker.fetchVolumeLocal(root: moduleCID)
        XCTAssertNotNil(retainedModule)
        try await broker.pin(
            root: configuration.nexusGenesisCID,
            owner: intentOwner
        )

        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        let recoveredStatus = await service!.status()
        XCTAssertEqual(recoveredStatus.pendingChildIntents, 1)
        let restoredModuleOwners = await broker.owners(root: moduleCID)
        let staleOwners = await broker.owners(
            root: configuration.nexusGenesisCID
        )
        XCTAssertTrue(restoredModuleOwners.contains(intentOwner))
        XCTAssertFalse(staleOwners.contains(intentOwner))

        let anchor = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID,
                parentWorkAuthorityKey: try childAuthority(for: intent)
            )]
        )
        _ = try await service!.submitTransaction(
            SubmitTransactionRequest(transaction: anchor)
        )
        let deployment = try await service!.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(
            try deployment.block.children.node?.allKeysAndValues()["Policy"]?
                .rawCID,
            intent.genesisCID
        )
    }

    func testPolicyChildIntentFailsClosedWhenRetainedModuleIsMissing()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-policy-intent-missing-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "7f", count: 32)
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        var service: ChainService? = makeService(process: process!)
        let module = try policySentinelModule()
        let moduleCID = try WasmPolicyModuleHeader(node: module).rawCID
        _ = try await service!.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Policy",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100,
                    wasmPolicies: [WasmPolicyRef(
                        moduleCID: moduleCID,
                        scope: .action
                    )]
                ),
                genesisTransactions: [],
                policyModules: [module],
                target: .max,
                timestamp: 1
            )
        )
        let intentOwner = [configuration.nexusGenesisCID, configuration.address.key]
            .joined(separator: ":") + ":child-intents"
        service = nil
        process = nil
        let broker = try DiskBroker(
            path: storage.appendingPathComponent("volumes.db").path
        )
        try await broker.unpin(
            root: moduleCID,
            owner: intentOwner,
            count: Int.max
        )
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let missing = await broker.fetchVolumeLocal(root: moduleCID)
        XCTAssertNil(missing)

        await XCTAssertThrowsErrorAsync(
            try await ChainProcess.open(configuration: configuration)
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("unexpected recovery error: \(error)")
            }
        }
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
                    blockCID: original.genesisCID,
                    parentWorkAuthorityKey: try childAuthority(for: original)
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

        let normal = try await service.miningTemplate(MiningTemplateRequest())
        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(
                MiningTemplateRequest(mode: .deployment)
            )
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .noDeploymentAvailable)
        }
        XCTAssertEqual(normal.block.transactions.node?.count, 0)
        XCTAssertEqual(normal.block.children.node?.count, 0)
    }

    func testDeploymentAnchorMustMatchPreparedParentAuthority() async throws {
        let service = makeService(process: try await nexusProcess())
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        let wrongAuthority = try XCTUnwrap(ParentWorkAuthorityKey(
            String(repeating: "a", count: ParentWorkAuthorityKey.encodedByteCount)
        ))
        let signer = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: signer,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID,
                    parentWorkAuthorityKey: wrongAuthority
                )]
            )
        ))

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(
                MiningTemplateRequest(mode: .deployment)
            )
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .noDeploymentAvailable)
        }
        let unmatchedStatus = await service.status()
        XCTAssertEqual(unmatchedStatus.pendingChildIntents, 1)

        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID,
                    parentWorkAuthorityKey: try childAuthority(for: intent)
                )]
            )
        ))
        let matched = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(matched.block.transactions.node?.count, 1)
        XCTAssertEqual(
            try matched.block.children.node?.allKeysAndValues()["Sandbox"]?
                .rawCID,
            intent.genesisCID
        )
    }

    func testRewardCannotSilentlyDisplacePendingDeploymentAtTransactionLimit()
        async throws
    {
        let fixture = try await activeChildService(spec: ChainSpec(
            maxNumberOfTransactionsPerBlock: 1,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        ))
        await fixture.service.setParentConsensusReady(true)
        let intent = try await simpleChildIntent(
            service: fixture.service,
            directory: "Grandchild",
            timestamp: 2
        )
        _ = try await fixture.service.submitTransaction(
            SubmitTransactionRequest(transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus", "Payments"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID,
                    parentWorkAuthorityKey: try childAuthority(for: intent)
                )]
            ))
        )
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus", "Payments"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.service.miningCandidate(
                parentCarrier: fixture.parentCarrier,
                parentContentSource: FetcherContentSource(fixture.parent),
                rewards: [MiningReward(
                    chainPath: ["Nexus", "Payments"],
                    transaction: reward
                )],
                mode: .deployment
            )
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .templateTooLarge)
        }
        let status = await fixture.service.status()
        XCTAssertEqual(status.pendingChildIntents, 1)
        XCTAssertEqual(status.mempoolCount, 1)
    }

    func testChildDeploymentRejectsParentOnlyHitBeforeAnchorCanStrand()
        async throws
    {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let childTarget = UInt256.max / UInt256(256)
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1,
            target: childTarget
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID,
                    parentWorkAuthorityKey: try childAuthority(for: intent)
                )]
            )
        ))
        let tipBefore = try BlockHeader(
            node: try await process.canonicalTipBlock()
        ).rawCID
        let template = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(template.searchTarget, childTarget)

        var missNonce: UInt64 = 0
        while template.block.replacingNonce(missNonce).proofOfWorkHash()
            <= childTarget {
            missNonce += 1
        }
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: missNonce
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }
        let tipAfterMiss = try BlockHeader(
            node: try await process.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(tipAfterMiss, tipBefore)
        var status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
        XCTAssertEqual(status.pendingChildIntents, 1)

        var hitNonce: UInt64 = 0
        while template.block.replacingNonce(hitNonce).proofOfWorkHash()
            > childTarget {
            hitNonce += 1
        }
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: hitNonce
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.parentGenesisLinks.map(\.childGenesisCID), [
            intent.genesisCID
        ])
        status = await service.status()
        XCTAssertEqual(status.mempoolCount, 0)
        XCTAssertEqual(status.pendingChildIntents, 0)
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-target-miss-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let genesis = try await process.canonicalTipBlock()
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(process.configuration.processPublicKey)
        )
        let activeChild = try await anchoredChildGenesis(
            parent: process,
            parentGenesis: genesis,
            parentAuthority: parentAuthority,
            transactions: [],
            childTimestamp: 1,
            carrierNonce: 0
        )
        let anchoredParent = try await process.canonicalTipBlock()
        XCTAssertEqual(anchoredParent.nextTarget, UInt256.max / UInt256(2))
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWork: configuration.minimumRootWork,
            issuingAuthorityKey: configuration.processPublicKey
        )
        let admissionsBefore = try await store.stagedAdmissions()
        let leavesBefore = try await process.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 16
        )

        let publishedProofs = PublishedProofs()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let child = try await BlockBuilder.buildBlock(
                    previous: activeChild.block,
                    transactions: [],
                    parentChainBlock: context.parentCarrier,
                    timestamp: context.parentCarrier.timestamp,
                    fetcher: process
                )
                return [DirectChildCandidate(
                    directory: "Payments",
                    block: child,
                    searchTarget: child.target,
                    acquisitionEntries: try await process
                        .durableCandidateEntries(for: child)
                )]
            },
            childProofPublisher: {
                await publishedProofs.record($0)
                throw TestPublicationError.failed
            },
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
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
        let admissionsAfter = try await store.stagedAdmissions()
        let leavesAfter = try await process.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 16
        )
        XCTAssertEqual(admissionsAfter, admissionsBefore)
        XCTAssertEqual(leavesAfter, leavesBefore)
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
        let provisionalContent = await process.content([provisionalWorkID])
        XCTAssertNil(provisionalContent[provisionalWorkID])
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

    func testIncompleteChildIsFilteredBeforeWorkWithoutNetworkFetch() async throws {
        let producer = try await nexusProcess()
        let parent = try await producer.canonicalTipBlock()
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
            fetcher: producer
        )
        let child = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: 2,
            nonce: 0,
            fetcher: producer
        )
        let completeChildEntries = try await producer.durableCandidateEntries(
            for: child
        )
        let childCID = try BlockHeader(node: child).rawCID
        let childData = try XCTUnwrap(child.toData())
        let remote = CountingContentSource(entries: completeChildEntries)
        let consumer = try await nexusProcess(remoteSource: remote)
        let rawChild = try XCTUnwrap(Block(data: childData))
        let service = makeService(
            process: consumer,
            childCandidateProvider: { _ in
                [
                    DirectChildCandidate(
                        directory: "Incomplete",
                        block: rawChild,
                        searchTarget: rawChild.target,
                        acquisitionEntries: [childCID: childData]
                    ),
                    DirectChildCandidate(
                        directory: "Healthy",
                        block: rawChild,
                        searchTarget: rawChild.target,
                        acquisitionEntries: completeChildEntries
                    ),
                ]
            }
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            Set(try XCTUnwrap(template.block.children.node).allKeysAndValues().keys),
            ["Healthy"]
        )
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        let remoteRequestCount = await remote.requestCount()
        XCTAssertEqual(remoteRequestCount, 0)
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
            acceptedBlockPublisher: { _ in },
            maximumChildCandidates: 1
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(Set(try children.allKeysAndValues().keys), ["A"])
    }

    func testNormalMiningIgnoresDeploymentClaimsAndDeploymentRoundsRotate()
        async throws
    {
        let process = try await nexusProcess()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let child = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp,
                    target: .max,
                    fetcher: process
                )
                let entries = try await process.durableCandidateEntries(
                    for: child
                )
                return [
                    DirectChildCandidate(
                        directory: "Healthy",
                        block: child,
                        searchTarget: .max,
                        acquisitionEntries: entries
                    ),
                    DirectChildCandidate(
                        directory: "Poisoned",
                        block: child,
                        searchTarget: UInt256(1),
                        deploymentTarget: UInt256(1),
                        acquisitionEntries: entries
                    ),
                    DirectChildCandidate(
                        directory: "Viable",
                        block: child,
                        searchTarget: UInt256.max / UInt256(2),
                        deploymentTarget: UInt256.max / UInt256(2),
                        acquisitionEntries: entries
                    ),
                ]
            }
        )

        let normal = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            Set(try XCTUnwrap(normal.block.children.node).allKeysAndValues().keys),
            ["Healthy"]
        )
        XCTAssertEqual(normal.searchTarget, .max)

        let first = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let second = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(Set([first.searchTarget, second.searchTarget]), [
            UInt256(1),
            UInt256.max / UInt256(2),
        ])
        for template in [first, second] {
            let directories = Set(
                try XCTUnwrap(template.block.children.node)
                    .allKeysAndValues().keys
            )
            XCTAssertTrue(directories.contains("Healthy"))
            XCTAssertEqual(directories.count, 2)
        }
    }

    func testDeploymentRoundsAlternateLocalAndDescendantSources() async throws {
        let process = try await nexusProcess()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let child = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp,
                    target: UInt256.max / UInt256(2),
                    fetcher: process
                )
                return [DirectChildCandidate(
                    directory: "Existing",
                    block: child,
                    searchTarget: child.target,
                    deploymentTarget: child.target,
                    acquisitionEntries: try await process.durableCandidateEntries(
                        for: child
                    )
                )]
            }
        )
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Local",
            timestamp: 1
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID,
                    parentWorkAuthorityKey: try childAuthority(for: intent)
                )]
            )
        ))

        let local = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let descendant = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let localAgain = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )

        XCTAssertEqual(
            Set(try XCTUnwrap(local.block.children.node).allKeysAndValues().keys),
            ["Local"]
        )
        XCTAssertEqual(local.block.transactions.node?.count, 1)
        XCTAssertEqual(
            Set(try XCTUnwrap(descendant.block.children.node).allKeysAndValues().keys),
            ["Existing"]
        )
        XCTAssertEqual(descendant.block.transactions.node?.count, 0)
        XCTAssertEqual(
            Set(try XCTUnwrap(localAgain.block.children.node).allKeysAndValues().keys),
            ["Local"]
        )
        XCTAssertEqual(localAgain.block.transactions.node?.count, 1)
    }

    func testContextualChildCandidateBindsNewParentCarrierState() async throws {
        let parentProcess = try await nexusProcess()
        let parentGenesis = try await parentProcess.canonicalTipBlock()
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parentProcess.configuration.processPublicKey)
        )
        let childSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 1,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        ).withParentWorkAuthorityKey(parentAuthority)
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
                blockCID: childHeader.rawCID,
                parentWorkAuthorityKey: parentAuthority
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
        let issuedGenesisLink = try await parentProcess.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID
        )
        let genesisLink = try XCTUnwrap(issuedGenesisLink)
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
        try await childHeader.storeBlock(
            fetcher: childProcess,
            storer: childProcess
        )
        try await childGenesis.postState.storeRecursively(storer: childProcess)
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
        await childService.setParentConsensusReady(true)
        await XCTAssertThrowsErrorAsync(
            try await childService.miningTemplate(MiningTemplateRequest())
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .parentCarrierRequired
            )
        }
        let childAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(childProcess.configuration.processPublicKey)
        )
        let unmatchedKey = CryptoUtils.generateKeyPair()
        let unmatchedDeployment = try signedTransaction(
            key: unmatchedKey,
            chainPath: ["Nexus", "Payments"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: unmatchedKey.publicKey),
                delta: -1
            )],
            genesisActions: [GenesisAction(
                directory: "Orphan",
                blockCID: childHeader.rawCID,
                parentWorkAuthorityKey: childAuthority
            )],
            fee: 1
        )
        let ordinary = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus", "Payments"]
        )
        await XCTAssertThrowsErrorAsync(
            try await childService.submitTransaction(
                SubmitTransactionRequest(transaction: unmatchedDeployment)
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .invalidState)
        }
        _ = try await childService.submitTransaction(
            SubmitTransactionRequest(transaction: ordinary)
        )
        let livenessCandidate = try await childService.miningCandidate(
            parentCarrier: nextParentCarrier,
            parentContentSource: FetcherContentSource(parentProcess),
            rewards: []
        )
        let selectedTransactions = try await livenessCandidate.block.transactions
            .resolve(fetcher: childProcess)
        XCTAssertEqual(selectedTransactions.node?.count, 1)
        XCTAssertEqual(
            try selectedTransactions.node?.allKeysAndValues()["0"]?.rawCID,
            try VolumeImpl<Transaction>(node: ordinary).rawCID
        )

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
                parentContentSource: FetcherContentSource(parentProcess),
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

    private func nexusProcess(
        remoteSource: (any ContentSource)? = nil
    ) async throws -> ChainProcess {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try await ChainProcess.open(
            configuration: NodeConfiguration(
                chainPath: ["Nexus"],
                minimumRootWork: UInt256(1),
                storagePath: directory,
                privateKeyHex: String(repeating: "01", count: 32)
            ),
            remoteSource: remoteSource
        )
    }

    private func makeService(
        process: ChainProcess,
        childCandidateProvider: @escaping ChildCandidateProvider = { _ in [] },
        childProofPublisher: @escaping ChildProofPublisher = { _ in },
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher = { _ in },
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
        timestamp: Int64,
        target: UInt256 = .max
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
            target: target,
            timestamp: timestamp
        ))
    }

    private func childAuthority(
        for intent: ChildDeployIntentResponse
    ) throws -> ParentWorkAuthorityKey {
        try XCTUnwrap(intent.genesisBlock.spec.node?.parentWorkAuthorityKey)
    }

    private struct InheritedForkFixture {
        let process: ChainProcess
        let service: ChainService
        let parentAuthority: ParentWorkAuthorityKey
        let activeCID: String
        let activeCarrierCID: String
        let siblingCID: String
        let siblingCarrierCID: String
        let siblingHeader: BlockHeader
        let siblingPackage: AuthenticatedChildPackage
        let siblingTransaction: Transaction
        let lateCID: String
        let lateCarrierCID: String
        let lateHeader: BlockHeader
        let latePackage: AuthenticatedChildPackage
    }

    private struct AnchoredChildGenesis {
        let block: Block
        let header: BlockHeader
        let carrierCID: String
        let package: AuthenticatedChildPackage
    }

    private struct ActiveChildServiceFixture {
        let parent: ChainProcess
        let service: ChainService
        let parentCarrier: Block
    }

    private func activeChildService(
        spec: ChainSpec
    ) async throws -> ActiveChildServiceFixture {
        let parent = try await nexusProcess()
        let parentGenesis = try await parent.canonicalTipBlock()
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parent.configuration.processPublicKey)
        )
        let child = try await anchoredChildGenesis(
            parent: parent,
            parentGenesis: parentGenesis,
            parentAuthority: parentAuthority,
            transactions: [],
            childTimestamp: 1,
            carrierNonce: 0,
            spec: spec
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: directory,
            privateKeyHex: String(repeating: "02", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parent.configuration.processPublicKey,
                host: "127.0.0.1",
                port: 4002
            )
        ))
        try await storeChildGenesis(child, in: process)
        let bootstrap = try await process.admit(
            child.header,
            authenticatedChildPackage: child.package
        )
        XCTAssertTrue(bootstrap.decision.isAccepted)
        let resolvedParentCarrier = try await BlockHeader(
            rawCID: child.carrierCID,
            node: nil,
            encryptionInfo: nil
        ).resolve(fetcher: parent)
        let parentCarrier = try XCTUnwrap(
            resolvedParentCarrier.node
        )
        return ActiveChildServiceFixture(
            parent: parent,
            service: makeService(process: process),
            parentCarrier: parentCarrier
        )
    }

    private func inheritedForkFixture() async throws -> InheritedForkFixture {
        let parent = try await nexusProcess()
        let parentGenesis = try await parent.canonicalTipBlock()
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parent.configuration.processPublicKey)
        )
        let siblingTransaction = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus", "Payments"]
        )
        let active = try await anchoredChildGenesis(
            parent: parent,
            parentGenesis: parentGenesis,
            parentAuthority: parentAuthority,
            transactions: [],
            childTimestamp: 1,
            carrierNonce: 0
        )
        let sibling = try await anchoredChildGenesis(
            parent: parent,
            parentGenesis: parentGenesis,
            parentAuthority: parentAuthority,
            transactions: [siblingTransaction],
            childTimestamp: 2,
            carrierNonce: 1
        )
        let late = try await anchoredChildGenesis(
            parent: parent,
            parentGenesis: parentGenesis,
            parentAuthority: parentAuthority,
            transactions: [siblingTransaction],
            childTimestamp: 3,
            carrierNonce: 2
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-inherited-fifo-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: directory,
            privateKeyHex: String(repeating: "02", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parent.configuration.processPublicKey,
                host: "127.0.0.1",
                port: 4002
            )
        ))
        try await storeChildGenesis(active, in: process)
        try await storeChildGenesis(sibling, in: process)
        try await storeChildGenesis(late, in: process)
        let bootstrap = try await process.admit(
            active.header,
            authenticatedChildPackage: active.package
        )
        XCTAssertTrue(bootstrap.decision.isAccepted)
        return InheritedForkFixture(
            process: process,
            service: makeService(process: process),
            parentAuthority: parentAuthority,
            activeCID: active.header.rawCID,
            activeCarrierCID: active.carrierCID,
            siblingCID: sibling.header.rawCID,
            siblingCarrierCID: sibling.carrierCID,
            siblingHeader: sibling.header,
            siblingPackage: sibling.package,
            siblingTransaction: siblingTransaction,
            lateCID: late.header.rawCID,
            lateCarrierCID: late.carrierCID,
            lateHeader: late.header,
            latePackage: late.package
        )
    }

    private func anchoredChildGenesis(
        parent: ChainProcess,
        parentGenesis: Block,
        parentAuthority: ParentWorkAuthorityKey,
        transactions: [Transaction],
        childTimestamp: Int64,
        carrierNonce: UInt64,
        spec: ChainSpec = NexusGenesis.spec
    ) async throws -> AnchoredChildGenesis {
        for transaction in transactions {
            try await VolumeImpl<Transaction>(node: transaction).storeRecursively(
                storer: parent
            )
        }
        let block = try await BlockBuilder.buildChildGenesis(
            spec: spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: parentGenesis.postState,
            transactions: transactions,
            timestamp: childTimestamp,
            target: UInt256.max,
            fetcher: parent
        )
        let header = try BlockHeader(node: block)
        let authorization = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: "Payments",
                blockCID: header.rawCID,
                parentWorkAuthorityKey: parentAuthority
            )]
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parent
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            children: ["Payments": block],
            timestamp: parentGenesis.timestamp + 1,
            nonce: carrierNonce,
            fetcher: parent
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let parentAdmission = try await parent.admit(carrierHeader)
        let carrierLink = try XCTUnwrap(parentAdmission.parentCarrierLink)
        let issuedGenesisLink = try await parent.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: header.rawCID
        )
        let genesisLink = try XCTUnwrap(issuedGenesisLink)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: parent
        )
        return AnchoredChildGenesis(
            block: block,
            header: header,
            carrierCID: carrierHeader.rawCID,
            package: AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentCarrierLink: carrierLink,
                    parentGenesisLink: genesisLink
                )
            )
        )
    }

    private func storeChildGenesis(
        _ child: AnchoredChildGenesis,
        in process: ChainProcess
    ) async throws {
        try await child.header.storeBlock(fetcher: process, storer: process)
        try await child.block.postState.storeRecursively(storer: process)
    }

    private func verifiedWorkContribution(
        id: String,
        work: UInt64
    ) throws -> VerifiedWorkContribution {
        try JSONDecoder().decode(
            VerifiedWorkContribution.self,
            from: Data("{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8)
        )
    }
}

private enum TestPublicationError: Error {
    case failed
}

private actor TaskStartLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor BlockingContentSource: ContentSource {
    private struct Waiter {
        let entries: [String: Data]
        let continuation: CheckedContinuation<[String: Data], Never>
    }

    private let blockedCID: String
    private var entries: [String: Data] = [:]
    private var blocked = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchWaiters: [Waiter] = []

    init(blockedCID: String) {
        self.blockedCID = blockedCID
    }

    func setEntries(_ entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        let found = entries.filter { cids.contains($0.key) }
        guard cids.contains(blockedCID) else { return found }

        blocked = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        guard !released else { return found }
        return await withCheckedContinuation { continuation in
            fetchWaiters.append(Waiter(
                entries: found,
                continuation: continuation
            ))
        }
    }

    func waitForBlockedFetch() async {
        guard !blocked else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedFetch() {
        released = true
        let pending = fetchWaiters
        fetchWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: waiter.entries)
        }
    }
}

private actor CanonicalCommitLatch {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let entryWaiters = self.entryWaiters
        self.entryWaiters.removeAll()
        for waiter in entryWaiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters { waiter.resume() }
    }
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

private actor CountingContentSource: ContentSource {
    private let entries: [String: Data]
    private var requests = 0

    init(entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        requests += 1
        return entries.filter { cids.contains($0.key) }
    }

    func requestCount() -> Int {
        requests
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
    fee: UInt64 = 0,
    nonce: UInt64 = 0
) throws -> Transaction {
    let body = transactionBody(
        key: key,
        chainPath: chainPath,
        accountActions: accountActions,
        genesisActions: genesisActions,
        fee: fee,
        nonce: nonce
    )
    let header = try HeaderImpl(node: body)
    let signature = try XCTUnwrap(TransactionSigning.sign(
        bodyHeader: header,
        privateKeyHex: key.privateKey
    ))
    return Transaction(signatures: [key.publicKey: signature], body: header)
}

private func policySentinelModule() throws -> WasmPolicyModule {
    WasmPolicyModule(bytes: try XCTUnwrap(Data(
        base64Encoded: "AGFzbQEAAAABDAJgAX8Bf2ACf38BfwMDAgABBQMBAAEGBwF/AUGACAsHUwQGbWVtb3J5AgANbGF0dGljZV9hbGxvYwAAHGxhdHRpY2VfdmFsaWRhdGVfdHJhbnNhY3Rpb24AARdsYXR0aWNlX3ZhbGlkYXRlX2FjdGlvbgABCnICEQEBfyMAIQEjACAAaiQAIAELXgECfyABQQ9JBEBBAA8LAkADQCACIAFBD2tLDQFBACEDAkADQCADQQ9GBEBBAQ8LIAAgAmogA2otAABBECADai0AAEcNASADQQFqIQMMAAsLIAJBAWohAgwACwtBAAsLFQEAQRALD3BvbGljeS1zZW50aW5lbA=="
    )))
}

private func transactionBody(
    key: (privateKey: String, publicKey: String),
    chainPath: [String],
    accountActions: [AccountAction] = [],
    genesisActions: [GenesisAction] = [],
    fee: UInt64 = 0,
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
        fee: fee,
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
