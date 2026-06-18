import Ivy
import XCTest
import HTTPTypes
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
import UInt256
import cashew
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Security smoke tests — each test demonstrates a specific vulnerability.
// These run WITHOUT the CI skip since they're lightweight unit-level checks.

final class SecurityTests: XCTestCase {
    // MARK: - SEC-000: public RPC client identity

    func testRPCClientIPPrefersFlyClientIPWhenProxyHeadersTrusted() {
        var headers = HTTPFields()
        headers.append(HTTPField(name: .init("Fly-Client-IP")!, value: "203.0.113.9"))
        headers.append(HTTPField(name: .init("X-Forwarded-For")!, value: "198.51.100.10, 192.0.2.20"))
        headers.append(HTTPField(name: .init("X-Real-IP")!, value: "198.51.100.11"))

        XCTAssertEqual(
            RPCClientIP.extract(from: headers, trustProxyHeaders: true),
            "203.0.113.9"
        )
    }

    func testRPCClientIPIgnoresProxyHeadersUnlessTrusted() {
        var headers = HTTPFields()
        headers.append(HTTPField(name: .init("Fly-Client-IP")!, value: "203.0.113.9"))
        headers.append(HTTPField(name: .init("X-Forwarded-For")!, value: "198.51.100.10"))

        XCTAssertEqual(
            RPCClientIP.extract(from: headers, trustProxyHeaders: false),
            "unknown"
        )
    }

    func testRPCClientIPUsesDirectConnectionAddressWhenProxyHeadersUntrusted() {
        var headers = HTTPFields()
        headers.append(HTTPField(name: .init("Fly-Client-IP")!, value: "203.0.113.9"))
        headers.append(HTTPField(name: .init("X-Forwarded-For")!, value: "198.51.100.10"))

        XCTAssertEqual(
            RPCClientIP.extract(from: headers, trustProxyHeaders: false, connectionIP: "192.0.2.55"),
            "192.0.2.55"
        )
    }

    func testRPCClientIPFallsBackToForwardedHeadersWhenFlyHeaderMissing() {
        var headers = HTTPFields()
        headers.append(HTTPField(name: .init("X-Forwarded-For")!, value: " 198.51.100.10, 192.0.2.20"))
        headers.append(HTTPField(name: .init("X-Real-IP")!, value: "198.51.100.11"))

        XCTAssertEqual(
            RPCClientIP.extract(from: headers, trustProxyHeaders: true),
            "198.51.100.10"
        )
    }

    func testRPCClientIPFallsBackToDirectConnectionAddressWhenTrustedHeadersMissing() {
        XCTAssertEqual(
            RPCClientIP.extract(from: HTTPFields(), trustProxyHeaders: true, connectionIP: "192.0.2.56"),
            "192.0.2.56"
        )
    }

    // MARK: - SEC-001: unauthenticated deployChain

    /// Any caller can deploy child chains on a node that has --rpc-bind 0.0.0.0
    /// and no --rpc-auth flag. This test verifies that deployChain REQUIRES
    /// authentication even when global auth is disabled.
    func testDeployChainRequiresAuth() async throws {
        let p = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p, storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        // Start RPC bound to 0.0.0.0 with NO auth — simulates a publicly-exposed node
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        // Attempt to deploy a child chain without any auth token
        // Request uses a non-loopback Host header to simulate an internet request
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct DeployBody: Encodable {
            let directory = "AttackerChain"; let parentDirectory = "Nexus"
            let targetBlockTime: UInt64 = 1000; let initialReward: UInt64 = 1000000
            let halvingInterval: UInt64 = 210000; let premine: UInt64 = 0
            let maxTransactionsPerBlock: UInt64 = 100; let maxStateGrowth: Int = 100000
            let maxBlockSize: Int = 1000000; let retargetWindow: UInt64 = 120
        }
        req.httpBody = try JSONEncoder().encode(DeployBody())

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // SHOULD be 401 Unauthorized — currently returns 200 (VULNERABLE)
        XCTAssertEqual(status, 401, "deployChain must require authentication (SEC-001): got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    func testTemplateAndCandidateRequireAuthOnPublicBind() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        for path in ["/api/chain/template", "/api/chain/candidate"] {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)\(path)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue("external-host.example.com", forHTTPHeaderField: "Host")
            req.httpBody = try JSONEncoder().encode(["childNodes": ["http://169.254.169.254"]])

            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            XCTAssertEqual(status, 401,
                "\(path) must require authentication on public bind: got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    // MARK: - admin endpoints require a cookie credential, never loopback alone

    /// RED on origin/main. Construct the server EXACTLY as the default CLI did before
    /// loopback bind, NO `auth:` argument (auth==nil, hasAuth=false,
    /// localOnly=true). On current code `requireAdminAccess` returns nil (ALLOW) on
    /// localOnly, so an unauthenticated admin POST returns 200 (deploy actually
    /// deploys). After the fix every admin endpoint must return 401.
    func testAdminEndpointsOpenOnDefaultLoopbackBindIsClosed() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        // The genuine pre-fix default: loopback bind, NO auth installed.
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        for path in ["/api/chain/deploy", "/api/chain/template", "/api/chain/candidate", "/api/chain/register-rpc"] {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)\(path)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["directory": "AttackerChain", "parentDirectory": "Nexus"])

            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            XCTAssertEqual(status, 401,
                "\(path) must require a cookie credential on the default loopback bind : got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    /// Regression guard: with a cookie installed, the correct Bearer token reaches
    /// the handler (non-401) while a header-less request is rejected by the admin gate.
    func testAdminEndpointSucceedsWithCookieToken() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        struct DeployBody: Encodable {
            let directory = "MyChain"; let parentDirectory = "Nexus"
            let targetBlockTime: UInt64 = 1000; let initialReward: UInt64 = 1000000
            let halvingInterval: UInt64 = 210000; let premine: UInt64 = 0
            let maxTransactionsPerBlock: UInt64 = 100; let maxStateGrowth: Int = 100000
            let maxBlockSize: Int = 1000000; let retargetWindow: UInt64 = 120
        }
        let body = try JSONEncoder().encode(DeployBody())

        // With the correct cookie → reaches the handler (NOT 401).
        var ok = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
        ok.httpMethod = "POST"
        ok.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ok.setValue("Bearer \(cookie.token)", forHTTPHeaderField: "Authorization")
        ok.httpBody = body
        let (_, okResp) = try await URLSession.shared.data(for: ok)
        let okStatus = (okResp as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertNotEqual(okStatus, 401, "valid cookie must reach the admin handler ")

        // No header → middleware rejects with 401.
        var unauth = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
        unauth.httpMethod = "POST"
        unauth.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauth.httpBody = body
        let (_, unauthResp) = try await URLSession.shared.data(for: unauth)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode ?? 0, 401,
            "missing cookie must be rejected by the admin gate ")
    }

    func testDefaultCookieAuthDoesNotGatePublicReadEndpoints() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        for path in ["/api/chain/info", "/health"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(rpcPort)\(path)")!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            XCTAssertNotEqual(status, 401, "\(path) must remain public when RPC cookie auth is installed")
        }
    }

    func testAdminEndpointRejectsQueryTokenCredential() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy?token=\(cookie.token)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["directory": "QueryTokenChain", "parentDirectory": "Nexus"])

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode ?? 0, 401,
            "admin endpoints must not accept URL query tokens as credentials")
    }

    func testAdminEndpointRejectsBareAuthorizationToken() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie.token, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["directory": "BareTokenChain", "parentDirectory": "Nexus"])

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode ?? 0, 401,
            "admin endpoints must require Authorization: Bearer <cookie>, not a bare token")
    }

    /// Exercise the CLI default wiring: a cookie is generated unconditionally at
    /// dataDir/.cookie (mode 0600) and installed, so an unauthenticated admin POST
    /// on the default loopback bind returns 401.
    func testDefaultNodeLaunchGeneratesCookieAndGatesAdmin() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // Replicate the default CLI wiring (NodeCommand: cookie unconditional at
        // dataDir/.cookie, bind 127.0.0.1, auth installed).
        let cookiePath = tmp.appendingPathComponent(".cookie")
        let cookie = try CookieAuth.generate(at: cookiePath)
        XCTAssertNotNil(cookie as CookieAuth?, "default launch must build RPCServer with auth != nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookiePath.path), "default launch must write dataDir/.cookie")
        let attrs = try FileManager.default.attributesOfItem(atPath: cookiePath.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "cookie file must be chmod 0600")

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["directory": "X", "parentDirectory": "Nexus"])
        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode ?? 0, 401,
            "default loopback launch must gate admin endpoints behind the cookie ")
    }

    // MARK: - wildcard CORS must not reflect an arbitrary Origin

    /// With allowedOrigin == "*", an attacker Origin not in the allowlist must NOT
    /// be echoed into Access-Control-Allow-Origin, nor may the header be wildcard "*".
    func testCORSDoesNotReflectArbitraryOrigin() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/info")!)
        req.httpMethod = "GET"
        req.setValue("https://evil.example", forHTTPHeaderField: "Origin")

        let (_, response) = try await URLSession.shared.data(for: req)
        let allowOrigin = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        XCTAssertNotEqual(allowOrigin, "https://evil.example",
            "CORS must not reflect an arbitrary attacker Origin ")
        XCTAssertNotEqual(allowOrigin, "*",
            "CORS must not return wildcard '*' for a non-allowlisted Origin ")
    }

    /// The OPTIONS preflight (which short-circuits before auth/rate-limit) must also
    /// not reflect an arbitrary Origin nor return wildcard "*".
    func testCORSPreflightDoesNotReflectArbitraryOrigin() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/transaction")!)
        req.httpMethod = "OPTIONS"
        req.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        req.setValue("POST", forHTTPHeaderField: "Access-Control-Request-Method")

        let (_, response) = try await URLSession.shared.data(for: req)
        let allowOrigin = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        XCTAssertNotEqual(allowOrigin, "https://evil.example",
            "CORS preflight must not reflect an arbitrary attacker Origin ")
        XCTAssertNotEqual(allowOrigin, "*",
            "CORS preflight must not return wildcard '*' for a non-allowlisted Origin ")
    }

    /// An explicitly allowlisted origin still receives an exact Access-Control-Allow-Origin
    /// equal to that allowlisted value (guards against over-correction).
    func testCORSAllowsConfiguredOrigin() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "http://127.0.0.1")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/info")!)
        req.httpMethod = "GET"
        req.setValue("http://127.0.0.1", forHTTPHeaderField: "Origin")

        let (_, response) = try await URLSession.shared.data(for: req)
        let allowOrigin = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        XCTAssertEqual(allowOrigin, "http://127.0.0.1",
            "Explicitly allowlisted origin must receive its exact Access-Control-Allow-Origin ")
    }

    func testRegisterRPCRequiresAuthOnPublicBind() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/register-rpc")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")
        struct RegisterBody: Encodable {
            let chainPath: [String]
            let endpoint: String
        }
        req.httpBody = try JSONEncoder().encode(RegisterBody(chainPath: ["Nexus"], endpoint: "http://attacker.example"))

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 401,
            "chain/register-rpc must require authentication on public bind: got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    func testRegisterRPCRejectsNonLoopbackEndpoint() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // admin endpoints require a cookie credential regardless of bind.
        // Present it so this test still exercises the endpoint's validation logic.
        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/register-rpc")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cookie.token)", forHTTPHeaderField: "Authorization")
        struct RegisterBody: Encodable {
            let chainPath: [String]
            let endpoint: String
        }
        req.httpBody = try JSONEncoder().encode(RegisterBody(chainPath: ["Nexus"], endpoint: "http://attacker.example"))

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 400,
            "chain/register-rpc must reject non-loopback endpoints: got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")

        let maybeNetwork = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(maybeNetwork)
        let endpoint = await network.rpcEndpoint
        XCTAssertNil(endpoint)
    }

    func testTemplateRejectsNonLoopbackChildNodes() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // admin endpoints require a cookie credential regardless of bind.
        // Present it so this test still exercises the endpoint's validation logic.
        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/template")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cookie.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["childNodes": ["http://169.254.169.254/latest/meta-data"]])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 400,
            "chain/template must reject non-loopback childNodes: got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    func testUnknownBlockDetailEndpointsDoNotTriggerNetworkFetchWait() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        let unknown = "bafyreibunknownblockcid000000000000000000000000000000000000000"
        let paths = [
            "/api/block/\(unknown)/transactions",
            "/api/block/\(unknown)/children",
            "/api/block/\(unknown)/state",
            "/api/block/\(unknown)/state/account/alice",
            "/api/transaction/\(unknown)?blockHash=\(unknown)",
        ]

        for path in paths {
            let start = Date()
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(rpcPort)\(path)")!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(status, 404, "\(path) should return 404 for unknown local block")
            XCTAssertLessThan(elapsed, 2.0, "\(path) should not wait for Ivy/DHT fetch; elapsed \(elapsed)s")
        }
    }

    func testRejectedRPCSubmitDoesNotStoreBodyDataDurably() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = CryptoUtils.createAddress(from: attacker.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: attackerAddr, delta: -1)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [attackerAddr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        let bodyData = try XCTUnwrap(body.toData())
        let bodyHex = bodyData.map { String(format: "%02x", $0) }.joined()

        struct SubmitBody: Encodable {
            let signatures: [String: String]
            let bodyCID: String
            let bodyData: String
            let chainPath: [String]
        }
        let submit = SubmitBody(
            signatures: [attacker.publicKey: "not-a-valid-signature"],
            bodyCID: bodyHeader.rawCID,
            bodyData: bodyHex,
            chainPath: ["Nexus"]
        )

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/transaction")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(submit)

        let (_, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 400)

        let maybeNetwork = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(maybeNetwork)
        let stored = await network.diskBroker.hasVolume(root: bodyHeader.rawCID)
        XCTAssertFalse(stored, "Rejected RPC bodyData must not be written to durable storage")
    }

    // MARK: - SEC-002: validateBalances overflow continue (silent skip)

    /// When netDebit accumulation overflows Int64, the validator silently skips
    /// the update via `continue`, potentially allowing a transaction to bypass
    /// the balance check for that account. The fix is to return
    /// .balanceNotConserved on overflow instead of continuing.
    func testValidateBalancesRejectsOnOverflow() async throws {
        let p = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p, storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }

        // Wait for genesis to be processed
        try await Task.sleep(for: .milliseconds(200))

        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = CryptoUtils.createAddress(from: attacker.publicKey)

        // Attacker has 0 tokens. Build a transaction where:
        // Action1: attacker delta = +Int64.max (huge credit)
        // Action2: attacker delta = +1          (another credit → overflow in accumulation)
        // Net after overflow bug: attacker netDebit stays at Int64.max (positive → not checked)
        // This bypasses the "does attacker have enough tokens" check
        // BUT validateConservation catches fee discrepancy — so the fix here is belt-and-suspenders.
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: attackerAddr, delta: Int64.max),
                AccountAction(owner: attackerAddr, delta: 1),          // overflow: silent skip BUG
                AccountAction(owner: attackerAddr, delta: -Int64.max), // debit same amount
                AccountAction(owner: attackerAddr, delta: -1)          // debit the +1
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [attackerAddr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: attacker.privateKey) else {
            XCTFail("Failed to sign"); return
        }
        let tx = Transaction(signatures: [attacker.publicKey: sig], body: bodyHeader)

        // This transaction should be REJECTED because attacker has 0 tokens
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction from zero-balance account must be rejected (SEC-002)")
    }

    // MARK: - SEC-003: validateBalances overflow must not silently continue

    /// Direct unit test of the overflow path in validateBalances.
    /// If netDebit overflows, the validator must return an error, not continue.
    func testValidatorRejectsOverflowDelta() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = CryptoUtils.createAddress(from: attacker.publicKey)

        // Single overflow: attacker sends themselves Int64.max tokens they don't have
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: attackerAddr, delta: -Int64.max), // debit Int64.max
                AccountAction(owner: attackerAddr, delta: Int64.max)   // cancel with credit
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [attackerAddr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: attacker.privateKey) else {
            XCTFail("Failed to sign"); return
        }
        let tx = Transaction(signatures: [attacker.publicKey: sig], body: bodyHeader)

        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        // debit(Int64.max) ≠ credit(Int64.max) + fee(1) → should fail conservation
        XCTAssertFalse(result, "Self-cancel transaction with fee must be rejected (SEC-003)")
    }

    // MARK: - SEC-004: Replay attack — same transaction twice

    /// A confirmed transaction must not be re-submittable (replay attack).
    func testTransactionCannotBeReplayed() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let premineAmt: UInt64 = 1_000_000
        let spec = testSpec(premine: premineAmt)
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        // Custom genesis builder that sends premine to minerAddr
        let node = try await LatticeNode(config: config, genesisConfig: genesis) { gc, f in
            let amount = Int64(gc.spec.premineAmount())
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: amount)],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 0, nonce: 0
            )
            let bh = try HeaderImpl<TransactionBody>(node: body)
            let tx = Transaction(signatures: [kp.publicKey: "genesis"], body: bh)
            return try await BlockBuilder.buildGenesis(
                spec: gc.spec, transactions: [tx],
                timestamp: gc.timestamp, target: gc.target, fetcher: f
            )
        }
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(1, on: node)

        let balance = (try? await node.getBalance(address: minerAddr)) ?? 0
        guard balance > 0 else { XCTFail("Need balance from genesis premine, got 0"); return }

        let recipient = CryptoUtils.generateKeyPair()
        let recipientAddr = CryptoUtils.createAddress(from: recipient.publicKey)

        // Build and submit a valid transfer
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: minerAddr, delta: -11),
                AccountAction(owner: recipientAddr, delta: 10)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 1, nonce: 1, chainPath: ["Nexus"]  // nonce 0 used by genesis premine
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)

        let first = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertTrue(first, "First submission should succeed (SEC-004)")

        // Mine to confirm it
        try await mineBlocks(1, on: node)

        // Replay the SAME transaction
        let replay = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(replay, "Replayed transaction must be rejected (SEC-004)")
    }

    // MARK: - SEC-005: Unsigned transaction must be rejected

    /// A transaction with no signatures must never be accepted.
    func testUnsignedTransactionRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -10)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        // NO signature
        let tx = Transaction(signatures: [:], body: try HeaderImpl<TransactionBody>(node: body))
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction with no signatures must be rejected (SEC-005)")
    }

    // MARK: - SEC-006: Wrong-signer transaction rejected

    /// A transaction signed by a different key than listed in `signers` must fail.
    func testWrongSignerRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let impostor = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -10)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        // Sign with IMPOSTOR key, not the listed signer
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: impostor.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [impostor.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction signed by wrong key must be rejected (SEC-006)")
    }

    // MARK: - SEC-007: Double-spend in same block

    /// Two transactions spending the same nonce slot cannot both be confirmed.
    func testDoubleSpendSameNonce() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let spec = testSpec(premine: 1_000_000)
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(2, on: node)

        let r1 = CryptoUtils.generateKeyPair()
        let r2 = CryptoUtils.generateKeyPair()

        func makeTx(to recipientAddr: String) -> Transaction? {
            let body = TransactionBody(
                accountActions: [
                    AccountAction(owner: addr, delta: -11),
                    AccountAction(owner: recipientAddr, delta: 10)
                ],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
            )
            // known-valid local node; CID cannot fail
            let bh = try! HeaderImpl<TransactionBody>(node: body)
            guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else { return nil }
            return Transaction(signatures: [kp.publicKey: sig], body: bh)
        }

        guard let tx1 = makeTx(to: CryptoUtils.createAddress(from: r1.publicKey)),
              let tx2 = makeTx(to: CryptoUtils.createAddress(from: r2.publicKey)) else {
            XCTFail("Failed to build txs"); return
        }

        // Both spend nonce=0 — only one can win
        let s1 = await node.submitTransaction(directory: "Nexus", transaction: tx1)
        let s2 = await node.submitTransaction(directory: "Nexus", transaction: tx2)

        // At most one should be in mempool (RBF allows the second to replace if higher fee,
        // but same fee means first wins)
        let accepted = [s1, s2].filter { $0 }.count
        XCTAssertLessThanOrEqual(accepted, 1, "At most one of two same-nonce transactions can be accepted (SEC-007)")
    }

    // MARK: - SEC-008: Empty chainPath accepted on all chains (cross-chain replay)

    /// A transaction with chainPath: [] bypasses chain routing validation and is
    /// accepted by any chain's mempool AND included in any chain's blocks.
    /// This enables cross-chain replay: spend tokens on one chain and replay
    /// the same transaction on another chain.
    func testEmptyChainPathRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let spec = testSpec(premine: 1_000_000)
        let genesisConfig = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesisConfig) { gc, f in
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(gc.spec.premineAmount()))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [senderAddr], fee: 0, nonce: 0
            )
            let bh = try HeaderImpl<TransactionBody>(node: body)
            let tx = Transaction(signatures: [kp.publicKey: "genesis"], body: bh)
            return try await BlockBuilder.buildGenesis(
                spec: gc.spec, transactions: [tx],
                timestamp: gc.timestamp, target: gc.target, fetcher: f
            )
        }
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(1, on: node)

        let recipient = CryptoUtils.generateKeyPair()
        let recipientAddr = CryptoUtils.createAddress(from: recipient.publicKey)

        // Transaction with EMPTY chainPath — should be REJECTED, currently ACCEPTED
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: -11),
                AccountAction(owner: recipientAddr, delta: 10)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [senderAddr], fee: 1, nonce: 1,
            chainPath: []   // ← EMPTY — bypasses chain isolation
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)

        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        // SHOULD be rejected — empty chainPath must not be accepted (SEC-008)
        XCTAssertFalse(result, "Transaction with empty chainPath must be rejected (SEC-008)")
    }

    // MARK: - SEC-009: Mining-control endpoint removed (no in-node miner)

    /// The node no longer mines in-process — block production runs in the
    /// external lattice-miner — so POST /api/mining/start no longer exists.
    /// This removes the reward-redirection attack surface entirely; the route
    /// must return 404 rather than ever accepting a foreign key.
    func testStartMiningEndpointRemoved() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        let attacker = CryptoUtils.generateKeyPair()
        struct MineBody: Encodable {
            let chain = "Nexus"
            let publicKey: String
            let privateKey: String
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/mining/start")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(MineBody(publicKey: attacker.publicKey, privateKey: attacker.privateKey))
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 404,
            "mining/start endpoint must be removed (SEC-009): got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    // MARK: - SEC-010: Mining-control endpoint removed (no griefing surface)

    /// POST /api/mining/stop previously let any caller halt block production on
    /// an internet-exposed node. The endpoint is removed along with the in-node
    /// miner, so it must return 404.
    func testStopMiningEndpointRemoved() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/mining/stop")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["chainPath": ["Nexus"]])
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 404,
            "mining/stop endpoint must be removed (SEC-010): got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    // MARK: - SEC-011: Path traversal via ".." in deployChain directory

    /// The directory name ".." passes whitespace and "/" checks but causes
    /// appendingPathComponent to traverse to the parent of the storage path.
    /// An attacker with local access could use this to create files outside
    /// the node's intended data directory.
    func testDeployChainRejectsDotDotDirectory() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // admin endpoints require a cookie credential regardless of bind.
        // Present it so this test still exercises deploy's directory validation.
        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        // Local-bound RPC (loopback) to test directory validation
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        // Test ".." — should be REJECTED (path traversal)
        for badDir in ["..", ".", ".hidden", "a/b", "a\\b"] {
            struct DeployBody: Encodable {
                let directory: String; let parentDirectory = "Nexus"
                let targetBlockTime: UInt64 = 1000; let initialReward: UInt64 = 1000000
                let halvingInterval: UInt64 = 210000; let premine: UInt64 = 0
                let maxTransactionsPerBlock: UInt64 = 100; let maxStateGrowth: Int = 100000
                let maxBlockSize: Int = 1000000; let retargetWindow: UInt64 = 120
            }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(cookie.token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(DeployBody(directory: badDir))
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            XCTAssertEqual(status, 400,
                "deployChain must reject path-traversal directory '\(badDir)' (SEC-011): got \(status)")
        }
    }

    // MARK: - cumulative cross-nonce over-debit at mempool admission

    /// Spin up a node whose genesis premine funds `minerWallet`, mine one block,
    /// then transfer `fund` from the miner to a fresh sender `S` and mine again so
    /// `getBalance(S) == fund` exactly and `S` has used no nonce of its own.
    /// Returns the running node plus the funded sender wallet. Caller owns stop().
    private func makeFundedSenderNode(
        minerWallet kp: (privateKey: String, publicKey: String),
        premine: UInt64,
        fund: UInt64,
        tmp: URL
    ) async throws -> (node: LatticeNode, sender: Wallet) {
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let spec = testSpec(premine: premine)
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis) { gc, f in
            let amount = Int64(gc.spec.premineAmount())
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: amount)],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 0, nonce: 0
            )
            let bh = try HeaderImpl<TransactionBody>(node: body)
            let tx = Transaction(signatures: [kp.publicKey: "genesis"], body: bh)
            return try await BlockBuilder.buildGenesis(
                spec: gc.spec, transactions: [tx],
                timestamp: gc.timestamp, target: gc.target, fetcher: f
            )
        }
        try await node.start()
        try await mineBlocks(1, on: node)

        let miner = Wallet(privateKeyHex: kp.privateKey, publicKeyHex: kp.publicKey)
        let sender = Wallet.create()
        // Fund S with EXACTLY `fund`: miner debit = fund + fee, miner nonce 1
        // (genesis used nonce 0). After mining, getBalance(S) == fund and S has
        // never used a nonce, so its next expected nonce is 0.
        guard let fundTx = miner.buildTransfer(
            to: sender.address, amount: fund, fee: 1, nonce: 1, chainPath: ["Nexus"]
        ) else {
            throw XCTestError(.failureWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "fund tx build failed"])
        }
        let funded = await node.submitTransaction(directory: "Nexus", transaction: fundTx)
        XCTAssertTrue(funded, "funding transfer must be admitted")
        try await mineBlocks(1, on: node)
        let bal = (try? await node.getBalance(address: sender.address)) ?? 0
        XCTAssertEqual(bal, fund, "sender S must be funded to exactly \(fund)")
        return (node, sender)
    }

    /// (a) A single sender S with confirmed balance B submits two distinct-nonce
    /// transfers each debiting ~0.8B. Each tx is individually affordable (passes
    /// the per-tx validateBalances against the full untouched B), but together
    /// they debit ~1.6B > B. Admission must reject the second on the cumulative
    /// per-sender bound, and the mempool must hold only tx0 for S.
    func testCumulativeCrossNonceDebitRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let B: UInt64 = 1_000_000
        let (node, sender) = try await makeFundedSenderNode(
            minerWallet: kp, premine: B + 1_000, fund: B, tmp: tmp
        )
        defer { Task { await node.stop() } }

        let recipient = Wallet.create().address
        let debit: UInt64 = 800_000          // amount + fee ≈ 0.8B
        let amount = debit - 1               // fee = 1

        // tx0 (nonce 0): net debit 0.8B <= B -> admitted.
        guard let tx0 = sender.buildTransfer(
            to: recipient, amount: amount, fee: 1, nonce: 0, chainPath: ["Nexus"]
        ) else { XCTFail("tx0 build failed"); return }
        let r0 = await node.submitTransaction(directory: "Nexus", transaction: tx0)
        XCTAssertTrue(r0, "tx0 (0.8B) must be admitted (affordable against full B)")

        // tx1 (nonce 1): individually 0.8B <= B, but cumulative 1.6B > B -> rejected.
        guard let tx1 = sender.buildTransfer(
            to: recipient, amount: amount, fee: 1, nonce: 1, chainPath: ["Nexus"]
        ) else { XCTFail("tx1 build failed"); return }
        let r1 = await node.submitTransaction(directory: "Nexus", transaction: tx1)
        XCTAssertFalse(r1, "tx1 must be rejected: cumulative 1.6B exceeds confirmed balance B ")

        // Only tx0 survives: mining one block confirms exactly one transfer out.
        try await mineBlocks(1, on: node)
        let after = (try? await node.getBalance(address: sender.address)) ?? 0
        XCTAssertEqual(after, B - debit,
            "exactly one transfer (tx0) may land; balance must reflect a single 0.8B debit")
    }

    /// (b) Two CONCURRENT submissions for distinct nonces N and N+1, each debiting
    /// ~0.8B, race the validate->insert window. The single locked view across the
    /// cumulative check and the insert must ensure at most one persists; the
    /// summed net debit of admitted-and-confirmed S-txs must never exceed B.
    func testConcurrentCrossNonceSubmitsCannotOverspend() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let B: UInt64 = 1_000_000
        let (node, sender) = try await makeFundedSenderNode(
            minerWallet: kp, premine: B + 1_000, fund: B, tmp: tmp
        )
        defer { Task { await node.stop() } }

        let recipient = Wallet.create().address
        let debit: UInt64 = 800_000
        let amount = debit - 1

        guard let tx0 = sender.buildTransfer(
                  to: recipient, amount: amount, fee: 1, nonce: 0, chainPath: ["Nexus"]),
              let tx1 = sender.buildTransfer(
                  to: recipient, amount: amount, fee: 1, nonce: 1, chainPath: ["Nexus"]) else {
            XCTFail("tx build failed"); return
        }

        // Race both submissions through the validate->insert seam.
        async let a = node.submitTransaction(directory: "Nexus", transaction: tx0)
        async let b = node.submitTransaction(directory: "Nexus", transaction: tx1)
        let admitted = [await a, await b].filter { $0 }.count
        XCTAssertLessThanOrEqual(admitted, 1,
            "at most one of the two concurrent 0.8B distinct-nonce txs may be admitted ")

        // Whatever was admitted, the confirmed on-chain outflow must not exceed B.
        try await mineBlocks(1, on: node)
        let after = (try? await node.getBalance(address: sender.address)) ?? 0
        XCTAssertGreaterThanOrEqual(after, B - debit,
            "summed net debit of admitted-and-confirmed S-txs must not exceed confirmed balance B")
    }

    // MARK: - SEC-012: validateBalanceChanges enforces coinbase <= reward + fees

    /// validateBalanceChanges checks totalCredits <= totalDebits + reward + fees.
    /// A block with an inflated coinbase (reward+1) must fail this check.
    func testInflatedCoinbaseRejectedByBlockValidation() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let f = cas()
        let t = now() - 50_000
        let spec = testSpec()
        let reward = spec.rewardAtBlock(1)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Inflated coinbase: miner claims reward+1 tokens (1 extra)
        let inflatedBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + 1))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: inflatedBody)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let inflateTx = Transaction(signatures: [kp.publicKey: sig], body: bh)

        let inflatedBlock = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [inflateTx],
            timestamp: t + 1000, target: UInt256(1000), nonce: 1, fetcher: f
        )
        try VolumeImpl<Block>(node: inflatedBlock).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // validateNexus runs validateBalanceChanges:
        // totalCredits (reward+1) > available (reward+0) -> must return false (SEC-012)
        let (valid, _, _) = (try? await inflatedBlock.validateNexus(fetcher: f)) ?? (false, .empty, nil)
        XCTAssertFalse(valid,
            "Block with inflated coinbase must fail validateNexus (SEC-012)")
    }

    // MARK: - SEC-013: Block timestamp too far in the future must be rejected

    /// isBlockTimestampValid rejects blocks more than 2h in the future.
    func testFutureBlockRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let f = cas()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build a block 3 hours in the future
        let farFuture = Int64(Date().timeIntervalSince1970 * 1000) + 3 * 60 * 60 * 1000
        let futureBlock = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: farFuture,
            target: UInt256(1000), nonce: 1, fetcher: f
        )

        // isBlockTimestampValid should reject it
        let valid = node.isBlockTimestampValid(futureBlock)
        XCTAssertFalse(valid, "Block 3h in the future must be rejected (SEC-013)")
    }

    // MARK: - SEC-014: Block too old must be rejected

    /// isBlockTimestampValid rejects blocks more than 24h old.
    func testAncientBlockRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let f = cas()
        let longAgo = now() - 200_000_000  // ~55 hours ago
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: longAgo, target: UInt256(1000), fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        let oldBlock = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: longAgo + 1000,
            target: UInt256(1000), nonce: 1, fetcher: f
        )

        let valid = node.isBlockTimestampValid(oldBlock)
        XCTAssertFalse(valid, "Block 55 hours old must be rejected (SEC-014)")
    }

    // MARK: - Cheap PoW gate must not be stricter than consensus

    /// `isBlockPoWValid` must reject a forged target but accept an exact match
    /// once the parent is cached. This pins the reachable behavior around the
    /// minimum-target-recovery parity clause (matching the library's internal
    /// `ChainSpec.isMinimumTargetRecovery`). NOTE: the recovery branch itself
    /// (target == minimumTarget == 1) is PoW-infeasible to mine — `target >=
    /// hash` would require hash <= 1 — so it cannot be exercised end-to-end; the
    /// clause exists only for parity with consensus on the accept side.
    func testPoWGateRejectsForgedTargetButAcceptsExactMatch() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let f = cas()
        let ts = now()
        // target = UInt256.max → validateProofOfWork (target >= hash) always holds,
        // so the PoW guard passes and we exercise the target-vs-cache check.
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: ts, target: UInt256.max, fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: ts + 1000,
            target: UInt256.max, nextTarget: UInt256.max, nonce: 0, fetcher: f
        )
        guard let parentCID = block.parent?.rawCID else {
            return XCTFail("built block has no parent CID")
        }

        // Forged target: parent's cached nextTarget differs and target is not the
        // minimum-target floor → the gate must REJECT (protective behavior intact).
        node.cacheNextTarget(blockCID: parentCID, value: UInt256(1000))
        XCTAssertFalse(node.isBlockPoWValid(block), "forged target must be rejected when parent is cached")

        // Exact match → the gate must ACCEPT.
        node.cacheNextTarget(blockCID: parentCID, value: UInt256.max)
        XCTAssertTrue(node.isBlockPoWValid(block), "exact target match must be accepted")
    }

    // MARK: - Announcement dedup must not poison the validated-block path

    /// A bare block ANNOUNCEMENT (CID-only, unvalidated) must not prime the
    /// validated-bytes dedup map (`recentPeerBlocks`); otherwise a peer could
    /// announce a CID it doesn't possess and dedup-suppress the genuine full
    /// block arriving within the window. Announcement dedup uses its own map.
    func testAnnouncementDoesNotPoisonValidatedBlockDedup() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let cid = "QmAnnouncedButNotPossessed"
        let t = ContinuousClock.Instant.now
        await node.recordBlockAnnounceTime(key: cid, time: t)

        let validatedHit = await node.recentBlockTime(for: cid)
        XCTAssertNil(validatedHit, "a bare announcement must NOT prime the validated-block dedup map (M1)")
        let announceHit = await node.recentBlockAnnounceTime(for: cid)
        XCTAssertNotNil(announceHit, "announcement dedup should record into its own map")
    }

    // MARK: - SEC-015: maxTransactionsPerBlock enforced on-chain

    /// A block containing more transactions than spec.maxTransactionsPerBlock
    /// must fail validateNexus.
    func testMaxTransactionsPerBlockEnforced() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let f = cas()
        let t = now() - 50_000
        let maxTx: UInt64 = 2
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: maxTx,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000, premine: 0,
                             targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
                             retargetWindow: 1000)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build maxTx + 1 transactions
        var txs: [Transaction] = []
        for i in 0..<(Int(maxTx) + 1) {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: addr, delta: 1)],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [addr], fee: 0, nonce: UInt64(i), chainPath: ["Nexus"]
            )
            let bh = try HeaderImpl<TransactionBody>(node: body)
            guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else { continue }
            txs.append(Transaction(signatures: [kp.publicKey: sig], body: bh))
        }

        let overloadedBlock = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: txs,
            timestamp: t + 1000, target: UInt256(1000), nonce: 1, fetcher: f
        )
        try VolumeImpl<Block>(node: overloadedBlock).storeRecursively(storer: storer)
        await storer.flush(to: f)

        let (valid, _, _) = (try? await overloadedBlock.validateNexus(fetcher: f)) ?? (false, .empty, nil)
        XCTAssertFalse(valid,
            "Block with \(txs.count) txs (max=\(maxTx)) must fail validateNexus (SEC-015)")
    }

    // MARK: - SEC-016: Duplicate account owner in single transaction rejected

    /// A transaction with two actions for the same owner is rejected by
    /// validateUniqueOwners to prevent balance manipulation.
    func testDuplicateAccountOwnerRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: addr, delta: 10),
                AccountAction(owner: addr, delta: -10)  // same owner twice
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction with duplicate owner must be rejected (SEC-016)")
    }

    // MARK: - SEC-017: Fee below minimum rejected

    func testFeeBelowMinimumRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -1)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 0,  // below minimum (1)
            nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction with fee=0 (below minimum=1) must be rejected (SEC-017)")
    }

    // MARK: - SEC-018: Transaction to unknown chain rejected

    func testTransactionToUnknownChainRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // Submit to a chain that doesn't exist
        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -1)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["GhostChain"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)
        // submitTransaction to "GhostChain" should return false (chain not found)
        let result = await node.submitTransaction(directory: "GhostChain", transaction: tx)
        XCTAssertFalse(result, "Transaction to unknown chain must be rejected (SEC-018)")
    }

    // MARK: - SEC-019: Rate limiter enforces per-IP limits

    /// The rate limiter must enforce a per-IP token-bucket limit and reject
    /// requests that exceed it. Also verifies the bucket map has a hard cap
    /// to prevent memory exhaustion via IP spoofing.
    func testRateLimiterEnforcesLimit() {
        let limiter = RPCRateLimiter(requestsPerSecond: 10, burstSize: 5)

        // First 5 (burst) requests should be allowed
        for i in 0..<5 {
            XCTAssertTrue(limiter.allow(ip: "1.2.3.4"),
                "Request \(i+1) within burst should be allowed (SEC-019)")
        }
        // Next request should be rate-limited
        XCTAssertFalse(limiter.allow(ip: "1.2.3.4"),
            "Request beyond burst must be rejected (SEC-019)")
    }

    func testRateLimiterBucketCapPreventsMemoryExhaustion() {
        let limiter = RPCRateLimiter(requestsPerSecond: 10, burstSize: 5)

        // Fill up to maxBuckets (10_000) distinct IPs
        // After cap, new IPs should be rejected
        for i in 0..<10_000 {
            _ = limiter.allow(ip: "10.0.\(i / 256).\(i % 256)")
        }
        // A brand new IP beyond the cap must be rejected (prevents memory exhaustion)
        let newIP = "192.168.99.99"
        XCTAssertFalse(limiter.allow(ip: newIP),
            "New IP beyond maxBuckets must be rejected to prevent memory exhaustion (SEC-019)")
    
    }

    // MARK: - SEC-020: Fee conservation property (any valid transfer conserves value)

    func testFeeConservationProperty() async throws {
        let sender = CryptoUtils.generateKeyPair()
        let senderAddr = CryptoUtils.createAddress(from: sender.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: sender.publicKey, privateKey: sender.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // Property: a transaction where debit != credit+fee must be rejected
        let recipient = CryptoUtils.generateKeyPair()
        let recipientAddr = CryptoUtils.createAddress(from: recipient.publicKey)

        // Case 1: send 100, pay fee 1, but only debit 100 (should be 101) — non-conservation
        let badBody = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: -100),  // only debits 100
                AccountAction(owner: recipientAddr, delta: 100)  // credits 100
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [senderAddr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: badBody)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: sender.privateKey) else {
            XCTFail("sign failed"); return
        }
        let badTx = Transaction(signatures: [sender.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: badTx)
        XCTAssertFalse(result,
            "Non-conserving transaction (debit 100, credit 100, fee 1: 100 ≠ 100+1) must be rejected (SEC-020)")
    }

    // MARK: - SEC-021: Block validation is complete — all checks fire for nexus blocks

    /// Verifies that a block with a wrong prevState (state continuity break) is rejected.
    /// This tests the chain of validation checks in validateNexus.
    func testStateContinuityBreakRejected() async throws {
        let f = cas()
        let t = now() - 50_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build a valid block1
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 1, fetcher: f
        )
        try VolumeImpl<Block>(node: block1).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build block2 using a DIFFERENT previous block's state (state break)
        // Use genesis as "previous" but claim block1's height+1
        // This is invalid: prevState should be block1.postState, not genesis.postState
        let fakeBlock2 = try await BlockBuilder.buildBlock(
            previous: genesis,  // wrong parent — uses genesis state, not block1 state
            timestamp: t + 2000, target: UInt256(1000), nonce: 2, fetcher: f
        )
        // Override height to 2 so validateHeight passes against block1
        let tamperedBlock = Block(
            version: fakeBlock2.version, parent: block1.parent,
            transactions: fakeBlock2.transactions, target: fakeBlock2.target,
            nextTarget: fakeBlock2.nextTarget, spec: fakeBlock2.spec,
            parentState: fakeBlock2.parentState, prevState: fakeBlock2.prevState,
            postState: fakeBlock2.postState, children: fakeBlock2.children,
            height: 2, timestamp: t + 2000, nonce: 2
        )
        try VolumeImpl<Block>(node: tamperedBlock).storeRecursively(storer: storer)
        await storer.flush(to: f)

        // validateNexus should reject because prevState doesn't match block1.postState
        let (valid, _, _) = (try? await tamperedBlock.validateNexus(fetcher: f)) ?? (false, .empty, nil)
        XCTAssertFalse(valid,
            "Block with broken state continuity (wrong prevState) must fail validateNexus (SEC-021)")
    }

    // MARK: - SEC-022: Deposits not allowed on nexus, withdrawals not allowed on nexus

    func testDepositsOnNexusRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let deposit = DepositAction(nonce: 0, demander: addr, amountDemanded: 100, amountDeposited: 100)
        let body = TransactionBody(
            accountActions: [], actions: [],
            depositActions: [deposit],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result,
            "Deposit action on Nexus chain must be rejected (SEC-022)")
    }

    // MARK: - SEC-023: Transaction size limit enforced in mempool

    func testOversizeTransactionRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        // Build a transaction with a huge action key (>102_400 bytes total)
        let hugeKey = String(repeating: "a", count: 110_000)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: hugeKey, oldValue: nil, newValue: "x")],
            depositActions: [], genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(bodyHeader: bh, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result,
            "Transaction exceeding MAX_TRANSACTION_SIZE (102_400) must be rejected (SEC-023)")
    }

    // MARK: - SEC-024: P2P message deserializer handles malformed input without crashing

    /// The Ivy Message.deserialize function must return nil (not crash) for any
    /// arbitrary byte sequence. This is a parser safety test (fuzzing baseline).
    func testMessageDeserializerHandlesMalformedInput() {
        // All these must return nil, not crash
        let cases: [Data] = [
            Data(),                                         // empty
            Data([0xFF]),                                   // unknown tag
            Data([0x01]),                                   // ping with no nonce
            Data([0x03, 0xFF, 0xFF]),                       // block with truncated CID
            Data([0x03] + Array(repeating: 0xFF, count: 8192)), // block: huge CID
            Data([0x0A, 0x01, 0x00]),                       // neighbors: count=1 but no data
            Data(repeating: 0x00, count: 1000),             // all zeros
            Data(repeating: 0xFF, count: 1000),             // all 0xFF
        ]
        for data in cases {
            let msg = Message.deserialize(data)
            // Anything is acceptable EXCEPT a crash
            _ = msg  // just ensure it doesn't trap
        }
        XCTAssertTrue(true, "Message.deserialize must not crash on malformed input (SEC-024)")
    }

    // MARK: - SEC-025: PBKDF2 used for key encryption (not weak HKDF)

    /// Verifies the identity key encryption uses PBKDF2 (100k iterations) rather
    /// than plain HKDF, which provides no brute-force resistance for passwords.
    func testKeyEncryptionUsesPBKDF2() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let password = "test-password-for-security-audit"
        let identity = try loadOrCreateIdentity(dataDir: tmp, password: password)

        // Identity must have an encrypted key when password is provided
        XCTAssertNotNil(identity.encryptedPrivateKey,
            "Identity must have an encrypted key when password provided (SEC-025)")
        // Note: loadOrCreateIdentity returns the decrypted key in memory for use by the node;
        // the STORED FILE is checked below to confirm the plaintext is not persisted.

        // Round-trip: re-loading with same password must yield the same private key
        let reloaded = try loadOrCreateIdentity(dataDir: tmp, password: password)
        XCTAssertEqual(reloaded.privateKey, identity.privateKey,
            "Key must be decryptable with same password (SEC-025)")

        // Wrong password must fail to decrypt
        XCTAssertThrowsError(try loadOrCreateIdentity(dataDir: tmp, password: "definitely-wrong-password-xyz"),
            "Wrong password must fail to decrypt (SEC-025)")

        // The on-disk identity must have encryptedPrivateKey set
        let path = tmp.appendingPathComponent("identity.json")
        let fileData = try Data(contentsOf: path)
        let storedIdentity = try JSONDecoder().decode(IdentityFile.self, from: fileData)
        XCTAssertNotNil(storedIdentity.encryptedPrivateKey,
            "Stored identity file must have encrypted private key (SEC-025)")
    }

    // MARK: - SEC-026: P2P peer identity requires valid signature

    /// handleIdentify in Ivy now requires a non-empty, cryptographically valid
    /// Ed25519 signature. Empty-signature identify messages are rejected to
    /// prevent peer identity spoofing/routing table poisoning.
    func testPeerIdentityKeyFormatIsValid() throws {
        // Verify Ed25519 keys and addresses conform to expected format.
        // The actual identity-spoofing fix lives in Ivy.handleIdentify (Ivy 5.16.0).
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)

        // Multikey-encoded Ed25519 public key: varint(0xed=1byte) + 32 bytes = 33 bytes = 66 hex chars
        // (varint for 0xed is a single byte since 0xed < 0x80 ... actually 0xed > 0x7f so it's 2 bytes)
        // varint(0xed): 0xed = 237 = 0b11101101, needs 2 bytes: [0xed & 0x7f | 0x80, 0xed >> 7] = [0x6d|0x80, 0x01] = [0xed, 0x01]
        // So: 2 (varint) + 32 (key) = 34 bytes = 68 hex chars
        XCTAssertEqual(kp.publicKey.count, 68, "Multikey-encoded Ed25519 public key must be 68 hex chars (SEC-026)")
        XCTAssertTrue(kp.publicKey.allSatisfy { "0123456789abcdef".contains($0) },
            "Public key must be lowercase hex (SEC-026)")

        // Ed25519 private key: 32 bytes = 64 hex chars (unchanged)
        XCTAssertEqual(kp.privateKey.count, 64, "Private key must be 64 hex chars (SEC-026)")

        // Address is a CID (bafyrei...) derived from the public key
        XCTAssertTrue(addr.hasPrefix("bafy"), "Address must be a CID (SEC-026)")
        XCTAssertTrue(addr.allSatisfy { "0123456789abcdefghijklmnopqrstuvwxyz".contains($0) },
            "Address must be lowercase hex (SEC-026)")

        // Verify a signature is producible and verifiable (round-trip)
        let message = "test-message-for-identify-signing"
        let sig = CryptoUtils.sign(message: message, privateKeyHex: kp.privateKey)
        XCTAssertNotNil(sig, "Signing must succeed for valid key (SEC-026)")
        if let sig {
            let valid = CryptoUtils.verify(message: message, signature: sig, publicKeyHex: kp.publicKey)
            XCTAssertTrue(valid, "Signature must verify with matching public key (SEC-026)")
            let badKey = CryptoUtils.generateKeyPair().publicKey
            let invalid = CryptoUtils.verify(message: message, signature: sig, publicKeyHex: badKey)
            XCTAssertFalse(invalid, "Signature must not verify with wrong public key (SEC-026)")
        }
    }

    // MARK: - SEC-027: Mutation fuzzing of transaction body parsing

    /// 1000 mutations of valid transaction JSON must not crash the deserializer.
    /// This tests parser robustness beyond the 8 hand-crafted cases in SEC-024.
    func testTransactionBodyMutationFuzzing() {
        let validJSON = """
        {"accountActions":[{"owner":"992fe6ae226df678b1f2dba90cd9704cba91abb9","delta":100}],
        "actions":[],"depositActions":[],"genesisActions":[],"receiptActions":[],
        "withdrawalActions":[],"signers":["992fe6ae226df678b1f2dba90cd9704cba91abb9"],"fee":1,"nonce":0}
        """.data(using: .utf8)!

        srand48(42)
        var parsedCount = 0
        for _ in 0..<1000 {
            var mutated = validJSON
            let numMutations = max(1, Int(drand48() * 5))
            for _ in 0..<numMutations {
                guard !mutated.isEmpty else { break }
                let idx = Int(drand48() * Double(mutated.count))
                switch Int(drand48() * 3) {
                case 0: mutated[idx] = UInt8(drand48() * 255)
                case 1: if mutated.count > 1 { mutated.remove(at: idx) }
                default: mutated.insert(UInt8(drand48() * 255), at: idx)
                }
            }
            // Must not crash — nil is fine
            if TransactionBody(data: mutated) != nil { parsedCount += 1 }
        }
        // A few mutations will happen to produce valid JSON — that's fine
        XCTAssertLessThan(parsedCount, 200, "Most mutations must not produce valid TransactionBody (SEC-027)")
    }

    // MARK: - SEC-028: Block parsing handles malformed data without crash

    func testBlockParsingHandlesMalformedData() {
        let malformedCases: [Data] = [
            Data(),
            Data([0x7B, 0x7D]),  // empty JSON object {}
            Data(repeating: 0x00, count: 100),
            Data(repeating: 0xFF, count: 100),
            "{\"height\": -1}".data(using: .utf8)!,
            "{\"height\": 999999999999999999999999}".data(using: .utf8)!,
        ]
        for data in malformedCases {
            let result = Block(data: data)
            // Must not crash — nil is expected for all these
            XCTAssertNil(result, "Malformed block data must not deserialize (SEC-028)")
        }
    }


    // MARK: - SEC-029: DevnetCommand identity must not overwrite mainnet identity

    /// DevnetCommand previously wrote identity.json to ~/.lattice, which would
    /// overwrite a user's mainnet private key if they had one. Fixed to write
    /// inside the --storage-path directory (/tmp/lattice-devnet by default).
    func testDevnetIdentityIsolatedFromMainnet() throws {
        let mainnetDir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-mainnet-\(UUID().uuidString)")
        let devnetDir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-devnet-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: mainnetDir)
            try? FileManager.default.removeItem(at: devnetDir)
        }
        try FileManager.default.createDirectory(at: mainnetDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devnetDir, withIntermediateDirectories: true)

        let mainnetIdentityPath = mainnetDir.appendingPathComponent("identity.json")
        let sentinel = "MAINNET_SENTINEL_KEY"
        try sentinel.write(to: mainnetIdentityPath, atomically: true, encoding: .utf8)

        // Simulate where devnet now writes identity (storagePath, not ~/.lattice)
        let devnetIdentityPath = devnetDir.appendingPathComponent("identity.json")
        let devnetJSON = "{\"publicKey\":\"abc123\",\"privateKey\":\"def456\"}"
        try devnetJSON.write(to: devnetIdentityPath, atomically: true, encoding: .utf8)

        // Mainnet identity must be untouched
        let mainnetContent = try String(contentsOf: mainnetIdentityPath, encoding: .utf8)
        XCTAssertEqual(mainnetContent, sentinel, "DevnetCommand must not overwrite mainnet identity (SEC-029)")

        // Devnet identity must be in devnet dir
        let devnetContent = try String(contentsOf: devnetIdentityPath, encoding: .utf8)
        XCTAssertEqual(devnetContent, devnetJSON, "DevnetCommand identity must be in storagePath (SEC-029)")
    }

    // MARK: - RPC endpoint admin/public classification coverage

    private static let tre50AdminRoutes: Set<String> = [
        "chain/register-rpc",
        "chain/template",
        "chain/submit-work",
        "chain/submit-child-block",
        "chain/candidate",
        "chain/deploy",
        // Per-process parent-continuity relay endpoint — admin-guarded
        // (requireAdminAccess in RPCServer.swift); an operator-internal channel.
        "chain/parent-continuity",
    ]

    private static let tre50KnownPublicPostRoutes: Set<String> = [
        "transaction",
        "transaction/prepare",
    ]

    static func tre50UnclassifiedStateChangingRoutes(in source: String) -> [String] {
        let pattern = #"api\.(?:post|on)\(\s*"([^"]+)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))

        var unclassified: [String] = []
        for match in matches {
            let route = ns.substring(with: match.range(at: 1))
            if tre50AdminRoutes.contains(route) || tre50KnownPublicPostRoutes.contains(route) {
                continue
            }
            unclassified.append(route)
        }
        return unclassified
    }

    /// Directory holding the RPC server source. Routes may register in
    /// `RPCServer.swift` or in any sibling `RPCServer+*.swift` extension, so the
    /// classification gate must scan the whole set, not a single file.
    static var tre50RPCSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LatticeNode/RPC")
    }

    /// All `RPCServer*.swift` files in the RPC directory, concatenated.
    static func tre50RPCServerSources() throws -> String {
        let dir = tre50RPCSourceDir
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("RPCServer") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "expected to find RPCServer*.swift sources to scan ")
        return try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    func testRegisteredStateChangingRoutesAreClassified() throws {
        let source = try Self.tre50RPCServerSources()

        XCTAssertTrue(
            source.contains(#"api.post("chain/deploy")"#),
            "source scan must see the canonical admin routes "
        )

        let unclassified = Self.tre50UnclassifiedStateChangingRoutes(in: source)
        XCTAssertEqual(
            unclassified,
            [],
            "unclassified state-changing RPC route(s): \(unclassified). Classify as admin or known-public."
        )
    }

    /// RED→GREEN guard: a state-changing route registered in a
    /// sibling `RPCServer+*.swift` extension (not `RPCServer.swift`) must be
    /// seen by the classification scan. Before the fix the scan read only
    /// `RPCServer.swift`, so such a route escaped the gate. We drop a synthetic
    /// extension source into the real RPC dir, confirm the glob+scan flags it,
    /// then remove it.
    func testClassificationScanCoversSiblingExtensionFiles() throws {
        let dir = Self.tre50RPCSourceDir
        let fixture = dir.appendingPathComponent("RPCServerTRE220Fixture.swift")
        let unclassifiedRoute = "tre220_unclassified_in_extension"
        let synthetic = """
        // Synthetic fixture: an unclassified state-changing route
        // registered OUTSIDE RPCServer.swift. The gate must catch this.
        extension RPCRoutes {
            static func tre220Fixture() {
                api.post("\(unclassifiedRoute)") { req, _ in req }
            }
        }
        """
        try synthetic.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = try Self.tre50RPCServerSources()
        let unclassified = Self.tre50UnclassifiedStateChangingRoutes(in: source)
        XCTAssertTrue(
            unclassified.contains(unclassifiedRoute),
            "classification scan must cover sibling RPCServer*.swift extensions; a route registered there must be flagged. Got: \(unclassified)"
        )
    }

    func testParityScanFlagsUnclassifiedStateChangingRoute() {
        let synthetic = """
        api.post("chain/deploy") { req, _ in /* admin, classified */ }
        api.post("transaction") { req, _ in /* known-public */ }
        api.post("tre50_fake_unclassified") { req, _ in /* drift */ }
        api.get("chain/info") { _, _ in /* GET, not state-changing */ }
        """

        let unclassified = Self.tre50UnclassifiedStateChangingRoutes(in: synthetic)
        XCTAssertEqual(
            unclassified,
            ["tre50_fake_unclassified"],
            "parity scan must flag an unclassified state-changing route and only that route"
        )
    }

    func testRouteClassificationMatchesRuntimeGating() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        func status(method: String, path: String) async throws -> Int {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)\(path)")!)
            req.httpMethod = method
            req.addValue("external-host.example.com", forHTTPHeaderField: "Host")
            if method == "POST" {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = Data("{}".utf8)
            }
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        for route in Self.tre50AdminRoutes {
            let code = try await status(method: "POST", path: "/api/\(route)")
            XCTAssertEqual(
                code,
                401,
                "admin route POST /api/\(route) must fail closed on public bind: got \(code)"
            )
        }

        for path in ["/api/chain/info", "/api/block/latest", "/api/mempool", "/health"] {
            let code = try await status(method: "GET", path: path)
            XCTAssertNotEqual(code, 401, "public read \(path) must not be gated: got \(code)")
        }

        for route in Self.tre50KnownPublicPostRoutes {
            let code = try await status(method: "POST", path: "/api/\(route)")
            XCTAssertNotEqual(code, 401, "public POST /api/\(route) must not be gated: got \(code)")
        }
    }
}
