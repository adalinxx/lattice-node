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
    let parentCarrierCertificate: ParentCarrierCertificateV1?
    let parentGenesisCertificate: ParentGenesisCertificateV1?
    let parentStateContinuityCertificate: ParentStateContinuityCertificateV1?

    init(
        package: ChildValidationPackage,
        parentCarrierCertificate: ParentCarrierCertificateV1? = nil,
        parentGenesisCertificate: ParentGenesisCertificateV1? = nil,
        parentStateContinuityCertificate: ParentStateContinuityCertificateV1? = nil
    ) {
        self.package = package
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
        self.parentStateContinuityCertificate = parentStateContinuityCertificate
    }
}

/// Deterministic, bounded transport for cross-chain evidence. Consensus proof
/// meaning remains in Lattice; this type only frames canonical proof bytes and
/// the authenticated parent facts that accompany them.
public struct ChildValidationPackageEnvelope: Sendable {
    // Leave room for Ivy framing.
    public static let maximumEncodedSize = Int(IvyConfig.protocolMaxFrameSize)
        - 1024

    private static let magic = Data("LNCPKG04".utf8)

    public let proofBytes: Data
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLink: ParentGenesisLink?
    public let parentStateContinuityLink: ParentStateContinuityLink?
    public let parentCarrierCertificate: ParentCarrierCertificateV1?
    public let parentGenesisCertificate: ParentGenesisCertificateV1?
    public let parentStateContinuityCertificate: ParentStateContinuityCertificateV1?

    public init(_ package: ChildValidationPackage) throws {
        proofBytes = try package.proof.serialize()
        parentCarrierLink = package.parentCarrierLink
        parentGenesisLink = package.parentGenesisLink
        parentStateContinuityLink = package.parentStateContinuityLink
        parentCarrierCertificate = nil
        parentGenesisCertificate = nil
        parentStateContinuityCertificate = nil
        try validateCanonicalContents()
    }

    /// Canonical proof-only Volume payload. Parent-issued state and genesis
    /// facts are separate authenticated inputs.
    public init(proof: ChildBlockProof) throws {
        try self.init(ChildValidationPackage(proof: proof))
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
        parentStateContinuityLink = package.parentStateContinuityLink
        parentCarrierCertificate = try package.parentCarrierLink.map {
            try ParentCarrierCertificateV1(link: $0, signedBy: configuration)
        }
        parentGenesisCertificate = try package.parentGenesisLink.map {
            try ParentGenesisCertificateV1(link: $0, signedBy: configuration)
        }
        parentStateContinuityCertificate =
            try package.parentStateContinuityLink.map {
                try ParentStateContinuityCertificateV1(
                    link: $0,
                    signedBy: configuration
                )
            }
        try validateCanonicalContents()
    }

    init(
        _ package: ChildValidationPackage,
        parentCarrierCertificate: ParentCarrierCertificateV1?,
        parentGenesisCertificate: ParentGenesisCertificateV1?,
        parentStateContinuityCertificate: ParentStateContinuityCertificateV1? = nil
    ) throws {
        proofBytes = try package.proof.serialize()
        parentCarrierLink = package.parentCarrierLink
        parentGenesisLink = package.parentGenesisLink
        parentStateContinuityLink = package.parentStateContinuityLink
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
        self.parentStateContinuityCertificate = parentStateContinuityCertificate
        try validateCanonicalContents()
    }

    private init(
        proofBytes: Data,
        parentCarrierLink: ParentCarrierLink?,
        parentGenesisLink: ParentGenesisLink?,
        parentStateContinuityLink: ParentStateContinuityLink?,
        parentCarrierCertificate: ParentCarrierCertificateV1?,
        parentGenesisCertificate: ParentGenesisCertificateV1?,
        parentStateContinuityCertificate: ParentStateContinuityCertificateV1?
    ) throws {
        self.proofBytes = proofBytes
        self.parentCarrierLink = parentCarrierLink
        self.parentGenesisLink = parentGenesisLink
        self.parentStateContinuityLink = parentStateContinuityLink
        self.parentCarrierCertificate = parentCarrierCertificate
        self.parentGenesisCertificate = parentGenesisCertificate
        self.parentStateContinuityCertificate = parentStateContinuityCertificate
        try validateCanonicalContents()
    }

    public func encode() throws -> Data {
        try validateCanonicalContents()
        let carrierBytes = try _canonicalJSONEncode(parentCarrierLink)
        let genesisBytes = try _canonicalJSONEncode(parentGenesisLink)
        let continuityBytes = try _canonicalJSONEncode(parentStateContinuityLink)
        let carrierCertificateBytes = try parentCarrierCertificate?.encode() ?? Data()
        let genesisCertificateBytes = try parentGenesisCertificate?.encode() ?? Data()
        let continuityCertificateBytes =
            try parentStateContinuityCertificate?.encode() ?? Data()
        guard proofBytes.count <= Int(UInt32.max),
              carrierBytes.count <= Int(UInt32.max),
              genesisBytes.count <= Int(UInt32.max),
              continuityBytes.count <= Int(UInt32.max),
              carrierCertificateBytes.count <= Int(UInt32.max),
              genesisCertificateBytes.count <= Int(UInt32.max),
              continuityCertificateBytes.count <= Int(UInt32.max) else {
            throw ChildValidationPackageEnvelopeError.oversized
        }

        var data = Data(
            capacity: 36 + proofBytes.count + carrierBytes.count + genesisBytes.count
                + continuityBytes.count + carrierCertificateBytes.count
                + genesisCertificateBytes.count + continuityCertificateBytes.count
        )
        data.append(Self.magic)
        _appendUInt32(UInt32(proofBytes.count), to: &data)
        data.append(proofBytes)
        _appendUInt32(UInt32(carrierBytes.count), to: &data)
        data.append(carrierBytes)
        _appendUInt32(UInt32(genesisBytes.count), to: &data)
        data.append(genesisBytes)
        _appendUInt32(UInt32(continuityBytes.count), to: &data)
        data.append(continuityBytes)
        _appendUInt32(UInt32(carrierCertificateBytes.count), to: &data)
        data.append(carrierCertificateBytes)
        _appendUInt32(UInt32(genesisCertificateBytes.count), to: &data)
        data.append(genesisCertificateBytes)
        _appendUInt32(UInt32(continuityCertificateBytes.count), to: &data)
        data.append(continuityCertificateBytes)
        guard data.count <= Self.maximumEncodedSize else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        return data
    }

    public static func decode(
        _ data: Data,
        maximumEncodedSize localMaximumEncodedSize: Int = maximumEncodedSize
    ) throws -> ChildValidationPackageEnvelope {
        guard localMaximumEncodedSize > 0,
              data.count <= min(maximumEncodedSize, localMaximumEncodedSize) else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        guard data.count >= magic.count + 28, data.prefix(magic.count) == magic else {
            throw ChildValidationPackageEnvelopeError.malformed
        }

        var position = data.index(data.startIndex, offsetBy: magic.count)
        guard let proofBytes = _readLengthPrefixedBytes(data, position: &position),
              let carrierBytes = _readLengthPrefixedBytes(data, position: &position),
              let genesisBytes = _readLengthPrefixedBytes(data, position: &position),
              let continuityBytes = _readLengthPrefixedBytes(
                data,
                position: &position
              ),
              let carrierCertificateBytes = _readLengthPrefixedBytes(
                data,
                position: &position
              ),
              let genesisCertificateBytes = _readLengthPrefixedBytes(
                data,
                position: &position
              ),
              let continuityCertificateBytes = _readLengthPrefixedBytes(
                data,
                position: &position
              ),
              position == data.endIndex else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        let carrier: ParentCarrierLink?
        let genesis: ParentGenesisLink?
        let continuity: ParentStateContinuityLink?
        do {
            carrier = try JSONDecoder().decode(ParentCarrierLink?.self, from: carrierBytes)
            genesis = try JSONDecoder().decode(ParentGenesisLink?.self, from: genesisBytes)
            continuity = try JSONDecoder().decode(
                ParentStateContinuityLink?.self,
                from: continuityBytes
            )
        } catch {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        guard (try? _canonicalJSONEncode(carrier)) == carrierBytes,
              (try? _canonicalJSONEncode(genesis)) == genesisBytes,
              (try? _canonicalJSONEncode(continuity)) == continuityBytes else {
            throw ChildValidationPackageEnvelopeError.nonCanonical
        }

        let carrierCertificate: ParentCarrierCertificateV1?
        let genesisCertificate: ParentGenesisCertificateV1?
        let continuityCertificate: ParentStateContinuityCertificateV1?
        do {
            carrierCertificate = carrierCertificateBytes.isEmpty
                ? nil
                : try ParentCarrierCertificateV1.decode(carrierCertificateBytes)
            genesisCertificate = genesisCertificateBytes.isEmpty
                ? nil
                : try ParentGenesisCertificateV1.decode(genesisCertificateBytes)
            continuityCertificate = continuityCertificateBytes.isEmpty
                ? nil
                : try ParentStateContinuityCertificateV1.decode(
                    continuityCertificateBytes
                )
        } catch {
            throw ChildValidationPackageEnvelopeError.malformed
        }

        let envelope = try ChildValidationPackageEnvelope(
            proofBytes: proofBytes,
            parentCarrierLink: carrier,
            parentGenesisLink: genesis,
            parentStateContinuityLink: continuity,
            parentCarrierCertificate: carrierCertificate,
            parentGenesisCertificate: genesisCertificate,
            parentStateContinuityCertificate: continuityCertificate
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
            parentGenesisLink: parentGenesisLink,
            parentStateContinuityLink: parentStateContinuityLink
        )
    }

    private func validateCanonicalContents() throws {
        guard !proofBytes.isEmpty,
              proofBytes.count < Self.maximumEncodedSize,
              let proof = ChildBlockProof.deserialize(proofBytes),
              (try? proof.serialize()) == proofBytes,
              _isBoundedWireAtom(proof.rootCID),
              proof.directoryPath.allSatisfy(StateAtomLimits.isDirectory),
              parentCarrierLink.map({
                  _isAbsoluteChainPath($0.parentPath)
                      && _isBoundedWireAtom($0.carrierCID)
                      && _isBoundedWireAtom($0.rootCID)
              }) ?? true,
              parentGenesisLink.map({
                  _isAbsoluteChainPath($0.parentPath)
                      && StateAtomLimits.isDirectory($0.directory)
                      && _isBoundedWireAtom($0.childGenesisCID)
              }) ?? true,
              parentStateContinuityLink.map({
                  _isAbsoluteChainPath($0.parentPath)
                      && _isBoundedWireAtom($0.fromStateCID)
                      && _isBoundedWireAtom($0.toStateCID)
              }) ?? true,
              parentCarrierCertificate == nil
                || parentCarrierLink?.rootCID == proof.rootCID,
              parentGenesisCertificate == nil || parentGenesisLink != nil,
              parentStateContinuityCertificate == nil
                || parentStateContinuityLink != nil else {
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
              envelope.parentGenesisLink.map({ $0.parentPath == parentPath }) ?? true,
              envelope.parentStateContinuityLink.map({
                  $0.parentPath == parentPath
              }) ?? true else {
            throw AuthenticatedParentFactGateError.wrongParentPath
        }
        let authority = ParentProcessKey(configuredParentIvyPeerKey)!
        try verifyCertificates(
            in: envelope,
            authorityKey: authority,
            requirePortable: false
        )
        return AuthenticatedChildPackage(
            package: try envelope.makeValidationPackage(),
            parentCarrierCertificate: envelope.parentCarrierCertificate,
            parentGenesisCertificate: envelope.parentGenesisCertificate,
            parentStateContinuityCertificate:
                envelope.parentStateContinuityCertificate
        )
    }

    /// Admit proof material relayed by an untrusted same-chain peer. The
    /// caller supplies the authority already committed by this child genesis;
    /// the relaying peer itself receives no parent-fact authority.
    public func acceptPortable(
        _ envelope: ChildValidationPackageEnvelope,
        durableParentProcessKey: ParentProcessKey
    ) throws -> AuthenticatedChildPackage {
        guard durableParentProcessKey.value == configuredParentIvyPeerKey else {
            throw AuthenticatedParentFactGateError.wrongParentAuthority
        }
        let parentPath = Array(childPath.dropLast())
        guard envelope.parentCarrierLink.map({ $0.parentPath == parentPath }) ?? true,
              envelope.parentGenesisLink.map({ $0.parentPath == parentPath }) ?? true,
              envelope.parentStateContinuityLink.map({
                  $0.parentPath == parentPath
              }) ?? true else {
            throw AuthenticatedParentFactGateError.wrongParentPath
        }
        try verifyCertificates(
            in: envelope,
            authorityKey: durableParentProcessKey,
            requirePortable: true
        )
        return AuthenticatedChildPackage(
            package: try envelope.makeValidationPackage(),
            parentCarrierCertificate: envelope.parentCarrierCertificate,
            parentGenesisCertificate: envelope.parentGenesisCertificate,
            parentStateContinuityCertificate:
                envelope.parentStateContinuityCertificate
        )
    }

    private func verifyCertificates(
        in envelope: ChildValidationPackageEnvelope,
        authorityKey: ParentProcessKey,
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
        if let link = envelope.parentStateContinuityLink {
            if let certificate = envelope.parentStateContinuityCertificate {
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
