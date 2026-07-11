import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import LatticeNode

/// Verifies process-per-chain environment isolation: a supervised child must be
/// launched with an explicit allowlist, NEVER a copy of the parent's ambient
/// environment (which would leak deploy tokens, cloud creds, API keys, etc.).
final class ChildSpecEnvironmentTests: XCTestCase {
    private func makeSpec(provisionedKey: String?) -> ChildSpec {
        ChildSpec(
            directory: "child-a",
            chainPath: ["nexus", "child-a"],
            genesisHex: "deadbeef",
            subscribeP2P: "pk@127.0.0.1:4001",
            bootstrapPeer: nil,
            port: 4101,
            rpcPort: 8101,
            dataDir: "/tmp/child-a",
            provisionedPrivateKeyHex: provisionedKey
        )
    }

    /// An arbitrary parent secret must not survive into the child environment,
    /// while allowlisted runtime vars and the provisioned key must.
    func testUnrelatedSecretIsNotForwarded() {
        setenv("UNRELATED_SECRET", "leak-me", 1)
        setenv("AWS_SECRET_ACCESS_KEY", "leak-me-too", 1)
        setenv("PATH", "/usr/bin:/bin", 1)
        defer {
            unsetenv("UNRELATED_SECRET")
            unsetenv("AWS_SECRET_ACCESS_KEY")
        }

        let spec = makeSpec(provisionedKey: "aabbccdd")
        let env = spec.childEnvironment()

        XCTAssertNil(env["UNRELATED_SECRET"], "arbitrary parent secret must not leak into child")
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"], "cloud credentials must not leak into child")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin", "allowlisted runtime var must be forwarded")
        XCTAssertEqual(env["LATTICE_PRIVATE_KEY"], "aabbccdd", "provisioned identity key must be delivered")
    }

    /// Allowlisted tuning knobs are forwarded; absent allowlisted keys are simply
    /// skipped (no empty entries).
    func testTuningKnobForwardedAndAbsentKeysSkipped() {
        let parentEnv: [String: String] = [
            "LOG_LEVEL": "debug",
            "RETENTION_DEPTH": "4096",
            "UNRELATED_SECRET": "leak-me",
            // PATH intentionally absent here
        ]

        let spec = makeSpec(provisionedKey: nil)
        let env = spec.childEnvironment(parentEnvironment: parentEnv)

        XCTAssertEqual(env["LOG_LEVEL"], "debug")
        XCTAssertEqual(env["RETENTION_DEPTH"], "4096")
        XCTAssertNil(env["UNRELATED_SECRET"], "non-allowlisted key must be dropped")
        XCTAssertNil(env["PATH"], "absent allowlisted key must not be synthesized")
        XCTAssertNil(env["LATTICE_PRIVATE_KEY"], "no key delivered when not provisioned")
    }

    /// `launch()` must carry the same allowlisted environment it builds — proving
    /// the supervisor never receives the full parent env.
    func testLaunchUsesAllowlistedEnvironment() throws {
        setenv("UNRELATED_SECRET", "leak-me", 1)
        defer { unsetenv("UNRELATED_SECRET") }

        let spec = makeSpec(provisionedKey: "aabbccdd")
        let launch = spec.launch(nodeExecutable: URL(fileURLWithPath: "/usr/bin/lattice-node"))

        let env = try XCTUnwrap(launch.environment, "launch must set an explicit environment")
        XCTAssertNil(env["UNRELATED_SECRET"], "launch env must not contain parent secrets")
        XCTAssertEqual(env["LATTICE_PRIVATE_KEY"], "aabbccdd")
    }
}
