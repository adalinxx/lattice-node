import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew

/// B1-class startup pin leak: `rebuildAccountPins` used to pin txCIDs AND
/// block hashes under the bare `account:<ns>` owner — never released,
/// re-pinned every restart. These tests lock in the fixed contract: the
/// rebuild mirrors the live path (`pinAccountData`) — height-scoped
/// `account:<ns>:txwindow:<h>` owners, bounded to `ownTxPinWindow`, and no
/// block-header pins.
final class AccountPinRebuildTests: XCTestCase {

    func testRebuildUsesWindowedOwnersAndPinsNoHeaders() async throws {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: port, storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let me = await node.nodeAddress
        let store = await node.stateStore(for: "Nexus")!
        let network = await node.network(for: "Nexus")!
        let window = await node.ownTxPinWindow

        // One row far outside the retention window, two within it. The newest
        // row anchors the window (chain tip is still ~0 in this test).
        let newest: UInt64 = window + 1_000
        let inWindow: UInt64 = newest - window + 1
        let outOfWindow: UInt64 = inWindow - 10
        try await store.indexTransaction(address: me, txCID: "txOld", blockHash: "hashOld", height: outOfWindow)
        try await store.indexTransaction(address: me, txCID: "txMid", blockHash: "hashMid", height: inWindow)
        try await store.indexTransaction(address: me, txCID: "txNew", blockHash: "hashNew", height: newest)

        await node.rebuildAccountPins(directory: "Nexus")

        let disk = await network.diskBroker
        let ns = network.ownerNamespace

        // 1. No bare-owner pins: every account:* owner is height-scoped.
        let accountOwners = await disk.pinnedOwners(prefix: "account:")
        XCTAssertFalse(accountOwners.contains("account:\(ns)"),
            "rebuild must not pin under the bare account:<ns> owner (B1 leak)")
        for owner in accountOwners {
            XCTAssertTrue(owner.hasPrefix("account:\(ns):txwindow:"),
                "unexpected non-windowed account owner: \(owner)")
        }

        // 2. In-window txCIDs are pinned under their per-height owner.
        let midOwners = await disk.owners(root: "txMid")
        XCTAssertTrue(midOwners.contains(LatticeNode.ownTxPinOwner(ownerNamespace: ns, height: inWindow)),
            "in-window tx must be pinned under its txwindow owner, got \(midOwners)")
        let newOwners = await disk.owners(root: "txNew")
        XCTAssertTrue(newOwners.contains(LatticeNode.ownTxPinOwner(ownerNamespace: ns, height: newest)))

        // 3. Out-of-window txCIDs are NOT re-pinned (M6 bound).
        let oldOwners = await disk.owners(root: "txOld")
        XCTAssertTrue(oldOwners.filter { $0.hasPrefix("account:") }.isEmpty,
            "tx older than ownTxPinWindow must not be re-pinned, got \(oldOwners)")

        // 4. Block headers are never pinned by the rebuild.
        for header in ["hashOld", "hashMid", "hashNew"] {
            let owners = await disk.owners(root: header)
            XCTAssertTrue(owners.filter { $0.hasPrefix("account:") }.isEmpty,
                "block header \(header) must not carry account pins, got \(owners)")
        }
    }

    /// Re-running the rebuild (i.e. every restart) must stay idempotent on the
    /// owner set — no growth, no new owner shapes.
    func testRebuildIsIdempotentAcrossRestarts() async throws {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: port, storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let me = await node.nodeAddress
        let store = await node.stateStore(for: "Nexus")!
        let network = await node.network(for: "Nexus")!
        try await store.indexTransaction(address: me, txCID: "txA", blockHash: "hashA", height: 7)

        await node.rebuildAccountPins(directory: "Nexus")
        let ownersAfterFirst = Set(await network.diskBroker.pinnedOwners(prefix: "account:"))
        await node.rebuildAccountPins(directory: "Nexus")
        let ownersAfterSecond = Set(await network.diskBroker.pinnedOwners(prefix: "account:"))

        XCTAssertEqual(ownersAfterFirst, ownersAfterSecond,
            "repeated rebuilds must not grow or reshape the pin owner set")
        XCTAssertTrue(ownersAfterFirst.contains("account:\(network.ownerNamespace):txwindow:7"))
        for owner in ownersAfterFirst {
            XCTAssertTrue(owner.hasPrefix("account:\(network.ownerNamespace):txwindow:"),
                "unexpected non-windowed account owner: \(owner)")
        }
    }

    /// F2: the rebuild is also the reclaim sweep — legacy bare-owner pins from
    /// pre-fix code and txwindow owners stranded below the window floor (the
    /// live release only fires when an own-tx block lands at exactly h+W) are
    /// released at startup; in-window owners survive.
    func testRebuildSweepsStaleWindowAndLegacyBareOwners() async throws {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: port, storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let me = await node.nodeAddress
        let store = await node.stateStore(for: "Nexus")!
        let network = await node.network(for: "Nexus")!
        let window = await node.ownTxPinWindow
        let ns = network.ownerNamespace
        let disk = await network.diskBroker

        // The newest history row anchors the window.
        let newest: UInt64 = window + 1_000
        try await store.indexTransaction(address: me, txCID: "txNew", blockHash: "hashNew", height: newest)

        // Seed pre-existing pin state: a legacy bare-owner pin (pre-fix code),
        // a txwindow owner stranded far below the floor, and an in-window
        // owner that must survive.
        try await network.pinBatchDurably(roots: ["legacyPinned"], owner: "account:\(ns)")
        let staleOwner = LatticeNode.ownTxPinOwner(ownerNamespace: ns, height: 1)
        try await network.pinBatchDurably(roots: ["stalePinned"], owner: staleOwner)
        let inWindowOwner = LatticeNode.ownTxPinOwner(ownerNamespace: ns, height: newest - 1)
        try await network.pinBatchDurably(roots: ["midPinned"], owner: inWindowOwner)

        await node.rebuildAccountPins(directory: "Nexus")

        let owners = Set(await disk.pinnedOwners(prefix: "account:"))
        XCTAssertFalse(owners.contains("account:\(ns)"),
            "legacy bare account owner must be swept at startup")
        XCTAssertFalse(owners.contains(staleOwner),
            "txwindow owner below the window floor must be swept")
        XCTAssertTrue(owners.contains(inWindowOwner),
            "in-window txwindow owner must survive the sweep")
        XCTAssertTrue(owners.contains(LatticeNode.ownTxPinOwner(ownerNamespace: ns, height: newest)),
            "the rebuild's own in-window pin must be present")
    }

    /// F1 (object-grain cutover, #248): transactions are in-package entries of
    /// the BLOCK volume, so a pinned txCID's reachability closure protects only
    /// the tx header blob. The rebuild must pin the body CID alongside the
    /// txCID (mirroring `pinAccountData`) — otherwise an eviction sweep after
    /// restart strands an unresolvable header. DATA SURVIVABILITY: after
    /// rebuild + eviction, the tx BODY bytes must still be resolvable.
    func testRebuildPinsTxBodySoDataSurvivesEviction() async throws {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: port, storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let me = await node.nodeAddress
        let store = await node.stateStore(for: "Nexus")!
        let network = await node.network(for: "Nexus")!

        // Build a REAL one-tx block and store it through the object-grain
        // block path, but never commit/pin it — the shape of a pruned block
        // whose own-tx data only the account pins protect.
        let genesis = await node.genesisResult.block
        let body = TransactionBody(
            accountActions: [AccountAction(owner: me, delta: 5)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [me], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let tx = sign(body, kp)
        let txCID = try VolumeImpl<Transaction>(node: tx).rawCID
        let bodyCID = tx.body.rawCID
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: genesis.timestamp + 1_000, target: genesis.nextTarget,
            nonce: 1, fetcher: network.ivyFetcher
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        let storedRoots = await node.storeBlockData(block, network: network)
        XCTAssertNotNil(storedRoots, "block storage must succeed")

        try await store.indexTransaction(address: me, txCID: txCID, blockHash: blockHash, height: 1)
        await node.rebuildAccountPins(directory: "Nexus")

        // Eviction sweep: everything unpinned goes (grace 0, as the daemon
        // loop would after the I4 grace expires).
        _ = try await network.diskBroker.evictUnpinned(graceSeconds: 0)

        // The tx header AND its body bytes must survive — not just the owner shape.
        let fetcher = network.canonicalContentFetcher()
        let resolved = try await VolumeImpl<Transaction>(rawCID: txCID, node: nil, encryptionInfo: nil)
            .resolve(fetcher: fetcher)
        XCTAssertNotNil(resolved.node, "tx header must survive eviction")
        let bodyData = try await fetcher.fetch(rawCid: bodyCID)
        XCTAssertFalse(bodyData.isEmpty,
            "tx BODY bytes must survive eviction — a pinned txCID alone protects only the header blob")
    }

}
