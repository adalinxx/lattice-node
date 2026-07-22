import Foundation
import XCTest
import UInt256
import VolumeBroker
import cashew
@testable import Lattice
@testable import LatticeNode

private func inheritedWorkCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

final class NodeStoreTests: XCTestCase {
    private let genesisCID = NexusGenesis.expectedBlockHash
    private let parentAuthorityKey = String(
        repeating: "a",
        count: ParentWorkAuthorityKey.encodedByteCount
    )

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
        for epoch in [
            NodeStore.currentSchemaEpoch - 1,
            NodeStore.currentSchemaEpoch + 1,
        ] {
            try database.execute(
                "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
                params: [.int(epoch)]
            )
            XCTAssertThrowsError(try makeStore(path: path)) { error in
                guard case NodeStoreError.wipeRequired = error else {
                    return XCTFail("expected wipe-required error, got \(error)")
                }
            }
            XCTAssertEqual(
                try database.query(
                    "SELECT schema_epoch FROM node_metadata WHERE singleton = 1"
                ).first?["schema_epoch"]?.intValue,
                epoch
            )
        }
        try database.execute(
            "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
            params: [.int(NodeStore.currentSchemaEpoch)]
        )

        for attempt in [
            { try self.makeStore(path: path, genesisCID: "different-root") },
            { try self.makeStore(path: path, chainPath: ["Nexus", "Payments"]) },
            { try self.makeStore(path: path, minimumRootWork: UInt256(2)) },
            { try self.makeStore(
                path: path,
                issuingAuthorityKey: String(repeating: "b", count: 64)
            ) },
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
        try database.execute("DROP TABLE issued_child_edges")

        XCTAssertThrowsError(try makeStore(path: path)) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected wipe-required error, got \(error)")
            }
        }
    }

    func testCurrentSchemaStoresImmediateParentFactsDirectly() throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent("state.db")
        _ = try makeStore(path: path)

        let tables = try NodeSQLite(path: path.path).query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { $0["name"]?.textValue }

        XCTAssertFalse(tables.contains("parent_coverage"))
        XCTAssertFalse(tables.contains("inherited_work_snapshot"))
        XCTAssertFalse(tables.contains("parent_work_sources"))
        XCTAssertFalse(tables.contains("parent_work_strengths"))
        XCTAssertFalse(tables.contains("parent_work_coverage"))
        XCTAssertTrue(tables.contains("parent_work_source"))
        XCTAssertTrue(tables.contains("parent_work_facts"))
        XCTAssertEqual(
            Set(try NodeSQLite(path: path.path).query(
                "PRAGMA table_info(local_mempool_transactions)"
            ).compactMap { $0["name"]?.textValue }),
            Set(["transaction_cid", "added_at"])
        )
    }

    func testInheritedWorkSourceStoresMonotoneFactsAndPinsAuthority()
        async throws {
        let childA = inheritedWorkCID("child-a")
        let childC = inheritedWorkCID("child-c")
        let childD = inheritedWorkCID("child-d")
        let shared = inheritedWorkCID("shared")
        let other = inheritedWorkCID("other")
        let late = inheritedWorkCID("late")
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(
            path: path,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let first = InheritedWorkSnapshot(
            revision: 8,
            workByBlock: [
                childA: WorkMeasure(
                    contribution(id: shared, work: 3)
                ),
            ]
        )
        let olderButStronger = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [
                childA: WorkMeasure(
                    contribution(id: shared, work: 9)
                ),
                childC: WorkMeasure(
                    contribution(id: other, work: 5)
                ),
            ]
        )

        let firstMerge = try await store!.mergeInheritedWorkSnapshot(
            first,
            from: parentAuthorityKey
        )
        XCTAssertEqual(firstMerge, first)
        let firstRecovered = try await store!.inheritedWorkSnapshot()
        XCTAssertEqual(firstRecovered, first)
        let secondMerge = try await store!.mergeInheritedWorkSnapshot(
            olderButStronger,
            from: parentAuthorityKey
        )
        XCTAssertEqual(
            secondMerge,
            InheritedWorkSnapshot(
                revision: 8,
                workByBlock: [
                    childA: WorkMeasure(contribution(id: shared, work: 9)),
                    childC: WorkMeasure(contribution(id: other, work: 5)),
                ]
            )
        )
        let olderCoverage = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                childD: WorkMeasure(
                    contribution(id: late, work: 1)
                ),
            ]
        )
        let olderCoverageMerge = try await store!.mergeInheritedWorkSnapshot(
            olderCoverage,
            from: parentAuthorityKey
        )
        XCTAssertEqual(
            olderCoverageMerge,
            InheritedWorkSnapshot(
                revision: 8,
                workByBlock: [
                    childD: WorkMeasure(contribution(id: late, work: 1)),
                ]
            )
        )
        let olderCoverageReplay = try await store!.mergeInheritedWorkSnapshot(
            olderCoverage,
            from: parentAuthorityKey
        )
        XCTAssertNil(olderCoverageReplay)
        let dominatedRawStrengthening = InheritedWorkSnapshot(
            revision: 3,
            workByBlock: [
                childA: WorkMeasure(
                    contribution(id: shared, work: 7)
                ),
            ]
        )
        let dominatedRawMerge = try await store!.mergeInheritedWorkSnapshot(
            dominatedRawStrengthening,
            from: parentAuthorityKey
        )
        XCTAssertNil(dominatedRawMerge)
        let revisionOnly = InheritedWorkSnapshot(revision: 9, workByBlock: [:])
        let revisionMerge = try await store!.mergeInheritedWorkSnapshot(
            revisionOnly,
            from: parentAuthorityKey
        )
        XCTAssertEqual(revisionMerge, revisionOnly)
        let revisionReplay = try await store!.mergeInheritedWorkSnapshot(
            revisionOnly,
            from: parentAuthorityKey
        )
        XCTAssertNil(revisionReplay)
        let expected = first
            .union(olderButStronger)
            .union(olderCoverage)
            .union(dominatedRawStrengthening)
            .union(revisionOnly)
        let materialized = try await store!.inheritedWorkSnapshot()
        XCTAssertEqual(materialized, expected)
        XCTAssertEqual(
            materialized?.work(forBlock: childD).work(forGrind: late),
            UInt256(1)
        )

        let database = try NodeSQLite(path: path.path)
        let sourceColumns = try database.query("PRAGMA table_info(parent_work_source)")
            .compactMap { $0["name"]?.textValue }
        XCTAssertEqual(Set(sourceColumns), Set(["singleton", "revision", "fact_count"]))
        let source = try database.query(
            "SELECT revision, fact_count FROM parent_work_source WHERE singleton = 1"
        ).first
        XCTAssertEqual(source?["revision"]?.textValue, "9")
        XCTAssertEqual(source?["fact_count"]?.intValue, 3)
        let facts = try database.query(
            "SELECT block_cid, grind_id, work FROM parent_work_facts ORDER BY block_cid, grind_id"
        )
        let actualFacts: [[String]] = facts.map {
            [
                $0["block_cid"]?.textValue ?? "",
                $0["grind_id"]?.textValue ?? "",
                $0["work"]?.textValue ?? "",
            ]
        }
        let expectedFacts: [[String]] = [
            [childA, shared, UInt256(9).toHexString()],
            [childC, other, UInt256(5).toHexString()],
            [childD, late, UInt256(1).toHexString()],
        ].sorted { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
        XCTAssertEqual(actualFacts, expectedFacts)

        await XCTAssertThrowsErrorAsync(
            try await store!.mergeInheritedWorkSnapshot(
                first,
                from: String(repeating: "b", count: ParentWorkAuthorityKey.encodedByteCount)
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected configured-parent rejection, got \(error)")
            }
        }

        store = nil
        store = try makeStore(
            path: path,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let recovered = try await store!.inheritedWorkSnapshot()
        XCTAssertEqual(recovered, expected)
        XCTAssertThrowsError(try makeStore(
            path: path,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: String(
                repeating: "b",
                count: ParentWorkAuthorityKey.encodedByteCount
            )
        )) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected parent-authority wipe requirement, got \(error)")
            }
        }
    }

    func testInheritedWorkFactCountAllowsRevisionOnlyAndRejectsLostFacts()
        async throws {
        let child = inheritedWorkCID("child")
        let grind = inheritedWorkCID("grind")
        let revisionOnlyPath = temporaryDirectory().appendingPathComponent("state.db")
        var revisionOnlyStore: NodeStore? = try makeStore(
            path: revisionOnlyPath,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let revisionOnly = InheritedWorkSnapshot(revision: 8, workByBlock: [:])
        let revisionOnlyMerge = try await revisionOnlyStore!.mergeInheritedWorkSnapshot(
            revisionOnly,
            from: parentAuthorityKey
        )
        XCTAssertNotNil(revisionOnlyMerge)
        revisionOnlyStore = nil
        revisionOnlyStore = try makeStore(
            path: revisionOnlyPath,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let recoveredRevisionOnly = try await revisionOnlyStore!.inheritedWorkSnapshot()
        XCTAssertEqual(recoveredRevisionOnly, revisionOnly)

        let factPath = temporaryDirectory().appendingPathComponent("state.db")
        let factStore = try makeStore(
            path: factPath,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let factMerge = try await factStore.mergeInheritedWorkSnapshot(
            InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    child: WorkMeasure(contribution(id: grind, work: 1)),
                ]
            ),
            from: parentAuthorityKey
        )
        XCTAssertNotNil(factMerge)
        try NodeSQLite(path: factPath.path).execute("DELETE FROM parent_work_facts")
        await XCTAssertThrowsErrorAsync(try await factStore.inheritedWorkSnapshot()) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected fact-count corruption, got \(error)")
            }
        }
    }

    func testInheritedWorkStrengtheningAtOneLocationSurvivesRestart()
        async throws {
        let childA = inheritedWorkCID("child-a")
        let shared = inheritedWorkCID("shared")
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(
            path: path,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let initial = InheritedWorkSnapshot(
            revision: 10,
            workByBlock: [
                childA: WorkMeasure(contribution(id: shared, work: 5)),
            ]
        )
        let initialMerge = try await store!.mergeInheritedWorkSnapshot(
            initial,
            from: parentAuthorityKey
        )
        XCTAssertNotNil(initialMerge)

        store = nil
        store = try makeStore(
            path: path,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let dominatedPairStrengthening = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [
                childA: WorkMeasure(contribution(id: shared, work: 7)),
            ]
        )
        let dominatedMerge = try await store!.mergeInheritedWorkSnapshot(
            dominatedPairStrengthening,
            from: parentAuthorityKey
        )
        XCTAssertNotNil(dominatedMerge)

        store = nil
        store = try makeStore(
            path: path,
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let laterStrengthening = InheritedWorkSnapshot(
            revision: 11,
            workByBlock: [
                childA: WorkMeasure(contribution(id: shared, work: 12)),
            ]
        )
        let globalMerge = try await store!.mergeInheritedWorkSnapshot(
            laterStrengthening,
            from: parentAuthorityKey
        )
        XCTAssertNotNil(globalMerge)

        let recoveredSnapshot = try await store!.inheritedWorkSnapshot()
        let recovered = try XCTUnwrap(recoveredSnapshot)
        XCTAssertEqual(recovered.revision, 11)
        XCTAssertEqual(
            recovered.work(forBlock: childA).work(forGrind: shared),
            UInt256(12)
        )

        let rawFacts = try NodeSQLite(path: path.path).query(
            "SELECT block_cid, grind_id, work FROM parent_work_facts ORDER BY block_cid, grind_id"
        )
        let actualFacts: [[String]] = rawFacts.map {
            [
                $0["block_cid"]?.textValue ?? "",
                $0["grind_id"]?.textValue ?? "",
                $0["work"]?.textValue ?? "",
            ]
        }
        let expectedFacts: [[String]] = [
            [childA, shared, UInt256(12).toHexString()],
        ].sorted { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
        XCTAssertEqual(actualFacts, expectedFacts)
    }

    func testInheritedWorkRejectsMalformedFactsBeforePersisting() async throws {
        let child = inheritedWorkCID("child")
        let grind = inheritedWorkCID("grind")
        let alternateCID =
            "f01711220e9eb6c60800df90fc8e237ed53246f396e87579aba406aaa7976a056859ee22d"
        let canonicalCID = try XCTUnwrap(CIDIdentity.canonicalString(alternateCID))
        let store = try makeStore(
            chainPath: ["Nexus", "Payments"],
            spawningParentKey: parentAuthorityKey
        )
        let emptyBlock = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                "": WorkMeasure(contribution(id: grind, work: 1)),
            ]
        )
        let emptyGrind = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                child: WorkMeasure(contribution(id: "", work: 1)),
            ]
        )
        let emptyMeasure = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [child: .zero]
        )
        let zeroWork = try JSONDecoder().decode(
            InheritedWorkSnapshot.self,
            from: Data(
                "{\"revision\":1,\"workByBlock\":{\"\(child)\":{\"workByGrind\":{\"\(grind)\":\"0x0\"}}}}".utf8
            )
        )
        let alternateCIDSpelling = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                canonicalCID: WorkMeasure(contribution(id: alternateCID, work: 1)),
            ]
        )
        let alternateBlockCIDSpelling = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                alternateCID: WorkMeasure(contribution(id: grind, work: 1)),
            ]
        )

        for snapshot in [
            emptyBlock,
            emptyGrind,
            emptyMeasure,
            zeroWork,
            alternateCIDSpelling,
            alternateBlockCIDSpelling,
        ] {
            await XCTAssertThrowsErrorAsync(
                try await store.mergeInheritedWorkSnapshot(
                    snapshot,
                    from: parentAuthorityKey
                )
            ) { error in
                guard case NodeStoreError.invalidConfiguration = error else {
                    return XCTFail("expected malformed inherited-work rejection, got \(error)")
                }
            }
        }
        let recovered = try await store.inheritedWorkSnapshot()
        XCTAssertNil(recovered)
    }

    func testOutgoingChildEvidenceRequiresItsAcceptedLocalCarrier()
        async throws {
        let content = TestContentStore()
        let authority = try XCTUnwrap(ParentWorkAuthorityKey(parentAuthorityKey))
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(authority),
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec.withParentWorkAuthorityKey(authority),
            parentState: LatticeState.emptyHeader,
            children: ["Leaf": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Middle": carrier],
            timestamp: 3,
            target: UInt256.max,
            fetcher: content
        )
        let rootHeader = try BlockHeader(node: root)
        let carrierHeader = try BlockHeader(node: carrier)
        let leafHeader = try BlockHeader(node: leaf)
        try await rootHeader.storeRecursively(storer: content as any Storer)
        let upstream = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Middle",
            fetcher: content
        )
        let direct = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Leaf",
            fetcher: content
        )
        let proof = upstream.composing(hop: direct)
        let entries = try await acquisitionEntries(for: leaf, fetcher: content)

        let store = try makeStore(chainPath: ["Nexus", "Middle"])
        try await store.stage(
            blockBatch(
                postStateCID: "carrier-state",
                blockHash: carrierHeader.rawCID,
                parentBlockHash: rootHeader.rawCID,
                blockHeight: 1
            ),
            volumeRoots: []
        )
        try await persistIssuedChildProof(
            in: store,
            proof,
            child: leaf,
            acquisitionEntries: entries,
            parentCarrierCID: carrierHeader.rawCID
        )
        await XCTAssertThrowsErrorAsync(
            try await persistIssuedChildProof(
                in: store,
                proof,
                child: leaf,
                acquisitionEntries: entries,
                parentCarrierCID: rootHeader.rawCID
            )
        ) { error in
            XCTAssertEqual(
                error as? NodeStoreError,
                .invalidIssuedChildProof(leafHeader.rawCID)
            )
        }

        let unacceptedStore = try makeStore(chainPath: ["Nexus", "Middle"])
        try await persistIssuedChildProof(
            in: unacceptedStore,
            proof,
            child: leaf,
            acquisitionEntries: entries,
            parentCarrierCID: carrierHeader.rawCID
        )
        let unacceptedEvidence = try await unacceptedStore.issuedChildEvidence(
            childCID: leafHeader.rawCID,
            directory: "Leaf",
            rootCID: rootHeader.rawCID
        )
        XCTAssertNotNil(unacceptedEvidence)
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

    func testAdmissionReplayFailsWhenNormalizedFactRowsAreMissing() async throws {
        let factsPath = temporaryDirectory().appendingPathComponent("state.db")
        let factsStore = try makeStore(path: factsPath)
        let batch = blockBatch(postStateCID: "state", blockHash: "child")
        try await factsStore.stage(batch, volumeRoots: [])
        try NodeSQLite(path: factsPath.path).execute("DELETE FROM admission_facts")
        await XCTAssertThrowsErrorAsync(
            try await factsStore.stage(batch, volumeRoots: [])
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testAdmissionStagesHierarchyFactsWithItsBatch() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"child-genesis","parentWorkAuthorityKey":"\(parentAuthorityKey)"}
            """)
        let artifacts = AdmissionHierarchyArtifacts(
            carrierLink: carrier,
            carrierEvidence: nil,
            parentGenesisLinks: [genesis]
        )

        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            hierarchyArtifacts: artifacts
        )

        let storedCarrier = try await store.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "carrier"
        )
        let storedGenesis = try await store.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: "child-genesis"
        )
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(storedCarrier, carrier)
        XCTAssertEqual(storedGenesis, genesis)
        XCTAssertEqual(staged.count, 1)
    }

    func testNormalizedIndexAuditRejectsParentFactWithoutSource() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: []
            )
        )
        try await store.auditNormalizedIndexes()

        let payload = try JSONEncoder().encode(carrier)
        try NodeSQLite(path: path.path).execute(
            "INSERT INTO issued_parent_facts (kind, key_a, key_b, payload) VALUES ('carrier', 'extra', 'extra', ?1)",
            params: [.blob(payload)]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corrupt parent-fact index, got \(error)")
            }
        }
    }

    func testEvidenceOnlyAdmissionStagesItsVerifiedCarrierLink() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)

        try await store.stage(
            ChainAdmissionBatch(facts: [
                .work(ChainWorkFact(
                    blockHash: "carrier",
                    contribution: contribution(id: "grind", work: 7)
                )),
            ]),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: []
            )
        )

        let stored = try await store.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "carrier"
        )
        XCTAssertEqual(stored, carrier)
    }

    func testInvalidHierarchyArtifactRollsBackItsAdmissionBatch() async throws {
        let store = try makeStore()
        let outsideBatch = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"outside","rootCID":"root"}
            """)

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state", blockHash: "carrier"),
                volumeRoots: [],
                hierarchyArtifacts: AdmissionHierarchyArtifacts(
                    carrierLink: outsideBatch,
                    carrierEvidence: nil,
                    parentGenesisLinks: []
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected invalid hierarchy artifact, got \(error)")
            }
        }
        let staged = try await store.stagedAdmissions()
        let carrier = try await store.issuedParentCarrierLink(
            carrierCID: "outside",
            rootCID: "root"
        )
        XCTAssertTrue(staged.isEmpty)
        XCTAssertNil(carrier)
    }

    func testNexusHierarchyArtifactCannotClaimAnotherRoot() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"other-root"}
            """)

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state", blockHash: "carrier"),
                volumeRoots: [],
                hierarchyArtifacts: AdmissionHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: []
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected invalid Nexus hierarchy artifact, got \(error)")
            }
        }
    }

    func testAcceptedLeafPageUsesAnImmutableAdmissionSnapshot() async throws {
        let store = try makeStore()
        try await store.stage(
            blockBatch(postStateCID: "root-a-state", blockHash: "root-a"),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(postStateCID: "root-b-state", blockHash: "root-b"),
            volumeRoots: []
        )
        let first = try await store.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 1
        )
        XCTAssertEqual(first.blockCIDs, ["root-a"])

        try await store.stage(
            blockBatch(postStateCID: "root-c-state", blockHash: "root-c"),
            volumeRoots: []
        )
        let continued = try await store.acceptedLeafPage(
            afterCID: "root-a",
            snapshotSequence: first.snapshotSequence,
            limit: 1
        )
        let refreshed = try await store.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 16
        )
        XCTAssertEqual(continued.blockCIDs, ["root-b"])
        XCTAssertEqual(refreshed.blockCIDs, ["root-a", "root-b", "root-c"])
    }

    func testNormalizedIndexAuditRequiresExactBatchDerivedRows() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "child"),
            volumeRoots: []
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

    func testNormalizedIndexAuditRejectsMissingAcceptedBlockRow() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "accepted"),
            volumeRoots: []
        )
        try await store.auditNormalizedIndexes()

        try NodeSQLite(path: path.path).execute(
            "DELETE FROM accepted_blocks WHERE block_cid = ?1",
            params: [.text("accepted")]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testIssuedParentFactsAreDurable() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"genesis","parentWorkAuthorityKey":"\(parentAuthorityKey)"}
            """)

        try await store!.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: [genesis]
            )
        )
        store = nil
        store = try makeStore(path: path)

        let storedCarrier = try await store!.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "carrier"
        )
        let storedGenesis = try await store!.issuedParentGenesisLink(
            directory: "Child",
            childGenesisCID: "genesis"
        )
        XCTAssertEqual(storedCarrier, carrier)
        XCTAssertEqual(storedGenesis, genesis)
    }

    func testIssuedChildProofsAreSetValuedContentBoundAndDurable() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let fixture = try await childProofFixture()

        try await persistIssuedChildProof(
            in: store!,
            fixture.first,
            child: fixture.child,
            acquisitionEntries: fixture.acquisitionEntries
        )
        try await persistIssuedChildProof(
            in: store!,
            fixture.second,
            child: fixture.child,
            acquisitionEntries: fixture.acquisitionEntries
        )

        let selectedValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child"
        )
        let selected = try XCTUnwrap(selectedValue).proof
        XCTAssertEqual(
            selected.rootCID,
            min(fixture.first.rootCID, fixture.second.rootCID)
        )
        let firstPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: nil,
            limit: 1
        )
        let secondPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(firstPage.last),
            limit: 1
        )
        let exhaustedPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(secondPage.last),
            limit: 1
        )
        XCTAssertEqual(
            firstPage + secondPage,
            [fixture.first.rootCID, fixture.second.rootCID].sorted()
        )
        XCTAssertTrue(exhaustedPage.isEmpty)
        let exactValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.second.rootCID
        )
        let exact = try XCTUnwrap(exactValue).proof
        XCTAssertEqual(try exact.serialize(), try fixture.second.serialize())

        store = nil
        store = try makeStore(path: path)
        let recoveredValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let recovered = try XCTUnwrap(recoveredValue).proof
        XCTAssertEqual(try recovered.serialize(), try fixture.first.serialize())
        let recoveredEvidenceValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let recoveredEvidence = try XCTUnwrap(recoveredEvidenceValue)
        XCTAssertEqual(recoveredEvidence.child.toData(), fixture.child.toData())

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
            try await persistIssuedChildProof(
                in: store!,
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

    func testIssuedChildProofsKeepSameChildDistinctAcrossDirectories() async throws {
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
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Alpha": child, "Beta": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: content as any Storer)
        let alpha = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Alpha",
            fetcher: content
        )
        let beta = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Beta",
            fetcher: content
        )
        let acquisitionEntries = try await acquisitionEntries(
            for: child,
            fetcher: content
        )
        let store = try makeStore()

        try await persistIssuedChildProof(
            in: store,
            alpha,
            child: child,
            acquisitionEntries: acquisitionEntries
        )
        try await persistIssuedChildProof(
            in: store,
            beta,
            child: child,
            acquisitionEntries: acquisitionEntries
        )

        let alphaValue = try await store.issuedChildEvidence(
            childCID: childCID,
            directory: "Alpha",
            rootCID: carrierHeader.rawCID
        )
        let betaValue = try await store.issuedChildEvidence(
            childCID: childCID,
            directory: "Beta",
            rootCID: carrierHeader.rawCID
        )
        let alphaProof = try XCTUnwrap(alphaValue).proof
        let betaProof = try XCTUnwrap(betaValue).proof
        XCTAssertEqual(try alphaProof.serialize(), try alpha.serialize())
        XCTAssertEqual(try betaProof.serialize(), try beta.serialize())
        let alphaRoots = try await store.issuedChildProofRoots(
            childCID: childCID,
            directory: "Alpha",
            afterRootCID: nil,
            limit: 2
        )
        XCTAssertEqual(
            alphaRoots,
            [carrierHeader.rawCID]
        )

        let historicalAlpha = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Alpha","childGenesisCID":"historical-alpha-genesis","parentWorkAuthorityKey":"\(parentAuthorityKey)"}
            """)
        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                    """),
                carrierEvidence: nil,
                parentGenesisLinks: [historicalAlpha]
            )
        )
        let alphaSummaries = try await store.issuedChildEvidenceSummaries(
            directory: "Alpha",
            after: nil,
            limit: 2
        )
        XCTAssertEqual(alphaSummaries.count, 1)
        XCTAssertEqual(alphaSummaries.first?.childCID, childCID)
        XCTAssertEqual(alphaSummaries.first?.rootCID, carrierHeader.rawCID)
        XCTAssertTrue(alphaSummaries.first.map {
            CIDIdentity.isCanonical($0.attachmentCID)
        } ?? false)
        let betaSummaries = try await store.issuedChildEvidenceSummaries(
            directory: "Beta",
            after: nil,
            limit: 2
        )
        XCTAssertTrue(betaSummaries.isEmpty)
    }

    func testIssuedCarrierEvidencePersistsProofAndLinkTogether() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path, chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        let link = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.first.rootCID)"}
            """)

        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: link,
                carrierEvidence: AdmissionCarrierEvidence(
                    proof: fixture.first,
                    child: fixture.child,
                    acquisitionEntries: fixture.acquisitionEntries
                ),
                parentGenesisLinks: []
            )
        )

        let storedLink = try await store.issuedParentCarrierLink(
            carrierCID: fixture.childCID,
            rootCID: fixture.first.rootCID
        )
        XCTAssertEqual(storedLink, link)
        let proofValue = try await store.incomingCarrierEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )?.proof
        let proof = try XCTUnwrap(proofValue)
        XCTAssertEqual(try proof.serialize(), try fixture.first.serialize())
        let incomingCoverage = try await store
            .incomingParentCarrierBlocksByChildBlock()
        XCTAssertEqual(Set(incomingCoverage.keys), [fixture.childCID])
    }

    func testIncomingCarrierProofRootsPageAcrossContexts() async throws {
        let store = try makeStore(chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        for proof in [fixture.first, fixture.second] {
            try await store.persistIssuedHierarchyArtifacts(
                AdmissionHierarchyArtifacts(
                    carrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(proof.rootCID)"}
                        """),
                    carrierEvidence: AdmissionCarrierEvidence(
                        proof: proof,
                        child: fixture.child,
                        acquisitionEntries: fixture.acquisitionEntries
                    ),
                    parentGenesisLinks: []
                )
            )
        }

        let firstPage = try await store.incomingCarrierProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: nil,
            limit: 1
        )
        let secondPage = try await store.incomingCarrierProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(firstPage.last),
            limit: 1
        )
        let exhaustedPage = try await store.incomingCarrierProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(secondPage.last),
            limit: 1
        )
        XCTAssertEqual(
            firstPage + secondPage,
            [fixture.first.rootCID, fixture.second.rootCID].sorted()
        )
        XCTAssertTrue(exhaustedPage.isEmpty)
    }

    func testIncomingAndOutgoingAttachmentsShareOneDirectEdgeAcrossRoots()
        async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["A": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let leafCID = try BlockHeader(node: leaf).rawCID
        let direct = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "A",
            fetcher: content
        )
        var absoluteProofs: [ChildBlockProof] = []
        for timestamp in [Int64(3), Int64(4)] {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["A": carrier],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content as any Storer)
            absoluteProofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "A",
                fetcher: content
            ).composing(hop: direct))
        }

        let parentPath = temporaryDirectory().appendingPathComponent("state.db")
        let parent = try makeStore(
            path: parentPath,
            chainPath: ["Nexus", "A"]
        )
        let child = try makeStore(chainPath: ["Nexus", "A", "A"])
        try await parent.stage(
            blockBatch(
                postStateCID: "carrier-state",
                blockHash: carrierHeader.rawCID
            ),
            volumeRoots: []
        )
        let entries = try await acquisitionEntries(for: leaf, fetcher: content)
        for proof in absoluteProofs {
            try await persistIssuedChildProof(
                in: parent,
                proof,
                child: leaf,
                acquisitionEntries: entries,
                parentCarrierCID: carrierHeader.rawCID
            )
            try await child.persistIssuedHierarchyArtifacts(
                AdmissionHierarchyArtifacts(
                    carrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus","A","A"],"carrierCID":"\(leafCID)","rootCID":"\(proof.rootCID)"}
                        """),
                    carrierEvidence: AdmissionCarrierEvidence(
                        proof: proof,
                        child: leaf,
                        acquisitionEntries: entries
                    ),
                    parentGenesisLinks: []
                )
            )
        }

        let parentAttachments = try await parent.childRootAttachmentSummaries(
            scope: .outgoingDirectChild,
            directory: "A",
            after: nil,
            limit: 3
        )
        let childAttachments = try await child.childRootAttachmentSummaries(
            scope: .incomingCarrier,
            directory: "A",
            after: nil,
            limit: 3
        )
        let portableAttachments = try await child.childRootAttachmentSummaries(
            scope: .incomingCarrier,
            directory: "A",
            after: nil,
            limit: 3,
            portableOnly: true
        )
        XCTAssertEqual(
            parentAttachments.map { [$0.edgeCID, $0.rootCID] },
            childAttachments.map { [$0.edgeCID, $0.rootCID] }
        )
        XCTAssertTrue(portableAttachments.isEmpty)
        XCTAssertEqual(parentAttachments.count, 2)
        XCTAssertEqual(Set(parentAttachments.map(\.edgeCID)).count, 1)
        XCTAssertEqual(
            Set(parentAttachments.map(\.rootCID)),
            Set(absoluteProofs.map(\.rootCID))
        )
        let database = try NodeSQLite(path: parentPath.path)
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) AS count FROM issued_child_edges"
            ).first?["count"]?.intValue,
            1
        )
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) AS count FROM issued_child_proofs"
            ).first?["count"]?.intValue,
            2
        )

        let derivedEdge = await DirectChildEdge.derive(from: absoluteProofs[0])
        let edge = try XCTUnwrap(derivedEdge)
        XCTAssertEqual(edge.parentCarrierCID, carrierHeader.rawCID)
        XCTAssertEqual(edge.childCID, leafCID)
        XCTAssertEqual(edge.directory, "A")
        XCTAssertEqual(edge.proofBytes, try direct.serialize())
        let attachment = try await child.issuedChildEvidence(
            scope: .incomingCarrier,
            edgeCID: try XCTUnwrap(edge.edgeCID),
            rootCID: absoluteProofs[1].rootCID
        )
        XCTAssertEqual(attachment?.edgeCID, edge.edgeCID)
        XCTAssertEqual(
            try attachment?.proof.serialize(),
            try absoluteProofs[1].serialize()
        )
        let tables = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).compactMap { $0["name"]?.textValue }
        XCTAssertFalse(tables.contains("issued_child_blocks"))
        XCTAssertEqual(
            Set(try database.query("PRAGMA table_info(issued_child_edges)")
                .compactMap { $0["name"]?.textValue }),
            Set([
                "edge_cid", "parent_carrier_cid", "directory", "child_cid",
                "direct_attachment_cid",
            ])
        )
        XCTAssertEqual(
            Set(try database.query("PRAGMA table_info(issued_child_proofs)")
                .compactMap { $0["name"]?.textValue }),
            Set([
                "scope", "edge_cid", "root_cid", "is_portable",
                "attachment_cid",
            ])
        )

        let proofRow = try XCTUnwrap(try database.query(
            "SELECT scope, edge_cid, root_cid, attachment_cid FROM issued_child_proofs LIMIT 1"
        ).first)
        let storedAttachmentCID = try XCTUnwrap(
            proofRow["attachment_cid"]?.textValue
        )
        let missingAttachmentCID = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "missing-evidence-volume")
        ).rawCID
        try database.execute(
            "UPDATE issued_child_proofs SET attachment_cid = ?1 WHERE scope = ?2 AND edge_cid = ?3 AND root_cid = ?4",
            params: [
                .text(missingAttachmentCID),
                .text(try XCTUnwrap(proofRow["scope"]?.textValue)),
                .text(try XCTUnwrap(proofRow["edge_cid"]?.textValue)),
                .text(try XCTUnwrap(proofRow["root_cid"]?.textValue)),
            ]
        )
        await XCTAssertThrowsErrorAsync(
            try await parent.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected missing attachment corruption, got \(error)")
            }
        }
        try database.execute(
            "UPDATE issued_child_proofs SET attachment_cid = ?1 WHERE attachment_cid = ?2",
            params: [.text(storedAttachmentCID), .text(missingAttachmentCID)]
        )

        try NodeSQLite(path: parentPath.path).execute(
            "UPDATE issued_child_edges SET child_cid = ?1",
            params: [.text(try BlockHeader(node: carrier).rawCID)]
        )
        await XCTAssertThrowsErrorAsync(
            try await parent.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corrupt edge index, got \(error)")
            }
        }
    }

    func testIncomingCarrierProofIsNeverAdvertisedAsOutgoingChildProof() async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["A": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["A": carrier],
            timestamp: 3,
            target: UInt256.max,
            fetcher: content
        )
        let rootHeader = try BlockHeader(node: root)
        let leafCID = try BlockHeader(node: leaf).rawCID
        try await rootHeader.storeRecursively(storer: content as any Storer)
        let incoming = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "A",
            fetcher: content
        )
        let direct = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "A",
            fetcher: content
        )
        let outgoing = incoming.composing(hop: direct)
        let store = try makeStore(chainPath: ["Nexus", "A"])

        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus","A"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(rootHeader.rawCID)"}
                    """),
                carrierEvidence: AdmissionCarrierEvidence(
                    proof: incoming,
                    child: carrier,
                    acquisitionEntries: try await acquisitionEntries(
                        for: carrier,
                        fetcher: content
                    )
                ),
                parentGenesisLinks: [try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus","A"],"directory":"A","childGenesisCID":"\(leafCID)","parentWorkAuthorityKey":"\(parentAuthorityKey)"}
                    """)]
            )
        )
        try await persistIssuedChildProof(
            in: store,
            outgoing,
            child: leaf,
            acquisitionEntries: try await acquisitionEntries(
                for: leaf,
                fetcher: content
            )
        )
        let carrierRoots = try await store.incomingCarrierProofRoots(
            childCID: carrierHeader.rawCID,
            directory: "A",
            afterRootCID: nil,
            limit: 1
        )
        XCTAssertEqual(carrierRoots, [rootHeader.rawCID])
        XCTAssertNotEqual(carrierRoots, [carrierHeader.rawCID])
        let outgoingCarrierEvidence = try await store.issuedChildEvidence(
            childCID: carrierHeader.rawCID,
            directory: "A",
            rootCID: rootHeader.rawCID
        )
        XCTAssertNil(outgoingCarrierEvidence)
        let incomingCarrierEvidence = try await store.incomingCarrierEvidence(
            childCID: carrierHeader.rawCID,
            directory: "A",
            rootCID: rootHeader.rawCID
        )
        XCTAssertNotNil(incomingCarrierEvidence)
        let summaries = try await store.issuedChildEvidenceSummaries(
            directory: "A",
            after: nil,
            limit: 2
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.childCID, leafCID)
        XCTAssertEqual(summaries.first?.rootCID, rootHeader.rawCID)
        XCTAssertTrue(summaries.first.map {
            CIDIdentity.isCanonical($0.attachmentCID)
        } ?? false)
    }

    func testOutgoingCertificateIsReverifiedFromDurableVolume() async throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        let fixture = try await childProofFixture()
        try await persistIssuedChildProof(
            in: store,
            fixture.first,
            child: fixture.child,
            acquisitionEntries: fixture.acquisitionEntries
        )
        let storedEvidence = try await store.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let evidence = try XCTUnwrap(storedEvidence)

        var signature = try XCTUnwrap(
            evidence.parentCarrierCertificate
        ).encode()
        signature[signature.startIndex] ^= 1
        let invalidCertificate = try ParentCarrierCertificateV1.decode(signature)
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(
                proof: evidence.proof,
                parentCarrierLink: evidence.parentCarrierLink,
                parentGenesisLink: evidence.parentGenesisLink
            ),
            parentCarrierCertificate: invalidCertificate,
            parentGenesisCertificate: evidence.parentGenesisCertificate
        )
        let invalidAttachment = try ChildEvidenceVolume(
            envelopeBytes: try envelope.encode(),
            acquisitionEntries: evidence.acquisitionEntries,
            childCID: fixture.childCID
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        try await invalidAttachment.store(storer: BrokerStorer(broker: broker))
        try NodeSQLite(path: path.path).execute(
            "UPDATE issued_child_proofs SET attachment_cid = ?1 WHERE scope = ?2 AND edge_cid = ?3 AND root_cid = ?4",
            params: [
                .text(invalidAttachment.rawCID),
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(evidence.edgeCID),
                .text(fixture.first.rootCID),
            ]
        )

        await XCTAssertThrowsErrorAsync(try await store.auditNormalizedIndexes()) {
            error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected invalid durable certificate, got \(error)")
            }
        }
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
        let extra = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "different-prepared-child-proof")
        )
        conflictingEntries[extra.rawCID] = try extra.mapToData()
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
        try await carrierHeader.storeRecursively(storer: content as any Storer)
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
        let broker = MemoryBroker()
        let admission = NodeAdmissionStorage(storage: BrokerStorer(broker: broker))
        let node = PublicKey(key: "actual-volume")
        let header = try HeaderImpl<PublicKey>(node: node)
        let root = header.rawCID
        try await admission.store(volume: SerializedVolume(
            root: root,
            entries: [root: try header.mapToData()]
        ))

        let recordedRoots = await admission.takeStoredVolumeRoots()
        let drainedRoots = await admission.takeStoredVolumeRoots()
        XCTAssertEqual(recordedRoots, [root])
        XCTAssertTrue(drainedRoots.isEmpty)
        let hasVolume = await broker.hasVolume(root: root)
        XCTAssertTrue(hasVolume)
    }

    private func makeStore(
        path: URL? = nil,
        genesisCID: String? = nil,
        chainPath: [String] = ["Nexus"],
        minimumRootWork: UInt256 = UInt256(1),
        spawningParentKey: String? = nil,
        issuingAuthorityKey: String? = nil
    ) throws -> NodeStore {
        let path = path ?? temporaryDirectory().appendingPathComponent("state.db")
        let broker = try DiskBroker(
            path: path.deletingLastPathComponent()
                .appendingPathComponent("volumes.db").path
        )
        let issuer = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: path.deletingLastPathComponent(),
            privateKeyHex: String(repeating: "7a", count: 32)
        )
        return try NodeStore(
            databasePath: path,
            nexusGenesisCID: genesisCID ?? self.genesisCID,
            chainPath: chainPath,
            minimumRootWork: minimumRootWork,
            spawningParentKey: spawningParentKey ?? (chainPath.count == 1
                ? ""
                : String(repeating: "a", count: ParentWorkAuthorityKey.encodedByteCount)),
            issuingAuthorityKey: issuingAuthorityKey ?? issuer.processPublicKey,
            recoveryVolumeStorer: BrokerStorer(broker: broker),
            recoveryVolumeBroker: broker
        )
    }

    private func persistIssuedChildProof(
        in store: NodeStore,
        _ proof: ChildBlockProof,
        child: Block,
        acquisitionEntries: [String: Data],
        parentCarrierCID: String? = nil
    ) async throws {
        let chainPath = ["Nexus"] + Array(proof.directoryPath.dropLast())
        let parentIdentity = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: "7b", count: 32)
        )
        let configuration = try NodeConfiguration(
            chainPath: Array(chainPath),
            minimumRootWork: UInt256(1),
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: "7a", count: 32),
            parentEndpoint: chainPath.count == 1 ? nil : ParentEndpoint(
                publicKey: parentIdentity.processPublicKey,
                host: "127.0.0.1",
                port: 4002
            )
        )
        let derivedEdge = await DirectChildEdge.derive(from: proof)
        let edge = try XCTUnwrap(derivedEdge)
        let pathJSON = String(
            data: try JSONEncoder().encode(chainPath),
            encoding: .utf8
        )!
        let carrierLink = try decode(ParentCarrierLink.self, json: """
            {"parentPath":\(pathJSON),"carrierCID":"\(edge.parentCarrierCID)","rootCID":"\(proof.rootCID)"}
            """)
        let childCID = try BlockHeader(node: child).rawCID
        let genesisLink: ParentGenesisLink?
        if child.parent == nil {
            genesisLink = try decode(ParentGenesisLink.self, json: """
                {"parentPath":\(pathJSON),"directory":"\(edge.directory)","childGenesisCID":"\(childCID)","parentWorkAuthorityKey":"\(configuration.processPublicKey)"}
                """)
        } else {
            genesisLink = nil
        }
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(
                proof: proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: genesisLink
            ),
            certificatesSignedBy: configuration
        )
        try await store.persistIssuedChildProof(
            proof,
            child: child,
            acquisitionEntries: acquisitionEntries,
            parentCarrierCID: parentCarrierCID,
            rootEnvelope: envelope,
            rootAuthorityKey: try XCTUnwrap(ParentWorkAuthorityKey(
                configuration.processPublicKey
            ))
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
        blockHash: String = "same-block",
        parentBlockHash: String? = nil,
        blockHeight: UInt64 = 0
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: blockHash,
                parentBlockHash: parentBlockHash,
                blockHeight: blockHeight,
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
            try await rootHeader.storeRecursively(storer: content as any Storer)
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

private actor TestContentStore: Fetcher, Storer, VolumeStorer {
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
