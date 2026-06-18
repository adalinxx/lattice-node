import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Foundation
import Ivy

/// S10: persistInterval default is 100. Before anyone tightens it toward 1
/// (the motivation was "recover-from-CAS gap = window since last persist"),
/// we need concrete per-persist wall-cost numbers so we can reason about the
/// trade-off instead of guessing. This test mines progressively deeper chains
/// and prints the JSON encode + file write cost at each depth.
///
/// The assertion is a loose upper bound so CI catches a regression where a
/// chain-state field grows unboundedly (e.g. someone inlines a tx list or a
/// retention buffer into `PersistedChainState`). Absolute numbers are expected
/// to drift with hardware; that's why the thresholds are generous.
final class PersistCadenceTests: XCTestCase {

    func testPersistCostScalesLinearlyWithChainDepth() async throws {
        let f = cas()
        let baseTime = now() - 2_000_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: baseTime, target: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let persister = ChainStatePersister(storagePath: tmpDir, directory: "Nexus")

        // Mine past the default persistInterval (100) in CI; local/nightly keeps
        // the deeper trend sample without making every PR pay for it.
        let ci = ProcessInfo.processInfo.environment["CI"] == "true"
        let deepestHeight = ci ? 120 : 250
        var prev = genesis
        var samples: [(height: Int, snapshotMs: Double, saveMs: Double, bytes: Int)] = []
        let probeHeights: Set<Int> = [10, 50, 100, deepestHeight]

        for i in 1...deepestHeight {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: baseTime + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = try VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
            prev = block

            if probeHeights.contains(i) {
                let tSnap = ContinuousClock.now
                let snapshot = await chain.persist()
                let dSnap = ContinuousClock.now - tSnap

                let tSave = ContinuousClock.now
                try await persister.save(snapshot)
                let dSave = ContinuousClock.now - tSave

                let path = tmpDir.appendingPathComponent("Nexus/chain_state.json")
                let bytes = (try? Data(contentsOf: path).count) ?? 0
                samples.append((
                    height: i,
                    snapshotMs: dSnap.milliseconds,
                    saveMs: dSave.milliseconds,
                    bytes: bytes
                ))
            }
        }

        print("[S10] persist cost measurement (retentionDepth=\(DEFAULT_RETENTION_DEPTH))")
        print("[S10]   height  snapshotMs  saveMs   bytes")
        for s in samples {
            print(String(format: "[S10]   %-6d  %-10.3f  %-7.3f  %d",
                         s.height, s.snapshotMs, s.saveMs, s.bytes))
        }

        // Regression guards: this test is about bounded persisted-state growth,
        // not CI filesystem latency. Keep printing timing samples for trend
        // visibility, but fail on size growth because wall-clock writes can spike
        // on hosted runners without indicating an unbounded state regression.
        let deepest = samples.last!
        let first = samples.first!
        let bytesPerBlock = Double(deepest.bytes - first.bytes) / Double(deepest.height - first.height)
        XCTAssertLessThan(bytesPerBlock, 2_000,
                          "chain_state.json grew by \(bytesPerBlock) bytes/block — persisted state should remain retention-bounded")
        XCTAssertLessThan(deepest.bytes, 10_000_000,
                          "chain_state.json at height=\(deepest.height) is \(deepest.bytes) bytes — persisted state should be retention-bounded")
    }

    /// `persistChainState` must reset the cadence counter ONLY on a
    /// successful `save`. The durable meta tip has already advanced by the time
    /// `save` runs; if `save` throws, `chain_state.json` is stale. The OLD code
    /// reset `blocksSinceLastPersist[key] = 0` UNCONDITIONALLY (outside the
    /// do/catch), so after a save failure `maybePersist` would wait another full
    /// `persistInterval` before retrying — widening the window where on-disk JSON
    /// disagrees with the durable tip. The fix moves the reset inside the `do`
    /// after a successful `save`, so a failure leaves the counter untouched and
    /// the next `maybePersist` (count already >= persistInterval) re-persists.
    ///
    /// Drives the REAL `persistChainState` entry point on a real node; the save
    /// is forced to throw by pre-creating `chain_state.json` as a DIRECTORY, so
    /// `Data.write(to:)` inside `ChainStatePersister.save` cannot overwrite it.
    func test_saveFailure_doesNotResetCounter() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let kp = CryptoUtils.generateKeyPair()
        let interval: UInt64 = 5
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmpDir,
                enableLocalDiscovery: false,
                persistInterval: interval, minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )

        let directory = await node.genesisConfig.directory
        let key = await node.chainKey(forDirectory: directory)

        // Pre-create chain_state.json as a directory → `save`'s `data.write(to:)`
        // throws because the path is occupied by a directory.
        let chainStatePath = tmpDir
            .appendingPathComponent(directory)
            .appendingPathComponent("chain_state.json")
        try FileManager.default.createDirectory(at: chainStatePath, withIntermediateDirectories: true)

        // Drive the cadence counter to the threshold through the REAL
        // `maybePersist` path. The first `interval-1` calls only increment; the
        // `interval`-th call reaches the threshold and invokes `persistChainState`,
        // whose `save` throws (chain_state.json is a directory).
        for _ in 0..<interval {
            await node.maybePersist(directory: directory)
        }

        // RED on main: the `interval`-th maybePersist's persistChainState reset
        // the counter to 0 despite the failed save. GREEN: it stays at `interval`.
        let counter = await node.blocksSinceLastPersist[key] ?? 0
        XCTAssertGreaterThanOrEqual(counter, interval,
            "after a FAILED save the cadence counter must stay >= persistInterval so the next maybePersist re-persists immediately (was reset to 0 on main)")
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attos) = self.components
        return Double(seconds) * 1_000 + Double(attos) / 1_000_000_000_000_000
    }
}
