import Foundation

enum ChildAcquisitionPackageError: Error, Equatable, Sendable {
    case malformed
    case oversized
}

/// Bounded content retained with a contextual child candidate. The package is
/// availability metadata; Lattice and cashew still validate every accessed CID.
struct ChildAcquisitionPackage: Sendable {
    static let maximumEntries = Int(UInt16.max)
    static let maximumBytes = ChainServiceLimits.maximumPayloadBytes

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

}
