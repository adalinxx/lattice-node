import XCTest
@testable import LatticeNode
import Foundation

/// I7: enableLocalDiscovery default must stay `false`. A headless colo/cloud
/// miner is the default deployment shape; mDNS advertising to no-one on the
/// LAN burns cycles and leaks liveness to anyone who shares a broadcast
/// domain. Flip this default back to `true` only after you've also taught
/// the daemon binary to default the CLI flag opt-out instead of opt-in.
final class LatticeNodeConfigTests: XCTestCase {

    func testEnableLocalDiscoveryDefaultsOff() {
        let cfg = LatticeNodeConfig(
            publicKey: "p", privateKey: "k",
            storagePath: URL(fileURLWithPath: "/tmp/does-not-matter"), minPeerKeyBits: 0
        )
        XCTAssertFalse(
            cfg.enableLocalDiscovery,
            "LatticeNodeConfig.enableLocalDiscovery default must be false (I7)"
        )
    }
}
