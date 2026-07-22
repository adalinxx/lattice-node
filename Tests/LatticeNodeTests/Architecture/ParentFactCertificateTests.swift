import Crypto
import Foundation
import Ivy
import Lattice
@testable import LatticeNode
import XCTest

final class ParentFactCertificateTests: XCTestCase {
    func testCertificatesRoundTripAndVerifyUnderTheirOwnDomains() throws {
        let parent = try configuration(seed: 1)
        let authority = try XCTUnwrap(ParentWorkAuthorityKey(parent.processPublicKey))
        let carrier = try carrierLink()
        let genesis = try genesisLink(authority: authority)

        let firstCarrier = try ParentCarrierCertificateV1(
            link: carrier,
            signedBy: parent
        )
        let decodedCarrier = try ParentCarrierCertificateV1.decode(
            firstCarrier.encode()
        )
        XCTAssertEqual(try decodedCarrier.encode(), try firstCarrier.encode())
        XCTAssertTrue(decodedCarrier.verifies(
            link: carrier,
            authorityKey: authority,
            expectedNexusGenesisCID: NexusGenesis.expectedBlockHash,
            expectedParentPath: ["Nexus"]
        ))

        let firstGenesis = try ParentGenesisCertificateV1(
            link: genesis,
            signedBy: parent
        )
        let decodedGenesis = try ParentGenesisCertificateV1.decode(
            firstGenesis.encode()
        )
        XCTAssertEqual(try decodedGenesis.encode(), try firstGenesis.encode())
        XCTAssertTrue(decodedGenesis.verifies(
            link: genesis,
            authorityKey: authority,
            expectedNexusGenesisCID: NexusGenesis.expectedBlockHash,
            expectedParentPath: ["Nexus"]
        ))
        XCTAssertNotEqual(
            firstCarrier.signature,
            firstGenesis.signature,
            "fact kinds must use distinct signature domains"
        )
    }

    func testTamperingAndWrongAuthorityFailVerification() throws {
        let parent = try configuration(seed: 2)
        let other = try configuration(seed: 3)
        let authority = try XCTUnwrap(ParentWorkAuthorityKey(parent.processPublicKey))
        let otherAuthority = try XCTUnwrap(ParentWorkAuthorityKey(other.processPublicKey))
        let carrier = try carrierLink()
        let certificate = try ParentCarrierCertificateV1(
            link: carrier,
            signedBy: parent
        )

        var tampered = try certificate.encode()
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        let decoded = try ParentCarrierCertificateV1.decode(tampered)
        XCTAssertFalse(decoded.verifies(
            link: carrier,
            authorityKey: authority,
            expectedNexusGenesisCID: NexusGenesis.expectedBlockHash,
            expectedParentPath: ["Nexus"]
        ))
        XCTAssertFalse(certificate.verifies(
            link: carrier,
            authorityKey: otherAuthority,
            expectedNexusGenesisCID: NexusGenesis.expectedBlockHash,
            expectedParentPath: ["Nexus"]
        ))
        XCTAssertFalse(certificate.verifies(
            link: carrier,
            authorityKey: authority,
            expectedNexusGenesisCID: NexusGenesis.expectedBlockHash,
            expectedParentPath: ["Nexus", "Other"]
        ))
    }

    func testCertificateFramingRejectsEveryTruncationAndTrailingBytes() throws {
        let parent = try configuration(seed: 7)
        let encoded = try ParentCarrierCertificateV1(
            link: carrierLink(),
            signedBy: parent
        ).encode()

        for length in 0..<encoded.count {
            XCTAssertThrowsError(try ParentCarrierCertificateV1.decode(
                Data(encoded.prefix(length))
            ))
        }
        var trailing = encoded
        trailing.append(0)
        XCTAssertThrowsError(try ParentCarrierCertificateV1.decode(trailing))
        XCTAssertThrowsError(try ParentCarrierCertificateV1.decode(
            Data(repeating: 0, count: ParentCarrierCertificateV1.maximumEncodedSize + 1)
        )) { error in
            XCTAssertEqual(error as? ParentFactCertificateError, .oversized)
        }
    }

    func testPortableGateRequiresBothSignedParentFacts() throws {
        let parent = try configuration(seed: 4)
        let authority = try XCTUnwrap(ParentWorkAuthorityKey(parent.processPublicKey))
        let package = ChildValidationPackage(
            proof: proof(),
            parentCarrierLink: try carrierLink(),
            parentGenesisLink: try genesisLink(authority: authority)
        )
        let signed = try ChildValidationPackageEnvelope(
            package,
            certificatesSignedBy: parent
        )
        let decoded = try ChildValidationPackageEnvelope.decode(signed.encode())
        let gate = try AuthenticatedParentFactGate(
            childPath: ["Nexus", "Payments"],
            configuredParentIvyPeerKey: parent.processPublicKey
        )

        XCTAssertNoThrow(try gate.acceptPortable(
            decoded,
            durableParentWorkAuthorityKey: authority
        ))

        let unsigned = try ChildValidationPackageEnvelope(package)
        XCTAssertThrowsError(try gate.acceptPortable(
            unsigned,
            durableParentWorkAuthorityKey: authority
        )) { error in
            XCTAssertEqual(
                error as? AuthenticatedParentFactGateError,
                .missingPortableCertificate
            )
        }

        let other = try configuration(seed: 5)
        let otherAuthority = try XCTUnwrap(ParentWorkAuthorityKey(other.processPublicKey))
        XCTAssertThrowsError(try gate.acceptPortable(
            decoded,
            durableParentWorkAuthorityKey: otherAuthority
        )) { error in
            XCTAssertEqual(
                error as? AuthenticatedParentFactGateError,
                .wrongParentAuthority
            )
        }
    }

    func testLiveGateAcceptsUnsignedFactsButRejectsInvalidPortableSignature() throws {
        let parent = try configuration(seed: 6)
        let authority = try XCTUnwrap(ParentWorkAuthorityKey(parent.processPublicKey))
        let package = ChildValidationPackage(
            proof: proof(),
            parentCarrierLink: try carrierLink(),
            parentGenesisLink: try genesisLink(authority: authority)
        )
        let gate = try AuthenticatedParentFactGate(
            childPath: ["Nexus", "Payments"],
            configuredParentIvyPeerKey: parent.processPublicKey
        )
        let peer = AuthenticatedPeer(
            key: try PeerKey(parent.processPublicKey),
            role: .endpoint,
            route: .direct,
            metadata: PeerMetadata()
        )
        XCTAssertNoThrow(try gate.accept(
            ChildValidationPackageEnvelope(package),
            from: peer
        ))

        var tampered = try ChildValidationPackageEnvelope(
            package,
            certificatesSignedBy: parent
        ).encode()
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        let decoded = try ChildValidationPackageEnvelope.decode(tampered)
        XCTAssertThrowsError(try gate.accept(decoded, from: peer)) { error in
            XCTAssertEqual(
                error as? AuthenticatedParentFactGateError,
                .invalidCertificate
            )
        }
    }

    private func configuration(seed: UInt8) throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: 1,
            storagePath: URL(fileURLWithPath: "/tmp/lattice-parent-certificate-tests"),
            privateKeyHex: Data(repeating: seed, count: 32).map {
                String(format: "%02x", $0)
            }.joined(),
            listenPort: 4101,
            factListenPort: 4102,
            rpcPort: 8100
        )
    }

    private func proof() -> ChildBlockProof {
        ChildBlockProof(
            rootCID: NexusGenesis.expectedBlockHash,
            directoryPath: ["Payments"],
            entries: []
        )
    }

    private func carrierLink() throws -> ParentCarrierLink {
        try JSONDecoder().decode(
            ParentCarrierLink.self,
            from: Data(#"{"parentPath":["Nexus"],"carrierCID":"\#(NexusGenesis.expectedBlockHash)","rootCID":"\#(NexusGenesis.expectedBlockHash)"}"#.utf8)
        )
    }

    private func genesisLink(
        authority: ParentWorkAuthorityKey
    ) throws -> ParentGenesisLink {
        try JSONDecoder().decode(
            ParentGenesisLink.self,
            from: Data(#"{"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\#(NexusGenesis.expectedBlockHash)","parentWorkAuthorityKey":"\#(authority.value)"}"#.utf8)
        )
    }
}
