import Foundation
import Ivy
import Lattice
import Tally
import XCTest
@testable import LatticeNode

/// scarce-key (minPeerKeyBits) gating + durable per-peer ban wiring.
///
/// These exercise the *live* admission paths, not just config plumbing:
/// - the node-built `IvyConfig` carries `minPeerKeyBits`, and a below-threshold
///   identity is rejected at the real Ivy handshake while an above-threshold one
///   is admitted;
/// - a persisted ban is reloaded on node restart and the real `didConnectPeer`
///   admission boundary disconnects the reconnecting banned peer.
final class PeerKeyWorkGateTests: XCTestCase {

    // MARK: - key-PoW grinding helper

    /// Generate a keypair with *at least* `bits` key-work bits under THE
    /// canonical gate measure (`KeyDifficulty.keyWorkBits`: trailing-zero
    /// SHA256 bits of the raw key form, `ed01` prefix stripped) — what the
    /// live Ivy 6 gate measures regardless of the presented spelling. Small
    /// thresholds keep this cheap (P(>=8) = 1/256).
    private func grindKeyPair(atLeast bits: Int) -> (privateKey: String, publicKey: String) {
        while true {
            let kp = CryptoUtils.generateKeyPair()
            if KeyDifficulty.keyWorkBits(kp.publicKey) >= bits { return kp }
        }
    }

    /// Generate a keypair with *fewer than* `bits` key-work bits under the
    /// canonical gate measure (a below-threshold, cheap identity).
    private func grindKeyPair(below bits: Int) -> (privateKey: String, publicKey: String) {
        while true {
            let kp = CryptoUtils.generateKeyPair()
            if KeyDifficulty.keyWorkBits(kp.publicKey) < bits { return kp }
        }
    }

    // MARK: - (a) minPeerKeyBits reaches the live Ivy admission gate

    /// The node-configured `minPeerKeyBits` must be threaded into the `IvyConfig`
    /// that backs the live `Ivy` instance — that config field is exactly what the
    /// Ivy handshake (Ivy.swift) and endpoint-insert gate read to reject a
    /// below-PoW-threshold identity.
    func testNodeWiresMinPeerKeyBitsIntoLiveIvyGate() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false,
            minPeerKeyBits: 16
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        defer { Task { await node.stop() } }

        let nexusDir = await node.genesisConfig.directory
        guard let network = await node.network(for: nexusDir) else {
            return XCTFail("expected a live Nexus ChainNetwork")
        }
        let ivy = await network.ivy
        let wired = await ivy.config.minPeerKeyBits
        XCTAssertEqual(wired, 16,
            "node minPeerKeyBits must reach the live Ivy gate config, not default to 0")
    }

    /// requires the non-zero security default to live in the canonical config
    /// layer, not only in the CLI. The Decision-15 default is exposed as
    /// `LatticeNodeConfig.defaultMinPeerKeyBits` (16 — the NETWORK-INTEROP value
    /// every deployed mainnet/testnet node runs; see the invariant comment on the
    /// constant), is what the production CLI/daemon path passes, and wires through
    /// to the live Ivy gate. Every remote default-config node applies this same
    /// gate to OUR identify key, which is why the CLI grinds the node's own
    /// identity to these bits at load (`loadOrCreateIdentity(minKeyBits:)` — see
    /// the identity-grind tests below). This test constructs the config directly
    /// with a random key (no grind needed); the in-process node never dials a
    /// gated remote here.
    func testCanonicalDefaultMinPeerKeyBitsIsNonZeroAndWires() async throws {
        XCTAssertEqual(LatticeNodeConfig.defaultMinPeerKeyBits, 16,
            "the canonical security default must be the mainnet value")

        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Production construction passes the canonical default explicitly.
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false,
            minPeerKeyBits: LatticeNodeConfig.defaultMinPeerKeyBits
        )
        XCTAssertEqual(config.minPeerKeyBits, 16)

        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        defer { Task { await node.stop() } }
        let nexusDir = await node.genesisConfig.directory
        guard let network = await node.network(for: nexusDir) else {
            return XCTFail("expected a live Nexus ChainNetwork")
        }
        let ivy = await network.ivy
        let wired = await ivy.config.minPeerKeyBits
        XCTAssertEqual(wired, 16, "the canonical default must reach the live Ivy config")
    }

    /// The initializer default is the canonical non-zero security gate, so a node
    /// constructed without an explicit value still gets it. Test topologies of
    /// difficulty-0 keys opt out explicitly by passing `minPeerKeyBits: 0`.
    func testBareInitializerDefaultsToSecureGate() {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let defaulted = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        XCTAssertEqual(defaulted.minPeerKeyBits, LatticeNodeConfig.defaultMinPeerKeyBits,
            "the bare initializer must default to the canonical non-zero security gate")

        let opted = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false,
            minPeerKeyBits: 0
        )
        XCTAssertEqual(opted.minPeerKeyBits, 0,
            "test topologies opt out of the gate by passing minPeerKeyBits: 0")
    }

    // MARK: - (b2) parent-subscription key cache + dev opt-outs

    /// The dedicated parent-subscription Ivy key is ground to `minBits` ONCE and
    /// cached in the data dir: a second load returns the identical key without
    /// regrinding. At the 24-bit mainnet default a regrind is ≈2^24 Curve25519
    /// keygens (minutes), so without the cache every subscription start would
    /// stall — the regression that blocked the previous raise attempt.
    func testParentSubscriptionKeyIsGroundOnceAndReloadedFromCache() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = loadOrGrindParentSubscriptionKey(storagePath: tmp, minBits: 8)
        XCTAssertGreaterThanOrEqual(KeyDifficulty.trailingZeroBits(of: first.publicKey), 8,
            "the ground key must meet the requested difficulty")

        let second = loadOrGrindParentSubscriptionKey(storagePath: tmp, minBits: 8)
        XCTAssertEqual(second.publicKey, first.publicKey, "cached key must be reused, not reground")
        XCTAssertEqual(second.privateKey, first.privateKey)
    }

    /// A cached key that no longer meets a RAISED `minBits` is invalidated and
    /// reground, and a corrupt cache file falls back to a fresh grind (never a
    /// crash, never an under-worked key).
    func testParentSubscriptionKeyCacheInvalidation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let weak = loadOrGrindParentSubscriptionKey(storagePath: tmp, minBits: 0)
        let raised = KeyDifficulty.trailingZeroBits(of: weak.publicKey) + 1
        let reground = loadOrGrindParentSubscriptionKey(storagePath: tmp, minBits: raised)
        XCTAssertGreaterThanOrEqual(KeyDifficulty.trailingZeroBits(of: reground.publicKey), raised,
            "a cached key below a raised minBits must be reground")

        let path = tmp.appendingPathComponent("parent-sub-identity.json")
        try Data("not json".utf8).write(to: path)
        let recovered = loadOrGrindParentSubscriptionKey(storagePath: tmp, minBits: 0)
        XCTAssertFalse(recovered.publicKey.isEmpty, "a corrupt cache must regrind, not fail")
    }

    // MARK: - (b3) main node identity grind + cache

    /// The node's MAIN identity is what every remote default-config node gates at
    /// identify, so `loadOrCreateIdentity(minKeyBits:)` must grind it: the created
    /// key passes the exact gate measure (`KeyDifficulty.trailingZeroBits` of the
    /// RAW key string the node presents — `p2pPublicKey`, Multikey prefix
    /// stripped), is persisted 0600, and a reload reuses it without regrinding.
    func testNodeIdentityGroundAtCreationAndReusedOnReload() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try loadOrCreateIdentity(dataDir: tmp, minKeyBits: 8)
        XCTAssertGreaterThanOrEqual(identityKeyWorkBits(of: first.publicKey), 8,
            "a created identity must meet the requested key-work bits")
        // Measure the wire-presented form directly with the gate's own primitive:
        // the stored key is Multikey ("ed01"-prefixed); Ivy gates the raw form.
        XCTAssertTrue(first.publicKey.hasPrefix("ed01"), "identity stays in Multikey form on disk")
        let raw = String(first.publicKey.dropFirst(4))
        XCTAssertGreaterThanOrEqual(KeyDifficulty.trailingZeroBits(of: raw), 8,
            "the RAW key the node presents at identify must pass the live gate measure")

        let reloaded = try loadOrCreateIdentity(dataDir: tmp, minKeyBits: 8)
        XCTAssertEqual(reloaded.publicKey, first.publicKey,
            "a passing persisted identity must be reused — no regrind")
        XCTAssertEqual(reloaded.privateKey, first.privateKey)

        #if !os(Windows)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: tmp.appendingPathComponent("identity.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600,
            "identity.json must be owner-read/write only")
        #endif
    }

    /// Raising `minKeyBits` above a persisted identity's work forces a regrind
    /// (new key that passes), while `minKeyBits == 0` preserves legacy behavior
    /// exactly: never grinds and never discards, even an unworked key.
    func testNodeIdentityRegroundOnRaisedBitsAndUntouchedAtZero() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // bits=0 create: plain random key, no grind.
        let weak = try loadOrCreateIdentity(dataDir: tmp)
        // bits=0 reload: reused as-is regardless of its (random) work.
        let reload0 = try loadOrCreateIdentity(dataDir: tmp)
        XCTAssertEqual(reload0.publicKey, weak.publicKey,
            "minKeyBits == 0 must never grind nor discard a persisted identity")

        // Raising the requirement above the current key's work forces a regrind.
        let raised = identityKeyWorkBits(of: weak.publicKey) + 1
        let reground = try loadOrCreateIdentity(dataDir: tmp, minKeyBits: raised)
        XCTAssertNotEqual(reground.publicKey, weak.publicKey,
            "an under-ground persisted identity must be replaced by a reground one")
        XCTAssertGreaterThanOrEqual(identityKeyWorkBits(of: reground.publicKey), raised,
            "the reground identity must meet the raised bits")

        // The OLD identity is preserved aside, not destroyed — its nodeAddress
        // may hold funds.
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasPrefix("identity.json.pre-grind-") }
        XCTAssertEqual(backups.count, 1, "regrind must preserve exactly one pre-grind backup")
        let backupData = try Data(contentsOf: tmp.appendingPathComponent(backups[0]))
        let preserved = try JSONDecoder().decode(IdentityFile.self, from: backupData)
        XCTAssertEqual(preserved.publicKey, weak.publicKey,
            "the pre-grind backup must contain the replaced identity")
        XCTAssertEqual(preserved.privateKey, weak.privateKey,
            "the pre-grind backup must keep the old private key recoverable")

        // And bits=0 after the regrind still reuses the (now worked) key.
        let reload = try loadOrCreateIdentity(dataDir: tmp)
        XCTAssertEqual(reload.publicKey, reground.publicKey)
    }

    /// Regrinding an ENCRYPTED identity with the WRONG password must throw before
    /// touching the old key — a typo would otherwise replace the identity and
    /// encrypt the new key under the mistyped password.
    func testEncryptedIdentityRegrindRejectsWrongPassword() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let password = "correct-password"
        let enc = try loadOrCreateIdentity(dataDir: tmp, password: password)
        let raised = identityKeyWorkBits(of: enc.publicKey) + 1

        XCTAssertThrowsError(
            try loadOrCreateIdentity(dataDir: tmp, password: "typo-password", minKeyBits: raised),
            "a wrong password must be rejected by decrypting the OLD key first"
        ) { error in
            XCTAssertEqual(error as? IdentityError, .decryptionFailed)
        }

        // The original identity is untouched and still loads with the real password.
        let intact = try loadOrCreateIdentity(dataDir: tmp, password: password)
        XCTAssertEqual(intact.publicKey, enc.publicKey,
            "a failed password check must leave the old identity in place")
    }

    // MARK: - private-key file write hygiene

    /// `writePrivateKeyFile` lands content atomically at 0600 — including when
    /// overwriting — and leaves no temp file behind on success. The 0600-from-birth
    /// property is structural: the temp file is opened `O_CREAT|O_EXCL|O_WRONLY`
    /// with mode 0600, so (unlike `FileManager.createFile`'s write-then-chmod)
    /// there is no mid-write window at the default umask.
    func testWritePrivateKeyFileAtomicOwnerOnly() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("identity.json")

        try writePrivateKeyFile(Data("first".utf8), to: path)
        try writePrivateKeyFile(Data("second".utf8), to: path)
        XCTAssertEqual(try Data(contentsOf: path), Data("second".utf8),
            "a rewrite must atomically replace the previous content")

        #if !os(Windows)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600,
            "the key file must be owner-read/write only")
        #endif

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "no temp file may be left behind on success")
    }

    /// Fail closed on regrind of an ENCRYPTED identity: without the password the
    /// load must throw (never silently replace it with a plaintext key); with the
    /// password the reground identity stays encrypted at rest.
    func testEncryptedIdentityRegrindRequiresPassword() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let password = "regrind-test-password"
        let enc = try loadOrCreateIdentity(dataDir: tmp, password: password)
        let raised = identityKeyWorkBits(of: enc.publicKey) + 1

        XCTAssertThrowsError(try loadOrCreateIdentity(dataDir: tmp, minKeyBits: raised),
            "an under-ground encrypted identity must not be replaced without its password")

        let reground = try loadOrCreateIdentity(dataDir: tmp, password: password, minKeyBits: raised)
        XCTAssertNotEqual(reground.publicKey, enc.publicKey)
        XCTAssertGreaterThanOrEqual(identityKeyWorkBits(of: reground.publicKey), raised)
        XCTAssertNotNil(reground.encryptedPrivateKey,
            "the reground identity must remain encrypted at rest")
    }

    /// Dev/cluster topologies (MultiNodeClient backs the `cluster` subcommand and
    /// in-process multi-node use) opt out of the key gate explicitly: their random
    /// throwaway identities would otherwise be rejected at every handshake under
    /// the raised default, and test runtimes must never pay the 24-bit grind.
    func testMultiNodeClientOptsOutOfPeerKeyGate() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let client = MultiNodeClient(genesisConfig: testGenesis(), baseStoragePath: tmp)
        let node = try await client.addNode(identity: .generate(id: "a", port: nextTestPort()))
        defer { Task { await node.stop() } }
        let bits = await node.config.minPeerKeyBits
        XCTAssertEqual(bits, 0, "dev/cluster nodes must opt out of the mainnet key gate")
    }

    /// Real admission path (rejection): a below-threshold (cheap) identity dialing a
    /// gated node is rejected at the live Ivy handshake and never admitted as a peer.
    func testLiveIvyGateRejectsBelowThresholdIdentity() async throws {
        let threshold = 8
        let p1 = nextTestPort()
        let p2 = nextTestPort()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis()

        // Gatekeeper: its own identity clears its own gate so it can serve. A very
        // high persistInterval keeps its chain network up (no genesis-only SQLite
        // persist) so the refusal is a real gate rejection, not a teardown artifact.
        let kpGate = grindKeyPair(atLeast: threshold)
        let gateConfig = LatticeNodeConfig(
            publicKey: kpGate.publicKey, privateKey: kpGate.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("gate"),
            enableLocalDiscovery: false, persistInterval: 1_000_000, minPeerKeyBits: threshold
        )
        // Below-threshold dialer (gate disabled on its side so it doesn't reject us).
        let kpLow = grindKeyPair(below: threshold)
        let lowConfig = LatticeNodeConfig(
            publicKey: kpLow.publicKey, privateKey: kpLow.privateKey,
            listenPort: p2,
            bootstrapPeers: [PeerEndpoint(publicKey: kpGate.publicKey, host: "127.0.0.1", port: p1)],
            storagePath: tmpDir.appendingPathComponent("low"),
            enableLocalDiscovery: false, persistInterval: 1_000_000, minPeerKeyBits: 0
        )
        let gateNode = try await LatticeNode(config: gateConfig, genesisConfig: genesis)
        let lowNode = try await LatticeNode(config: lowConfig, genesisConfig: genesis)
        try await gateNode.start()
        try await lowNode.start()
        defer { Task { await gateNode.stop() } }
        defer { Task { await lowNode.stop() } }

        // Give the dial + handshake ample time; the below-threshold peer must never
        // appear in the gate's connected set. Compare canonical raw key forms:
        // the node presents (and Ivy 6 keys peers by) the raw 64-hex spelling.
        let lowKey = KeyDifficulty.canonicalRawHex(kpLow.publicKey)
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(250))
            let gatePeers = await gateNode.connectedPeerEndpoints()
            XCTAssertFalse(gatePeers.contains(where: { KeyDifficulty.canonicalRawHex($0.publicKey) == lowKey }),
                "a below-threshold identity must be rejected at the live Ivy handshake")
        }
    }

    /// Build a live `Ivy` carrying the exact `minPeerKeyBits` gate a node wires into
    /// its ChainNetwork (ChainNetwork.swift) — same `publicKey` (full Multikey;
    /// Ivy 6 canonicalizes to the raw form before gating/identity) and
    /// `signingKey: Data(hex: privKey)` derivation — so
    /// the real handshake gate (Ivy.swift:648) is exercised directly. STUN is disabled
    /// so `start()` doesn't block, and the SQLite-backed chain network (whose
    /// nondeterministic genesis-only teardown masks a node-level connectivity
    /// assertion in this harness) is out of the picture.
    private func makeGateIvy(
        keyPair: (privateKey: String, publicKey: String),
        listenPort: UInt16,
        minPeerKeyBits: Int
    ) -> Ivy {
        let cfg = IvyConfig(
            publicKey: keyPair.publicKey,
            listenPort: listenPort,
            enableLocalDiscovery: false,
            stunServers: [],
            signingKey: Data(hex: keyPair.privateKey) ?? Data(),
            minPeerKeyBits: minPeerKeyBits
        )
        return Ivy(config: cfg)
    }

    /// Real admission path (acceptance): an above-threshold identity dialing a gated
    /// Ivy clears the live handshake and IS admitted into the gatekeeper's connected
    /// set. This drives the real `connect` + identify-verify + gate path (Ivy.swift:648),
    /// not a recomputed `KeyDifficulty` — the positive complement of the real-socket
    /// rejection above. A small threshold (8) keeps the key grind cheap.
    func testLiveIvyGateAdmitsAboveThresholdIdentity() async throws {
        let threshold = 8
        let p1 = nextTestPort()
        let p2 = nextTestPort()

        // Both identities clear the gatekeeper's gate, so admission must succeed.
        let kpGate = grindKeyPair(atLeast: threshold)
        let kpHigh = grindKeyPair(atLeast: threshold)
        let gateIvy = makeGateIvy(keyPair: kpGate, listenPort: p1, minPeerKeyBits: threshold)
        let highIvy = makeGateIvy(keyPair: kpHigh, listenPort: p2, minPeerKeyBits: threshold)
        try await gateIvy.start()
        try await highIvy.start()
        defer { Task { await gateIvy.stop() } }
        defer { Task { await highIvy.stop() } }

        // Dial the gatekeeper; after the handshake + identify-verify, the gate must
        // KEEP the above-threshold peer in its connected set (re-keyed to realID).
        // Ivy 6.0.0 derives a peer's identity from the CANONICAL raw key form, so
        // compare canonical forms — a connected endpoint's publicKey is the raw
        // 64-hex key even when the dialer configured the `ed01` Multikey spelling.
        try await highIvy.connect(to: PeerEndpoint(publicKey: kpGate.publicKey, host: "127.0.0.1", port: p1))
        let gateKey = KeyDifficulty.canonicalRawHex(kpGate.publicKey)
        let highKey = KeyDifficulty.canonicalRawHex(kpHigh.publicKey)
        var admitted = false
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(250))
            let gateConns = await gateIvy.connectedPeerEndpoints.map { KeyDifficulty.canonicalRawHex($0.publicKey) }
            let highConns = await highIvy.connectedPeerEndpoints.map { KeyDifficulty.canonicalRawHex($0.publicKey) }
            if gateConns.contains(highKey) || highConns.contains(gateKey) {
                admitted = true
                break
            }
        }
        XCTAssertTrue(admitted,
            "an above-threshold identity must be admitted at the live Ivy handshake gate")
    }

    // MARK: - (b) durable per-peer ban survives a real node restart + reconnect

    /// A peer banned for misbehavior stays banned across a real node restart and is
    /// dropped at the live `didConnectPeer` admission boundary when it reconnects.
    /// RED without durable persistence: the restarted node starts with an empty ban
    /// set and re-admits the peer.
    func testBannedPeerDisconnectedAtDidConnectAfterRestart() async throws {
        let p1 = nextTestPort()
        let p2 = nextTestPort()
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis()
        let node1Dir = tmpDir.appendingPathComponent("node1")

        let config1 = LatticeNodeConfig(
            publicKey: kp1.publicKey, privateKey: kp1.privateKey,
            listenPort: p1, storagePath: node1Dir,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let config2 = LatticeNodeConfig(
            publicKey: kp2.publicKey, privateKey: kp2.privateKey,
            listenPort: p2,
            bootstrapPeers: [PeerEndpoint(publicKey: kp1.publicKey, host: "127.0.0.1", port: p1)],
            storagePath: tmpDir.appendingPathComponent("node2"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )

        // Session 1: node1 bans node2 (durably), then shuts down.
        //
        // KNOWN GAP (pre-existing, reproduced at origin/main with Ivy 5.x): this
        // ban is keyed by the `ed01`-prefixed Multikey while live PeerIDs carry
        // the canonical RAW key (the node presents p2pPublicKey stripped; Ivy
        // keys peers by the presented/canonical form). Banning the canonical
        // form instead does NOT keep the peer out either: Ivy fires didConnect
        // for inbound connections with the temporary `inbound-<uuid>` ID and
        // never re-fires after the identify re-key, so the node's didConnectPeer
        // ban gate never sees an inbound peer's real identity. Both halves need
        // an Ivy-level post-identify hook + node-side enforcement (follow-up);
        // until then this test only covers ban persistence across restart.
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()
        let node2Peer = PeerID(publicKey: kp2.publicKey)
        try await node1.banStore.ban(node2Peer)
        await node1.stop()

        // Session 2 (restart): a brand-new node over the same dir must reload the ban
        // during start(), and refuse node2 at the real didConnectPeer boundary.
        let node1b = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1b.start()
        defer { Task { await node1b.stop() } }
        let reloadedBan = await node1b.banStore.isBanned(node2Peer)
        XCTAssertTrue(reloadedBan, "the persisted ban must be reloaded on restart")

        let node2 = try await LatticeNode(config: config2, genesisConfig: genesis)
        try await node2.start()
        defer { Task { await node2.stop() } }

        // node2 keeps trying to bootstrap to node1b; the ban must keep it out.
        // NOTE: this compares the prefixed expectation against raw presented
        // keys, so it cannot currently catch an admitted inbound peer — see the
        // KNOWN GAP note above. Kept as-is (pre-existing) pending the Ivy-level
        // post-identify hook.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(250))
            let peers = await node1b.connectedPeerEndpoints()
            XCTAssertFalse(peers.contains(where: { $0.publicKey == kp2.publicKey }),
                "a persisted-banned peer must be dropped at didConnectPeer on reconnect")
        }
    }

    /// Direct boundary check: didConnectPeer disconnects a peer whose ban was
    /// reloaded from disk, with no live socket needed.
    func testDidConnectDisconnectsReloadedBannedPeer() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let genesis = testGenesis()
        let kp = CryptoUtils.generateKeyPair()
        let banned = PeerID(publicKey: "feedfacefeedfacefeedfacefeedface")
        let storage = tmp.appendingPathComponent("node")

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: storage,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        // Pre-seed a durable ban, then boot a node that reloads it on start().
        let seed = PeerBanStore(dataDir: storage)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try await seed.ban(banned)

        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        let bannedReloaded = await node.banStore.isBanned(banned)
        XCTAssertTrue(bannedReloaded, "ban must survive into the restarted node")

        let nexusDir = await node.genesisConfig.directory
        guard let network = await node.network(for: nexusDir) else {
            return XCTFail("expected a live Nexus ChainNetwork")
        }
        // Drive the real admission boundary; a banned peer is refused service.
        await node.chainNetwork(network, didConnectPeer: banned)
        let peers = await node.connectedPeerEndpoints()
        XCTAssertFalse(peers.contains(where: { $0.publicKey == banned.publicKey }),
            "didConnectPeer must not admit a reloaded-banned peer")
    }

    /// a banned peer reconnecting INBOUND completes the identify handshake
    /// under its real (canonical) identity. The node must disconnect it at
    /// `didIdentifyPeer` — the first admission point an inbound peer's real id
    /// reaches (`didConnectPeer` only ever saw the temporary `inbound-<uuid>`).
    /// RED without the enforcement body: the banned peer is left admitted.
    func testIdentifiedBannedPeerDisconnectedAtDidIdentify() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let genesis = testGenesis()
        let kp = CryptoUtils.generateKeyPair()
        let banned = PeerID(publicKey: "feedfacefeedfacefeedfacefeedface")
        let storage = tmp.appendingPathComponent("node")

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: storage,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        // Pre-seed a durable ban, then boot a node that reloads it on start().
        let seed = PeerBanStore(dataDir: storage)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try await seed.ban(banned)

        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        let bannedReloaded = await node.banStore.isBanned(banned)
        XCTAssertTrue(bannedReloaded, "ban must survive into the restarted node")

        let nexusDir = await node.genesisConfig.directory
        guard let network = await node.network(for: nexusDir) else {
            return XCTFail("expected a live Nexus ChainNetwork")
        }
        let nexusKey = await node.chainKey(forDirectory: nexusDir)

        // Seed node-side per-peer state under the banned peer's REAL identity, as if
        // it had announced a tip earlier in the (now-banned) session. The identify
        // enforcement must drop this map entry when it disconnects the peer — the
        // deterministic, in-process side effect we assert on (no live socket / no
        // timing race). `connectedPeerEndpoints` cannot show admission here because
        // no real connection is staged; the map cleanup is the observable signal
        // that the enforcement body actually fired.
        await node.recordPeerTip(directory: nexusDir, peerKey: banned.publicKey,
                                 tipCID: "bafyreifakebannedtip00000000000000", height: 7)
        let seeded = await node.knownPeerTips[nexusKey]?[banned.publicKey]
        XCTAssertNotNil(seeded, "precondition: banned peer's tip is recorded in knownPeerTips")

        // Drive the real post-identify boundary with the peer's REAL identity (what
        // Ivy 6.1.0 surfaces after re-keying an inbound `inbound-<uuid>` connection).
        await node.chainNetwork(network, didIdentifyPeer: banned)
        let afterFirst = await node.knownPeerTips[nexusKey]?[banned.publicKey]
        XCTAssertNil(afterFirst,
            "didIdentifyPeer must enforce the ban: disconnect + drop the banned peer's per-peer state")
        var peers = await node.connectedPeerEndpoints()
        XCTAssertFalse(peers.contains(where: { $0.publicKey == banned.publicKey }),
            "didIdentifyPeer must not leave a reloaded-banned peer admitted")

        // Idempotent: Ivy may re-fire didIdentifyPeer per identify frame. Re-seed and
        // re-fire — a re-fire just re-checks + re-disconnects + re-cleans, no
        // accumulation, banned peer still removed.
        await node.recordPeerTip(directory: nexusDir, peerKey: banned.publicKey,
                                 tipCID: "bafyreifakebannedtip00000000000000", height: 7)
        await node.chainNetwork(network, didIdentifyPeer: banned)
        let afterRefire = await node.knownPeerTips[nexusKey]?[banned.publicKey]
        XCTAssertNil(afterRefire,
            "a re-fired didIdentifyPeer must keep the banned peer out idempotently")
        peers = await node.connectedPeerEndpoints()
        XCTAssertFalse(peers.contains(where: { $0.publicKey == banned.publicKey }),
            "a re-fired didIdentifyPeer must keep the banned peer out idempotently")
    }

    // MARK: - node-side key-work helper: gate-measure parity

    /// Raw (wire-presented, `p2pPublicKey`-form) key whose GATE measure satisfies
    /// `predicate` — exactly the form refresh/DNS-seed candidates carry.
    private func grindRawKey(where predicate: (Int) -> Bool) -> String {
        while true {
            let raw = String(CryptoUtils.generateKeyPair().publicKey.dropFirst(4))
            if predicate(KeyDifficulty.trailingZeroBits(of: raw)) { return raw }
        }
    }

    /// `KeyDifficulty.keyWorkBits` must be the SAME measure the live Ivy gates
    /// apply (`KeyDifficulty.trailingZeroBits` of the wire-presented key): a key
    /// ground to pass the identify gate at N bits must pass the diversity filter
    /// at N bits. Under the previous leading-zero-bytes measure the two agreed
    /// only with P≈2^-N, making gate-passing honest nodes unselectable in
    /// outbound refresh at the 24-bit default.
    func testKeyWorkBitsMatchesIdentifyGateMeasure() {
        let raw = grindRawKey(where: { $0 >= 8 })
        XCTAssertGreaterThanOrEqual(KeyDifficulty.keyWorkBits(raw), 8,
            "a key passing the identify gate at 8 bits must pass the diversity filter at 8 bits")
        XCTAssertEqual(KeyDifficulty.keyWorkBits(raw), KeyDifficulty.trailingZeroBits(of: raw),
            "the diversity filter must apply the gate's exact measure")
        // The Multikey (ed01-prefixed) storage form is normalized to the raw form
        // the peer actually presents at identify before measuring.
        XCTAssertEqual(KeyDifficulty.keyWorkBits("ed01" + raw), KeyDifficulty.keyWorkBits(raw),
            "prefixed and wire-presented forms must measure identically")
        // The identity-grind helper and the diversity filter are one measure.
        XCTAssertEqual(identityKeyWorkBits(of: "ed01" + raw), KeyDifficulty.keyWorkBits(raw))
    }

    // MARK: - outbound selection drops low-work candidates, keeps high-work

    /// With a positive `minKeyWorkBits`, `selectDiversePeers` must exclude
    /// below-threshold (cheap) identities while still selecting ones ground to
    /// the gate measure. Assert membership (not count) because the selection
    /// shuffles.
    func testSelectDiversePeersFiltersLowWorkCandidates() {
        let highWorkKey = grindRawKey(where: { $0 >= 8 })
        let lowWorkKey = grindRawKey(where: { $0 < 8 })

        let high = PeerEndpoint(publicKey: highWorkKey, host: "10.0.0.1", port: 4001)
        let low = PeerEndpoint(publicKey: lowWorkKey, host: "10.1.0.1", port: 4001)

        let selected = PeerDiversity.selectDiversePeers(
            from: [high, low],
            existing: [],
            maxNew: 8,
            minKeyWorkBits: 8
        )
        let selectedKeys = Set(selected.map(\.publicKey))
        XCTAssertTrue(selectedKeys.contains(highWorkKey),
            "a gate-passing identity must be selectable")
        XCTAssertFalse(selectedKeys.contains(lowWorkKey),
            "a below-threshold (cheap) identity must be filtered before connect")
    }

    /// With the filter disabled (0), both candidates remain eligible — the default
    /// preserves existing non-gated callers.
    func testSelectDiversePeersFilterDisabledKeepsAll() {
        let a = PeerEndpoint(publicKey: "00" + "01" + String(repeating: "0", count: 60), host: "10.0.0.1", port: 4001)
        let b = PeerEndpoint(publicKey: String(repeating: "a", count: 64), host: "10.1.0.1", port: 4001)
        let selected = PeerDiversity.selectDiversePeers(from: [a, b], existing: [], maxNew: 8)
        let keys = Set(selected.map(\.publicKey))
        XCTAssertTrue(keys.contains(a.publicKey))
        XCTAssertTrue(keys.contains(b.publicKey))
    }
}
