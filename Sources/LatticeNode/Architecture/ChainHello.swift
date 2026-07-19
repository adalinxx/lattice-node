import Foundation

public enum ChainHelloError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case incompatibleProtocol
    case wrongNexusGenesis
    case wrongChainPath
    case wrongMinimumRootWork
}

/// Authenticated application handshake for both the same-chain overlay and a
/// pinned parent link. Synchronization state is advertised separately because
/// competing roots on one child path remain ordinary fork-choice candidates.
public struct ChainHello: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1
    public static let maximumEncodedSize = 64 * 1024

    public let version: UInt16
    public let nexusGenesisCID: String
    public let chainPath: [String]
    public let minimumRootWorkHex: String

    public init(
        nexusGenesisCID: String,
        chainPath: [String],
        minimumRootWorkHex: String
    ) {
        version = Self.protocolVersion
        self.nexusGenesisCID = nexusGenesisCID
        self.chainPath = chainPath
        self.minimumRootWorkHex = minimumRootWorkHex
    }

    public func encode() throws -> Data {
        try validateShape()
        let data = try _canonicalJSONEncode(self)
        guard data.count <= Self.maximumEncodedSize else {
            throw ChainHelloError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ChainHello {
        guard data.count <= Self.maximumEncodedSize else {
            throw ChainHelloError.oversized
        }
        guard let hello = try? JSONDecoder().decode(ChainHello.self, from: data) else {
            throw ChainHelloError.malformed
        }
        try hello.validateShape()
        return hello
    }

    /// Ivy authenticates the peer key. This handshake only establishes that an
    /// authenticated peer speaks for the same chain setup; it grants no fact
    /// authority.
    public func validateCompatibility(
        expectedNexusGenesisCID: String,
        expectedChainPath: [String],
        expectedMinimumRootWorkHex: String
    ) throws {
        try validateShape()
        guard version == Self.protocolVersion else {
            throw ChainHelloError.incompatibleProtocol
        }
        guard nexusGenesisCID == expectedNexusGenesisCID else {
            throw ChainHelloError.wrongNexusGenesis
        }
        guard chainPath == expectedChainPath else {
            throw ChainHelloError.wrongChainPath
        }
        guard minimumRootWorkHex == expectedMinimumRootWorkHex else {
            throw ChainHelloError.wrongMinimumRootWork
        }
    }

    private func validateShape() throws {
        guard _isBoundedWireAtom(nexusGenesisCID),
              _isAbsoluteChainPath(chainPath),
              _isCanonicalWorkHex(minimumRootWorkHex) else {
            throw ChainHelloError.malformed
        }
    }
}

func _isAbsoluteChainPath(_ path: [String]) -> Bool {
    ChainAddress(path) != nil
}

func _isBoundedWireAtom(_ value: String, maximumBytes: Int = 128) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= maximumBytes
        && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

private func _isCanonicalWorkHex(_ value: String) -> Bool {
    value.utf8.count == 64
        && value != String(repeating: "0", count: 64)
        && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
}

func _canonicalJSONEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
