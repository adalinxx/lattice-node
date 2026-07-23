import Crypto
import Ivy
@testable import Lattice
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

final class ChainProcessTests: XCTestCase {
    func testLocalTransactionVolumeSurvivesRestartAndUnretainsOnRemoval()
        async throws
    {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let transaction = try signedGenesisAnchorTransaction(
            directory: "Local",
            childGenesisCID: try HeaderImpl<PublicKey>(
                node: PublicKey(key: "local-mempool-child")
            ).rawCID
        )
        let owner = [config.nexusGenesisCID, config.address.key]
            .joined(separator: ":") + ":durable-mempool"

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        let transactionCID = try await process!.persistLocalTransaction(
            transaction,
            addedAt: 123
        )
        var loaded = try await process!.localTransactions()
        XCTAssertEqual(loaded.map(\.transactionCID), [transactionCID])
        XCTAssertEqual(loaded.map(\.addedAt), [123])

        process = nil
        process = try await ChainProcess.open(configuration: config)
        loaded = try await process!.localTransactions()
        XCTAssertEqual(loaded.map(\.transactionCID), [transactionCID])
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        var owners = await broker.owners(root: transactionCID)
        XCTAssertTrue(owners.contains(owner))

        try await process!.removeLocalTransaction(transactionCID)
        var isEmpty = try await process!.localTransactions().isEmpty
        XCTAssertTrue(isEmpty)
        owners = await broker.owners(root: transactionCID)
        XCTAssertTrue(owners.isEmpty)
        process = nil
        process = try await ChainProcess.open(configuration: config)
        isEmpty = try await process!.localTransactions().isEmpty
        owners = await broker.owners(root: transactionCID)
        XCTAssertTrue(isEmpty)
        XCTAssertTrue(owners.isEmpty)
    }

    func testOpenFailsClosedWhenLocalTransactionVolumeIsMissing() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let transaction = try signedGenesisAnchorTransaction(
            directory: "Missing",
            childGenesisCID: try HeaderImpl<PublicKey>(
                node: PublicKey(key: "missing-mempool-child")
            ).rawCID
        )
        let transactionCID = try VolumeImpl<Transaction>(node: transaction).rawCID
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store.persistLocalMempoolTransaction(
            transactionCID: transactionCID,
            addedAt: 1
        )

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("expected missing local transaction Volume")
        } catch {
            XCTAssertEqual(
                error as? ChainProcessError,
                .missingMaterializedVolume(transactionCID)
            )
        }
    }

    func testLiveMempoolPinsTrackCurrentRootsAndClearOnRestart() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let first = try signedGenesisAnchorTransaction(
            directory: "First",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let second = try signedGenesisAnchorTransaction(
            directory: "Second",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        let firstRoot = try await process!.persistPeerTransaction(first)
        let secondRoot = try await process!.persistPeerTransaction(second)
        try await process!.updateLiveMempoolRoots(
            adding: [firstRoot, secondRoot],
            removing: []
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let owner = [config.nexusGenesisCID, config.address.key]
            .joined(separator: ":") + ":live-mempool"
        var firstOwners = await broker.owners(root: firstRoot)
        var secondOwners = await broker.owners(root: secondRoot)
        XCTAssertEqual(firstOwners, Set([owner]))
        XCTAssertEqual(secondOwners, Set([owner]))

        try await process!.updateLiveMempoolRoots(
            adding: [],
            removing: [firstRoot]
        )
        firstOwners = await broker.owners(root: firstRoot)
        secondOwners = await broker.owners(root: secondRoot)
        XCTAssertTrue(firstOwners.isEmpty)
        XCTAssertEqual(secondOwners, Set([owner]))

        process = nil
        process = try await ChainProcess.open(configuration: config)
        secondOwners = await broker.owners(root: secondRoot)
        XCTAssertTrue(secondOwners.isEmpty)
        process = nil
    }

    func testTransientHierarchyContentIsAvailableOnlyAsACompleteVolume()
        async throws
    {
        let directory = temporaryDirectory()
        let process = try await ChainProcess.open(configuration: try configuration(
            path: ["Nexus"],
            storage: directory
        ))
        let durableHeader = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "durable")
        )
        let provisionalHeader = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "provisional")
        )
        let missingHeader = try HeaderImpl<PublicKey>(node: PublicKey(key: "missing"))
        let durable = try durableHeader.mapToData()
        let provisional = try provisionalHeader.mapToData()
        let nestedHeader = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "provisional-member")
        )
        let nested = try nestedHeader.mapToData()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        try await BrokerStorer(broker: broker).store(volume: SerializedVolume(
            root: durableHeader.rawCID,
            entries: [durableHeader.rawCID: durable]
        ))
        let source = ChainProcessIvyContentSource(
            process: process,
            transientRootVolume: { rootCID in
                rootCID == provisionalHeader.rawCID
                    ? SerializedVolume(
                        root: provisionalHeader.rawCID,
                        entries: [
                            provisionalHeader.rawCID: provisional,
                            nestedHeader.rawCID: nested,
                        ]
                    )
                    : nil
            }
        )

        let provisionalVolume = await source.volume(
            rootCID: provisionalHeader.rawCID,
            maxDataBytes: 1_024
        )
        XCTAssertEqual(provisionalVolume, [
            ContentEntry(cid: provisionalHeader.rawCID, data: provisional),
            ContentEntry(cid: nestedHeader.rawCID, data: nested),
        ].sorted { $0.cid < $1.cid })

        let durableVolume = await source.volume(
            rootCID: durableHeader.rawCID,
            maxDataBytes: 1_024
        )
        XCTAssertEqual(durableVolume, [
            ContentEntry(cid: durableHeader.rawCID, data: durable),
        ])

        let missingVolume = await source.volume(
            rootCID: missingHeader.rawCID,
            maxDataBytes: 1_024
        )
        XCTAssertTrue(missingVolume.isEmpty)

        let selectedEntries = await source.content(
            rootCID: provisionalHeader.rawCID,
            cids: [provisionalHeader.rawCID],
            maxDataBytes: 1_024
        )
        XCTAssertTrue(selectedEntries.isEmpty)
    }

    func testNexusOpenBootstrapsExactGenesisAndRecoversIt() async throws {
        let directory = temporaryDirectory()
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: try configuration(path: ["Nexus"], storage: directory)
        )

        var status = await process!.status()
        XCTAssertEqual(status.phase, .active)
        XCTAssertEqual(status.tipCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(status.height, 0)

        process = nil
        process = try await ChainProcess.open(
            configuration: try configuration(path: ["Nexus"], storage: directory)
        )
        status = await process!.status()
        XCTAssertEqual(status.phase, .active)
        XCTAssertEqual(status.tipCID, NexusGenesis.expectedBlockHash)
    }

    func testNexusBootstrapNeverFetchesRemoteContent() async throws {
        let remote = BatchRecordingContentSource(entries: [:])
        _ = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            ),
            remoteSource: remote
        )

        let requests = await remote.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testAuthenticatedPackageUsesOneBatchedFallbackWave() async throws {
        let fixture = try await childBootstrapFixture()
        let proofEntry = try XCTUnwrap(
            fixture.package.package.proof.entries.first
        )
        let fallback = BatchRecordingContentSource(entries: [
            "first": Data([0x01]),
            "second": Data([0x02]),
        ])
        let source = try ChainProcess.attemptContentSource(
            package: fixture.package.package,
            fallback: fallback
        )

        let entries = await source.fetch([
            proofEntry.cid,
            "first",
            "second",
        ])
        let requests = await fallback.requests()
        XCTAssertEqual(entries[proofEntry.cid], proofEntry.data)
        XCTAssertEqual(entries["first"], Data([0x01]))
        XCTAssertEqual(entries["second"], Data([0x02]))
        XCTAssertEqual(requests, [Set(["first", "second"])])
    }

    func testAttemptFetchersNeverShareAnAcquisitionScope() throws {
        let fallback = BatchRecordingContentSource(entries: [:])
        let first = try ChainProcess.attemptFetcher(
            package: nil,
            fallback: fallback
        )
        let second = try ChainProcess.attemptFetcher(
            package: nil,
            fallback: fallback
        )

        XCTAssertFalse(first === second)
    }

    func testAttemptContentSourceRejectsUnauthenticatedOrConflictingBytes()
        async throws {
        let fixture = try await childBootstrapFixture()
        let proofEntry = try XCTUnwrap(
            fixture.package.package.proof.entries.first
        )
        let fallback = BatchRecordingContentSource(entries: [:])

        XCTAssertThrowsError(try ChainProcess.attemptContentSource(
            package: nil,
            acquisitionEntries: ["unexpected": Data()],
            fallback: fallback
        )) { error in
            XCTAssertEqual(
                error as? ChainProcessError,
                .malformedAuthenticatedChildProof
            )
        }

        XCTAssertThrowsError(try ChainProcess.attemptContentSource(
            package: fixture.package.package,
            acquisitionEntries: [
                proofEntry.cid: proofEntry.data + Data([0x00]),
            ],
            fallback: fallback
        )) { error in
            XCTAssertEqual(
                error as? ChainProcessError,
                .malformedAuthenticatedChildProof
            )
        }
    }

    func testRemoteAdmissionRequiresExplicitPermission() async throws {
        let producer = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            )
        )
        let genesis = try await producer.canonicalTipBlock()
        let candidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 0,
            fetcher: producer
        )
        let header = try BlockHeader(node: candidate)
        let remote = BatchRecordingContentSource(entries:
            try await blockContentEntries(header, fetcher: producer)
        )
        let consumer = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            ),
            remoteSource: remote
        )
        let unresolved = BlockHeader(
            rawCID: header.rawCID,
            node: nil,
            encryptionInfo: nil
        )

        _ = try? await consumer.admit(unresolved)
        let localRequests = await remote.requests()
        XCTAssertTrue(localRequests.isEmpty)

        let outcome = try await consumer.admit(
            unresolved,
            allowsRemoteAcquisition: true
        )
        XCTAssertTrue(outcome.decision.isAccepted)
        let remoteRequests = await remote.requests()
        XCTAssertFalse(remoteRequests.isEmpty)
    }

    func testAdmissionStagesHierarchyArtifactsAcrossReopen() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(config.processPublicKey)
        )
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        let genesis = try await process!.canonicalTipBlock()
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: genesis.postState,
            timestamp: 1,
            target: UInt256.max,
            fetcher: process!
        )
        let childCID = try BlockHeader(node: child).rawCID
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process!
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [authorization],
            children: ["Payments": child],
            timestamp: 1,
            nonce: 0,
            fetcher: process!
        )
        let carrierHeader = try BlockHeader(node: carrier)

        let outcome = try await process!.admit(carrierHeader)
        XCTAssertTrue(outcome.decision.isAccepted)
        let carrierLink = try XCTUnwrap(outcome.parentCarrierLink)
        process = nil

        process = try await ChainProcess.open(configuration: config)
        let persistedCarrier = try await process!.issuedParentCarrierLink(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierLink.rootCID
        )
        let persistedGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID
        )
        XCTAssertEqual(persistedCarrier, carrierLink)
        XCTAssertEqual(persistedGenesis?.parentPath, ["Nexus"])
        XCTAssertEqual(persistedGenesis?.directory, "Payments")
        XCTAssertEqual(persistedGenesis?.childGenesisCID, childCID)
    }

    func testAcceptedOrphanPromotesGenesisLinkOnLiveRetryAfterPredecessorArrival()
        async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(config.processPublicKey)
        )
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        let genesis = try await process!.canonicalTipBlock()
        let predecessor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 1,
            fetcher: process!
        )
        let predecessorHeader = try BlockHeader(node: predecessor)
        // Make the orphan's predecessor resolvable without admitting it yet.
        try await predecessorHeader.storeBlock(fetcher: process!, storer: process!)

        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: predecessor.postState,
            timestamp: 2,
            target: UInt256.max,
            fetcher: process!
        )
        let childCID = try BlockHeader(node: child).rawCID
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process!
        )
        let orphanCandidate = try await BlockBuilder.buildBlock(
            previous: predecessor,
            transactions: [authorization],
            children: ["Payments": child],
            timestamp: 2,
            nonce: 2,
            fetcher: process!
        )
        let orphan = try XCTUnwrap(BlockBuilder.mine(
            block: orphanCandidate,
            target: orphanCandidate.target,
            maxAttempts: 128
        ))
        let orphanHeader = try BlockHeader(node: orphan)

        let first = try await process!.admit(orphanHeader)
        guard case .acceptedSide = first.decision else {
            return XCTFail("expected accepted orphan, got \(first.decision)")
        }
        XCTAssertEqual(first.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: orphanHeader.rawCID,
            predecessorCID: predecessorHeader.rawCID
        ))
        XCTAssertNil(first.parentCarrierLink)
        let prepared = try await process!.prepareChildProofs(
            for: orphan,
            capacity: 16
        )
        XCTAssertEqual(prepared.map(\.directory), ["Payments"])
        let beforePredecessor = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID
        )
        XCTAssertNil(beforePredecessor)
        let beforeAttachment = await process!.parentSecuringWorkSnapshot()
        XCTAssertNil(
            beforeAttachment?.sourceWork(forBlock: orphanHeader.rawCID)
                .work(forGrind: orphanHeader.rawCID)
        )

        let predecessorOutcome = try await process!.admit(predecessorHeader)
        XCTAssertTrue(predecessorOutcome.decision.isAccepted)
        // NodeNetworkRuntime re-enqueues this durable side candidate after its
        // predecessor arrives; the process therefore resolves it as a duplicate.
        let retry = try await process!.admit(orphanHeader)
        XCTAssertEqual(retry.decision, .duplicate)
        XCTAssertEqual(retry.parentCarrierLink?.carrierCID, orphanHeader.rawCID)
        XCTAssertNil(retry.sameChainPredecessor)
        let promotedGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID
        )
        XCTAssertEqual(
            promotedGenesis?.parentPath,
            ["Nexus"]
        )
        let export = await process!.parentSecuringWorkSnapshot()
        let exported = try XCTUnwrap(export)
        XCTAssertEqual(
            exported.sourceWork(forBlock: orphanHeader.rawCID).grindIDs,
            [orphanHeader.rawCID]
        )
        XCTAssertEqual(
            exported.work(forBlock: orphanHeader.rawCID)
                .work(forGrind: orphanHeader.rawCID),
            workForTarget(orphan.target)
        )

        process = nil
        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        let staged = try await store!.stagedAdmissions()
        XCTAssertEqual(staged.count, 3)
        XCTAssertEqual(staged.filter { admission in
            admission.batch.facts.contains { fact in
                guard case .block(let block) = fact else { return false }
                return block.blockHash == orphanHeader.rawCID
            }
        }.count, 1)
        store = nil
        process = try await ChainProcess.open(configuration: config)
        let reopenedGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID
        )
        XCTAssertEqual(
            reopenedGenesis?.parentPath,
            ["Nexus"]
        )
        let reopened = await process!.parentSecuringWorkSnapshot()
        let reopenedExport = try XCTUnwrap(reopened)
        XCTAssertEqual(reopenedExport, exported)
    }

    func testPureParentDescendantsDoNotReweightChildBeforeOrAfterRestart()
        async throws {
        let parentConfiguration = try configuration(
            path: ["Nexus"],
            storage: temporaryDirectory()
        )
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parentConfiguration.processPublicKey)
        )
        let parent = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let parentGenesis = try await parent.canonicalTipBlock()

        let competingChild = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: parentGenesis.postState,
            timestamp: 3_600_000,
            target: UInt256.max / UInt256(2),
            fetcher: parent
        )
        let competingChildHeader = try BlockHeader(node: competingChild)
        let competingAuthorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: competingChildHeader.rawCID
        )
        try await VolumeImpl<Transaction>(node: competingAuthorization).storeRecursively(
            storer: parent
        )
        let competingCarrierCandidate = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [competingAuthorization],
            children: ["Payments": competingChild],
            timestamp: 3_600_000,
            nonce: 1,
            fetcher: parent
        )
        let competingCarrier = try XCTUnwrap(BlockBuilder.mine(
            block: competingCarrierCandidate,
            target: competingChild.target,
            maxAttempts: 128
        ))
        let competingCarrierHeader = try BlockHeader(node: competingCarrier)
        let competingCarrierAdmission = try await parent.admit(
            competingCarrierHeader
        )
        XCTAssertTrue(competingCarrierAdmission.decision.isAccepted)

        var canonical = competingCarrier
        for step in 2...5 {
            canonical = try await BlockBuilder.buildBlock(
                previous: canonical,
                timestamp: Int64(step * 3_600_000),
                nonce: UInt64(step),
                fetcher: parent
            )
            let outcome = try await parent.admit(BlockHeader(node: canonical))
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonicalCID = try BlockHeader(node: canonical).rawCID

        let predecessor = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            timestamp: 3_600_000,
            nonce: 10,
            fetcher: parent
        )
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(fetcher: parent, storer: parent)

        let sideChild = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: predecessor.postState,
            timestamp: 7_200_000,
            target: UInt256.max,
            fetcher: parent
        )
        let sideChildHeader = try BlockHeader(node: sideChild)
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: sideChildHeader.rawCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parent
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: predecessor,
            transactions: [authorization],
            children: ["Payments": sideChild],
            timestamp: 7_200_000,
            nonce: 11,
            fetcher: parent
        )
        let carrierHeader = try BlockHeader(node: carrier)

        let orphan = try await parent.admit(carrierHeader)
        guard case .acceptedSide = orphan.decision else {
            return XCTFail("expected accepted side carrier, got \(orphan.decision)")
        }
        XCTAssertEqual(orphan.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: carrierHeader.rawCID,
            predecessorCID: predecessorHeader.rawCID
        ))
        let prepared = try await parent.prepareChildProofs(
            for: carrier,
            capacity: 16
        )
        XCTAssertEqual(prepared.map(\.directory), ["Payments"])
        let beforeAttachment = await parent.parentSecuringWorkSnapshot()
        XCTAssertNil(
            beforeAttachment?.sourceWork(forBlock: carrierHeader.rawCID)
                .work(forGrind: carrierHeader.rawCID)
        )

        let predecessorOutcome = try await parent.admit(predecessorHeader)
        XCTAssertTrue(predecessorOutcome.decision.isAccepted)
        // NodeNetworkRuntime performs this durable-descendant retry live when
        // the predecessor arrives; it must resolve as a duplicate, not a side admission.
        let retry = try await parent.admit(carrierHeader)
        XCTAssertEqual(retry.decision, .duplicate)
        let carrierLink = try XCTUnwrap(retry.parentCarrierLink)
        XCTAssertEqual(carrierLink.carrierCID, carrierHeader.rawCID)
        XCTAssertNil(retry.sameChainPredecessor)
        let afterAttachment = await parent.parentSecuringWorkSnapshot()
        let promotedExport = try XCTUnwrap(afterAttachment)
        XCTAssertEqual(
            promotedExport.sourceWork(forBlock: carrierHeader.rawCID).grindIDs,
            [carrierHeader.rawCID]
        )

        let sideOne = try await BlockBuilder.buildBlock(
            previous: carrier,
            timestamp: 10_800_000,
            nonce: 12,
            fetcher: parent
        )
        let sideOneHeader = try BlockHeader(node: sideOne)
        let sideOneOutcome = try await parent.admit(sideOneHeader)
        guard case .acceptedSide = sideOneOutcome.decision else {
            return XCTFail("expected accepted side descendant, got \(sideOneOutcome.decision)")
        }
        let sideTwo = try await BlockBuilder.buildBlock(
            previous: sideOne,
            timestamp: 14_400_000,
            nonce: 13,
            fetcher: parent
        )
        let sideTwoHeader = try BlockHeader(node: sideTwo)
        let sideTwoOutcome = try await parent.admit(sideTwoHeader)
        guard case .acceptedSide = sideTwoOutcome.decision else {
            return XCTFail("expected accepted side descendant, got \(sideTwoOutcome.decision)")
        }
        let parentStatus = await parent.status()
        XCTAssertEqual(parentStatus.tipCID, canonicalCID)

        let durableProofs = try await parent.durableDirectChildProofs(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let durable = try XCTUnwrap(durableProofs.first)
        XCTAssertEqual(durable.childCID, sideChildHeader.rawCID)
        let exportedSnapshot = await parent.parentSecuringWorkSnapshot()
        let exported = try XCTUnwrap(exportedSnapshot)
        XCTAssertEqual(
            exported.sourceWork(forBlock: carrierHeader.rawCID).grindIDs,
            [carrierHeader.rawCID]
        )
        for (cid, block) in [
            (carrierHeader.rawCID, carrier),
            (sideOneHeader.rawCID, sideOne),
            (sideTwoHeader.rawCID, sideTwo),
        ] {
            XCTAssertEqual(
                exported.sourceWork(forBlock: cid)
                    .work(forGrind: cid),
                workForTarget(block.target)
            )
        }

        let competingCarrierLink = try await parent.issuedParentCarrierLink(
            carrierCID: competingCarrierHeader.rawCID,
            rootCID: competingCarrierHeader.rawCID
        )
        let competingGenesisLink = try await parent.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: competingChildHeader.rawCID
        )
        let competingProof = try await ChildBlockProof.generate(
            rootHeader: competingCarrierHeader,
            childDirectory: "Payments",
            fetcher: parent
        )
        let competingPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: competingProof,
                parentCarrierLink: try XCTUnwrap(competingCarrierLink),
                parentGenesisLink: try XCTUnwrap(competingGenesisLink)
            ),
            acquisitionEntries: try await blockContentEntries(
                competingChildHeader,
                fetcher: parent
            )
        )
        let genesisLink = try await parent.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: sideChildHeader.rawCID
        )
        let sidePackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: durable.proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: try XCTUnwrap(genesisLink)
            ),
            acquisitionEntries: durable.acquisitionEntries
        )

        let childConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: "03", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parentConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: 4001
            )
        )
        var child: ChainProcess? = try await ChainProcess.open(
            configuration: childConfiguration
        )
        let competingAdmission = try await child!.admit(
            competingChildHeader,
            authenticatedChildPackage: competingPackage
        )
        XCTAssertTrue(competingAdmission.decision.isAccepted)
        let sideAdmission = try await child!.admit(
            sideChildHeader,
            authenticatedChildPackage: sidePackage
        )
        XCTAssertTrue(sideAdmission.decision.isAccepted)
        let beforeReorg = await child!.status()
        XCTAssertEqual(beforeReorg.tipCID, competingChildHeader.rawCID)

        let update = try await child!.applyInheritedWorkSnapshot(
            exported,
            from: parentConfiguration.processPublicKey
        )
        XCTAssertFalse(update?.canonicalChanged ?? false)
        let live = await child!.status()
        XCTAssertEqual(live.tipCID, competingChildHeader.rawCID)
        let parentAfterChildReorg = await parent.status()
        XCTAssertEqual(parentAfterChildReorg.tipCID, canonicalCID)

        child = nil
        child = try await ChainProcess.open(configuration: childConfiguration)
        let reopened = await child!.status()
        XCTAssertEqual(reopened.tipCID, competingChildHeader.rawCID)
        let replay = try await child!.applyInheritedWorkSnapshot(
            exported,
            from: parentConfiguration.processPublicKey
        )
        XCTAssertNil(replay)
        let replayed = await child!.status()
        XCTAssertEqual(replayed.tipCID, competingChildHeader.rawCID)
    }

    func testDurableParentFactActivatesWhenExactEdgeArrivesForAcceptedChild()
        async throws {
        let fixture = try await directProjectionArrivalFixture()
        var child: ChainProcess? = try await ChainProcess.open(
            configuration: fixture.configuration
        )
        try await admitProjectionIncumbent(fixture, to: child!)
        let competing = try await child!.admit(
            fixture.competingHeader,
            authenticatedChildPackage: fixture.acceptingPackage
        )
        XCTAssertTrue(competing.decision.isAccepted)
        var status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.incumbentHeader.rawCID)

        let stored = try await child!.applyInheritedWorkSnapshot(
            fixture.parentWork(revision: 1, includeAcceptingCarrier: false),
            from: fixture.parentAuthority.value
        )
        XCTAssertNil(stored)
        status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.incumbentHeader.rawCID)

        let lateEdge = try await child!.admit(
            fixture.competingHeader,
            authenticatedChildPackage: fixture.targetMissPackage
        )
        XCTAssertEqual(lateEdge.decision, .carrier)
        XCTAssertTrue(lateEdge.inheritedWorkChanged)
        status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.competingHeader.rawCID)

        child = nil
        child = try await ChainProcess.open(configuration: fixture.configuration)
        status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.competingHeader.rawCID)
    }

    func testConflictingLateExactBindingIsRejectedWithoutBecomingDurable()
        async throws {
        let fixture = try await directProjectionArrivalFixture()
        var child: ChainProcess? = try await ChainProcess.open(
            configuration: fixture.configuration
        )
        try await admitProjectionIncumbent(fixture, to: child!)
        let competing = try await child!.admit(
            fixture.competingHeader,
            authenticatedChildPackage: fixture.acceptingPackage
        )
        XCTAssertTrue(competing.decision.isAccepted)

        let incumbentGrind = try XCTUnwrap(
            fixture.incumbentPackage.package.parentCarrierLink
        ).carrierCID
        let stored = try await child!.applyInheritedWorkSnapshot(
            InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    fixture.targetMissCarrierCID: WorkMeasure(contribution(
                        id: incumbentGrind,
                        work: 16
                    )),
                ]
            ),
            from: fixture.parentAuthority.value
        )
        XCTAssertNil(stored)

        do {
            _ = try await child!.admit(
                fixture.competingHeader,
                authenticatedChildPackage: fixture.targetMissPackage
            )
            XCTFail("accepted an exact edge that relocates an existing grind")
        } catch {
            XCTAssertEqual(
                error as? ChainProcessError,
                .malformedAuthenticatedChildProof
            )
        }
        var status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.incumbentHeader.rawCID)

        child = nil
        var store: NodeStore? = try testNodeStore(
            databasePath: fixture.configuration.storagePath
                .appendingPathComponent("state.db"),
            nexusGenesisCID: fixture.configuration.nexusGenesisCID,
            chainPath: fixture.configuration.chainPath,
            minimumRootWork: fixture.configuration.minimumRootWork,
            spawningParentKey: fixture.parentAuthority.value,
            issuingAuthorityKey: fixture.configuration.processPublicKey
        )
        let bindings = try await store!.incomingParentCarrierBlockCIDs(
            forChildBlockCID: fixture.competingHeader.rawCID
        )
        XCTAssertEqual(bindings, [fixture.acceptingCarrierCID])

        store = nil
        child = try await ChainProcess.open(configuration: fixture.configuration)
        status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.incumbentHeader.rawCID)
    }

    func testAcceptedChildActivatesEveryPreviouslyBoundParentCarrier()
        async throws {
        let fixture = try await directProjectionArrivalFixture()
        var child: ChainProcess? = try await ChainProcess.open(
            configuration: fixture.configuration
        )
        try await admitProjectionIncumbent(fixture, to: child!)

        let stored = try await child!.applyInheritedWorkSnapshot(
            fixture.parentWork(revision: 1, includeAcceptingCarrier: true),
            from: fixture.parentAuthority.value
        )
        XCTAssertNil(stored)
        let earlyEdge = try await child!.admit(
            fixture.competingHeader,
            authenticatedChildPackage: fixture.targetMissPackage
        )
        XCTAssertEqual(earlyEdge.decision, .carrier)
        var status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.incumbentHeader.rawCID)

        let competing = try await child!.admit(
            fixture.competingHeader,
            authenticatedChildPackage: fixture.acceptingPackage
        )
        XCTAssertTrue(competing.decision.isAccepted)
        status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.competingHeader.rawCID)
        let liveSnapshot = await child!.parentSecuringWorkSnapshot()
        let liveExport = try XCTUnwrap(liveSnapshot)
        XCTAssertTrue(
            liveExport.sourceWork(forBlock: fixture.competingHeader.rawCID)
                .grindIDs.isSuperset(of: [fixture.lateGrind, fixture.acceptingGrind])
        )

        child = nil
        child = try await ChainProcess.open(configuration: fixture.configuration)
        status = await child!.status()
        XCTAssertEqual(status.tipCID, fixture.competingHeader.rawCID)
        let reopenedSnapshot = await child!.parentSecuringWorkSnapshot()
        let reopenedExport = try XCTUnwrap(reopenedSnapshot)
        XCTAssertTrue(
            reopenedExport.sourceWork(forBlock: fixture.competingHeader.rawCID)
                .grindIDs.isSuperset(of: [fixture.lateGrind, fixture.acceptingGrind])
        )
    }

    func testAcceptedChildOrphanRecoversIncomingEvidenceForPackageLessRetry()
        async throws {
        let fixture = try await childBootstrapFixture()
        let parentAuthority = try XCTUnwrap(
            fixture.configuration.parentEndpoint.flatMap {
                ParentWorkAuthorityKey($0.publicKey)
            }
        )
        var child: ChainProcess? = try await ChainProcess.open(
            configuration: fixture.configuration
        )
        let bootstrap = try await child!.admit(
            fixture.childHeader,
            authenticatedChildPackage: fixture.package
        )
        XCTAssertTrue(bootstrap.decision.isAccepted)
        let genesis = try await child!.canonicalTipBlock()

        let predecessor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 2,
            nonce: 1,
            fetcher: child!
        )
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(fetcher: child!, storer: child!)
        let orphan = try await BlockBuilder.buildBlock(
            previous: predecessor,
            timestamp: 3,
            nonce: 2,
            fetcher: child!
        )
        let orphanHeader = try BlockHeader(node: orphan)

        func package(
            for block: Block,
            header: BlockHeader,
            timestamp: Int64
        ) async throws -> (AuthenticatedChildPackage, String) {
            let source = ChainProcessTestContentStore()
            try await LatticeState.emptyHeader.storeRecursively(storer: source)
            try await header.storeBlock(fetcher: child!, storer: source)
            let carrier = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Payments": block],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: source
            )
            let carrierHeader = try BlockHeader(node: carrier)
            await source.store(entries: [
                carrierHeader.rawCID: try XCTUnwrap(carrier.toData()),
            ])
            let proof = try await ChildBlockProof.generate(
                rootHeader: carrierHeader,
                childDirectory: "Payments",
                fetcher: source
            )
            var entries = try await blockContentEntries(header, fetcher: child!)
            entries[carrierHeader.rawCID] = try XCTUnwrap(carrier.toData())
            return (
                AuthenticatedChildPackage(
                    package: ChildValidationPackage(
                        proof: proof,
                        parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                            {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                            """),
                        parentGenesisLink: nil
                    ),
                    acquisitionEntries: entries
                ),
                carrierHeader.rawCID
            )
        }

        let (predecessorPackage, _) = try await package(
            for: predecessor,
            header: predecessorHeader,
            timestamp: 10
        )
        let (orphanPackage, orphanCarrierCID) = try await package(
            for: orphan,
            header: orphanHeader,
            timestamp: 11
        )
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                orphanCarrierCID: WorkMeasure(contribution(
                    id: orphanCarrierCID,
                    work: 64
                )),
            ]
        )
        let storedParentWork = try await child!.applyInheritedWorkSnapshot(
            inherited,
            from: parentAuthority.value
        )
        XCTAssertNil(storedParentWork)

        let first = try await child!.admit(
            orphanHeader,
            authenticatedChildPackage: orphanPackage
        )
        guard case .acceptedSide = first.decision else {
            return XCTFail("expected accepted child orphan, got \(first.decision)")
        }
        XCTAssertEqual(first.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: orphanHeader.rawCID,
            predecessorCID: predecessorHeader.rawCID
        ))
        XCTAssertNil(first.parentCarrierLink)

        child = nil
        child = try await ChainProcess.open(configuration: fixture.configuration)
        let predecessorOutcome = try await child!.admit(
            predecessorHeader,
            authenticatedChildPackage: predecessorPackage
        )
        XCTAssertTrue(predecessorOutcome.decision.isAccepted)

        // This is the exact runtime wake-up shape: only the durable orphan CID
        // is retained, so ChainProcess must recover its authenticated package.
        let retry = try await child!.admit(orphanHeader)
        XCTAssertEqual(retry.decision, .duplicate)
        XCTAssertEqual(retry.parentCarrierLink?.carrierCID, orphanHeader.rawCID)
        XCTAssertEqual(retry.parentCarrierLink?.rootCID, orphanCarrierCID)
        XCTAssertNil(retry.sameChainPredecessor)
        let liveSnapshot = await child!.parentSecuringWorkSnapshot()
        let liveExport = try XCTUnwrap(liveSnapshot)
        XCTAssertEqual(
            liveExport.sourceWork(forBlock: orphanHeader.rawCID)
                .work(forGrind: orphanCarrierCID),
            UInt256(64)
        )

        child = nil
        child = try await ChainProcess.open(configuration: fixture.configuration)
        let reopened = await child!.status()
        XCTAssertEqual(reopened.tipCID, orphanHeader.rawCID)
        let reopenedSnapshot = await child!.parentSecuringWorkSnapshot()
        let reopenedExport = try XCTUnwrap(reopenedSnapshot)
        XCTAssertEqual(
            reopenedExport.sourceWork(forBlock: orphanHeader.rawCID)
                .work(forGrind: orphanCarrierCID),
            UInt256(64)
        )
    }

    func testAcceptedLeafPageStartsWithDurableGenesis() async throws {
        let process = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            )
        )

        let page = try await process.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 1
        )
        XCTAssertEqual(page.blockCIDs, [NexusGenesis.expectedBlockHash])
        let continuation = try await process.acceptedLeafPage(
            afterCID: NexusGenesis.expectedBlockHash,
            snapshotSequence: page.snapshotSequence,
            limit: 1
        )
        XCTAssertTrue(continuation.blockCIDs.isEmpty)
    }

    func testEmptyChildOpensReadyToRelayWithoutInventingGenesis() async throws {
        let directory = temporaryDirectory()
        let process = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus", "Payments"],
                storage: directory
            )
        )

        let status = await process.status()
        XCTAssertEqual(status.phase, .awaitingGenesis)
        XCTAssertNil(status.tipCID)
        XCTAssertNil(status.height)
    }

    func testSuccessorAttachmentWaitsForChildGenesis() async throws {
        let fixture = try await childBootstrapFixture()
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        await source.store(entries: fixture.package.acquisitionEntries)
        try await fixture.childHeader.storeRecursively(storer: source as any Storer)
        let genesis = try XCTUnwrap(fixture.childHeader.node)
        let successor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 2,
            nonce: 1,
            fetcher: source
        )
        let successorHeader = try BlockHeader(node: successor)
        try await successorHeader.storeBlock(fetcher: source, storer: source)
        let parentCarrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": successor],
            timestamp: 3,
            target: UInt256.max,
            fetcher: source
        )
        let parentCarrierHeader = try BlockHeader(node: parentCarrier)
        let proof = try await ChildBlockProof.generate(
            rootHeader: parentCarrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        var entries = try await blockContentEntries(
            successorHeader,
            fetcher: source
        )
        entries[parentCarrierHeader.rawCID] = try XCTUnwrap(
            parentCarrier.toData()
        )
        let successorPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(parentCarrierHeader.rawCID)","rootCID":"\(parentCarrierHeader.rawCID)"}
                    """),
                parentGenesisLink: nil
            ),
            acquisitionEntries: entries
        )
        let process = try await ChainProcess.open(
            configuration: fixture.configuration
        )

        let early = try await process.admit(
            successorHeader,
            authenticatedChildPackage: successorPackage
        )
        XCTAssertEqual(early.decision, .unavailable(nil))
        XCTAssertEqual(
            early.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: successorHeader.rawCID,
                predecessorCID: fixture.childHeader.rawCID
            )
        )

        let bootstrap = try await process.admit(
            fixture.childHeader,
            authenticatedChildPackage: fixture.package
        )
        XCTAssertTrue(bootstrap.decision.isAccepted)
        let retry = try await process.admit(
            successorHeader,
            authenticatedChildPackage: successorPackage
        )
        XCTAssertTrue(retry.decision.isAccepted)
        XCTAssertNil(retry.sameChainPredecessor)
    }

    func testPreBootstrapInheritedWorkSelectsSiblingGenesisAfterReopen()
        async throws {
        let fixture = try await childBootstrapFixture()
        let parentAuthority = try XCTUnwrap(
            fixture.configuration.parentEndpoint.flatMap {
                ParentWorkAuthorityKey($0.publicKey)
            }
        )
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let sibling = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 3,
            target: UInt256.max,
            fetcher: source
        )
        let siblingHeader = try BlockHeader(node: sibling)
        let parentCarrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": sibling],
            timestamp: 4,
            target: UInt256.max,
            fetcher: source
        )
        let parentCarrierHeader = try BlockHeader(node: parentCarrier)
        try await parentCarrierHeader.storeRecursively(storer: source as any Storer)
        let siblingProof = try await ChildBlockProof.generate(
            rootHeader: parentCarrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        var siblingEntries = try await blockContentEntries(
            siblingHeader,
            fetcher: source
        )
        siblingEntries[parentCarrierHeader.rawCID] = try XCTUnwrap(
            parentCarrier.toData()
        )
        let siblingPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: siblingProof,
                parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(parentCarrierHeader.rawCID)","rootCID":"\(parentCarrierHeader.rawCID)"}
                    """),
                parentGenesisLink: try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(siblingHeader.rawCID)"}
                    """)
            ),
            acquisitionEntries: siblingEntries
        )
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                parentCarrierHeader.rawCID: WorkMeasure(contribution(
                    id: parentCarrierHeader.rawCID,
                    work: 100
                )),
            ]
        )

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: fixture.configuration
        )
        do {
            _ = try await process!.applyInheritedWorkSnapshot(
                inherited,
                from: String(repeating: "0", count: ParentWorkAuthorityKey.encodedByteCount)
            )
            XCTFail("unconfigured parent authority unexpectedly updated work")
        } catch let error as NodeStoreError {
            guard case .invalidConfiguration = error else {
                return XCTFail("unexpected authority error: \(error)")
            }
        }
        let preBootstrapCommit = try await process!.applyInheritedWorkSnapshot(
            inherited,
            from: parentAuthority.value
        )
        XCTAssertNil(preBootstrapCommit)

        let first = try await process!.admit(
            BlockHeader(
                rawCID: fixture.childHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            authenticatedChildPackage: fixture.package
        )
        XCTAssertTrue(first.decision.isAccepted)
        let firstStatus = await process!.status()
        XCTAssertEqual(firstStatus.tipCID, fixture.childHeader.rawCID)

        let second = try await process!.admit(
            BlockHeader(
                rawCID: siblingHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            authenticatedChildPackage: siblingPackage
        )
        XCTAssertTrue(second.decision.isAccepted)
        let secondStatus = await process!.status()
        XCTAssertEqual(secondStatus.tipCID, siblingHeader.rawCID)

        process = nil
        process = try await ChainProcess.open(configuration: fixture.configuration)
        let reopenedStatus = await process!.status()
        XCTAssertEqual(reopenedStatus.tipCID, siblingHeader.rawCID)
    }

    func testInheritedWorkRawFramesSurviveRestartAndReweightForkChoice()
        async throws {
        let fixture = try await childBootstrapFixture()
        let configuration = fixture.configuration
        let parentAuthority = try XCTUnwrap(
            configuration.parentEndpoint.flatMap {
                ParentWorkAuthorityKey($0.publicKey)
            }
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let bootstrap = try await process!.admit(
            fixture.childHeader,
            authenticatedChildPackage: fixture.package
        )
        XCTAssertTrue(bootstrap.decision.isAccepted)

        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let sibling = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 3,
            target: UInt256.max,
            fetcher: source
        )
        let firstHeader = fixture.childHeader
        let secondHeader = try BlockHeader(node: sibling)
        let siblingCarrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": sibling],
            timestamp: 4,
            target: UInt256.max,
            fetcher: source
        )
        let siblingCarrierHeader = try BlockHeader(node: siblingCarrier)
        try await siblingCarrierHeader.storeRecursively(storer: source as any Storer)
        let siblingProof = try await ChildBlockProof.generate(
            rootHeader: siblingCarrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        var siblingEntries = try await blockContentEntries(
            secondHeader,
            fetcher: source
        )
        siblingEntries[siblingCarrierHeader.rawCID] = try XCTUnwrap(
            siblingCarrier.toData()
        )
        let siblingPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: siblingProof,
                parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(siblingCarrierHeader.rawCID)","rootCID":"\(siblingCarrierHeader.rawCID)"}
                    """),
                parentGenesisLink: try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(secondHeader.rawCID)"}
                    """)
            ),
            acquisitionEntries: siblingEntries
        )
        let secondAdmission = try await process!.admit(
            BlockHeader(rawCID: secondHeader.rawCID, node: nil, encryptionInfo: nil),
            authenticatedChildPackage: siblingPackage
        )
        XCTAssertTrue(secondAdmission.decision.isAccepted)

        let firstCarrierCID = fixture.rootCID
        let secondCarrierCID = siblingCarrierHeader.rawCID
        let firstGrind = fixture.rootCID
        let secondGrind = siblingCarrierHeader.rawCID
        let branchOnlyGrind = secondHeader.rawCID
        let relocation = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                secondCarrierCID: WorkMeasure(contribution(
                    id: firstGrind,
                    work: 100
                )),
            ]
        )
        do {
            _ = try await process!.applyInheritedWorkSnapshot(
                relocation,
                from: parentAuthority.value
            )
            XCTFail("Core accepted one grind at a second child block")
        } catch {
            XCTAssertEqual(
                error as? ChainProcessError,
                .malformedAuthenticatedChildProof
            )
        }
        process = nil
        var preflightStore: NodeStore? = try testNodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWork: configuration.minimumRootWork,
            spawningParentKey: parentAuthority.value,
            issuingAuthorityKey: configuration.processPublicKey
        )
        let rejectedSnapshot = try await preflightStore!.inheritedWorkSnapshot()
        XCTAssertNil(rejectedSnapshot)
        preflightStore = nil
        process = try await ChainProcess.open(configuration: configuration)

        let initial = InheritedWorkSnapshot(
            revision: 10,
            workByBlock: [
                firstCarrierCID: WorkMeasure(contribution(id: firstGrind, work: 5)),
                secondCarrierCID: WorkMeasure(contribution(id: secondGrind, work: 10)),
            ]
        )
        let firstOnly = InheritedWorkSnapshot(
            revision: initial.revision,
            workByBlock: [
                firstCarrierCID: initial.sourceWork(forBlock: firstCarrierCID),
            ]
        )
        let secondOnly = InheritedWorkSnapshot(
            revision: initial.revision,
            workByBlock: [
                secondCarrierCID: initial.sourceWork(forBlock: secondCarrierCID),
            ]
        )
        let firstFrames = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: firstOnly
            )
        )
        let firstFrame = try XCTUnwrap(firstFrames.first)
        let secondFrames = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: secondOnly
            )
        )
        let secondFrame = try XCTUnwrap(secondFrames.first)
        let frames = try XCTUnwrap(
            NodeNetworkRuntime.inheritedWorkPushPayloads(
                snapshot: initial,
                maximumPayloadBytes: max(firstFrame.count, secondFrame.count)
            )
        )
        XCTAssertGreaterThan(frames.count, 1)
        for payload in Array(frames.reversed()) + [try XCTUnwrap(frames.first)] {
            let push = try InheritedWorkPushMessage.decoded(payload)
            _ = try await process!.applyInheritedWorkSnapshot(
                push.snapshot,
                from: parentAuthority.value
            )
        }

        let initialStatus = await process!.status()
        let initialTip = try XCTUnwrap(initialStatus.tipCID)
        XCTAssertEqual(initialTip, secondHeader.rawCID)

        func decodedPush(_ snapshot: InheritedWorkSnapshot) throws -> InheritedWorkSnapshot {
            try InheritedWorkPushMessage.decoded(
                InheritedWorkPushMessage(
                    snapshot: snapshot
                ).encoded()
            ).snapshot
        }

        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        let firstReopenStatus = await process!.status()
        XCTAssertEqual(firstReopenStatus.tipCID, initialTip)

        let dominated = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [
                firstCarrierCID: WorkMeasure(contribution(id: firstGrind, work: 7)),
            ]
        )
        let dominatedCommit = try await process!.applyInheritedWorkSnapshot(
            decodedPush(dominated),
            from: parentAuthority.value
        )
        XCTAssertFalse(dominatedCommit?.canonicalChanged ?? true)

        process = nil
        var store: NodeStore? = try testNodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWork: configuration.minimumRootWork,
            spawningParentKey: parentAuthority.value,
            issuingAuthorityKey: configuration.processPublicKey
        )
        let afterDominatedSnapshot = try await store!.inheritedWorkSnapshot()
        let afterDominated = try XCTUnwrap(afterDominatedSnapshot)
        XCTAssertEqual(afterDominated.revision, 10)
        XCTAssertEqual(
            afterDominated.sourceWork(forBlock: firstCarrierCID)
                .work(forGrind: firstGrind),
            UInt256(7)
        )
        XCTAssertEqual(
            afterDominated.sourceWork(forBlock: secondCarrierCID)
                .work(forGrind: secondGrind),
            UInt256(10)
        )
        store = nil

        process = try await ChainProcess.open(configuration: configuration)
        let secondReopenStatus = await process!.status()
        XCTAssertEqual(secondReopenStatus.tipCID, initialTip)

        let strengthening = InheritedWorkSnapshot(
            revision: 11,
            workByBlock: [
                secondCarrierCID: WorkMeasure(contribution(id: secondGrind, work: 12)),
            ]
        )
        let sharedCommit = try await process!.applyInheritedWorkSnapshot(
            decodedPush(strengthening),
            from: parentAuthority.value
        )
        XCTAssertFalse(sharedCommit?.canonicalChanged ?? true)
        let strengthenedStatus = await process!.status()
        XCTAssertEqual(strengthenedStatus.tipCID, initialTip)

        let branchOnly = InheritedWorkSnapshot(
            revision: 12,
            workByBlock: [
                firstCarrierCID: WorkMeasure(contribution(
                    id: branchOnlyGrind,
                    work: 1_000
                )),
            ]
        )
        let reorg = try await process!.applyInheritedWorkSnapshot(
            decodedPush(branchOnly),
            from: parentAuthority.value
        )
        XCTAssertTrue(reorg?.canonicalChanged ?? false)
        let reorgStatus = await process!.status()
        XCTAssertEqual(reorgStatus.tipCID, firstHeader.rawCID)

        process = nil
        store = try testNodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            minimumRootWork: configuration.minimumRootWork,
            spawningParentKey: parentAuthority.value,
            issuingAuthorityKey: configuration.processPublicKey
        )
        let recoveredSnapshot = try await store!.inheritedWorkSnapshot()
        let recovered = try XCTUnwrap(recoveredSnapshot)
        XCTAssertEqual(
            recovered.sourceWork(forBlock: firstCarrierCID)
                .work(forGrind: firstGrind),
            UInt256(7)
        )
        XCTAssertEqual(
            recovered.sourceWork(forBlock: secondCarrierCID)
                .work(forGrind: secondGrind),
            UInt256(12)
        )
        store = nil

        process = try await ChainProcess.open(configuration: configuration)
        let finalReopenStatus = await process!.status()
        XCTAssertEqual(finalReopenStatus.tipCID, firstHeader.rawCID)
    }

    func testSecondProcessCannotOpenTheSameStorageDirectory() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let process = try await ChainProcess.open(configuration: config)
        defer { _ = process }

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("second writer unexpectedly opened the same storage")
        } catch let error as ChainProcessError {
            XCTAssertEqual(error, .storageInUse)
        }
    }

    func testReopenFailsWhenAStagedMaterializedVolumeIsMissing() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store.stage(
            ChainAdmissionBatch(facts: [.block(ChainBlockFact(
                blockHash: NexusGenesis.expectedBlockHash,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: "state",
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            ))]),
            volumeRoots: ["missing-volume"]
        )

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("reopen unexpectedly accepted a missing materialized volume")
        } catch let error as ChainProcessError {
            XCTAssertEqual(error, .missingMaterializedVolume("missing-volume"))
        }
    }

    func testReopenRejectsASecondNexusGenesisRoot() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let volume = try VolumeImpl<Transaction>(node: signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: NexusGenesis.expectedBlockHash
        ))
        try await volume.store(storer: BrokerStorer(broker: broker))
        let root = volume.rawCID
        func genesis(_ hash: String) -> ChainAdmissionFact {
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: root,
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            ))
        }
        try await store.stage(
            ChainAdmissionBatch(facts: [
                genesis(NexusGenesis.expectedBlockHash),
                genesis("forged-nexus-genesis"),
            ]),
            volumeRoots: [root]
        )

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("reopen unexpectedly accepted a second Nexus genesis")
        } catch let error as ChainProcessError {
            XCTAssertEqual(error, .invalidNexusGenesis)
        }
    }

#if DEBUG
    func testBlockedChildProofAcquisitionDoesNotBlockAdmission() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let blockedCID = "blocked-carrier"
        let source = BlockingContentSource(blockedCID: blockedCID)
        let candidateCID: String

        do {
            let process = try await ChainProcess.open(
                configuration: config,
                remoteSource: source
            )
            let genesis = try await process.canonicalTipBlock()
            let candidate = try await BlockBuilder.buildBlock(
                previous: genesis,
                timestamp: 1,
                nonce: 0,
                fetcher: process
            )
            let candidateHeader = try BlockHeader(node: candidate)
            candidateCID = candidateHeader.rawCID
            await source.setEntries(try await blockContentEntries(
                candidateHeader,
                fetcher: process
            ))

            let holder = Task {
                try await process.prepareChildProofs(
                    for: BlockHeader(
                        rawCID: blockedCID,
                        node: nil,
                        encryptionInfo: nil
                    ),
                    directories: ["Payments"]
                )
            }
            await source.waitForBlockedFetch()

            let admission = Task {
                return try await process.admit(candidateHeader)
            }
            let admissionFinished = expectation(
                description: "admission bypasses blocked proof acquisition"
            )
            Task {
                _ = try? await admission.value
                admissionFinished.fulfill()
            }
            await fulfillment(of: [admissionFinished], timeout: 1)
            let admitted = try await admission.value
            XCTAssertTrue(admitted.decision.isAccepted)
            let statusWhileBlocked = await process.status()
            XCTAssertEqual(statusWhileBlocked.tipCID, candidateCID)

            await source.releaseBlockedFetch()
            try await holder.value
            let status = await process.status()
            XCTAssertEqual(status.tipCID, candidateCID)
            XCTAssertEqual(status.height, 1)
        }

        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 2)
        XCTAssertTrue(staged.contains { admission in
            admission.batch.facts.contains { fact in
                guard case .block(let block) = fact else { return false }
                return block.blockHash == candidateCID
            }
        })
    }
#endif

    func testCancellationAfterRetentionCompletesDurableStage() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let admissionStorage = NodeAdmissionStorage(
            storage: BrokerStorer(broker: broker)
        )
        let transaction = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: admissionStorage)
        let root = volume.rawCID
        let batch = ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: root,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: root,
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            )),
        ])
        let retained = TestLatch()
        let continueStage = TestLatch()
        let task = Task {
            try await ChainProcess.persist(
                batch,
                admissionStorage: admissionStorage,
                store: store,
                broker: broker,
                retentionScope: "cancellation-test",
                pendingChildProofRoutes: [],
                pendingChildProofCapacity: 1,
                afterRetainingRoots: {
                    await retained.signal()
                    await continueStage.wait()
                }
            )
        }

        await retained.wait()
        task.cancel()
        await continueStage.signal()
        try await task.value

        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.volumeRoots, [root])
        let retainedRoots = try await broker.retainedRoots(
            scope: "cancellation-test"
        )
        XCTAssertEqual(retainedRoots, [root])
        let evicted = try await broker.evictUnpinned()
        XCTAssertEqual(evicted, 0)
        let stored = await broker.fetchVolumeLocal(root: root)
        XCTAssertNotNil(stored)
    }

    func testFailedStageLeavesSafeRetainedOrphanUntilStartupReconciliation()
        async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let admissionStorage = NodeAdmissionStorage(
            storage: BrokerStorer(broker: broker)
        )
        func batch(for root: String) -> ChainAdmissionBatch {
            ChainAdmissionBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: root,
                    parentBlockHash: nil,
                    blockHeight: 0,
                    postStateCID: root,
                    prevStateCID: "previous-state",
                    specCID: "spec",
                    target: "target",
                    nextTarget: "next-target",
                    timestamp: 0,
                    stateDiff: .empty
                )),
            ])
        }
        let durableTransaction = try signedGenesisAnchorTransaction(
            directory: "Durable",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let durableVolume = try VolumeImpl<Transaction>(node: durableTransaction)
        try await durableVolume.store(storer: admissionStorage)
        let durableRoot = durableVolume.rawCID
        try await ChainProcess.persist(
            batch(for: durableRoot),
            admissionStorage: admissionStorage,
            store: store,
            broker: broker,
            retentionScope: "failed-stage-test",
            pendingChildProofRoutes: [],
            pendingChildProofCapacity: 1
        )

        let transaction = try signedGenesisAnchorTransaction(
            directory: "Failed",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: admissionStorage)
        let root = volume.rawCID

        do {
            try await ChainProcess.persist(
                batch(for: root),
                admissionStorage: admissionStorage,
                store: store,
                broker: broker,
                retentionScope: "failed-stage-test",
                pendingChildProofRoutes: [PendingChildProofRoute(
                    carrierCID: "not-in-batch",
                    directory: "Payments"
                )],
                pendingChildProofCapacity: 1
            )
            XCTFail("invalid staging route unexpectedly succeeded")
        } catch let error as NodeStoreError {
            guard case .invalidConfiguration = error else {
                return XCTFail("expected invalid staging route, got \(error)")
            }
        } catch {
            XCTFail("expected invalid staging route, got \(error)")
        }

        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.volumeRoots, [durableRoot])
        let retainedRoots = try await broker.retainedRoots(scope: "failed-stage-test")
        XCTAssertEqual(retainedRoots, [durableRoot, root].sorted())
        let evicted = try await broker.evictUnpinned()
        XCTAssertEqual(evicted, 0)
        let stored = await broker.fetchVolumeLocal(root: root)
        XCTAssertNotNil(stored)
        let durableStored = await broker.fetchVolumeLocal(root: durableRoot)
        XCTAssertNotNil(durableStored)
    }

    func testReopenDropsRetainedRootWithoutStagedAdmission() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        process = nil

        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let scope = [config.nexusGenesisCID, config.address.key].joined(separator: ":")
        let durableRoots = try await broker.retainedRoots(scope: scope)
        let orphan = try VolumeImpl<Transaction>(node: signedGenesisAnchorTransaction(
            directory: "Orphan",
            childGenesisCID: NexusGenesis.expectedBlockHash
        ))
        try await orphan.store(storer: BrokerStorer(broker: broker))
        let orphanRoot = orphan.rawCID
        try await broker.mergeRetainedRoots(scope: scope, roots: [orphanRoot])
        let retainedBeforeReopen = try await broker.retainedRoots(scope: scope)
        XCTAssertEqual(
            retainedBeforeReopen,
            Array(Set(durableRoots + [orphanRoot])).sorted()
        )

        process = try await ChainProcess.open(configuration: config)
        let status = await process!.status()
        let retainedAfterReopen = try await broker.retainedRoots(scope: scope)
        let evicted = try await broker.evictUnpinned()
        let orphanStored = await broker.fetchVolumeLocal(root: orphanRoot)
        XCTAssertEqual(status.tipCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(retainedAfterReopen, durableRoots)
        XCTAssertGreaterThanOrEqual(evicted, 1)
        XCTAssertNil(orphanStored)
    }

    func testChildBootstrapsFromHierarchyProofWithoutOverlaySupplier() async throws {
        let fixture = try await childBootstrapFixture()
        XCTAssertTrue(fixture.proof.entries.contains { $0.cid == fixture.childHeader.rawCID })
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: fixture.configuration
        )

        let outcome = try await process!.admit(
            BlockHeader(
                rawCID: fixture.childHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            authenticatedChildPackage: fixture.package
        )

        XCTAssertTrue(
            outcome.decision.isAccepted,
            "unexpected admission outcome: \(outcome.decision)"
        )
        let status = await process!.status()
        XCTAssertEqual(status.phase, .active)
        process = nil

        let store = try testNodeStore(
            databasePath: fixture.configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: fixture.configuration.nexusGenesisCID,
            chainPath: fixture.configuration.chainPath,
            minimumRootWork: fixture.configuration.minimumRootWork,
            spawningParentKey: try XCTUnwrap(
                fixture.configuration.parentEndpoint?.publicKey
            ),
            issuingAuthorityKey: fixture.configuration.processPublicKey
        )
        let persisted = try await store.incomingCarrierEvidence(
            childCID: fixture.childHeader.rawCID,
            directory: "Payments",
            rootCID: fixture.rootCID
        )
        let evidence = try XCTUnwrap(persisted)
        XCTAssertEqual(try evidence.proof.serialize(), try fixture.proof.serialize())
        XCTAssertEqual(evidence.acquisitionEntries, fixture.canonicalEntries)
    }

    func testPreparedProofRetryDoesNotRefetchOrEvictPendingCarriers() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(config.processPublicKey)
        )
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        process = nil

        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source as any Storer)
        let hop = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Payments"],
            capacity: 16
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Payments",
                child: child,
                proof: hop,
                acquisitionEntries: try await blockContentEntries(
                    BlockHeader(node: child),
                    fetcher: source
                )
            )],
            capacity: 16
        )
        try await store!.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                    """),
                carrierEvidence: nil,
                parentGenesisLinks: [try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(try BlockHeader(node: child).rawCID)"}
                    """)]
            )
        )
        store = nil

        let remote = BatchRecordingContentSource(entries: [:])
        process = try await ChainProcess.open(
            configuration: config,
            remoteSource: remote
        )
        let retriedDirectories = try await process!.retryPendingChildProofs(
            carrierCID: carrierHeader.rawCID
        )
        XCTAssertEqual(retriedDirectories, ["Payments"])
        let requestsAfterRecovery = await remote.requests()
        let pendingAfterRecovery = try await process!
            .pendingChildProofCarrierCIDs()
        XCTAssertTrue(requestsAfterRecovery.isEmpty)
        XCTAssertTrue(pendingAfterRecovery.isEmpty)

        for index in 0..<16 {
            try await process!.prepareChildProofs(
                for: BlockHeader(
                    rawCID: "missing-\(index)",
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: ["Missing"]
            )
        }
        let requestsBeforePreparedRetry = await remote.requests()
        let pendingBeforePreparedRetry = try await process!
            .pendingChildProofCarrierCIDs()
        try await process!.prepareChildProofs(
            for: BlockHeader(
                rawCID: carrierHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            directories: ["Payments"]
        )
        let requestsAfterPreparedRetry = await remote.requests()
        let pendingAfterPreparedRetry = try await process!
            .pendingChildProofCarrierCIDs()
        XCTAssertEqual(requestsAfterPreparedRetry, requestsBeforePreparedRetry)
        XCTAssertEqual(pendingAfterPreparedRetry, pendingBeforePreparedRetry)
        XCTAssertEqual(pendingAfterPreparedRetry.count, 16)
        let recovered = try await process!.durableDirectChildProofs(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        XCTAssertEqual(recovered.map(\.directory), ["Payments"])
        XCTAssertEqual(
            recovered.map(\.childCID),
            [try BlockHeader(node: child).rawCID]
        )
        XCTAssertEqual(recovered.first?.proof.rootCID, carrierHeader.rawCID)
    }

    func testPreparedProofEvictedDuringBlockedRetryStaysPending() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(config.processPublicKey)
        )
        _ = try await ChainProcess.open(configuration: config)

        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Prepared": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source as any Storer)
        let hop = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Prepared",
            fetcher: source
        )

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Prepared", "Waiting"],
            capacity: 16
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Prepared",
                child: child,
                proof: hop,
                acquisitionEntries: try await blockContentEntries(
                    BlockHeader(node: child),
                    fetcher: source
                )
            )],
            capacity: 16
        )
        store = nil

        let remote = BlockingContentSource(blockedCID: carrierHeader.rawCID)
        await remote.setEntries(await source.allEntries())
        let liveProcess = try await ChainProcess.open(
            configuration: config,
            remoteSource: remote
        )

        var evictionCarriers: [Block] = []
        for index in 0..<16 {
            let evictionCarrier = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Evict": child],
                timestamp: Int64(index + 10),
                target: UInt256.max,
                fetcher: source
            )
            try await BlockHeader(node: evictionCarrier).storeRecursively(
                storer: source as any Storer
            )
            evictionCarriers.append(evictionCarrier)
            try await BlockHeader(node: evictionCarrier).storeBlock(
                fetcher: source,
                storer: liveProcess
            )
        }

        let retry = Task {
            try await liveProcess.retryPendingChildProofs(
                carrierCID: carrierHeader.rawCID
            )
        }
        await remote.waitForBlockedFetch()
        for evictionCarrier in evictionCarriers {
            _ = try await liveProcess.prepareChildProofs(
                for: evictionCarrier,
                capacity: 16
            )
        }
        await remote.releaseBlockedFetch()

        let completed = try await retry.value
        let pending = try await liveProcess.pendingChildProofCarrierCIDs()
        let issued = try await liveProcess.issuedChildEvidenceSummaries(
            directory: "Prepared",
            after: nil,
            limit: 1
        )
        let durable = try await liveProcess.durableDirectChildProofs(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        XCTAssertEqual(completed, ["Waiting"])
        XCTAssertEqual(pending, [carrierHeader.rawCID])
        XCTAssertTrue(issued.isEmpty)
        XCTAssertTrue(durable.isEmpty)
    }

    func testRestartRetriesPendingProofForNonTipCarrier() async throws {
        let source = ChainProcessTestContentStore()
        let remote = ChainProcessTestContentStore()
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(config.processPublicKey)
        )
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let childHeader = try BlockHeader(node: child)
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Leaf": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source as any Storer)

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Leaf"],
            capacity: 16
        )
        try await store!.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                    """),
                carrierEvidence: nil,
                parentGenesisLinks: [try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Leaf","childGenesisCID":"\(childHeader.rawCID)"}
                    """)]
            )
        )
        store = nil

        let process = try await ChainProcess.open(
            configuration: config,
            remoteSource: remote
        )
        let status = await process.status()
        XCTAssertNotEqual(status.tipCID, carrierHeader.rawCID)
        let pendingBefore = try await process.pendingChildProofCarrierCIDs()
        XCTAssertEqual(pendingBefore, [carrierHeader.rawCID])

        await remote.store(entries: await source.allEntries())
        let retriedDirectories = try await process.retryPendingChildProofs(
            carrierCID: carrierHeader.rawCID
        )
        XCTAssertEqual(retriedDirectories, ["Leaf"])
        let pendingAfter = try await process.pendingChildProofCarrierCIDs()
        XCTAssertTrue(pendingAfter.isEmpty)
        let durableProofs = try await process.durableDirectChildProofs(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let durable = try XCTUnwrap(durableProofs.first)
        XCTAssertEqual(durable.directory, "Leaf")
        XCTAssertEqual(durable.childCID, childHeader.rawCID)
    }

    private func configuration(path: [String], storage: URL) throws -> NodeConfiguration {
        let parentKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 2, count: 32)
        )
        let parentEndpoint = path.count == 1 ? nil : ParentEndpoint(
            publicKey: try PeerKey(
                rawRepresentation: parentKey.publicKey.rawRepresentation
            ).hex,
            host: "127.0.0.1",
            port: 4001
        )
        return try NodeConfiguration(
            chainPath: path,
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32),
            parentEndpoint: parentEndpoint
        )
    }

    private struct DirectProjectionArrivalFixture {
        let configuration: NodeConfiguration
        let parentAuthority: ParentWorkAuthorityKey
        let incumbentHeader: BlockHeader
        let competingHeader: BlockHeader
        let incumbentPackage: AuthenticatedChildPackage
        let acceptingPackage: AuthenticatedChildPackage
        let targetMissPackage: AuthenticatedChildPackage
        let acceptingCarrierCID: String
        let targetMissCarrierCID: String
        let acceptingGrind: String
        let lateGrind: String

        func parentWork(
            revision: UInt64,
            includeAcceptingCarrier: Bool
        ) -> InheritedWorkSnapshot {
            var workByBlock = [
                targetMissCarrierCID: WorkMeasure(
                    VerifiedWorkContribution(id: lateGrind, work: UInt256(16))
                ),
            ]
            if includeAcceptingCarrier {
                workByBlock[acceptingCarrierCID] = WorkMeasure(
                    VerifiedWorkContribution(id: acceptingGrind, work: UInt256(16))
                )
            }
            return InheritedWorkSnapshot(
                revision: revision,
                workByBlock: workByBlock
            )
        }
    }

    private func directProjectionArrivalFixture()
        async throws -> DirectProjectionArrivalFixture {
        let configuration = try configuration(
            path: ["Nexus", "Payments"],
            storage: temporaryDirectory()
        )
        let parentAuthority = try XCTUnwrap(
            configuration.parentEndpoint.flatMap {
                ParentWorkAuthorityKey($0.publicKey)
            }
        )
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let incumbent = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max / UInt256(8),
            fetcher: source
        )
        let competing = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 2,
            target: UInt256.max / UInt256(4),
            fetcher: source
        )
        let incumbentHeader = try BlockHeader(node: incumbent)
        let competingHeader = try BlockHeader(node: competing)

        let incumbentCandidate = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": incumbent],
            timestamp: 10,
            target: UInt256.max,
            nonce: 1,
            fetcher: source
        )
        let incumbentCarrier = try XCTUnwrap(BlockBuilder.mine(
            block: incumbentCandidate,
            target: incumbent.target,
            maxAttempts: 4_096
        ))
        let acceptingCandidate = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": competing],
            timestamp: 11,
            target: UInt256.max,
            nonce: 1,
            fetcher: source
        )
        let acceptingCarrier = try XCTUnwrap(BlockBuilder.mine(
            block: acceptingCandidate,
            target: competing.target,
            maxAttempts: 4_096
        ))
        var targetMissCarrier: Block?
        for nonce in UInt64(1)...UInt64(64) {
            let candidate = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Payments": competing],
                timestamp: 12,
                target: UInt256.max,
                nonce: nonce,
                fetcher: source
            )
            if candidate.proofOfWorkHash() > competing.target {
                targetMissCarrier = candidate
                break
            }
        }
        let missedCarrier = try XCTUnwrap(targetMissCarrier)

        func package(
            childHeader: BlockHeader,
            childCID: String,
            carrier: Block
        ) async throws -> AuthenticatedChildPackage {
            let carrierHeader = try BlockHeader(node: carrier)
            try await carrierHeader.storeRecursively(storer: source as any Storer)
            let proof = try await ChildBlockProof.generate(
                rootHeader: carrierHeader,
                childDirectory: "Payments",
                fetcher: source
            )
            var entries = try await blockContentEntries(
                childHeader,
                fetcher: source
            )
            entries[carrierHeader.rawCID] = try XCTUnwrap(carrier.toData())
            return AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                        """),
                    parentGenesisLink: try decode(ParentGenesisLink.self, json: """
                        {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(childCID)"}
                        """)
                ),
                acquisitionEntries: entries
            )
        }

        let incumbentPackage = try await package(
            childHeader: incumbentHeader,
            childCID: incumbentHeader.rawCID,
            carrier: incumbentCarrier
        )
        let acceptingPackage = try await package(
            childHeader: competingHeader,
            childCID: competingHeader.rawCID,
            carrier: acceptingCarrier
        )
        let targetMissPackage = try await package(
            childHeader: competingHeader,
            childCID: competingHeader.rawCID,
            carrier: missedCarrier
        )
        let acceptingCarrierCID = try XCTUnwrap(
            acceptingPackage.package.parentCarrierLink
        ).carrierCID
        let targetMissCarrierCID = try XCTUnwrap(
            targetMissPackage.package.parentCarrierLink
        ).carrierCID
        let acceptingGrind = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "accepting-\(UUID().uuidString)")
        ).rawCID
        let lateGrind = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "late-\(UUID().uuidString)")
        ).rawCID
        return DirectProjectionArrivalFixture(
            configuration: configuration,
            parentAuthority: parentAuthority,
            incumbentHeader: incumbentHeader,
            competingHeader: competingHeader,
            incumbentPackage: incumbentPackage,
            acceptingPackage: acceptingPackage,
            targetMissPackage: targetMissPackage,
            acceptingCarrierCID: acceptingCarrierCID,
            targetMissCarrierCID: targetMissCarrierCID,
            acceptingGrind: acceptingGrind,
            lateGrind: lateGrind
        )
    }

    private func admitProjectionIncumbent(
        _ fixture: DirectProjectionArrivalFixture,
        to process: ChainProcess
    ) async throws {
        let admitted = try await process.admit(
            fixture.incumbentHeader,
            authenticatedChildPackage: fixture.incumbentPackage
        )
        XCTAssertTrue(admitted.decision.isAccepted)
        let status = await process.status()
        XCTAssertEqual(status.tipCID, fixture.incumbentHeader.rawCID)
    }

    private struct ChildBootstrapFixture {
        let configuration: NodeConfiguration
        let childHeader: BlockHeader
        let rootCID: String
        let proof: ChildBlockProof
        let canonicalEntries: [String: Data]
        let package: AuthenticatedChildPackage
    }

    private func childBootstrapFixture() async throws -> ChildBootstrapFixture {
        let configuration = try configuration(
            path: ["Nexus", "Payments"],
            storage: temporaryDirectory()
        )
        let parentAuthority = try XCTUnwrap(
            configuration.parentEndpoint.flatMap { ParentWorkAuthorityKey($0.publicKey) }
        )
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let childHeader = try BlockHeader(node: child)
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeRecursively(storer: source as any Storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        let canonicalEntries = try await blockContentEntries(
            childHeader,
            fetcher: source
        )
        var acquisitionEntries = canonicalEntries
        acquisitionEntries[rootHeader.rawCID] = try XCTUnwrap(root.toData())
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(rootHeader.rawCID)","rootCID":"\(rootHeader.rawCID)"}
                    """),
                parentGenesisLink: try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(childHeader.rawCID)"}
                    """)
            ),
            acquisitionEntries: acquisitionEntries
        )
        return ChildBootstrapFixture(
            configuration: configuration,
            childHeader: childHeader,
            rootCID: rootHeader.rawCID,
            proof: proof,
            canonicalEntries: canonicalEntries,
            package: package
        )
    }

    private func contribution(id: String, work: UInt64) -> VerifiedWorkContribution {
        let json = Data(
            "{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}"
                .utf8
        )
        return try! JSONDecoder().decode(VerifiedWorkContribution.self, from: json)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-process-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func blockContentEntries(
        _ header: BlockHeader,
        fetcher: any Fetcher
    ) async throws -> [String: Data] {
        let collector = ChainProcessTestContentStore()
        try await header.storeBlock(fetcher: fetcher, storer: collector)
        return await collector.allEntries()
    }
}

private func signedGenesisAnchorTransaction(
    directory: String,
    childGenesisCID: String,
    chainPath: [String] = ["Nexus"]
) throws -> Transaction {
    let key = CryptoUtils.generateKeyPair()
    let body = TransactionBody(
        accountActions: [],
        actions: [],
        depositActions: [],
        genesisActions: [GenesisAction(
            directory: directory,
            blockCID: childGenesisCID
        )],
        receiptActions: [],
        withdrawalActions: [],
        signers: [CryptoUtils.createAddress(from: key.publicKey)],
        fee: 0,
        nonce: 0,
        chainPath: chainPath
    )
    let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
    let signature = try XCTUnwrap(TransactionSigning.sign(
        bodyHeader: bodyHeader,
        privateKeyHex: key.privateKey
    ))
    return Transaction(
        signatures: [key.publicKey: signature],
        body: bodyHeader
    )
}

private actor ChainProcessTestContentStore: ContentSource, Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries: [String: Data]) {
        self.entries.merge(entries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        entries.merge(volume.entries) { existing, _ in existing }
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }

    func allEntries() -> [String: Data] {
        entries
    }
}

private actor BatchRecordingContentSource: ContentSource {
    private let entries: [String: Data]
    private var recordedRequests: [Set<String>] = []

    init(entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        recordedRequests.append(cids)
        return entries.filter { cids.contains($0.key) }
    }

    func requests() -> [Set<String>] {
        recordedRequests
    }
}

private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
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
    private var blockedFetchStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedFetchWaiters: [Waiter] = []

    init(blockedCID: String) {
        self.blockedCID = blockedCID
    }

    func setEntries(_ entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        let found = entries.filter { cids.contains($0.key) }
        guard cids.contains(blockedCID) else { return found }

        blockedFetchStarted = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        guard !released else { return found }

        return await withCheckedContinuation { continuation in
            blockedFetchWaiters.append(Waiter(
                entries: found,
                continuation: continuation
            ))
        }
    }

    func waitForBlockedFetch() async {
        guard !blockedFetchStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedFetch() {
        released = true
        let pending = blockedFetchWaiters
        blockedFetchWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: waiter.entries)
        }
    }
}
