import Crypto
import Ivy
import UInt256
import XCTest
@testable import LatticeNode

final class NodeConfigurationTests: XCTestCase {
    func testChainAddressUsesConsensusDirectoryGrammar() throws {
        let address = try XCTUnwrap(ChainAddress(["Nexus", "Payments-1"]))
        XCTAssertNoThrow(try ChainHello(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: address.components
        ).encode())

        XCTAssertNil(ChainAddress([
            "Nexus",
            String(repeating: "x", count: 65),
        ]))
        XCTAssertNil(ChainAddress(["Nexus", "日本語-☃"]))
        XCTAssertNil(ChainAddress(["Nexus", "line\nbreak"]))
        XCTAssertNil(ChainAddress(["Nexus", "has/slash"]))
        XCTAssertNil(ChainAddress(["Payments"]))
        XCTAssertThrowsError(try ChainHello(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: ["Payments"]
        ).encode())
    }

    func testConfigurationRejectsPathWhoseCanonicalHandshakeIsOversized() throws {
        let component = String(repeating: "x", count: 64)
        let path = ["Nexus"] + Array(repeating: component, count: 1_100)
        XCTAssertNotNil(ChainAddress(path))

        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: path,
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32)
        )) { error in
            XCTAssertEqual(error as? NodeConfigurationError, .invalidChainPath)
        }
    }

    func testNexusIdentityIsFixed() throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32)
        )

        XCTAssertEqual(configuration.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertNil(configuration.parentEndpoint)
        XCTAssertEqual(configuration.minPeerKeyBits, 0)

        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32),
            listenPort: 4001,
            factListenPort: 4001
        )) { error in
            XCTAssertEqual(error as? NodeConfigurationError, .invalidPorts)
        }
    }

    func testZeroMinimumRootWorkIsValidLocalPolicy() throws {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertNoThrow(try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: .zero,
            storagePath: FileManager.default.temporaryDirectory,
            privateKeyHex: key.rawRepresentation.map {
                String(format: "%02x", $0)
            }.joined()
        ))
    }

    func testSigningKeyRecreatesConfiguredIdentity() throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let message = Data("lattice".utf8)
        let first = configuration.signingKey
        let second = configuration.signingKey

        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertEqual(
            try PeerKey(rawRepresentation: first.publicKey.rawRepresentation).hex,
            configuration.processPublicKey
        )
        XCTAssertTrue(
            second.publicKey.isValidSignature(
                try first.signature(for: message),
                for: message
            )
        )
    }

    func testChildRequiresDialableAuthenticatedParent() throws {
        let parentKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 2, count: 32)
        )
        let parentPublicKey = try PeerKey(
            rawRepresentation: parentKey.publicKey.rawRepresentation
        ).hex

        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPublicKey.uppercased(),
                host: " 127.0.0.1 ",
                port: 4001
            )
        )
        XCTAssertEqual(configuration.parentEndpoint?.publicKey, parentPublicKey)
        XCTAssertEqual(configuration.parentEndpoint?.host, "127.0.0.1")

        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32),
            parentEndpoint: ParentEndpoint(publicKey: "bad", host: "", port: 0)
        )) { error in
            XCTAssertEqual(error as? NodeConfigurationError, .invalidParentEndpoint)
        }
    }
}
