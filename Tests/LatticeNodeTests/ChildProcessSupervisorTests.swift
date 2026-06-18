import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import LatticeNode

final class ChildProcessSupervisorTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func tempFile(_ name: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name).path
    }

    private func lineCount(_ path: String) -> Int {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Poll `condition` until true or `timeout` seconds elapse.
    private func waitUntil(_ timeout: Double = 3.0, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }

    func testSpawnTracksThenQuiesceStops() async throws {
        let sup = ChildProcessSupervisor(policy: .init(maxRestarts: 0, restartBackoffSeconds: 0, quiesceGraceSeconds: 1.0))
        let launch = SupervisedLaunch(label: "alpha", executableURL: shell, arguments: ["-c", "sleep 30"])
        _ = try await sup.spawn(launch)

        let up = await waitUntil { await sup.isRunning("alpha") }
        XCTAssertTrue(up, "child should be running after spawn")
        let labels = await sup.supervisedLabels()
        XCTAssertEqual(labels, ["alpha"])

        await sup.quiesce()
        let gone = await waitUntil {
            let running = await sup.isRunning("alpha")
            let remaining = await sup.supervisedLabels()
            return !running && remaining.isEmpty
        }
        XCTAssertTrue(gone, "quiesce should terminate and clear all children")
    }

    func testRestartsCrashedChildUpToBudgetThenGivesUp() async throws {
        let marker = tempFile("runs.txt")
        let sup = ChildProcessSupervisor(policy: .init(maxRestarts: 2, restartBackoffSeconds: 0.05, quiesceGraceSeconds: 1.0))
        let launch = SupervisedLaunch(
            label: "crasher",
            executableURL: shell,
            arguments: ["-c", "echo run >> \(marker); exit 1"]
        )
        _ = try await sup.spawn(launch)

        // initial run + maxRestarts restarts = 3 runs, then the entry is dropped.
        let done = await waitUntil(5.0) {
            let remaining = await sup.supervisedLabels()
            return self.lineCount(marker) >= 3 && remaining.isEmpty
        }
        XCTAssertTrue(done, "expected 3 runs then give-up; saw \(lineCount(marker)) runs")
        // Stable: no further restarts after the budget is exhausted.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lineCount(marker), 3, "must not restart past the budget")
    }

    func testStopDoesNotRestart() async throws {
        let sup = ChildProcessSupervisor(policy: .init(maxRestarts: 5, restartBackoffSeconds: 0.05, quiesceGraceSeconds: 1.0))
        let launch = SupervisedLaunch(label: "beta", executableURL: shell, arguments: ["-c", "sleep 30"])
        _ = try await sup.spawn(launch)
        _ = await waitUntil { await sup.isRunning("beta") }

        await sup.stop(label: "beta")
        let gone = await !(sup.isRunning("beta"))
        XCTAssertTrue(gone, "stopped child should not be running")
        let labels = await sup.supervisedLabels()
        XCTAssertFalse(labels.contains("beta"), "stopped child should be untracked, not restarted")
    }

    func testQuiesceHaltsTheCrashLoop() async throws {
        let marker = tempFile("runs.txt")
        let sup = ChildProcessSupervisor(policy: .init(maxRestarts: 100, restartBackoffSeconds: 0.05, quiesceGraceSeconds: 1.0))
        let launch = SupervisedLaunch(
            label: "loop",
            executableURL: shell,
            arguments: ["-c", "echo run >> \(marker); exit 1"]
        )
        _ = try await sup.spawn(launch)
        // Let it crash-loop a little, then quiesce.
        _ = await waitUntil { self.lineCount(marker) >= 1 }
        await sup.quiesce()
        let after = lineCount(marker)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertLessThanOrEqual(lineCount(marker) - after, 1, "quiesce must stop the restart loop")
        let remaining = await sup.supervisedLabels()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCleanExitIsNotRestarted() async throws {
        let marker = tempFile("runs.txt")
        let sup = ChildProcessSupervisor(policy: .init(maxRestarts: 5, restartBackoffSeconds: 0.0, quiesceGraceSeconds: 1.0))
        let launch = SupervisedLaunch(
            label: "clean",
            executableURL: shell,
            arguments: ["-c", "echo run >> \(marker); exit 0"]
        )
        _ = try await sup.spawn(launch)
        // A status-0 exit is intentional: run exactly once, then drop the entry.
        let dropped = await waitUntil(3.0) {
            let remaining = await sup.supervisedLabels()
            return self.lineCount(marker) >= 1 && remaining.isEmpty
        }
        XCTAssertTrue(dropped, "clean-exit child should run once and not restart")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lineCount(marker), 1, "clean exit must never restart")
    }

    func testRespawnSameLabelReplacesOldProcess() async throws {
        let sup = ChildProcessSupervisor(policy: .init(maxRestarts: 5, restartBackoffSeconds: 0.05, quiesceGraceSeconds: 1.0))
        let mk = { SupervisedLaunch(label: "x", executableURL: self.shell, arguments: ["-c", "sleep 30"]) }
        let pid1 = try await sup.spawn(mk())
        _ = await waitUntil { await sup.isRunning("x") }

        let pid2 = try await sup.spawn(mk())
        XCTAssertNotEqual(pid1, pid2, "respawn should be a new process")
        let labels = await sup.supervisedLabels()
        XCTAssertEqual(labels, ["x"], "only one tracked entry per label")
        let pid2Running = await sup.isRunning("x")
        XCTAssertTrue(pid2Running, "the new process should be running")
        // The old process must be terminated, not orphaned.
        let oldGone = await waitUntil { kill(pid1, 0) != 0 }
        XCTAssertTrue(oldGone, "the replaced process must not be left running")
        await sup.quiesce()
    }

    func testChildSpecArgumentsMatchManualSpawn() {
        let spec = ChildSpec(
            directory: "Alpha",
            chainPath: ["Nexus", "Alpha"],
            genesisHex: "deadbeef",
            subscribeP2P: "pub@127.0.0.1:4001",
            bootstrapPeer: "pub@127.0.0.1:4001",
            port: 4500,
            rpcPort: 8500,
            dataDir: "/tmp/x/children/Alpha",
            inheritedArguments: ["--min-fee-rate", "7"]
        )
        let args = spec.arguments()
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        XCTAssertEqual(args.first, "node", "must lead with the explicit node subcommand")
        XCTAssertEqual(value("--genesis-hex"), "deadbeef")
        XCTAssertEqual(value("--chain-directory"), "Alpha")
        XCTAssertEqual(value("--chain-path"), "Nexus/Alpha")
        XCTAssertEqual(value("--subscribe-p2p"), "pub@127.0.0.1:4001")
        XCTAssertEqual(value("--peer"), "pub@127.0.0.1:4001")
        XCTAssertEqual(value("--port"), "4500")
        XCTAssertEqual(value("--rpc-port"), "8500")
        XCTAssertEqual(value("--data-dir"), "/tmp/x/children/Alpha")
        XCTAssertEqual(value("--min-fee-rate"), "7")
        XCTAssertEqual(spec.launch(nodeExecutable: URL(fileURLWithPath: "/usr/bin/lattice-node")).label, "Alpha")
    }
}
