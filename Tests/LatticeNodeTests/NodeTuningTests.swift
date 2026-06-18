import XCTest
@testable import LatticeNode

/// NodeTuning is the single home for the node's operational tunables. These
/// tests lock in two contracts: (1) defaults equal the literals they replaced
/// (so the centralization stays behavior-preserving), and (2) environment
/// overrides actually take effect (so the knobs are genuinely configurable).
final class NodeTuningTests: XCTestCase {

    func testDefaultsMatchReplacedLiterals() {
        let t = NodeTuning.default
        XCTAssertEqual(t.sync.timeout, .seconds(600))
        XCTAssertEqual(t.sync.catchUpThreshold, 3)
        XCTAssertEqual(t.sync.shallowThreshold, 200)
        XCTAssertEqual(t.sync.fetchDeadline, .seconds(15))
        XCTAssertEqual(t.sync.fetchPollInterval, .milliseconds(400))

        XCTAssertEqual(t.gossip.txDedupWindow, .seconds(60))
        XCTAssertEqual(t.gossip.blockDedupWindow, .milliseconds(100))
        XCTAssertEqual(t.gossip.maxRecentTxCIDs, 8_192)
        XCTAssertEqual(t.gossip.maxConcurrentBlockValidations, 4)
        XCTAssertEqual(t.gossip.maxPendingGossipTasks, 64)

        XCTAssertEqual(t.rateLimit.mempoolGossipCapacity, 200)
        XCTAssertEqual(t.rateLimit.hardFaultBanThreshold, 5)
        XCTAssertEqual(t.rateLimit.peerRateWindow, .seconds(10))

        XCTAssertEqual(t.parentExtractor.maxPendingExtractionTasks, 64)

        XCTAssertEqual(t.storage.evictGraceSeconds, 600)
        XCTAssertEqual(t.storage.ownTxPinWindow, 4_096)
    }

    func testEmptyEnvironmentYieldsDefaults() {
        let t = NodeTuning.fromEnvironment([:])
        XCTAssertEqual(t.sync.timeout, NodeTuning.default.sync.timeout)
        XCTAssertEqual(t.sync.catchUpThreshold, NodeTuning.default.sync.catchUpThreshold)
        XCTAssertEqual(t.storage.evictGraceSeconds, NodeTuning.default.storage.evictGraceSeconds)
    }

    func testEnvironmentOverridesApply() {
        let env = [
            "SYNC_TIMEOUT_SECONDS": "120",
            "SYNC_CATCHUP_THRESHOLD": "32",
            "FETCH_DEADLINE_SECONDS": "8",
            "FETCH_POLL_MILLIS": "250",
            "MAX_CONCURRENT_BLOCK_VALIDATIONS": "16",
            "MEMPOOL_GOSSIP_CAPACITY": "500",
            "HARD_FAULT_BAN_THRESHOLD": "3",
            "EXTRACTOR_MAX_PENDING_TASKS": "128",
            "EVICT_GRACE_SECONDS": "2",
        ]
        let t = NodeTuning.fromEnvironment(env)
        XCTAssertEqual(t.sync.timeout, .seconds(120))
        XCTAssertEqual(t.sync.catchUpThreshold, 32)
        XCTAssertEqual(t.sync.fetchDeadline, .seconds(8))
        XCTAssertEqual(t.sync.fetchPollInterval, .milliseconds(250))
        XCTAssertEqual(t.gossip.maxConcurrentBlockValidations, 16)
        XCTAssertEqual(t.rateLimit.mempoolGossipCapacity, 500)
        XCTAssertEqual(t.rateLimit.hardFaultBanThreshold, 3)
        XCTAssertEqual(t.parentExtractor.maxPendingExtractionTasks, 128)
        XCTAssertEqual(t.storage.evictGraceSeconds, 2)
    }

    /// Malformed values are ignored (keep the default) rather than crashing.
    func testMalformedOverridesFallBackToDefault() {
        let t = NodeTuning.fromEnvironment([
            "SYNC_TIMEOUT_SECONDS": "not-a-number",
            "SYNC_CATCHUP_THRESHOLD": "",
        ])
        XCTAssertEqual(t.sync.timeout, NodeTuning.default.sync.timeout)
        XCTAssertEqual(t.sync.catchUpThreshold, NodeTuning.default.sync.catchUpThreshold)
    }
}
