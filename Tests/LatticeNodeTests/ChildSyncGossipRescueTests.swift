import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import UInt256
import cashew
import VolumeBroker

/// Prerequisite for unconditional child fast-forward SYNC admission: sync
/// deliberately never decides a child REORG (own-target sums are meaningless
/// for child ordering — a carrier's real weight is the securing work in its
/// ChildBlockProof), so the machinery that DOES own that decision — gossip
/// fork choice over trueCumWork = same-chain subtree weight + inherited
/// securing work — must be able to rescue a follower that is parked on a
/// cheaper branch (e.g. one it fast-forwarded onto via sync).
///
/// This test proves that rescue end-to-end at the node layer: a follower
/// whose canonical branch is TALLER but secured by child-only carriers
/// (zero inherited work) must reorg onto a SHORTER sibling branch whose
/// carrier clears the parent target (strictly greater trueCumWork), delivered
/// through the same proven-child ingestion gossip relay uses.
final class ChildSyncGossipRescueTests: XCTestCase {

    /// Parent (Nexus) target hard enough that a random carrier usually does
    /// NOT clear it, yet easy enough that a short nonce search finds a clearing
    /// one: p(clear) = 1/4 per nonce. workForTarget(max >> 2) == 4, so one
    /// clearing carrier out-weighs several trivial-target child blocks.
    private static let nexusTarget = UInt256.max >> 2

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
        let ts = midGenesis.timestamp
        try await storeBlockFixtureTree(midGenesis, to: fixture)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: Self.nexusTarget, fetcher: fixture
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

    /// Mine a Mid child block on `previousMid`, embedded in a Nexus carrier whose
    /// PoW hash clears the (hard) Nexus target iff `carrierClears`. A clearing
    /// carrier contributes workForTarget(nexusTarget) of inherited securing work;
    /// a non-clearing (child-only) carrier contributes zero.
    private func minedChild(
        node: LatticeNode,
        fixture: TestBrokerFetcher,
        previousMid: Block,
        nexusGenesis: Block,
        carrierClears: Bool,
        nonceSeed: UInt64,
        ts: Int64
    ) async throws -> (midCID: String, block: Block, proof: ChildBlockProof) {
        let parentAnchor = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: ts, nonce: nonceSeed, fetcher: fixture
        )
        let child = try await BlockBuilder.buildBlock(
            previous: previousMid, parentChainBlock: parentAnchor,
            timestamp: ts, nonce: 0, fetcher: fixture
        )
        try await storeBlockFixtureTree(child, to: fixture)

        // Nonce-search the carrier for the required clear/non-clear outcome so
        // the branch weights are deterministic, not left to hash luck.
        var carrier: Block? = nil
        for nonce in nonceSeed..<(nonceSeed + 10_000) {
            let candidate = try await BlockBuilder.buildBlock(
                previous: nexusGenesis, children: ["Mid": child],
                timestamp: ts, nonce: nonce, fetcher: fixture
            )
            let clears = candidate.validateProofOfWork(nexusHash: candidate.proofOfWorkHash())
            if clears == carrierClears {
                carrier = candidate
                break
            }
        }
        let minedCarrier = try XCTUnwrap(carrier, "no nonce in the search window produced carrierClears=\(carrierClears)")
        try await storeBlockFixtureTree(minedCarrier, to: fixture)

        let proof = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: minedCarrier),
            childDirectory: "Mid",
            fetcher: fixture
        )
        let expectedWork = await proof.securingWork()
        if carrierClears {
            XCTAssertGreaterThan(expectedWork, .zero, "clearing carrier must contribute inherited securing work")
        } else {
            XCTAssertEqual(expectedWork, .zero, "child-only carrier must contribute zero inherited securing work")
        }

        if let network = await node.network(for: "Mid") {
            try await storeBlockFixtureVolumes(child, in: network)
            try await storeBlockFixtureVolumes(nexusGenesis, in: network)
        }
        return (try VolumeImpl<Block>(node: child).rawCID, child, proof)
    }

    /// Rescue boundary, case 1 (WORKS?): the competing heavier-secured branch
    /// forks at the tip's parent — its block arrives at the SAME height as the
    /// local tip, so the gossip pipeline's height-monotonicity guard
    /// (processBlockAndRecoverReorgUnlocked: `block.height < localHeight` →
    /// rejected) does not fire, and inherited-weight fork choice can decide.
    func testGossipReorgsEqualHeightSiblingWithHeavierSecuringWork() async throws {
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode()
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        // Incumbent: one child block secured by a child-only carrier (zero
        // inherited work).
        let a1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: false, nonceSeed: 1_000, ts: ts + 1_000
        )
        let a1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: a1.block, proof: a1.proof)
        XCTAssertEqual(a1Result.status, .accepted)
        let tipOnA = await chain.getMainChainTip()
        XCTAssertEqual(tipOnA, a1.midCID)

        // Challenger: an EQUAL-HEIGHT sibling whose carrier clears the hard
        // Nexus target — strictly greater trueCumWork (1 + workForTarget(target)
        // vs 1 + 0), so this is NOT an equal-work tie and must be adopted.
        let b1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: true, nonceSeed: 3_000, ts: ts + 2_000
        )
        let b1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: b1.block, proof: b1.proof)
        XCTAssertEqual(b1Result.status, .accepted, "an equal-height heavier-secured sibling must be accepted")

        var tip = await chain.getMainChainTip()
        for _ in 0..<50 where tip != b1.midCID {
            try await Task.sleep(for: .milliseconds(100))
            tip = await chain.getMainChainTip()
        }
        XCTAssertEqual(
            tip, b1.midCID,
            "fork choice must adopt the equal-height sibling with strictly greater inherited securing work"
        )
    }

    /// Rescue boundary, case 2 — CHARACTERIZATION OF A KNOWN GAP (this test
    /// pins today's behavior; it is NOT an endorsement of it).
    ///
    /// The heavier-secured branch is offered newest-first while the follower's
    /// cheap branch is TALLER — the realistic shape of the canonical branch
    /// reaching a follower parked on a cheaper fork. Today the follower CANNOT
    /// be rescued:
    ///  - the interior connector BELOW the local tip height is hard-rejected by
    ///    the gossip pipeline's height-monotonicity guard
    ///    (processBlockAndRecoverReorgUnlocked: `block.height < localHeight`),
    ///    so the heavier branch can never become contiguously body-present;
    ///  - Lattice's held-heavier convergence transport
    ///    (`ChainLevel.backfillHeldHeavierSubtree` /
    ///    `chain.heldHeavierBackfillTarget()`) has NO call site in the node, so
    ///    a held heavier subtree never requests its missing interior bodies;
    ///  - child-chain SYNC admission is fast-forward-only by design, so sync
    ///    cannot deliver the competing branch either.
    ///
    /// Net: gossip fork choice rescues only a fork at depth 1 (the equal-height
    /// sibling swap proven above). Any deeper cheap-branch parking is permanent.
    /// When the missing rescue transport is wired, this test MUST be flipped to
    /// assert convergence on the heavier branch (tip == b2).
    func testGossipCannotYetRescueCheaperTallerBranchWithForkBelowTipHeight() async throws {
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode()
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        // Branch A (the follower's branch): two child blocks secured only by
        // child-only carriers — zero inherited work, subtree weight = 2 trivial
        // own-target units.
        let a1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: false, nonceSeed: 1_000, ts: ts + 1_000
        )
        let a2 = try await minedChild(
            node: node, fixture: fixture, previousMid: a1.block,
            nexusGenesis: nexusGenesis, carrierClears: false, nonceSeed: 2_000, ts: ts + 2_000
        )
        let a1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: a1.block, proof: a1.proof)
        XCTAssertEqual(a1Result.status, .accepted)
        let a2Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: a2.block, proof: a2.proof)
        XCTAssertEqual(a2Result.status, .accepted)
        let tipOnA = await chain.getMainChainTip()
        XCTAssertEqual(tipOnA, a2.midCID, "the follower starts parked on the taller cheap branch")

        // Branch B: B1 (height 1) → B2 (height 2), BOTH with clearing carriers.
        // trueCumWork(B) strictly exceeds trueCumWork(A) = 2.
        let b1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: true, nonceSeed: 3_000, ts: ts + 3_000
        )
        let b2 = try await minedChild(
            node: node, fixture: fixture, previousMid: b1.block,
            nexusGenesis: nexusGenesis, carrierClears: true, nonceSeed: 4_000, ts: ts + 4_000
        )

        // Deliver newest-first, the realistic gossip shape for a follower that
        // just came back online. TODAY: B1 (height 1 < local tip height 2) is
        // hard-rejected by the height-monotonicity guard, so the heavier branch
        // can never connect, and the follower stays parked on the cheap branch.
        let b2Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: b2.block, proof: b2.proof)
        let b1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: b1.block, proof: b1.proof)
        XCTAssertEqual(
            b1Result.status, .rejected,
            "PINS THE GAP: the heavier branch's interior connector below the local tip height is undeliverable via gossip — flip this test to assert convergence once a held-heavier rescue transport exists"
        )

        // Give fork choice every chance to converge; today it cannot.
        var tip = await chain.getMainChainTip()
        for _ in 0..<20 where tip != b2.midCID {
            try await Task.sleep(for: .milliseconds(100))
            tip = await chain.getMainChainTip()
        }
        XCTAssertEqual(
            tip, a2.midCID,
            "PINS THE GAP: the follower remains on the cheaper taller branch (b2Result=\(b2Result.status), b1Result=\(b1Result.status)) — no gossip rescue for forks deeper than the tip sibling"
        )
    }
}
