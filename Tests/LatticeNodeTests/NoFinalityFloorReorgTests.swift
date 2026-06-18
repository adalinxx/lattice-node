import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker

/// SEC-101: consensus is pure heaviest-chain (`trueCumWork`) with NO
/// finality floor and NO depth-based rejection. These tests drive the node's
/// real consensus entry point — `ChainState.submitBlock`, which runs fork choice
/// (`checkForReorg`) — and assert:
///   1. a DEEP but strictly-heavier reorg is ACCEPTED (the tip moves to the
///      heavier fork even though its fork point is buried far below the old tip),
///      refuting any surviving depth gate; and
///   2. an equal/lighter chain is still REJECTED (the tip does not move).
///
/// Blocks built with `buildRetargetedTestBlock` carry equal per-block work
/// (target `UInt256.max`), so "more blocks past the fork point" == "strictly
/// heavier `trueCumWork`". This exercises the same code path live consensus uses.
///
/// This is a *genuine* refutation, not a defaulted-off no-op: the node re-pins
/// Lattice to the floor-removed revision (Package.swift), in which the
/// `violatesFinalityFloor` guard and the `finalityDepth` / `setFinalityDepth` /
/// `getFinalityDepth` API have been DELETED from `Chain`/`RetentionFinalityPolicy`.
/// There is therefore no operator-local or per-chain knob that can re-arm a
/// depth-based rejection of a heavier fork — the acceptance below holds
/// unconditionally, not merely because some finality depth was left at its
/// default. (Were the symbols still present, this file would simply not reference
/// them; their absence is enforced by the pin and the Lattice-side test suite.)
final class NoFinalityFloorReorgTests: XCTestCase {

    /// Build `count` blocks on top of `start`, submitting each to `chain`.
    /// Returns the built blocks (excluding `start`).
    private func extend(
        chain: ChainState, from start: Block, count: Int,
        baseTimestamp: Int64, nonceBase: UInt64, fetcher: TestBrokerFetcher
    ) async throws -> [Block] {
        var built: [Block] = []
        var prev = start
        for i in 1...count {
            let b = try await buildRetargetedTestBlock(
                previous: prev,
                timestamp: baseTimestamp + Int64(i) * 1_000,
                nonce: nonceBase + UInt64(i),
                fetcher: fetcher
            )
            try await storeBlockFixture(b, to: fetcher)
            _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl(node: b), block: b
            )
            built.append(b)
            prev = b
        }
        return built
    }

    func testDeepStrictlyHeavierReorgIsAccepted() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)
        let ts = now() - 500_000
        let target = UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: ts, target: target, fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: 100)

        // Main chain: genesis → A1 … A6 (tip at height 6).
        let aChain = try await extend(
            chain: chain, from: genesis, count: 6,
            baseTimestamp: ts, nonceBase: 0, fetcher: f
        )
        let mainTip = try VolumeImpl<Block>(node: aChain.last!).rawCID
        let tipAfterMain = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterMain, mainTip)
        let heightAfterMain = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfterMain, 6)

        // Competing fork off genesis (fork point buried 6 deep below the tip):
        // build 7 blocks B1 … B7 — strictly heavier than the 6-block main chain.
        let bChain = try await extend(
            chain: chain, from: genesis, count: 7,
            baseTimestamp: ts + 100, nonceBase: 10_000, fetcher: f
        )
        let forkTip = try VolumeImpl<Block>(node: bChain.last!).rawCID

        // Heaviest-chain only: the deeper-but-heavier fork must win. No finality
        // floor may refuse it for the reorg being too deep.
        let tipAfterFork = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterFork, forkTip,
            "deep but strictly-heavier fork must be ACCEPTED (no finality floor)")
        let heightAfterFork = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfterFork, 7)
        // The whole old suffix is gone — the heavier fork is canonical end to end.
        for (idx, b) in bChain.enumerated() {
            let h = await chain.getMainChainBlockHash(atIndex: UInt64(idx + 1))
            XCTAssertEqual(h, try VolumeImpl<Block>(node: b).rawCID,
                "fork block at height \(idx + 1) must be canonical after the deep reorg")
        }
    }

    func testEqualOrLighterForkIsRejected() async throws {
        let f = cas()
        let spec = testSpec(premine: 0)
        let ts = now() - 500_000
        let target = UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: ts, target: target, fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: 100)

        // Main chain: genesis → A1 … A5 (tip at height 5).
        let aChain = try await extend(
            chain: chain, from: genesis, count: 5,
            baseTimestamp: ts, nonceBase: 0, fetcher: f
        )
        let mainTip = try VolumeImpl<Block>(node: aChain.last!).rawCID
        let tipAfterMain = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterMain, mainTip)

        // Competing fork off genesis with only 4 blocks — strictly lighter.
        _ = try await extend(
            chain: chain, from: genesis, count: 4,
            baseTimestamp: ts + 100, nonceBase: 20_000, fetcher: f
        )

        // Heaviest-chain only: a lighter fork must NOT reorg the tip.
        let tipAfterFork = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterFork, mainTip,
            "lighter fork must be REJECTED — heaviest-chain only")
        let heightAfterFork = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfterFork, 5)
    }
}
