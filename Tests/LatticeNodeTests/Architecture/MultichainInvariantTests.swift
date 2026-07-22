import Foundation
import UInt256
import XCTest
import cashew
@testable import Lattice
@testable import LatticeNode

final class MultichainInvariantTests: XCTestCase {
    func testHierarchicalGhostAggregatesExactParentCommitmentsIndependentOfOrder()
        async throws {
        let parent = try configuration(
            path: ["Nexus"],
            storage: temporaryDirectory(),
            privateKeyHex: String(repeating: "51", count: 32)
        )
        let authority = try XCTUnwrap(
            ParentWorkAuthorityKey(parent.processPublicKey)
        )
        let graph = try await ghostGraph(parentAuthority: authority)
        let firstConfiguration = try configuration(
            path: ["Nexus", "Payments"],
            storage: temporaryDirectory(),
            privateKeyHex: String(repeating: "52", count: 32),
            parentPublicKey: parent.processPublicKey
        )
        let secondConfiguration = try configuration(
            path: ["Nexus", "Payments"],
            storage: temporaryDirectory(),
            privateKeyHex: String(repeating: "53", count: 32),
            parentPublicKey: parent.processPublicKey
        )

        let first = try await ChainProcess.open(configuration: firstConfiguration)
        let longBaseOutcome = try await first.admit(
            graph.longBase,
            authenticatedChildPackage: graph.longBasePackage
        )
        XCTAssertTrue(longBaseOutcome.decision.isAccepted)
        let longTipOutcome = try await first.admit(
            graph.longTip,
            authenticatedChildPackage: graph.longTipPackage
        )
        XCTAssertTrue(longTipOutcome.decision.isAccepted)
        let shortSideOutcome = try await first.admit(
            graph.shortBase,
            authenticatedChildPackage: graph.shortPackages[0]
        )
        guard case .acceptedSide = shortSideOutcome.decision else {
            return XCTFail("short fork must begin noncanonical")
        }
        _ = try await first.admit(
            graph.shortBase,
            authenticatedChildPackage: graph.shortPackages[1]
        )
        var status = await first.status()
        XCTAssertEqual(status.tipCID, graph.longTip.rawCID)

        let firstCommit = try await first.applyInheritedWorkSnapshot(
            graph.parentWork,
            from: authority.value
        )
        XCTAssertTrue(firstCommit?.canonicalChanged ?? false)
        status = await first.status()
        XCTAssertEqual(status.tipCID, graph.shortBase.rawCID)
        let replay = try await first.applyInheritedWorkSnapshot(
            graph.parentWork,
            from: authority.value
        )
        XCTAssertNil(replay)

        let second = try await ChainProcess.open(configuration: secondConfiguration)
        for blockCID in graph.parentWork.blockCIDs.reversed() {
            _ = try await second.applyInheritedWorkSnapshot(
                InheritedWorkSnapshot(
                    revision: graph.parentWork.revision,
                    workByBlock: [
                        blockCID: graph.parentWork.sourceWork(forBlock: blockCID)
                    ]
                ),
                from: authority.value
            )
        }
        _ = try await second.admit(
            graph.shortBase,
            authenticatedChildPackage: graph.shortPackages[1]
        )
        _ = try await second.admit(
            graph.shortBase,
            authenticatedChildPackage: graph.shortPackages[0]
        )
        let lateLongBase = try await second.admit(
            graph.longBase,
            authenticatedChildPackage: graph.longBasePackage
        )
        guard case .acceptedSide = lateLongBase.decision else {
            return XCTFail("inherited work must keep the short fork canonical")
        }
        let lateLongTip = try await second.admit(
            graph.longTip,
            authenticatedChildPackage: graph.longTipPackage
        )
        guard case .acceptedSide = lateLongTip.decision else {
            return XCTFail("long fork tip must remain noncanonical")
        }
        status = await second.status()
        XCTAssertEqual(status.tipCID, graph.shortBase.rawCID)

        let firstSnapshot = await first.parentSecuringWorkSnapshot()
        let secondSnapshot = await second.parentSecuringWorkSnapshot()
        let firstExport = try XCTUnwrap(firstSnapshot)
        let secondExport = try XCTUnwrap(secondSnapshot)
        XCTAssertEqual(firstExport.blockCIDs, secondExport.blockCIDs)
        for blockCID in firstExport.blockCIDs {
            XCTAssertEqual(
                firstExport.sourceWork(forBlock: blockCID),
                secondExport.sourceWork(forBlock: blockCID)
            )
        }
        let shortWork = firstExport.sourceWork(forBlock: graph.shortBase.rawCID)
        XCTAssertEqual(shortWork.grindIDs, Set(
            graph.shortCarrierCIDs + graph.shortInheritedGrindCIDs
        ))
        XCTAssertEqual(
            shortWork.total,
            WorkMeasure(
                graph.shortCarrierCIDs.map {
                    contribution(id: $0, work: workForTarget(graph.shortTarget))
                } + graph.shortInheritedGrindCIDs.map {
                    contribution(id: $0, work: UInt256(100))
                }
            ).total
        )
    }

    func testDirectParentPackageReplaysOnlyToItsDeclaredChildAcrossRestarts()
        async throws {
        let parentStorage = temporaryDirectory()
        let paymentsStorage = temporaryDirectory()
        let receiptsStorage = temporaryDirectory()
        let parentConfiguration = try configuration(
            path: ["Nexus"],
            storage: parentStorage,
            privateKeyHex: String(repeating: "41", count: 32)
        )
        let paymentsConfiguration = try configuration(
            path: ["Nexus", "Payments"],
            storage: paymentsStorage,
            privateKeyHex: String(repeating: "42", count: 32),
            parentPublicKey: parentConfiguration.processPublicKey
        )
        let receiptsConfiguration = try configuration(
            path: ["Nexus", "Payments", "Receipts"],
            storage: receiptsStorage,
            privateKeyHex: String(repeating: "43", count: 32),
            parentPublicKey: paymentsConfiguration.processPublicKey
        )

        var parent: ChainProcess? = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let parentGenesis = try await parent!.canonicalTipBlock()
        let parentAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(parentConfiguration.processPublicKey)
        )
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority),
            parentState: parentGenesis.postState,
            timestamp: 1,
            target: .max,
            fetcher: parent!
        )
        let childHeader = try BlockHeader(node: childGenesis)
        let authorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID,
            parentWorkAuthorityKey: parentAuthority
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parent!
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            children: ["Payments": childGenesis],
            timestamp: 1,
            nonce: 0,
            fetcher: parent!
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carrierOutcome = try await parent!.admit(
            carrierHeader,
            preparingChildDirectories: ["Payments"]
        )
        XCTAssertTrue(carrierOutcome.decision.isAccepted)

        XCTAssertEqual(
            carrierOutcome.parentCarrierLink?.carrierCID,
            carrierHeader.rawCID
        )
        let persistedEvidence = try await parent!.issuedChildEvidence(
            childCID: childHeader.rawCID,
            directory: "Payments",
            rootCID: carrierHeader.rawCID
        )
        let beforeRestart = try XCTUnwrap(persistedEvidence)

        parent = nil
        parent = try await ChainProcess.open(configuration: parentConfiguration)
        let reopenedEvidence = try await parent!.issuedChildEvidence(
            childCID: childHeader.rawCID,
            directory: "Payments",
            rootCID: carrierHeader.rawCID
        )
        let evidence = try XCTUnwrap(reopenedEvidence)
        let reopenedCarrierLink = try await parent!.issuedParentCarrierLink(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let carrierLink = try XCTUnwrap(reopenedCarrierLink)
        let reopenedGenesisLink = try await parent!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID
        )
        let genesisLink = try XCTUnwrap(reopenedGenesisLink)
        XCTAssertEqual(carrierLink.parentPath, ["Nexus"])
        XCTAssertEqual(carrierLink.carrierCID, carrierHeader.rawCID)
        XCTAssertEqual(carrierLink.rootCID, carrierHeader.rawCID)
        XCTAssertEqual(genesisLink.parentPath, ["Nexus"])
        XCTAssertEqual(genesisLink.directory, "Payments")
        XCTAssertEqual(genesisLink.childGenesisCID, childHeader.rawCID)
        XCTAssertEqual(
            try evidence.proof.serialize(),
            try beforeRestart.proof.serialize()
        )
        XCTAssertEqual(evidence.proof.rootCID, carrierHeader.rawCID)
        XCTAssertEqual(evidence.proof.directoryPath, ["Payments"])
        XCTAssertEqual(evidence.acquisitionEntries, beforeRestart.acquisitionEntries)

        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: evidence.proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: genesisLink
            ),
            acquisitionEntries: evidence.acquisitionEntries
        )
        let childGenesisHeader = BlockHeader(
            rawCID: childHeader.rawCID,
            node: nil,
            encryptionInfo: nil
        )

        var receipts: ChainProcess? = try await ChainProcess.open(
            configuration: receiptsConfiguration
        )
        do {
            _ = try await receipts!.admit(
                childGenesisHeader,
                authenticatedChildPackage: package
            )
            XCTFail("an ancestor package must not bootstrap a descendant")
        } catch {
            XCTAssertEqual(
                error as? ChainProcessError,
                .parentWorkAuthorityMismatch
            )
        }
        let receiptsStatus = await receipts!.status()
        XCTAssertEqual(receiptsStatus.phase, .awaitingGenesis)
        XCTAssertEqual(receiptsStatus.chainPath, ["Nexus", "Payments", "Receipts"])
        XCTAssertNil(receiptsStatus.tipCID)

        receipts = nil
        receipts = try await ChainProcess.open(configuration: receiptsConfiguration)
        let reopenedReceiptsStatus = await receipts!.status()
        XCTAssertEqual(reopenedReceiptsStatus.phase, .awaitingGenesis)
        XCTAssertNil(reopenedReceiptsStatus.tipCID)

        var payments: ChainProcess? = try await ChainProcess.open(
            configuration: paymentsConfiguration
        )
        let accepted = try await payments!.admit(
            childGenesisHeader,
            authenticatedChildPackage: package
        )
        XCTAssertTrue(accepted.decision.isAccepted)
        let paymentsStatus = await payments!.status()
        XCTAssertEqual(paymentsStatus.tipCID, childHeader.rawCID)

        payments = nil
        payments = try await ChainProcess.open(configuration: paymentsConfiguration)
        let reopenedPaymentsStatus = await payments!.status()
        XCTAssertEqual(reopenedPaymentsStatus.tipCID, childHeader.rawCID)
    }

    private func configuration(
        path: [String],
        storage: URL,
        privateKeyHex: String,
        parentPublicKey: String? = nil
    ) throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: path,
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: privateKeyHex,
            parentEndpoint: parentPublicKey.map {
                ParentEndpoint(publicKey: $0, host: "127.0.0.1", port: 4002)
            }
        )
    }

    private func signedGenesisAuthorization(
        directory: String,
        childGenesisCID: String,
        parentWorkAuthorityKey: ParentWorkAuthorityKey
    ) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: directory,
                blockCID: childGenesisCID,
                parentWorkAuthorityKey: parentWorkAuthorityKey
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
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

    private struct GhostGraph {
        let longBase: BlockHeader
        let longTip: BlockHeader
        let shortBase: BlockHeader
        let longBasePackage: AuthenticatedChildPackage
        let longTipPackage: AuthenticatedChildPackage
        let shortPackages: [AuthenticatedChildPackage]
        let shortCarrierCIDs: [String]
        let shortInheritedGrindCIDs: [String]
        let shortTarget: UInt256
        let parentWork: InheritedWorkSnapshot
    }

    private func ghostGraph(
        parentAuthority: ParentWorkAuthorityKey
    ) async throws -> GhostGraph {
        let source = MultichainContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let longTarget = UInt256.max / UInt256(8)
        let shortTarget = UInt256.max / UInt256(4)
        let spec = NexusGenesis.spec.withParentWorkAuthorityKey(parentAuthority)
        let parentGenesis = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            timestamp: 0,
            target: .max,
            fetcher: source
        )
        try await BlockHeader(node: parentGenesis).storeRecursively(
            storer: source as any Storer
        )
        let longBaseBlock = try await BlockBuilder.buildChildGenesis(
            spec: spec,
            parentState: parentGenesis.postState,
            timestamp: 1,
            target: longTarget,
            fetcher: source
        )
        let shortBaseBlock = try await BlockBuilder.buildChildGenesis(
            spec: spec,
            parentState: parentGenesis.postState,
            timestamp: 2,
            target: shortTarget,
            fetcher: source
        )
        let longBase = try BlockHeader(node: longBaseBlock)
        let shortBase = try BlockHeader(node: shortBaseBlock)
        let longAuthorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: longBase.rawCID,
            parentWorkAuthorityKey: parentAuthority
        )
        let shortAuthorization = try signedGenesisAuthorization(
            directory: "Payments",
            childGenesisCID: shortBase.rawCID,
            parentWorkAuthorityKey: parentAuthority
        )
        try await VolumeImpl<Transaction>(node: longAuthorization)
            .storeRecursively(storer: source)
        try await VolumeImpl<Transaction>(node: shortAuthorization)
            .storeRecursively(storer: source)

        let longRootCandidate = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [longAuthorization],
            children: ["Payments": longBaseBlock],
            timestamp: 3_600_000,
            fetcher: source
        )
        let longRoot = try XCTUnwrap(BlockBuilder.mine(
            block: longRootCandidate,
            target: longTarget,
            maxAttempts: 8_192
        ))
        try await longRoot.postState.storeRecursively(storer: source)
        let provisionalParent = try await BlockBuilder.buildBlock(
            previous: longRoot,
            timestamp: 7_200_000,
            fetcher: source
        )
        let longTipBlock = try await BlockBuilder.buildBlock(
            previous: longBaseBlock,
            parentChainBlock: provisionalParent,
            timestamp: 7_200_000,
            fetcher: source
        )
        let longTip = try BlockHeader(node: longTipBlock)
        let longTipRootCandidate = try await BlockBuilder.buildBlock(
            previous: longRoot,
            children: ["Payments": longTipBlock],
            timestamp: 7_200_000,
            fetcher: source
        )
        let longTipRoot = try XCTUnwrap(BlockBuilder.mine(
            block: longTipRootCandidate,
            target: longTarget,
            maxAttempts: 8_192
        ))
        var shortRoots: [Block] = []
        for timestamp in [Int64(3_600_001), Int64(3_600_002)] {
            let candidate = try await BlockBuilder.buildBlock(
                previous: parentGenesis,
                transactions: [shortAuthorization],
                children: ["Payments": shortBaseBlock],
                timestamp: timestamp,
                fetcher: source
            )
            shortRoots.append(try XCTUnwrap(BlockBuilder.mine(
                block: candidate,
                target: shortTarget,
                maxAttempts: 8_192
            )))
        }

        let longBasePackage = try await childPackage(
            child: longBase,
            carrier: longRoot,
            parentAuthority: parentAuthority,
            isGenesis: true,
            source: source
        )
        let longTipPackage = try await childPackage(
            child: longTip,
            carrier: longTipRoot,
            parentAuthority: parentAuthority,
            isGenesis: false,
            source: source
        )
        var shortPackages: [AuthenticatedChildPackage] = []
        for root in shortRoots {
            shortPackages.append(try await childPackage(
                child: shortBase,
                carrier: root,
                parentAuthority: parentAuthority,
                isGenesis: true,
                source: source
            ))
        }
        let longCarrierCIDs = try [longRoot, longTipRoot].map {
            try BlockHeader(node: $0).rawCID
        }
        let shortCarrierCIDs = try shortRoots.map {
            try BlockHeader(node: $0).rawCID
        }
        let longGrinds = try ["long-1", "long-2"].map(grindCID)
        let shortGrinds = try ["short-1", "short-2"].map(grindCID)
        return GhostGraph(
            longBase: longBase,
            longTip: longTip,
            shortBase: shortBase,
            longBasePackage: longBasePackage,
            longTipPackage: longTipPackage,
            shortPackages: shortPackages,
            shortCarrierCIDs: shortCarrierCIDs,
            shortInheritedGrindCIDs: shortGrinds,
            shortTarget: shortTarget,
            parentWork: InheritedWorkSnapshot(
                revision: 4,
                workByBlock: [
                    longCarrierCIDs[0]: WorkMeasure(contribution(
                        id: longGrinds[0], work: UInt256(60)
                    )),
                    longCarrierCIDs[1]: WorkMeasure(contribution(
                        id: longGrinds[1], work: UInt256(60)
                    )),
                    shortCarrierCIDs[0]: WorkMeasure(contribution(
                        id: shortGrinds[0], work: UInt256(100)
                    )),
                    shortCarrierCIDs[1]: WorkMeasure(contribution(
                        id: shortGrinds[1], work: UInt256(100)
                    )),
                ]
            )
        )
    }

    private func childPackage(
        child: BlockHeader,
        carrier: Block,
        parentAuthority: ParentWorkAuthorityKey,
        isGenesis: Bool,
        source: MultichainContentStore
    ) async throws -> AuthenticatedChildPackage {
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeBlock(fetcher: source, storer: source)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        let collector = MultichainContentStore()
        try await child.storeBlock(fetcher: source, storer: collector)
        var entries = await collector.allEntries()
        entries[carrierHeader.rawCID] = try XCTUnwrap(carrier.toData())
        let genesisLink: ParentGenesisLink? = if isGenesis {
            try decode(ParentGenesisLink.self, json: """
                {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(child.rawCID)","parentWorkAuthorityKey":"\(parentAuthority.value)"}
                """)
        } else {
            nil
        }
        return AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                    """),
                parentGenesisLink: genesisLink
            ),
            acquisitionEntries: entries
        )
    }

    private func contribution(id: String, work: UInt256)
        -> VerifiedWorkContribution {
        try! JSONDecoder().decode(
            VerifiedWorkContribution.self,
            from: Data("{\"id\":\"\(id)\",\"work\":\"\(work.toHexString())\"}".utf8)
        )
    }

    private func grindCID(_ seed: String) throws -> String {
        try HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-multichain-invariant-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private actor MultichainContentStore: ContentSource, Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }

    func store(entries: [String: Data]) {
        self.entries.merge(entries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        entries.merge(volume.entries) { existing, _ in existing }
    }

    func allEntries() -> [String: Data] {
        entries
    }
}
