import Foundation

enum ChildAcquisitionPackageError: Error, Equatable, Sendable {
    case malformed
    case oversized
    case nonCanonical
}

/// Bounded content retained with a contextual child candidate. The package is
/// availability metadata; Lattice and cashew still validate every accessed CID.
struct ChildAcquisitionPackage: Sendable {
    static let maximumEntries = Int(UInt16.max)
    static let maximumBytes = ChainServiceLimits.maximumPayloadBytes

    private struct Entry: Codable {
        let cid: String
        let data: Data
    }

    let entries: [String: Data]
    let framedByteCount: Int

    init(
        entries: [String: Data],
        childCID: String,
        childData: Data,
        maximumBytes: Int
    ) throws {
        guard maximumBytes > 0,
              entries.count <= Self.maximumEntries,
              entries[childCID] == childData else {
            throw ChildAcquisitionPackageError.malformed
        }
        var byteCount = 0
        for (cid, data) in entries {
            guard _isBoundedWireAtom(cid), !data.isEmpty,
                  data.count <= Int(UInt32.max) else {
                throw ChildAcquisitionPackageError.malformed
            }
            let framed = 6 + cid.utf8.count + data.count
            let next = byteCount.addingReportingOverflow(framed)
            guard !next.overflow, next.partialValue <= maximumBytes else {
                throw ChildAcquisitionPackageError.oversized
            }
            byteCount = next.partialValue
        }
        self.entries = entries
        framedByteCount = byteCount
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries.sorted { $0.key < $1.key }.map {
            Entry(cid: $0.key, data: $0.value)
        })
    }

    static func decoded(
        _ data: Data,
        childCID: String,
        childData: Data,
        maximumBytes: Int
    ) throws -> Self {
        guard let values = try? JSONDecoder().decode([Entry].self, from: data),
              values.map(\.cid) == values.map(\.cid).sorted(),
              Set(values.map(\.cid)).count == values.count else {
            throw ChildAcquisitionPackageError.malformed
        }
        let package = try Self(
            entries: Dictionary(uniqueKeysWithValues: values.map { ($0.cid, $0.data) }),
            childCID: childCID,
            childData: childData,
            maximumBytes: maximumBytes
        )
        guard try package.encoded() == data else {
            throw ChildAcquisitionPackageError.nonCanonical
        }
        return package
    }
}
