import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import Ivy
import Tally
import UInt256
import cashew
import VolumeBroker

/// Fix: `submitMinedChildBlock` must announce the mined child's CID as the chain
/// tip ONLY when that block actually wins fork choice (the promoted-to-tip
/// contract centralized in `publishAcceptedBlock`/`broadcastCanonicalTipAnnounce`).
/// A mined child that lands as a SIDE FORK (lost the tie / lower work) must not
/// be announced as the tip — it may at most re-announce the incumbent canonical
/// tip (child-chain ingestion keeps peers' headers-first sync primed).
///
/// RED before the fix: `submitMinedChildBlock` called
/// `broadcastChainAnnounce(tipCID: header.rawCID, …)` UNCONDITIONALLY on accept,
/// so the side-fork child's CID was announced as the tip.
final class MinedChildBlockSideForkTests: XCTestCase {

    /// Boot a per-process child node rooted at Nexus ⊃ Mid (the leaf chain this
    /// node serves), and a separate Nexus fixture CAS to build proof carriers.
    private func makeChildNode() async throws -> (node: LatticeNode, fixture: TestBrokerFetcher, nexusGenesis: Block, midGenesis: Block) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false,
                fullChainPath: ["Nexus", "Mid"],
                minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis(spec: testSpec(), directory: "Mid")
        )
        addTeardownBlock { [node] in
            await node.stop()
            try? FileManager.default.removeItem(at: tmp)
        }

        let fixture = cas()
        let midGenesis = await node.genesisResult.block
        // Base all block timestamps on the node's actual Mid genesis timestamp so
        // child blocks are strictly later than their parent (Lattice's monotonic
        // timestamp validation).
        let ts = midGenesis.timestamp
        try await storeBlockFixtureTree(midGenesis, to: fixture)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: UInt256.max, fetcher: fixture
        )
        return (node, fixture, nexusGenesis, midGenesis)
    }

    private func storeBlockFixtureTree(_ block: Block, to f: TestBrokerFetcher) async throws {
        let header = try VolumeImpl<Block>(node: block)
        await f.store(rawCid: header.rawCID, data: block.toData()!)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        for (cid, data) in storer.entryList {
            await f.store(rawCid: cid, data: data)
        }
    }

    /// Mine a Mid child block on `previousMid` whose `parentState` is the Nexus
    /// carrier's prev-state (the committing-parent anchor invariant), embed it in
    /// a Nexus carrier block, generate the single-hop work proof, and store the
    /// whole tree both in the fixture CAS and the node's Mid network so the child
    /// block resolves locally for processing.
    private func minedChild(
        node: LatticeNode,
        fixture: TestBrokerFetcher,
        previousMid: Block,
        nexusGenesis: Block,
        nexusNonce: UInt64,
        ts: Int64
    ) async throws -> (midCID: String, block: Block, proof: ChildBlockProof) {
        // Build the child with the derived (retargeted) target/nextTarget so it
        // passes Lattice's `validateNextTarget` (target == parent.nextTarget and
        // nextTarget == windowed retarget). An explicit target would break that.
        // The carrier's prev-state is the Nexus genesis post-state (height-1 Nexus
        // block). The child's parentState must equal the committing parent's
        // prevState for `verifiedCommittingParentAnchor` to accept it.
        let parentAnchor = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: ts, nonce: nexusNonce, fetcher: fixture
        )
        let child = try await BlockBuilder.buildBlock(
            previous: previousMid, parentChainBlock: parentAnchor,
            timestamp: ts, nonce: 0, fetcher: fixture
        )
        try await storeBlockFixtureTree(child, to: fixture)

        let nexusCarrier = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Mid": child],
            timestamp: ts, nonce: nexusNonce, fetcher: fixture
        )
        try await storeBlockFixtureTree(nexusCarrier, to: fixture)

        let proof = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: nexusCarrier),
            childDirectory: "Mid",
            fetcher: fixture
        )

        // Mirror the proof carrier tree into the node's Mid network so the child
        // body + state resolve during processing. The child's parentState is the
        // Nexus carrier's prev-state (genesis post-state); store that subtree too
        // so the parent-chain state root resolves locally (a real child node holds
        // it via its parent subscription).
        if let network = await node.network(for: "Mid") {
            try await storeBlockFixtureVolumes(child, in: network)
            try await storeBlockFixtureVolumes(nexusGenesis, in: network)
        }

        let midCID = try VolumeImpl<Block>(node: child).rawCID
        return (midCID, child, proof)
    }

    func testMinedChildAnnouncedAsTipOnlyWhenItWinsForkChoice() async throws {
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode()
        let networkMaybe = await node.network(for: "Mid")
        let network = try XCTUnwrap(networkMaybe)
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        await network.resetTipPublishCountsForTesting()

        // 1) A winning mined child at height 1 — it extends the tip and IS the new
        //    canonical tip, so it must be announced as the tip.
        let winner = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 1, ts: ts + 1_000
        )
        let winResult = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: winner.block, proof: winner.proof
        )
        XCTAssertEqual(winResult.status, .accepted, "the winning mined child must be accepted")
        let tipAfterWinner = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterWinner, winner.midCID, "the winning child must become the canonical tip")
        let winnerAnnounceCount = await network.broadcastChainAnnounceCountForTesting()
        XCTAssertEqual(
            winnerAnnounceCount, 1,
            "a winning mined child must announce its tip exactly once"
        )
        let winnerAnnouncedTip = await network.lastBroadcastChainAnnounceTipCIDForTesting()
        XCTAssertEqual(
            winnerAnnouncedTip, winner.midCID,
            "the announced tip CID must be the winning child"
        )

        // 2) A mined child that lands as a SIDE FORK (accepted, but not the new
        //    canonical tip). Build a competing branch B1 → B2 (height 2, strictly
        //    heavier than the single-block A branch). Deliver B2 first while its
        //    parent B1 is absent (a retained, non-canonical side block), then mine
        //    + submit B1. Submitting B1 connects the heavier B branch and promotes
        //    its TIP (B2) via reorg — so B1 is accepted but `getMainChainTip()` is
        //    B2, not B1. B1 must therefore NOT be announced as the tip.
        let b1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 2, ts: ts + 2_000
        )
        let b2 = try await minedChild(
            node: node, fixture: fixture, previousMid: b1.block,
            nexusGenesis: nexusGenesis, nexusNonce: 3, ts: ts + 3_000
        )
        XCTAssertNotEqual(b1.midCID, winner.midCID, "B1 must be a distinct sibling of the winner")

        // Deliver B2 out of order (parent B1 absent) — retained as a side block.
        _ = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: b2.block, proof: b2.proof
        )

        await network.resetTipPublishCountsForTesting()

        // Now submit B1. It connects B2 to the chain; the height-2 B branch beats
        // the height-1 winner, so fork choice reorganizes onto B and the tip
        // becomes B2 (B1's descendant), NOT B1 itself.
        let b1Result = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: b1.block, proof: b1.proof
        )
        XCTAssertEqual(b1Result.status, .accepted, "B1 connects the heavier branch and is accepted")
        let tipAfterB1 = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB1, b2.midCID, "the heavier branch's TIP (B2) must be canonical, not B1")
        XCTAssertNotEqual(tipAfterB1, b1.midCID, "B1 itself must not be the canonical tip")

        // The core contract: the accepted-but-not-promoted B1 must NEVER be
        // announced as the chain tip. (Before the fix `submitMinedChildBlock`
        // announced `header.rawCID` unconditionally on accept — RED.)
        let b1AnnouncedTip = await network.lastBroadcastChainAnnounceTipCIDForTesting()
        XCTAssertNotEqual(
            b1AnnouncedTip, b1.midCID,
            "a mined child that lost fork choice (B1) must NOT be announced as the chain tip"
        )
    }
}
