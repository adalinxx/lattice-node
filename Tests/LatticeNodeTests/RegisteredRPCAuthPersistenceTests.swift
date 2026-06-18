import XCTest
@testable import Lattice
@testable import LatticeNode

final class RegisteredRPCAuthPersistenceTests: XCTestCase {
    func testRegisteredRPCTokensPersistOnlyInOwnerOnlySidecar() async throws {
        let (node, storagePath) = try await makeNode()
        defer { try? FileManager.default.removeItem(at: storagePath) }

        await node.registerRPCEndpoint(
            chainPath: ["Nexus", "Child"],
            endpoint: "http://127.0.0.1:43123/api",
            authToken: "child-cookie-token"
        )

        let endpointsURL = storagePath.appendingPathComponent("registered_rpc_endpoints.json")
        let tokensURL = storagePath.appendingPathComponent("registered_rpc_auth_tokens.json")
        let endpointsData = try Data(contentsOf: endpointsURL)
        let endpointsJSON = try JSONSerialization.jsonObject(with: endpointsData) as? [String: Any]
        let endpoints = try XCTUnwrap(endpointsJSON?["endpoints"] as? [String: String])
        XCTAssertEqual(endpoints["Nexus/Child"], "http://127.0.0.1:43123/api")
        let endpointsText = String(data: endpointsData, encoding: .utf8) ?? ""
        XCTAssertFalse(endpointsText.contains("child-cookie-token"), "bearer tokens must not be mixed into public route metadata")

        let tokenText = try String(contentsOf: tokensURL, encoding: .utf8)
        XCTAssertTrue(tokenText.contains("child-cookie-token"))
        XCTAssertEqual(try mode(tokensURL), 0o600, "registered RPC bearer-token sidecar must be owner-only")

        let restarted = try await makeNode(storagePath: storagePath).node
        await restarted.restoreDeployedChildChains()
        let token = await restarted.registeredRPCAuthToken(chainPath: ["Nexus", "Child"])
        XCTAssertEqual(token, "child-cookie-token")
    }

    func testRegisteredRPCTokensWithLoosePermissionsAreIgnored() async throws {
        let (_, storagePath) = try await makeNode()
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let endpointsURL = storagePath.appendingPathComponent("registered_rpc_endpoints.json")
        let tokensURL = storagePath.appendingPathComponent("registered_rpc_auth_tokens.json")
        try #"{"endpoints":{"Nexus/Child":"http://127.0.0.1:43123/api"}}"#
            .write(to: endpointsURL, atomically: true, encoding: .utf8)
        try #"{"authTokens":{"Nexus/Child":"loose-token"}}"#
            .write(to: tokensURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: tokensURL.path)

        let restarted = try await makeNode(storagePath: storagePath).node
        await restarted.restoreDeployedChildChains()
        let endpoint = await restarted.registeredRPCEndpoint(chainPath: ["Nexus", "Child"])
        let token = await restarted.registeredRPCAuthToken(chainPath: ["Nexus", "Child"])
        XCTAssertEqual(endpoint, "http://127.0.0.1:43123/api")
        XCTAssertNil(token, "loose-permission bearer-token sidecar must fail closed")
    }

    private func makeNode(storagePath: URL? = nil) async throws -> (node: LatticeNode, storagePath: URL) {
        let kp = CryptoUtils.generateKeyPair()
        let path = storagePath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("registered-rpc-auth-\(UUID().uuidString)")
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: path,
            enableLocalDiscovery: false,
            minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        return (node, path)
    }

    private func mode(_ url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        return perms.uint16Value & 0o777
    }
}
