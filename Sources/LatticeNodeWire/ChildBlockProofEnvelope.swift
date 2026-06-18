import Foundation
import Lattice

/// Network/storage envelope for the complete set of PoW paths currently known for
/// one child block. The proof MEANING (validity, securing-work, anchors) is owned
/// by `Lattice.ChildBlockProof`; this is pure byte transport — how a *set* of
/// proofs travels over the wire.
///
/// Parser safety: `deserialize` is the ingress codec. It rejects malformed input
/// (bad magic, truncated frames, length fields exceeding the buffer), non-canonical
/// duplicates (dedup by `canonicalProofID`), and trailing garbage (`pos` must reach
/// `endIndex`) BEFORE any returned proof undergoes semantic verification.
public enum ChildBlockProofEnvelope {
    private static let magic = Data([0x4C, 0x4E, 0x50, 0x46, 0x53, 0x45, 0x54, 0x31]) // LNPFSET1

    public static func serialize(_ proofs: [ChildBlockProof]) -> Data {
        var deduped: [ChildBlockProof] = []
        var seen = Set<String>()
        let canonicalProofs = proofs.map(\.canonicalized).sorted {
            $0.canonicalProofID < $1.canonicalProofID
        }
        for proof in canonicalProofs where seen.insert(proof.canonicalProofID).inserted {
            deduped.append(proof)
        }

        var out = Data()
        out.append(magic)
        writeU16(&out, UInt16(deduped.count))
        for proof in deduped {
            let bytes = proof.serialize()
            writeU32(&out, UInt32(bytes.count))
            out.append(bytes)
        }
        return out
    }

    public static func deserialize(_ data: Data) -> [ChildBlockProof]? {
        guard data.count >= magic.count + 2,
              data.prefix(magic.count) == magic else { return nil }
        var pos = data.index(data.startIndex, offsetBy: magic.count)
        guard let count = readU16(data, &pos) else { return nil }
        var proofs: [ChildBlockProof] = []
        var seen = Set<String>()
        for _ in 0..<Int(count) {
            guard let len = readU32(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(len) else { return nil }
            let proofData = Data(data[pos..<data.index(pos, offsetBy: Int(len))])
            guard let proof = ChildBlockProof.deserialize(proofData) else { return nil }
            let canonical = proof.canonicalized
            if seen.insert(canonical.canonicalProofID).inserted {
                proofs.append(canonical)
            }
            pos = data.index(pos, offsetBy: Int(len))
        }
        guard pos == data.endIndex, !proofs.isEmpty else { return nil }
        return proofs.sorted { $0.canonicalProofID < $1.canonicalProofID }
    }
}

// MARK: - Envelope byte helpers

private func writeU16(_ out: inout Data, _ v: UInt16) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
}
private func writeU32(_ out: inout Data, _ v: UInt32) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
}
private func readU16(_ data: Data, _ pos: inout Data.Index) -> UInt16? {
    guard data.distance(from: pos, to: data.endIndex) >= 2 else { return nil }
    let v = UInt16(data[pos]) | (UInt16(data[data.index(after: pos)]) << 8)
    pos = data.index(pos, offsetBy: 2); return v
}
private func readU32(_ data: Data, _ pos: inout Data.Index) -> UInt32? {
    guard data.distance(from: pos, to: data.endIndex) >= 4 else { return nil }
    let v = UInt32(data[pos]) | (UInt32(data[data.index(pos, offsetBy: 1)]) << 8)
              | (UInt32(data[data.index(pos, offsetBy: 2)]) << 16)
              | (UInt32(data[data.index(pos, offsetBy: 3)]) << 24)
    pos = data.index(pos, offsetBy: 4); return v
}
