import Foundation
import Lattice
import UInt256
import VolumeBroker
import cashew

enum NodeStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case wipeRequired(String)
    case conflictingAdmissionFact
    case conflictingAdmissionBatch
    case conflictingIssuedParentFact
    case conflictingIssuedChildProof
    case invalidIssuedChildProof(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Invalid node store configuration: \(reason)"
        case .wipeRequired(let reason):
            "The node store is incompatible (\(reason)); stop the process, delete its entire configured storage directory (state.db and volumes.db), and restart."
        case .conflictingAdmissionFact:
            "Conflicting bytes for an immutable chain fact."
        case .conflictingAdmissionBatch:
            "An admission batch was replayed with different Volume roots."
        case .conflictingIssuedParentFact:
            "A locally issued parent fact was replayed with different bytes."
        case .conflictingIssuedChildProof:
            "A locally issued child proof was replayed with different bytes."
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
}

struct LocalMempoolTransactionRecord: Sendable, Equatable {
    let transactionCID: String
    let addedAt: Int64
}

struct AcceptedLeafPage: Sendable, Equatable {
    let snapshotSequence: Int64
    let blockCIDs: [String]
}

struct IssuedChildEvidence: Sendable {
    let edgeCID: String
    let attachmentCID: String
    let edge: DirectChildEdge
    let proof: ChildBlockProof
    let child: Block
    let acquisitionEntries: [String: Data]
    let parentCarrierLink: ParentCarrierLink?
    let parentGenesisLink: ParentGenesisLink?
    let parentCarrierCertificate: ParentCarrierCertificateV1?
    let parentGenesisCertificate: ParentGenesisCertificateV1?
}

/// Evidence verified by Lattice that the node must commit with the admission
/// batch that made it issuable. The proof package is optional for Nexus, where
/// the carrier is its own root.
struct AdmissionCarrierEvidence: Sendable {
    let proof: ChildBlockProof
    let child: Block
    let acquisitionEntries: [String: Data]
    let parentCarrierLink: ParentCarrierLink?
    let parentGenesisLink: ParentGenesisLink?
    let parentCarrierCertificate: ParentCarrierCertificateV1?
    let parentGenesisCertificate: ParentGenesisCertificateV1?

    init(
        proof: ChildBlockProof,
        child: Block,
        acquisitionEntries: [String: Data],
        parentCarrierLink: ParentCarrierLink? = nil,
        parentGenesisLink: ParentGenesisLink? = nil,
        parentCarrierCertificate: ParentCarrierCertificateV1? = nil,
        parentGenesisCertificate: ParentGenesisCertificateV1? = nil
    ) {
        self.proof = proof
        self.child = child
        self.acquisitionEntries = acquisitionEntries
        self.parentCarrierLink = parentCarrierLink
        self.parentGenesisLink = parentGenesisLink
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
    }
}

/// Hierarchy facts produced by Lattice at the same boundary as an accepted
/// admission. They remain separate from chain facts because replay does not
/// need them, but NodeStore commits both in one SQLite transaction.
struct AdmissionHierarchyArtifacts: Sendable {
    let carrierLink: ParentCarrierLink
    let carrierEvidence: AdmissionCarrierEvidence?
    let parentGenesisLinks: [ParentGenesisLink]
}

struct IssuedChildEvidenceSummary: Codable, Equatable, Hashable, Sendable {
    let childCID: String
    let rootCID: String
    let attachmentCID: String
}

struct ChildRootAttachmentSummary: Equatable, Hashable, Sendable {
    let edgeCID: String
    let rootCID: String
    let attachmentCID: String
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

private struct PreparedAdmissionCarrierEvidence {
    let edge: DirectChildEdge
    let childCID: String
    let directory: String
    let rootCID: String
    let isPortable: Bool
    let directAttachment: ChildEvidenceVolume
    let proofAttachment: ChildEvidenceVolume
}

private struct PreparedAdmissionHierarchyArtifacts {
    let carrierLink: ParentCarrierLink
    let carrierLinkPayload: Data
    let carrierEvidence: PreparedAdmissionCarrierEvidence?
    let parentGenesisLinks: [(link: ParentGenesisLink, payload: Data)]
}

private struct PersistedParentFactSource: Codable {
    let carrierLink: ParentCarrierLink
    let parentGenesisLinks: [ParentGenesisLink]
}

private struct IssuedParentFactKey: Hashable {
    let kind: String
    let keyA: String
    let keyB: String
}

private struct AcceptedBlockRecord: Hashable {
    let blockCID: String
    let parentCID: String?
}

private struct PersistedAcceptedBlock: Hashable {
    let blockCID: String
    let parentCID: String?
    let admissionSequence: Int64
}

enum IssuedChildProofScope: String, Sendable {
    case incomingCarrier = "incoming_carrier"
    case outgoingDirectChild = "outgoing_direct_child"
}

/// Node-owned immutable facts and availability indexes for one absolute path.
actor NodeStore {
    /// Epoch 21 stores exact hierarchy edges and inherited work by grind.
    /// Existing stores must be rebuilt from the pinned genesis.
    static let currentSchemaEpoch: Int64 = 21

    private let database: NodeSQLite
    private let nexusGenesisCID: String
    private let chainPath: [String]
    private let parentWorkAuthorityKey: ParentWorkAuthorityKey?
    private let issuingParentWorkAuthorityKey: ParentWorkAuthorityKey
    private let recoveryVolumeStorer: any VolumeStorer
    private let recoveryVolumeBroker: any VolumeBroker

    init(
        databasePath: URL,
        nexusGenesisCID: String,
        chainPath: [String],
        minimumRootWork: UInt256,
        spawningParentKey: String = "",
        issuingAuthorityKey: String,
        recoveryVolumeStorer: any VolumeStorer,
        recoveryVolumeBroker: any VolumeBroker
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
        guard let issuingParentWorkAuthorityKey = ParentWorkAuthorityKey(
            issuingAuthorityKey
        ) else {
            throw NodeStoreError.invalidConfiguration(
                "issuing parent-work authority key is malformed"
            )
        }
        let parentWorkAuthorityKey: ParentWorkAuthorityKey?
        if chainPath.count == 1 {
            guard spawningParentKey.isEmpty else {
                throw NodeStoreError.invalidConfiguration(
                    "Nexus cannot have a spawning parent key"
                )
            }
            parentWorkAuthorityKey = nil
        } else {
            guard let authority = ParentWorkAuthorityKey(spawningParentKey) else {
                throw NodeStoreError.invalidConfiguration(
                    "a child chain requires a canonical Ed25519 parent key"
                )
            }
            parentWorkAuthorityKey = authority
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
                minimumRootWorkHex: minimumRootWorkHex,
                spawningParentKey: spawningParentKey,
                issuingAuthorityKey: issuingAuthorityKey
            )
        } else {
            try Self.validateMetadata(
                in: database,
                tableNames: tableNames,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData,
                minimumRootWorkHex: minimumRootWorkHex,
                spawningParentKey: spawningParentKey,
                issuingAuthorityKey: issuingAuthorityKey
            )
            guard tableNames == Self.expectedTables else {
                throw NodeStoreError.wipeRequired("schema tables are missing or unexpected")
            }
        }
        try database.configureDurability()

        self.database = database
        self.nexusGenesisCID = nexusGenesisCID
        self.chainPath = chainPath
        self.parentWorkAuthorityKey = parentWorkAuthorityKey
        self.issuingParentWorkAuthorityKey = issuingParentWorkAuthorityKey
        self.recoveryVolumeStorer = recoveryVolumeStorer
        self.recoveryVolumeBroker = recoveryVolumeBroker
    }

    func stage(
        _ batch: ChainAdmissionBatch,
        volumeRoots: [String],
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16,
        hierarchyArtifacts: AdmissionHierarchyArtifacts? = nil,
        incomingCarrierEvidence: AdmissionCarrierEvidence? = nil
    ) async throws {
        let payload = try Self.encode(batch)
        let factsInBatch = try Self.normalizedFacts(in: batch)
        let facts = factsInBatch.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        let acceptedBlocks = try Self.acceptedBlocks(in: batch)
        let pendingRoutes = Array(Set(pendingChildProofRoutes)).sorted {
            ($0.carrierCID, $0.directory) < ($1.carrierCID, $1.directory)
        }
        let carrierCIDs = Set(batch.facts.map { fact -> String in
            switch fact {
            case .block(let block): block.blockHash
            case .work(let work): work.blockHash
            }
        })
        guard pendingRoutes.allSatisfy({
            carrierCIDs.contains($0.carrierCID) && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route is outside its admission batch"
            )
        }
        let preparedHierarchyArtifacts = try await prepareHierarchyArtifacts(
            hierarchyArtifacts,
            carrierCIDs: carrierCIDs
        )
        let preparedIncomingCarrierEvidence: PreparedAdmissionCarrierEvidence?
        if let incomingCarrierEvidence {
            preparedIncomingCarrierEvidence = try await prepareCarrierEvidence(
                incomingCarrierEvidence,
                expectedChildCIDs: carrierCIDs,
                expectedRootCID: nil
            )
        } else {
            preparedIncomingCarrierEvidence = nil
        }
        let recoveryVolumes = try recoveryVolumes(in: preparedHierarchyArtifacts)
            + [preparedIncomingCarrierEvidence].compactMap { $0 }.flatMap {
                [$0.directAttachment, $0.proofAttachment]
            }
        if !recoveryVolumes.isEmpty {
            for volume in recoveryVolumes {
                try await volume.store(storer: recoveryVolumeStorer)
            }
        }
        let rootsPayload = try Self.encode(Array(Set(volumeRoots)).sorted())

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
                "SELECT seq, volume_roots FROM admission_batches WHERE payload = ?1",
                params: [.blob(payload)]
            )
            if let existing = replay.first,
               let existingSequence = existing["seq"]?.intValue,
               let existingRoots = existing["volume_roots"]?.blobValue {
                guard existingRoots == rootsPayload else {
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
                try validateAcceptedBlockRows(
                    acceptedBlocks,
                    admissionSequence: existingSequence
                )
            } else {
                try database.execute(
                    "INSERT INTO admission_batches (payload, volume_roots) VALUES (?1, ?2)",
                    params: [.blob(payload), .blob(rootsPayload)]
                )
                guard let admissionSequence = try database.query(
                    "SELECT seq FROM admission_batches WHERE payload = ?1",
                    params: [.blob(payload)]
                ).first?["seq"]?.intValue else {
                    throw NodeStoreError.corrupt("missing newly staged admission batch")
                }
                for fact in facts {
                    try database.execute(
                        "INSERT OR IGNORE INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
                        params: [.blob(fact.key), .blob(fact.value)]
                    )
                }
                try persistAcceptedBlockRows(
                    acceptedBlocks,
                    admissionSequence: admissionSequence
                )
            }
            if let preparedHierarchyArtifacts {
                try persistHierarchyArtifacts(preparedHierarchyArtifacts)
            }
            if let preparedIncomingCarrierEvidence {
                try persistCarrierEvidence(preparedIncomingCarrierEvidence)
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

    func persistLocalMempoolTransaction(
        transactionCID: String,
        addedAt: Int64
    ) throws {
        guard CIDIdentity.isCanonical(transactionCID), addedAt >= 0 else {
            throw NodeStoreError.invalidConfiguration(
                "local mempool transaction reference is malformed"
            )
        }
        try database.execute(
            "INSERT OR IGNORE INTO local_mempool_transactions (transaction_cid, added_at) VALUES (?1, ?2)",
            params: [.text(transactionCID), .int(addedAt)]
        )
    }

    func removeLocalMempoolTransaction(transactionCID: String) throws {
        guard CIDIdentity.isCanonical(transactionCID) else {
            throw NodeStoreError.invalidConfiguration(
                "local mempool transaction CID is malformed"
            )
        }
        try database.execute(
            "DELETE FROM local_mempool_transactions WHERE transaction_cid = ?1",
            params: [.text(transactionCID)]
        )
    }

    func localMempoolTransactions() throws -> [LocalMempoolTransactionRecord] {
        try database.query(
            "SELECT transaction_cid, added_at FROM local_mempool_transactions ORDER BY added_at, transaction_cid"
        ).map { row in
            guard let transactionCID = row["transaction_cid"]?.textValue,
                  let addedAt = row["added_at"]?.intValue,
                  CIDIdentity.isCanonical(transactionCID),
                  addedAt >= 0 else {
                throw NodeStoreError.corrupt(
                    "malformed local mempool transaction reference"
                )
            }
            return LocalMempoolTransactionRecord(
                transactionCID: transactionCID,
                addedAt: addedAt
            )
        }
    }

    /// Stable pagination over the accepted forest's leaves. The first call
    /// captures the current admission sequence; later calls reuse it so newly
    /// admitted descendants cannot reshuffle an in-progress page walk.
    func acceptedLeafPage(
        afterCID: String?,
        snapshotSequence: Int64?,
        limit: Int
    ) throws -> AcceptedLeafPage {
        guard limit > 0, let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "accepted-leaf page limit must be positive"
            )
        }
        let currentSequence = try database.query(
            "SELECT COALESCE(MAX(seq), 0) AS sequence FROM admission_batches"
        ).first?["sequence"]?.intValue ?? 0
        let snapshot = snapshotSequence ?? currentSequence
        guard snapshot >= 0, snapshot <= currentSequence else {
            throw NodeStoreError.invalidConfiguration(
                "accepted-leaf snapshot is outside durable admission history"
            )
        }

        let rows: [[String: NodeSQLiteValue]]
        if let afterCID {
            rows = try database.query(
                "SELECT block_cid FROM accepted_blocks AS block WHERE block.admission_seq <= ?1 AND block.block_cid > ?2 AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.parent_cid = block.block_cid AND child.admission_seq <= ?1) ORDER BY block.block_cid LIMIT ?3",
                params: [.int(snapshot), .text(afterCID), .int(sqlLimit)]
            )
        } else {
            rows = try database.query(
                "SELECT block_cid FROM accepted_blocks AS block WHERE block.admission_seq <= ?1 AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.parent_cid = block.block_cid AND child.admission_seq <= ?1) ORDER BY block.block_cid LIMIT ?2",
                params: [.int(snapshot), .int(sqlLimit)]
            )
        }
        let blockCIDs = try rows.map { row -> String in
            guard let cid = row["block_cid"]?.textValue, !cid.isEmpty else {
                throw NodeStoreError.corrupt("malformed accepted-block leaf index")
            }
            return cid
        }
        return AcceptedLeafPage(
            snapshotSequence: snapshot,
            blockCIDs: blockCIDs
        )
    }

    func auditNormalizedIndexes() async throws {
        let staged = try loadStagedAdmissions()
        var expectedFacts: [Data: Data] = [:]
        var expectedAcceptedBlocks: [String: PersistedAcceptedBlock] = [:]

        for admission in staged {
            for (id, payload) in try Self.normalizedFacts(in: admission.batch) {
                if let existing = expectedFacts[id], existing != payload {
                    throw NodeStoreError.corrupt(
                        "admission batches disagree about an immutable fact"
                    )
                }
                expectedFacts[id] = payload
            }
            for block in try Self.acceptedBlocks(in: admission.batch) {
                if let existing = expectedAcceptedBlocks[block.blockCID] {
                    guard existing.parentCID == block.parentCID else {
                        throw NodeStoreError.corrupt(
                            "admission batches disagree about an accepted block parent"
                        )
                    }
                } else {
                    expectedAcceptedBlocks[block.blockCID] = PersistedAcceptedBlock(
                        blockCID: block.blockCID,
                        parentCID: block.parentCID,
                        admissionSequence: admission.sequence
                    )
                }
            }
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

        var actualAcceptedBlocks: [String: PersistedAcceptedBlock] = [:]
        for row in try database.query(
            "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks"
        ) {
            let block = try persistedAcceptedBlock(from: row)
            actualAcceptedBlocks[block.blockCID] = block
        }
        guard actualAcceptedBlocks == expectedAcceptedBlocks else {
            throw NodeStoreError.corrupt(
                "accepted-block index does not match immutable batches"
            )
        }

        var expectedParentFacts: [IssuedParentFactKey: Data] = [:]
        for row in try database.query(
            "SELECT payload FROM issued_parent_fact_sources ORDER BY payload"
        ) {
            guard let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed parent-fact source")
            }
            let source = try Self.decode(
                PersistedParentFactSource.self,
                from: payload
            )
            guard try Self.encode(source) == payload,
                  source.carrierLink.parentPath == chainPath,
                  !source.carrierLink.carrierCID.isEmpty,
                  !source.carrierLink.rootCID.isEmpty,
                  chainPath.count > 1
                    || source.carrierLink.carrierCID
                        == source.carrierLink.rootCID else {
                throw NodeStoreError.corrupt("invalid parent-fact source")
            }
            let sortedGenesis = Array(Set(source.parentGenesisLinks)).sorted {
                ($0.directory, $0.childGenesisCID)
                    < ($1.directory, $1.childGenesisCID)
            }
            guard source.parentGenesisLinks == sortedGenesis,
                  source.parentGenesisLinks.allSatisfy({
                      $0.parentPath == chainPath
                          && !$0.directory.isEmpty
                          && !$0.childGenesisCID.isEmpty
                  }) else {
                throw NodeStoreError.corrupt("invalid genesis-fact source")
            }
            try Self.addExpectedParentFact(
                key: IssuedParentFactKey(
                    kind: "carrier",
                    keyA: source.carrierLink.carrierCID,
                    keyB: source.carrierLink.rootCID
                ),
                payload: try Self.encode(source.carrierLink),
                to: &expectedParentFacts
            )
            for link in source.parentGenesisLinks {
                try Self.addExpectedParentFact(
                    key: IssuedParentFactKey(
                        kind: "genesis",
                        keyA: link.directory,
                        keyB: link.childGenesisCID
                    ),
                    payload: try Self.encode(link),
                    to: &expectedParentFacts
                )
            }
        }
        var actualParentFacts: [IssuedParentFactKey: Data] = [:]
        for row in try database.query(
            "SELECT kind, key_a, key_b, payload FROM issued_parent_facts"
        ) {
            guard let kind = row["kind"]?.textValue,
                  let keyA = row["key_a"]?.textValue,
                  let keyB = row["key_b"]?.textValue,
                  let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed issued parent fact")
            }
            actualParentFacts[IssuedParentFactKey(
                kind: kind,
                keyA: keyA,
                keyB: keyB
            )] = payload
        }
        guard actualParentFacts == expectedParentFacts else {
            throw NodeStoreError.corrupt(
                "issued parent facts do not match immutable sources"
            )
        }

        let attachments = try database.query(
            "SELECT scope, edge_cid, root_cid FROM issued_child_proofs ORDER BY scope, edge_cid, root_cid"
        )
        for row in attachments {
            guard let rawScope = row["scope"]?.textValue,
                  let scope = IssuedChildProofScope(rawValue: rawScope),
                  let edgeCID = row["edge_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  try await issuedChildEvidence(
                    scope: scope,
                    edgeCID: edgeCID,
                    rootCID: rootCID
                  ) != nil else {
                throw NodeStoreError.corrupt(
                    "malformed direct-child attachment index"
                )
            }
        }
        for row in try database.query(
            "SELECT edge_cid, parent_carrier_cid, directory, child_cid, direct_attachment_cid FROM issued_child_edges ORDER BY edge_cid"
        ) {
            guard try await persistedChildEdge(from: row) != nil else {
                throw NodeStoreError.corrupt(
                    "malformed direct-child edge attachment index"
                )
            }
        }
        for carrierCID in try await preparedChildProofCarrierCIDs() {
            _ = try await preparedChildProofs(carrierCID: carrierCID)
        }
        let edgeCount = try database.query(
            "SELECT COUNT(*) AS count FROM issued_child_edges"
        ).first?["count"]?.intValue
        let attachedEdgeCount = try database.query(
            "SELECT COUNT(DISTINCT edge_cid) AS count FROM issued_child_proofs"
        ).first?["count"]?.intValue
        guard edgeCount == attachedEdgeCount else {
            throw NodeStoreError.corrupt("orphaned direct-child content")
        }
    }

    /// Durable child-to-parent carrier links used only by this child when it
    /// projects its configured parent's generic securing-work graph.
    func incomingParentCarrierBlocksByChildBlock()
        throws -> [String: Set<String>]
    {
        let rows = try database.query(
            "SELECT DISTINCT edge.child_cid, edge.parent_carrier_cid FROM issued_child_proofs AS proof INNER JOIN issued_child_edges AS edge ON edge.edge_cid = proof.edge_cid WHERE proof.scope = ?1 ORDER BY edge.child_cid, edge.parent_carrier_cid",
            params: [.text(IssuedChildProofScope.incomingCarrier.rawValue)]
        )
        var result: [String: Set<String>] = [:]
        for row in rows {
            guard let childCID = row["child_cid"]?.textValue,
                  let parentCarrierCID = row["parent_carrier_cid"]?.textValue,
                  CIDIdentity.isCanonical(childCID),
                  CIDIdentity.isCanonical(parentCarrierCID) else {
                throw NodeStoreError.corrupt("malformed incoming parent binding")
            }
            result[childCID, default: []].insert(parentCarrierCID)
        }
        return result
    }

    /// Resolve only bindings touched by a live parent-work delta. Full graph
    /// materialization remains a restart/reconnect operation.
    func incomingParentCarrierBlocksByChildBlock(
        matching parentBlockCIDs: Set<String>
    ) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for parentBlockCID in parentBlockCIDs.sorted() {
            let rows = try database.query(
                "SELECT DISTINCT edge.child_cid FROM issued_child_proofs AS proof INNER JOIN issued_child_edges AS edge ON edge.edge_cid = proof.edge_cid WHERE proof.scope = ?1 AND edge.parent_carrier_cid = ?2 ORDER BY edge.child_cid",
                params: [
                    .text(IssuedChildProofScope.incomingCarrier.rawValue),
                    .text(parentBlockCID),
                ]
            )
            for row in rows {
                guard let childCID = row["child_cid"]?.textValue,
                      CIDIdentity.isCanonical(childCID) else {
                    throw NodeStoreError.corrupt(
                        "malformed incoming parent binding"
                    )
                }
                result[childCID, default: []].insert(parentBlockCID)
            }
        }
        return result
    }

    func incomingParentCarrierBlockCIDs(
        forChildBlockCID childBlockCID: String
    ) throws -> Set<String> {
        guard CIDIdentity.isCanonical(childBlockCID) else {
            throw NodeStoreError.corrupt("invalid incoming child block")
        }
        let rows = try database.query(
            "SELECT edge.parent_carrier_cid FROM issued_child_edges AS edge WHERE edge.child_cid = ?1 AND EXISTS (SELECT 1 FROM issued_child_proofs AS proof WHERE proof.scope = ?2 AND proof.edge_cid = edge.edge_cid) ORDER BY edge.parent_carrier_cid",
            params: [
                .text(childBlockCID),
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
            ]
        )
        return try Set(rows.map { row in
            guard let parentCarrierCID = row["parent_carrier_cid"]?.textValue,
                  CIDIdentity.isCanonical(parentCarrierCID) else {
                throw NodeStoreError.corrupt("malformed incoming parent binding")
            }
            return parentCarrierCID
        })
    }

    func hasAcceptedBlock(_ blockCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid accepted block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE block_cid = ?1 LIMIT 1",
            params: [.text(blockCID)]
        ).isEmpty
    }

    func hasIncomingCarrierEdge(_ edgeCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(edgeCID) else {
            throw NodeStoreError.corrupt("invalid incoming edge lookup")
        }
        return try !database.query(
            "SELECT 1 FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 LIMIT 1",
            params: [
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
                .text(edgeCID),
            ]
        ).isEmpty
    }

    /// Materialize the one configured parent's fact set only when a process
    /// opens or recovers. Live updates stay in one monotone SQL table and go
    /// straight to Core as their original fragment.
    func inheritedWorkSnapshot(
        matchingParentBlockCIDs parentBlockCIDs: Set<String>? = nil
    ) throws -> InheritedWorkSnapshot? {
        guard parentWorkAuthorityKey != nil else { return nil }
        if let parentBlockCIDs,
           !parentBlockCIDs.allSatisfy(CIDIdentity.isCanonical) {
            throw NodeStoreError.corrupt("invalid inherited work lookup")
        }
        let sourceRows = try database.query(
            "SELECT revision, fact_count FROM parent_work_source"
        )
        guard sourceRows.count <= 1 else {
            throw NodeStoreError.corrupt("duplicate immediate-parent work source")
        }
        guard let sourceRow = sourceRows.first else {
            let hasFacts = try hasParentWorkFacts()
            guard !hasFacts else {
                throw NodeStoreError.corrupt("parent work facts have no source revision")
            }
            return nil
        }
        guard let revisionText = sourceRow["revision"]?.textValue,
              let factCount = sourceRow["fact_count"]?.intValue,
              factCount >= 0 else {
            throw NodeStoreError.corrupt("malformed immediate-parent work source")
        }
        let revision = try Self.parentWorkRevision(from: revisionText)
        let rows: [[String: NodeSQLiteValue]] = if let parentBlockCIDs {
            if parentBlockCIDs.isEmpty {
                []
            } else {
                try database.query(
                    "SELECT block_cid, grind_id, work FROM parent_work_facts WHERE block_cid IN (\((1...parentBlockCIDs.count).map { "?\($0)" }.joined(separator: ", "))) ORDER BY block_cid, grind_id",
                    params: parentBlockCIDs.sorted().map(NodeSQLiteValue.text)
                )
            }
        } else {
            try database.query(
                "SELECT block_cid, grind_id, work FROM parent_work_facts ORDER BY block_cid, grind_id"
            )
        }
        guard parentBlockCIDs != nil || factCount == Int64(rows.count) else {
            throw NodeStoreError.corrupt("immediate-parent work fact count mismatch")
        }
        var facts: [InheritedWorkFact] = []
        facts.reserveCapacity(rows.count)
        for row in rows {
            guard let blockCID = row["block_cid"]?.textValue,
                  let grindID = row["grind_id"]?.textValue,
                  let workText = row["work"]?.textValue,
                  CIDIdentity.isCanonical(blockCID),
                  CIDIdentity.isCanonical(grindID) else {
                throw NodeStoreError.corrupt("malformed inherited work fact")
            }
            guard let fact = InheritedWorkFact(
                blockCID: blockCID,
                grindID: grindID,
                work: try Self.parentWorkValue(from: workText)
            ) else {
                throw NodeStoreError.corrupt("zero inherited work fact")
            }
            facts.append(fact)
        }
        return InheritedWorkSnapshot(revision: revision, facts: facts)
    }

    func inheritedWorkRevision() throws -> UInt64? {
        guard parentWorkAuthorityKey != nil else { return nil }
        let rows = try database.query(
            "SELECT revision FROM parent_work_source"
        )
        guard rows.count <= 1 else {
            throw NodeStoreError.corrupt("duplicate immediate-parent work source")
        }
        guard let row = rows.first else { return nil }
        guard let revisionText = row["revision"]?.textValue else {
            throw NodeStoreError.corrupt("malformed immediate-parent work source")
        }
        return try Self.parentWorkRevision(from: revisionText)
    }

    /// Persist one authenticated parent's monotone facts. A revision is only a
    /// progress watermark, so an older fragment may still strengthen one
    /// physical grind at its reserved parent-block location. Returns only
    /// facts that changed, at the durable revision, so Core need not reread
    /// the complete source.
    func mergeInheritedWorkSnapshot(
        _ snapshot: InheritedWorkSnapshot,
        from authorityKey: String
    ) throws -> InheritedWorkSnapshot? {
        guard let authority = parentWorkAuthorityKey,
              authority.value == authorityKey,
              snapshot.hasUniqueGrindLocations else {
            throw NodeStoreError.invalidConfiguration(
                "invalid immediate-parent work facts"
            )
        }
        let facts = try snapshot.blockCIDs.flatMap { blockCID in
            guard CIDIdentity.isCanonical(blockCID) else {
                throw NodeStoreError.invalidConfiguration(
                    "inherited work has an invalid child block identifier"
                )
            }
            let measure = snapshot.sourceWork(forBlock: blockCID)
            guard !measure.isEmpty else {
                throw NodeStoreError.invalidConfiguration(
                    "inherited work contains an empty child block measure"
                )
            }
            return try measure.grindIDs.sorted().map { grindID in
                guard CIDIdentity.isCanonical(grindID) else {
                    throw NodeStoreError.invalidConfiguration(
                        "inherited work has an invalid physical grind identifier"
                    )
                }
                guard let work = measure.work(forGrind: grindID), work > .zero else {
                    throw NodeStoreError.invalidConfiguration(
                        "inherited work contains zero physical grind work"
                    )
                }
                return (blockCID, grindID, work)
            }
        }
        return try database.transaction {
            var advanced = false
            var changedFacts: [InheritedWorkFact] = []
            var durableRevision = snapshot.revision
            let sourceRows = try database.query(
                "SELECT revision, fact_count FROM parent_work_source"
            )
            guard sourceRows.count <= 1 else {
                throw NodeStoreError.corrupt("duplicate immediate-parent work source")
            }
            if let sourceRow = sourceRows.first {
                guard let revisionText = sourceRow["revision"]?.textValue,
                      let factCount = sourceRow["fact_count"]?.intValue,
                      factCount >= 0 else {
                    throw NodeStoreError.corrupt("malformed immediate-parent work source")
                }
                let currentRevision = try Self.parentWorkRevision(from: revisionText)
                durableRevision = max(currentRevision, snapshot.revision)
                if snapshot.revision > currentRevision {
                    try database.execute(
                        "UPDATE parent_work_source SET revision = ?1 WHERE singleton = 1",
                        params: [.text(String(snapshot.revision))]
                    )
                    advanced = true
                }
            } else {
                let hasFacts = try hasParentWorkFacts()
                guard !hasFacts else {
                    throw NodeStoreError.corrupt("parent work facts have no source revision")
                }
                try database.execute(
                    "INSERT INTO parent_work_source (singleton, revision, fact_count) VALUES (1, ?1, 0)",
                    params: [.text(String(snapshot.revision))]
                )
                advanced = true
            }

            for (blockCID, grindID, work) in facts {
                let locationRows = try database.query(
                    "SELECT block_cid, work FROM parent_work_facts WHERE grind_id = ?1",
                    params: [.text(grindID)]
                )
                guard locationRows.count <= 1 else {
                    throw NodeStoreError.corrupt("duplicate parent grind")
                }
                guard locationRows.allSatisfy({
                    $0["block_cid"]?.textValue == blockCID
                }) else {
                    throw NodeStoreError.corrupt(
                        "one parent grind has multiple block locations"
                    )
                }
                let currentWork = try locationRows.first?["work"]?.textValue.map {
                    try Self.parentWorkValue(from: $0)
                }
                if work > (currentWork ?? .zero) {
                    if currentWork == nil {
                        try database.execute(
                            "INSERT INTO parent_work_facts (block_cid, grind_id, work) VALUES (?1, ?2, ?3)",
                            params: [
                                .text(blockCID), .text(grindID), .text(work.toHexString()),
                            ]
                        )
                        try database.execute(
                            "UPDATE parent_work_source SET fact_count = fact_count + 1 WHERE singleton = 1"
                        )
                    } else {
                        try database.execute(
                            "UPDATE parent_work_facts SET work = ?1 WHERE grind_id = ?2",
                            params: [
                                .text(work.toHexString()), .text(grindID),
                            ]
                        )
                    }
                    advanced = true
                    changedFacts.append(InheritedWorkFact(
                        blockCID: blockCID,
                        grindID: grindID,
                        work: work
                    )!)
                }
            }
            guard advanced else { return nil }
            return InheritedWorkSnapshot(
                revision: durableRevision,
                facts: changedFacts
            )
        }
    }

    private static func acceptedBlocks(
        in batch: ChainAdmissionBatch
    ) throws -> [AcceptedBlockRecord] {
        var blocks: [String: AcceptedBlockRecord] = [:]
        for fact in batch.facts {
            guard case .block(let block) = fact else { continue }
            let record = AcceptedBlockRecord(
                blockCID: block.blockHash,
                parentCID: block.parentBlockHash
            )
            if let existing = blocks[record.blockCID], existing != record {
                throw NodeStoreError.conflictingAdmissionFact
            }
            blocks[record.blockCID] = record
        }
        return blocks.values.sorted { $0.blockCID < $1.blockCID }
    }

    private func persistedAcceptedBlock(
        from row: [String: NodeSQLiteValue]
    ) throws -> PersistedAcceptedBlock {
        guard let blockCID = row["block_cid"]?.textValue,
              !blockCID.isEmpty,
              let admissionSequence = row["admission_seq"]?.intValue,
              admissionSequence > 0,
              let rawParent = row["parent_cid"] else {
            throw NodeStoreError.corrupt("malformed accepted-block index")
        }
        let parentCID: String?
        switch rawParent {
        case .null:
            parentCID = nil
        case .text(let value) where !value.isEmpty:
            parentCID = value
        default:
            throw NodeStoreError.corrupt("malformed accepted-block parent")
        }
        return PersistedAcceptedBlock(
            blockCID: blockCID,
            parentCID: parentCID,
            admissionSequence: admissionSequence
        )
    }

    private func validateAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        admissionSequence: Int64
    ) throws {
        for block in blocks {
            let rows = try database.query(
                "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks WHERE block_cid = ?1",
                params: [.text(block.blockCID)]
            )
            guard let row = rows.first else {
                throw NodeStoreError.corrupt(
                    "an admission batch is missing its accepted-block index"
                )
            }
            let persisted = try persistedAcceptedBlock(from: row)
            guard persisted.parentCID == block.parentCID,
                  persisted.admissionSequence <= admissionSequence else {
                throw NodeStoreError.corrupt("malformed accepted-block index")
            }
        }
    }

    private func persistAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        admissionSequence: Int64
    ) throws {
        for block in blocks {
            let rows = try database.query(
                "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks WHERE block_cid = ?1",
                params: [.text(block.blockCID)]
            )
            if let row = rows.first {
                let persisted = try persistedAcceptedBlock(from: row)
                guard persisted.parentCID == block.parentCID,
                      persisted.admissionSequence <= admissionSequence else {
                    throw NodeStoreError.corrupt("conflicting accepted-block index")
                }
                continue
            }
            try database.execute(
                "INSERT INTO accepted_blocks (block_cid, parent_cid, admission_seq) VALUES (?1, ?2, ?3)",
                params: [
                    .text(block.blockCID),
                    block.parentCID.map(NodeSQLiteValue.text) ?? .null,
                    .int(admissionSequence),
                ]
            )
        }
    }

    private func prepareHierarchyArtifacts(
        _ artifacts: AdmissionHierarchyArtifacts?,
        carrierCIDs: Set<String>
    ) async throws -> PreparedAdmissionHierarchyArtifacts? {
        guard let artifacts else { return nil }
        let link = artifacts.carrierLink
        guard !link.carrierCID.isEmpty,
              !link.rootCID.isEmpty,
              link.parentPath == chainPath,
              carrierCIDs.contains(link.carrierCID) else {
            throw NodeStoreError.invalidConfiguration(
                "issued hierarchy artifacts are outside their admission batch"
            )
        }
        if chainPath.count == 1,
           (link.rootCID != link.carrierCID || artifacts.carrierEvidence != nil) {
            throw NodeStoreError.invalidConfiguration(
                "Nexus carrier evidence must be rooted at its carrier"
            )
        }
        if chainPath.count > 1, artifacts.carrierEvidence == nil {
            throw NodeStoreError.invalidConfiguration(
                "child carrier evidence requires its authenticated parent proof"
            )
        }

        let parentGenesisLinks = try prepareParentGenesisLinks(
            artifacts.parentGenesisLinks
        )

        let carrierEvidence: PreparedAdmissionCarrierEvidence?
        if let evidence = artifacts.carrierEvidence {
            carrierEvidence = try await prepareCarrierEvidence(
                evidence,
                expectedChildCIDs: Set([link.carrierCID]),
                expectedRootCID: link.rootCID
            )
        } else {
            carrierEvidence = nil
        }

        return PreparedAdmissionHierarchyArtifacts(
            carrierLink: link,
            carrierLinkPayload: try Self.encode(link),
            carrierEvidence: carrierEvidence,
            parentGenesisLinks: parentGenesisLinks
        )
    }

    private func prepareCarrierEvidence(
        _ evidence: AdmissionCarrierEvidence,
        expectedChildCIDs: Set<String>,
        expectedRootCID: String?
    ) async throws -> PreparedAdmissionCarrierEvidence {
        _ = try Self.validatedChildData(evidence.child)
        let childCID = try BlockHeader(node: evidence.child).rawCID
        guard expectedChildCIDs.contains(childCID),
              expectedRootCID.map({ $0 == evidence.proof.rootCID }) ?? true,
              let edge = await DirectChildEdge.derive(from: evidence.proof),
              edge.childCID == childCID,
              let directory = evidence.proof.directoryPath.last,
              edge.directory == directory else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let expectedParentPath = Array(chainPath.dropLast())
        if let parentLink = evidence.parentCarrierLink {
            guard parentLink.parentPath == expectedParentPath,
                  parentLink.carrierCID == edge.parentCarrierCID,
                  parentLink.rootCID == evidence.proof.rootCID else {
                throw NodeStoreError.invalidIssuedChildProof(childCID)
            }
        }
        if let genesisLink = evidence.parentGenesisLink {
            guard genesisLink.parentPath == expectedParentPath,
                  genesisLink.directory == chainPath.last,
                  genesisLink.childGenesisCID == childCID,
                  genesisLink.parentWorkAuthorityKey == parentWorkAuthorityKey else {
                throw NodeStoreError.invalidIssuedChildProof(childCID)
            }
        }
        if let certificate = evidence.parentCarrierCertificate {
            guard let parentLink = evidence.parentCarrierLink,
                  let authority = parentWorkAuthorityKey,
                  certificate.verifies(
                    link: parentLink,
                    authorityKey: authority,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: expectedParentPath
                  ) else {
                throw NodeStoreError.invalidIssuedChildProof(childCID)
            }
        }
        if let certificate = evidence.parentGenesisCertificate {
            guard let genesisLink = evidence.parentGenesisLink,
                  let authority = parentWorkAuthorityKey,
                  certificate.verifies(
                    link: genesisLink,
                    authorityKey: authority,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: expectedParentPath
                  ) else {
                throw NodeStoreError.invalidIssuedChildProof(childCID)
            }
        }
        guard edge.edgeCID != nil, let directProof = edge.proof else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let portableEnvelopePayload = try ChildValidationPackageEnvelope(
            ChildValidationPackage(
                proof: evidence.proof,
                parentCarrierLink: evidence.parentCarrierLink,
                parentGenesisLink: evidence.parentGenesisLink
            ),
            parentCarrierCertificate: evidence.parentCarrierCertificate,
            parentGenesisCertificate: evidence.parentGenesisCertificate
        ).encode()
        let hasPortableGenesis = evidence.child.parent == nil
            ? evidence.parentGenesisLink != nil
                && evidence.parentGenesisCertificate != nil
            : evidence.parentGenesisLink == nil
                && evidence.parentGenesisCertificate == nil
        let directAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: directProof)
            ).encode(),
            acquisitionEntries: evidence.acquisitionEntries,
            childCID: childCID
        )
        let proofAttachment = try ChildEvidenceVolume(
            envelopeBytes: portableEnvelopePayload,
            acquisitionEntries: evidence.acquisitionEntries,
            childCID: childCID
        )
        return PreparedAdmissionCarrierEvidence(
            edge: edge,
            childCID: childCID,
            directory: directory,
            rootCID: evidence.proof.rootCID,
            isPortable: evidence.parentCarrierLink != nil
                && evidence.parentCarrierCertificate != nil
                && hasPortableGenesis,
            directAttachment: directAttachment,
            proofAttachment: proofAttachment
        )
    }

    private func prepareParentGenesisLinks(
        _ links: [ParentGenesisLink]
    ) throws -> [(link: ParentGenesisLink, payload: Data)] {
        let links = Array(Set(links)).sorted {
            ($0.directory, $0.childGenesisCID)
                < ($1.directory, $1.childGenesisCID)
        }
        guard links.allSatisfy({ link in
            link.parentPath == chainPath
                && !link.directory.isEmpty
                && !link.childGenesisCID.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "issued genesis link belongs to a different chain path"
            )
        }
        return try links.map { (link: $0, payload: try Self.encode($0)) }
    }

    private func persistHierarchyArtifacts(
        _ artifacts: PreparedAdmissionHierarchyArtifacts
    ) throws {
        if let evidence = artifacts.carrierEvidence {
            try persistCarrierEvidence(evidence)
        }
        try persistParentFacts(
            link: artifacts.carrierLink,
            payload: artifacts.carrierLinkPayload,
            parentGenesisLinks: artifacts.parentGenesisLinks
        )
    }

    private func persistCarrierEvidence(
        _ evidence: PreparedAdmissionCarrierEvidence
    ) throws {
        guard let edgeCID = evidence.edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(evidence.childCID)
        }
        try persistIssuedChildEdgeRow(
            evidence.edge,
            directAttachmentCID: evidence.directAttachment.rawCID
        )
        try persistIssuedChildProofRow(
            scope: .incomingCarrier,
            edgeCID: edgeCID,
            rootCID: evidence.rootCID,
            isPortable: evidence.isPortable,
            attachmentCID: evidence.proofAttachment.rawCID
        )
    }

    private func recoveryVolumes(
        in artifacts: PreparedAdmissionHierarchyArtifacts?
    ) throws -> [ChildEvidenceVolume] {
        guard let evidence = artifacts?.carrierEvidence else { return [] }
        return [evidence.directAttachment, evidence.proofAttachment]
    }

    private func persistParentFacts(
        link: ParentCarrierLink,
        payload: Data,
        parentGenesisLinks: [(link: ParentGenesisLink, payload: Data)]
    ) throws {
        let source = PersistedParentFactSource(
            carrierLink: link,
            parentGenesisLinks: parentGenesisLinks.map(\.link)
        )
        try database.execute(
            "INSERT OR IGNORE INTO issued_parent_fact_sources (payload) VALUES (?1)",
            params: [.blob(try Self.encode(source))]
        )
        try persistIssuedParentFact(
            kind: "carrier",
            keyA: link.carrierCID,
            keyB: link.rootCID,
            payload: payload
        )
        for genesis in parentGenesisLinks {
            try persistIssuedParentFact(
                kind: "genesis",
                keyA: genesis.link.directory,
                keyB: genesis.link.childGenesisCID,
                payload: genesis.payload
            )
        }
    }

    func persistIssuedHierarchyArtifacts(
        _ artifacts: AdmissionHierarchyArtifacts,
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16
    ) async throws {
        let link = artifacts.carrierLink
        guard pendingChildProofRoutes.allSatisfy({
            $0.carrierCID == link.carrierCID && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route belongs to another carrier"
            )
        }
        guard let prepared = try await prepareHierarchyArtifacts(
            artifacts,
            carrierCIDs: [link.carrierCID]
        ) else {
            throw NodeStoreError.corrupt("missing issued hierarchy artifacts")
        }
        for volume in try recoveryVolumes(in: prepared) {
            try await volume.store(storer: recoveryVolumeStorer)
        }
        try database.transaction {
            try persistHierarchyArtifacts(prepared)
            try persistPendingChildProofRouteRows(
                pendingChildProofRoutes,
                capacity: pendingChildProofCapacity
            )
        }
    }

    func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String
    ) async throws -> ParentCarrierLink? {
        guard let payload = try issuedParentFact(
            kind: "carrier",
            keyA: carrierCID,
            keyB: rootCID
        ) else { return nil }
        let link = try Self.decode(ParentCarrierLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.carrierCID == carrierCID,
              link.rootCID == rootCID else {
            throw NodeStoreError.corrupt("malformed locally issued carrier link")
        }
        return link
    }

    func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String
    ) async throws -> ParentGenesisLink? {
        guard let payload = try issuedParentFact(
            kind: "genesis",
            keyA: directory,
            keyB: childGenesisCID
        ) else { return nil }
        let link = try Self.decode(ParentGenesisLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.directory == directory,
              link.childGenesisCID == childGenesisCID else {
            throw NodeStoreError.corrupt("malformed locally issued genesis link")
        }
        return link
    }

    func hasIssuedChildDirectory(_ directory: String) throws -> Bool {
        let rows = try database.query(
            "SELECT key_b, payload FROM issued_parent_facts WHERE kind = 'genesis' AND key_a = ?1 ORDER BY key_b",
            params: [.text(directory)]
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
    /// child. Different Nexus roots and directories for the same child are
    /// distinct valid evidence, so the cache is set-valued by
    /// `(childCID, directory, rootCID)`.
    func persistIssuedChildProof(
        _ proof: ChildBlockProof,
        child: Block,
        acquisitionEntries: [String: Data],
        parentCarrierCID: String? = nil,
        rootEnvelope: ChildValidationPackageEnvelope,
        rootAuthorityKey: ParentWorkAuthorityKey
    ) async throws {
        _ = try Self.validatedChildData(child)
        let childCID = try BlockHeader(node: child).rawCID
        guard let directory = proof.directoryPath.last else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard let edge = await DirectChildEdge.derive(from: proof),
              edge.childCID == childCID,
              edge.directory == directory,
              proof.directoryPath
                == Array(chainPath.dropFirst()) + [directory],
              parentCarrierCID.map({ $0 == edge.parentCarrierCID }) ?? true else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        _ = try await validatedProofPayload(
            proof,
            childCID: childCID
        )
        guard let edgeCID = edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard let directProof = edge.proof else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let directAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: directProof)
            ).encode(),
            acquisitionEntries: acquisitionEntries,
            childCID: childCID
        )
        guard rootEnvelope.proofBytes == (try? proof.serialize()),
              let carrierLink = rootEnvelope.parentCarrierLink,
              carrierLink.parentPath == chainPath,
              carrierLink.carrierCID == edge.parentCarrierCID,
              carrierLink.rootCID == proof.rootCID,
              let carrierCertificate = rootEnvelope.parentCarrierCertificate,
              carrierCertificate.verifies(
                link: carrierLink,
                authorityKey: rootAuthorityKey,
                expectedNexusGenesisCID: nexusGenesisCID,
                expectedParentPath: chainPath
              ) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        if child.parent == nil {
            guard let genesisLink = rootEnvelope.parentGenesisLink,
                  genesisLink.parentPath == chainPath,
                  genesisLink.directory == directory,
                  genesisLink.childGenesisCID == childCID,
                  genesisLink.parentWorkAuthorityKey == rootAuthorityKey,
                  let genesisCertificate = rootEnvelope.parentGenesisCertificate,
                  genesisCertificate.verifies(
                    link: genesisLink,
                    authorityKey: rootAuthorityKey,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: chainPath
                  ) else {
                throw NodeStoreError.invalidIssuedChildProof(childCID)
            }
        } else if rootEnvelope.parentGenesisLink != nil
                    || rootEnvelope.parentGenesisCertificate != nil {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let proofAttachment = try ChildEvidenceVolume(
            envelopeBytes: try rootEnvelope.encode(),
            acquisitionEntries: acquisitionEntries,
            childCID: childCID
        )
        try await directAttachment.store(storer: recoveryVolumeStorer)
        try await proofAttachment.store(storer: recoveryVolumeStorer)
        try database.transaction {
            try persistIssuedChildEdgeRow(
                edge,
                directAttachmentCID: directAttachment.rawCID
            )
            try persistIssuedChildProofRow(
                scope: .outgoingDirectChild,
                edgeCID: edgeCID,
                rootCID: proof.rootCID,
                isPortable: true,
                attachmentCID: proofAttachment.rawCID
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

    private func persistIssuedChildEdgeRow(
        _ edge: DirectChildEdge,
        directAttachmentCID: String
    ) throws {
        guard let edgeCID = edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(edge.childCID)
        }
        let byIdentity = try database.query(
            "SELECT parent_carrier_cid, directory, child_cid, direct_attachment_cid FROM issued_child_edges WHERE edge_cid = ?1",
            params: [.text(edgeCID)]
        )
        let byTuple = try database.query(
            "SELECT edge_cid, direct_attachment_cid FROM issued_child_edges WHERE parent_carrier_cid = ?1 AND directory = ?2 AND child_cid = ?3",
            params: [
                .text(edge.parentCarrierCID), .text(edge.directory),
                .text(edge.childCID),
            ]
        )
        if let row = byIdentity.first {
            guard row["parent_carrier_cid"]?.textValue == edge.parentCarrierCID,
                  row["directory"]?.textValue == edge.directory,
                  row["child_cid"]?.textValue == edge.childCID,
                  row["direct_attachment_cid"]?.textValue == directAttachmentCID,
                  byTuple.first?["edge_cid"]?.textValue == edgeCID,
                  byTuple.first?["direct_attachment_cid"]?.textValue
                    == directAttachmentCID else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        guard byTuple.isEmpty else {
            throw NodeStoreError.conflictingIssuedChildProof
        }
        try database.execute(
            "INSERT INTO issued_child_edges (edge_cid, parent_carrier_cid, directory, child_cid, direct_attachment_cid) VALUES (?1, ?2, ?3, ?4, ?5)",
            params: [
                .text(edgeCID), .text(edge.parentCarrierCID),
                .text(edge.directory), .text(edge.childCID),
                .text(directAttachmentCID),
            ]
        )
    }

    private func persistedChildEdge(
        from row: [String: NodeSQLiteValue]
    ) async throws -> DirectChildEdge? {
        guard let edgeCID = row["edge_cid"]?.textValue,
              let parentCarrierCID = row["parent_carrier_cid"]?.textValue,
              let directory = row["directory"]?.textValue,
              let childCID = row["child_cid"]?.textValue,
              let attachmentCID = row["direct_attachment_cid"]?.textValue else {
            return nil
        }
        let attachment = try await recoveryVolume(
            attachmentCID: attachmentCID,
            childCID: childCID
        )
        guard let envelope = try? ChildValidationPackageEnvelope.decode(
                  attachment.envelopeBytes
              ),
              envelope.parentCarrierLink == nil,
              envelope.parentGenesisLink == nil,
              envelope.parentCarrierCertificate == nil,
              envelope.parentGenesisCertificate == nil,
              let proof = ChildBlockProof.deserialize(envelope.proofBytes),
              let edge = await DirectChildEdge.derive(from: proof),
              edge.edgeCID == edgeCID,
              edge.parentCarrierCID == parentCarrierCID,
              edge.directory == directory,
              edge.childCID == childCID,
              let childData = attachment.acquisitionEntries[childCID],
              let child = Self.contentBoundChild(cid: childCID, data: childData),
              await edge.validates(child: child) else {
            return nil
        }
        return edge
    }

    private func recoveryVolume(
        attachmentCID: String,
        childCID: String
    ) async throws -> ChildEvidenceVolume {
        guard CIDIdentity.isCanonical(attachmentCID) else {
            throw NodeStoreError.corrupt("malformed recovery attachment CID")
        }
        do {
            guard let serialized = await recoveryVolumeBroker.fetchVolumeLocal(
                root: attachmentCID
            ) else {
                throw NodeStoreError.corrupt("incomplete recovery attachment")
            }
            return try ChildEvidenceVolume(
                serialized: serialized,
                childCID: childCID
            )
        } catch let error as NodeStoreError {
            throw error
        } catch {
            throw NodeStoreError.corrupt("missing recovery attachment \(attachmentCID)")
        }
    }

    private func persistIssuedChildProofRow(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String,
        isPortable: Bool,
        attachmentCID: String
    ) throws {
        let rows = try database.query(
            "SELECT is_portable, attachment_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        if let row = rows.first {
            guard row["is_portable"]?.intValue == (isPortable ? 1 : 0),
                  row["attachment_cid"]?.textValue == attachmentCID else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_child_proofs (scope, edge_cid, root_cid, is_portable, attachment_cid) VALUES (?1, ?2, ?3, ?4, ?5)",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
                .int(isPortable ? 1 : 0),
                .text(attachmentCID),
            ]
        )
    }

    func issuedChildEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await issuedChildEvidence(
            scope: .outgoingDirectChild,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func incomingCarrierEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await issuedChildEvidence(
            scope: .incomingCarrier,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func issuedChildEvidence(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> IssuedChildEvidence? {
        let rows = try database.query(
            "SELECT e.child_cid, e.directory FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND p.edge_cid = ?2 AND p.root_cid = ?3 LIMIT 1",
            params: [.text(scope.rawValue), .text(edgeCID), .text(rootCID)]
        )
        guard let row = rows.first,
              let childCID = row["child_cid"]?.textValue,
              let directory = row["directory"]?.textValue else {
            return nil
        }
        let evidence = try await issuedChildEvidence(
            scope: scope,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID,
            exactEdgeCID: edgeCID
        )
        guard evidence?.edgeCID == edgeCID else {
            throw NodeStoreError.corrupt("malformed child root attachment")
        }
        return evidence
    }

    func issuedChildEvidence(
        scope: IssuedChildProofScope,
        edgeCID: String
    ) async throws -> IssuedChildEvidence? {
        guard let rootCID = try database.query(
            "SELECT root_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 ORDER BY root_cid LIMIT 1",
            params: [.text(scope.rawValue), .text(edgeCID)]
        ).first?["root_cid"]?.textValue else {
            return nil
        }
        return try await issuedChildEvidence(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
        )
    }

    private func issuedChildEvidence(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        rootCID: String? = nil,
        exactEdgeCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        guard !directory.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof directory must be nonempty"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let rootCID, let exactEdgeCID {
            rows = try database.query(
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, p.is_portable, e.parent_carrier_cid, e.directory, e.child_cid, e.direct_attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND p.edge_cid = ?2 AND e.child_cid = ?3 AND e.directory = ?4 AND p.root_cid = ?5 LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(exactEdgeCID),
                    .text(childCID), .text(directory), .text(rootCID),
                ]
            )
        } else if let rootCID {
            rows = try database.query(
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, p.is_portable, e.parent_carrier_cid, e.directory, e.child_cid, e.direct_attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid = ?4 LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .text(rootCID),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, p.is_portable, e.parent_carrier_cid, e.directory, e.child_cid, e.direct_attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 ORDER BY p.root_cid, p.edge_cid LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                ]
            )
        }
        guard let row = rows.first else { return nil }
        guard let edgeCID = row["edge_cid"]?.textValue,
              let directory = row["directory"]?.textValue,
              let storedRoot = row["root_cid"]?.textValue,
              let attachmentCID = row["attachment_cid"]?.textValue,
              let parentCarrierCID = row["parent_carrier_cid"]?.textValue,
              let isPortable = row["is_portable"]?.intValue,
              isPortable == 0 || isPortable == 1 else {
            throw NodeStoreError.corrupt("malformed locally issued child proof")
        }
        let attachment = try await recoveryVolume(
            attachmentCID: attachmentCID,
            childCID: childCID
        )
        let envelope: ChildValidationPackageEnvelope
        do {
            envelope = try ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
            )
        } catch {
            throw NodeStoreError.corrupt("malformed child evidence attachment")
        }
        let acquisitionEntries = attachment.acquisitionEntries
        guard let childData = acquisitionEntries[childCID],
              let child = Self.contentBoundChild(cid: childCID, data: childData),
              let proof = ChildBlockProof.deserialize(envelope.proofBytes),
              (try? proof.serialize()) == envelope.proofBytes,
              proof.directoryPath.last == directory,
              proof.rootCID == storedRoot,
              try await Self.proves(
                  proof,
                  childCID: childCID,
                  from: chainPath
              ),
              let edge = await DirectChildEdge.derive(from: proof),
              edge.edgeCID == edgeCID,
              edge.parentCarrierCID == parentCarrierCID,
              edge.childCID == childCID,
              edge.directory == directory else {
            throw NodeStoreError.corrupt("malformed locally issued child proof")
        }
        let parentCarrierLink = envelope.parentCarrierLink
        let parentGenesisLink = envelope.parentGenesisLink
        let parentCarrierCertificate = envelope.parentCarrierCertificate
        let parentGenesisCertificate = envelope.parentGenesisCertificate
        let expectedParentPath = scope == .incomingCarrier
            ? Array(chainPath.dropLast())
            : chainPath
        let certificateAuthority = scope == .incomingCarrier
            ? parentWorkAuthorityKey
            : issuingParentWorkAuthorityKey
        guard parentCarrierLink.map({ link in
                  link.parentPath == expectedParentPath
                    && link.carrierCID == edge.parentCarrierCID
                    && link.rootCID == storedRoot
              }) ?? true,
              parentGenesisLink.map({ link in
                  link.parentPath == expectedParentPath
                    && link.directory == directory
                    && link.childGenesisCID == childCID
              }) ?? true,
              parentCarrierCertificate.map({ certificate in
                  guard let link = parentCarrierLink,
                        let authority = certificateAuthority else { return false }
                  return certificate.verifies(
                    link: link,
                    authorityKey: authority,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: expectedParentPath
                  )
              }) ?? true,
              parentGenesisCertificate.map({ certificate in
                  guard let link = parentGenesisLink,
                        let authority = certificateAuthority else { return false }
                  return certificate.verifies(
                    link: link,
                    authorityKey: authority,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: expectedParentPath
                  )
              }) ?? true,
              (isPortable == 1)
                == (parentCarrierLink != nil
                    && parentCarrierCertificate != nil
                    && (child.parent == nil
                        ? parentGenesisLink != nil
                            && parentGenesisCertificate != nil
                        : parentGenesisLink == nil
                            && parentGenesisCertificate == nil)) else {
            throw NodeStoreError.corrupt("invalid portable parent attachment")
        }
        return IssuedChildEvidence(
            edgeCID: edgeCID,
            attachmentCID: attachmentCID,
            edge: edge,
            proof: proof,
            child: child,
            acquisitionEntries: acquisitionEntries,
            parentCarrierLink: parentCarrierLink,
            parentGenesisLink: parentGenesisLink,
            parentCarrierCertificate: parentCarrierCertificate,
            parentGenesisCertificate: parentGenesisCertificate
        )
    }

    func issuedChildProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await issuedChildProofRoots(
            scope: .outgoingDirectChild,
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    func incomingCarrierProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await issuedChildProofRoots(
            scope: .incomingCarrier,
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    private func issuedChildProofRoots(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof page limit must be positive"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let afterRootCID {
            rows = try database.query(
                "SELECT DISTINCT p.root_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid > ?4 ORDER BY p.root_cid LIMIT ?5",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .text(afterRootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT DISTINCT p.root_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 ORDER BY p.root_cid LIMIT ?4",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .int(sqlLimit),
                ]
            )
        }
        var roots: [String] = []
        roots.reserveCapacity(rows.count)
        for row in rows {
            guard let root = row["root_cid"]?.textValue,
                  !root.isEmpty,
                  try await issuedChildEvidence(
                    scope: scope,
                    childCID: childCID,
                    directory: directory,
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
        after: IssuedChildEvidenceSummary?,
        limit: Int
    ) async throws -> [IssuedChildEvidenceSummary] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child-evidence page must be bounded"
            )
        }
        guard try hasIssuedChildDirectory(directory) else {
            return []
        }
        let rows: [[String: NodeSQLiteValue]]
        if let after {
            rows = try database.query(
                "SELECT e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2 AND (e.child_cid > ?3 OR (e.child_cid = ?3 AND p.root_cid > ?4)) ORDER BY e.child_cid, p.root_cid LIMIT ?5",
                params: [
                    .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                    .text(directory), .text(after.childCID),
                    .text(after.rootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2 ORDER BY e.child_cid, p.root_cid LIMIT ?3",
                params: [
                    .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                    .text(directory), .int(sqlLimit),
                ]
            )
        }
        var summaries: [IssuedChildEvidenceSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows {
            guard let childCID = row["child_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  let attachmentCID = row["attachment_cid"]?.textValue,
                  CIDIdentity.isCanonical(attachmentCID),
                  try await issuedChildEvidence(
                    childCID: childCID,
                    directory: directory,
                    rootCID: rootCID
                  ) != nil else {
                throw NodeStoreError.corrupt(
                    "malformed locally issued child-evidence index"
                )
            }
            summaries.append(IssuedChildEvidenceSummary(
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: attachmentCID
            ))
        }
        return summaries
    }

    func childRootAttachmentSummaries(
        scope: IssuedChildProofScope,
        directory: String,
        after: ChildRootAttachmentSummary?,
        limit: Int,
        portableOnly: Bool = false
    ) async throws -> [ChildRootAttachmentSummary] {
        guard !directory.isEmpty, limit > 0,
              !portableOnly || scope == .incomingCarrier,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child root-attachment page must be bounded"
            )
        }
        let portablePredicate = portableOnly
            ? " AND p.is_portable = 1"
            : ""
        let rows: [[String: NodeSQLiteValue]]
        if let after {
            rows = try database.query(
                "SELECT p.edge_cid, e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2\(portablePredicate) AND (p.edge_cid > ?3 OR (p.edge_cid = ?3 AND p.root_cid > ?4)) ORDER BY p.edge_cid, p.root_cid LIMIT ?5",
                params: [
                    .text(scope.rawValue), .text(directory), .text(after.edgeCID),
                    .text(after.rootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT p.edge_cid, e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2\(portablePredicate) ORDER BY p.edge_cid, p.root_cid LIMIT ?3",
                params: [
                    .text(scope.rawValue), .text(directory), .int(sqlLimit),
                ]
            )
        }
        var summaries: [ChildRootAttachmentSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows {
            guard let edgeCID = row["edge_cid"]?.textValue,
                  row["child_cid"]?.textValue != nil,
                  let rootCID = row["root_cid"]?.textValue,
                  let attachmentCID = row["attachment_cid"]?.textValue,
                  CIDIdentity.isCanonical(attachmentCID),
                  try await issuedChildEvidence(
                    scope: scope,
                    edgeCID: edgeCID,
                    rootCID: rootCID
                  ) != nil else {
                throw NodeStoreError.corrupt(
                    "malformed child root-attachment index"
                )
            }
            summaries.append(ChildRootAttachmentSummary(
                edgeCID: edgeCID,
                rootCID: rootCID,
                attachmentCID: attachmentCID
            ))
        }
        return summaries
    }

    func recoveryAttachmentCIDs() throws -> [String] {
        let rows = try database.query(
            "SELECT direct_attachment_cid AS cid FROM issued_child_edges UNION SELECT attachment_cid AS cid FROM issued_child_proofs UNION SELECT attachment_cid AS cid FROM prepared_child_proofs ORDER BY cid"
        )
        return try rows.map { row in
            guard let cid = row["cid"]?.textValue,
                  CIDIdentity.isCanonical(cid) else {
                throw NodeStoreError.corrupt("malformed recovery attachment index")
            }
            return cid
        }
    }

    func portableRecoveryAttachmentCID(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) throws -> String? {
        let rows = try database.query(
            "SELECT attachment_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3 AND is_portable = 1",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              let cid = row["attachment_cid"]?.textValue,
              CIDIdentity.isCanonical(cid) else {
            throw NodeStoreError.corrupt("malformed portable recovery attachment index")
        }
        return cid
    }

    /// Permanent root-independent hops already published by this parent.
    /// They outlive the bounded pre-publication recovery buffer and can be
    /// recomposed whenever this carrier gains another authenticated root.
    func retainedDirectChildProofs(
        carrierCID: String
    ) async throws -> [PreparedChildProof] {
        let rows = try database.query(
            "SELECT DISTINCT p.edge_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.parent_carrier_cid = ?2 ORDER BY p.edge_cid",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(carrierCID),
            ]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            guard let edgeCID = row["edge_cid"]?.textValue,
                  let evidence = try await issuedChildEvidence(
                    scope: .outgoingDirectChild,
                    edgeCID: edgeCID
                  ), let proof = evidence.edge.proof else {
                throw NodeStoreError.corrupt("malformed retained direct-child edge")
            }
            proofs.append(try PreparedChildProof(
                directory: evidence.edge.directory,
                child: evidence.child,
                proof: proof,
                acquisitionEntries: evidence.acquisitionEntries
            ))
        }
        return proofs
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
            attachment: ChildEvidenceVolume
        )] = []
        var directories = Set<String>()
        for entry in proofs.sorted(by: { $0.directory < $1.directory }) {
            _ = try Self.validatedChildData(entry.child)
            guard !entry.directory.isEmpty,
                  directories.insert(entry.directory).inserted,
                  entry.proof.rootCID == carrierCID,
                  entry.proof.directoryPath == [entry.directory],
                  await entry.proof.directHop()?.childCID == entry.childCID else {
                throw NodeStoreError.invalidIssuedChildProof(entry.childCID)
            }
            let payload = try entry.proof.serialize()
            guard ChildBlockProof.deserialize(payload) != nil else {
                throw NodeStoreError.invalidIssuedChildProof(entry.childCID)
            }
            canonical.append((
                entry.directory,
                entry.childCID,
                try ChildEvidenceVolume(
                    envelopeBytes: try ChildValidationPackageEnvelope(
                        ChildValidationPackage(proof: entry.proof)
                    ).encode(),
                    acquisitionEntries: entry.acquisitionEntries,
                    childCID: entry.childCID
                )
            ))
        }
        guard !canonical.isEmpty else { return }
        for entry in canonical {
            try await entry.attachment.store(storer: recoveryVolumeStorer)
        }

        try database.transaction {
            let existing = try database.query(
                "SELECT batch_seq, directory, child_cid, attachment_cid FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
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
                          row["attachment_cid"]?.textValue
                            == expected.attachment.rawCID else {
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
                        "INSERT INTO prepared_child_proofs (carrier_cid, batch_seq, directory, child_cid, attachment_cid) VALUES (?1, ?2, ?3, ?4, ?5)",
                        params: [
                            .text(carrierCID),
                            .int(batchSequence),
                            .text(entry.directory),
                            .text(entry.childCID),
                            .text(entry.attachment.rawCID),
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
        let unresolvedRoutes = try routes.filter { route in
            try database.query(
                "SELECT 1 FROM prepared_child_proofs WHERE carrier_cid = ?1 AND directory = ?2 LIMIT 1",
                params: [.text(route.carrierCID), .text(route.directory)]
            ).isEmpty
        }
        guard !unresolvedRoutes.isEmpty else { return }
        for (carrierCID, carrierRoutes) in Dictionary(
            grouping: unresolvedRoutes,
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
            "SELECT directory, child_cid, attachment_cid FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
            params: [.text(carrierCID)]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            guard let directory = row["directory"]?.textValue,
                  let childCID = row["child_cid"]?.textValue,
                  let attachmentCID = row["attachment_cid"]?.textValue else {
                throw NodeStoreError.corrupt("malformed prepared child proof")
            }
            let attachment = try await recoveryVolume(
                attachmentCID: attachmentCID,
                childCID: childCID
            )
            guard let envelope = try? ChildValidationPackageEnvelope.decode(
                      attachment.envelopeBytes
                  ),
                  let proof = ChildBlockProof.deserialize(envelope.proofBytes),
                  (try? proof.serialize()) == envelope.proofBytes,
                  let childData = attachment.acquisitionEntries[childCID],
                  let child = Self.contentBoundChild(cid: childCID, data: childData),
                  proof.rootCID == carrierCID,
                  proof.directoryPath == [directory],
                  await proof.directHop()?.childCID == childCID else {
                throw NodeStoreError.corrupt("malformed prepared child proof")
            }
            proofs.append(try PreparedChildProof(
                directory: directory,
                child: child,
                proof: proof,
                acquisitionEntries: attachment.acquisitionEntries
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

    func removePreparedChildProof(
        carrierCID: String,
        directory: String
    ) throws {
        try database.execute(
            "DELETE FROM prepared_child_proofs WHERE carrier_cid = ?1 AND directory = ?2",
            params: [.text(carrierCID), .text(directory)]
        )
    }

    /// Durable direct edges can outlive their bounded preparation row. Return
    /// only carriers whose retained edge has a newly learned upstream root
    /// that has not been composed into an outgoing attachment yet.
    func uncomposedDirectChildProofCarrierCIDs(
        parentDirectory: String
    ) async throws -> [String] {
        guard !parentDirectory.isEmpty else { return [] }
        return try database.query(
            """
            SELECT DISTINCT outgoing_edge.parent_carrier_cid AS carrier_cid
            FROM issued_child_edges AS outgoing_edge
            INNER JOIN issued_child_proofs AS retained
                ON retained.edge_cid = outgoing_edge.edge_cid
                AND retained.scope = ?1
            INNER JOIN issued_child_edges AS incoming_edge
                ON incoming_edge.child_cid = outgoing_edge.parent_carrier_cid
                AND incoming_edge.directory = ?2
            INNER JOIN issued_child_proofs AS incoming
                ON incoming.edge_cid = incoming_edge.edge_cid
                AND incoming.scope = ?3
            WHERE NOT EXISTS (
                SELECT 1
                FROM issued_child_proofs AS composed
                WHERE composed.scope = ?1
                    AND composed.edge_cid = outgoing_edge.edge_cid
                    AND composed.root_cid = incoming.root_cid
            )
            ORDER BY carrier_cid
            """,
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(parentDirectory),
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
            ]
        ).map { row in
            guard let carrierCID = row["carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt(
                    "malformed uncomposed direct-child carrier index"
                )
            }
            return carrierCID
        }
    }

    private func loadStagedAdmissions() throws -> [StagedAdmission] {
        try database.query(
            "SELECT seq, payload, volume_roots FROM admission_batches ORDER BY seq ASC"
        ).map { row in
            guard let sequence = row["seq"]?.intValue,
                  let payload = row["payload"]?.blobValue,
                  let rootsPayload = row["volume_roots"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed admission batch row")
            }
            return StagedAdmission(
                sequence: sequence,
                batch: try Self.decode(ChainAdmissionBatch.self, from: payload),
                volumeRoots: try Self.decode([String].self, from: rootsPayload)
            )
        }
    }

    private func persistIssuedParentFact(
        kind: String,
        keyA: String,
        keyB: String,
        payload: Data
    ) throws {
        guard !keyA.isEmpty, !keyB.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "issued parent fact keys must be nonempty"
            )
        }
        let rows = try database.query(
            "SELECT payload FROM issued_parent_facts WHERE kind = ?1 AND key_a = ?2 AND key_b = ?3",
            params: [.text(kind), .text(keyA), .text(keyB)]
        )
        if let existing = rows.first?["payload"]?.blobValue {
            guard existing == payload else {
                throw NodeStoreError.conflictingIssuedParentFact
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_parent_facts (kind, key_a, key_b, payload) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(kind), .text(keyA), .text(keyB), .blob(payload),
            ]
        )
    }

    private func issuedParentFact(
        kind: String,
        keyA: String,
        keyB: String
    ) throws -> Data? {
        return try database.query(
            "SELECT payload FROM issued_parent_facts WHERE kind = ?1 AND key_a = ?2 AND key_b = ?3",
            params: [.text(kind), .text(keyA), .text(keyB)]
        ).first?["payload"]?.blobValue
    }

    private static func addExpectedParentFact(
        key: IssuedParentFactKey,
        payload: Data,
        to facts: inout [IssuedParentFactKey: Data]
    ) throws {
        if let existing = facts[key], existing != payload {
            throw NodeStoreError.corrupt(
                "parent-fact sources disagree about an immutable fact"
            )
        }
        facts[key] = payload
    }

    private static func validateMetadata(
        in database: NodeSQLite,
        tableNames: Set<String>,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data,
        minimumRootWorkHex: String,
        spawningParentKey: String,
        issuingAuthorityKey: String
    ) throws {
        guard tableNames.contains("node_metadata") else {
            throw NodeStoreError.wipeRequired("missing schema metadata")
        }
        let rows: [[String: NodeSQLiteValue]]
        do {
            rows = try database.query(
                "SELECT schema_epoch, nexus_genesis_cid, chain_path, minimum_root_work, spawning_parent_key, issuing_authority_key FROM node_metadata WHERE singleton = 1"
            )
        } catch {
            throw NodeStoreError.wipeRequired("unreadable schema metadata")
        }
        guard rows.count == 1,
              rows[0]["schema_epoch"]?.intValue == schemaEpoch,
              rows[0]["nexus_genesis_cid"]?.textValue == nexusGenesisCID,
              rows[0]["chain_path"]?.blobValue == chainPath,
              rows[0]["minimum_root_work"]?.textValue == minimumRootWorkHex,
              rows[0]["spawning_parent_key"]?.textValue == spawningParentKey,
              rows[0]["issuing_authority_key"]?.textValue
                == issuingAuthorityKey else {
            throw NodeStoreError.wipeRequired(
                "schema epoch, Nexus genesis, chain path, minimum root work, spawning parent, or issuing authority changed"
            )
        }
    }

    private static let expectedTables: Set<String> = [
        "node_metadata",
        "admission_batches",
        "admission_facts",
        "accepted_blocks",
        "issued_parent_fact_sources",
        "issued_parent_facts",
        "issued_child_edges",
        "issued_child_proofs",
        "parent_work_source",
        "parent_work_facts",
        "local_mempool_transactions",
        "prepared_child_proofs",
        "pending_child_proof_routes",
    ]

    private static func createSchema(
        in database: NodeSQLite,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data,
        minimumRootWorkHex: String,
        spawningParentKey: String,
        issuingAuthorityKey: String
    ) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE node_metadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    schema_epoch INTEGER NOT NULL,
                    nexus_genesis_cid TEXT NOT NULL,
                    chain_path BLOB NOT NULL,
                    minimum_root_work TEXT NOT NULL,
                    spawning_parent_key TEXT NOT NULL,
                    issuing_authority_key TEXT NOT NULL
                )
                """)
            try database.execute(
                "INSERT INTO node_metadata (singleton, schema_epoch, nexus_genesis_cid, chain_path, minimum_root_work, spawning_parent_key, issuing_authority_key) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)",
                params: [
                    .int(schemaEpoch),
                    .text(nexusGenesisCID),
                    .blob(chainPath),
                    .text(minimumRootWorkHex),
                    .text(spawningParentKey),
                    .text(issuingAuthorityKey),
                ]
            )
            try createDataTables(in: database)
        }
    }

    private static func createDataTables(in database: NodeSQLite) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_batches (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                payload BLOB NOT NULL UNIQUE,
                volume_roots BLOB NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_facts (
                fact_id BLOB PRIMARY KEY,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS accepted_blocks (
                block_cid TEXT PRIMARY KEY,
                parent_cid TEXT,
                admission_seq INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS accepted_blocks_by_parent ON accepted_blocks (parent_cid, admission_seq, block_cid)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_parent_fact_sources (
                payload BLOB PRIMARY KEY
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_parent_facts (
                kind TEXT NOT NULL,
                key_a TEXT NOT NULL,
                key_b TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (kind, key_a, key_b)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_edges (
                edge_cid TEXT PRIMARY KEY,
                parent_carrier_cid TEXT NOT NULL,
                directory TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                direct_attachment_cid TEXT NOT NULL,
                UNIQUE (parent_carrier_cid, directory, child_cid)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_proofs (
                scope TEXT NOT NULL,
                edge_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                is_portable INTEGER NOT NULL CHECK (is_portable IN (0, 1)),
                attachment_cid TEXT NOT NULL,
                PRIMARY KEY (scope, edge_cid, root_cid)
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_edges_by_directory ON issued_child_edges (directory, child_cid, edge_cid)"
        )
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_edges_by_child ON issued_child_edges (child_cid, parent_carrier_cid, edge_cid)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS parent_work_source (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                revision TEXT NOT NULL,
                fact_count INTEGER NOT NULL CHECK (fact_count >= 0)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS parent_work_facts (
                block_cid TEXT NOT NULL,
                grind_id TEXT PRIMARY KEY,
                work TEXT NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS parent_work_facts_by_block ON parent_work_facts (block_cid, grind_id)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS local_mempool_transactions (
                transaction_cid TEXT PRIMARY KEY,
                added_at INTEGER NOT NULL CHECK (added_at >= 0)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS prepared_child_proofs (
                carrier_cid TEXT NOT NULL,
                batch_seq INTEGER NOT NULL,
                directory TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                attachment_cid TEXT NOT NULL,
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

    private func hasParentWorkFacts() throws -> Bool {
        try !database.query(
            "SELECT 1 AS present FROM parent_work_facts LIMIT 1"
        ).isEmpty
    }

    private static func parentWorkRevision(from value: String) throws -> UInt64 {
        guard let revision = UInt64(value), String(revision) == value else {
            throw NodeStoreError.corrupt("malformed parent work revision")
        }
        return revision
    }

    private static func parentWorkValue(from value: String) throws -> UInt256 {
        guard let work = UInt256.fromHexString(value),
              work > .zero,
              work.toHexString() == value else {
            throw NodeStoreError.corrupt("malformed parent work fact")
        }
        return work
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
        return await proof.directHop()?.childCID == childCID
    }

}

/// Records the canonical Volume boundaries materialized during one admission.
actor NodeAdmissionStorage: VolumeStorer {
    private let storage: any VolumeStorer
    private var roots = Set<String>()

    init(storage: any VolumeStorer) {
        self.storage = storage
    }

    func store(volume: SerializedVolume) async throws {
        try await storage.store(volume: volume)
        roots.insert(volume.root)
    }

    func takeStoredVolumeRoots() -> [String] {
        defer { roots.removeAll(keepingCapacity: true) }
        return roots.sorted()
    }
}
