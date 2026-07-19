import Foundation
import Ivy
import Lattice

public enum ChildValidationPackageEnvelopeError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case nonCanonical
}

/// Proof and parent facts admitted through the pinned immediate-parent session.
/// No other ingress can construct this value.
public struct AuthenticatedChildPackage: Sendable {
    let package: ChildValidationPackage
    let acquisitionEntries: [String: Data]

    init(
        package: ChildValidationPackage,
        acquisitionEntries: [String: Data] = [:]
    ) {
        self.package = package
        self.acquisitionEntries = acquisitionEntries
    }
}

/// Deterministic, bounded transport for cross-chain evidence. Consensus proof
/// meaning remains in Lattice; this type only frames canonical proof bytes and
/// the authenticated parent facts that accompany them.
public struct ChildValidationPackageEnvelope: Sendable {
    // Leave room for the retained availability package and Ivy framing.
    public static let maximumEncodedSize = Int(IvyConfig.protocolMaxFrameSize)
        - ChildAcquisitionPackage.maximumBytes - 1024

    private static let magic = Data("LNCPKG02".utf8)

    public let proofBytes: Data
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLink: ParentGenesisLink?

    public init(_ package: ChildValidationPackage) throws {
        proofBytes = try package.proof.serialize()
        parentCarrierLink = package.parentCarrierLink
        parentGenesisLink = package.parentGenesisLink
        try validateCanonicalContents()
    }

    private init(
        proofBytes: Data,
        parentCarrierLink: ParentCarrierLink?,
        parentGenesisLink: ParentGenesisLink?
    ) throws {
        self.proofBytes = proofBytes
        self.parentCarrierLink = parentCarrierLink
        self.parentGenesisLink = parentGenesisLink
        try validateCanonicalContents()
    }

    public func encode() throws -> Data {
        try validateCanonicalContents()
        let carrierBytes = try _canonicalJSONEncode(parentCarrierLink)
        let genesisBytes = try _canonicalJSONEncode(parentGenesisLink)
        guard proofBytes.count <= Int(UInt32.max),
              carrierBytes.count <= Int(UInt32.max),
              genesisBytes.count <= Int(UInt32.max) else {
            throw ChildValidationPackageEnvelopeError.oversized
        }

        var data = Data(capacity: 20 + proofBytes.count + carrierBytes.count + genesisBytes.count)
        data.append(Self.magic)
        _appendUInt32(UInt32(proofBytes.count), to: &data)
        data.append(proofBytes)
        _appendUInt32(UInt32(carrierBytes.count), to: &data)
        data.append(carrierBytes)
        _appendUInt32(UInt32(genesisBytes.count), to: &data)
        data.append(genesisBytes)
        guard data.count <= Self.maximumEncodedSize else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ChildValidationPackageEnvelope {
        guard data.count <= maximumEncodedSize else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        guard data.count >= magic.count + 12, data.prefix(magic.count) == magic else {
            throw ChildValidationPackageEnvelopeError.malformed
        }

        var position = data.index(data.startIndex, offsetBy: magic.count)
        guard let proofBytes = _readLengthPrefixedBytes(data, position: &position),
              let carrierBytes = _readLengthPrefixedBytes(data, position: &position),
              let genesisBytes = _readLengthPrefixedBytes(data, position: &position),
              position == data.endIndex else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        let carrier: ParentCarrierLink?
        let genesis: ParentGenesisLink?
        do {
            carrier = try JSONDecoder().decode(ParentCarrierLink?.self, from: carrierBytes)
            genesis = try JSONDecoder().decode(ParentGenesisLink?.self, from: genesisBytes)
        } catch {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        guard (try? _canonicalJSONEncode(carrier)) == carrierBytes,
              (try? _canonicalJSONEncode(genesis)) == genesisBytes else {
            throw ChildValidationPackageEnvelopeError.nonCanonical
        }

        let envelope = try ChildValidationPackageEnvelope(
            proofBytes: proofBytes,
            parentCarrierLink: carrier,
            parentGenesisLink: genesis
        )
        guard try envelope.encode() == data else {
            throw ChildValidationPackageEnvelopeError.nonCanonical
        }
        return envelope
    }

    func makeValidationPackage() throws -> ChildValidationPackage {
        guard let proof = ChildBlockProof.deserialize(proofBytes) else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        return ChildValidationPackage(
            proof: proof,
            parentCarrierLink: parentCarrierLink,
            parentGenesisLink: parentGenesisLink
        )
    }

    private func validateCanonicalContents() throws {
        guard !proofBytes.isEmpty,
              proofBytes.count < Self.maximumEncodedSize,
              let proof = ChildBlockProof.deserialize(proofBytes),
              (try? proof.serialize()) == proofBytes,
              _isBoundedWireAtom(proof.rootCID),
              proof.directoryPath.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= Int(UInt16.max)
              }),
              parentCarrierLink.map({
                  _isAbsoluteChainPath($0.parentPath)
                      && _isBoundedWireAtom($0.carrierCID)
                      && _isBoundedWireAtom($0.rootCID)
              }) ?? true,
              parentGenesisLink.map({
                  _isAbsoluteChainPath($0.parentPath)
                      && !$0.directory.isEmpty
                      && $0.directory.utf8.count <= Int(UInt16.max)
                      && _isBoundedWireAtom($0.childGenesisCID)
              }) ?? true else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
    }
}

public enum AuthenticatedParentFactGateError: Error, Equatable, Sendable {
    case malformedChildPath
    case malformedConfiguredPeer
    case unauthenticatedParent
    case wrongParentPath
}

/// The only admission point for parent-issued facts. Ivy authenticates the
/// session; this gate grants fact authority only to the configured immediate
/// parent on a direct pinned connection.
public struct AuthenticatedParentFactGate: Sendable {
    public let childPath: [String]
    public let configuredParentIvyPeerKey: String

    public init(
        childPath: [String],
        configuredParentIvyPeerKey: String
    ) throws {
        guard _isAbsoluteChainPath(childPath), childPath.count > 1 else {
            throw AuthenticatedParentFactGateError.malformedChildPath
        }
        guard let parent = try? PeerKey(configuredParentIvyPeerKey) else {
            throw AuthenticatedParentFactGateError.malformedConfiguredPeer
        }
        self.childPath = childPath
        self.configuredParentIvyPeerKey = parent.hex
    }

    public func accept(
        _ envelope: ChildValidationPackageEnvelope,
        from authenticatedPeer: AuthenticatedPeer
    ) throws -> AuthenticatedChildPackage {
        guard authenticatedPeer.role == .endpoint,
              authenticatedPeer.route == .direct,
              authenticatedPeer.key.hex == configuredParentIvyPeerKey else {
            throw AuthenticatedParentFactGateError.unauthenticatedParent
        }
        let parentPath = Array(childPath.dropLast())
        guard envelope.parentCarrierLink.map({ $0.parentPath == parentPath }) ?? true,
              envelope.parentGenesisLink.map({ $0.parentPath == parentPath }) ?? true else {
            throw AuthenticatedParentFactGateError.wrongParentPath
        }
        return AuthenticatedChildPackage(
            package: try envelope.makeValidationPackage(),
            acquisitionEntries: [:]
        )
    }
}

private func _appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8(value >> 24))
}

private func _readLengthPrefixedBytes(
    _ data: Data,
    position: inout Data.Index
) -> Data? {
    guard data.distance(from: position, to: data.endIndex) >= 4 else { return nil }
    let length = Int(data[position])
        | (Int(data[data.index(position, offsetBy: 1)]) << 8)
        | (Int(data[data.index(position, offsetBy: 2)]) << 16)
        | (Int(data[data.index(position, offsetBy: 3)]) << 24)
    position = data.index(position, offsetBy: 4)
    guard data.distance(from: position, to: data.endIndex) >= length else { return nil }
    let end = data.index(position, offsetBy: length)
    let bytes = Data(data[position..<end])
    position = end
    return bytes
}
