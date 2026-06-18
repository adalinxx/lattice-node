import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import LatticeMiningCoordinator
import LatticeMinerCore
import LatticeNodeAuth

final class MiningCoordinatorEndToEndTests: XCTestCase {
    func testCoordinatorProcessFansOutWorkerProcessesAndNodeAcceptsSolution() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let executables = try miningProcessProducts()
        let output = try runProcess(
            executableURL: executables.coordinator,
            arguments: [
                "--node", fixture.apiBaseURL.absoluteString,
                "--worker-executable", executables.worker.path,
                "--workers", "2",
                "--batch-size", "128",
                "--rpc-cookie-file", fixture.cookieFile.path,
                "--once",
                "--no-stale-probe",
            ],
            timeout: 10
        )
        let response = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any]
        XCTAssertEqual(response?["result"] as? String, "submitted")
        XCTAssertTrue(response?["accepted"] as? Bool ?? false, "node-owned submit-work path must accept the coordinator result")
        XCTAssertEqual(response?["status"] as? String, MiningWorkSubmissionStatus.accepted.rawValue)
        XCTAssertEqual(response?["height"] as? Int, 1)
        XCTAssertNotNil(response?["blockHash"] as? String)
        XCTAssertLessThan(response?["nonce"] as? Int ?? 128, 128)

        let chain = try await nexusChain(fixture.node)
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    func testCoordinatorLandsBlockWithStaleProbeEnabled() async throws {
        // Full path with the stale probe ENABLED (the default). Proves the node
        // emits a stable staleToken (tip hash) so the probe doesn't false-positive
        // on the workId churn — the template timestamp is restamped to now on every
        // fetch, so the candidate CID (workId) changes each time. Before the
        // staleToken fix this aborted every solution as stale and never landed a
        // block (the smoke-suite symptom). No --no-stale-probe here.
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let executables = try miningProcessProducts()
        let output = try runProcess(
            executableURL: executables.coordinator,
            arguments: [
                "--node", fixture.apiBaseURL.absoluteString,
                "--worker-executable", executables.worker.path,
                "--workers", "2",
                "--batch-size", "128",
                "--rpc-cookie-file", fixture.cookieFile.path,
                "--once",
            ],
            timeout: 10
        )
        let response = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any]
        XCTAssertEqual(response?["result"] as? String, "submitted")
        XCTAssertTrue(response?["accepted"] as? Bool ?? false, "stale probe must not false-positive on workId churn")
        XCTAssertEqual(response?["status"] as? String, MiningWorkSubmissionStatus.accepted.rawValue)
        XCTAssertEqual(response?["height"] as? Int, 1)

        let chain = try await nexusChain(fixture.node)
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    func testCoordinatorCLIFailsClosedWhenRPCTokenIsWrong() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let executables = try miningProcessProducts()
        let output = try runProcess(
            executableURL: executables.coordinator,
            arguments: [
                "--node", fixture.apiBaseURL.absoluteString,
                "--worker-executable", executables.worker.path,
                "--workers", "1",
                "--batch-size", "1",
                "--rpc-token", "wrong-token",
                "--once",
            ],
            timeout: 10,
            expectSuccess: false
        )

        XCTAssertNotEqual(output.status, 0)
        XCTAssertFalse(String(data: output.stdout, encoding: .utf8)?.contains("backoff") ?? false)
        let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("node RPC failed"), stderr)
        XCTAssertTrue(stderr.contains("unauthorized"), stderr)
    }

    func testCoordinatorCancelsStaleWorkAndNodeRejectsOldResult() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let httpClient = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: fixture.apiBaseURL,
            authToken: fixture.authToken
        )
        let advancingClient = AdvancingNodeClient(inner: httpClient, node: fixture.node)
        let slowWorker = MiningCoordinatorWorker(id: "slow-worker") { work, _ in
            try? await Task.sleep(for: .milliseconds(150))
            return MiningWorkerResult(workerId: "slow-worker", workId: work.workId, nonce: 0)
        }
        let coordinator = MiningCoordinator(
            nodeClient: advancingClient,
            workers: [slowWorker],
            totalBatchSize: 1,
            staleProbeEnabled: true
        )

        let result = await coordinator.runBatch()

        guard case .stale(let workId) = result else {
            return XCTFail("expected stale cancellation after node tip advanced, got \(result)")
        }
        let maybeOriginalWorkId = await advancingClient.firstWorkId()
        let originalWorkId = try XCTUnwrap(maybeOriginalWorkId)
        XCTAssertEqual(workId, originalWorkId)
        let submissionCount = await advancingClient.submissionCount()
        XCTAssertEqual(submissionCount, 0, "coordinator must not submit old worker results")

        let oldResult = try await httpClient.submit(workId: originalWorkId, nonce: 0, hash: nil)
        XCTAssertFalse(oldResult.accepted)
        XCTAssertEqual(oldResult.status, MiningWorkSubmissionStatus.stale.rawValue)

        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.staleAbortCount, 1)
        XCTAssertEqual(metrics.acceptedSolutionCount, 0)
        XCTAssertEqual(metrics.rejectedSolutionCount, 0)

        let chain = try await nexusChain(fixture.node)
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    private func miningProcessProducts() throws -> (coordinator: URL, worker: URL) {
        let root = try repoRoot()
        let buildDirectory = root.appendingPathComponent(".build/debug")
        let coordinator = buildDirectory.appendingPathComponent("LatticeMiningCoordinatorTool")
        let worker = buildDirectory.appendingPathComponent("LatticeMiner")
        if !FileManager.default.isExecutableFile(atPath: coordinator.path) ||
            !FileManager.default.isExecutableFile(atPath: worker.path) {
            throw NSError(domain: "MiningCoordinatorEndToEndTests", code: 3)
        }
        return (coordinator, worker)
    }

    private struct ProcessOutput {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        expectSuccess: Bool = true
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }
        let output = ProcessOutput(
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
            status: process.terminationStatus
        )
        if expectSuccess {
            XCTAssertEqual(
                output.status,
                0,
                String(data: output.stderr, encoding: .utf8) ?? "process failed"
            )
        }
        return output
    }

    private actor AdvancingNodeClient: MiningCoordinatorNodeClient {
        private let inner: HTTPMiningCoordinatorNodeClient
        private let node: LatticeNode
        private var fetchCount = 0
        private var firstWork: String?
        private var submissions = 0

        init(inner: HTTPMiningCoordinatorNodeClient, node: LatticeNode) {
            self.inner = inner
            self.node = node
        }

        func fetchWork() async throws -> MiningCoordinatorWork? {
            fetchCount += 1
            if fetchCount == 2 {
                _ = await node.produceAndSubmitBlock()
            }
            let work = try await inner.fetchWork()
            if firstWork == nil {
                firstWork = work?.workId
            }
            return work
        }

        func submit(workId: String, nonce: UInt64, hash: String?) async throws -> MiningSolutionSubmission {
            submissions += 1
            return try await inner.submit(workId: workId, nonce: nonce, hash: hash)
        }

        func firstWorkId() -> String? { firstWork }
        func submissionCount() -> Int { submissions }
    }

    private func startNodeWithRPC() async throws -> (
        node: LatticeNode,
        apiBaseURL: URL,
        authToken: String,
        cookieFile: URL,
        shutdown: () -> Void
    ) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()

        let rpcPort = nextTestPort()
        let cookieFile = tmp.appendingPathComponent(".cookie")
        let cookie = try CookieAuth.generate(at: cookieFile)
        let server = RPCServer(
            node: node,
            port: rpcPort,
            bindAddress: "127.0.0.1",
            allowedOrigin: "*",
            auth: cookie
        )
        let task = Task { try await server.run() }
        try await waitForRPCServer(port: rpcPort)

        return (
            node,
            URL(string: "http://127.0.0.1:\(rpcPort)/api")!,
            cookie.token,
            cookieFile,
            {
                task.cancel()
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    await node.stop()
                    semaphore.signal()
                }
                semaphore.wait()
                try? FileManager.default.removeItem(at: tmp)
            }
        )
    }

    private func nexusChain(_ node: LatticeNode) async throws -> ChainState {
        guard let chain = await node.chain(forPath: ["Nexus"]) else {
            throw NSError(domain: "MiningCoordinatorEndToEndTests", code: 2)
        }
        return chain
    }

    private func repoRoot() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
        while current.path != "/" {
            let packageFile = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageFile.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw NSError(domain: "MiningCoordinatorEndToEndTests", code: 1)
    }

    private func readTree(_ directory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        return try files
            .sorted { $0.path < $1.path }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}

final class MiningCoordinatorSourceBoundaryTests: XCTestCase {
    func testCoordinatorAndWorkerCoreTargetsKeepMiningBoundariesNarrow() throws {
        let root = try repoRoot()
        let coordinator = try readTree(root.appendingPathComponent("Sources/LatticeMiningCoordinator"))
        let coordinatorCLI = try readTree(root.appendingPathComponent("Sources/LatticeMiningCoordinatorTool"))
        let processWorker = try readTree(root.appendingPathComponent("Sources/LatticeMiner"))
        let workerCore = try readTree(root.appendingPathComponent("Sources/LatticeMinerCore"))

        for (name, source) in [
            ("LatticeMiner", processWorker),
            ("LatticeMinerCore", workerCore),
        ] {
            assertNotContains(source, workerBannedNeedles, target: name)
        }
        for (name, source) in [
            ("LatticeMiningCoordinator", coordinator),
            ("LatticeMiningCoordinatorTool", coordinatorCLI),
        ] {
            assertNotContains(source, coordinatorBannedNeedles, target: name)
        }
    }

    func testCoordinatorCLIFailsClosedWhenWorkerExecutableIsMissing() throws {
        let coordinator = try miningProcessCoordinator()
        let output = try runProcess(
            executableURL: coordinator,
            arguments: [
                "--node", "http://127.0.0.1:1/api",
                "--worker-executable", "/definitely/missing",
                "--once",
            ],
            timeout: 5
        )

        XCTAssertNotEqual(output.status, 0)
        XCTAssertFalse(String(data: output.stdout, encoding: .utf8)?.contains("noSolution") ?? false)
        XCTAssertTrue(String(data: output.stderr, encoding: .utf8)?.contains("not executable") ?? false)
    }

    func testCoordinatorCLIFailsClosedWhenCookieFileIsMissing() throws {
        let coordinator = try miningProcessCoordinator()
        let output = try runProcess(
            executableURL: coordinator,
            arguments: [
                "--node", "http://127.0.0.1:1/api",
                "--worker-executable", "/bin/sh",
                "--rpc-cookie-file", "/definitely/missing.cookie",
                "--once",
            ],
            timeout: 5
        )

        XCTAssertNotEqual(output.status, 0)
        XCTAssertFalse(String(data: output.stdout, encoding: .utf8)?.contains("backoff") ?? false)
        XCTAssertTrue(String(data: output.stderr, encoding: .utf8)?.contains("not readable") ?? false)
    }

    private var workerBannedNeedles: [String] {
        [
            "import Ivy",
            "broadcastMessage",
            "ChildBlockProof",
            "childNode",
            "childNodes",
            "minerPrivateKey",
            "minerPrivate",
            "privateKeyHex",
        ]
    }

    private var coordinatorBannedNeedles: [String] {
        [
            "import Ivy",
            "broadcastMessage",
            "ChildBlockProof",
            "minerPrivateKey",
            "minerPrivate",
            "privateKeyHex",
        ]
    }

    private func miningProcessCoordinator() throws -> URL {
        let coordinator = try repoRoot()
            .appendingPathComponent(".build/debug")
            .appendingPathComponent("LatticeMiningCoordinatorTool")
        if !FileManager.default.isExecutableFile(atPath: coordinator.path) {
            throw NSError(domain: "MiningCoordinatorSourceBoundaryTests", code: 4)
        }
        return coordinator
    }

    private struct ProcessOutput {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }
        return ProcessOutput(
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
            status: process.terminationStatus
        )
    }

    private func repoRoot() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
        while current.path != "/" {
            let packageFile = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageFile.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw NSError(domain: "MiningCoordinatorSourceBoundaryTests", code: 1)
    }

    private func readTree(_ directory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        return try files
            .sorted { $0.path < $1.path }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func assertNotContains(
        _ haystack: String,
        _ needles: [String],
        target: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for needle in needles {
            XCTAssertFalse(
                haystack.contains(needle),
                "\(target) must not contain \(needle)",
                file: file,
                line: line
            )
        }
    }
}
