import XCTest
import Hummingbird
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
import UInt256

final class MergedMiningTemplateTargetTests: XCTestCase {
    private actor CandidateCounter {
        private var value = 0

        func next() -> Int {
            value += 1
            return value
        }

        func count() -> Int {
            value
        }
    }

    private struct TemplateResponse: Decodable {
        let childBlocks: [String: String]
        let effectiveTarget: String
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        let data = try JSONEncoder().encode(value)
        return Response(status: .ok, body: .init(byteBuffer: .init(data: data)))
    }

    private func postTemplate(
        parentPort: UInt16,
        parentToken: String,
        childPort: UInt16,
        childToken: String
    ) async throws -> TemplateResponse {
        let childURL = "http://127.0.0.1:\(childPort)/api"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(parentPort)/api/chain/template")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(parentToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "childNodes": [childURL],
            "childNodeAuth": ["\(childURL)/": childToken]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
        return try JSONDecoder().decode(TemplateResponse.self, from: data)
    }

    private func withTemplateServers(
        childTarget: UInt256,
        _ body: (UInt16, String, UInt16, String, UInt256, CandidateCounter) async throws -> Void
    ) async throws {
        let parentKeyPair = CryptoUtils.generateKeyPair()
        let parentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let parentDifficulty = UInt256(1_000)
        let genesis = GenesisConfig(
            spec: testSpec(),
            timestamp: now() - 10_000,
            target: parentDifficulty
        )
        let parentNode = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: parentKeyPair.publicKey,
                privateKey: parentKeyPair.privateKey,
                listenPort: nextTestPort(),
                storagePath: parentDir,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: genesis
        )
        try await parentNode.start()

        let parentRPCPort = nextTestPort()
        let parentCookie = try CookieAuth.generate(at: parentDir.appendingPathComponent(".cookie"))
        let parentServer = RPCServer(node: parentNode, port: parentRPCPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: parentCookie)
        let parentTask = Task { try await parentServer.run() }

        let childFetcher = cas()
        let childSpec = testSpec("Child")
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec,
            timestamp: now() - 10_000,
            target: parentDifficulty,
            fetcher: childFetcher
        )
        let childPort = nextTestPort()
        let router = Router()
        let candidateCounter = CandidateCounter()
        router.get("api/chain/info") { _, _ in
            struct ChainInfo: Encodable {
                struct Chain: Encodable {
                    let directory: String
                    let parentDirectory: String?
                }
                let chains: [Chain]
            }
            return try Self.jsonResponse(ChainInfo(chains: [.init(directory: "Child", parentDirectory: "Nexus")]))
        }
        let childToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        router.post("api/chain/candidate") { request, _ in
            struct CandidateVolume: Decodable { let root: String; let entries: [String: String] }
            struct CandidateBody: Decodable {
                let parentBlockHex: String?
                let parentHomesteadVolume: CandidateVolume?
            }
            struct CandidateResponse: Encodable { let directory: String; let blockHex: String }
            guard request.headers[.authorization] == "Bearer \(childToken)" else {
                return Response(status: .unauthorized)
            }
            let candidateBody = try? await JSONDecoder().decode(
                CandidateBody.self,
                from: request.body.collect(upTo: 4_194_304)
            )
            let parentBlock = candidateBody?.parentBlockHex
                .flatMap { Data(hex: $0) }
                .flatMap { Block(data: $0) }
            let homesteadRoot = parentBlock?.prevState.rawCID
            XCTAssertEqual(candidateBody?.parentHomesteadVolume?.root, homesteadRoot)
            if let homesteadRoot {
                XCTAssertNotNil(candidateBody?.parentHomesteadVolume?.entries[homesteadRoot])
            }
            let sequence = await candidateCounter.next()
            let childBlock = try await BlockBuilder.buildBlock(
                previous: childGenesis,
                parentChainBlock: parentBlock,
                timestamp: now() + Int64(sequence),
                target: childTarget,
                nextTarget: childTarget,
                nonce: UInt64(sequence),
                fetcher: childFetcher
            )
            let blockData = try XCTUnwrap(childBlock.toData())
            return try Self.jsonResponse(CandidateResponse(directory: "Child", blockHex: Self.hex(blockData)))
        }
        let childApp = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: Int(childPort)))
        )
        let childTask = Task { try await childApp.run() }

        defer {
            parentTask.cancel()
            childTask.cancel()
            Task { await parentNode.stop() }
        }
        try await Task.sleep(for: .milliseconds(300))

        try await body(parentRPCPort, parentCookie.token, childPort, childToken, parentDifficulty, candidateCounter)
    }

    func testTemplateUsesEasiestEmbeddedChildTarget() async throws {
        let easyChildTarget = UInt256(10_000)
        try await withTemplateServers(childTarget: easyChildTarget) { parentPort, parentToken, childPort, childToken, _, _ in
            let template = try await postTemplate(parentPort: parentPort, parentToken: parentToken, childPort: childPort, childToken: childToken)

            XCTAssertNotNil(template.childBlocks["Child"], "child candidate should still be returned for embedding")
            XCTAssertEqual(template.effectiveTarget, easyChildTarget.toHexString())
        }
    }

    func testTemplateDoesNotLowerTargetForHarderChildTarget() async throws {
        try await withTemplateServers(childTarget: UInt256(1)) { parentPort, parentToken, childPort, childToken, parentDifficulty, _ in
            let template = try await postTemplate(parentPort: parentPort, parentToken: parentToken, childPort: childPort, childToken: childToken)

            XCTAssertNotNil(template.childBlocks["Child"], "child candidate should still be returned for embedding")
            XCTAssertEqual(template.effectiveTarget, parentDifficulty.toHexString())
        }
    }

    func testRecursiveTemplatePollsRefreshChildCandidates() async throws {
        try await withTemplateServers(childTarget: UInt256(10_000)) { parentPort, parentToken, childPort, childToken, _, candidateCounter in
            let first = try await postTemplate(parentPort: parentPort, parentToken: parentToken, childPort: childPort, childToken: childToken)
            let second = try await postTemplate(parentPort: parentPort, parentToken: parentToken, childPort: childPort, childToken: childToken)

            let candidateCount = await candidateCounter.count()
            XCTAssertEqual(candidateCount, 2, "recursive template polls must not be served from the parent-only template cache")
            XCTAssertNotEqual(first.childBlocks["Child"], second.childBlocks["Child"], "the second poll should embed the refreshed child candidate")
        }
    }
}
