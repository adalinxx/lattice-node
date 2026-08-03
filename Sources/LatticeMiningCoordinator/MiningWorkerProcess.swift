import Foundation
import LatticeMinerCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum MiningWorkerProcessError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingExecutable(String)
    case nonzeroExit(status: Int32, stderr: String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .missingExecutable(let path):
            return "missingExecutable(\(path))"
        case .nonzeroExit(let status, let stderr):
            return "nonzeroExit(status: \(status), stderr: \(stderr))"
        case .invalidOutput(let output):
            return "invalidOutput(\(output))"
        }
    }
}

/// Mirror of the `LatticeMiner` worker's stdout `WorkerResult` JSON contract.
struct MiningWorkerProcessResult: Decodable {
    let workId: String
    let status: String
    let nonce: UInt64?
    let rangeStart: UInt64
    let rangeCount: UInt64
}

/// Spawns the `LatticeMiner` worker process for one immutable nonce-range
/// assignment and parses its `WorkerResult` JSON output. The worker takes its
/// assignment as CLI flags (`--workId/--blockHex/--target/--startNonce/--count`)
/// and prints exactly one `WorkerResult` JSON object to stdout.
public struct MiningWorkerProcessClient: Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String] = []) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func search(workerId: String, work: MiningCoordinatorWork, range: NonceSearchRange) async throws -> MiningWorkerResult? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MiningWorkerProcessError.missingExecutable(executableURL.path)
        }

        let handle = MiningWorkerSubprocess()
        let process = handle.process
        process.executableURL = executableURL
        process.arguments = arguments + [
            "--work-id", work.workId,
            "--block-hex", work.blockHex,
            "--target", work.targetHex,
            "--start-nonce", String(range.startNonce),
            "--count", String(range.count),
        ] + (work.prefixHex.isEmpty ? [] : [
            "--prefix-hex", work.prefixHex,
        ])

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain BOTH pipes concurrently (on their own threads), starting before
        // the child exits. A single post-exit read would fill and wedge on
        // whichever pipe exceeds the 64 KB kernel buffer before the child exits
        // — the exact hazard the stdout-only fix left open for stderr (a large
        // worker crash backtrace never drained, the worker blocks in write(),
        // terminationHandler never fires). The drains capture the Pipe so it
        // outlives the read even when we abandon them on the cancel path.
        let stdoutDrain = Task.detached { Self.readToEnd(stdout, cap: 16_384) }
        let stderrDrain = Task.detached { Self.readToEnd(stderr, cap: 4_096) }

        try await handle.run()

        // Close the parent's write-ends so the concurrent reads see EOF; the
        // child owns its own dup'd copies.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        // On cancellation (e.g. stale work) the worker result is irrelevant.
        // Return WITHOUT awaiting the drains: a forked grandchild could hold a
        // write-end open past the worker's SIGKILL, so the reads may never hit
        // EOF. The detached tasks own their Pipe and terminate whenever the
        // write-end finally closes.
        if Task.isCancelled { return nil }

        let output = await stdoutDrain.value
        let errorData = await stderrDrain.value

        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            throw MiningWorkerProcessError.nonzeroExit(status: process.terminationStatus, stderr: errorText)
        }
        guard let result = try? JSONDecoder().decode(MiningWorkerProcessResult.self, from: output) else {
            // Cap the surfaced stdout the same way as stderr: it is forwarded
            // verbatim into the coordinator's single-line stdout that the CLI
            // reads post-exit, so a non-decodable flood must not amplify.
            let capped = output.count > 4096 ? Data(output.suffix(4096)) : output
            throw MiningWorkerProcessError.invalidOutput(String(data: capped, encoding: .utf8) ?? "")
        }
        guard result.status == "found", let nonce = result.nonce else {
            return nil
        }
        return MiningWorkerResult(
            workerId: workerId,
            workId: result.workId,
            nonce: nonce
        )
    }

    /// Blocking drain of a pipe's read-end to EOF, retaining at most `cap`
    /// bytes (it keeps reading and discarding past the cap so the child never
    /// blocks on a full pipe). The `pipe` argument is captured so the drain
    /// keeps it alive across the read — including when the caller abandons this
    /// task on the cancel path. Reading the raw descriptor keeps the detached
    /// task Sendable.
    private static func readToEnd(_ pipe: Pipe, cap: Int) -> Data {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, $0.count)
            }
            if n > 0 {
                if data.count < cap {
                    data.append(contentsOf: buffer[0..<min(n, cap - data.count)])
                }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}

private final class MiningWorkerSubprocess: @unchecked Sendable {
    let process = Process()

    /// How long to wait after SIGTERM before escalating to SIGKILL. Some shells
    /// (e.g. dash `sh -c`) don't reliably propagate SIGTERM to their children,
    /// and on swift-corelibs-foundation a bare `terminate()` does not promptly
    /// reap such a child, so we force-kill after a short grace period.
    private static let terminationGraceNanoseconds: UInt64 = 200_000_000

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didFinish = false
    private var cancelRequested = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Runs the process to completion, resuming off `terminationHandler` rather
    /// than parking a thread on the synchronous `waitUntilExit()`. On task
    /// cancellation it sends SIGTERM and escalates to SIGKILL after a short
    /// grace so the child is reaped promptly and reliably across platforms.
    func run() async throws {
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        try process.run()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow = withLock { () -> Bool in
                    if didFinish { return true }
                    continuation = cont
                    return false
                }
                if resumeNow {
                    cont.resume()
                }
            }
        } onCancel: {
            requestTermination()
        }
    }

    private func finish() {
        let cont = withLock { () -> CheckedContinuation<Void, Never>? in
            let pending = continuation
            continuation = nil
            didFinish = true
            return pending
        }
        cont?.resume()
    }

    private func requestTermination() {
        let proceed = withLock { () -> Bool in
            if cancelRequested || didFinish { return false }
            cancelRequested = true
            return true
        }
        guard proceed else { return }

        // SIGTERM first; the terminationHandler will resume the continuation if
        // the child exits in response.
        if process.isRunning {
            process.terminate()
        }

        // Escalate to SIGKILL after a grace period for children that ignore or
        // don't propagate SIGTERM. Detached so the cancel handler returns
        // immediately.
        let pid = process.processIdentifier
        Task.detached { [weak self] in
            try? await Task.sleep(
                nanoseconds: MiningWorkerSubprocess.terminationGraceNanoseconds
            )
            guard let self else { return }
            let finished = self.withLock { self.didFinish }
            if !finished, self.process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

extension MiningCoordinatorWorker {
    public static func process(
        id: String,
        executableURL: URL,
        arguments: [String] = []
    ) -> MiningCoordinatorWorker {
        let client = MiningWorkerProcessClient(executableURL: executableURL, arguments: arguments)
        return MiningCoordinatorWorker(id: id) { work, range in
            try await client.search(workerId: id, work: work, range: range)
        }
    }
}
