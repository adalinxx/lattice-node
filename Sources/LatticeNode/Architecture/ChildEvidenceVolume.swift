import Foundation
import Ivy
import Lattice
import VolumeBroker
import cashew

enum ChildEvidenceVolumeError: Error, Equatable, Sendable {
    case malformed
    case oversized
}

/// One complete evidence Volume for a parent-issued child-work proof.
///
/// The proof is stored as a real cashew DAG: a small header node committing to
/// the child CID, the PoW root, the directory path, and the exact set of proof
/// entry CIDs, alongside the proof's own already-content-addressed CAS nodes as
/// separate volume entries. The proof is NOT flattened into a single blob, so a
/// large-but-legitimate multi-hop proof (many sparse state/receipt/continuity
/// nodes) is not bound to one transport frame — Ivy chunks the volume across
/// frames the same way it carries block and transaction content, and the total
/// is bounded by an operator budget rather than a hard per-evidence ceiling.
/// Child-chain validation content remains owned and served by the child chain.
struct ChildEvidenceVolume: Sendable {
    /// Header node: commits to the evidence identity and the exact entry set, so
    /// the volume root (the advertised `attachmentCID`) is a content address of
    /// the whole proof, not just its metadata.
    private struct Manifest: Scalar {
        let childCID: String
        let rootCID: String
        let directoryPath: [String]
        let entryCIDs: [String]
    }

    /// Total-bytes budget for the whole evidence DAG. Matches the transport's
    /// own volume-archive ceiling (Ivy carries a volume up to this as
    /// per-frame-bounded chunks), so a proof up to this size never wedges. This
    /// is an operator/transport budget, not a consensus constant: exhausting it
    /// declines the work, it does not make chain data invalid.
    static let maximumArchiveBytes = Int(IvyConfig.defaultProtocolMaxFrameSize) * 16
    /// Per-volume storage budget the fetch path will hold for one evidence root.
    static let maximumStorageBytes = maximumArchiveBytes
    /// Entry-count budget for the fetch path: the DAG is header + one node per
    /// proof entry, so it is always multi-entry. Bounded by the proof's own
    /// wire limit (ChildBlockProof serializes at most UInt16.max entries, which
    /// Ivy's per-volume entry cap also matches); total bytes are bounded
    /// separately by maximumArchiveBytes.
    static let maximumMembers = Int(UInt16.max)

    let serialized: SerializedVolume
    let proof: ChildBlockProof
    let envelopeBytes: Data

    var rawCID: String { serialized.root }

    /// Build from a transport envelope (the flat proof serialization). The
    /// envelope is decoded to a proof and re-modeled as a DAG; the flat form is
    /// never stored or single-framed.
    init(envelopeBytes: Data, childCID: String) throws {
        let envelope = try ChildValidationPackageEnvelope.decode(
            envelopeBytes,
            maximumEncodedSize: Self.maximumArchiveBytes
        )
        try self.init(proof: envelope.makeValidationPackage().proof, childCID: childCID)
    }

    init(proof: ChildBlockProof, childCID: String) throws {
        guard !childCID.isEmpty else {
            throw ChildEvidenceVolumeError.malformed
        }
        // `ChildBlockProof.init` canonicalizes entries by sorting on CID; the
        // envelope decode path (the only production caller) already rejects
        // duplicate/unsorted entries, so the entry CIDs are unique and ascending.
        var entries: [String: Data] = [:]
        for entry in proof.entries {
            entries[entry.cid] = entry.data
        }
        let entryCIDs = proof.entries.map(\.cid)
        let manifest = Manifest(
            childCID: childCID,
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entryCIDs: entryCIDs
        )
        let header = try VolumeImpl<Manifest>(node: manifest)
        let headerCID = header.rawCID
        // The header CID must not collide with a proof-entry CID (it would make
        // the entry set ambiguous). Content addressing makes this effectively
        // impossible, but reject rather than trust it.
        guard entries[headerCID] == nil else {
            throw ChildEvidenceVolumeError.malformed
        }
        entries[headerCID] = try header.mapToData()
        try self.init(
            serialized: SerializedVolume(root: headerCID, entries: entries),
            childCID: childCID
        )
    }

    init(serialized: SerializedVolume, childCID: String? = nil) throws {
        // Every entry is self-authenticating (cid == hash(data)).
        try serialized.validate()
        guard let rootData = serialized.entries[serialized.root],
              let manifest = Manifest(data: rootData),
              !manifest.childCID.isEmpty else {
            throw ChildEvidenceVolumeError.malformed
        }
        // The root is the canonical serialization of its own manifest.
        let canonicalRoot = try VolumeImpl<Manifest>(node: manifest)
        guard canonicalRoot.rawCID == serialized.root,
              try canonicalRoot.mapToData() == rootData else {
            throw ChildEvidenceVolumeError.malformed
        }
        guard childCID.map({ $0 == manifest.childCID }) ?? true else {
            throw ChildEvidenceVolumeError.malformed
        }
        // The entry set is EXACTLY the header plus the committed entry CIDs —
        // no missing (unfetchable proof) and no extra (unaccounted bytes).
        let committed = Set(manifest.entryCIDs)
        guard committed.count == manifest.entryCIDs.count,
              !committed.contains(serialized.root),
              Set(serialized.entries.keys) == committed.union([serialized.root]) else {
            throw ChildEvidenceVolumeError.malformed
        }
        var proofEntries: [(cid: String, data: Data)] = []
        proofEntries.reserveCapacity(manifest.entryCIDs.count)
        for cid in manifest.entryCIDs {
            guard let data = serialized.entries[cid] else {
                throw ChildEvidenceVolumeError.malformed
            }
            proofEntries.append((cid, data))
        }
        let proof = ChildBlockProof(
            rootCID: manifest.rootCID,
            directoryPath: manifest.directoryPath,
            entries: proofEntries
        )
        // The header must commit to the proof's OWN canonical entry order, or a
        // relayer could reorder/relabel the manifest without changing the root.
        guard proof.entries.map(\.cid) == manifest.entryCIDs,
              proof.rootCID == manifest.rootCID,
              proof.directoryPath == manifest.directoryPath else {
            throw ChildEvidenceVolumeError.malformed
        }
        let totalBytes = serialized.entries.values.reduce(0) { $0 + $1.count }
        guard totalBytes <= Self.maximumArchiveBytes else {
            throw ChildEvidenceVolumeError.oversized
        }
        // The flat envelope is derived in memory for the local validation path
        // (it never travels as one frame — the DAG above is the transport).
        let envelope = try ChildValidationPackageEnvelope(proof: proof)
        self.serialized = serialized
        self.proof = proof
        self.envelopeBytes = try envelope.encode()
    }

    func store(storer: any VolumeStorer) async throws {
        try await storer.store(volume: serialized)
    }
}
