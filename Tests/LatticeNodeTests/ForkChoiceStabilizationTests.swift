import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import Ivy
import UInt256
import cashew
import VolumeBroker

/// Module 4: Fork-Choice Stabilization.
///
/// TESTS/FIXTURES ONLY. These fixtures PIN current Hierarchical-GHOST behavior as a
/// regression tripwire ahead of later refactors — they do NOT change production
/// code and do NOT introduce a `ForkChoiceEvidenceStore`. A child block's fork
/// choice weight is `effectiveWeight = subtreeWeight + inheritedWeight`, where the
/// inherited term is the parent's faithful-union securing work, held by the durable
/// `InheritedWeightStore` floor and projected through `LiveInheritedWeightIndex`.
///
/// The invariants captured:
///  1. restart → same selected head AND byte-identical inherited-work contributions;
///  2. retention pruning of bodies/old proofs does NOT change the selected head
///     (the durable inherited-weight floor survives the proof being deleted);
///  3. insertion order of equivalent inherited-weight evidence is irrelevant
///     (only-grows / union dedup makes the resolved weight order-independent).
///
/// Fixtures 1 & 2 boot a REAL per-process child node (Nexus ⊃ Mid) and commit a
/// merged-mining-secured child block via the production accept path
/// (`submitProvenChildBlock`), so the committed tip and the persisted
/// `inherited_work_contributions` are exactly what live ingestion writes. They are
/// skipped in CI (real nodes). Fixture 3 runs at the store/index level (cheap,
/// deterministic) per the module guidance and needs no real node.
final class ForkChoiceStabilizationTests: XCTestCase {

    override func setUp() async throws {
        // Fixtures 1 & 2 boot real nodes; fixture 3 does not but the class-level
        // guard is harmless for it (it spins up nothing). Mirrors the existing
        // real-node test suites' CI skip.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true",
                      "ForkChoiceStabilizationTests skipped in CI (real nodes)")
    }

    // MARK: - In-process child-node fixture (mirrors MinedChildBlockSideForkTests)

    private struct ChildFixture {
        let node: LatticeNode
        let fixtureCAS: TestBrokerFetcher
        let nexusGenesis: Block
        let midGenesis: Block
        let storagePath: URL
        let config: LatticeNodeConfig
    }

    /// Boot a per-process child node rooted at Nexus ⊃ Mid (the leaf chain this
    /// node serves) plus a Nexus fixture CAS for building proof carriers. The
    /// caller owns teardown so it can RESTART the node on the same storagePath.
    private func makeChildNode(
        retentionDepth: UInt64 = DEFAULT_RETENTION_DEPTH,
        blockRetention: BlockRetention = .retention,
        storagePath: URL? = nil,
        keyPair: (publicKey: String, privateKey: String)? = nil
    ) async throws -> ChildFixture {
        let kp = keyPair ?? CryptoUtils.generateKeyPair()
        let tmp = storagePath ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmp,
            enableLocalDiscovery: false,
            persistInterval: 10_000,
            retentionDepth: retentionDepth,
            blockRetention: blockRetention,
            fullChainPath: ["Nexus", "Mid"],
            minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis(spec: testSpec(), directory: "Mid"))
        try await node.start()

        let fixtureCAS = cas()
        let midGenesis = await node.genesisResult.block
        let ts = midGenesis.timestamp
        try await storeBlockTree(midGenesis, to: fixtureCAS)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: UInt256.max, fetcher: fixtureCAS
        )
        return ChildFixture(
            node: node, fixtureCAS: fixtureCAS,
            nexusGenesis: nexusGenesis, midGenesis: midGenesis,
            storagePath: tmp, config: config
        )
    }

    private func storeBlockTree(_ block: Block, to f: TestBrokerFetcher) async throws {
        let header = try VolumeImpl<Block>(node: block)
        await f.store(rawCid: header.rawCID, data: block.toData()!)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        for (cid, data) in storer.entryList {
            await f.store(rawCid: cid, data: data)
        }
    }

    /// Mine a Mid child block on `previousMid`, embed it in a Nexus carrier, generate
    /// the single-hop work proof, and mirror the carrier tree into the node's Mid
    /// network so the child resolves locally for processing. The carrier credits the
    /// child real, intrinsic securing work — exactly as live merged mining does.
    @discardableResult
    private func commitChild(
        on fixture: ChildFixture,
        previousMid: Block,
        nexusNonce: UInt64,
        ts: Int64
    ) async throws -> (midCID: String, block: Block, proof: ChildBlockProof) {
        // The carrier's prev-state is the Nexus genesis post-state (height-1 Nexus
        // block). The child's parentState must equal the committing parent's prevState
        // for `verifiedCommittingParentAnchor` to accept it, so build the child with
        // `parentChainBlock: parentAnchor` (sets parentState = parentAnchor.prevState =
        // nexusGenesis.postState) — the current API replacement for `withParentState`.
        let parentAnchor = try await BlockBuilder.buildBlock(
            previous: fixture.nexusGenesis, timestamp: ts, nonce: nexusNonce, fetcher: fixture.fixtureCAS
        )
        let child = try await BlockBuilder.buildBlock(
            previous: previousMid, parentChainBlock: parentAnchor,
            timestamp: ts, nonce: 0, fetcher: fixture.fixtureCAS
        )
        try await storeBlockTree(child, to: fixture.fixtureCAS)

        let nexusCarrier = try await BlockBuilder.buildBlock(
            previous: fixture.nexusGenesis, children: ["Mid": child],
            timestamp: ts, nonce: nexusNonce, fetcher: fixture.fixtureCAS
        )
        try await storeBlockTree(nexusCarrier, to: fixture.fixtureCAS)

        let proof = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: nexusCarrier),
            childDirectory: "Mid",
            fetcher: fixture.fixtureCAS
        )

        if let network = await fixture.node.network(for: "Mid") {
            try await storeBlockFixtureVolumes(child, in: network)
            try await storeBlockFixtureVolumes(fixture.nexusGenesis, in: network)
        }

        let midCID = try VolumeImpl<Block>(node: child).rawCID
        let result = await fixture.node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: child, proof: proof
        )
        XCTAssertEqual(result.status, .accepted, "merged-mining-secured child must be accepted")
        return (midCID, child, proof)
    }

    // MARK: - Fixture 1: restart preserves head with inherited work

    /// Core invariant: a restart re-derives the SAME selected head and replays
    /// byte-identical inherited-work contributions. We commit a chain of
    /// merged-mining-secured Mid blocks (each accruing real inherited work through
    /// the production accept path), snapshot the committed head + inherited-work
    /// rows, then drop the node WITHOUT `stop()` (a crash) and reboot on the same
    /// storagePath. The restored head and contributions must match exactly.
    func test_restartPreservesHead_withInheritedWork() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let storagePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        // --- First boot: commit two secured child blocks.
        let fx = try await makeChildNode(storagePath: storagePath, keyPair: kp)
        let ts = fx.midGenesis.timestamp
        let c1 = try await commitChild(on: fx, previousMid: fx.midGenesis, nexusNonce: 1, ts: ts + 1_000)
        let c2 = try await commitChild(on: fx, previousMid: c1.block, nexusNonce: 2, ts: ts + 2_000)

        let chainMaybe = await fx.node.chain(forPath: ["Nexus", "Mid"])
        let chain = try XCTUnwrap(chainMaybe)
        let storeMaybe = await fx.node.stateStore(forPath: ["Nexus", "Mid"])
        let store = try XCTUnwrap(storeMaybe)

        let headBefore = await chain.getMainChainTip()
        XCTAssertEqual(headBefore, c2.midCID, "the latest secured child is the selected head")
        let committedTipBefore = store.getChainTip()
        let heightBefore = store.getHeight()
        let contributionsBefore = store.getAllInheritedWorkContributions()
        XCTAssertFalse(contributionsBefore.isEmpty,
                       "secured child blocks must persist inherited-work contributions")
        let liveWeightBefore = await fx.node.ensureLiveInheritedWeightIndex(directory: "Mid")
            .inheritedWeight(forChild: c2.midCID)
        XCTAssertGreaterThan(liveWeightBefore, .zero, "the head must carry positive inherited work")

        // --- Crash: drop the node WITHOUT stop(), then reboot on the same storage.
        // start() runs recoverFromCAS (head) + restoreInheritedWeight (durable floor).

        let fx2 = try await makeChildNode(storagePath: storagePath, keyPair: kp)
        await fx2.node.restoreInheritedWeight(directory: "Mid")
        let chain2Maybe = await fx2.node.chain(forPath: ["Nexus", "Mid"])
        let chain2 = try XCTUnwrap(chain2Maybe)
        let store2Maybe = await fx2.node.stateStore(forPath: ["Nexus", "Mid"])
        let store2 = try XCTUnwrap(store2Maybe)

        let headAfter = await chain2.getMainChainTip()
        XCTAssertEqual(headAfter, headBefore, "restart must re-derive the same selected head")
        XCTAssertEqual(store2.getChainTip(), committedTipBefore,
                       "committed state.db tip must survive the restart unchanged")
        XCTAssertEqual(store2.getHeight(), heightBefore, "committed height must survive the restart")

        // Inherited-work contributions must be byte-identical after restart.
        let contributionsAfter = store2.getAllInheritedWorkContributions()
        assertContributionsEqual(contributionsAfter, contributionsBefore)

        // And the value reaches fork choice through the provider path (live index +
        // durable floor), not merely the persisted rows.
        let liveWeightAfter = await fx2.node.ensureLiveInheritedWeightIndex(directory: "Mid")
            .inheritedWeight(forChild: c2.midCID)
        XCTAssertEqual(liveWeightAfter, liveWeightBefore,
                       "restored inherited weight must reach fork choice identically across restart")

        await fx2.node.stop()
    }

    // MARK: - Fixture 2: prune-eligible data preserves the selected head

    /// Retention pruning of out-of-window data must NOT change the selected head.
    ///
    /// CURRENT BEHAVIOR pinned here: `pruneBlocks` → `deleteBlockProofs(height:)`
    /// drops BOTH the pruned height's `block_proofs` AND its
    /// `inherited_work_contributions` (StateStore.deleteBlockProofs deletes both
    /// tables). This is SAFE for fork choice — a pruned block is below the retention
    /// window and can no longer be a competing fork-choice tip — and it does not
    /// change the selected head. The head retains its OWN inherited weight (it is
    /// in-window), and the head is stable across a restart even though the pruned
    /// block's floor can no longer be replayed. The assertions below pin exactly
    /// that: head unchanged, head weight retained, head stable across restart.
    func test_pruneEligibleData_preservesSelectedHead() async throws {
        // retentionDepth = 2: committing height N prunes height (N - 2), so committing
        // a chain of children pushes the earliest secured (non-genesis) block out of
        // the window and runs the prune path (deleteStoredRoots + deleteBlockProofs).
        let kp = CryptoUtils.generateKeyPair()
        let storagePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: storagePath) }

        let fx = try await makeChildNode(
            retentionDepth: 2, blockRetention: .retention, storagePath: storagePath, keyPair: kp
        )
        let ts = fx.midGenesis.timestamp

        let chainMaybe = await fx.node.chain(forPath: ["Nexus", "Mid"])
        let chain = try XCTUnwrap(chainMaybe)
        let storeMaybe = await fx.node.stateStore(forPath: ["Nexus", "Mid"])
        let store = try XCTUnwrap(storeMaybe)

        // Commit children up to height 4. We track c2 (height 2) — committing height 4
        // prunes height 2, so c2 leaves the retention window and its body/proof are
        // pruned, while genesis-edge pruning of height 0 is avoided.
        let c1 = try await commitChild(on: fx, previousMid: fx.midGenesis, nexusNonce: 1, ts: ts + 1_000)
        let c2 = try await commitChild(on: fx, previousMid: c1.block, nexusNonce: 2, ts: ts + 2_000)

        let c2ProofsBeforePrune = store.getBlockProofs(blockHash: c2.midCID)
        XCTAssertFalse(c2ProofsBeforePrune.isEmpty, "the committed child must have a persisted proof before prune")

        // Commit children #3 and #4. Committing height 4 prunes height 2 (c2), so c2's
        // body/proof/contributions are pruned (out of the retention window).
        let c3 = try await commitChild(on: fx, previousMid: c2.block, nexusNonce: 3, ts: ts + 3_000)
        let c4 = try await commitChild(on: fx, previousMid: c3.block, nexusNonce: 4, ts: ts + 4_000)

        // Pruning ran: c2 is out of the retention window, so its block proof rows are
        // gone (deleteBlockProofs path drops block_proofs AND inherited_work_contributions).
        let c2ProofsAfterPrune = store.getBlockProofs(blockHash: c2.midCID)
        XCTAssertTrue(c2ProofsAfterPrune.isEmpty,
                      "retention prune must delete the out-of-window child's block proof")
        let contributionsAfterPrune = store.getAllInheritedWorkContributions()
        XCTAssertFalse(contributionsAfterPrune.contains { $0.blockHash == c2.midCID },
                       "CURRENT BEHAVIOR: retention prune drops the out-of-window child's inherited-work rows too")

        // The selected head is c4 (the latest secured child), unchanged by pruning,
        // and it retains its OWN inherited weight (it is in-window).
        let headAfterPrune = await chain.getMainChainTip()
        XCTAssertEqual(headAfterPrune, c4.midCID, "pruning out-of-window data must not change the selected head")
        let c4WeightAfterPrune = await fx.node.ensureLiveInheritedWeightIndex(directory: "Mid")
            .inheritedWeight(forChild: c4.midCID)
        XCTAssertGreaterThan(c4WeightAfterPrune, .zero, "the in-window head retains its inherited weight after prune")
        let committedTip = store.getChainTip()
        let committedHeight = store.getHeight()
        await fx.node.stop()

        // Restart on the same storage: the selected head must be the SAME head even
        // though the pruned block's proof/floor can no longer be replayed. This is
        // the durable invariant — pruning eligible data does not change fork choice
        // across a restart.
        let fx2 = try await makeChildNode(
            retentionDepth: 2, blockRetention: .retention, storagePath: storagePath, keyPair: kp
        )
        addTeardownBlock { [node = fx2.node] in await node.stop() }
        await fx2.node.restoreInheritedWeight(directory: "Mid")
        let chain2Maybe = await fx2.node.chain(forPath: ["Nexus", "Mid"])
        let chain2 = try XCTUnwrap(chain2Maybe)
        let store2Maybe = await fx2.node.stateStore(forPath: ["Nexus", "Mid"])
        let store2 = try XCTUnwrap(store2Maybe)

        let headAfterRestart = await chain2.getMainChainTip()
        XCTAssertEqual(headAfterRestart, c4.midCID,
                       "restart after prune must re-derive the same selected head")
        XCTAssertEqual(store2.getChainTip(), committedTip, "committed tip stable across prune + restart")
        XCTAssertEqual(store2.getHeight(), committedHeight, "committed height stable across prune + restart")
        let c4WeightAfterRestart = await fx2.node.ensureLiveInheritedWeightIndex(directory: "Mid")
            .inheritedWeight(forChild: c4.midCID)
        XCTAssertEqual(c4WeightAfterRestart, c4WeightAfterPrune,
                       "the surviving in-window head's inherited weight is identical after prune + restart")
    }

    // MARK: - Fixture 3: insertion-order independence (store / index level)

    /// The same set of verified inherited-weight contributions, applied in DIFFERENT
    /// orders, must resolve to the SAME inherited weight. The store's only-grows /
    /// CID-deduped union semantics make order irrelevant. Run at the
    /// `InheritedWeightStore` + `LiveInheritedWeightIndex` level (no node needed),
    /// mirroring `InheritedWeightStoreTests`, but specifically varying order.
    func test_insertionOrderIndependence() {
        // A child committed by several distinct contributors with overlap across the
        // "carrier groups" a node might apply in any order (out-of-order gossip,
        // duplicate carriers, reorg replay).
        let child = "C"
        let groupA: [(id: String, work: UInt256)] = [
            (id: "Root", work: UInt256(10)),
            (id: "MidA", work: UInt256(5)),
        ]
        let groupB: [(id: String, work: UInt256)] = [
            (id: "Root", work: UInt256(10)),   // overlaps groupA — must count once
            (id: "MidB", work: UInt256(7)),
        ]
        let groupC: [(id: String, work: UInt256)] = [
            (id: "MidA", work: UInt256(5)),    // overlaps groupA — must count once
            (id: "Deep", work: UInt256(3)),
        ]
        // Union over distinct contributor IDs: Root(10)+MidA(5)+MidB(7)+Deep(3) = 25.
        let expected = UInt256(25)

        func resolvedWeight(applying order: [[(id: String, work: UInt256)]]) -> UInt256 {
            let store = InheritedWeightStore()
            for group in order {
                store.recordVerifiedWorkContributions(group, committingChild: child)
            }
            return store.inheritedWeight(forChild: child)
        }

        let permutations: [[[(id: String, work: UInt256)]]] = [
            [groupA, groupB, groupC],
            [groupC, groupB, groupA],
            [groupB, groupA, groupC],
            [groupA, groupC, groupB],
            [groupC, groupA, groupB],
            [groupB, groupC, groupA],
            // Duplicate application of a group must not inflate the union either.
            [groupA, groupA, groupB, groupC, groupB],
        ]
        for order in permutations {
            XCTAssertEqual(resolvedWeight(applying: order), expected,
                           "store union weight must be insertion-order independent")
        }

        // The fork-choice projection (LiveInheritedWeightIndex) reading the same
        // store as its durable floor must also be order-independent. The live union
        // promotion is only-grows, so promoting the per-order resolved weights in
        // any sequence yields the same head-deciding value.
        func indexResolvedWeight(promotionOrder weights: [UInt256]) -> UInt256 {
            let index = LiveInheritedWeightIndex()
            for w in weights {
                index.promoteChildUnionWeight(childHash: child, weight: w)
            }
            return index.inheritedWeight(forChild: child)
        }
        // Whatever order partial unions are promoted in, the resolved value is the
        // maximum (only-grows) — identical regardless of arrival order.
        let partials = [UInt256(15), UInt256(22), expected, UInt256(18)]
        XCTAssertEqual(indexResolvedWeight(promotionOrder: partials), expected)
        XCTAssertEqual(indexResolvedWeight(promotionOrder: partials.reversed()), expected)
        XCTAssertEqual(indexResolvedWeight(promotionOrder: [expected, UInt256(1), UInt256(22)]), expected)
    }

    // MARK: - Helpers

    private func assertContributionsEqual(
        _ lhs: [(height: UInt64, blockHash: String, contributorID: String, work: UInt256)],
        _ rhs: [(height: UInt64, blockHash: String, contributorID: String, work: UInt256)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.count, rhs.count, "contribution row count must match across restart", file: file, line: line)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(a.height, b.height, file: file, line: line)
            XCTAssertEqual(a.blockHash, b.blockHash, file: file, line: line)
            XCTAssertEqual(a.contributorID, b.contributorID, file: file, line: line)
            XCTAssertEqual(a.work, b.work, file: file, line: line)
        }
    }
}
