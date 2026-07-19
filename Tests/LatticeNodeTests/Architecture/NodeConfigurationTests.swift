import Crypto
import Ivy
import UInt256
import XCTest
@testable import LatticeNode

final class NodeConfigurationTests: XCTestCase {
    func testChainAddressUsesWireSizedUnicodeComponents() throws {
        let address = try XCTUnwrap(ChainAddress(["Nexus", "日本語-☃"]))
        XCTAssertNoThrow(try ChainHello(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: address.components,
            minimumRootWorkHex: String(repeating: "0", count: 63) + "1"
        ).encode())

        XCTAssertNil(ChainAddress([
            "Nexus",
            String(repeating: "x", count: ChainAddress.maximumComponentBytes + 1),
        ]))
        XCTAssertNotNil(ChainAddress(["Nexus", "line\nbreak"]))
        XCTAssertNil(ChainAddress(["Nexus", "has/slash"]))
    }

    func testConfigurationRejectsPathWhoseCanonicalHandshakeIsOversized() throws {
        let escapedControl = String(repeating: "\u{0001}", count: 64)
        let path = ["Nexus"] + Array(repeating: escapedControl, count: 256)
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
