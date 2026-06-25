import XCTest
import Hummingbird
import LatticeNodeRPCFuzzSupport
@testable import LatticeNode
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Regression for the merged-mining `childNodes` URL validator. The hardening in
/// commit 5bb44cb over-constrained `validHTTPBaseURL` to reject any non-root
/// path, but the node addresses child nodes as "<base>/api" and then appends
/// "/chain/info" / "/chain/candidate" — so the `/api` base must validate, while
/// the loopback / no-credential / no-traversal guarantees must stay intact.
final class ChildNodeURLValidationTests: XCTestCase {
    private actor RequestCounter {
        private var value = 0

        func increment() {
            value += 1
        }

        func count() -> Int {
            value
        }
    }

    func testMiningChildFanoutSessionHasFiniteTimeouts() {
        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, RPCRoutes.childFanoutRequestTimeout)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, RPCRoutes.childFanoutResourceTimeout)
    }

    func testMiningChildFanoutSessionDoesNotFollowRedirects() async throws {
        let port = nextTestPort()
        let followed = RequestCounter()
        let router = Router()
        router.get("redirect") { _, _ in
            Response(
                status: .temporaryRedirect,
                headers: [.location: "http://127.0.0.1:\(port)/followed"]
            )
        }
        router.get("followed") { _, _ in
            await followed.increment()
            return Response(status: .ok)
        }
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: Int(port)))
        )
        let task = Task { try await app.run() }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/redirect")!)

        let followedCount = await followed.count()
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        XCTAssertEqual(followedCount, 0)
    }

    func testRegisteredRPCProxyDoesNotFollowRedirects() async throws {
        let targetPort = nextTestPort()
        let proxyPort = nextTestPort()
        let followed = RequestCounter()
        let targetRouter = Router()
        targetRouter.get("api/chain/info") { _, _ in
            Response(
                status: .temporaryRedirect,
                headers: [.location: "http://127.0.0.1:\(targetPort)/followed"]
            )
        }
        targetRouter.get("followed") { _, _ in
            await followed.increment()
            return Response(status: .ok)
        }
        let targetApp = Application(
            router: targetRouter,
            configuration: .init(address: .hostname("127.0.0.1", port: Int(targetPort)))
        )
        let targetTask = Task { try await targetApp.run() }
        defer { targetTask.cancel() }

        let proxyRouter = Router()
        proxyRouter.get("api/chain/info") { request, _ in
            await RPCRoutes.proxyRegisteredRPC(
                endpoint: "http://127.0.0.1:\(targetPort)/api",
                request: request,
                authToken: "child-token"
            )
        }
        let proxyApp = Application(
            router: proxyRouter,
            configuration: .init(address: .hostname("127.0.0.1", port: Int(proxyPort)))
        )
        let proxyTask = Task { try await proxyApp.run() }
        defer { proxyTask.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(proxyPort)/api/chain/info")!
        )

        let followedCount = await followed.count()
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        XCTAssertEqual(followedCount, 0)
    }

    func testAcceptsApiBasePathOnLoopback() {
        XCTAssertTrue(RPCRequestBodyCodecs.validLoopbackHTTPBaseURL("http://127.0.0.1:8000/api"))
        XCTAssertTrue(RPCRequestBodyCodecs.validLoopbackHTTPBaseURL("http://localhost:8000/api"))
        // Bare base and root path remain valid.
        XCTAssertTrue(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000"))
        XCTAssertTrue(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/"))
    }

    func testAcceptsMultiSegmentCanonicalPath() {
        // The contract is a base URL, not specifically "/api": any canonical
        // segment path is fine (the node just appends "/chain/..." to it).
        XCTAssertTrue(RPCRequestBodyCodecs.validLoopbackHTTPBaseURL("http://127.0.0.1:8000/api/v1"))
        XCTAssertTrue(RPCRequestBodyCodecs.validLoopbackHTTPBaseURL("http://127.0.0.1:8000/lattice-node_1"))
    }

    func testStillRejectsNonLoopbackAndUnsafeURLs() {
        // SSRF: non-loopback host is rejected regardless of path (the regression
        // must not reopen the metadata-endpoint hole).
        XCTAssertFalse(RPCRequestBodyCodecs.validLoopbackHTTPBaseURL("http://169.254.169.254/api"))
        XCTAssertFalse(RPCRequestBodyCodecs.validLoopbackHTTPBaseURL("http://169.254.169.254/latest/meta-data"))
        // Credentials, query, fragment, and non-http schemes stay rejected.
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://user:pass@127.0.0.1:8000/api"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api?x=1"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api#frag"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("ftp://127.0.0.1:8000/api"))
    }

    func testRejectsNonCanonicalAndTraversalPaths() {
        // Trailing slash and double slash would make "<base>/chain/info"
        // concatenation produce non-canonical routes ("/api//chain/info").
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api/"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000//api"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api//v1"))
        // Path traversal — raw and percent-encoded — and a bare dot segment.
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/../admin"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api/.."))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api/%2e%2e"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/."))
        // Percent-encoding (incl. encoded slash) is rejected outright.
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/api%2Fx"))
        XCTAssertFalse(RPCRequestBodyCodecs.validHTTPBaseURL("http://127.0.0.1:8000/a b"))
    }
}
