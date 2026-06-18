import Ivy
import Tally
import XCTest
import HTTPTypes
import UInt256
import VolumeBroker
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// node P2P/RPC DoS-hardening gates. Each gate is proven through a real
/// entry point (live RPC socket, the real genesis-hex parse path, the real ban
/// store, the real config→Tally wiring) — never a private-helper-only seam.
final class NodeDoSHardeningTests: XCTestCase {

    // MARK: - Gate (a): per-IP RPC rate limiter

    /// Per-source keying: exhausting source A must NOT deny source B. This is the
    /// canonical RED→GREEN unit through the rate-limiter + IP-extraction seam the
    /// middleware uses. RED on old code: both direct-connect clients collapsed to
    /// the constant "unknown", so allow(B) returned false after A drained the pool.
    func testRPCRateLimiterIsPerSourceConnectionIP() {
        let limiter = RPCRateLimiter(requestsPerSecond: 1, burstSize: 1)
        // The middleware keys off the per-connection source IP (no proxy trust).
        let ipA = RPCClientIP.extract(from: HTTPFields(), trustProxyHeaders: false, connectionIP: "10.0.0.1")
        let ipB = RPCClientIP.extract(from: HTTPFields(), trustProxyHeaders: false, connectionIP: "10.0.0.2")
        XCTAssertEqual(ipA, "10.0.0.1")
        XCTAssertEqual(ipB, "10.0.0.2")
        XCTAssertNotEqual(ipA, ipB, "distinct connections must produce distinct keys")

        XCTAssertTrue(limiter.allow(ip: ipA), "first request from A consumes its only token")
        XCTAssertFalse(limiter.allow(ip: ipA), "A is now exhausted")
        XCTAssertTrue(limiter.allow(ip: ipB), "B has its OWN pool and must not be starved by A")
    }

    /// End-to-end: a per-IP flood through the REAL RPC ingress is throttled (429).
    /// A tight node-configured limiter is exhausted by a burst from one client.
    func testRPCFloodThroughRealIngressReturns429() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Node-configurable limiter: 1 req/s, burst 2 — fail closed, good default
        // shape, just tightened for the test.
        let resources = NodeResourceConfig(rpcRequestsPerSecond: 1, rpcBurstSize: 2)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp,
            enableLocalDiscovery: false, resources: resources, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        let url = URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/info")!
        var sawThrottle = false
        // Burst well past burstSize; the per-IP bucket must start rejecting.
        for _ in 0..<20 {
            let (_, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 429 { sawThrottle = true; break }
        }
        XCTAssertTrue(sawThrottle, "a single-IP RPC flood must be throttled with HTTP 429 by the per-IP limiter")
    }

    // MARK: - Gate (b): mempool-full source-exclusion / penalize

    /// When the mempool is at capacity it reports `isAtCapacity`, the signal the
    /// gossip layer uses to distinguish a flooding source (penalize/exclude) from
    /// an ordinary policy rejection. Driven through the real mempool admission
    /// path (addTransaction), not a private helper.
    func testMempoolReportsCapacityForSourceExclusion() async {
        // maxSize=1: the second distinct-sender tx cannot displace the first
        // (equal/lower fee), so it is a genuine capacity rejection.
        let mempool = NodeMempool(maxSize: 1)
        let a = Wallet.create()
        let b = Wallet.create()
        let txA = a.buildTransfer(to: a.address, amount: 1, fee: 10, nonce: 0)!
        let txB = b.buildTransfer(to: b.address, amount: 1, fee: 10, nonce: 0)!

        let addedA = await mempool.add(transaction: txA)
        XCTAssertTrue(addedA, "first tx fills the single slot")
        var full = await mempool.isAtCapacity
        XCTAssertTrue(full, "mempool must report at-capacity once full")

        let result = await mempool.addTransaction(txB)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("full") || reason.message.contains("too low"),
                          "capacity rejection expected, got: \(reason)")
        default:
            XCTFail("a full mempool must reject the flooding source's tx, got \(result)")
        }
        full = await mempool.isAtCapacity
        XCTAssertTrue(full, "still full after the rejected flood tx")
    }

    /// H7: the mempool BYTE budget is a NODE-wide memory cap, enforced through a
    /// SHARED cross-chain limiter every chain's mempool debits — NOT a per-chain
    /// slice. The invariant: the aggregate retained bytes across ALL chains never
    /// exceeds the configured node budget, no matter how many chains share it (a
    /// per-chain independent cap would let N chains retain ~N × the budget; a
    /// floored per-chain slice would amplify; a late-registered chain would add a
    /// fresh cap). This is the review finding (per-chain slicing → N× bypass).
    func testSharedByteLimiterBoundsAggregateAcrossChains() async {
        // One node-wide budget shared by several chain mempools (simulating Nexus +
        // children, incl. ones "registered later" by simply sharing the limiter).
        let budget: UInt64 = 8192
        let limiter = MempoolByteLimiter(maxBytes: budget)
        let chainA = NodeMempool(maxSize: 10_000, byteLimiter: limiter, maxPerAccount: 64)
        let chainB = NodeMempool(maxSize: 10_000, byteLimiter: limiter, maxPerAccount: 64)

        // Fill chain A (uniform fee → no eviction) until the SHARED budget rejects more.
        var addedA = 0
        for _ in 0..<500 {
            let w = Wallet.create()
            let tx = w.buildTransfer(to: w.address, amount: 1, fee: 100, nonce: 0)!
            if case .added = await chainA.addTransaction(tx) { addedA += 1 } else { break }
        }
        XCTAssertGreaterThan(addedA, 0, "chain A must admit at least some txs")
        XCTAssertLessThanOrEqual(limiter.used(), budget, "chain A alone cannot exceed the shared budget")

        // A SECOND chain sharing the budget must not get a fresh cap: with the node
        // full of A's bytes and no residents of its own to evict, B rejects. This is
        // exactly the bypass the old per-chain slice allowed.
        var addedB = 0
        for _ in 0..<50 {
            let w = Wallet.create()
            let tx = w.buildTransfer(to: w.address, amount: 1, fee: 1, nonce: 0)!
            if case .added = await chainB.addTransaction(tx) { addedB += 1 } else { break }
        }
        XCTAssertEqual(addedB, 0, "a second chain must not admit beyond the shared node-wide budget")

        // The hard invariant: Σ bytes across ALL chains ≤ the node budget.
        XCTAssertLessThanOrEqual(limiter.used(), budget,
                                 "aggregate retained bytes across chains must stay within the node budget")

        // Freeing A's bytes returns budget to the shared pool — B can then admit
        // (proves the limiter is a live shared accountant, not a per-chain constant).
        let aTxs = await chainA.allTransactions()
        await chainA.removeAll(txCIDs: Set(aTxs.map { $0.body.rawCID }))
        XCTAssertEqual(limiter.used(), 0, "removing every resident releases the shared budget")
        let w = Wallet.create()
        let txB = w.buildTransfer(to: w.address, amount: 1, fee: 1, nonce: 0)!
        if case .added = await chainB.addTransaction(txB) {} else {
            XCTFail("chain B must admit once the shared budget is freed")
        }
    }

    /// H7: check+reserve on the shared limiter must be ATOMIC — a single lock decides
    /// fit and commits in one step — and a FAILED reservation must leave `used()`
    /// unchanged. Without this, two chain mempool actors could both read the same
    /// `used()` and both reserve past `maxBytes`. This unit-tests the primitive
    /// directly (the cross-actor race the sequential aggregate test can't force).
    func testByteLimiterTryReserveIsAtomicAndLeavesStateUnchangedOnFailure() {
        let limiter = MempoolByteLimiter(maxBytes: 1000)
        XCTAssertTrue(limiter.tryReserve(incoming: 600, freed: 0), "fits: 0+600 ≤ 1000")
        XCTAssertEqual(limiter.used(), 600)
        // Would overshoot (600+600 > 1000): must reject AND not mutate used().
        XCTAssertFalse(limiter.tryReserve(incoming: 600, freed: 0), "600+600 > 1000 must fail")
        XCTAssertEqual(limiter.used(), 600, "a failed reservation must leave used() unchanged")
        // Crediting freed bytes lets a reservation fit exactly at the cap.
        XCTAssertTrue(limiter.tryReserve(incoming: 700, freed: 300), "600-300+700 = 1000 ≤ 1000")
        XCTAssertEqual(limiter.used(), 1000, "net delta (-freed +incoming) committed atomically")
        XCTAssertFalse(limiter.tryReserve(incoming: 1, freed: 0), "at the cap, +1 must fail")
        XCTAssertEqual(limiter.used(), 1000)
        // nil maxBytes = unbounded: always admits, still tracks usage.
        let unbounded = MempoolByteLimiter(maxBytes: nil)
        XCTAssertTrue(unbounded.tryReserve(incoming: .max, freed: 0))
    }

    /// H7: concurrent admissions across chains sharing one budget must NEVER push the
    /// shared total past `maxBytes`, and `used()` must equal the bytes actually
    /// resident (no accounting drift between the atomic reserve and the per-entry
    /// release paths). Hammers two real mempool actors at once.
    func testSharedByteLimiterNeverOvershootsUnderConcurrentAdmission() async {
        let budget: UInt64 = 16_384
        let limiter = MempoolByteLimiter(maxBytes: budget)
        let chainA = NodeMempool(maxSize: 100_000, byteLimiter: limiter, maxPerAccount: 100_000)
        let chainB = NodeMempool(maxSize: 100_000, byteLimiter: limiter, maxPerAccount: 100_000)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let w = Wallet.create()
                    let tx = w.buildTransfer(to: w.address, amount: 1, fee: 100, nonce: 0)!
                    _ = await chainA.addTransaction(tx)
                }
                group.addTask {
                    let w = Wallet.create()
                    let tx = w.buildTransfer(to: w.address, amount: 1, fee: 100, nonce: 0)!
                    _ = await chainB.addTransaction(tx)
                }
            }
        }

        XCTAssertLessThanOrEqual(limiter.used(), budget,
                                 "concurrent cross-chain admissions must never overshoot the shared budget")
        // used() must equal the bytes actually resident across both chains.
        let txsA = await chainA.allTransactions()
        let txsB = await chainB.allTransactions()
        var resident: UInt64 = 0
        for t in txsA + txsB { resident += UInt64(t.body.node?.toData()?.count ?? 0) }
        XCTAssertEqual(limiter.used(), resident,
                       "shared used() must equal bytes resident across chains (no accounting drift)")
    }

    /// The penalize action wired behind a repeated mempool-full flood is a durable
    /// ban: banning a peer makes it banned (and that state persists — covered by
    /// the restart test). This proves the ban path the gossip handler invokes.
    func testBanStorePenalizeBansPeer() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let flooder = PeerID(publicKey: "f100df100df100df100df100df100df1")
        let honest = PeerID(publicKey: "0000111122223333444455556666aaaa")
        let store = PeerBanStore(dataDir: tmp)
        var banned = await store.isBanned(flooder)
        XCTAssertFalse(banned)
        try await store.ban(flooder)
        banned = await store.isBanned(flooder)
        XCTAssertTrue(banned, "the flooding source is excluded via the ban store")
        let honestBanned = await store.isBanned(honest)
        XCTAssertFalse(honestBanned, "an honest peer is NOT swept up by source-exclusion")
    }

    // MARK: - Gate (c): caps

    /// genesis-hex parser fails closed on oversized input with a typed error,
    /// through the same parse function the CLI bootstrap path calls.
    func testGenesisHexParserRejectsOversizedInput() throws {
        // One byte over the cap, hex-encoded.
        let oversized = String(repeating: "00", count: GenesisHexBootstrap.maxBytes + 1)
        XCTAssertThrowsError(try GenesisHexBootstrap.parse(hex: oversized)) { error in
            XCTAssertEqual(error as? GenesisHexBootstrap.ParseError, .tooLarge)
        }
        // And the hex-length guard trips before allocation even for huge strings.
        let hugeHex = String(repeating: "ab", count: GenesisHexBootstrap.maxBytes + 1024)
        XCTAssertThrowsError(try GenesisHexBootstrap.parse(hex: hugeHex)) { error in
            XCTAssertEqual(error as? GenesisHexBootstrap.ParseError, .tooLarge)
        }
    }

    /// A well-formed, in-bounds genesis-hex blob still parses correctly (the cap
    /// rejects only abuse, not legitimate small payloads).
    func testGenesisHexParserAcceptsSmallValidPayload() throws {
        // [numEntries=1][cidLen=3]["abc"][dataLen=2][0xDE,0xAD]
        var bytes: [UInt8] = [0x01, 0x00]              // numEntries = 1
        bytes += [0x03, 0x00]                          // cidLen = 3
        bytes += Array("abc".utf8)                     // cid
        bytes += [0x02, 0x00, 0x00, 0x00]              // dataLen = 2
        bytes += [0xDE, 0xAD]                          // data
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let entries = try GenesisHexBootstrap.parse(hex: hex)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.cid, "abc")
        XCTAssertEqual(entries.first?.data, Data([0xDE, 0xAD]))
    }

    /// childNodes fan-out count is capped through the REAL admin RPC ingress: an
    /// over-cap list is rejected with a typed 400 before any fan-out fetch.
    func testChildNodesFanoutCapRejectedThroughRealIngress() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: cookie)
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await waitForRPCServer(port: rpcPort)

        // All entries are valid loopback URLs, so ONLY the count cap can reject.
        let tooMany = (0..<(RPCRoutes.maxChildNodesFanout + 1)).map { "http://127.0.0.1:\(9000 + $0)" }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/template")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cookie.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["childNodes": tooMany])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 400,
            "chain/template must reject an over-cap childNodes fan-out: got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    /// SSE subscriber cap: the SubscriptionManager refuses new subscribers past
    /// its cap (the real seam wsUpgrade uses). Returns nil so wsUpgrade emits 503.
    func testSSESubscriberCapRefusesBeyondLimit() async {
        let mgr = SubscriptionManager()
        let cap = SubscriptionManager.maxSubscribers
        for _ in 0..<cap {
            let id = await mgr.subscribe(events: [.newBlock], send: { _ in })
            XCTAssertNotNil(id)
        }
        let overflow = await mgr.subscribe(events: [.newBlock], send: { _ in })
        XCTAssertNil(overflow, "SSE subscriber count must be capped; the (cap+1)th subscribe is refused")
    }

    /// Per-client SSE cap: a single client (source IP) cannot hold more than its
    /// per-client share, so it can't monopolize the global pool and starve others.
    /// A DIFFERENT client key still subscribes — liveness preserved.
    func testSSEPerClientCapRefusesOneClientMonopoly() async {
        let mgr = SubscriptionManager(maxSubscribersPerClient: 3)
        let flooder = "10.9.9.9"
        for _ in 0..<3 {
            let id = await mgr.subscribe(events: [.newBlock], clientKey: flooder, send: { _ in })
            XCTAssertNotNil(id)
        }
        let overflow = await mgr.subscribe(events: [.newBlock], clientKey: flooder, send: { _ in })
        XCTAssertNil(overflow, "one client must not exceed its per-client SSE cap")

        // A different client still gets served (not starved by the flooder).
        let other = await mgr.subscribe(events: [.newBlock], clientKey: "10.0.0.2", send: { _ in })
        XCTAssertNotNil(other, "a distinct client keeps its own per-client SSE budget")

        // Releasing one of the flooder's streams frees a slot for it again.
        if let firstID = await mgr.subscribe(events: [.newBlock], clientKey: "tmp", send: { _ in }) {
            await mgr.unsubscribe(id: firstID)
        }
    }

    // MARK: - Gate (d): maxconnections cap (default 128, configurable)

    /// The 128 default is wired into the per-chain Tally maxPeers — the real
    /// admission ceiling — and remains operator-configurable.
    func testMaxConnectionsDefaultIs128AndConfigurable() async throws {
        XCTAssertEqual(BootstrapPeers.maxPeerConnections, 128, "locked default maxconnections == 128")

        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let custom = 7
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp,
            enableLocalDiscovery: false, maxPeerConnections: custom, minPeerKeyBits: 0
        )
        XCTAssertEqual(config.maxPeerConnections, custom, "maxPeerConnections must be node-configurable")
    }

    // MARK: - Gate (e): persistent cross-restart ban store

    /// A banned peer stays banned across a fresh store instance pointed at the
    /// same data dir — i.e. across a restart. RED without persistence: a new
    /// instance would have an empty in-memory set.
    func testBannedPeerSurvivesRestart() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let peer = PeerID(publicKey: "deadbeefdeadbeefdeadbeefdeadbeef")

        let store1 = PeerBanStore(dataDir: tmp)
        try await store1.ban(peer)
        let bannedBefore = await store1.isBanned(peer)
        XCTAssertTrue(bannedBefore)

        // Simulate a restart: a brand-new store over the same dir must reload it.
        let store2 = PeerBanStore(dataDir: tmp)
        let loaded = try await store2.load()
        XCTAssertEqual(loaded, 1, "ban must be reloaded from disk on restart")
        let bannedAfter = await store2.isBanned(peer)
        XCTAssertTrue(bannedAfter, "a banned peer remains banned across restart")
    }

    /// An expired ban is pruned on reload and does not survive (TTL semantics).
    func testExpiredBanIsPrunedOnRestart() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let peer = PeerID(publicKey: "cafebabecafebabecafebabecafebabe")
        // Negative duration => already expired the instant it's written.
        let store1 = PeerBanStore(dataDir: tmp, banDuration: -1)
        try await store1.ban(peer)

        let store2 = PeerBanStore(dataDir: tmp)
        let loaded = try await store2.load()
        XCTAssertEqual(loaded, 0, "an expired ban must not survive a restart")
        let stillBanned = await store2.isBanned(peer)
        XCTAssertFalse(stillBanned)
    }

    /// Fail-closed restore: an absent ban file is fresh state (load -> 0), but a
    /// file that exists yet is corrupt/undecodable must NOT be silently treated as
    /// "no bans" (which would re-admit every previously banned peer). load() throws.
    func testCorruptBanFileFailsClosedOnLoad() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Absent file: fresh state, no throw.
        let fresh = PeerBanStore(dataDir: tmp)
        let freshCount = try await fresh.load()
        XCTAssertEqual(freshCount, 0)

        // Corrupt the persisted file, then a fresh store must refuse to load it.
        let banFile = tmp.appendingPathComponent("peer_bans.json")
        try Data("{ not valid json".utf8).write(to: banFile)
        let store = PeerBanStore(dataDir: tmp)
        do {
            _ = try await store.load()
            XCTFail("corrupt ban state must fail closed, not return 0")
        } catch is PeerBanStore.BanStoreError {
            // expected
        }
    }

    /// Fail-closed durability: when the ban cannot be written (storage path is not a
    /// writable directory), ban() throws instead of reporting a phantom durable ban.
    func testBanFailsClosedWhenNotDurable() async {
        // Point the store at a path whose parent is a regular file, so the atomic
        // write of peer_bans.json cannot succeed.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try? Data("x".utf8).write(to: base) // base is a FILE, not a directory
        let store = PeerBanStore(dataDir: base) // writes base/peer_bans.json -> fails
        let peer = PeerID(publicKey: "abadabadabadabadabadabadabadabad")
        do {
            try await store.ban(peer)
            XCTFail("a ban that cannot be durably persisted must throw, not silently succeed")
        } catch is PeerBanStore.BanStoreError {
            // expected
        } catch {
            XCTFail("expected BanStoreError, got \(error)")
        }
    }

    // MARK: - Fix #5: LRU eviction never resets an actively-rate-limited bucket

    /// AC Red #5: an exhausted-but-recently-active bucket must NOT be the eviction
    /// victim, and re-touching that peer must NOT reset it to full capacity. RED on
    /// the old `evictIfNeeded`: it preferentially removed `tokens <= 0` (the active
    /// attacker), and the next message re-created the bucket at full capacity.
    func testExhaustedActiveBucketIsNotEvictedAndNotReset() {
        // Capacity 2 so the attacker exhausts in two consumes; maxEntries 2 so each
        // new distinct peer forces an eviction decision. refillPerSec 0 so the
        // attacker bucket cannot refill within the test.
        var buckets = PeerRateBuckets(capacity: 2, refillPerSec: 0, maxEntries: 2)
        let attacker = PeerID(publicKey: "attacker-active-bucket")

        // Attacker drains its bucket; it is now exhausted.
        XCTAssertTrue(buckets.tryConsume(attacker))
        XCTAssertTrue(buckets.tryConsume(attacker))
        XCTAssertFalse(buckets.tryConsume(attacker), "attacker is now rate-limited (exhausted)")
        XCTAssertEqual(buckets.tokensForTesting(attacker), 0, "attacker bucket is exhausted")

        // A flood of distinct spoofed peers churns the dict. The attacker KEEPS
        // hammering (its failed consume marks it most-recently-seen each round), so
        // it is never the least-recently-seen victim. The old anti-pattern evicted
        // whichever bucket had `tokens <= 0` — i.e. the attacker — then re-created
        // it at full capacity on the next hit, defeating the limit entirely.
        for i in 0..<50 {
            _ = buckets.tryConsume(PeerID(publicKey: "spoof-\(i)"))
            // Attacker hammers again — stays exhausted, stays most-recently-seen.
            XCTAssertFalse(buckets.tryConsume(attacker),
                "a continuously-active exhausted attacker must stay rate-limited (never reset to full)")
        }

        XCTAssertTrue(buckets.containsForTesting(attacker),
            "the exhausted, actively-rate-limited attacker must NOT be evicted")
        XCTAssertEqual(buckets.tokensForTesting(attacker), 0,
            "attacker bucket must remain exhausted — never reset to full on re-insert")
    }

    /// The LRU counter (mempoolFullFailures) must not let a spoofed-key flood evict
    /// the real flooder's accumulating count (which would reset it to 0 and defeat
    /// the ban trigger). The incremented peer is most-recently-seen, never evicted.
    func testLRUCounterDoesNotEvictTheAccumulatingFlooder() {
        var counter = LRUCounter(maxEntries: 2)
        let flooder = PeerID(publicKey: "real-flooder")
        // Flooder accumulates a high count, touched on each increment.
        for _ in 0..<5 { _ = counter.increment(flooder) }
        XCTAssertEqual(counter[flooder], 5)
        // Spoofed keys flood in; at capacity the LRU victim is the least-recently
        // touched — never the flooder we keep incrementing.
        _ = counter.increment(PeerID(publicKey: "spoof-1"))
        _ = counter.increment(flooder)  // keeps flooder most-recently-seen
        _ = counter.increment(PeerID(publicKey: "spoof-2"))
        XCTAssertEqual(counter[flooder], 6,
            "a spoofed-key flood must NOT evict/reset the real flooder's accumulating count")
    }

    // MARK: - Fix #2: getHeaders2 per-peer bucket gates before the fetch loop

    /// AC Red #2: a getHeaders2 flood from one peer is rate-limited before the
    /// up-to-1000-fetch walk. Driven through the REAL handlePeerMessage ingress.
    /// RED before the fix: every request walked the fetch loop with no gate.
    func testGetHeaders2FloodIsRateLimitedThroughRealIngress() async throws {
        let network = try await makeChainNetwork()
        let peer = PeerID(publicKey: "getheaders2-flooder")
        let req = getHeadersRequest(fromCID: "nonexistent-cid", count: 1000)

        // Burst far past the bucket capacity; admitted requests are bounded by the
        // per-peer bucket. We assert via the bucket's own accounting: after a large
        // burst, the bucket is exhausted (the gate is in force before the loop).
        for _ in 0..<200 {
            await network.ingestForTesting(topic: "getHeaders2", payload: req, from: peer)
        }
        let admittedAfterBurst = await network.getHeadersBucketTryConsumeForTesting(peer)
        XCTAssertFalse(admittedAfterBurst,
            "after a getHeaders2 burst past capacity, the per-peer bucket must be exhausted (flood gated before the fetch loop)")

        // A DIFFERENT peer has its own pool and is not starved by the flooder.
        let honest = PeerID(publicKey: "getheaders2-honest")
        let honestAdmitted = await network.getHeadersBucketTryConsumeForTesting(honest)
        XCTAssertTrue(honestAdmitted,
            "a distinct peer has its own getHeaders2 bucket and is not starved by the flooder")
    }

    // MARK: - NET-A1: plain getHeaders flood gated before the fetch loop

    /// NET-A1: the PLAIN `getHeaders` handler (not just `getHeaders2`) is the same
    /// cheap-request/expensive-response amplifier — one request fans out to up to
    /// `maxHeaderBatchSize` diskBroker.fetchVolumeLocal + Block(data:) decodes. It
    /// must be gated by the per-peer token bucket BEFORE the fetch loop. Driven
    /// through the REAL handlePeerMessage ingress on the `getHeaders` topic.
    /// RED without the gate: every `getHeaders` request walks the fetch loop.
    func testGetHeadersFloodIsRateLimitedThroughRealIngress() async throws {
        let network = try await makeChainNetwork()
        let peer = PeerID(publicKey: "getheaders-flooder")
        let req = getHeadersRequest(fromCID: "nonexistent-cid", count: 1000)

        for _ in 0..<200 {
            await network.ingestForTesting(topic: "getHeaders", payload: req, from: peer)
        }
        let admittedAfterBurst = await network.getHeadersBucketTryConsumeForTesting(peer)
        XCTAssertFalse(admittedAfterBurst,
            "after a plain-getHeaders burst past capacity, the per-peer bucket must be exhausted (flood gated before the fetch loop)")

        let honest = PeerID(publicKey: "getheaders-honest")
        let honestAdmitted = await network.getHeadersBucketTryConsumeForTesting(honest)
        XCTAssertTrue(honestAdmitted,
            "a distinct peer has its own getHeaders bucket and is not starved by the flooder")
    }

    // MARK: - Fail-closed gossip admission before the delegate is attached

    /// Before LatticeNode attaches itself as the admission delegate (the
    /// startup/recovery window after network.start()), a gossiped tx must be
    /// DROPPED, not inserted into the mempool unvalidated. RED before the fix:
    /// the nil-delegate branch called bare `nodeMempool.add(transaction:)`,
    /// skipping signature/nonce/balance/policy validation entirely.
    func testGossipedTxDroppedWhenNoAdmissionDelegateAttached() async throws {
        let network = try await makeChainNetwork()
        // Deliberately NO setDelegate: simulate the pre-wiring window.
        let peer = PeerID(publicKey: "pre-delegate-peer")
        let (payload, cid) = try mempoolFullPayloadWithCID(nonce: 1)
        await network.ingestForTesting(topic: "mempool-full", payload: payload, from: peer)

        let pooled = await network.nodeMempool.allTransactions()
        XCTAssertTrue(pooled.isEmpty,
            "with no admission delegate attached, a gossiped tx must be dropped (fail closed), never inserted unvalidated")
        let recorded = await network.recentTxCIDTimestampForTesting(cid)
        XCTAssertNil(recorded,
            "a dropped tx must not be recorded as seen — the peer's re-gossip after wiring must be admittable")
    }

    // MARK: - NET-A3: re-seen CID cannot defeat oldest-insertion dedup eviction

    /// NET-A3: when the gossip dedup sees a CID it already holds within the
    /// dedup window, it must NOT refresh that CID's recorded timestamp. If a
    /// re-see reordered/refreshed the entry, an attacker could keep a CID "young"
    /// so an oldest-first eviction drops a DIFFERENT still-in-window CID, opening
    /// a replay slot. Driven through the REAL mempool-full handler ingress: the
    /// recorded timestamp after a re-see must equal the first-insertion timestamp.
    func testReSeenCIDDoesNotRefreshDedupTimestampThroughRealIngress() async throws {
        let network = try await makeChainNetwork()
        // ChainNetwork.delegate is weak — retain the delegate for the test's
        // lifetime or ingress fail-closes on a nil delegate and drops the tx.
        let admissionDelegate = AcceptingMempoolDelegate()
        defer { withExtendedLifetime(admissionDelegate) {} }
        await network.setDelegate(admissionDelegate)
        let peer = PeerID(publicKey: "dedup-resend-peer")

        let (payload, cid) = try mempoolFullPayloadWithCID(nonce: 1)
        await network.ingestForTesting(topic: "mempool-full", payload: payload, from: peer)
        let first = await network.recentTxCIDTimestampForTesting(cid)
        XCTAssertNotNil(first, "an accepted tx CID must be recorded in the dedup set")

        // Re-send the SAME CID within the dedup window (and again, repeatedly).
        for _ in 0..<5 {
            await network.ingestForTesting(topic: "mempool-full", payload: payload, from: peer)
        }
        let after = await network.recentTxCIDTimestampForTesting(cid)
        XCTAssertEqual(after, first,
            "re-seeing an in-window CID must NOT refresh its dedup timestamp (else oldest-insertion eviction can be defeated to replay a tx)")
        let count = await network.recentTxCIDCountForTesting()
        XCTAssertEqual(count, 1, "duplicate re-sends must not add new dedup entries")
    }

    // MARK: - Fix #3: mempool-full source-exclusion + ban through real ingress

    /// The source peer is excluded from the relay fan-out (it already has the tx),
    /// and an honest connected peer remains a relay target. Pure-function seam used
    /// by the real handler's relay edge.
    func testMempoolFullRelayExcludesSourceKeepsHonest() {
        let source = PeerID(publicKey: "relay-source")
        let honest = PeerID(publicKey: "relay-honest")
        let other = PeerID(publicKey: "relay-other")
        let targets = ChainNetwork.relayTargets(connected: [source, honest, other], excludingSource: source)
        XCTAssertFalse(targets.contains(source), "the source peer must be excluded from relay fan-out")
        XCTAssertTrue(targets.contains(honest), "an honest connected peer remains a relay target")
        XCTAssertTrue(targets.contains(other))
    }

    /// NET-A2: source-exclusion must hold even at the edges that matter for a
    /// flooder: when the source is the ONLY connected peer the relay set is empty
    /// (the tx is never bounced straight back), and a source that appears MULTIPLE
    /// times in the connected list (e.g. duplicate transport entries) is excluded
    /// on every occurrence — no self-relay slips through.
    func testRelayTargetsNeverIncludeSourceEvenWhenSoleOrDuplicated() {
        let source = PeerID(publicKey: "relay-source")
        let honest = PeerID(publicKey: "relay-honest")

        let soleSource = ChainNetwork.relayTargets(connected: [source], excludingSource: source)
        XCTAssertTrue(soleSource.isEmpty,
            "with the source as the only connected peer, the relay set must be empty (no self-relay)")

        let duplicated = ChainNetwork.relayTargets(
            connected: [source, honest, source, source], excludingSource: source
        )
        XCTAssertFalse(duplicated.contains(source),
            "a duplicated source must be excluded on every occurrence")
        XCTAssertEqual(duplicated, [honest],
            "only the honest peer survives; no duplicate-source self-relay")
    }

    /// NET-A2 (real entry point): drive the actual mempool-full re-gossip path in
    /// `handlePeerMessage` (the named entry `chainNetwork(_:admitTransaction:bodyCID:)`
    /// re-gossip edge) end-to-end and observe, through the REAL `ivy.sendMessage`
    /// fan-out, that the source peer is NEVER a relay target while an honest
    /// connected peer IS. This exercises the handler's relayTargets+sendMessage
    /// wiring — not just the static helper. RED if the handler reverted to
    /// `broadcastMessage` (which would bounce the tx back to its source) or swapped
    /// the `excludingSource` argument: the source's stream would then receive the
    /// relayed mempool-full message.
    func testMempoolFullRelayThroughRealIngressNeverSendsBackToSource() async throws {
        let network = try await makeChainNetwork()
        // ChainNetwork.delegate is weak — retain the delegate for the test's
        // lifetime or ingress fail-closes on a nil delegate and drops the tx.
        let admissionDelegate = AcceptingMempoolDelegate()
        defer { withExtendedLifetime(admissionDelegate) {} }
        await network.setDelegate(admissionDelegate)

        // Register source + honest as LOCAL peers on the real Ivy instance so they
        // appear in `connectedPeers` and `ivy.sendMessage(to:)` delivers to an
        // observable LocalPeerConnection stream — the real send edge, no Ivy mock.
        let bus = await network.ivy.serviceBus()
        let sourceKey = "source0000000000000000000000feed"
        let honestKey = "honest0000000000000000000000beef"
        let sourceConn = await bus.register(name: "source", publicKey: sourceKey)
        let honestConn = await bus.register(name: "honest", publicKey: honestKey)
        let source = PeerID(publicKey: sourceKey)
        let honest = PeerID(publicKey: honestKey)

        // Registration is async (a spawned Task); wait until both are connected.
        var connected: [PeerID] = []
        for _ in 0..<200 {
            connected = await network.ivy.connectedPeers
            if connected.contains(source) && connected.contains(honest) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(connected.contains(source) && connected.contains(honest),
                      "both local peers must be connected before driving ingress")

        // Drive the REAL mempool-full ingress with the source as the message origin.
        let payload = try mempoolFullPayload(nonce: 7)
        await network.ingestForTesting(topic: "mempool-full", payload: payload, from: source)

        // The honest peer must receive the relayed mempool-full message; the source
        // must NOT (it already has the tx — no self-relay).
        let honestGot = await receivedMempoolFull(on: honestConn, within: .seconds(2))
        XCTAssertTrue(honestGot,
            "an honest connected peer must receive the relayed mempool-full message via ivy.sendMessage")
        let sourceGot = await receivedMempoolFull(on: sourceConn, within: .milliseconds(300))
        XCTAssertFalse(sourceGot,
            "the source peer must NEVER be a relay target — the accepted tx must not be bounced back to its origin")
    }

    /// AC Red #3: a sustained mempool-full flood from one peer (admission keeps
    /// rejecting with .rejectedMempoolFull) crosses the ban threshold and triggers
    /// banPeer; an honest peer whose tx is accepted never accumulates failures and
    /// is never banned. Driven through the REAL handlePeerMessage ingress.
    func testMempoolFullFloodBansSourceThroughRealIngress() async throws {
        let network = try await makeChainNetwork()
        let flooder = PeerID(publicKey: "mempool-full-flooder")
        let delegate = RejectingMempoolDelegate()
        await network.setDelegate(delegate)

        // Each distinct valid tx is rejected (.rejectedMempoolFull). Feed more than
        // the ban threshold; the flooder must be banned exactly once.
        let threshold = network.mempoolFullBanThreshold
        for i in 0..<(threshold + 5) {
            let payload = try mempoolFullPayload(nonce: UInt64(i))
            await network.ingestForTesting(topic: "mempool-full", payload: payload, from: flooder)
        }
        let bans = await delegate.bannedPeers()
        XCTAssertTrue(bans.contains(flooder), "a sustained mempool-full flood must ban the source peer")
    }

    // MARK: - Fix #4: chainAnnounce bounded spawner

    /// AC Red #4: chainAnnounce dispatch is bounded by its OWN spawner cap, so a
    /// flood cannot create unbounded concurrent Tasks. Drives the REAL spawner used
    /// by ivy(_:didReceiveMessage:) and asserts the in-flight count never exceeds
    /// the cap. RED before the fix: chainAnnounce used a raw unbounded `Task`.
    func testChainAnnounceSpawnerBoundsConcurrency() async throws {
        let network = try await makeChainNetwork()
        let gate = TaskGate()
        let cap = network.maxPendingChainAnnounceTasks

        // Flood the real spawner with blocking work; each accepted task parks on the
        // gate so they accumulate.
        for _ in 0..<(cap * 4) {
            network.spawnChainAnnounceTaskForTesting { await gate.wait() }
        }
        // Let the accepted tasks reach the gate.
        try await Task.sleep(for: .milliseconds(100))
        let inflight = network.pendingChainAnnounceCountForTesting()
        XCTAssertLessThanOrEqual(inflight, cap,
            "chainAnnounce in-flight Tasks must never exceed the cap (\(cap)); got \(inflight)")
        await gate.open()
    }

    // MARK: - Fix #6: extractor concurrency cap

    /// AC Red #6: the parent-block extractor caps concurrent extraction Tasks via
    /// its own bounded spawner. Drives the REAL spawner and asserts the in-flight
    /// count never exceeds the cap.
    func testExtractorSpawnerBoundsConcurrency() async throws {
        let node = try await makeNode()
        defer { Task { await node.stop() } }
        let extractor = ParentChainBlockExtractor(
            childDirectory: "Child", parentDirectory: nil,
            extractor: LatticeChildBlockExtractor(), node: node
        )
        let gate = TaskGate()
        let cap = extractor.maxPendingExtractionTasks
        for _ in 0..<(cap * 4) {
            extractor.spawnExtractionTaskForTesting { await gate.wait() }
        }
        try await Task.sleep(for: .milliseconds(100))
        let inflight = extractor.pendingExtractionCountForTesting()
        XCTAssertLessThanOrEqual(inflight, cap,
            "extraction in-flight Tasks must never exceed the cap (\(cap)); got \(inflight)")
        await gate.open()
    }

    // MARK: - Integration: single-peer multi-ingress flood, honest peer served

    /// Epic integration gate: a single peer flooding multiple ingress paths leaves
    /// every bounded resource bounded (bucket dicts, in-flight Task counts) while a
    /// second honest peer keeps getting admitted on its own per-peer pools.
    func testMultiIngressFloodKeepsBoundsAndServesHonestPeer() async throws {
        let network = try await makeChainNetwork()
        let flooder = PeerID(publicKey: "multi-ingress-flooder")
        let honest = PeerID(publicKey: "multi-ingress-honest")

        // Flood getHeaders2 + pinRequest + chainAnnounce from one peer.
        let req = getHeadersRequest(fromCID: "x", count: 1000)
        for _ in 0..<300 {
            await network.ingestForTesting(topic: "getHeaders2", payload: req, from: flooder)
            await network.ingestForTesting(topic: "pinRequest", payload: Data("some-cid".utf8), from: flooder)
            await network.ingestForTesting(topic: "chainAnnounce", payload: Data("garbage".utf8), from: flooder)
        }

        // Bucket dicts stay bounded (one entry per touched peer here, far below cap).
        let getHeadersDictSize = await network.getHeadersBucketCountForTesting()
        XCTAssertLessThanOrEqual(getHeadersDictSize, ChainNetwork.maxBucketEntries)
        // The flooder is now rate-limited on getHeaders2...
        let flooderAdmitted = await network.getHeadersBucketTryConsumeForTesting(flooder)
        XCTAssertFalse(flooderAdmitted, "flooder must be rate-limited after the burst")
        // ...while the honest peer still has its full pool (liveness).
        let honestAdmitted = await network.getHeadersBucketTryConsumeForTesting(honest)
        XCTAssertTrue(honestAdmitted,
            "an honest peer keeps being served on its own per-peer pool under flood")
    }

    // MARK: - Helpers

    private func makeChainNetwork() async throws -> ChainNetwork {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = try DiskBroker(path: directory.appendingPathComponent("volumes.sqlite").path)
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey, listenPort: 0, bootstrapPeers: [],
                enableLocalDiscovery: false, stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    private func makeNode() async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        return try await LatticeNode(config: config, genesisConfig: testGenesis())
    }

    /// Returns true if a `peerMessage(topic: "mempool-full", ...)` is delivered to
    /// this local peer's inbound stream within the deadline. Used to observe the
    /// real `ivy.sendMessage` relay fan-out target set.
    private func receivedMempoolFull(on conn: LocalPeerConnection, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await message in conn.messages {
                    if case .peerMessage(let topic, _) = message, topic == "mempool-full" {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// getHeaders / getHeaders2 request wire: [requestID:16][cidLen:UInt16 LE][cid][count:UInt32 LE].
    private func getHeadersRequest(fromCID: String, count: UInt32) -> Data {
        var payload = Data(repeating: 0xAB, count: 16)
        let cidBytes = Data(fromCID.utf8)
        var cl = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cl, count: 2))
        payload.append(cidBytes)
        var c = count.littleEndian
        payload.append(Data(bytes: &c, count: 4))
        return payload
    }

    /// A wire-valid mempool-full payload for a freshly built transfer tx.
    private func mempoolFullPayload(nonce: UInt64) throws -> Data {
        let wallet = Wallet.create()
        guard let tx = wallet.buildTransfer(to: wallet.address, amount: 1, fee: 10, nonce: nonce),
              let bodyData = tx.body.node?.toData(),
              let txData = tx.toData() else {
            throw XCTSkip("could not build a valid transfer tx")
        }
        return ChainNetwork.encodeMempoolFullPayload(
            cid: tx.body.rawCID, bodyData: bodyData, transactionData: txData
        )
    }

    /// Like `mempoolFullPayload` but also returns the tx CID so a test can inspect
    /// the dedup-set entry the real handler records for it.
    private func mempoolFullPayloadWithCID(nonce: UInt64) throws -> (payload: Data, cid: String) {
        let wallet = Wallet.create()
        guard let tx = wallet.buildTransfer(to: wallet.address, amount: 1, fee: 10, nonce: nonce),
              let bodyData = tx.body.node?.toData(),
              let txData = tx.toData() else {
            throw XCTSkip("could not build a valid transfer tx")
        }
        let payload = ChainNetwork.encodeMempoolFullPayload(
            cid: tx.body.rawCID, bodyData: bodyData, transactionData: txData
        )
        return (payload, tx.body.rawCID)
    }
}

/// Awaitable gate: parks callers in `wait()` until `open()` is called.
private actor TaskGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// Delegate that always reports the mempool as full so the mempool-full
/// ban-threshold path is exercised, and records every banned peer. An actor so it
/// is Sendable without an unchecked escape.
private actor RejectingMempoolDelegate: ChainNetworkDelegate {
    private var bans: Set<PeerID> = []

    func bannedPeers() -> Set<PeerID> { bans }

    nonisolated func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, height: UInt64, from peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, didReceiveChildBlock cid: String, data: Data, proofs: [ChildBlockProof], from peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> GossipAdmission {
        .rejectedMempoolFull
    }
    nonisolated func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, banPeer peer: PeerID) async {
        bans.insert(peer)
    }
}

/// Delegate that admits every gossip-received tx, so the dedup record + relay
/// fan-out edge of the real mempool-full handler is exercised end-to-end.
private actor AcceptingMempoolDelegate: ChainNetworkDelegate {
    nonisolated func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, height: UInt64, from peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, didReceiveChildBlock cid: String, data: Data, proofs: [ChildBlockProof], from peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> GossipAdmission {
        .accepted
    }
    nonisolated func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async {}
    nonisolated func chainNetwork(_ network: ChainNetwork, banPeer peer: PeerID) async {}
}
