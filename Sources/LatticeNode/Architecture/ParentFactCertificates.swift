import Crypto
import Foundation
import Ivy
import Lattice

public enum ParentFactCertificateError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case wrongConfiguration
}

/// A portable signature over one root-bound carrier fact. The link remains in
/// the validation package; the certificate adds no second representation of it.
public struct ParentCarrierCertificateV1: Equatable, Sendable {
    public static let maximumEncodedSize = 64

    private static let domain = Data("lattice-node.parent-carrier.v1\0".utf8)

    public let signature: Data

    public init(
        link: ParentCarrierLink,
        signedBy configuration: NodeConfiguration
    ) throws {
        guard link.parentPath == configuration.chainPath else {
            throw ParentFactCertificateError.wrongConfiguration
        }
        signature = try configuration.signingKey.signature(
            for: Self.signedBytes(
                link: link,
                nexusGenesisCID: configuration.nexusGenesisCID
            )
        )
    }

    private init(signature: Data) {
        self.signature = signature
    }

    public func encode() throws -> Data {
        guard signature.count == Self.maximumEncodedSize else {
            throw ParentFactCertificateError.malformed
        }
        return signature
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedSize else {
            throw ParentFactCertificateError.oversized
        }
        guard data.count == maximumEncodedSize else {
            throw ParentFactCertificateError.malformed
        }
        return Self(signature: data)
    }

    public func verifies(
        link: ParentCarrierLink,
        authorityKey: ParentProcessKey,
        expectedNexusGenesisCID: String,
        expectedParentPath: [String]
    ) -> Bool {
        guard link.parentPath == expectedParentPath,
              let body = try? Self.signedBytes(
                link: link,
                nexusGenesisCID: expectedNexusGenesisCID
              ),
              let key = try? PeerKey(authorityKey.value),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: key.rawRepresentation
              ) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: body)
    }

    private static func signedBytes(
        link: ParentCarrierLink,
        nexusGenesisCID: String
    ) throws -> Data {
        guard _isBoundedWireAtom(nexusGenesisCID),
              CIDIdentity.isCanonical(nexusGenesisCID),
              _isAbsoluteChainPath(link.parentPath),
              _isBoundedWireAtom(link.rootCID),
              CIDIdentity.isCanonical(link.rootCID),
              _isBoundedWireAtom(link.carrierCID),
              CIDIdentity.isCanonical(link.carrierCID) else {
            throw ParentFactCertificateError.malformed
        }
        return domain
            + (try _canonicalJSONEncode(nexusGenesisCID))
            + (try _canonicalJSONEncode(link))
    }
}

/// A portable signature over one child-genesis authorization. The existing
/// Lattice link is the signed value and remains the single fact representation.
public struct ParentGenesisCertificateV1: Equatable, Sendable {
    public static let maximumEncodedSize = 64

    private static let domain = Data("lattice-node.parent-genesis.v1\0".utf8)

    public let signature: Data

    public init(
        link: ParentGenesisLink,
        signedBy configuration: NodeConfiguration
    ) throws {
        guard link.parentPath == configuration.chainPath else {
            throw ParentFactCertificateError.wrongConfiguration
        }
        signature = try configuration.signingKey.signature(
            for: Self.signedBytes(
                link: link,
                nexusGenesisCID: configuration.nexusGenesisCID
            )
        )
    }

    private init(signature: Data) {
        self.signature = signature
    }

    public func encode() throws -> Data {
        guard signature.count == Self.maximumEncodedSize else {
            throw ParentFactCertificateError.malformed
        }
        return signature
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedSize else {
            throw ParentFactCertificateError.oversized
        }
        guard data.count == maximumEncodedSize else {
            throw ParentFactCertificateError.malformed
        }
        return Self(signature: data)
    }

    public func verifies(
        link: ParentGenesisLink,
        authorityKey: ParentProcessKey,
        expectedNexusGenesisCID: String,
        expectedParentPath: [String]
    ) -> Bool {
        guard link.parentPath == expectedParentPath,
              let body = try? Self.signedBytes(
                link: link,
                nexusGenesisCID: expectedNexusGenesisCID
              ),
              let key = try? PeerKey(authorityKey.value),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: key.rawRepresentation
              ) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: body)
    }

    private static func signedBytes(
        link: ParentGenesisLink,
        nexusGenesisCID: String
    ) throws -> Data {
        guard _isBoundedWireAtom(nexusGenesisCID),
              CIDIdentity.isCanonical(nexusGenesisCID),
              _isAbsoluteChainPath(link.parentPath),
              StateAtomLimits.isDirectory(link.directory),
              _isBoundedWireAtom(link.childGenesisCID),
              CIDIdentity.isCanonical(link.childGenesisCID) else {
            throw ParentFactCertificateError.malformed
        }
        return domain
            + (try _canonicalJSONEncode(nexusGenesisCID))
            + (try _canonicalJSONEncode(link))
    }
}
