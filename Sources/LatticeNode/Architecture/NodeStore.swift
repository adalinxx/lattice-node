import Foundation
import Lattice
import UInt256
import cashew

enum NodeStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case wipeRequired(String)
    case conflictingContent(String)
    case conflictingAdmissionFact
    case conflictingAdmissionBatch
    case conflictingIssuedParentFact
    case conflictingIssuedChildProof
    case invalidParentCoverage(String)
    case invalidIssuedChildProof(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Invalid node store configuration: \(reason)"
        case .wipeRequired(let reason):
            "The node store is incompatible (\(reason)); stop the process, delete its entire configured storage directory (state.db and volumes.db), and restart."
        case .conflictingContent(let cid):
            "Conflicting bytes for immutable validation content \(cid)."
        case .conflictingAdmissionFact:
            "Conflicting bytes for an immutable chain fact."
        case .conflictingAdmissionBatch:
            "An admission batch was replayed with different Volume roots."
        case .conflictingIssuedParentFact:
            "A locally issued parent fact was replayed with different bytes."
        case .conflictingIssuedChildProof:
            "A locally issued child proof was replayed with different bytes."
        case .invalidParentCoverage(let childCID):
            "Parent coverage references child \(childCID) outside its admission batch."
        case .invalidIssuedChildProof(let childCID):
            "The proof cached for child \(childCID) does not prove that child from this chain path."
        case .corrupt(let reason):
            "The node store is corrupt: \(reason)"
        }
    }
}

struct StagedAdmission: Sendable, Equatable {
    let sequence: Int64
    let batch: ChainAdmissionBatch
    let volumeRoots: [String]
    let parentCoverage: [ParentCoverageBinding]
}

struct ParentCoverageBinding: Codable, Hashable, Sendable {
    let childBlockCID: String
    let parentCarrierCID: String
}

struct IssuedChildEvidence: Sendable {
    let proof: ChildBlockProof
    let child: Block
    let childData: Data
    let acquisitionEntries: [String: Data]
}

struct IssuedChildEvidenceSummary: Codable, Equatable, Hashable, Sendable {
    let childCID: String
    let rootCID: String
}

struct PreparedChildProof: Sendable {
    let directory: String
    let childCID: String
    let child: Block
    let proof: ChildBlockProof
    let acquisitionEntries: [String: Data]

    init(
        directory: String,
        child: Block,
        proof: ChildBlockProof,
        acquisitionEntries: [String: Data]
    ) throws {
        self.directory = directory
        let childCID = try BlockHeader(node: child).rawCID
        self.childCID = childCID
        self.child = child
        self.proof = proof
        self.acquisitionEntries = acquisitionEntries
    }
}

struct PendingChildProofRoute: Sendable, Hashable {
    let carrierCID: String
    let directory: String
}

/// Node-owned immutable facts and recovery inputs for exactly one absolute path.
actor NodeStore: Storer, Fetcher, ContentSource {
    static let currentSchemaEpoch: Int64 = 3

    private let database: NodeSQLite
    private let chainPath: [String]

    init(
        databasePath: URL,
        nexusGenesisCID: String,
        chainPath: [String],
        minimumRootWork: UInt256
    ) throws {
        guard !nexusGenesisCID.isEmpty else {
            throw NodeStoreError.invalidConfiguration("Nexus genesis CID is empty")
        }
        guard chainPath.first == "Nexus", chainPath.allSatisfy({ !$0.isEmpty }) else {
            throw NodeStoreError.invalidConfiguration("chainPath must be absolute and begin with Nexus")
        }
        guard minimumRootWork > .zero else {
            throw NodeStoreError.invalidConfiguration("minimum root work must be nonzero")
        }

        let database = try NodeSQLite(path: databasePath.path)
        let pathData = try Self.encode(chainPath)
        let minimumRootWorkHex = minimumRootWork.toHexString()
        let tables = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
        let tableNames = Set(tables.compactMap { $0["name"]?.textValue })

        if tableNames.isEmpty {
            try Self.createSchema(
                in: database,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData,
                minimumRootWorkHex: minimumRootWorkHex
            )
        } else {
            try Self.validateMetadata(
                in: database,
                tableNames: tableNames,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData,
                minimumRootWorkHex: minimumRootWorkHex
            )
            guard tableNames == Self.expectedTables else {
                throw NodeStoreError.wipeRequired("schema tables are missing or unexpected")
            }
        }
        try database.configureDurability()

        self.database = database
        self.chainPath = chainPath
    }

    func store(entries: [String: Data]) async throws {
        try database.transaction {
            for cid in entries.keys.sorted() {
                guard let data = entries[cid] else { continue }
                let rows = try database.query(
                    "SELECT data FROM validation_content WHERE cid = ?1",
                    params: [.text(cid)]
                )
                if let existing = rows.first?["data"]?.blobValue {
                    guard existing == data else {
                        throw NodeStoreError.conflictingContent(cid)
                    }
                } else {
                    try database.execute(
                        "INSERT INTO validation_content (cid, data) VALUES (?1, ?2)",
                        params: [.text(cid), .blob(data)]
                    )
                }
            }
        }
    }

    func fetch(rawCid: String) async throws -> Data {
        let rows = try database.query(
            "SELECT data FROM validation_content WHERE cid = ?1",
            params: [.text(rawCid)]
        )
        guard let data = rows.first?["data"]?.blobValue else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var entries: [String: Data] = [:]
        for cid in cids.sorted() {
            let rows = try? database.query(
                "SELECT data FROM validation_content WHERE cid = ?1",
                params: [.text(cid)]
            )
            if let data = rows?.first?["data"]?.blobValue {
                entries[cid] = data
            }
        }
        return entries
    }

    func stage(
        _ batch: ChainAdmissionBatch,
        volumeRoots: [String],
        parentCoverage: [ParentCoverageBinding] = [],
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16
    ) async throws {
        let payload = try Self.encode(batch)
        let rootsPayload = try Self.encode(Array(Set(volumeRoots)).sorted())
        let coverage = Array(Set(parentCoverage)).sorted {
            ($0.childBlockCID, $0.parentCarrierCID)
                < ($1.childBlockCID, $1.parentCarrierCID)
        }
        try Self.validate(coverage: coverage, in: batch)
        let coveragePayload = try Self.encode(coverage)
        let factsInBatch = try Self.normalizedFacts(in: batch)
        let facts = factsInBatch.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        let pendingRoutes = Array(Set(pendingChildProofRoutes)).sorted {
            ($0.carrierCID, $0.directory) < ($1.carrierCID, $1.directory)
        }
        let blockCIDs = Set(batch.facts.compactMap { fact -> String? in
            guard case .block(let block) = fact else { return nil }
            return block.blockHash
        })
        guard pendingRoutes.allSatisfy({
            blockCIDs.contains($0.carrierCID) && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route is outside its admission batch"
            )
        }

        try database.transaction {
            for fact in facts {
                let rows = try database.query(
                    "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                    params: [.blob(fact.key)]
                )
                if let existing = rows.first?["payload"]?.blobValue {
                    guard existing == fact.value else {
                        throw NodeStoreError.conflictingAdmissionFact
                    }
                }
            }

            let replay = try database.query(
                "SELECT volume_roots, parent_coverage FROM admission_batches WHERE payload = ?1",
                params: [.blob(payload)]
            )
            if let existing = replay.first,
               let existingRoots = existing["volume_roots"]?.blobValue,
               let existingCoverage = existing["parent_coverage"]?.blobValue {
                guard existingRoots == rootsPayload,
                      existingCoverage == coveragePayload else {
                    throw NodeStoreError.conflictingAdmissionBatch
                }
                for fact in facts {
                    let rows = try database.query(
                        "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                        params: [.blob(fact.key)]
                    )
                    guard rows.first?["payload"]?.blobValue == fact.value else {
                        throw NodeStoreError.corrupt(
                            "an admission batch is missing its normalized fact"
                        )
                    }
                }
                for binding in coverage {
                    let rows = try database.query(
                        "SELECT 1 AS present FROM parent_coverage WHERE child_cid = ?1 AND parent_carrier_cid = ?2",
                        params: [
                            .text(binding.childBlockCID),
                            .text(binding.parentCarrierCID),
                        ]
                    )
                    guard !rows.isEmpty else {
                        throw NodeStoreError.corrupt(
                            "an admission batch is missing its normalized parent coverage"
                        )
                    }
                }
                try persistPendingChildProofRouteRows(
                    pendingRoutes,
                    capacity: pendingChildProofCapacity
                )
                return
            }

            try database.execute(
                "INSERT INTO admission_batches (payload, volume_roots, parent_coverage) VALUES (?1, ?2, ?3)",
                params: [.blob(payload), .blob(rootsPayload), .blob(coveragePayload)]
            )
            for fact in facts {
                let existing = try database.query(
                    "SELECT 1 AS present FROM admission_facts WHERE fact_id = ?1",
                    params: [.blob(fact.key)]
                )
                if existing.isEmpty {
                    try database.execute(
                        "INSERT INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
                        params: [.blob(fact.key), .blob(fact.value)]
                    )
                }
            }
            for binding in coverage {
                try database.execute(
                    "INSERT OR IGNORE INTO parent_coverage (child_cid, parent_carrier_cid) VALUES (?1, ?2)",
                    params: [.text(binding.childBlockCID), .text(binding.parentCarrierCID)]
                )
            }
            try persistPendingChildProofRouteRows(
                pendingRoutes,
                capacity: pendingChildProofCapacity
            )
        }
    }

    func stagedAdmissions() async throws -> [StagedAdmission] {
        try loadStagedAdmissions()
    }

    func auditNormalizedIndexes() async throws {
        let staged = try loadStagedAdmissions()
        var expectedFacts: [Data: Data] = [:]
        var expectedCoverage = Set<ParentCoverageBinding>()

        for admission in staged {
            try Self.validate(coverage: admission.parentCoverage, in: admission.batch)
            for (id, payload) in try Self.normalizedFacts(in: admission.batch) {
                if let existing = expectedFacts[id], existing != payload {
                    throw NodeStoreError.corrupt(
                        "admission batches disagree about an immutable fact"
                    )
                }
                expectedFacts[id] = payload
            }
            expectedCoverage.formUnion(admission.parentCoverage)
        }

        var actualFacts: [Data: Data] = [:]
        for row in try database.query("SELECT fact_id, payload FROM admission_facts") {
            guard let id = row["fact_id"]?.blobValue,
                  let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed normalized admission fact")
            }
            actualFacts[id] = payload
        }
        guard actualFacts == expectedFacts else {
            throw NodeStoreError.corrupt(
                "normalized admission facts do not match immutable batches"
            )
        }

        var actualCoverage = Set<ParentCoverageBinding>()
        for row in try database.query(
            "SELECT child_cid, parent_carrier_cid FROM parent_coverage"
        ) {
            guard let child = row["child_cid"]?.textValue,
                  let parent = row["parent_carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt("malformed normalized parent coverage")
            }
            actualCoverage.insert(ParentCoverageBinding(
                childBlockCID: child,
                parentCarrierCID: parent
            ))
        }
        guard actualCoverage == expectedCoverage else {
            throw NodeStoreError.corrupt(
                "normalized parent coverage does not match immutable batches"
            )
        }
    }

    func persistIssuedParentCarrierLink(
        _ link: ParentCarrierLink,
        issuerKey: String,
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16
    ) async throws {
        guard link.parentPath == chainPath else {
            throw NodeStoreError.invalidConfiguration(
                "issued carrier link belongs to a different chain path"
            )
        }
        guard pendingChildProofRoutes.allSatisfy({
            $0.carrierCID == link.carrierCID && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route belongs to another carrier"
            )
        }
        try database.transaction {
            try persistIssuedParentFact(
                kind: "carrier",
                keyA: link.carrierCID,
                keyB: link.rootCID,
                payload: Self.encode(link),
                issuerKey: issuerKey
            )
            try persistPendingChildProofRouteRows(
                pendingChildProofRoutes,
                capacity: pendingChildProofCapacity
            )
        }
    }

    func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String,
        issuerKey: String
    ) async throws -> ParentCarrierLink? {
        guard let payload = try issuedParentFact(
            kind: "carrier",
            keyA: carrierCID,
            keyB: rootCID,
            issuerKey: issuerKey
        ) else { return nil }
        let link = try Self.decode(ParentCarrierLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.carrierCID == carrierCID,
              link.rootCID == rootCID else {
            throw NodeStoreError.corrupt("malformed locally issued carrier link")
        }
        return link
    }

    func persistIssuedParentGenesisLink(
        _ link: ParentGenesisLink,
        issuerKey: String
    ) async throws {
        guard link.parentPath == chainPath else {
            throw NodeStoreError.invalidConfiguration(
                "issued genesis link belongs to a different chain path"
            )
        }
        try persistIssuedParentFact(
            kind: "genesis",
            keyA: link.directory,
            keyB: link.childGenesisCID,
            payload: Self.encode(link),
            issuerKey: issuerKey
        )
    }

    func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String,
        issuerKey: String
    ) async throws -> ParentGenesisLink? {
        guard let payload = try issuedParentFact(
            kind: "genesis",
            keyA: directory,
            keyB: childGenesisCID,
            issuerKey: issuerKey
        ) else { return nil }
        let link = try Self.decode(ParentGenesisLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.directory == directory,
              link.childGenesisCID == childGenesisCID else {
            throw NodeStoreError.corrupt("malformed locally issued genesis link")
        }
        return link
    }

    func hasIssuedChildDirectory(
        _ directory: String,
        issuerKey: String
    ) throws -> Bool {
        let rows = try database.query(
            "SELECT key_b, payload FROM issued_parent_facts WHERE issuer_key = ?1 AND kind = 'genesis' AND key_a = ?2 ORDER BY key_b",
            params: [.text(issuerKey), .text(directory)]
        )
        for row in rows {
            guard let childGenesisCID = row["key_b"]?.textValue,
                  let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt(
                    "malformed locally issued child-directory index"
                )
            }
            let link = try Self.decode(ParentGenesisLink.self, from: payload)
            guard link.parentPath == chainPath,
                  link.directory == directory,
                  link.childGenesisCID == childGenesisCID else {
                throw NodeStoreError.corrupt(
                    "malformed locally issued child-directory link"
                )
            }
        }
        return !rows.isEmpty
    }

    /// Persists content-authenticated proof material used to serve a direct
    /// child. Different Nexus roots for the same child are distinct valid
    /// evidence, so the cache is set-valued by `(childCID, rootCID)`.
    func persistIssuedChildProof(
        _ proof: ChildBlockProof,
        child: Block,
        acquisitionEntries: [String: Data]
    ) async throws {
        let childData = try Self.validatedChildData(child)
        let childCID = try BlockHeader(node: child).rawCID
        guard let directory = proof.directoryPath.last else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let package = try ChildAcquisitionPackage(
            entries: acquisitionEntries,
            childCID: childCID,
            childData: childData,
            maximumBytes: ChildAcquisitionPackage.maximumBytes
        )
        let payload = try await validatedProofPayload(
            proof,
            childCID: childCID
        )
        try database.transaction {
            try persistIssuedChildBlockRow(
                childCID: childCID,
                data: childData,
                acquisitionData: try package.encoded()
            )
            try persistIssuedChildProofRow(
                childCID: childCID,
                directory: directory,
                rootCID: proof.rootCID,
                payload: payload
            )
        }
    }

    /// A child admission derives these two relay artifacts from one verified
    /// package. They become visible together or not at all.
    func persistIssuedCarrierEvidence(
        link: ParentCarrierLink,
        proof: ChildBlockProof,
        child: Block,
        acquisitionEntries: [String: Data],
        issuerKey: String,
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16
    ) async throws {
        let childData = try Self.validatedChildData(child)
        let childCID = try BlockHeader(node: child).rawCID
        guard let directory = proof.directoryPath.last else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let package = try ChildAcquisitionPackage(
            entries: acquisitionEntries,
            childCID: childCID,
            childData: childData,
            maximumBytes: ChildAcquisitionPackage.maximumBytes
        )
        guard link.parentPath == chainPath,
              link.carrierCID == childCID,
              link.rootCID == proof.rootCID,
              pendingChildProofRoutes.allSatisfy({
                  $0.carrierCID == childCID && !$0.directory.isEmpty
              }) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let payload = try await validatedProofPayload(
            proof,
            childCID: childCID,
            exactDirectoryPath: Array(chainPath.dropFirst())
        )
        let linkPayload = try Self.encode(link)
        try database.transaction {
            try persistIssuedChildBlockRow(
                childCID: childCID,
                data: childData,
                acquisitionData: try package.encoded()
            )
            try persistIssuedChildProofRow(
                childCID: childCID,
                directory: directory,
                rootCID: proof.rootCID,
                payload: payload
            )
            try persistIssuedParentFact(
                kind: "carrier",
                keyA: link.carrierCID,
                keyB: link.rootCID,
                payload: linkPayload,
                issuerKey: issuerKey
            )
            try persistPendingChildProofRouteRows(
                pendingChildProofRoutes,
                capacity: pendingChildProofCapacity
            )
        }
    }

    private func validatedProofPayload(
        _ proof: ChildBlockProof,
        childCID: String,
        exactDirectoryPath: [String]? = nil
    ) async throws -> Data {
        guard !childCID.isEmpty,
              exactDirectoryPath.map({ proof.directoryPath == $0 }) ?? true,
              try await Self.proves(
                proof,
                childCID: childCID,
                from: chainPath
              ) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let payload = try proof.serialize()
        guard ChildBlockProof.deserialize(payload) != nil else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        return payload
    }

    private func persistIssuedChildBlockRow(
        childCID: String,
        data: Data,
        acquisitionData: Data
    ) throws {
        let rows = try database.query(
            "SELECT data, acquisition_data FROM issued_child_blocks WHERE child_cid = ?1",
            params: [.text(childCID)]
        )
        if let row = rows.first,
           let existing = row["data"]?.blobValue,
           let existingAcquisition = row["acquisition_data"]?.blobValue {
            guard existing == data,
                  existingAcquisition == acquisitionData else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_child_blocks (child_cid, data, acquisition_data) VALUES (?1, ?2, ?3)",
            params: [.text(childCID), .blob(data), .blob(acquisitionData)]
        )
    }

    private func persistIssuedChildProofRow(
        childCID: String,
        directory: String,
        rootCID: String,
        payload: Data
    ) throws {
        let rows = try database.query(
            "SELECT directory, payload FROM issued_child_proofs WHERE child_cid = ?1 AND root_cid = ?2",
            params: [.text(childCID), .text(rootCID)]
        )
        if let row = rows.first,
           let existing = row["payload"]?.blobValue {
            guard row["directory"]?.textValue == directory,
                  existing == payload else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_child_proofs (child_cid, directory, root_cid, payload) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(childCID), .text(directory), .text(rootCID), .blob(payload),
            ]
        )
    }

    /// With no root requested, use a deterministic proof. Exact-root lookup is
    /// available for carrier requirements so two valid grinds never get mixed.
    func issuedChildProof(
        childCID: String,
        rootCID: String? = nil
    ) async throws -> ChildBlockProof? {
        try await issuedChildEvidence(
            childCID: childCID,
            rootCID: rootCID
        )?.proof
    }

    func issuedChildEvidence(
        childCID: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        let rows: [[String: NodeSQLiteValue]]
        if let rootCID {
            rows = try database.query(
                "SELECT p.directory, p.root_cid, p.payload, b.data AS child_data, b.acquisition_data FROM issued_child_proofs AS p LEFT JOIN issued_child_blocks AS b ON b.child_cid = p.child_cid WHERE p.child_cid = ?1 AND p.root_cid = ?2",
                params: [.text(childCID), .text(rootCID)]
            )
        } else {
            rows = try database.query(
                "SELECT p.directory, p.root_cid, p.payload, b.data AS child_data, b.acquisition_data FROM issued_child_proofs AS p LEFT JOIN issued_child_blocks AS b ON b.child_cid = p.child_cid WHERE p.child_cid = ?1 ORDER BY p.root_cid LIMIT 1",
                params: [.text(childCID)]
            )
        }
        guard let row = rows.first,
              let directory = row["directory"]?.textValue,
              let storedRoot = row["root_cid"]?.textValue,
              let payload = row["payload"]?.blobValue,
              let childData = row["child_data"]?.blobValue,
              let acquisitionData = row["acquisition_data"]?.blobValue,
              let child = Self.contentBoundChild(cid: childCID, data: childData),
              let proof = ChildBlockProof.deserialize(payload),
              proof.directoryPath.last == directory,
              proof.rootCID == storedRoot,
              (try? proof.serialize()) == payload,
              try await Self.proves(
                proof,
                childCID: childCID,
                from: chainPath
              ) else {
            if rows.isEmpty { return nil }
            throw NodeStoreError.corrupt("malformed locally issued child proof")
        }
        let acquisitionEntries: [String: Data]
        do {
            acquisitionEntries = try ChildAcquisitionPackage.decoded(
                acquisitionData,
                childCID: childCID,
                childData: childData,
                maximumBytes: ChildAcquisitionPackage.maximumBytes
            ).entries
        } catch {
            throw NodeStoreError.corrupt("malformed locally issued child package")
        }
        return IssuedChildEvidence(
            proof: proof,
            child: child,
            childData: childData,
            acquisitionEntries: acquisitionEntries
        )
    }

    func issuedChildProofRoots(
        childCID: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        guard limit > 0, let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof page limit must be positive"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let afterRootCID {
            rows = try database.query(
                "SELECT root_cid FROM issued_child_proofs WHERE child_cid = ?1 AND root_cid > ?2 ORDER BY root_cid LIMIT ?3",
                params: [.text(childCID), .text(afterRootCID), .int(sqlLimit)]
            )
        } else {
            rows = try database.query(
                "SELECT root_cid FROM issued_child_proofs WHERE child_cid = ?1 ORDER BY root_cid LIMIT ?2",
                params: [.text(childCID), .int(sqlLimit)]
            )
        }
        var roots: [String] = []
        roots.reserveCapacity(rows.count)
        for row in rows {
            guard let root = row["root_cid"]?.textValue,
                  !root.isEmpty,
                  try await issuedChildEvidence(
                    childCID: childCID,
                    rootCID: root
                  ) != nil else {
                throw NodeStoreError.corrupt("malformed locally issued child-proof index")
            }
            roots.append(root)
        }
        return roots
    }

    func issuedChildEvidenceSummaries(
        directory: String,
        issuerKey: String,
        after: IssuedChildEvidenceSummary?,
        limit: Int
    ) async throws -> [IssuedChildEvidenceSummary] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child-evidence page must be bounded"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let after {
            rows = try database.query(
                "SELECT p.child_cid, p.root_cid FROM issued_child_proofs AS p INNER JOIN issued_parent_facts AS f ON f.issuer_key = ?1 AND f.kind = 'genesis' AND f.key_a = ?2 AND f.key_b = p.child_cid WHERE p.directory = ?2 AND (p.child_cid > ?3 OR (p.child_cid = ?3 AND p.root_cid > ?4)) ORDER BY p.child_cid, p.root_cid LIMIT ?5",
                params: [
                    .text(issuerKey), .text(directory),
                    .text(after.childCID), .text(after.rootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT p.child_cid, p.root_cid FROM issued_child_proofs AS p INNER JOIN issued_parent_facts AS f ON f.issuer_key = ?1 AND f.kind = 'genesis' AND f.key_a = ?2 AND f.key_b = p.child_cid WHERE p.directory = ?2 ORDER BY p.child_cid, p.root_cid LIMIT ?3",
                params: [.text(issuerKey), .text(directory), .int(sqlLimit)]
            )
        }
        var summaries: [IssuedChildEvidenceSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows {
            guard let childCID = row["child_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  try await issuedChildEvidence(
                    childCID: childCID,
                    rootCID: rootCID
                  ) != nil else {
                throw NodeStoreError.corrupt(
                    "malformed locally issued child-evidence index"
                )
            }
            summaries.append(IssuedChildEvidenceSummary(
                childCID: childCID,
                rootCID: rootCID
            ))
        }
        return summaries
    }

    /// A contextual candidate's child-link trie exists before that candidate is
    /// admitted. Keep a bounded durable direct-hop batch so a restart cannot
    /// prevent the admitted carrier from relaying work to its descendants.
    func persistPreparedChildProofs(
        carrierCID: String,
        proofs: [PreparedChildProof],
        capacity: Int
    ) async throws {
        guard capacity > 0, let sqlCapacity = Int64(exactly: capacity) else {
            throw NodeStoreError.invalidConfiguration(
                "prepared child-proof capacity must be positive"
            )
        }
        var canonical: [(
            directory: String,
            childCID: String,
            payload: Data,
            childData: Data,
            acquisitionData: Data
        )] = []
        var directories = Set<String>()
        for entry in proofs.sorted(by: { $0.directory < $1.directory }) {
            let childData = try Self.validatedChildData(entry.child)
            let package = try ChildAcquisitionPackage(
                entries: entry.acquisitionEntries,
                childCID: entry.childCID,
                childData: childData,
                maximumBytes: ChildAcquisitionPackage.maximumBytes
            )
            guard !entry.directory.isEmpty,
                  directories.insert(entry.directory).inserted,
                  entry.proof.rootCID == carrierCID,
                  entry.proof.directoryPath == [entry.directory],
                  try await Self.proofTerminates(
                    entry.proof,
                    at: entry.childCID
                  ) else {
                throw NodeStoreError.invalidIssuedChildProof(entry.childCID)
            }
            let payload = try entry.proof.serialize()
            guard ChildBlockProof.deserialize(payload) != nil else {
                throw NodeStoreError.invalidIssuedChildProof(entry.childCID)
            }
            canonical.append((
                entry.directory,
                entry.childCID,
                payload,
                childData,
                try package.encoded()
            ))
        }
        guard !canonical.isEmpty else { return }

        try database.transaction {
            let existing = try database.query(
                "SELECT batch_seq, directory, child_cid, payload, child_data, acquisition_data FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
                params: [.text(carrierCID)]
            )
            let existingByDirectory = Dictionary(
                uniqueKeysWithValues: try existing.map { row in
                    guard let directory = row["directory"]?.textValue else {
                        throw NodeStoreError.corrupt(
                            "malformed prepared child-proof directory"
                        )
                    }
                    return (directory, row)
                }
            )
            for expected in canonical {
                if let row = existingByDirectory[expected.directory] {
                    guard row["child_cid"]?.textValue == expected.childCID,
                          row["payload"]?.blobValue == expected.payload,
                          row["child_data"]?.blobValue == expected.childData,
                          row["acquisition_data"]?.blobValue
                            == expected.acquisitionData else {
                        throw NodeStoreError.conflictingIssuedChildProof
                    }
                }
            }

            let batchSequence: Int64
            if let first = existing.first {
                guard let sequence = first["batch_seq"]?.intValue,
                      existing.allSatisfy({
                          $0["batch_seq"]?.intValue == sequence
                      }) else {
                    throw NodeStoreError.corrupt(
                        "malformed prepared child-proof sequence"
                    )
                }
                batchSequence = sequence
            } else {
                let sequence = try database.query(
                    "SELECT COALESCE(MAX(batch_seq), 0) AS max_seq FROM prepared_child_proofs"
                ).first?["max_seq"]?.intValue ?? 0
                guard sequence < Int64.max else {
                    throw NodeStoreError.corrupt(
                        "prepared child-proof sequence overflow"
                    )
                }
                batchSequence = sequence + 1
            }

            for entry in canonical where existingByDirectory[entry.directory] == nil {
                do {
                    try database.execute(
                        "INSERT INTO prepared_child_proofs (carrier_cid, batch_seq, directory, child_cid, payload, child_data, acquisition_data) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                        params: [
                            .text(carrierCID),
                            .int(batchSequence),
                            .text(entry.directory),
                            .text(entry.childCID),
                            .blob(entry.payload),
                            .blob(entry.childData),
                            .blob(entry.acquisitionData),
                        ]
                    )
                } catch {
                    throw NodeStoreError.conflictingIssuedChildProof
                }
            }
            let stale = try database.query(
                "SELECT carrier_cid FROM prepared_child_proofs GROUP BY carrier_cid ORDER BY MIN(batch_seq) DESC, carrier_cid DESC LIMIT -1 OFFSET ?1",
                params: [.int(sqlCapacity)]
            )
            for row in stale {
                guard let staleCID = row["carrier_cid"]?.textValue else {
                    throw NodeStoreError.corrupt("malformed prepared child-proof index")
                }
                try database.execute(
                    "DELETE FROM prepared_child_proofs WHERE carrier_cid = ?1",
                    params: [.text(staleCID)]
                )
            }
        }
    }

    /// Records bounded acquisition work before consensus admission can make a
    /// carrier externally visible. A missing route stays retryable across a
    /// crash without making child availability a consensus prerequisite.
    func persistPendingChildProofRoutes(
        carrierCID: String,
        directories: [String],
        capacity: Int
    ) throws {
        let canonical = Array(Set(directories)).sorted()
        guard !carrierCID.isEmpty,
              !canonical.isEmpty,
              canonical.allSatisfy({ !$0.isEmpty }) else { return }
        try database.transaction {
            try persistPendingChildProofRouteRows(
                canonical.map {
                    PendingChildProofRoute(
                        carrierCID: carrierCID,
                        directory: $0
                    )
                },
                capacity: capacity
            )
        }
    }

    private func persistPendingChildProofRouteRows(
        _ routes: [PendingChildProofRoute],
        capacity: Int
    ) throws {
        guard capacity > 0, let sqlCapacity = Int64(exactly: capacity) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof capacity must be positive"
            )
        }
        guard !routes.isEmpty else { return }
        for (carrierCID, carrierRoutes) in Dictionary(
            grouping: routes,
            by: \.carrierCID
        ) {
            let existing = try database.query(
                "SELECT batch_seq FROM pending_child_proof_routes WHERE carrier_cid = ?1 LIMIT 1",
                params: [.text(carrierCID)]
            ).first?["batch_seq"]?.intValue
            let batchSequence: Int64
            if let existing {
                batchSequence = existing
            } else {
                let maximum = try database.query(
                    "SELECT COALESCE(MAX(batch_seq), 0) AS max_seq FROM pending_child_proof_routes"
                ).first?["max_seq"]?.intValue ?? 0
                guard maximum < Int64.max else {
                    throw NodeStoreError.corrupt(
                        "pending child-proof sequence overflow"
                    )
                }
                batchSequence = maximum + 1
            }
            for route in carrierRoutes {
                try database.execute(
                    "INSERT OR IGNORE INTO pending_child_proof_routes (carrier_cid, batch_seq, directory) VALUES (?1, ?2, ?3)",
                    params: [
                        .text(carrierCID),
                        .int(batchSequence),
                        .text(route.directory),
                    ]
                )
            }
        }
        let stale = try database.query(
            "SELECT carrier_cid FROM pending_child_proof_routes GROUP BY carrier_cid ORDER BY MIN(batch_seq) DESC, carrier_cid DESC LIMIT -1 OFFSET ?1",
            params: [.int(sqlCapacity)]
        )
        for row in stale {
            guard let staleCID = row["carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt(
                    "malformed pending child-proof index"
                )
            }
            try database.execute(
                "DELETE FROM pending_child_proof_routes WHERE carrier_cid = ?1",
                params: [.text(staleCID)]
            )
        }
    }

    func removePendingChildProofRoutes(
        carrierCID: String,
        directories: [String]
    ) throws {
        for directory in Set(directories) {
            try database.execute(
                "DELETE FROM pending_child_proof_routes WHERE carrier_cid = ?1 AND directory = ?2",
                params: [.text(carrierCID), .text(directory)]
            )
        }
    }

    func pendingChildProofRoutes() throws -> [PendingChildProofRoute] {
        try database.query(
            "SELECT carrier_cid, directory FROM pending_child_proof_routes ORDER BY batch_seq, carrier_cid, directory"
        ).map { row in
            guard let carrierCID = row["carrier_cid"]?.textValue,
                  let directory = row["directory"]?.textValue,
                  !carrierCID.isEmpty,
                  !directory.isEmpty else {
                throw NodeStoreError.corrupt(
                    "malformed pending child-proof route"
                )
            }
            return PendingChildProofRoute(
                carrierCID: carrierCID,
                directory: directory
            )
        }
    }

    func preparedChildProofs(carrierCID: String) async throws -> [PreparedChildProof] {
        let rows = try database.query(
            "SELECT directory, child_cid, payload, child_data, acquisition_data FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
            params: [.text(carrierCID)]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            guard let directory = row["directory"]?.textValue,
                  let childCID = row["child_cid"]?.textValue,
                  let payload = row["payload"]?.blobValue,
                  let childData = row["child_data"]?.blobValue,
                  let acquisitionData = row["acquisition_data"]?.blobValue,
                  let child = Self.contentBoundChild(cid: childCID, data: childData),
                  let proof = ChildBlockProof.deserialize(payload),
                  (try? proof.serialize()) == payload,
                  proof.rootCID == carrierCID,
                  proof.directoryPath == [directory],
                  try await Self.proofTerminates(proof, at: childCID) else {
                throw NodeStoreError.corrupt("malformed prepared child proof")
            }
            let acquisitionEntries: [String: Data]
            do {
                acquisitionEntries = try ChildAcquisitionPackage.decoded(
                    acquisitionData,
                    childCID: childCID,
                    childData: childData,
                    maximumBytes: ChildAcquisitionPackage.maximumBytes
                ).entries
            } catch {
                throw NodeStoreError.corrupt("malformed prepared child package")
            }
            proofs.append(try PreparedChildProof(
                directory: directory,
                child: child,
                proof: proof,
                acquisitionEntries: acquisitionEntries
            ))
        }
        return proofs
    }

    func preparedChildProofCarrierCIDs() async throws -> [String] {
        try database.query(
            "SELECT carrier_cid FROM prepared_child_proofs GROUP BY carrier_cid ORDER BY MIN(batch_seq), carrier_cid"
        ).map { row in
            guard let carrierCID = row["carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt("malformed prepared child-proof carrier index")
            }
            return carrierCID
        }
    }

    private func loadStagedAdmissions() throws -> [StagedAdmission] {
        try database.query(
            "SELECT seq, payload, volume_roots, parent_coverage FROM admission_batches ORDER BY seq ASC"
        ).map { row in
            guard let sequence = row["seq"]?.intValue,
                  let payload = row["payload"]?.blobValue,
                  let rootsPayload = row["volume_roots"]?.blobValue,
                  let coveragePayload = row["parent_coverage"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed admission batch row")
            }
            return StagedAdmission(
                sequence: sequence,
                batch: try Self.decode(ChainAdmissionBatch.self, from: payload),
                volumeRoots: try Self.decode([String].self, from: rootsPayload),
                parentCoverage: try Self.decode(
                    [ParentCoverageBinding].self,
                    from: coveragePayload
                )
            )
        }
    }

    private func persistIssuedParentFact(
        kind: String,
        keyA: String,
        keyB: String,
        payload: Data,
        issuerKey: String
    ) throws {
        guard !keyA.isEmpty, !keyB.isEmpty, !issuerKey.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "issued parent fact keys must be nonempty"
            )
        }
        let rows = try database.query(
            "SELECT payload FROM issued_parent_facts WHERE issuer_key = ?1 AND kind = ?2 AND key_a = ?3 AND key_b = ?4",
            params: [.text(issuerKey), .text(kind), .text(keyA), .text(keyB)]
        )
        if let existing = rows.first?["payload"]?.blobValue {
            guard existing == payload else {
                throw NodeStoreError.conflictingIssuedParentFact
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_parent_facts (issuer_key, kind, key_a, key_b, payload) VALUES (?1, ?2, ?3, ?4, ?5)",
            params: [
                .text(issuerKey),
                .text(kind),
                .text(keyA),
                .text(keyB),
                .blob(payload),
            ]
        )
    }

    private func issuedParentFact(
        kind: String,
        keyA: String,
        keyB: String,
        issuerKey: String
    ) throws -> Data? {
        try database.query(
            "SELECT payload FROM issued_parent_facts WHERE issuer_key = ?1 AND kind = ?2 AND key_a = ?3 AND key_b = ?4",
            params: [.text(issuerKey), .text(kind), .text(keyA), .text(keyB)]
        ).first?["payload"]?.blobValue
    }

    func parentCoverage() async throws -> [String: Set<String>] {
        var coverage: [String: Set<String>] = [:]
        for row in try database.query(
            "SELECT child_cid, parent_carrier_cid FROM parent_coverage ORDER BY child_cid, parent_carrier_cid"
        ) {
            guard let child = row["child_cid"]?.textValue,
                  let parent = row["parent_carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt("malformed parent coverage row")
            }
            coverage[child, default: []].insert(parent)
        }
        return coverage
    }

    /// Joins coverage instead of trusting the revision as a completeness marker.
    func persistInheritedWorkSnapshot(_ snapshot: InheritedWorkSnapshot) async throws {
        try database.transaction {
            let currentRows = try database.query(
                "SELECT payload FROM inherited_work_snapshot WHERE singleton = 1"
            )
            let current = try currentRows.first?["payload"]?.blobValue.map {
                try Self.decode(InheritedWorkSnapshot.self, from: $0)
            }
            let merged = current?.union(snapshot) ?? snapshot
            guard merged != current else { return }
            let payload = try Self.encode(merged)
            try database.execute(
                "INSERT OR REPLACE INTO inherited_work_snapshot (singleton, payload) VALUES (1, ?1)",
                params: [.blob(payload)]
            )
        }
    }

    func inheritedWorkSnapshot() async throws -> InheritedWorkSnapshot? {
        let rows = try database.query(
            "SELECT payload FROM inherited_work_snapshot WHERE singleton = 1"
        )
        guard let payload = rows.first?["payload"]?.blobValue else { return nil }
        return try Self.decode(InheritedWorkSnapshot.self, from: payload)
    }

    /// A rebuildable cache. Admission batches remain the authority if a crash
    /// happens after staging but before this projection is refreshed.
    func saveCanonicalProjection(_ projection: PersistedChainState) async throws {
        let payload = try Self.encode(projection)
        try database.execute(
            "INSERT OR REPLACE INTO canonical_projection (singleton, payload) VALUES (1, ?1)",
            params: [.blob(payload)]
        )
    }

    func canonicalProjection() async throws -> PersistedChainState? {
        let rows = try database.query(
            "SELECT payload FROM canonical_projection WHERE singleton = 1"
        )
        guard let payload = rows.first?["payload"]?.blobValue else { return nil }
        return try Self.decode(PersistedChainState.self, from: payload)
    }

    private static func validateMetadata(
        in database: NodeSQLite,
        tableNames: Set<String>,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data,
        minimumRootWorkHex: String
    ) throws {
        guard tableNames.contains("node_metadata") else {
            throw NodeStoreError.wipeRequired("missing schema metadata")
        }
        let rows: [[String: NodeSQLiteValue]]
        do {
            rows = try database.query(
                "SELECT schema_epoch, nexus_genesis_cid, chain_path, minimum_root_work FROM node_metadata WHERE singleton = 1"
            )
        } catch {
            throw NodeStoreError.wipeRequired("unreadable schema metadata")
        }
        guard rows.count == 1,
              rows[0]["schema_epoch"]?.intValue == schemaEpoch,
              rows[0]["nexus_genesis_cid"]?.textValue == nexusGenesisCID,
              rows[0]["chain_path"]?.blobValue == chainPath,
              rows[0]["minimum_root_work"]?.textValue == minimumRootWorkHex else {
            throw NodeStoreError.wipeRequired(
                "schema epoch, Nexus genesis, chain path, or minimum root work changed"
            )
        }
    }

    private static let expectedTables: Set<String> = [
        "node_metadata",
        "validation_content",
        "admission_batches",
        "admission_facts",
        "parent_coverage",
        "issued_parent_facts",
        "issued_child_blocks",
        "issued_child_proofs",
        "prepared_child_proofs",
        "pending_child_proof_routes",
        "inherited_work_snapshot",
        "canonical_projection",
    ]

    private static func createSchema(
        in database: NodeSQLite,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data,
        minimumRootWorkHex: String
    ) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE node_metadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    schema_epoch INTEGER NOT NULL,
                    nexus_genesis_cid TEXT NOT NULL,
                    chain_path BLOB NOT NULL,
                    minimum_root_work TEXT NOT NULL
                )
                """)
            try database.execute(
                "INSERT INTO node_metadata (singleton, schema_epoch, nexus_genesis_cid, chain_path, minimum_root_work) VALUES (1, ?1, ?2, ?3, ?4)",
                params: [
                    .int(schemaEpoch),
                    .text(nexusGenesisCID),
                    .blob(chainPath),
                    .text(minimumRootWorkHex),
                ]
            )
            try createDataTables(in: database)
        }
    }

    private static func createDataTables(in database: NodeSQLite) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS validation_content (
                cid TEXT PRIMARY KEY,
                data BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_batches (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                payload BLOB NOT NULL UNIQUE,
                volume_roots BLOB NOT NULL,
                parent_coverage BLOB NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_facts (
                fact_id BLOB PRIMARY KEY,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS parent_coverage (
                child_cid TEXT NOT NULL,
                parent_carrier_cid TEXT NOT NULL,
                PRIMARY KEY (child_cid, parent_carrier_cid)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_parent_facts (
                issuer_key TEXT NOT NULL,
                kind TEXT NOT NULL,
                key_a TEXT NOT NULL,
                key_b TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (issuer_key, kind, key_a, key_b)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_blocks (
                child_cid TEXT PRIMARY KEY,
                data BLOB NOT NULL,
                acquisition_data BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_proofs (
                child_cid TEXT NOT NULL,
                directory TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (child_cid, root_cid)
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_proofs_by_directory ON issued_child_proofs (directory, child_cid, root_cid)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS prepared_child_proofs (
                carrier_cid TEXT NOT NULL,
                batch_seq INTEGER NOT NULL,
                directory TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                payload BLOB NOT NULL,
                child_data BLOB NOT NULL,
                acquisition_data BLOB NOT NULL,
                PRIMARY KEY (carrier_cid, directory)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS pending_child_proof_routes (
                carrier_cid TEXT NOT NULL,
                batch_seq INTEGER NOT NULL,
                directory TEXT NOT NULL,
                PRIMARY KEY (carrier_cid, directory)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS inherited_work_snapshot (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                payload BLOB NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS canonical_projection (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                payload BLOB NOT NULL
            )
            """)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NodeStoreError.corrupt(String(describing: error))
        }
    }

    private static func validatedChildData(_ child: Block) throws -> Data {
        guard let data = child.toData(),
              let childCID = try? BlockHeader(node: child).rawCID,
              contentBoundChild(cid: childCID, data: data) != nil else {
            throw NodeStoreError.invalidIssuedChildProof("malformed child block")
        }
        return data
    }

    private static func contentBoundChild(cid: String, data: Data) -> Block? {
        guard let child = Block(data: data), child.toData() == data,
              let header = try? BlockHeader(node: child), header.rawCID == cid else {
            return nil
        }
        return child
    }

    private static func normalizedFacts(
        in batch: ChainAdmissionBatch
    ) throws -> [Data: Data] {
        var normalized: [Data: Data] = [:]
        for fact in batch.facts {
            let id = try encode(fact.id)
            let payload = try encode(fact)
            if let existing = normalized[id], existing != payload {
                throw NodeStoreError.conflictingAdmissionFact
            }
            normalized[id] = payload
        }
        return normalized
    }

    private static func validate(
        coverage: [ParentCoverageBinding],
        in batch: ChainAdmissionBatch
    ) throws {
        let blockCIDs = Set(batch.facts.map { fact in
            switch fact {
            case .block(let block): block.blockHash
            case .work(let work): work.blockHash
            }
        })
        for binding in coverage where
            binding.childBlockCID.isEmpty
                || binding.parentCarrierCID.isEmpty
                || !blockCIDs.contains(binding.childBlockCID) {
            throw NodeStoreError.invalidParentCoverage(binding.childBlockCID)
        }
    }

    /// Checks only the content-addressed root-to-leaf association and path
    /// scope. Consensus work and transition validity remain Lattice's job.
    private static func proves(
        _ proof: ChildBlockProof,
        childCID: String,
        from chainPath: [String]
    ) async throws -> Bool {
        let localPath = Array(chainPath.dropFirst())
        let provesSelf = !localPath.isEmpty && proof.directoryPath == localPath
        let provesDirectChild = proof.directoryPath.count == localPath.count + 1
            && proof.directoryPath.starts(with: localPath)
        guard !proof.rootCID.isEmpty,
              provesSelf || provesDirectChild,
              proof.directoryPath.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        return try await proofTerminates(proof, at: childCID)
    }

    private static func proofTerminates(
        _ proof: ChildBlockProof,
        at childCID: String
    ) async throws -> Bool {
        var entries: [String: Data] = [:]
        for entry in proof.entries {
            guard entries.updateValue(entry.data, forKey: entry.cid) == nil else {
                return false
            }
        }
        let source = InMemoryContentSource(entries)
        var current = BlockHeader(
            rawCID: proof.rootCID,
            node: nil,
            encryptionInfo: nil
        )
        for directory in proof.directoryPath {
            guard let block = try await current.resolve(fetcher: source).node,
                  let children = try await block.children.resolve(
                    paths: [[directory]: .targeted],
                    fetcher: source
                  ).node,
                  let next: BlockHeader = try? children.get(key: directory) else {
                return false
            }
            current = next
        }
        return current.rawCID == childCID
    }
}

/// Keeps sparse validation entries separate from complete materialized Volumes.
actor NodeAdmissionStorage: Storer, VolumeStorer {
    private let validationContent: NodeStore
    private let materializedVolumes: any VolumeStorer
    private var roots = Set<String>()

    init(validationContent: NodeStore, materializedVolumes: any VolumeStorer) {
        self.validationContent = validationContent
        self.materializedVolumes = materializedVolumes
    }

    func store(entries: [String: Data]) async throws {
        try await validationContent.store(entries: entries)
    }

    func store(volume: SerializedVolume) async throws {
        try await materializedVolumes.store(volume: volume)
        roots.insert(volume.root)
    }

    func takeStoredVolumeRoots() -> [String] {
        defer { roots.removeAll(keepingCapacity: true) }
        return roots.sorted()
    }
}
