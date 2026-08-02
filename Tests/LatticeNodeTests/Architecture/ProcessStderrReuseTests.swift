import XCTest

/// The `lattice mine` loop spawns a fresh coordinator per block, forever.
/// It must direct each child's stderr at a handle that stays valid across
/// spawns: on swift-corelibs-Foundation the shared `FileHandle.nullDevice`
/// singleton has its fd closed after a child exits, so reusing it makes a
/// later spawn throw EBADF — which once killed the miner an hour in, past
/// where the E2Es exercised it. This pins the fresh-handle pattern the fix
/// uses (see runCoordinatorOnce / the child-deploy loop).
final class ProcessStderrReuseTests: XCTestCase {
    private func trueBinary() throws -> URL {
        for path in ["/usr/bin/true", "/bin/true"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("no `true` binary available")
    }

    func testFreshDevNullSurvivesManySequentialSpawns() throws {
        let binary = try trueBinary()
        for iteration in 0..<50 {
            let process = Process()
            process.executableURL = binary
            let devNull = FileHandle(forWritingAtPath: "/dev/null")
            process.standardError = try XCTUnwrap(devNull)
            process.standardOutput = devNull
            do {
                try process.run()
            } catch {
                XCTFail("spawn \(iteration) threw: \(error)")
                return
            }
            process.waitUntilExit()
            try? devNull?.close()
        }
    }
}
