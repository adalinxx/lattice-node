import XCTest
import Foundation
import cashew
import VolumeBroker
import UInt256
@testable import Lattice
@testable import LatticeNode

/// Equivalence coverage for the TWO remaining local-broker resolve call sites
/// migrated to the source API (`resolve(paths:source:)`):
///
///   - LatticeNode+Sync.swift  — deep-sync durable-presence check (composite shape
///     `CompositeContentSource([FetcherContentSource(durable)] + childSources)`).
///   - LatticeNode+Mining.swift — work-template resolution (single local-broker
///     shape `FetcherContentSource(localFetcher)`).
///
/// Both are LOCAL-BROKER (canonicalContentFetcher) sites, so the migration bridges
/// the EXACT brokers via `FetcherContentSource` (byte-identical, sequential
/// per-CID — no network wave-batching to gain; that win is only on the network tier,
/// already landed in #287). These tests confirm the bridged source resolves the
/// BYTE-IDENTICAL ORIGINAL block for the two broker shapes the migrated sites use,
/// with a disjoint-tier split so the equivalence is non-vacuous.
final class ResolveSourceRestTests: XCTestCase {

    private struct UnresolvedBlock: Error { let cid: String }

    // MARK: - Fixtures (mirrors SourceResolutionEquivalenceProofTests)

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

    private func blockClosureEntries(_ block: Block) throws -> [String: Data] {
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        var out: [String: Data] = [:]
        for (cid, data) in storer.entries { out[cid] = data }
        return out
    }

    private func contentCIDs(of block: Block, blockHash: String, all: [String: Data]) -> Set<String> {
        let stateRefs: Set<String> = [
            block.postState.rawCID,
            block.prevState.rawCID,
            block.parentState.rawCID,
        ]
        var content = Set(all.keys).subtracting(stateRefs)
        content.insert(blockHash)
        return content
    }

    // MARK: - Resolution helpers

    /// SOURCE side: exactly what the migrated sites call now.
    private func resolveViaSource(blockHash: String, source: any ContentSource) async throws -> Block {
        let resolved = try await VolumeImpl<Block>(rawCID: blockHash, node: nil)
            .resolve(paths: Block.contentResolutionPaths, source: source)
        guard let node = resolved.node else { throw UnresolvedBlock(cid: blockHash) }
        return node
    }

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

    // MARK: - Test 1: Mining site shape — single local-broker fetcher

    /// Mirrors `LatticeNode+Mining.swift`: the whole content closure lives in one
    /// local broker; `FetcherContentSource(localFetcher)` must resolve the
    /// identical original block.
    func testLocalBrokerSourceMatchesOriginalForMiningTemplateShape() async throws {
        let localBroker = cas()
        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: localBroker)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        try await storeBlockFixture(block, to: localBroker)

        let viaSource = try await resolveViaSource(
            blockHash: blockHash,
            source: FetcherContentSource(localBroker)
        )

        // Non-vacuous: the source actually resolved the real block.
        try assertIdentical(viaSource, block, "mining-local-broker vs original")
    }

    // MARK: - Test 2: Sync site shape — composite content source

    /// Mirrors `LatticeNode+Sync.swift`: content is split across a durable broker
    /// plus child-network brokers stitched by `CompositeContentSource` (each member
    /// bridged via `FetcherContentSource`). Disjoint tiers ⇒ resolution
    /// succeeds only if the composite walks every fallback in order; cross-checked
    /// against the original block.
    func testCompositeSourceMatchesOriginalForSyncDurablePresenceShape() async throws {
        let durableBroker = cas()
        let childBrokerA = cas()
        let childBrokerB = cas()
        let block = try await buildMultiVolumeGenesis(accountCount: 8, fetcher: durableBroker)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        // Scatter the content closure across the durable + child brokers so
        // resolution succeeds only if the composite walks every fallback.
        let all = try blockClosureEntries(block)
        let content = contentCIDs(of: block, blockHash: blockHash, all: all)
        let brokers = [durableBroker, childBrokerA, childBrokerB]
        for (idx, cid) in content.sorted().enumerated() {
            guard let data = all[cid] else { continue }
            await brokers[idx % brokers.count].store(rawCid: cid, data: data)
        }
        XCTAssertGreaterThan(content.count, 2, "need a non-trivial content split")

        // Exactly the Sync.swift composition: durable broker primary, child brokers
        // as fallbacks in order.
        let compositeSource = CompositeContentSource([
            FetcherContentSource(durableBroker),
            FetcherContentSource(childBrokerA),
            FetcherContentSource(childBrokerB),
        ])
        let viaSource = try await resolveViaSource(blockHash: blockHash, source: compositeSource)

        try assertIdentical(viaSource, block, "sync-composite vs original")
    }
}
