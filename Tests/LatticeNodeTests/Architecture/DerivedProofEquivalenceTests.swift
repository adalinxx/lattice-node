import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// A child level derives a carried block's `ChildBlockProof` in-host
/// (`Carriage.proof`) from its co-hosted parent level's reads
/// (`LocalParentLevel.carrierContent`, `.incomingProof`) and the child block
/// itself. The derived proof is byte-identical to the one the parent issues
/// through its proof pipeline (`prepareChildProofs`, promotion), and so is
/// the portable attachment it becomes: per root, at every depth, whether the
/// middle carrier was accepted or only relayed.
final class DerivedProofEquivalenceTests: XCTestCase {

    func testTheNexusHopEqualsTheIssuedProof() async throws {
        let nexus = try await open(["Nexus"], key: "81")
        let payments = try await open(["Nexus", "Payments"], key: "82")
        let seed = ChildGenesisSeed(spec: NexusGenesis.spec, premineTo: nil, timestamp: 1)
        let genesis = try await ChildGenesisBuilder.build(
            seed: seed, chainPath: ["Nexus", "Payments"], fetcher: nexus
        )
        let recording = try await record(
            anchorOf: genesis, directory: "Payments", on: nexus,
            previous: try await nexus.canonicalTipBlock(), chainPath: ["Nexus"], timestamp: 1
        )
        let up = try await payments.activateChildGenesis(
            seed: seed, confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(up)
        let provisional = try await BlockBuilder.buildBlock(
            previous: recording, timestamp: 2, nonce: 0, fetcher: nexus
        )
        let childBlock = try await BlockBuilder.buildBlock(
            previous: genesis, parentChainBlock: provisional, timestamp: 2,
            fetcher: UnionFetcher([nexus, payments])
        )
        let unmined = try await BlockBuilder.buildBlock(
            previous: recording, children: ["Payments": childBlock],
            timestamp: 2, nonce: 0, fetcher: nexus
        )
        let carrier = try XCTUnwrap(BlockBuilder.mine(
            block: unmined, target: min(recording.nextTarget, childBlock.target)
        ))
        let carrierCID = try await issue(carrier, into: "Payments", on: nexus)
        let childContent = InMemoryContentStore()
        try await BlockHeader(node: childBlock).storeBlock(
            fetcher: UnionFetcher([nexus, payments]), storer: childContent
        )
        let parentLevel = LocalParentLevel(nexus)
        let noUpstream = await parentLevel.incomingProof(carrier: carrierCID, root: carrierCID)
        XCTAssertNil(noUpstream, "Nexus has no upstream proof")
        try await assertDerivedEqualsIssued(
            carrierCID: carrierCID, rootCID: carrierCID,
            childCID: try BlockHeader(node: childBlock).rawCID,
            directory: "Payments", parent: nexus, parentIsNexus: true,
            childContent: childContent
        )
        // A Nexus carriage is its own root: under another root it composes
        // nothing.
        let otherRoot = try await Carriage(
            carrierCID: carrierCID, rootCID: "other", childCID: nil
        ).proof(
            directory: "Payments", parentIsNexus: true, upstream: nil,
            fetcher: CoalescingFetcher(CompositeContentSource([
                parentLevel.carrierContent(carrierCID), childContent,
            ]))
        )
        XCTAssertNil(otherRoot)
    }

    func testDepthTwoUnderOneRootEqualsTheIssuedProof() async throws {
        let levels = try await twoLevels(roots: 1, relayOnlyMiddle: false)
        try await assertGrandchildProofs(levels)
    }

    /// The same middle block C under two Nexus roots R1 and R2: the middle
    /// holds an incoming proof per root, and the grandchild's proof derives
    /// per root, each equal to the one the middle issues for that root.
    func testDepthTwoUnderTwoRootsEqualsTheIssuedProofPerRoot() async throws {
        let levels = try await twoLevels(roots: 2, relayOnlyMiddle: false)
        XCTAssertEqual(levels.roots.count, 2)
        XCTAssertNotEqual(levels.roots[0], levels.roots[1])
        let heldRoots = try await levels.a.recoveredIncomingCarrierRootCIDs(
            for: levels.a2CID
        )
        XCTAssertEqual(Set(heldRoots), Set(levels.roots))
        try await assertGrandchildProofs(levels)
    }

    /// A middle block C whose root misses the middle's own target is only
    /// relayed there, never accepted: the middle still holds its incoming
    /// proof, and the grandchild's proof derives from it.
    func testARelayOnlyMiddleCarrierEqualsTheIssuedProof() async throws {
        let levels = try await twoLevels(roots: 1, relayOnlyMiddle: true)
        let accepted = await levels.a.hasAcceptedBlock(levels.a2CID)
        XCTAssertFalse(accepted, "C is relay-only at the middle level")
        let commitments = await levels.a.childCommitments(ofCarrier: levels.a2CID)
        XCTAssertNil(commitments, "a relayed carrier has no consensus metadata")
        // Relayed, C's block boundary is not in the middle's store: in a host
        // it is the middle's own contextual candidate, or the middle's
        // overlay serves it by CID (`carrierContent`'s fallback). The fixture
        // hands it in as that source.
        let local = await LocalParentLevel(levels.a).carrierContent(levels.a2CID)
            .fetch([levels.a2CID])
        XCTAssertTrue(local.isEmpty, "a relayed carrier's content is not local")
        try await assertGrandchildProofs(levels, carrierFallback: levels.a2Content)
    }

    // MARK: - Fixture

    private struct TwoLevels {
        let nexus: ChainProcess
        let a: ChainProcess
        let b: ChainProcess
        let a2CID: String
        let b1CID: String
        let roots: [String]
        let bContent: InMemoryContentStore
        let a2Content: InMemoryContentStore
    }

    private func assertGrandchildProofs(
        _ levels: TwoLevels, carrierFallback: InMemoryContentStore? = nil
    ) async throws {
        for root in levels.roots {
            try await assertDerivedEqualsIssued(
                carrierCID: levels.a2CID, rootCID: root, childCID: levels.b1CID,
                directory: "B", parent: levels.a, parentIsNexus: false,
                childContent: levels.bContent, carrierFallback: carrierFallback
            )
        }
        // No incoming proof under an unknown root: nothing to compose onto.
        let unknown = await LocalParentLevel(levels.a).incomingProof(
            carrier: levels.a2CID, root: "unknown"
        )
        XCTAssertNil(unknown)
    }

    /// Nexus anchors A; N1 carries A1 (committing B's anchor); B comes up.
    /// A2 on A1 commits B1; each of `roots` Nexus siblings on N1 commits A2,
    /// and A admits (or, with `relayOnlyMiddle`, only relays) A2 under each
    /// root and issues B1's proof per root through its pipeline.
    private func twoLevels(roots rootCount: Int, relayOnlyMiddle: Bool) async throws -> TwoLevels {
        let nexus = try await open(["Nexus"], key: "91")
        let a = try await open(["Nexus", "A"], key: "92")
        let b = try await open(["Nexus", "A", "B"], key: "93")
        let aSeed = ChildGenesisSeed(spec: NexusGenesis.spec, premineTo: nil, timestamp: 1)
        let aGenesis = try await ChildGenesisBuilder.build(
            seed: aSeed, chainPath: ["Nexus", "A"], fetcher: nexus
        )
        let n0 = try await record(
            anchorOf: aGenesis, directory: "A", on: nexus,
            previous: try await nexus.canonicalTipBlock(), chainPath: ["Nexus"], timestamp: 1
        )
        let aUp = try await a.activateChildGenesis(
            seed: aSeed, confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(aUp)
        let bSeed = ChildGenesisSeed(spec: NexusGenesis.spec, premineTo: nil, timestamp: 1)
        let bGenesis = try await ChildGenesisBuilder.build(
            seed: bSeed, chainPath: ["Nexus", "A", "B"], fetcher: nexus
        )
        let bAnchor = try signedGenesisAnchorTransaction(
            directory: "B", childGenesisCID: try BlockHeader(node: bGenesis).rawCID,
            chainPath: ["Nexus", "A"]
        )
        try await VolumeImpl<Transaction>(node: bAnchor).storeRecursively(storer: nexus)

        // N1 carries A1. A1 is A's block 1, so its committed target anchors
        // A's schedule: a hard one lets a root clear B's target but miss A's.
        let provisional1 = try await BlockBuilder.buildBlock(
            previous: n0, timestamp: 2, nonce: 0, fetcher: nexus
        )
        let a1 = try await BlockBuilder.buildBlock(
            previous: aGenesis, transactions: [bAnchor], parentChainBlock: provisional1,
            timestamp: 2, target: relayOnlyMiddle ? UInt256.max >> 6 : nil,
            fetcher: UnionFetcher([nexus, a])
        )
        let unminedN1 = try await BlockBuilder.buildBlock(
            previous: n0, children: ["A": a1], timestamp: 2, nonce: 0, fetcher: nexus
        )
        let n1 = try XCTUnwrap(BlockBuilder.mine(
            block: unminedN1, target: min(n0.nextTarget, a1.target)
        ))
        let n1CID = try await issue(n1, into: "A", on: nexus)
        try await admit(
            a1, under: n1CID, directory: "A", parent: nexus, child: a,
            preparing: [], expectAccepted: true
        )
        let bUp = try await b.activateChildGenesis(
            seed: bSeed, confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(bUp)

        let provisionalA = try await BlockBuilder.buildBlock(
            previous: a1, timestamp: 3, nonce: 0, fetcher: nexus
        )
        let b1 = try await BlockBuilder.buildBlock(
            previous: bGenesis, parentChainBlock: provisionalA, timestamp: 3, fetcher: nexus
        )
        let provisionalN = try await BlockBuilder.buildBlock(
            previous: n1, timestamp: 3, nonce: 0, fetcher: nexus
        )
        let a2 = try await BlockBuilder.buildBlock(
            previous: a1, children: ["B": b1], parentChainBlock: provisionalN,
            timestamp: 3, fetcher: UnionFetcher([nexus, a])
        )
        if relayOnlyMiddle {
            XCTAssertLessThan(a2.target, b1.target, "A's target is harder than B's")
        }
        var roots: [String] = []
        for index in 0..<rootCount {
            let unmined = try await BlockBuilder.buildBlock(
                previous: n1, children: ["A": a2], timestamp: 3 + Int64(index),
                nonce: 0, fetcher: nexus
            )
            let root: Block
            if relayOnlyMiddle {
                // Clears Nexus and B, misses A: a carrier at A.
                let target = min(n1.nextTarget, b1.target)
                root = try XCTUnwrap((0..<UInt64(1_000_000)).lazy.map {
                    unmined.replacingNonce($0)
                }.first {
                    let hash = $0.proofOfWorkHash()
                    return hash <= target && hash > a2.target
                })
            } else {
                root = try XCTUnwrap(BlockBuilder.mine(
                    block: unmined, target: min(n1.nextTarget, a2.target)
                ))
            }
            let rootCID = try await issue(root, into: "A", on: nexus)
            try await admit(
                a2, under: rootCID, directory: "A", parent: nexus, child: a,
                preparing: ["B"], carrying: [b1], expectAccepted: !relayOnlyMiddle
            )
            roots.append(rootCID)
        }
        let bContent = InMemoryContentStore()
        try await BlockHeader(node: b1).storeBlock(
            fetcher: UnionFetcher([a, nexus]), storer: bContent
        )
        let a2Content = InMemoryContentStore()
        try await BlockHeader(node: a2).storeBlock(
            fetcher: UnionFetcher([a, nexus]), storer: a2Content
        )
        return TwoLevels(
            nexus: nexus, a: a, b: b,
            a2CID: try BlockHeader(node: a2).rawCID,
            b1CID: try BlockHeader(node: b1).rawCID,
            roots: roots, bContent: bContent, a2Content: a2Content
        )
    }

    /// `carrier` admitted on `parent` (a root level), which issues the proof
    /// of what it carries into `directory` through its pipeline.
    private func issue(
        _ carrier: Block, into directory: String, on parent: ChainProcess
    ) async throws -> String {
        let header = try BlockHeader(node: carrier)
        _ = try await parent.prepareChildProofs(for: carrier, capacity: 16)
        let outcome = try await parent.importBlock(
            header, preparingChildDirectories: [directory]
        )
        XCTAssertTrue(outcome.decision.isAccepted, "carrier into \(directory)")
        _ = try await parent.retryPendingChildProofs(carrierCID: header.rawCID)
        return header.rawCID
    }

    /// `block` admitted on `child` with the proof `parent` issued for it
    /// under `rootCID`; `child` then issues the proofs of what `block`
    /// carries into `preparing`.
    private func admit(
        _ block: Block, under rootCID: String, directory: String,
        parent: ChainProcess, child: ChainProcess, preparing: [String],
        carrying: [Block] = [], expectAccepted: Bool
    ) async throws {
        let blockCID = try BlockHeader(node: block).rawCID
        let issuedValue = try await parent.store.issuedChildEvidence(
            childCID: blockCID, directory: directory, rootCID: rootCID
        )
        let issued = try XCTUnwrap(issuedValue, "\(directory) proof under \(rootCID)")
        let content = InMemoryContentStore()
        try await BlockHeader(node: block).storeBlock(
            fetcher: UnionFetcher([parent, child]), storer: content
        )
        // The carrier package brings the committed child block along.
        for carried in carrying {
            try await BlockHeader(node: carried).storeBlock(
                fetcher: UnionFetcher([child, parent]), storer: content
            )
        }
        let outcome = try await child.importBlock(
            BlockHeader(rawCID: blockCID, node: nil, encryptionInfo: nil),
            authenticatedChildPackage: AuthenticatedChildPackage(package: ChildValidationPackage(
                proof: issued.proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: Array(child.configuration.chainPath.dropLast()),
                    fromStateCID: LatticeState.emptyHeader.rawCID,
                    toStateCID: block.parentState.rawCID
                )
            )),
            preparingChildDirectories: preparing,
            remoteSource: content
        )
        XCTAssertEqual(
            outcome.decision.isAccepted, expectAccepted,
            "\(directory) block admission: \(outcome.decision)"
        )
        XCTAssertNotNil(outcome.parentCarrierLink, "the relay link is issued")
        if !preparing.isEmpty {
            _ = try await child.retryPendingChildProofs(
                carrierCID: blockCID, remoteSource: content
            )
        }
    }

    /// Derives the proof of `childCID` carried by `carrierCID` under `rootCID`
    /// through `parent`'s level reads, and checks it against the proof
    /// `parent` issued: the same bytes and the same portable attachment.
    private func assertDerivedEqualsIssued(
        carrierCID: String, rootCID: String, childCID: String, directory: String,
        parent: ChainProcess, parentIsNexus: Bool, childContent: InMemoryContentStore,
        carrierFallback: InMemoryContentStore? = nil
    ) async throws {
        let parentLevel = LocalParentLevel(parent)
        let carrierSources: [any ContentSource] = [parentLevel.carrierContent(carrierCID)]
            + (carrierFallback.map { [$0] } ?? [])
        let issuedValue = try await parent.store.issuedChildEvidence(
            childCID: childCID, directory: directory, rootCID: rootCID
        )
        let issued = try XCTUnwrap(issuedValue, "issued under \(rootCID)")
        // The carriage the parent sends when the child CID is not in its
        // metadata: the child resolves it from the carrier's index.
        let resolved = await NodeNetworkRuntime.carriedChildCID(
            carrierCID: carrierCID, directory: directory,
            source: CompositeContentSource(carrierSources)
        )
        XCTAssertEqual(resolved, childCID)
        let upstream = await parentLevel.incomingProof(carrier: carrierCID, root: rootCID)
        if !parentIsNexus {
            XCTAssertNotNil(upstream, "the middle holds its incoming proof under \(rootCID)")
        }
        let derivedValue = try await Carriage(
            carrierCID: carrierCID, rootCID: rootCID, childCID: childCID
        ).proof(
            directory: directory, parentIsNexus: parentIsNexus, upstream: upstream,
            fetcher: CoalescingFetcher(CompositeContentSource(
                carrierSources + [childContent]
            ))
        )
        let derived = try XCTUnwrap(derivedValue)
        XCTAssertEqual(derived.rootCID, rootCID)
        XCTAssertEqual(try derived.serialize(), try issued.proof.serialize())
        XCTAssertEqual(
            try attachmentCID(derived, childCID: childCID), issued.attachmentCID,
            "the derived proof's portable attachment is the issued one"
        )
    }

    private func attachmentCID(_ proof: ChildBlockProof, childCID: String) throws -> String {
        try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(proof: proof).encode(),
            childCID: childCID
        ).rawCID
    }

    private func open(_ path: [String], key: String) async throws -> ChainProcess {
        try await ChainProcess.open(configuration: try NodeConfiguration(
            chainPath: path,
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: key, count: 32)
        ))
    }

    private func record(
        anchorOf childGenesis: Block, directory: String, on chain: ChainProcess,
        previous: Block, chainPath: [String], timestamp: Int64
    ) async throws -> Block {
        let authorization = try signedGenesisAnchorTransaction(
            directory: directory, childGenesisCID: try BlockHeader(node: childGenesis).rawCID,
            chainPath: chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(storer: chain)
        let unmined = try await BlockBuilder.buildBlock(
            previous: previous, transactions: [authorization], timestamp: timestamp,
            nonce: 0, fetcher: chain
        )
        let mined = try XCTUnwrap(BlockBuilder.mine(block: unmined, target: previous.nextTarget))
        let outcome = try await chain.importBlock(try BlockHeader(node: mined))
        XCTAssertTrue(outcome.decision.isAccepted, "recording block on \(chainPath)")
        return mined
    }
}
