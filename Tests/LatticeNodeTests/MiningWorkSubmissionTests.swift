import Foundation
import XCTest
import LatticeMinerCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Lattice
@testable import LatticeNode
import cashew
import LatticeNodeAuth

final class MiningWorkSubmissionTests: XCTestCase {
    private struct TemplateResponse: Decodable {
        let workId: String
        let blockHex: String
        let childBlocks: [String: String]
        let effectiveTarget: String
    }

    private struct SubmitResponse: Decodable {
        let accepted: Bool
        let status: String
        let blockHash: String?
        let height: UInt64?
        let message: String?
    }

    func testSubmitWorkEndpointAcceptsNonceAndRejectsDuplicate() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let template = try await postTemplate(port: fixture.rpcPort, authToken: fixture.authToken)
        XCTAssertFalse(template.workId.isEmpty)

        let accepted = try await postSubmitWork(port: fixture.rpcPort, authToken: fixture.authToken, workId: template.workId, nonce: 1)
        XCTAssertEqual(accepted.httpStatus, 200)
        XCTAssertTrue(accepted.body.accepted)
        XCTAssertEqual(accepted.body.status, MiningWorkSubmissionStatus.accepted.rawValue)
        XCTAssertEqual(accepted.body.height, 1)
        XCTAssertNotNil(accepted.body.blockHash)

        guard let chain = await fixture.node.chain(forPath: ["Nexus"]) else {
            return XCTFail("missing Nexus chain")
        }
        var height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)

        let duplicate = try await postSubmitWork(port: fixture.rpcPort, authToken: fixture.authToken, workId: template.workId, nonce: 1)
        XCTAssertEqual(duplicate.httpStatus, 409)
        XCTAssertFalse(duplicate.body.accepted)
        XCTAssertEqual(duplicate.body.status, MiningWorkSubmissionStatus.duplicate.rawValue)
        height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    func testSubmitWorkRejectsWrongHashWithoutPublishingOrMutatingTip() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let template = try await postTemplate(port: fixture.rpcPort, authToken: fixture.authToken)
        let blockData = try XCTUnwrap(Data(hex: template.blockHex))
        let templateBlock = try XCTUnwrap(Block(data: blockData))
        let sealed = ProofOfWork.withNonce(templateBlock, nonce: 1)
        let sealedCID = try VolumeImpl<Block>(node: sealed).rawCID

        let rejected = try await postSubmitWork(
            port: fixture.rpcPort,
            authToken: fixture.authToken,
            workId: template.workId,
            nonce: 1,
            hash: "deadbeef"
        )
        XCTAssertEqual(rejected.httpStatus, 400)
        XCTAssertFalse(rejected.body.accepted)
        XCTAssertEqual(rejected.body.status, MiningWorkSubmissionStatus.hashMismatch.rawValue)

        guard let chain = await fixture.node.chain(forPath: ["Nexus"]) else {
            return XCTFail("missing Nexus chain")
        }
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 0)

        guard let network = await fixture.node.network(forPath: ["Nexus"]) else {
            return XCTFail("missing Nexus network")
        }
        let owners = await network.diskBroker.owners(root: sealedCID)
        XCTAssertFalse(
            owners.contains("Nexus:1"),
            "wrong-target results must not pin or publish a sealed block as chain storage"
        )
    }

    func testSubmitWorkRejectsStaleWorkAfterTipAdvances() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let staleTemplate = try await postTemplate(port: fixture.rpcPort, authToken: fixture.authToken)
        let accepted = await fixture.node.produceAndSubmitBlock()
        XCTAssertTrue(accepted)

        let stale = try await postSubmitWork(port: fixture.rpcPort, authToken: fixture.authToken, workId: staleTemplate.workId, nonce: 1)
        XCTAssertEqual(stale.httpStatus, 409)
        XCTAssertFalse(stale.body.accepted)
        XCTAssertEqual(stale.body.status, MiningWorkSubmissionStatus.stale.rawValue)

        guard let chain = await fixture.node.chain(forPath: ["Nexus"]) else {
            return XCTFail("missing Nexus chain")
        }
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    func testNodeSubmitWorkRejectsUnknownWorkIdAsMalformed() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let result = await fixture.node.submitWork(
            chainPath: ["Nexus"],
            workId: "bafyreifake-work-id",
            nonce: 1
        )

        XCTAssertEqual(result.status, .malformed)
        guard let chain = await fixture.node.chain(forPath: ["Nexus"]) else {
            return XCTFail("missing Nexus chain")
        }
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 0)
    }

    func testNodeSubmitWorkRejectsWrongChainWithoutMutatingTip() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let template = try await postTemplate(port: fixture.rpcPort, authToken: fixture.authToken)
        let result = await fixture.node.submitWork(
            chainPath: ["Nexus", "MissingChild"],
            workId: template.workId,
            nonce: 1
        )

        XCTAssertEqual(result.status, .wrongChain)
        guard let chain = await fixture.node.chain(forPath: ["Nexus"]) else {
            return XCTFail("missing Nexus chain")
        }
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 0)
    }

    private func startNodeWithRPC() async throws -> (node: LatticeNode, rpcPort: UInt16, authToken: String, shutdown: () -> Void) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false,
                discoveryOnly: true, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()

        let rpcPort = nextTestPort()
        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: cookie)
        let task = Task {
            do {
                try await server.run()
            } catch {
                // Expected when the test fixture tears down the RPC server.
            }
        }
        try await waitForRPCServer(port: rpcPort)

        return (
            node,
            rpcPort,
            cookie.token,
            {
                task.cancel()
                Task {
                    await node.stop()
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
        )
    }

    private func postTemplate(
        port: UInt16,
        authToken: String,
        payload: [String: Any] = [:]
    ) async throws -> TemplateResponse {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/chain/template")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
                return try JSONDecoder().decode(TemplateResponse.self, from: data)
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func postSubmitWork(
        port: UInt16,
        authToken: String,
        workId: String,
        nonce: UInt64,
        hash: String? = nil
    ) async throws -> (httpStatus: Int, body: SubmitResponse) {
        var payload: [String: Any] = [
            "chainPath": ["Nexus"],
            "workId": workId,
            "nonce": nonce
        ]
        if let hash {
            payload["hash"] = hash
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/chain/submit-work")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, try JSONDecoder().decode(SubmitResponse.self, from: data))
    }

}
