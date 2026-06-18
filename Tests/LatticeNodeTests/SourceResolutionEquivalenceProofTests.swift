import XCTest
import Foundation
import cashew
import VolumeBroker
import UInt256
@testable import Lattice
@testable import LatticeNode

/// ANCHOR proof for the completed fetcher-zoo → ContentSource migration
/// (content-store cutover #5/#B).
///
/// The consensus-critical validation path resolves a block's content via a
/// *ContentSource composition* (OverlayContentSource / CompositeContentSource /
/// FetcherContentSource) over cashew's `resolve(paths:source:)`. The retired
/// per-CID fetcher zoo (the mempool overlay + composite fallbacks) has been
/// deleted; these tests now prove the SOURCE composition resolves the
/// BYTE-IDENTICAL block as the ORIGINAL built block, for the three composition
/// shapes the validation path depends on:
///   1. base-only             (empty mempool case)
///   2. overlay-then-fallback (mempool entries first, then base)
///   3. composite try-in-order
///
/// The split-tier fixtures (disjoint overlay/base, disjoint primary/fallback)
/// mean resolution can only succeed if the source composition honors
/// overlay-then-fallback / try-in-order precedence — the exact precedence the
/// retired fetcher compositions had.
///
/// `Block.contentResolutionPaths` is public and `VolumeImpl<Block>` (a cashew
/// `Header`) exposes `resolve(paths:source:)`, so the source path is expressed as
/// `VolumeImpl<Block>(rawCID: blockHash, node: nil).resolve(paths: Block.contentResolutionPaths, source:)`.
final class SourceResolutionEquivalenceProofTests: XCTestCase {

    private struct UnresolvedBlock: Error { let cid: String }

    // MARK: - Fixtures

    /// Real multi-volume genesis: distinct premine owner per tx (nonce 0) so the
    /// resolved closure has real transactions + spec + children. Mirrors
    /// ProvenClosureRetentionTests.buildMultiVolumeGenesis.
    private func buildMultiVolumeGenesis(accountCount: Int, fetcher: Fetcher) async throws -> Block {
        var transactions: [Transaction] = []
        for i in 0..<accountCount {
            let owner = "premine-owner-\(i)-\(UUID().uuidString)"
            let action = AccountAction(owner: owner, delta: Int64(1000 + i))
            let body = TransactionBody(
                accountActions: [action], actions: [], depositActions: [],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 0, nonce: 0
            )
            let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
            transactions.append(Transaction(signatures: [owner: "genesis"], body: bodyHeader))
        }
        return try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            transactions: transactions,
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: fetcher
        )
    }

    /// Every CID→Data entry in the block's stored closure (same walk
    /// `storeBlockFixture` uses), so tests can partition content across tiers.
    private func blockClosureEntries(_ block: Block) throws -> [String: Data] {
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        var out: [String: Data] = [:]
        for (cid, data) in storer.entries { out[cid] = data }
        return out
    }

    /// The CIDs the content-resolution paths actually walk (spec, transactions +
    /// bodies, children) — i.e. everything reachable EXCEPT the state references
    /// (postState/prevState/parentState), which `resolveBlockContent` leaves as
    /// unresolved Volume references. Used to pick overlay/base splits that the
    /// content walk genuinely traverses.
    private func contentCIDs(of block: Block, blockHash: String, all: [String: Data]) -> Set<String> {
        let stateRefs: Set<String> = [
            block.postState.rawCID,
            block.prevState.rawCID,
            block.parentState.rawCID,
        ]
        // Content CIDs = block root + everything not a state-ref root.
        var content = Set(all.keys).subtracting(stateRefs)
        content.insert(blockHash)
        return content
    }

    // MARK: - Resolution helpers

    /// SOURCE side: same path spec (`Block.contentResolutionPaths`) over a
    /// ContentSource via cashew's `resolve(paths:source:)`.
    private func resolveViaSource(blockHash: String, source: any ContentSource) async throws -> Block {
        let resolved = try await VolumeImpl<Block>(rawCID: blockHash, node: nil)
            .resolve(paths: Block.contentResolutionPaths, source: source)
        guard let node = resolved.node else {
            throw UnresolvedBlock(cid: blockHash)
        }
        return node
    }

    /// Strong identity check: the re-encoded block CIDs must match across every
    /// content field plus the references the content walk leaves intact.
    private func assertIdentical(
        _ a: Block,
        _ b: Block,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let aCID = try VolumeImpl<Block>(node: a).rawCID
        let bCID = try VolumeImpl<Block>(node: b).rawCID
        XCTAssertEqual(aCID, bCID, "\(message): re-encoded block CID differs", file: file, line: line)
        XCTAssertEqual(a.spec.rawCID, b.spec.rawCID, "\(message): spec", file: file, line: line)
        XCTAssertEqual(a.transactions.rawCID, b.transactions.rawCID, "\(message): transactions", file: file, line: line)
        XCTAssertEqual(a.children.rawCID, b.children.rawCID, "\(message): children", file: file, line: line)
        XCTAssertEqual(a.postState.rawCID, b.postState.rawCID, "\(message): postState", file: file, line: line)
        XCTAssertEqual(a.prevState.rawCID, b.prevState.rawCID, "\(message): prevState", file: file, line: line)
    }

    // MARK: - Test 1: base-only (empty-mempool case)

    func testSourceCompositionResolvesBlockContentIdenticalToOriginal() async throws {
        let cas = cas()
        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: cas)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        try await storeBlockFixture(block, to: cas)

        // SOURCE: the empty-overlay composition over the base — the empty-mempool
        // case (overlay returns base unchanged).
        let source = CompositeContentSource([
            OverlayContentSource(entries: [:], fallback: FetcherContentSource(cas))
        ])
        let viaSource = try await resolveViaSource(blockHash: blockHash, source: source)

        try assertIdentical(viaSource, block, "base-only")
        print("[SourceEquiv][base-only] source=\(try VolumeImpl<Block>(node: viaSource).rawCID)")
    }

    // MARK: - Test 2: overlay-then-fallback (mempool precedence)

    func testOverlaySourceServesMempoolEntriesThenFallsBack() async throws {
        let base = cas()
        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: base)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        // Partition the CONTENT closure: half the content CIDs go ONLY into the
        // overlay (mempool-style), the rest ONLY into the base. No CID is in both,
        // so resolution can only succeed if overlay-then-fallback precedence works
        // in BOTH worlds.
        let all = try blockClosureEntries(block)
        let content = contentCIDs(of: block, blockHash: blockHash, all: all)
        let sortedContent = content.sorted()
        var overlay: [String: Data] = [:]
        for (idx, cid) in sortedContent.enumerated() {
            guard let data = all[cid] else { continue }
            if idx % 2 == 0 {
                overlay[cid] = data                       // overlay-only
            } else {
                await base.store(rawCid: cid, data: data) // base-only
            }
        }
        XCTAssertFalse(overlay.isEmpty, "overlay must hold some content")
        XCTAssertGreaterThan(content.count, 2, "need a non-trivial content split")

        // SOURCE: OverlayContentSource(overlay, fallback: base-source). The
        // disjoint split means resolution succeeds only if overlay-then-fallback
        // precedence holds; the original-block identity check confirms it actually
        // traversed the split (not that it failed identically).
        let overlaySource = OverlayContentSource(
            entries: overlay,
            fallback: FetcherContentSource(base)
        )
        let viaSource = try await resolveViaSource(blockHash: blockHash, source: overlaySource)

        try assertIdentical(viaSource, block, "overlay-then-fallback vs original")
        print("[SourceEquiv][overlay] overlayCount=\(overlay.count) contentCount=\(content.count)")
    }

    // MARK: - Test 3: composite try-in-order

    func testCompositeSourceTriesInOrder() async throws {
        let primaryBase = cas()
        let fallbackBase = cas()
        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: primaryBase)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        // Split content across two disjoint bases. Resolution succeeds only if
        // BOTH compositions try primary then fallback (in order).
        let all = try blockClosureEntries(block)
        let content = contentCIDs(of: block, blockHash: blockHash, all: all)
        for (idx, cid) in content.sorted().enumerated() {
            guard let data = all[cid] else { continue }
            if idx % 2 == 0 {
                await primaryBase.store(rawCid: cid, data: data)
            } else {
                await fallbackBase.store(rawCid: cid, data: data)
            }
        }

        // SOURCE: CompositeContentSource([primary-source, fallback-source]) in
        // order. The disjoint split means resolution succeeds only if it tries
        // primary then fallback; the original-block identity check confirms it.
        let compositeSource = CompositeContentSource([
            FetcherContentSource(primaryBase),
            FetcherContentSource(fallbackBase),
        ])
        let viaSource = try await resolveViaSource(blockHash: blockHash, source: compositeSource)

        try assertIdentical(viaSource, block, "composite-order vs original")
        print("[SourceEquiv][composite] contentCount=\(content.count)")
    }
}
