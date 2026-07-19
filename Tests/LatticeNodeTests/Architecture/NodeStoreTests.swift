import Foundation
import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticeNode

final class NodeStoreTests: XCTestCase {
    private let genesisCID = "bafy-nexus-genesis"

    func testLegacyDatabaseFailsBeforeNewDDL() throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent("state.db")
        let legacy = try NodeSQLite(path: path.path)
        try legacy.execute("CREATE TABLE legacy_state (value TEXT NOT NULL)")

        XCTAssertThrowsError(try makeStore(path: path)) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected wipe-required error, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("entire configured storage directory"))
        }

        let tables = try legacy.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { $0["name"]?.textValue }
        XCTAssertEqual(tables, ["legacy_state"])
    }

    func testMetadataRejectsWrongEpochRootAndPath() throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent("state.db")
        _ = try makeStore(path: path)

        let database = try NodeSQLite(path: path.path)
        try database.execute(
            "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
            params: [.int(NodeStore.currentSchemaEpoch + 1)]
        )
        XCTAssertThrowsError(try makeStore(path: path)) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected wipe-required error, got \(error)")
            }
        }
        try database.execute(
            "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
            params: [.int(NodeStore.currentSchemaEpoch)]
        )

        for attempt in [
            { try self.makeStore(path: path, genesisCID: "different-root") },
            { try self.makeStore(path: path, chainPath: ["Nexus", "Payments"]) },
            { try self.makeStore(path: path, minimumRootWork: UInt256(2)) },
        ] {
            XCTAssertThrowsError(try attempt()) { error in
                guard case NodeStoreError.wipeRequired = error else {
                    return XCTFail("expected wipe-required error, got \(error)")
                }
            }
        }
    }

    func testMatchingMetadataDoesNotRepairMissingTables() throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent("state.db")
        _ = try makeStore(path: path)
        let database = try NodeSQLite(path: path.path)
        try database.execute("DROP TABLE validation_content")

        XCTAssertThrowsError(try makeStore(path: path)) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected wipe-required error, got \(error)")
            }
        }
    }

    func testValidationContentIsIdempotentAndConflictsFailClosed() async throws {
        let store = try makeStore()
        let original = Data("original".utf8)
        try await store.store(entries: ["cid": original])
        try await store.store(entries: ["cid": original])
        let fetched = try await store.fetch(rawCid: "cid")
        XCTAssertEqual(fetched, original)

        await XCTAssertThrowsErrorAsync(
            try await store.store(entries: ["cid": Data("different".utf8)])
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingContent("cid"))
        }
    }

    func testValidationContentCallIsAtomic() async throws {
        let store = try makeStore()
        try await store.store(entries: ["z-existing": Data("original".utf8)])

        await XCTAssertThrowsErrorAsync(
            try await store.store(entries: [
                "a-new": Data("must-roll-back".utf8),
                "z-existing": Data("conflict".utf8),
            ])
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingContent("z-existing"))
        }

        let fetched = await store.fetch(["a-new", "z-existing"])
        XCTAssertNil(fetched["a-new"])
        XCTAssertEqual(fetched["z-existing"], Data("original".utf8))
    }

    func testAdmissionBatchReplayIsIdempotentAndFactConflictFailsClosed() async throws {
        let store = try makeStore()
        let original = blockBatch(postStateCID: "state-a")

        try await store.stage(original, volumeRoots: ["volume-z", "volume-a"])
        try await store.stage(original, volumeRoots: ["volume-a", "volume-z"])

        var staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged[0].batch, original)
        XCTAssertEqual(staged[0].volumeRoots, ["volume-a", "volume-z"])

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state-b"),
                volumeRoots: ["other-volume"]
            )
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingAdmissionFact)
        }

        staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
    }

    func testAdmissionBatchRejectsDifferentRootList() async throws {
        let store = try makeStore()
        let batch = blockBatch(postStateCID: "state")
        try await store.stage(batch, volumeRoots: ["volume-a"])

        await XCTAssertThrowsErrorAsync(
            try await store.stage(batch, volumeRoots: ["volume-b"])
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingAdmissionBatch)
        }
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
    }

    func testAdmissionAtomicallyPersistsSetValuedParentCoverage() async throws {
        let store = try makeStore()
        let first = blockBatch(postStateCID: "state", blockHash: "child")
        let second = ChainAdmissionBatch(facts: first.facts + [
            .work(ChainWorkFact(
                blockHash: "child",
                contribution: contribution(id: "grind", work: 7)
            )),
        ])
        let a = ParentCoverageBinding(
            childBlockCID: "child",
            parentCarrierCID: "carrier-a"
        )
        let b = ParentCoverageBinding(
            childBlockCID: "child",
            parentCarrierCID: "carrier-b"
        )

        try await store.stage(first, volumeRoots: [], parentCoverage: [a])
        try await store.stage(second, volumeRoots: [], parentCoverage: [b])

        let coverage = try await store.parentCoverage()
        XCTAssertEqual(coverage, ["child": Set(["carrier-a", "carrier-b"])])
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.map(\.parentCoverage), [[a], [b]])
    }

    func testAdmissionRejectsCoverageOutsideItsBatch() async throws {
        let store = try makeStore()
        let binding = ParentCoverageBinding(
            childBlockCID: "different-block",
            parentCarrierCID: "carrier"
        )

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state", blockHash: "batch-block"),
                volumeRoots: [],
                parentCoverage: [binding]
            )
        ) { error in
            XCTAssertEqual(
                error as? NodeStoreError,
                .invalidParentCoverage("different-block")
            )
        }
        let staged = try await store.stagedAdmissions()
        XCTAssertTrue(staged.isEmpty)
    }

    func testAdmissionReplayFailsWhenNormalizedRowsAreMissing() async throws {
        let factsPath = temporaryDirectory().appendingPathComponent("state.db")
        let factsStore = try makeStore(path: factsPath)
        let batch = blockBatch(postStateCID: "state", blockHash: "child")
        let binding = ParentCoverageBinding(
            childBlockCID: "child",
            parentCarrierCID: "carrier"
        )
        try await factsStore.stage(
            batch,
            volumeRoots: [],
            parentCoverage: [binding]
        )
        try NodeSQLite(path: factsPath.path).execute("DELETE FROM admission_facts")
        await XCTAssertThrowsErrorAsync(
            try await factsStore.stage(
                batch,
                volumeRoots: [],
                parentCoverage: [binding]
            )
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }

        let coveragePath = temporaryDirectory().appendingPathComponent("state.db")
        let coverageStore = try makeStore(path: coveragePath)
        try await coverageStore.stage(
            batch,
            volumeRoots: [],
            parentCoverage: [binding]
        )
        try NodeSQLite(path: coveragePath.path).execute("DELETE FROM parent_coverage")
        await XCTAssertThrowsErrorAsync(
            try await coverageStore.stage(
                batch,
                volumeRoots: [],
                parentCoverage: [binding]
            )
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testNormalizedIndexAuditRequiresExactBatchDerivedRows() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "child"),
            volumeRoots: [],
            parentCoverage: [ParentCoverageBinding(
                childBlockCID: "child",
                parentCarrierCID: "carrier"
            )]
        )
        try await store.auditNormalizedIndexes()

        try NodeSQLite(path: path.path).execute(
            "INSERT INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
            params: [.blob(Data("extra-id".utf8)), .blob(Data("extra".utf8))]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testIssuedParentFactsAreScopedToIssuerKey() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"root"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"genesis"}
            """)

        try await store.persistIssuedParentCarrierLink(carrier, issuerKey: "issuer-a")
        try await store.persistIssuedParentGenesisLink(genesis, issuerKey: "issuer-a")

        let storedCarrier = try await store.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "root",
            issuerKey: "issuer-a"
        )
        let storedGenesis = try await store.issuedParentGenesisLink(
            directory: "Child",
            childGenesisCID: "genesis",
            issuerKey: "issuer-a"
        )
        let rotatedCarrier = try await store.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "root",
            issuerKey: "issuer-b"
        )
        let rotatedGenesis = try await store.issuedParentGenesisLink(
            directory: "Child",
            childGenesisCID: "genesis",
            issuerKey: "issuer-b"
        )
        XCTAssertEqual(storedCarrier, carrier)
        XCTAssertEqual(storedGenesis, genesis)
        XCTAssertNil(rotatedCarrier)
        XCTAssertNil(rotatedGenesis)
    }

    func testIssuedChildProofsAreSetValuedContentBoundAndDurable() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let fixture = try await childProofFixture()

        try await store!.persistIssuedChildProof(
            fixture.first,
            child: fixture.child,
            acquisitionEntries: fixture.acquisitionEntries
        )
        try await store!.persistIssuedChildProof(
            fixture.second,
            child: fixture.child,
            acquisitionEntries: fixture.acquisitionEntries
        )

        let selectedValue = try await store!.issuedChildProof(
            childCID: fixture.childCID
        )
        let selected = try XCTUnwrap(selectedValue)
        XCTAssertEqual(
            selected.rootCID,
            min(fixture.first.rootCID, fixture.second.rootCID)
        )
        let firstPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            afterRootCID: nil,
            limit: 1
        )
        let secondPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            afterRootCID: try XCTUnwrap(firstPage.last),
            limit: 1
        )
        let exhaustedPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            afterRootCID: try XCTUnwrap(secondPage.last),
            limit: 1
        )
        XCTAssertEqual(
            firstPage + secondPage,
            [fixture.first.rootCID, fixture.second.rootCID].sorted()
        )
        XCTAssertTrue(exhaustedPage.isEmpty)
        let exactValue = try await store!.issuedChildProof(
            childCID: fixture.childCID,
            rootCID: fixture.second.rootCID
        )
        let exact = try XCTUnwrap(exactValue)
        XCTAssertEqual(try exact.serialize(), try fixture.second.serialize())

        store = nil
        store = try makeStore(path: path)
        let recoveredValue = try await store!.issuedChildProof(
            childCID: fixture.childCID,
            rootCID: fixture.first.rootCID
        )
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(try recovered.serialize(), try fixture.first.serialize())
        let recoveredEvidenceValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            rootCID: fixture.first.rootCID
        )
        let recoveredEvidence = try XCTUnwrap(recoveredEvidenceValue)
        XCTAssertEqual(recoveredEvidence.childData, fixture.child.toData())

        let otherChild = Block(
            version: fixture.child.version,
            parent: fixture.child.parent,
            transactions: fixture.child.transactions,
            target: fixture.child.target,
            nextTarget: fixture.child.nextTarget,
            spec: fixture.child.spec,
            parentState: fixture.child.parentState,
            prevState: fixture.child.prevState,
            postState: fixture.child.postState,
            children: fixture.child.children,
            height: fixture.child.height,
            timestamp: fixture.child.timestamp,
            nonce: fixture.child.nonce + 1
        )
        let otherChildCID = try BlockHeader(node: otherChild).rawCID

        await XCTAssertThrowsErrorAsync(
            try await store!.persistIssuedChildProof(
                fixture.first,
                child: otherChild,
                acquisitionEntries: try replacingRoot(
                    fixture.acquisitionEntries,
                    oldCID: fixture.childCID,
                    with: otherChild
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? NodeStoreError,
                .invalidIssuedChildProof(otherChildCID)
            )
        }
    }

    func testIssuedCarrierEvidencePersistsProofAndLinkTogether() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path, chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        let link = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.first.rootCID)"}
            """)

        try await store.persistIssuedCarrierEvidence(
            link: link,
            proof: fixture.first,
            child: fixture.child,
            acquisitionEntries: fixture.acquisitionEntries,
            issuerKey: "issuer"
        )

        let storedLink = try await store.issuedParentCarrierLink(
            carrierCID: fixture.childCID,
            rootCID: fixture.first.rootCID,
            issuerKey: "issuer"
        )
        XCTAssertEqual(storedLink, link)
        let proofValue = try await store.issuedChildProof(
            childCID: fixture.childCID,
            rootCID: fixture.first.rootCID
        )
        let proof = try XCTUnwrap(proofValue)
        XCTAssertEqual(try proof.serialize(), try fixture.first.serialize())
    }

    func testPreparedChildProofsAreDurableAndBoundedByCarrier() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let fixture = try await childProofFixture()
        let first = try PreparedChildProof(
            directory: "Child",
            child: fixture.child,
            proof: fixture.first,
            acquisitionEntries: fixture.acquisitionEntries
        )
        let second = try PreparedChildProof(
            directory: "Child",
            child: fixture.child,
            proof: fixture.second,
            acquisitionEntries: fixture.acquisitionEntries
        )

        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [first],
            capacity: 1
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [first],
            capacity: 1
        )
        store = nil
        store = try makeStore(path: path)

        let recovered = try await store!.preparedChildProofs(
            carrierCID: fixture.first.rootCID
        )
        XCTAssertEqual(recovered.map(\.directory), ["Child"])
        XCTAssertEqual(recovered.map(\.childCID), [fixture.childCID])
        XCTAssertEqual(
            try recovered.first?.proof.serialize(),
            try fixture.first.serialize()
        )
        XCTAssertEqual(
            recovered.first?.acquisitionEntries,
            fixture.acquisitionEntries
        )

        var conflictingEntries = fixture.acquisitionEntries
        conflictingEntries["extra"] = Data("different".utf8)
        await XCTAssertThrowsErrorAsync(try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                child: fixture.child,
                proof: fixture.first,
                acquisitionEntries: conflictingEntries
            )],
            capacity: 1
        )) { error in
            XCTAssertEqual(
                error as? NodeStoreError,
                .conflictingIssuedChildProof
            )
        }

        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.second.rootCID,
            proofs: [second],
            capacity: 1
        )
        let evicted = try await store!.preparedChildProofs(
            carrierCID: fixture.first.rootCID
        )
        let carriers = try await store!.preparedChildProofCarrierCIDs()
        XCTAssertTrue(evicted.isEmpty)
        XCTAssertEqual(carriers, [fixture.second.rootCID])
    }

    func testPendingChildProofRoutesUnionRecoverAndEvictByCarrier() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        try await store!.persistPendingChildProofRoutes(
            carrierCID: "carrier-a",
            directories: ["Beta", "Alpha"],
            capacity: 1
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: "carrier-a",
            directories: ["Gamma", "Alpha"],
            capacity: 1
        )
        store = nil
        store = try makeStore(path: path)

        let recoveredRoutes = try await store!.pendingChildProofRoutes()
        XCTAssertEqual(
            recoveredRoutes,
            [
                PendingChildProofRoute(carrierCID: "carrier-a", directory: "Alpha"),
                PendingChildProofRoute(carrierCID: "carrier-a", directory: "Beta"),
                PendingChildProofRoute(carrierCID: "carrier-a", directory: "Gamma"),
            ]
        )
        try await store!.removePendingChildProofRoutes(
            carrierCID: "carrier-a",
            directories: ["Beta"]
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: "carrier-b",
            directories: ["Delta"],
            capacity: 1
        )
        let remainingRoutes = try await store!.pendingChildProofRoutes()
        XCTAssertEqual(
            remainingRoutes,
            [PendingChildProofRoute(carrierCID: "carrier-b", directory: "Delta")]
        )
    }

    func testPreparedChildProofRoutesGrowByImmutableDirectory() async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let alpha = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let beta = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Alpha": alpha, "Beta": beta],
            timestamp: 3,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: content)
        let alphaProof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Alpha",
            fetcher: content
        )
        let betaProof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Beta",
            fetcher: content
        )
        let store = try makeStore()
        try await store.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Alpha",
                child: alpha,
                proof: alphaProof,
                acquisitionEntries: try await acquisitionEntries(
                    for: alpha,
                    fetcher: content
                )
            )],
            capacity: 2
        )
        try await store.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Beta",
                child: beta,
                proof: betaProof,
                acquisitionEntries: try await acquisitionEntries(
                    for: beta,
                    fetcher: content
                )
            )],
            capacity: 2
        )

        let recovered = try await store.preparedChildProofs(
            carrierCID: carrierHeader.rawCID
        )
        XCTAssertEqual(recovered.map(\.directory), ["Alpha", "Beta"])
    }

    func testAdmissionStorageRecordsOnlyActualVolumeRoots() async throws {
        let store = try makeStore()
        let volumes = RecordingVolumeStorer()
        let admission = NodeAdmissionStorage(
            validationContent: store,
            materializedVolumes: volumes
        )

        try await admission.store(entries: ["sparse-cid": Data("sparse".utf8)])
        try await admission.store(volume: SerializedVolume(
            root: "actual-root",
            entries: ["actual-root": Data("volume".utf8)]
        ))

        let recordedRoots = await admission.takeStoredVolumeRoots()
        let drainedRoots = await admission.takeStoredVolumeRoots()
        let storedRoots = await volumes.storedRoots()
        let sparse = try await store.fetch(rawCid: "sparse-cid")
        XCTAssertEqual(recordedRoots, ["actual-root"])
        XCTAssertTrue(drainedRoots.isEmpty)
        XCTAssertEqual(storedRoots, ["actual-root"])
        XCTAssertEqual(sparse, Data("sparse".utf8))
    }

    func testInheritedWorkSnapshotRoundTripsAndJoinsOlderCoverage() async throws {
        let store = try makeStore()
        let first = InheritedWorkSnapshot(
            revision: 7,
            workByBlock: [
                "block-a": WorkMeasure(contribution(id: "grind-a", work: 5)),
            ]
        )
        let olderAddition = InheritedWorkSnapshot(
            revision: 4,
            workByBlock: [
                "block-b": WorkMeasure(contribution(id: "grind-b", work: 9)),
            ]
        )

        try await store.persistInheritedWorkSnapshot(first)
        try await store.persistInheritedWorkSnapshot(olderAddition)
        let loaded = try await store.inheritedWorkSnapshot()
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.revision, 7)
        XCTAssertEqual(restored.work(forBlock: "block-a"), first.work(forBlock: "block-a"))
        XCTAssertEqual(
            restored.work(forBlock: "block-b"),
            olderAddition.work(forBlock: "block-b")
        )
    }

    private func makeStore(
        path: URL? = nil,
        genesisCID: String? = nil,
        chainPath: [String] = ["Nexus"],
        minimumRootWork: UInt256 = UInt256(1)
    ) throws -> NodeStore {
        let path = path ?? temporaryDirectory().appendingPathComponent("state.db")
        return try NodeStore(
            databasePath: path,
            nexusGenesisCID: genesisCID ?? self.genesisCID,
            chainPath: chainPath,
            minimumRootWork: minimumRootWork
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-store-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func blockBatch(
        postStateCID: String,
        blockHash: String = "same-block"
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: blockHash,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: postStateCID,
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            )),
        ])
    }

    private func contribution(id: String, work: UInt64) -> VerifiedWorkContribution {
        let json = Data("{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8)
        return try! JSONDecoder().decode(VerifiedWorkContribution.self, from: json)
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func childProofFixture() async throws -> (
        child: Block,
        childCID: String,
        first: ChildBlockProof,
        second: ChildBlockProof,
        acquisitionEntries: [String: Data]
    ) {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let childCID = try BlockHeader(node: child).rawCID
        var proofs: [ChildBlockProof] = []
        for (timestamp, nonce) in [(Int64(2), UInt64(1)), (Int64(3), UInt64(2))] {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Child": child],
                timestamp: timestamp,
                target: UInt256.max,
                nonce: nonce,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content)
            proofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "Child",
                fetcher: content
            ))
        }
        return (
            child,
            childCID,
            proofs[0],
            proofs[1],
            try await acquisitionEntries(for: child, fetcher: content)
        )
    }

    private func acquisitionEntries(
        for block: Block,
        fetcher: any Fetcher
    ) async throws -> [String: Data] {
        let collector = TestContentStore()
        try await BlockHeader(node: block).storeBlock(
            fetcher: fetcher,
            storer: collector
        )
        return await collector.allEntries()
    }

    private func replacingRoot(
        _ entries: [String: Data],
        oldCID: String,
        with block: Block
    ) throws -> [String: Data] {
        var entries = entries
        entries.removeValue(forKey: oldCID)
        entries[try BlockHeader(node: block).rawCID] = try XCTUnwrap(block.toData())
        return entries
    }
}

private actor RecordingVolumeStorer: VolumeStorer {
    private var roots: [String] = []

    func store(volume: SerializedVolume) async throws {
        roots.append(volume.root)
    }

    func storedRoots() -> [String] {
        roots
    }
}

private actor TestContentStore: Fetcher, Storer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries: [String: Data]) {
        self.entries.merge(entries) { existing, _ in existing }
    }

    func allEntries() -> [String: Data] { entries }
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
