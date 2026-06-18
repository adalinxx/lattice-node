import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Process-per-chain supervisor (step 1). A parent LatticeNode owns one
// ChildProcessSupervisor and uses it to spawn + supervise the child-chain OS
// processes beneath it: launch, restart-on-unexpected-exit, and quiesce-the-subtree.
// See docs/design/process-supervisor.md.
//
// The supervisor itself is deliberately GENERIC over `SupervisedLaunch` (an
// executable + argv) so it can be unit-tested against stub processes; the
// lattice-node-specific argument vector lives in `ChildSpec`.

/// A single thing to launch and supervise.
public struct SupervisedLaunch: Sendable {
    /// Stable key for this child (the chain directory, in production).
    public let label: String
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?

    public init(label: String, executableURL: URL, arguments: [String], environment: [String: String]? = nil) {
        self.label = label
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

public actor ChildProcessSupervisor {
    public struct Policy: Sendable {
        /// Maximum automatic restarts after an unexpected (non-zero) exit before giving up.
        public var maxRestarts: Int
        /// Backoff before re-spawning a crashed child (floored, see `minRestartBackoffSeconds`).
        public var restartBackoffSeconds: Double
        /// Grace period between SIGTERM and SIGKILL during quiesce/stop.
        public var quiesceGraceSeconds: Double

        public init(maxRestarts: Int = 5, restartBackoffSeconds: Double = 1.0, quiesceGraceSeconds: Double = 3.0) {
            self.maxRestarts = maxRestarts
            self.restartBackoffSeconds = restartBackoffSeconds
            self.quiesceGraceSeconds = quiesceGraceSeconds
        }
    }

    /// Hard floor on restart backoff, even if the policy asks for less, so a
    /// child that exits instantly can never become a tight spawn loop.
    private static let minRestartBackoffSeconds = 0.1

    private struct Entry {
        let launch: SupervisedLaunch
        var process: Process
        var restarts: Int
        /// Monotonic id distinguishing this launch from any prior one for the
        /// same label, so a stale terminationHandler can't mutate a newer process.
        var generation: UInt64
        var stopping: Bool
    }

    private let policy: Policy
    private let log = NodeLogger("supervisor")
    private var entries: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    /// Set once quiesced — refuses further spawns/restarts.
    private var closed = false

    public init(policy: Policy = .init()) {
        self.policy = policy
    }

    /// Best-effort resolution of THIS process's own executable, so the whole
    /// chain tree runs one binary. Tests inject an explicit URL instead.
    public static func selfExecutableURL() -> URL {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let end = buffer.firstIndex(of: 0) ?? buffer.count
                let pathBytes = buffer.prefix(end).map { UInt8(bitPattern: $0) }
                return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self)).resolvingSymlinksInPath()
            }
        }
        #elseif canImport(Glibc)
        if let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            return URL(fileURLWithPath: path)
        }
        #endif
        if let exe = Bundle.main.executableURL { return exe }
        let arg0 = CommandLine.arguments.first ?? "lattice-node"
        if arg0.hasPrefix("/") { return URL(fileURLWithPath: arg0) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(arg0)
    }

    /// Launch and start supervising. If a child with the same label is already
    /// running it is stopped first, so we never orphan a live process or let two
    /// processes contend for the same deterministic ports.
    @discardableResult
    public func spawn(_ launch: SupervisedLaunch) async throws -> Int32 {
        guard !closed else { throw SupervisorError.closed }
        if entries[launch.label] != nil { await stop(label: launch.label) }
        return try startProcess(launch, restarts: 0)
    }

    /// Stop one child without restarting it (e.g. an undeployed chain, or a
    /// replace-on-respawn). Generation-guarded so a concurrent restart can't be
    /// clobbered.
    public func stop(label: String) async {
        guard let generation = entries[label]?.generation else { return }
        entries[label]?.stopping = true
        if let process = entries[label]?.process, process.isRunning { process.terminate() }
        await waitForExit(label: label, generation: generation, graceSeconds: policy.quiesceGraceSeconds)
        // Only act if this is still the generation we were stopping — a concurrent
        // spawn() may have replaced it.
        guard entries[label]?.generation == generation else { return }
        if let process = entries[label]?.process, process.isRunning { Self.forceKill(process) }
        entries[label] = nil
    }

    /// SIGTERM every child, wait the grace period, SIGKILL stragglers, and stop
    /// restarting. A child's own SIGTERM path quiesces ITS children in turn, so
    /// quiescing the root quiesces the whole tree. Graceful only — a parent that
    /// is SIGKILLed/crashes cannot run this (see docs/design/process-supervisor.md).
    public func quiesce() async {
        closed = true
        for entry in entries.values where entry.process.isRunning {
            entry.process.terminate()
        }
        let deadline = Date().addingTimeInterval(policy.quiesceGraceSeconds)
        while Date() < deadline, entries.values.contains(where: { $0.process.isRunning }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for entry in entries.values where entry.process.isRunning {
            Self.forceKill(entry.process)
        }
        entries.removeAll()
    }

    // MARK: - Introspection (status / tests)

    public func supervisedLabels() -> [String] { Array(entries.keys) }
    public func isRunning(_ label: String) -> Bool { entries[label]?.process.isRunning ?? false }
    public func restartCount(_ label: String) -> Int { entries[label]?.restarts ?? 0 }
    public func processIdentifier(_ label: String) -> Int32? { entries[label]?.process.processIdentifier }

    // MARK: - Internals

    enum SupervisorError: Error { case closed }

    @discardableResult
    private func startProcess(_ launch: SupervisedLaunch, restarts: Int) throws -> Int32 {
        let generation = nextGeneration
        nextGeneration += 1
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        if let environment = launch.environment { process.environment = environment }
        let label = launch.label
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { await self.handleExit(label: label, generation: generation, status: status) }
        }
        try process.run()
        entries[label] = Entry(launch: launch, process: process, restarts: restarts, generation: generation, stopping: false)
        log.info("spawned child '\(label)' pid \(process.processIdentifier) gen \(generation) (restart \(restarts))")
        return process.processIdentifier
    }

    private func handleExit(label: String, generation: UInt64, status: Int32) async {
        // Ignore handlers from a process that is no longer the current generation
        // (already restarted, replaced by spawn(), or stopped), or after quiesce.
        guard let entry = entries[label], entry.generation == generation, !entry.stopping, !closed else { return }
        // A clean exit (status 0) is intentional — do not restart.
        guard status != 0 else {
            log.info("child '\(label)' exited cleanly (status 0); not restarting")
            entries[label] = nil
            return
        }
        guard entry.restarts < policy.maxRestarts else {
            log.error("child '\(label)' crashed (status \(status)); restart budget exhausted after \(entry.restarts) — giving up")
            entries[label] = nil
            return
        }
        let backoff = max(policy.restartBackoffSeconds, Self.minRestartBackoffSeconds)
        log.warn("child '\(label)' crashed (status \(status)); restarting (\(entry.restarts + 1)/\(policy.maxRestarts)) after \(backoff)s")
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        // Re-validate after the suspension: same generation present, not stopped/closed.
        guard !closed, let current = entries[label], current.generation == generation, !current.stopping else { return }
        do {
            _ = try startProcess(current.launch, restarts: current.restarts + 1)
        } catch {
            log.error("child '\(label)' restart failed: \(error)")
            entries[label] = nil
        }
    }

    private func waitForExit(label: String, generation: UInt64, graceSeconds: Double) async {
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            guard let entry = entries[label], entry.generation == generation, entry.process.isRunning else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func forceKill(_ process: Process) {
        kill(process.processIdentifier, SIGKILL)
    }
}
