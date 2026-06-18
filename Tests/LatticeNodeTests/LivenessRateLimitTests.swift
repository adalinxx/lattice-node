import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth

/// RPC-A2: the liveness endpoints /health and /metrics must NOT be a free
/// amplification surface — they are subject to the same per-IP rate limiter as
/// every other route. A flood past the limit gets 429, while normal monitoring
/// (a few probes well under the burst) stays 200. Driven through the REAL
/// URLSession → middleware chain → route, never a private helper.
final class LivenessRateLimitTests: XCTestCase {

    private func makeNode(rps: Int, burst: Int, _ tmp: URL) async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let resources = NodeResourceConfig(rpcRequestsPerSecond: rps, rpcBurstSize: burst)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp,
            enableLocalDiscovery: false, resources: resources, minPeerKeyBits: 0
        )
        return try await LatticeNode(config: config, genesisConfig: testGenesis())
    }

    private func withRunningRPCNode(
        rps: Int,
        burst: Int,
        _ body: (URL) async throws -> Void
    ) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let node = try await makeNode(rps: rps, burst: burst, tmp)
            try await node.start()

            let rpcPort = nextTestPort()
            let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
            let serverTask = Task { try await server.run() }
            let cleanup: () async -> Void = {
                await server.shutdown()
                serverTask.cancel()
                await Task.yield()
                await node.stop()
                try? FileManager.default.removeItem(at: tmp)
            }

            do {
                try await waitForRPCServer(port: rpcPort)
                try await body(URL(string: "http://127.0.0.1:\(rpcPort)")!)
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Flooding /health past the per-IP limit must yield 429. RED if /health
    /// bypasses the rate-limit middleware (unbounded liveness amplification).
    func testHealthFloodReturns429() async throws {
        try await withRunningRPCNode(rps: 1, burst: 2) { baseURL in
            let url = baseURL.appendingPathComponent("health")
            var sawThrottle = false
            for _ in 0..<20 {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 429 { sawThrottle = true; break }
            }
            XCTAssertTrue(sawThrottle, "a /health flood must be rate-limited with HTTP 429 (liveness is not a free amplification surface)")
        }
    }

    /// Flooding /metrics past the per-IP limit must yield 429.
    func testMetricsFloodReturns429() async throws {
        try await withRunningRPCNode(rps: 1, burst: 2) { baseURL in
            let url = baseURL.appendingPathComponent("metrics")
            var sawThrottle = false
            for _ in 0..<20 {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 429 { sawThrottle = true; break }
            }
            XCTAssertTrue(sawThrottle, "a /metrics flood must be rate-limited with HTTP 429")
        }
    }

    /// Liveness under load: normal monitoring (a couple of probes, well under the
    /// burst) is served 200 — the limiter throttles abuse, not ordinary scraping.
    func testNormalMonitoringStaysUnderBurst() async throws {
        // Generous burst so a handful of monitoring probes never trip the limit.
        try await withRunningRPCNode(rps: 50, burst: 100) { baseURL in
            for path in ["health", "metrics"] {
                let url = baseURL.appendingPathComponent(path)
                for _ in 0..<3 {
                    let (_, response) = try await URLSession.shared.data(from: url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    XCTAssertEqual(status, 200, "/\(path) must serve normal monitoring under the burst (got \(status))")
                }
            }
        }
    }
}
