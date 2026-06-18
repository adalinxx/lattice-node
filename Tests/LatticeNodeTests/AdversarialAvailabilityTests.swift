import XCTest
import Foundation
@testable import Ivy
import CID
import Multihash
import Tally
import VolumeBroker
@testable import Lattice
@testable import LatticeNode

/// Adversarial tests for the node's data-availability invariants.
///
/// Each test ATTACKS one invariant of the serve/fetch plane:
///   1. Volumes are served by pins (pin-reachability gate in `volumeData`).
///   2. A volume's internal entries never cross the wire individually.
///   3. Tier-union serving — a poorer memory grouping cannot shadow disk.
///   4. A durable-tier hit must not self-poison the memory tier.
///   5. Wave-order fetch serves local closures without network activity and
///      reports genuinely-missing CIDs as ABSENT, not as an error or a hang.
///   6. JIT deficiency attribution bookkeeping fails closed for unknown roots.
///   7. Missing sub-volume bytes degrade to a prompt notFound, never a wedge.
///
/// All tests are unit-level: standalone `ChainNetwork` (never started — no TCP),
/// in-memory brokers, temp-sqlite `DiskBroker`s, and an `Ivy` that is constructed
/// but never started (connectedPeers == []). Deterministic and CI-safe.
final class AdversarialAvailabilityTests: XCTestCase {

    // MARK: - Fixtures

    /// An Ivy actor that is never started/connected: `connectedPeers` is empty,
    /// so every network fan-out path is a guaranteed no-op.
    private func noPeerIvy() -> Ivy {
        let kp = CryptoUtils.generateKeyPair()
        return Ivy(config: IvyConfig(
            publicKey: kp.publicKey,
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            stunServers: []
        ))
    }

    /// Temp-sqlite DiskBroker, removed on teardown.
    private func tempDiskBroker() throws -> DiskBroker {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)
    }

    /// Standalone ChainNetwork in local mode. Never started — no TCP.
    private func makeNetwork() async throws -> ChainNetwork {
        let disk = try tempDiskBroker()
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    /// IvyFetcher with no peers and SHORT deadlines so network-miss paths
    /// resolve in a few hundred milliseconds instead of the production deadline.
    private func shortDeadlineFetcher(broker: any VolumeBroker) -> IvyFetcher {
        IvyFetcher(
            ivy: noPeerIvy(),
            broker: broker,
            fetchDeadline: .milliseconds(200),
            fetchPollInterval: .milliseconds(20)
        )
    }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func cid(for data: Data) -> String {
        let multihash = try! Multihash(raw: data, hashedWith: .sha2_256)
        return try! CID(version: .v1, codec: .dag_json, multihash: multihash).toBaseEncodedString
    }

    // MARK: - Invariant 1: volumes are served by PINS

    /// ATTACK: ask a node to serve a multi-entry grouping it merely CACHED
    /// (tracker/relay residue, never pinned) — the serve gate must refuse;
    /// pinning the root is exactly what flips it to served.
    func testCachedGroupingWithoutPinIsNotServedUntilPinned() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let root = "adv1-root"
        let entries = [root: bytes("root-node"), "adv1-a": bytes("entry-a"), "adv1-b": bytes("entry-b")]
        try await disk.storeVolumeLocal(SerializedVolume(root: root, entries: entries))

        // Unpinned cached grouping must NOT be servable.
        let unpinnedServe = await network.volumeData(for: root, cids: [])
        XCTAssertTrue(unpinnedServe.isEmpty,
            "A cached-but-unpinned grouping must not be served — got \(unpinnedServe.count) entries")

        // Pinning the root is the node's commitment to serve: now the FULL grouping serves.
        try await disk.pin(root: root, owner: "adv1-owner")
        let pinnedServe = await network.volumeData(for: root, cids: [])
        XCTAssertEqual(Set(pinnedServe.map(\.cid)), Set(entries.keys),
            "A pinned root must serve its full grouping")
        for (cid, data) in pinnedServe {
            XCTAssertEqual(data, entries[cid], "Served bytes for \(cid) must match stored bytes")
        }
    }

    /// ATTACK: request a SUB-volume root that has no pin of its own but is a
    /// member of a pinned root's entry set — pin-REACHABILITY (closure pin
    /// coverage) must serve it; requiring a per-root pin would break
    /// object-grain block serving.
    func testSubVolumeRootInsidePinnedClosureServesWithoutOwnPin() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        // Block-shaped closure: pinned root P contains sub-volume root S as an
        // in-package member; S also has its OWN grouping (its sub-closure).
        let blockRoot = "adv2-block"
        let subRoot = "adv2-sub"
        try await disk.storeVolumeLocal(SerializedVolume(
            root: blockRoot,
            entries: [blockRoot: bytes("block-node"), subRoot: bytes("sub-node")]
        ))
        try await disk.storeVolumeLocal(SerializedVolume(
            root: subRoot,
            entries: [subRoot: bytes("sub-node"), "adv2-sub-leaf": bytes("sub-leaf")]
        ))
        try await disk.pin(root: blockRoot, owner: "adv2-owner")

        let owners = await disk.owners(root: subRoot)
        XCTAssertTrue(owners.isEmpty, "Precondition: the sub-volume root must not be pinned itself")

        let served = await network.volumeData(for: subRoot, cids: [])
        XCTAssertEqual(Set(served.map(\.cid)), [subRoot, "adv2-sub-leaf"],
            "A sub-volume root covered by a pinned closure must serve its grouping")
    }

    /// WHOLE-OBJECT-BY-ROOT: a CID that exists ONLY as a member of a larger volume
    /// and has NO grouping of its own is NOT a servable Volume root — even when it
    /// is DIRECTLY pinned. Direct-pin is a retention marker, not a serve grant; a
    /// thing is servable iff it has its own `volume_entries(self, *)` grouping (it
    /// is a real object root). Such a directly-pinned-but-grouping-less CID is the
    /// non-root case to refuse: a real boundary root (a block, spec, sub-volume,
    /// state node) always HAS its own grouping, so this synthetic premise (pinned
    /// bytes-only, no grouping) does not occur for genuine roots and must be
    /// refused if it ever does.
    func testDirectlyPinnedBoundaryRootWithoutGroupingIsRefused() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let parent = "adv2b-parent"
        let boundaryRoot = "adv2b-boundary"
        // The boundary root lives only as a member of `parent` (no own grouping)…
        try await disk.storeVolumeLocal(SerializedVolume(
            root: parent,
            entries: [parent: bytes("parent-node"), boundaryRoot: bytes("boundary-node")]
        ))
        // …and storage ALSO pinned it directly (it was in storedRoots).
        try await disk.pin(root: parent, owner: "adv2b-owner")
        try await disk.pin(root: boundaryRoot, owner: "adv2b-owner")
        let ownGrouping = await disk.fetchVolumeLocal(root: boundaryRoot)
        XCTAssertNil(ownGrouping, "Precondition: the boundary root has no grouping of its own")
        let boundaryOwners = await disk.owners(root: boundaryRoot)
        XCTAssertFalse(boundaryOwners.isEmpty, "Precondition: the boundary root IS directly pinned")

        let served = await network.volumeData(for: boundaryRoot, cids: [])
        XCTAssertTrue(served.isEmpty,
            "A grouping-less CID is not a servable root — refuse it even when directly pinned (got \(served.count) entries)")
    }

    /// ATTACK: pin a root with an already-expired TTL — a dead pin must not
    /// satisfy the serve gate (otherwise expired retention would keep serving).
    func testExpiredTTLPinDoesNotServe() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let root = "adv3-root"
        try await disk.storeVolumeLocal(SerializedVolume(
            root: root,
            entries: [root: bytes("root-node"), "adv3-a": bytes("entry-a")]
        ))
        try await disk.pin(root: root, owner: "adv3-owner", ttl: .seconds(-60))

        let served = await network.volumeData(for: root, cids: [])
        XCTAssertTrue(served.isEmpty,
            "An expired-TTL pin must not serve — got \(served.count) entries")
        let reachable = await disk.isPinReachable(cid: root)
        XCTAssertFalse(reachable, "An expired pin must not count as pin-reachable")
    }

    // MARK: - Invariant 2: internal entries never cross the wire individually

    /// WHOLE-OBJECT-BY-ROOT: a pin-reachable in-package CID (member of a pinned
    /// closure, present in CAS, NO own `volume_entries` grouping) must be REFUSED
    /// by volumeData — it is not a servable Volume root. It is delivered only
    /// INSIDE its owning object's bundle (fetched by that object's root), never as
    /// a standalone by-CID response. Serving its bare bytes here was non-root
    /// serving (the removed `fetchDataLocal` branch). A requester that misses such
    /// a node re-fetches the OWNING block whole by root, so refusing here does not
    /// strand sync — it routes recovery back to whole-object-by-root.
    func testPinReachableInPackageCIDIsRefused() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let root = "adv4-root"
        let internalCID = "adv4-internal"
        try await disk.storeVolumeLocal(SerializedVolume(
            root: root,
            entries: [root: bytes("root-node"), internalCID: bytes("internal-node")]
        ))
        try await disk.pin(root: root, owner: "adv4-owner")

        let reachable = await disk.isPinReachable(cid: internalCID)
        XCTAssertTrue(reachable, "Precondition: in-package CID is pin-reachable via its closure")
        let ownGrouping = await disk.fetchVolumeLocal(root: internalCID)
        XCTAssertNil(ownGrouping, "Precondition: the internal CID has NO grouping of its own (not a root)")

        let served = await network.volumeData(for: internalCID, cids: [])
        XCTAssertTrue(served.isEmpty,
            "A non-root in-package CID must be REFUSED (whole-object-by-root) — got \(served.count) entries")

        // The OWNING root, by contrast, still serves its whole grouping (incl. the
        // internal entry) — recovery is whole-object-by-root.
        let rootServe = await network.volumeData(for: root, cids: [])
        XCTAssertEqual(Set(rootServe.map(\.cid)), [root, internalCID],
            "The owning root must serve its full grouping, delivering the internal entry inside the bundle")
    }

    /// ATTACK: poison the MEMORY tier with a 1-entry grouping keyed by a CID that
    /// is NOT pin-reachable on disk (uncommitted cache residue), then request it.
    /// volumeData serves disk-only behind the pin-reachability gate, so the memory
    /// poison is never consulted and the unreachable CID is refused — a peer
    /// cannot make us serve content we never committed to.
    func testUnreachableMemoryPoisonIsNotServed() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let poisonCID = "adv5-poison"
        // Poison ONLY the memory tier; nothing on disk, nothing pinned.
        try await (await network.broker).storeVolumeLocal(SerializedVolume(
            root: poisonCID, entries: [poisonCID: bytes("uncommitted-junk")]
        ))
        let reachable = await disk.isPinReachable(cid: poisonCID)
        XCTAssertFalse(reachable, "Precondition: poison CID is NOT pin-reachable on disk")

        let perCIDServe = await network.data(for: poisonCID)
        XCTAssertNil(perCIDServe,
            "data(for:) must reject a memory singleton keyed by an uncommitted CID")

        let volumeServe = await network.volumeData(for: poisonCID, cids: [])
        XCTAssertTrue(volumeServe.isEmpty,
            "volumeData serves disk-only behind the pin gate — an unreachable memory poison is never served")
    }

    // MARK: - Invariant 3: tier-union serving

    /// ATTACK: make the memory tier hold a POORER grouping (bare root) than the
    /// disk tier (full closure) for the same root — serving must return the
    /// UNION, not let memory's bare-root stub shadow disk's complete closure.
    func testBareMemoryGroupingDoesNotShadowRicherDiskGrouping() async throws {
        let network = try await makeNetwork()
        let disk = await network.diskBroker
        let root = "adv6-root"
        let full = [root: bytes("root-node"), "adv6-a": bytes("entry-a"), "adv6-b": bytes("entry-b")]
        try await disk.storeVolumeLocal(SerializedVolume(root: root, entries: full))
        try await disk.pin(root: root, owner: "adv6-owner")
        // Memory tier holds only the bare root (e.g. a headers-first stub).
        try await (await network.broker).storeVolumeLocal(SerializedVolume(
            root: root, entries: [root: bytes("root-node")]
        ))

        let served = await network.volumeData(for: root, cids: [])
        XCTAssertEqual(Set(served.map(\.cid)), Set(full.keys),
            "Serving must be the tier UNION — memory's 1-entry grouping must not shadow disk's \(full.count)-entry closure")
    }

    // MARK: - Invariant 4: no self-poisoning re-cache

    /// ATTACK: resolve a CID whose bytes live only in the durable tier and check
    /// the memory tier afterwards — re-caching the durable hit as a 1-entry
    /// volume keyed by the CID would shadow the root's full grouping later
    /// (self-poisoning, no bad peer required).
    func testDurableTierHitDoesNotRecacheSingletonIntoMemory() async throws {
        let memory = MemoryBroker()
        let durable = try tempDiskBroker()
        let root = "adv7-root"
        let data = bytes("durable-bytes")
        try await durable.storeVolumeLocal(SerializedVolume(root: root, entries: [root: data]))
        memory.setNear(durable)
        let fetcher = shortDeadlineFetcher(broker: memory)

        let fetched = try await fetcher.fetch(rawCid: root)
        XCTAssertEqual(fetched, data, "The durable tier must serve the bytes")

        let memoryGrouping = await memory.fetchVolumeLocal(root: root)
        XCTAssertNil(memoryGrouping,
            "A durable hit must NOT create a volume grouping in the memory tier — a singleton under the root would shadow the full grouping (self-poisoning)")
        let has = await memory.hasVolume(root: root)
        XCTAssertFalse(has, "Memory tier must hold nothing under the durable-resolved root")
    }

    // MARK: - Invariant 5: wave-order fetch

    /// ATTACK: hand fetchWave a wave containing IN-PACKAGE CIDs with no peers
    /// connected — everything is in local CAS, so it must return all bytes
    /// without any network polling (fast), never trying to fetch internal
    /// entries individually over the wire.
    func testFetchWaveServesLocalClosureWithoutNetworkActivity() async throws {
        let memory = MemoryBroker()
        let root = "adv8-root"
        let closure = [root: bytes("root-node"), "adv8-a": bytes("entry-a"), "adv8-b": bytes("entry-b")]
        try await memory.storeVolumeLocal(SerializedVolume(root: root, entries: closure))
        let fetcher = shortDeadlineFetcher(broker: memory)

        let clock = ContinuousClock()
        let start = clock.now
        let out = await fetcher.fetchWave(Set(closure.keys))
        let elapsed = clock.now - start

        XCTAssertEqual(out, closure, "Every in-package CID must resolve from local CAS")
        // No peers, nothing missing: a wave served locally must not burn the
        // network-poll deadline.
        XCTAssertLessThan(elapsed, .seconds(1),
            "A fully-local wave must return without network polling — took \(elapsed)")
    }

    /// ATTACK: include a genuinely-missing CID in the wave with no peers — it
    /// must come back ABSENT from the returned map (the resolver's notFound
    /// signal), not throw and not hang past the short deadline.
    func testFetchWaveReturnsMissingCIDAbsentNotErrorAndPromptly() async throws {
        let memory = MemoryBroker()
        let present = "adv9-present"
        let missing = "adv9-missing"
        try await memory.storeVolumeLocal(SerializedVolume(root: present, entries: [present: bytes("present")]))
        let fetcher = shortDeadlineFetcher(broker: memory)

        let clock = ContinuousClock()
        let start = clock.now
        let out = await fetcher.fetchWave([present, missing])
        let elapsed = clock.now - start

        XCTAssertEqual(out[present], bytes("present"), "The locally-held CID must still resolve")
        XCTAssertNil(out[missing], "A genuinely-missing CID must be ABSENT in the wave result, not fabricated")
        XCTAssertLessThan(elapsed, .seconds(2),
            "A missing CID with no peers must run out the short deadline promptly — took \(elapsed)")
    }

    /// WHOLE-OBJECT-BY-ROOT regression: against a ROOT-ONLY serve gate (a holder
    /// that refuses any non-root in-package CID), block-content resolution still
    /// completes when the block is fetched WHOLE by its root — the internal trie
    /// nodes arrive inside the block bundle and resolve from local CAS — while a
    /// bare in-package internal CID is NEVER served standalone.
    ///
    /// Models the multi-node sync path locally: a "holder" network with a pinned
    /// block grouping (root + internal entries) is the serve plane; a "requester"
    /// broker starts empty. Fetching the block by ROOT delivers the whole grouping;
    /// every internal CID then resolves locally. Requesting an internal CID against
    /// the holder's serve gate returns [] — it is refused — yet whole-block
    /// resolution succeeds.
    func testWholeBlockByRootResolvesAgainstRootOnlyServeGate() async throws {
        // Holder: pinned block grouping = root node + two internal (non-root) trie
        // entries. No internal CID has its own grouping.
        let holder = try await makeNetwork()
        let holderDisk = await holder.diskBroker
        let blockRoot = "wob-block-root"
        let internalA = "wob-internal-a"
        let internalB = "wob-internal-b"
        let grouping = [
            blockRoot: bytes("block-node"),
            internalA: bytes("trie-node-a"),
            internalB: bytes("trie-node-b"),
        ]
        try await holderDisk.storeVolumeLocal(SerializedVolume(root: blockRoot, entries: grouping))
        try await holderDisk.pin(root: blockRoot, owner: "wob-owner")

        // Serve gate: the ROOT serves its whole grouping…
        let rootServe = await holder.volumeData(for: blockRoot, cids: [])
        XCTAssertEqual(Set(rootServe.map(\.cid)), Set(grouping.keys),
            "The block root must serve its whole grouping (incl. internal trie nodes)")
        // …while each internal in-package CID is REFUSED standalone (no own grouping).
        for internalCID in [internalA, internalB] {
            let internalServe = await holder.volumeData(for: internalCID, cids: [])
            XCTAssertTrue(internalServe.isEmpty,
                "Internal in-package CID \(internalCID) must NEVER be served standalone — got \(internalServe.count)")
        }

        // Requester: starts empty; "fetches" the whole block by ROOT — which is the
        // grouping the root-only serve gate hands back — then persists it. After
        // that, every internal CID resolves from local CAS (whole-object-by-root),
        // proving resolution never needs a standalone internal-CID fetch.
        let requesterBroker = MemoryBroker()
        let wholeBundle = await holder.volumeData(for: blockRoot, cids: [])
        try await requesterBroker.storeVolumeLocal(SerializedVolume(
            root: blockRoot, entries: Dictionary(uniqueKeysWithValues: wholeBundle.map { ($0.cid, $0.data) })
        ))

        let requesterFetcher = shortDeadlineFetcher(broker: requesterBroker)
        // No peers connected: any standalone internal-CID network fetch would run
        // out the deadline and miss. Resolving the whole wave from the locally-held
        // block bundle must return every internal CID from CAS without any miss.
        let resolved = await requesterFetcher.fetchWave(Set(grouping.keys))
        XCTAssertEqual(resolved, grouping,
            "Whole-block-by-root delivers every internal trie node locally — resolution completes with no standalone internal-CID fetch")
    }

    /// ATTACK: a fast peer has only a bare block root while a slower peer has the
    /// complete block closure. Since Ivy resolves a want with the first non-empty
    /// response, the fast stub can otherwise win every poll and permanently shadow
    /// the complete holder. For known multi-entry roots (`preferComplete: true`),
    /// the fetcher must suppress the bare-root responder for that root and persist
    /// only the complete bundle.
    func testPreferCompleteSuppressesBareRootFirstResponder() async throws {
        let ivy = noPeerIvy()
        let nodeID = await ivy.localID
        let fastPeer = PeerID(publicKey: "adv-complete-fast-stub")
        let slowPeer = PeerID(publicKey: "adv-complete-slow-full")
        let (fastLocal, fastRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: fastPeer)
        let (slowLocal, slowRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: slowPeer)
        await ivy.registerLocalPeer(fastLocal, as: fastPeer)
        await ivy.registerLocalPeer(slowLocal, as: slowPeer)

        let rootData = bytes("adv-complete-root")
        let childData = bytes("adv-complete-child")
        let rootCID = cid(for: rootData)
        let childCID = cid(for: childData)

        let fastTask = Task {
            for await msg in fastRemote.messages {
                if case .want(let cids) = msg, cids.contains(rootCID) {
                    fastRemote.send(.blocks(rootCID: rootCID, items: [(cid: rootCID, data: rootData)]))
                }
            }
        }
        let slowTask = Task {
            for await msg in slowRemote.messages {
                if case .want(let cids) = msg, cids.contains(rootCID) {
                    try? await Task.sleep(for: .milliseconds(25))
                    slowRemote.send(.blocks(rootCID: rootCID, items: [
                        (cid: rootCID, data: rootData),
                        (cid: childCID, data: childData),
                    ]))
                }
            }
        }
        defer {
            fastTask.cancel()
            slowTask.cancel()
            fastRemote.close()
            slowRemote.close()
        }

        let memory = MemoryBroker()
        let fetcher = IvyFetcher(
            ivy: ivy,
            broker: memory,
            fetchDeadline: .seconds(2),
            fetchPollInterval: .milliseconds(20)
        )

        await fetcher.fetchVolumeBundle(rootCID: rootCID, preferComplete: true)

        let cached = await memory.fetchVolumeLocal(root: rootCID)
        XCTAssertEqual(cached?.entries[rootCID], rootData)
        XCTAssertEqual(cached?.entries[childCID], childData)
        XCTAssertEqual(cached?.entries.count, 2,
            "Known multi-entry roots must persist the complete holder's bundle, never the fast bare-root stub")
    }

    // MARK: - Invariant 6: JIT deficiency attribution

    // TODO(missing seam): `rememberVolumeServer` is private and is only driven by
    // the network fetch paths (`ivy.fetchVolumeFromAllPeersAttributed` inside
    // `fetch`/`fetchVolumeBundle`) — there is no public way to inject an
    // attributed server without a live peer exchange, so the
    // "punish exactly the remembered server" half of this invariant is only
    // exercisable at the two-node TCP level. Unit level tests the fail-closed
    // half: unknown roots punish NOBODY.
    /// ATTACK: report roots the fetcher never network-fetched as deficient —
    /// the bookkeeping must fail closed (empty punished set, no crash), never
    /// inventing a peer to demote.
    func testReportDeficientVolumesOnUnknownRootsPunishesNoPeers() async throws {
        let fetcher = shortDeadlineFetcher(broker: MemoryBroker())
        let punished = await fetcher.reportDeficientVolumes(
            roots: ["adv10-never-fetched-1", "adv10-never-fetched-2", ""]
        )
        XCTAssertTrue(punished.isEmpty,
            "Roots with no remembered server must punish no peers — got \(punished)")
    }

    // MARK: - Invariant 7: eviction mid-resolve degrades, not wedges

    /// ATTACK: resolve a closure whose sub-volume bytes were evicted, with no
    /// peers and a short deadline — the per-CID fetch the resolution issues for
    /// the missing sub-node must throw notFound PROMPTLY (the JIT-failure path
    /// is reachable), never hang the resolve.
    func testMissingSubVolumeBytesThrowNotFoundPromptlyNotWedge() async throws {
        let memory = MemoryBroker()
        let root = "adv11-root"
        let evictedSub = "adv11-evicted-sub"
        // Block-shaped: the root node is local, the sub-volume bytes are NOT
        // (evicted mid-resolve).
        try await memory.storeVolumeLocal(SerializedVolume(root: root, entries: [root: bytes("root-node")]))
        let fetcher = shortDeadlineFetcher(broker: memory)

        // The root still resolves (degraded, not wedged)…
        let rootData = try await fetcher.fetch(rawCid: root)
        XCTAssertEqual(rootData, bytes("root-node"))

        // …and the evicted sub-volume fails FAST with the typed notFound.
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await fetcher.fetch(rawCid: evictedSub)
            XCTFail("Fetching evicted sub-volume bytes with no peers must throw notFound")
        } catch let error as FetcherError {
            guard case .notFound(let cid) = error else {
                XCTFail("Expected FetcherError.notFound, got \(error)")
                return
            }
            XCTAssertEqual(cid, evictedSub, "notFound must name the missing CID")
        } catch {
            XCTFail("Expected FetcherError.notFound, got \(error)")
        }
        let elapsed = clock.now - start
        XCTAssertLessThan(elapsed, .seconds(2),
            "The miss must run out the 200ms deadline promptly, not wedge — took \(elapsed)")
    }
}
