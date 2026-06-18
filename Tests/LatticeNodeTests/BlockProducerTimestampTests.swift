import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew

final class BlockProducerTimestampTests: XCTestCase {
    private func store(_ block: Block, to fetcher: TestBrokerFetcher) async throws {
        let header = try VolumeImpl<Block>(node: block)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        await storer.flush(to: fetcher)
    }

    private func buildFutureStampedChain(
        blockCount: Int = 12
    ) async throws -> (fetcher: TestBrokerFetcher, spec: ChainSpec, chain: ChainState, blocks: [Block]) {
        let fetcher = cas()
        let spec = testSpec(retargetWindow: 1_000)
        let baseTimestamp = now() + 30_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: baseTimestamp,
            target: UInt256.max,
            fetcher: fetcher
        )
        try await store(genesis, to: fetcher)

        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        var blocks = [genesis]
        var previous = genesis
        for index in 1...blockCount {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: baseTimestamp + Int64(index) * 1_000,
                target: UInt256.max,
                nonce: UInt64(index),
                fetcher: fetcher
            )
            try await store(block, to: fetcher)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block),
                block: block
            )
            XCTAssertTrue(result.extendsMainChain, "fixture block \(index) should extend the chain")
            blocks.append(block)
            previous = block
        }
        return (fetcher, spec, chain, blocks)
    }

    private func recentAncestorTimestamps(from blocks: [Block]) -> [Int64] {
        blocks.suffix(Int(BlockProducer.timestampMedianPastWindow)).reversed().map(\.timestamp)
    }

    private func difficultyAncestorTimestamps(from blocks: [Block]) -> [Int64] {
        blocks.reversed().map(\.timestamp)
    }

    func testCandidateTimestampClampsAboveParentMedianAndFutureBound() {
        let nowMs: Int64 = 1_000_000
        let previousTimestamp = nowMs + 30_000
        let ancestors = (0..<11).map { previousTimestamp - Int64($0) * 1_000 }

        let timestamp = BlockProducer.adjustedCandidateTimestamp(
            nowMs: nowMs,
            previousTimestamp: previousTimestamp,
            ancestorTimestamps: ancestors
        )

        XCTAssertGreaterThan(timestamp, previousTimestamp)
        XCTAssertGreaterThan(timestamp, BlockProducer.medianTimePast(ancestors)!)
        XCTAssertLessThanOrEqual(timestamp, nowMs + BlockProducer.maxCandidateFutureDriftMs)

        let monotone = BlockProducer.adjustedCandidateTimestamp(
            nowMs: nowMs + 5_000,
            previousTimestamp: previousTimestamp,
            ancestorTimestamps: ancestors,
            previousCandidateTimestamp: timestamp + 10_000
        )
        XCTAssertGreaterThanOrEqual(monotone, timestamp + 10_000)
    }

    func testRestampCadenceIsOneSecondWallClock() {
        let start: Int64 = 50_000
        XCTAssertFalse(BlockProducer.shouldRestampCandidate(nowMs: start + 999, lastRestampMs: start))
        XCTAssertTrue(BlockProducer.shouldRestampCandidate(nowMs: start + 1_000, lastRestampMs: start))
        XCTAssertTrue(BlockProducer.shouldRestampCandidate(nowMs: start + 5_000, lastRestampMs: start))
    }

    func testSealedTimestampPassesValidationWithFutureAncestors() async throws {
        let fixture = try await buildFutureStampedChain()
        let previousBlock = fixture.blocks.last!
        let ancestors = recentAncestorTimestamps(from: fixture.blocks)
        let mempool = NodeMempool(maxSize: 100)
        let producer = BlockProducer(
            chainState: fixture.chain,
            mempool: mempool,
            fetcher: fixture.fetcher,
            spec: fixture.spec,
            chainPath: [DEFAULT_ROOT_DIRECTORY],
            batchSize: 10_000
        )

        let producedOptional = try await producer.produceBlock()
        let produced = try XCTUnwrap(producedOptional)
        let block = produced.block

        XCTAssertGreaterThan(block.timestamp, previousBlock.timestamp)
        XCTAssertGreaterThan(block.timestamp, BlockProducer.medianTimePast(ancestors)!)
        XCTAssertLessThanOrEqual(block.timestamp, now() + BlockProducer.maxCandidateFutureDriftMs)
        XCTAssertTrue(block.validateTimestamp(parent: previousBlock, ancestorTimestamps: ancestors))
    }

    func testRestampedBlockUsesCanonicalWindowedDifficulty() async throws {
        let fixture = try await buildFutureStampedChain()
        let previousBlock = fixture.blocks.last!
        let ancestors = difficultyAncestorTimestamps(from: fixture.blocks)
        let mempool = NodeMempool(maxSize: 100)
        let producer = BlockProducer(
            chainState: fixture.chain,
            mempool: mempool,
            fetcher: fixture.fetcher,
            spec: fixture.spec,
            chainPath: [DEFAULT_ROOT_DIRECTORY],
            batchSize: 10_000
        )

        let producedOptional = try await producer.produceBlock()
        let produced = try XCTUnwrap(producedOptional)
        let block = produced.block
        let requiredDepth = min(fixture.spec.retargetWindow, previousBlock.height + 1)
        let window = [block.timestamp] + Array(ancestors.prefix(Int(requiredDepth)))
        let expectedNext = fixture.spec.calculateWindowedTarget(
            previousTarget: block.target,
            ancestorTimestamps: window
        )

        XCTAssertEqual(block.target, max(previousBlock.nextTarget, ChainSpec.minimumTarget))
        XCTAssertEqual(block.nextTarget, expectedNext)
        XCTAssertTrue(block.validateNextTarget(
            spec: fixture.spec,
            parent: previousBlock,
            ancestorTimestamps: ancestors
        ))
    }
}
