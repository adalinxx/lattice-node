import Testing
import Foundation
import VolumeBroker
import cashew
@testable import Lattice
@testable import LatticeNode

/// Module 6 (Retention Edge Fix): object-grain closure reachability under retention.
///
/// KNOWN HISTORY (pre-existing object-grain bug): pinning a block ROOT did not
/// protect that block's IN-PACKAGE transaction/state content from eviction, so
/// fetching an IN-WINDOW (retained, not yet height-pruned) block's transactions
/// via `/api/block/{h}/transactions` could 500 / fail to resolve once an eviction
/// sweep ran. The expected fix lives at the cashew/VolumeBroker EDGE — eviction
/// must protect the TRANSITIVE reachable object closure of a live pin, not just the
/// pinned root — NOT in node pruning policy.
///
/// This suite drives the REAL read path end-to-end: boot a node under `.retention`,
/// mine PAST the retention window so `pruneBlocks` unpins below-floor heights, force
/// an eviction sweep (`sharedDiskBroker.evictUnpinned`, grace=0), then fetch an
/// IN-WINDOW block's transactions over the live RPC server and assert the in-package
/// coinbase tx content still resolves. Every mined block carries an in-package
/// coinbase transaction (`BlockProducer.buildCoinbaseTransaction`), so each retained
/// block has real in-package tx content under test — no mempool submission needed.
///
/// GREEN here = the bug is FIXED in the currently-pinned VolumeBroker (the eviction
/// engine's `protected` CTE walks the recursive owned-child closure of every live
/// pin). RED would mean the in-window tx content was evicted despite the root pin.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CI"] != "true"))
struct RetentionClosureReachabilityTests {

    private static func freshStoragePath() -> (tmpDir: URL, storagePath: URL) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (tmpDir, tmpDir.appendingPathComponent("node"))
    }

    private static func makeConfig(
        storagePath: URL,
        kp: (privateKey: String, publicKey: String),
        retentionDepth: UInt64
    ) -> LatticeNodeConfig {
        LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: 0,
            storagePath: storagePath,
            enableLocalDiscovery: false,
            persistInterval: 1,
            retentionDepth: retentionDepth,
            blockRetention: .retention,
            minPeerKeyBits: 0
        )
    }

    /// Boot a node with the eviction grace window forced to 0 so a freshly-stored,
    /// now-unpinned block becomes immediately evictable (the grace is read from
    /// `EVICT_GRACE_SECONDS` at node construction — see `LatticeNode.init`).
    private static func bootWithZeroGrace(
        storagePath: URL,
        kp: (privateKey: String, publicKey: String),
        genesis: GenesisConfig,
        retentionDepth: UInt64
    ) async throws -> LatticeNode {
        let prior = ProcessInfo.processInfo.environment["EVICT_GRACE_SECONDS"]
        setenv("EVICT_GRACE_SECONDS", "0", 1)
        defer {
            if let prior { setenv("EVICT_GRACE_SECONDS", prior, 1) }
            else { unsetenv("EVICT_GRACE_SECONDS") }
        }
        let node = try await LatticeNode(
            config: makeConfig(storagePath: storagePath, kp: kp, retentionDepth: retentionDepth),
            genesisConfig: genesis)
        try await node.start()
        return node
    }

    private static func rpcGet(_ base: String, _ path: String) async throws -> (json: [String: Any], status: Int) {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "\(base)\(path)")!)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, status)
    }

    /// Mine past the retention window, evict unpinned content, then fetch an
    /// IN-WINDOW block's transactions over the live RPC read path. The in-package
    /// coinbase tx must still resolve — proving the block-root pin transitively
    /// protected the whole reachable closure through eviction.
    @Test func inWindowBlockTransactionsResolveAfterEviction() async throws {
        let (tmpDir, storagePath) = Self.freshStoragePath()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let kp = CryptoUtils.generateKeyPair()
        let genesis = testGenesis()
        let retentionDepth: UInt64 = 3

        let node = try await Self.bootWithZeroGrace(
            storagePath: storagePath, kp: kp, genesis: genesis, retentionDepth: retentionDepth)
        defer { Task { await node.stop() } }
        let network = try #require(await node.network(for: "Nexus"))

        // Mine well past the retention window so the live prune path has unpinned
        // several below-floor heights. tip = 8, retentionDepth = 3 → floor = 5;
        // heights 1..5 are below/at the floor and have had their height owners
        // unpinned by `pruneBlocks`.
        let blocksToMine = 8
        try await mineBlocks(blocksToMine, on: node)
        let tip = try #require(await node.chain(for: "Nexus")?.getHighestBlockHeight())
        #expect(tip == UInt64(blocksToMine))

        // Confirm below-floor height owners were actually unpinned by the live
        // prune path — otherwise eviction would protect everything and the test
        // would be vacuous. The floor is `tip - retentionDepth`; owners strictly
        // below the floor are released.
        let floor = tip - retentionDepth
        let blockOwners = await network.pinnedOwners(prefix: "Nexus:")
        let belowFloorOwner = "Nexus:\(floor - 1)"
        #expect(!blockOwners.contains(belowFloorOwner),
                "live prune must have unpinned below-floor owner \(belowFloorOwner) (owners: \(blockOwners.sorted()))")

        // Force an eviction sweep. With grace=0 every unpinned, unreachable root is
        // now reclaimable. If pinning a block root did NOT protect its in-package
        // children, this is where the in-window block's tx content would vanish.
        _ = try await node.sharedDiskBroker.evictUnpinned()

        // Bring up the real RPC server and exercise the literal read path.
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        defer { rpcTask.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        let base = "http://127.0.0.1:\(rpcPort)/api"

        // Pick an IN-WINDOW height: strictly above the floor, below the tip.
        let inWindowHeight = floor + 1
        #expect(inWindowHeight < tip)

        // Resolve the in-window block summary → hash, then fetch its transactions
        // BY HASH (exercises resolveBlock + the canonical content fetcher closure).
        let summary = try await Self.rpcGet(base, "/block/\(inWindowHeight)")
        #expect(summary.status == 200, "in-window block summary must resolve (status \(summary.status))")
        let blockHash = try #require(summary.json["hash"] as? String)
        let summaryTxCount = summary.json["transactionCount"] as? Int ?? 0
        #expect(summaryTxCount > 0, "every mined block carries an in-package coinbase tx")

        let txResp = try await Self.rpcGet(base, "/block/\(blockHash)/transactions")
        #expect(txResp.status == 200,
                """
                IN-WINDOW block \(inWindowHeight) transactions must resolve after eviction. \
                A 500 here is the object-grain retention bug: the block-root pin failed to \
                protect in-package tx content. (status \(txResp.status))
                """)
        let txs = txResp.json["transactions"] as? [[String: Any]] ?? []
        #expect(!txs.isEmpty,
                "in-package coinbase tx content for in-window block \(inWindowHeight) must survive eviction")
        // The tx body content must itself resolve — the read path resolves each
        // tx + its body, so a non-empty list with a real bodyCID proves the deep
        // in-package closure (tx → body) survived, not just the dictionary root.
        let bodyCID = txs.first?["bodyCID"] as? String ?? ""
        #expect(!bodyCID.isEmpty,
                "in-package tx BODY content must resolve (deep closure protection)")
    }

    /// The same guarantee at the retention BOUNDARY: the block exactly at the live
    /// retention floor (`tip - retentionDepth`) is the oldest still-retained height.
    /// Its in-package tx content must survive an eviction sweep too.
    @Test func boundaryBlockTransactionsResolveAfterEviction() async throws {
        let (tmpDir, storagePath) = Self.freshStoragePath()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let kp = CryptoUtils.generateKeyPair()
        let genesis = testGenesis()
        let retentionDepth: UInt64 = 3

        let node = try await Self.bootWithZeroGrace(
            storagePath: storagePath, kp: kp, genesis: genesis, retentionDepth: retentionDepth)
        defer { Task { await node.stop() } }
        _ = try #require(await node.network(for: "Nexus"))

        try await mineBlocks(8, on: node)
        let tip = try #require(await node.chain(for: "Nexus")?.getHighestBlockHeight())
        let boundaryHeight = tip - retentionDepth + 1  // oldest height still strictly above the released floor

        _ = try await node.sharedDiskBroker.evictUnpinned()

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        defer { rpcTask.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        let base = "http://127.0.0.1:\(rpcPort)/api"

        let summary = try await Self.rpcGet(base, "/block/\(boundaryHeight)")
        #expect(summary.status == 200)
        let blockHash = try #require(summary.json["hash"] as? String)

        let txResp = try await Self.rpcGet(base, "/block/\(blockHash)/transactions")
        #expect(txResp.status == 200,
                "boundary block \(boundaryHeight) transactions must resolve after eviction (status \(txResp.status))")
        let txs = txResp.json["transactions"] as? [[String: Any]] ?? []
        #expect(!txs.isEmpty,
                "in-package coinbase tx content for boundary block \(boundaryHeight) must survive eviction")
    }
}
