import Foundation
import Lattice
import VolumeBroker
import cashew

enum ChildEvidenceVolumeError: Error, Equatable, Sendable {
    case malformed
    case oversized
}

/// One complete evidence Volume. Its manifest commits the exact acquisition
/// membership while each acquisition byte remains stored under its original CID.
struct ChildEvidenceVolume: Sendable {
    private struct Manifest: Scalar {
        let childCID: String
        let envelope: Data
        let memberCIDs: [String]
    }

    private static let maximumFramedBytes =
        ChildValidationPackageEnvelope.maximumEncodedSize
        + ChildAcquisitionPackage.maximumBytes
        + 1024

    let serialized: SerializedVolume
    let envelopeBytes: Data
    let acquisitionEntries: [String: Data]

    var rawCID: String { serialized.root }

    init(
        envelopeBytes: Data,
        acquisitionEntries: [String: Data],
        childCID: String
    ) throws {
        guard !envelopeBytes.isEmpty,
              let childData = acquisitionEntries[childCID] else {
            throw ChildEvidenceVolumeError.malformed
        }
        _ = try ChildAcquisitionPackage(
            entries: acquisitionEntries,
            childCID: childCID,
            childData: childData,
            maximumBytes: ChildAcquisitionPackage.maximumBytes
        )
        let manifest = Manifest(
            childCID: childCID,
            envelope: envelopeBytes,
            memberCIDs: acquisitionEntries.keys.sorted()
        )
        let header = try VolumeImpl<Manifest>(node: manifest)
        let rootData = try header.mapToData()
        guard acquisitionEntries[header.rawCID] == nil else {
            throw ChildEvidenceVolumeError.malformed
        }
        var entries = acquisitionEntries
        entries[header.rawCID] = rootData
        try self.init(
            serialized: SerializedVolume(root: header.rawCID, entries: entries),
            childCID: childCID
        )
    }

    init(serialized: SerializedVolume, childCID: String? = nil) throws {
        try serialized.validate()
        guard let rootData = serialized.entries[serialized.root],
              let manifest = Manifest(data: rootData),
              !manifest.childCID.isEmpty,
              !manifest.envelope.isEmpty,
              manifest.memberCIDs == manifest.memberCIDs.sorted(),
              Set(manifest.memberCIDs).count == manifest.memberCIDs.count,
              manifest.memberCIDs.contains(manifest.childCID),
              !manifest.memberCIDs.contains(serialized.root),
              Set(serialized.entries.keys)
                == Set(manifest.memberCIDs).union([serialized.root]) else {
            throw ChildEvidenceVolumeError.malformed
        }
        let canonicalRoot = try VolumeImpl<Manifest>(node: manifest)
        guard canonicalRoot.rawCID == serialized.root,
              try canonicalRoot.mapToData() == rootData else {
            throw ChildEvidenceVolumeError.malformed
        }
        let acquisitionEntries = serialized.entries.filter {
            $0.key != serialized.root
        }
        guard childCID.map({ $0 == manifest.childCID }) ?? true,
              let packageRootData = acquisitionEntries[manifest.childCID],
              let child = Block(data: packageRootData),
              child.toData() == packageRootData,
              try BlockHeader(node: child).rawCID == manifest.childCID else {
            throw ChildEvidenceVolumeError.malformed
        }
        let package = try ChildAcquisitionPackage(
            entries: acquisitionEntries,
            childCID: manifest.childCID,
            childData: packageRootData,
            maximumBytes: ChildAcquisitionPackage.maximumBytes
        )
        let rootFramedBytes = 6 + serialized.root.utf8.count + rootData.count
        let framed = package.framedByteCount.addingReportingOverflow(
            rootFramedBytes
        )
        guard !framed.overflow,
              framed.partialValue <= Self.maximumFramedBytes else {
            throw ChildEvidenceVolumeError.oversized
        }
        self.serialized = serialized
        envelopeBytes = manifest.envelope
        self.acquisitionEntries = acquisitionEntries
    }

    func store(storer: any VolumeStorer) async throws {
        try await storer.store(volume: serialized)
    }
}
