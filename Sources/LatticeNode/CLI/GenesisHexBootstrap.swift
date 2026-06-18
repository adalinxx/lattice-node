import Foundation
import LatticeNodeRPCFuzzSupport

/// Size-bounded decoder for the `--genesis-hex` per-process bootstrap blob.
///
/// Wire format: `[numEntries:2LE][cidLen:2LE][cid][dataLen:4LE][data]...`
///
/// This is the single choke point where untrusted genesis-hex input is turned
/// into CAS entries. It fails CLOSED on oversized input — an unbounded blob (or
/// one whose declared entry count / length fields are hostile) would otherwise
/// force an arbitrarily large allocation and parse. The byte cap, hex-length
/// cap, and per-entry-count cap are all enforced before any large allocation.
enum GenesisHexBootstrap {
    /// A genesis payload is a genesis block + spec + a small number of genesis
    /// TX bodies, all well under 16 MiB.
    static let maxBytes = 16 * 1_048_576
    static var maxHexChars: Int { maxBytes * 2 }  // hex encodes 2 chars/byte
    static let maxEntries = 4_096

    enum ParseError: Error, Equatable {
        case tooLarge
        case malformed
    }

    /// Decode the hex string into ordered `(cid, data)` CAS entries, enforcing
    /// the size/count caps. The first entry is the genesis block; callers own all
    /// downstream block/spec validation.
    static func parse(hex: String) throws -> [(cid: String, data: Data)] {
        do {
            return try GenesisHexCodec.parseHexThrowing(
                hex,
                maxPayloadBytes: maxBytes,
                maxHexChars: maxHexChars,
                maxEntries: maxEntries
            ).map { ($0.cid, $0.data) }
        } catch GenesisHexCodec.ParseError.tooLarge {
            throw ParseError.tooLarge
        } catch {
            throw ParseError.malformed
        }
    }
}
