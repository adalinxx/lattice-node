import Foundation
import Ivy
import Lattice

public enum ChildValidationPackageEnvelopeError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case nonCanonical
}

/// Proof and parent facts admitted after either a pinned live session or
/// portable parent-certificate verification.
public struct AuthenticatedChildPackage: Sendable {
    let package: ChildValidationPackage
    let acquisitionEntries: [String: Data]
    let parentCarrierCertificate: ParentCarrierCertificateV1?
    let parentGenesisCertificate: ParentGenesisCertificateV1?

    init(
        package: ChildValidationPackage,
        acquisitionEntries: [String: Data] = [:],
        parentCarrierCertificate: ParentCarrierCertificateV1? = nil,
        parentGenesisCertificate: ParentGenesisCertificateV1? = nil
    ) {
        self.package = package
        self.acquisitionEntries = acquisitionEntries
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
    }
}

/// Deterministic, bounded transport for cross-chain evidence. Consensus proof
/// meaning remains in Lattice; this type only frames canonical proof bytes and
/// the authenticated parent facts that accompany them.
public struct ChildValidationPackageEnvelope: Sendable {
    // Leave room for the retained availability package and Ivy framing.
    public static let maximumEncodedSize = Int(IvyConfig.protocolMaxFrameSize)
        - ChildAcquisitionPackage.maximumBytes - 1024

    private static let magic = Data("LNCPKG03".utf8)

    public let proofBytes: Data
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLink: ParentGenesisLink?
    public let parentCarrierCertificate: ParentCarrierCertificateV1?
    public let parentGenesisCertificate: ParentGenesisCertificateV1?

    public init(_ package: ChildValidationPackage) throws {
        proofBytes = try package.proof.serialize()
        parentCarrierLink = package.parentCarrierLink
        parentGenesisLink = package.parentGenesisLink
        parentCarrierCertificate = nil
        parentGenesisCertificate = nil
        try validateCanonicalContents()
    }

    /// Build peer-portable root evidence. Signatures authenticate the parent
    /// facts only; Lattice still verifies the proof and derives work.
    public init(
        _ package: ChildValidationPackage,
        certificatesSignedBy configuration: NodeConfiguration
    ) throws {
        proofBytes = try package.proof.serialize()
        parentCarrierLink = package.parentCarrierLink
        parentGenesisLink = package.parentGenesisLink
        parentCarrierCertificate = try package.parentCarrierLink.map {
            try ParentCarrierCertificateV1(link: $0, signedBy: configuration)
        }
        parentGenesisCertificate = try package.parentGenesisLink.map {
            try ParentGenesisCertificateV1(link: $0, signedBy: configuration)
        }
        try validateCanonicalContents()
    }

    init(
        _ package: ChildValidationPackage,
        parentCarrierCertificate: ParentCarrierCertificateV1?,
        parentGenesisCertificate: ParentGenesisCertificateV1?
    ) throws {
        proofBytes = try package.proof.serialize()
        parentCarrierLink = package.parentCarrierLink
        parentGenesisLink = package.parentGenesisLink
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
        try validateCanonicalContents()
    }

    private init(
        proofBytes: Data,
        parentCarrierLink: ParentCarrierLink?,
        parentGenesisLink: ParentGenesisLink?,
        parentCarrierCertificate: ParentCarrierCertificateV1?,
        parentGenesisCertificate: ParentGenesisCertificateV1?
    ) throws {
        self.proofBytes = proofBytes
        self.parentCarrierLink = parentCarrierLink
        self.parentGenesisLink = parentGenesisLink
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
        try validateCanonicalContents()
    }

    public func encode() throws -> Data {
        try validateCanonicalContents()
        let carrierBytes = try _canonicalJSONEncode(parentCarrierLink)
        let genesisBytes = try _canonicalJSONEncode(parentGenesisLink)
        let carrierCertificateBytes = try parentCarrierCertificate?.encode() ?? Data()
        let genesisCertificateBytes = try parentGenesisCertificate?.encode() ?? Data()
        guard proofBytes.count <= Int(UInt32.max),
              carrierBytes.count <= Int(UInt32.max),
              genesisBytes.count <= Int(UInt32.max),
              carrierCertificateBytes.count <= Int(UInt32.max),
              genesisCertificateBytes.count <= Int(UInt32.max) else {
            throw ChildValidationPackageEnvelopeError.oversized
        }

        var data = Data(
            capacity: 28 + proofBytes.count + carrierBytes.count + genesisBytes.count
                + carrierCertificateBytes.count + genesisCertificateBytes.count
        )
        data.append(Self.magic)
        _appendUInt32(UInt32(proofBytes.count), to: &data)
        data.append(proofBytes)
        _appendUInt32(UInt32(carrierBytes.count), to: &data)
        data.append(carrierBytes)
        _appendUInt32(UInt32(genesisBytes.count), to: &data)
        data.append(genesisBytes)
        _appendUInt32(UInt32(carrierCertificateBytes.count), to: &data)
        data.append(carrierCertificateBytes)
        _appendUInt32(UInt32(genesisCertificateBytes.count), to: &data)
        data.append(genesisCertificateBytes)
        guard data.count <= Self.maximumEncodedSize else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ChildValidationPackageEnvelope {
        guard data.count <= maximumEncodedSize else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        guard data.count >= magic.count + 20, data.prefix(magic.count) == magic else {
            throw ChildValidationPackageEnvelopeError.malformed
        }

        var position = data.index(data.startIndex, offsetBy: magic.count)
        guard let proofBytes = _readLengthPrefixedBytes(data, position: &position),
              let carrierBytes = _readLengthPrefixedBytes(data, position: &position),
              let genesisBytes = _readLengthPrefixedBytes(data, position: &position),
              let carrierCertificateBytes = _readLengthPrefixedBytes(
                data,
                position: &position
              ),
              let genesisCertificateBytes = _readLengthPrefixedBytes(
                data,
                position: &position
              ),
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

        let carrierCertificate: ParentCarrierCertificateV1?
        let genesisCertificate: ParentGenesisCertificateV1?
        do {
            carrierCertificate = carrierCertificateBytes.isEmpty
                ? nil
                : try ParentCarrierCertificateV1.decode(carrierCertificateBytes)
            genesisCertificate = genesisCertificateBytes.isEmpty
                ? nil
                : try ParentGenesisCertificateV1.decode(genesisCertificateBytes)
        } catch {
            throw ChildValidationPackageEnvelopeError.malformed
        }

        let envelope = try ChildValidationPackageEnvelope(
            proofBytes: proofBytes,
            parentCarrierLink: carrier,
            parentGenesisLink: genesis,
            parentCarrierCertificate: carrierCertificate,
            parentGenesisCertificate: genesisCertificate
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
              }) ?? true,
              parentCarrierCertificate == nil
                || parentCarrierLink?.rootCID == proof.rootCID,
              parentGenesisCertificate == nil || parentGenesisLink != nil else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
    }
}

public enum AuthenticatedParentFactGateError: Error, Equatable, Sendable {
    case malformedChildPath
    case malformedConfiguredPeer
    case unauthenticatedParent
    case wrongParentPath
    case wrongParentAuthority
    case missingPortableCertificate
    case invalidCertificate
}

/// The only admission point for parent-issued facts. Ivy authenticates the
/// session; this gate grants fact authority only to the configured immediate
/// parent on a direct pinned connection.
public struct AuthenticatedParentFactGate: Sendable {
    public let childPath: [String]
    public let configuredParentIvyPeerKey: String
    public let nexusGenesisCID: String

    public init(
        childPath: [String],
        configuredParentIvyPeerKey: String,
        nexusGenesisCID: String = NexusGenesis.expectedBlockHash
    ) throws {
        guard _isAbsoluteChainPath(childPath), childPath.count > 1 else {
            throw AuthenticatedParentFactGateError.malformedChildPath
        }
        guard let parent = try? PeerKey(configuredParentIvyPeerKey),
              _isBoundedWireAtom(nexusGenesisCID),
              CIDIdentity.isCanonical(nexusGenesisCID) else {
            throw AuthenticatedParentFactGateError.malformedConfiguredPeer
        }
        self.childPath = childPath
        self.configuredParentIvyPeerKey = parent.hex
        self.nexusGenesisCID = nexusGenesisCID
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
        let authority = ParentWorkAuthorityKey(configuredParentIvyPeerKey)!
        try verifyCertificates(
            in: envelope,
            authorityKey: authority,
            requirePortable: false
        )
        return AuthenticatedChildPackage(
            package: try envelope.makeValidationPackage(),
            acquisitionEntries: [:],
            parentCarrierCertificate: envelope.parentCarrierCertificate,
            parentGenesisCertificate: envelope.parentGenesisCertificate
        )
    }

    /// Admit proof material relayed by an untrusted same-chain peer. The
    /// caller supplies the authority already committed by this child genesis;
    /// the relaying peer itself receives no parent-fact authority.
    public func acceptPortable(
        _ envelope: ChildValidationPackageEnvelope,
        durableParentWorkAuthorityKey: ParentWorkAuthorityKey
    ) throws -> AuthenticatedChildPackage {
        guard durableParentWorkAuthorityKey.value == configuredParentIvyPeerKey else {
            throw AuthenticatedParentFactGateError.wrongParentAuthority
        }
        let parentPath = Array(childPath.dropLast())
        guard envelope.parentCarrierLink.map({ $0.parentPath == parentPath }) ?? true,
              envelope.parentGenesisLink.map({ $0.parentPath == parentPath }) ?? true else {
            throw AuthenticatedParentFactGateError.wrongParentPath
        }
        try verifyCertificates(
            in: envelope,
            authorityKey: durableParentWorkAuthorityKey,
            requirePortable: true
        )
        return AuthenticatedChildPackage(
            package: try envelope.makeValidationPackage(),
            acquisitionEntries: [:],
            parentCarrierCertificate: envelope.parentCarrierCertificate,
            parentGenesisCertificate: envelope.parentGenesisCertificate
        )
    }

    private func verifyCertificates(
        in envelope: ChildValidationPackageEnvelope,
        authorityKey: ParentWorkAuthorityKey,
        requirePortable: Bool
    ) throws {
        let parentPath = Array(childPath.dropLast())
        if let link = envelope.parentCarrierLink {
            if let certificate = envelope.parentCarrierCertificate {
                guard certificate.verifies(
                    link: link,
                    authorityKey: authorityKey,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: parentPath
                ) else {
                    throw AuthenticatedParentFactGateError.invalidCertificate
                }
            } else if requirePortable {
                throw AuthenticatedParentFactGateError.missingPortableCertificate
            }
        }
        if let link = envelope.parentGenesisLink {
            if let certificate = envelope.parentGenesisCertificate {
                guard certificate.verifies(
                    link: link,
                    authorityKey: authorityKey,
                    expectedNexusGenesisCID: nexusGenesisCID,
                    expectedParentPath: parentPath
                ) else {
                    throw AuthenticatedParentFactGateError.invalidCertificate
                }
            } else if requirePortable {
                throw AuthenticatedParentFactGateError.missingPortableCertificate
            }
        }
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
