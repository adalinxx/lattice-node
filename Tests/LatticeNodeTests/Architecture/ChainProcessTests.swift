import Crypto
import Ivy
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode

final class ChainProcessTests: XCTestCase {
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

    func testChildBootstrapsFromHierarchyProofWithoutOverlaySupplier() async throws {
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
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
        try await rootHeader.storeRecursively(storer: source)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        XCTAssertTrue(proof.entries.contains { $0.cid == childHeader.rawCID })
        let acquisitionEntries = try await blockContentEntries(
            childHeader,
            fetcher: source
        )

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
        let process = try await ChainProcess.open(configuration: try configuration(
            path: ["Nexus", "Payments"],
            storage: temporaryDirectory()
        ))

        let outcome = try await process.admit(
            BlockHeader(rawCID: childHeader.rawCID, node: nil, encryptionInfo: nil),
            authenticatedChildPackage: package
        )

        XCTAssertTrue(
            outcome.decision.isAccepted,
            "unexpected admission outcome: \(outcome.decision)"
        )
        let status = await process.status()
        XCTAssertEqual(status.phase, .active)
    }

    func testRestartPromotesPreparedChildProofAfterDurableCarrierLink() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        process = nil

        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
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
        try await carrierHeader.storeRecursively(storer: source)
        let hop = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )

        var store: NodeStore? = try NodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork
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
        try await store!.persistIssuedParentCarrierLink(
            try decode(ParentCarrierLink.self, json: """
                {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                """),
            issuerKey: config.processPublicKey
        )
        store = nil

        process = try await ChainProcess.open(configuration: config)
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

    func testNonNexusRestartRecoversComposedGrandchildProof() async throws {
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let grandchild = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            children: ["Leaf": grandchild],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let childHeader = try BlockHeader(node: child)
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Middle": child],
            timestamp: 3,
            target: UInt256.max,
            fetcher: source
        )
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeRecursively(storer: source)
        let upstreamProof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Middle",
            fetcher: source
        )
        let childHop = try await ChildBlockProof.generate(
            rootHeader: childHeader,
            childDirectory: "Leaf",
            fetcher: source
        )
        let grandchildHeader = try BlockHeader(node: grandchild)
        let leafEntries = try await blockContentEntries(
            grandchildHeader,
            fetcher: source
        )

        let directory = temporaryDirectory()
        let config = try configuration(
            path: ["Nexus", "Middle"],
            storage: directory
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        try await process!.store(entries: await source.allEntries())
        let prepared = try await process!.prepareChildProofs(
            for: child,
            children: [DirectChildCandidate(
                directory: "Leaf",
                block: grandchild,
                searchTarget: grandchild.target,
                acquisitionEntries: leafEntries
            )],
            capacity: 16
        )
        XCTAssertEqual(prepared.map(\.directory), ["Leaf"])
        XCTAssertEqual(
            try prepared.first?.proof.serialize(),
            try childHop.serialize()
        )
        process = nil
        process = try await ChainProcess.open(configuration: config)

        let acquisitionEntries = try await blockContentEntries(
            childHeader,
            fetcher: source
        )
        XCTAssertNil(acquisitionEntries[grandchildHeader.rawCID])
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: upstreamProof,
                parentCarrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(rootHeader.rawCID)","rootCID":"\(rootHeader.rawCID)"}
                    """),
                parentGenesisLink: try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Middle","childGenesisCID":"\(childHeader.rawCID)"}
                    """)
            ),
            acquisitionEntries: acquisitionEntries
        )

        let outcome = try await process!.admit(
            BlockHeader(rawCID: childHeader.rawCID, node: nil, encryptionInfo: nil),
            authenticatedChildPackage: package
        )
        XCTAssertTrue(outcome.decision.isAccepted)
        process = nil

        process = try await ChainProcess.open(configuration: config)
        let recovered = try await process!.durableDirectChildProofs(
            carrierCID: childHeader.rawCID,
            rootCID: rootHeader.rawCID
        )
        let durable = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(durable.directory, "Leaf")
        XCTAssertEqual(durable.childCID, grandchildHeader.rawCID)
        XCTAssertEqual(durable.proof.rootCID, rootHeader.rawCID)
        XCTAssertEqual(durable.proof.directoryPath, ["Middle", "Leaf"])
        XCTAssertEqual(try BlockHeader(node: durable.childBlock).rawCID, durable.childCID)
        XCTAssertEqual(durable.childBlock.toData(), grandchild.toData())
        XCTAssertEqual(durable.acquisitionEntries, leafEntries)
    }

    func testRestartRetriesPendingProofForNonTipCarrier() async throws {
        let source = ChainProcessTestContentStore()
        let remote = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
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
        try await carrierHeader.storeRecursively(storer: source)

        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        var store: NodeStore? = try NodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            minimumRootWork: config.minimumRootWork
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Leaf"],
            capacity: 16
        )
        try await store!.persistIssuedParentCarrierLink(
            try decode(ParentCarrierLink.self, json: """
                {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                """),
            issuerKey: config.processPublicKey
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
        try await process.retryPendingChildProofs(
            carrierCID: carrierHeader.rawCID
        )
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

private actor ChainProcessTestContentStore: ContentSource, Fetcher, Storer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries: [String: Data]) {
        self.entries.merge(entries) { existing, _ in existing }
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }

    func allEntries() -> [String: Data] {
        entries
    }
}
